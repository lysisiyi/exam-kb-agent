/// 试卷导出：三版式 PDF。
///
/// ## 三个版式，对应三种真实用法
///
/// | 版式 | 用来干什么 | 关键设计 |
/// |---|---|---|
/// | [PaperLayout.exam] 试卷 | 掐表做一遍 | **不含答案解析**，每题下方留演算空间 |
/// | [PaperLayout.answers] 解析卷 | 做完对答案 | 题干 + 答案 + 解析 + 我的笔记 |
/// | [PaperLayout.wrongBook] 错题本 | 打印装订 | 按考点分组（错得多的排前面）|
///
/// 前两个是同一份卷子的两面。**组卷必须同时出答案** ——
/// 一份做完了无处核对的卷子等于没出。
///
/// ## 两个必须绕开的坑
///
/// ### 1. 中文在 `pdf` 包的默认字体里没有字形
///
/// `pdf` 包内置 Helvetica，不含中日韩字形。想写中文有两条路：
/// - `PdfGoogleFonts` —— **要联网下载**，与"纯本地、国内可用"的原则直接冲突
/// - 自带字体文件 —— 一个中文字体 5–10 MB，为了导出 PDF 给包体加这么多不划算
///
/// V1 的做法是**如实告知**：导出结果里带上提示，说明中文可能显示异常，
/// 并给出替代方案（导出 Markdown 包，或先看 App 内预览）。
/// 把它记进技术债，不假装没问题。
///
/// ### 2. 公式必须走位图
///
/// 见 `formula_rasterizer.dart`：用 Flutter 自己的 `KatexBoxPainter` 光栅化，
/// 换 PDF 与屏幕逐像素一致。非法 LaTeX 降级成等宽源码并计数 ——
/// **不静默丢内容**。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/platform/system_fonts.dart';
import '../../data/markdown/problem_markdown.dart';
import '../../domain/paper/paper_models.dart';
import 'formula_rasterizer.dart';

/// 导出为哪种版式。
enum PaperLayout {
  exam('试卷', '只有题目，留够演算空间'),
  answers('解析卷', '题干 + 答案 + 解析'),
  wrongBook('错题本', '按考点分组，带错题记录');

  const PaperLayout(this.label, this.description);
  final String label;
  final String description;
}

/// 导出结果。
class PdfExportResult {
  final String path;
  final int bytes;
  final int problems;

  /// 因为非法 LaTeX 而降级成源码的公式数。
  ///
  /// 单独报出来而不是静默处理：用户看到某道题显示的是源码而不是公式时，
  /// 要知道那是**数据的问题**（那条 LaTeX 不合法或太长），不是 App 坏了。
  final int degradedFormulas;

  /// 在题库里读不到、只能用摘要兜底的题目数。
  ///
  /// 这个必须报出来。读不到的题在**解析卷**里会连带丢掉答案、解析与选项 ——
  /// 而解析卷的全部意义就是"做完对答案"。不提示的话，用户拿到的是一份
  /// 缺答案的解析卷，还以为自己组的卷子没答案可给。
  final int missingProblems;

  /// 题干里引用了图片、但 PDF 里没有嵌入的题目数。
  ///
  /// 公式走位图，图片目前不走（`splitMarkdownPieces` 只切 `$...$`）。
  /// 与其把 `![](images/x.png)` 原样印在卷子上，不如换成占位符并如实告知：
  /// 要看原图请用 Markdown 包（`设置 → 导出题库`），那里图片是拷过去的。
  final int omittedImages;

  /// 正文里含中文字符。
  ///
  /// ⚠️ 这个标志**恒为 true**：PDF 的页眉、页脚、页码、分区标题（"选择题
  /// （共 10 题，50 分）"）、"答案"/"解析"标签全都是中文，由本文件自己写死。
  /// 早先它只统计题目正文，于是"一道纯英文题"导出后会带着一堆乱码标签，
  /// 而提示**不出现** —— 恰好是最需要提示的那种情况。
  final bool hasChinese;

  /// 是否成功嵌入了中文字体。
  ///
  /// 为 true 时中文**正常显示**（字形取自本机字体，只嵌入用到的那些）。
  /// 为 false 表示这台机器上一个候选中文字体都没找到（英文/精简版 Windows），
  /// 此时中文会渲染成空白 —— **必须提示用户**，见 [caveats]。
  final bool hasCjkFont;

  const PdfExportResult({
    required this.path,
    required this.bytes,
    required this.problems,
    this.degradedFormulas = 0,
    this.missingProblems = 0,
    this.omittedImages = 0,
    this.hasChinese = true,
    this.hasCjkFont = false,
  });

  String get sizeText {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  String get summary => '导出了 $problems 道题 · $sizeText';

  /// 需要提醒用户的事（可能为空）。
  List<String> get caveats => [
        // 只有"有中文但没找到中文字体"才需要提醒。
        // 找得到字体时**不再出现**这条 —— T43 已经修好了。
        if (hasChinese && !hasCjkFont) _noFontCaveat,
        if (missingProblems > 0)
          '$missingProblems 道题在题库里读不到（Markdown 文件缺失或损坏），这份卷子里它们只有题干摘要，没有答案与解析。可以先重建索引确认题库是否完整。',
        if (omittedImages > 0)
          '$omittedImages 道题的题干里有插图，PDF 里以「［图］」占位、未嵌入原图。需要带图的版本请用「设置 → 导出题库」导出 Markdown 包。',
        if (degradedFormulas > 0)
          '$degradedFormulas 处公式无法渲染（LaTeX 不合法或尺寸过大），已降级为等宽源码显示。',
      ];

  /// 本机一个中文字体都没找到时的提示。
  ///
  /// 措辞要给出**具体出路**：这不是"App 坏了"，而是这台机器缺字体。
  static const String _noFontCaveat =
      '这台机器上没有找到可用的中文字体（黑体 / 楷体 / 仿宋 / 等线），'
      '卷子里的中文会显示成空白。'
      '装一个中文字体（Windows 的「语言和区域」里加中文即可），'
      '或改用「设置 → 导出题库」的 Markdown 包。';
}

/// 试卷 PDF 导出器。
class PaperPdfExporter {
  final FormulaRasterizer rasterizer;

  /// 取完整题目内容。组卷结果里只有摘要，导出需要题干/答案/解析。
  final Future<Problem?> Function(String problemId) loadProblem;

  PaperPdfExporter({
    required this.loadProblem,
    FormulaRasterizer? rasterizer,
  }) : rasterizer = rasterizer ?? FormulaRasterizer();

  int _degraded = 0;
  int _missing = 0;
  int _omittedImages = 0;

  /// 题干里的图片引用。PDF 不嵌图，只记数并换成占位符。
  static final RegExp _imageRef = RegExp(r'!\[([^\]]*)\]\(([^)]*)\)');

  /// 中文字体：整个进程只加载一次。
  ///
  /// ## 为什么要缓存
  ///
  /// 黑体那个文件是 **9.29 MB**，`pw.Font.ttf()` 持有它的字节，
  /// 真正解析发生在第一次用它画字的时候。每次导出都重读一遍
  /// 是没必要的 IO + 解析。
  ///
  /// 用 `static` 而不是实例字段：`PaperPdfExporter` 是**每次点导出新建一个**的
  /// （见 `paper_page.dart`），实例字段等于没有缓存。
  static pw.Font? _cjkFont;
  static bool _cjkLoaded = false;

  /// 取中文字体。找不到返回 null（**不抛**）。
  ///
  /// ⚠️ 这里**必须允许注入失败**：测试要能验"这台机器没有中文字体时
  /// 会如实提示"，而在装了中文字体的开发机上跑不出那条分支。
  static Future<pw.Font?> cjkFont({bool forceReload = false}) async {
    if (_cjkLoaded && !forceReload) return _cjkFont;
    _cjkLoaded = true;
    _cjkFont = null;

    final bytes = await SystemFonts.loadCjk();
    if (bytes == null || bytes.isEmpty) return null;
    try {
      _cjkFont = pw.Font.ttf(ByteData.view(bytes.buffer, bytes.offsetInBytes));
    } catch (_) {
      // 字体文件损坏 / 格式不被 pdf 包支持 —— 降级到"没有中文字体"
      _cjkFont = null;
    }
    return _cjkFont;
  }

  /// 仅供测试：清掉缓存，让下一次调用重新探测。
  @visibleForTesting
  static void resetCjkFontCache() {
    _cjkFont = null;
    _cjkLoaded = false;
  }

  /// 导出到 [target]。
  ///
  /// ## 为什么先把所有 widget 建好再交给 pdf 包
  ///
  /// `pw.MultiPage.build` 是**同步**回调，而公式光栅化必须 await
  /// （`Picture.toImage` 是异步的）。把 `await` 塞进同步回调里编译都过不去，
  /// 所以顺序是：先 await 建出完整 widget 列表 → 再 `addPage`。
  Future<PdfExportResult> export({
    required PaperResult paper,
    required PaperLayout layout,
    required File target,
    String? title,
  }) async {
    _resetCounters();

    final cjk = await cjkFont();
    final body = await _buildBody(paper, layout);

    final doc = pw.Document(
      title: title ?? paper.template.name,
      author: '考研数学错题 Agent',
      // 中文走 [fontFallback]，拉丁字母与数字**仍然用 Helvetica**：
      // 后者是 PDF 的标准 14 字体之一，不嵌入、只引用，文件更小
      // 且字形比中文字体里的拉丁部分好看。
      theme: _themeWith(cjk),
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(42, 40, 42, 36),
        header: (ctx) => _header(paper, layout, title),
        footer: _footer,
        build: (ctx) => body,
      ),
    );

    final bytes = await doc.save();
    await target.writeAsBytes(bytes, flush: true);

    return PdfExportResult(
      path: target.path,
      bytes: bytes.length,
      problems: paper.items.length,
      degradedFormulas: _degraded,
      missingProblems: _missing,
      omittedImages: _omittedImages,
      hasChinese: true,
      hasCjkFont: cjk != null,
    );
  }

  /// 文档主题：把中文字体挂在 [pw.ThemeData.withFont] 的 `fontFallback` 上。
  ///
  /// 走主题而不是给每个 `pw.TextStyle` 加一遍 `fontFallback`：
  /// 样式散在七八处（页眉、页脚、"答案"/"解析"标签、题号行、正文……），
  /// 逐处加**迟早会漏一处**，而漏掉的那处就是一块空白。
  /// 主题是单一入口，漏不掉。
  static pw.ThemeData _themeWith(pw.Font? cjk) => pw.ThemeData.withFont(
        base: pw.Font.helvetica(),
        bold: pw.Font.helveticaBold(),
        italic: pw.Font.helveticaOblique(),
        boldItalic: pw.Font.helveticaBoldOblique(),
        fontFallback: cjk == null ? const [] : [cjk],
      );

  void _resetCounters() {
    _degraded = 0;
    _missing = 0;
    _omittedImages = 0;
  }

  /// 只渲染第一页的字节，用于"导出前看一眼"而不落盘。
  Future<int> estimateBytes(PaperResult paper, PaperLayout layout) async {
    final cjk = await cjkFont();
    final body = await _buildBody(paper, layout);
    final doc = pw.Document(theme: _themeWith(cjk));
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(42, 40, 42, 36),
      build: (ctx) => body,
    ));
    return (await doc.save()).length;
  }

  // ───────────────────────────────────────────────────────────────────────
  // 页面结构
  // ───────────────────────────────────────────────────────────────────────

  pw.Widget _header(PaperResult paper, PaperLayout layout, String? title) {
    final parts = <String>[
      if (paper.template.durationMinutes != null)
        '建议用时 ${paper.template.durationMinutes} 分钟',
      '满分 ${paper.totalScore} 分',
      '共 ${paper.items.length} 题',
      if (paper.hasEstimatedScores) '分值为估算',
    ];
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Expanded(
              child: pw.Text(
                title ?? paper.template.name,
                style: const pw.TextStyle(
                    fontSize: 15, fontWeight: pw.FontWeight.bold),
              ),
            ),
            pw.Text(layout.label,
                style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
          ],
        ),
        pw.SizedBox(height: 2),
        pw.Text(parts.join('　·　'),
            style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700)),
        pw.SizedBox(height: 4),
        pw.Divider(thickness: 0.6, color: PdfColors.grey600),
      ],
    );
  }

  pw.Widget _footer(pw.Context ctx) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('考研数学错题 Agent',
              style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey600)),
          pw.Text('第 ${ctx.pageNumber} / ${ctx.pagesCount} 页',
              style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey600)),
        ],
      );

  Future<List<pw.Widget>> _buildBody(PaperResult paper, PaperLayout layout) async {
    const base = pw.TextStyle(fontSize: 10.5, lineSpacing: 2.5);

    if (paper.items.isEmpty) {
      return [
        pw.SizedBox(height: 40),
        pw.Center(
          child: pw.Text('这份卷子没有题目 —— 题库里还没有符合条件的题。',
              style: const pw.TextStyle(fontSize: 11)),
        ),
      ];
    }

    final widgets = <pw.Widget>[];
    if (layout == PaperLayout.wrongBook) {
      await _byKnowledgePoint(paper, layout, base, widgets);
    } else {
      await _bySection(paper, layout, base, widgets);
    }

    // 末尾附组卷说明。用户需要知道这份卷子偏离模板在哪里。
    if (paper.warnings.isNotEmpty) {
      widgets.add(pw.SizedBox(height: 18));
      widgets.add(pw.Divider(thickness: 0.5, color: PdfColors.grey500));
      widgets.add(pw.SizedBox(height: 6));
      widgets.add(pw.Text('组卷说明',
          style:
              const pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)));
      widgets.add(pw.SizedBox(height: 4));
      for (final w in paper.warnings) {
        widgets.add(pw.Text('· $w',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey800)));
      }
    }

    return widgets;
  }

  Future<void> _bySection(
    PaperResult paper,
    PaperLayout layout,
    pw.TextStyle base,
    List<pw.Widget> out,
  ) async {
    for (final entry in paper.bySection.entries) {
      final items = entry.value;
      final subtotal = items.fold<int>(
          0, (s, it) => s + (it.seat.score ?? kFallbackScorePerItem));
      out.add(pw.SizedBox(height: 10));
      out.add(pw.Text(
        '${entry.key}（共 ${items.length} 题，$subtotal 分）',
        style:
            const pw.TextStyle(fontSize: 11.5, fontWeight: pw.FontWeight.bold),
      ));
      out.add(pw.SizedBox(height: 6));
      for (final it in items) {
        await _appendItem(it, layout, base, out);
      }
    }
  }

  Future<void> _byKnowledgePoint(
    PaperResult paper,
    PaperLayout layout,
    pw.TextStyle base,
    List<pw.Widget> out,
  ) async {
    final byKp = <String, List<PaperItem>>{};
    for (final it in paper.items) {
      byKp.putIfAbsent(it.primaryKpName ?? '未归类', () => []).add(it);
    }
    // 错得多的考点排前面 —— 错题本是拿来重点攻的
    final keys = byKp.keys.toList()
      ..sort((a, b) {
        int wrongOf(String k) => byKp[k]!.fold(0, (s, it) => s + it.wrongCount);
        return wrongOf(b).compareTo(wrongOf(a));
      });

    for (final kp in keys) {
      final items = byKp[kp]!;
      out.add(pw.SizedBox(height: 10));
      out.add(pw.Text(
        '$kp（${items.length} 题）',
        style:
            const pw.TextStyle(fontSize: 11.5, fontWeight: pw.FontWeight.bold),
      ));
      out.add(pw.SizedBox(height: 6));
      for (final it in items) {
        await _appendItem(it, layout, base, out);
      }
    }
  }

  /// 追加一道题的全部 widget。
  Future<void> _appendItem(
    PaperItem item,
    PaperLayout layout,
    pw.TextStyle base,
    List<pw.Widget> out,
  ) async {
    final problem = await loadProblem(item.problemId);

    final meta = <String>[
      if (item.seat.score != null) '${item.seat.score} 分',
      if (item.wrongCount > 0) '错过 ${item.wrongCount} 次',
    ];

    // 题号行
    out.add(pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(
          width: 26,
          child: pw.Text('${item.seat.no}.',
              style: const pw.TextStyle(
                  fontSize: 10.5, fontWeight: pw.FontWeight.bold)),
        ),
        pw.Expanded(
          child: meta.isEmpty
              ? pw.SizedBox()
              : pw.Text(meta.join('　'),
                  style: const pw.TextStyle(
                      fontSize: 7.5, color: PdfColors.grey600)),
        ),
      ],
    ));

    // 题干
    if (problem == null) {
      // 读不到 Markdown 时用摘要兜底 —— 宁可显示得糙一点，
      // 也不要让这道题在 PDF 里凭空消失。
      //
      // 但**必须计数**：解析卷版式下，这里会连带丢掉答案、解析与选项，
      // 而解释卷的全部意义就是"做完对答案"。静默降级等于交付一份残卷。
      _missing++;
      out.add(_indented(pw.Text(item.stemText, style: base)));
    } else {
      await _markdown(problem.stem, base, indent: 26, out: out);
      for (var i = 0; i < problem.options.length; i++) {
        await _markdown(
          '${String.fromCharCode(65 + i)}. ${problem.options[i]}',
          base,
          indent: 34,
          out: out,
        );
      }
    }

    // 答案解析（只在解析卷与错题本版式里出）
    if (layout != PaperLayout.exam && problem != null) {
      if (_has(problem.answer)) {
        out.add(_label('答案'));
        await _markdown(problem.answer!, base, indent: 26, out: out);
      }
      if (_has(problem.solution)) {
        out.add(_label('解析'));
        await _markdown(problem.solution!, base, indent: 26, out: out);
      }
      if (_has(problem.note)) {
        out.add(_label('我的笔记'));
        await _markdown(problem.note!, base, indent: 26, out: out);
      }
    }

    if (layout == PaperLayout.exam) {
      // 试卷版式：留演算空间。这是"打印出来能直接做"的关键 ——
      // 不留白的话用户得另找纸，那份卷子就白出了。
      out.add(pw.SizedBox(height: _answerSpaceFor(item)));
    } else {
      out.add(pw.SizedBox(height: 10));
      out.add(pw.Divider(thickness: 0.3, color: PdfColors.grey400));
    }
  }

  static bool _has(String? s) => s != null && s.trim().isNotEmpty;

  /// 演算空间高度：解答题给得多，客观题给得少。
  double _answerSpaceFor(PaperItem item) {
    if (item.seat.isAnyQtype) return 90;
    return switch (item.seat.qtype) {
      'solve' || 'proof' => 110,
      'fill' => 34,
      _ => 46,
    };
  }

  pw.Widget _label(String text) => pw.Padding(
        padding: const pw.EdgeInsets.only(left: 26, top: 3, bottom: 1),
        child: pw.Text(text,
            style: const pw.TextStyle(
                fontSize: 8.5,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.grey800)),
      );

  pw.Widget _indented(pw.Widget child) =>
      pw.Padding(padding: const pw.EdgeInsets.only(left: 26), child: child);

  /// 把一段 Markdown + LaTeX 追加成 PDF widget。
  ///
  /// 公式走 [FormulaRasterizer] 出位图；光栅化失败（非法 LaTeX）时
  /// 降级成等宽源码并计数 —— **不静默丢内容**。
  ///
  /// ## ⚠️ 行内公式必须**留在段落里**，不能各占一行
  ///
  /// 早先这里是"每个片段一个块"：文字一段、公式一张图、再文字一段……
  /// 于是一句
  ///
  /// ```
  /// 设函数 $f(x)$ 在闭区间 $[a,b]$ 上连续，在开区间 $(a,b)$ 内可导。
  /// ```
  ///
  /// 会被拆成 **7 个上下堆叠的块**（"设函数" / f(x) / "在闭区间" / [a,b] /
  /// "上连续，在开区间" / (a,b) / "内可导。"），每个各占一行 ——
  /// 排版碎得没法读。用户反馈的"换行过多"就是它。
  ///
  /// 现在按 [groupPieces] 分组：**一段连续的行内内容合成一个 `pw.RichText`**，
  /// 公式作为 `pw.WidgetSpan` 嵌在文字中间，基线用
  /// [FormulaImage.baseline] 对齐。只有 `$$...$$` 独立公式仍然单独成行
  /// （那本来就该居中独占一行）。
  Future<void> _markdown(
    String src,
    pw.TextStyle base, {
    required double indent,
    required List<pw.Widget> out,
  }) async {
    // 图片引用换成占位符。
    //
    // `splitMarkdownPieces` 只切 `$...$`，所以 `![图](images/x.png)` 会原样
    // 落进 TextPiece —— 直接印出来就是一行 Markdown 源码，用户完全看不懂。
    // 这里换成"［图］"并记数，导出结束后如实提示去看 Markdown 包。
    final withPlaceholders = src.replaceAllMapped(_imageRef, (m) {
      _omittedImages++;
      final alt = (m.group(1) ?? '').trim();
      return alt.isEmpty ? '［图］' : '［图：$alt］';
    });

    for (final block in groupPieces(splitMarkdownPieces(withPlaceholders))) {
      switch (block) {
        case DisplayFormula(:final tex):
          final img = await rasterizer.rasterize(
            tex,
            fontSize: 14,
            displayMode: true,
          );
          if (img == null) {
            _degraded++;
            out.add(pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 4),
              child: _degradedText(tex),
            ));
            continue;
          }
          out.add(pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 5),
            child: pw.Center(child: _formulaImage(img)),
          ));

        case InlineRun(:final pieces):
          final spans = await _inlineSpans(pieces, base);
          if (spans.isEmpty) continue;
          out.add(pw.Padding(
            padding: pw.EdgeInsets.only(left: indent, top: 1, bottom: 1),
            child: pw.RichText(
              text: pw.TextSpan(style: base, children: spans),
            ),
          ));
      }
    }
  }

  /// 把一段行内内容排成 span 序列（公式是 [pw.WidgetSpan]）。
  ///
  /// 文字片段**不 trim**：片段之间的空格是原文的一部分，
  /// 去掉会让 `设函数 f(x) 在…` 变成 `设函数f(x)在…`。
  /// 只把整体两端交给 `RichText` 自己处理。
  Future<List<pw.InlineSpan>> _inlineSpans(
    List<MarkdownPiece> pieces,
    pw.TextStyle base,
  ) async {
    final spans = <pw.InlineSpan>[];
    for (final p in pieces) {
      switch (p) {
        case TextPiece(:final text):
          if (text.isEmpty) continue;
          spans.add(pw.TextSpan(text: text));
        case FormulaPiece(:final tex, :final display):
          // 行内片段里理论上不会出现 display（groupPieces 已把它们分出去），
          // 但真出现了也按行内排，别丢内容
          final img = await rasterizer.rasterize(
            tex,
            fontSize: display ? 14 : 10.5,
            displayMode: false,
          );
          if (img == null) {
            _degraded++;
            spans.add(pw.TextSpan(
              text: tex,
              // `pw.Font.courier()` 不是 const 构造，所以这里不能用 const
              style: pw.TextStyle(
                fontSize: 8.5,
                font: pw.Font.courier(),
                color: PdfColors.red800,
              ),
            ));
            continue;
          }
          spans.add(pw.WidgetSpan(
            // 基线对齐：见 [_pdfBaseline]（`pdf` 的锚点不是 Flutter 那套）
            baseline: _pdfBaseline(img),
            child: _formulaImage(img),
          ));
      }
    }
    return spans;
  }

  /// 把 [FormulaImage] 的几何值换算成 `pdf` 包要的 `WidgetSpan.baseline`。
  ///
  /// ## 为什么不能直接用 `img.baseline`
  ///
  /// Flutter 的 `WidgetSpan.baseline` 是"控件顶到自己基线的距离"，
  /// 而 `pdf` 包的实现**锚的是控件底边**：它把控件底边放在
  /// `文字基线 + baseline` 处，控件从那里往上长
  /// （见其 `text.dart`：`ws.offset = PdfPoint(offsetX, -offsetY + baseline)`，
  /// 控件再以该点为原点向上绘制）。
  ///
  /// 于是"控件顶到基线距离 = d"这件事在 `pdf` 里要写成 `d - 高度`。
  ///
  /// ## 这个结论是量出来的，不是猜的
  ///
  /// 早先直接传 `img.baseline`，导出的样张里量到的位置是
  /// （`解析卷.pdf`，题干行文字基线 y = 688.14）：
  ///
  /// | 量到的东西 | 值 |
  /// |---|---|
  /// | 公式图片底边 y | 696.91 |
  /// | 即图片底边比文字基线**高** | 8.77pt |
  /// | 而图片顶到数学基线是 | 8.77pt |
  /// | → 数学基线比文字基线高 | 12.07pt（正好一个图片高度）|
  ///
  /// 也就是每个公式都整整浮高一行。换算后图片底边落到
  /// `文字基线 - (depth + 内边距) * 字号`（约 −3pt），公式基线与文字基线重合。
  static double _pdfBaseline(FormulaImage img) => img.baseline - img.height;

  /// 公式位图 → PDF 图片控件。
  ///
  /// ⚠️ `dpi` 不能省。
  ///
  /// 一旦给 `pw.Image` 传了 width/height，`pdf` 包就走 **DPI 路径**：
  /// 它按 dpi（省略时默认 72）算出目标像素数，再 `copyResize` 缩放。
  /// 默认 72 的含义是"这张位图按 72 dpi 使用"，于是我们辛苦按 4 倍光栅化
  /// 出来的 56px 公式，会被**重新采样回 14px** 再嵌入 —— 打印出来就是糊的
  /// （`formula_rasterizer.dart` 承诺的 300 dpi 量级完全没有兑现）。
  /// 把 dpi 按同样的倍数放大，`effectiveDpi` 才与位图实际密度一致，
  /// 包里的 `copyResize` 也就不会发生。
  pw.Widget _formulaImage(FormulaImage img) => pw.Image(
        pw.MemoryImage(img.png, dpi: 72 * rasterizer.pixelRatio),
        width: img.width,
        height: img.height,
      );

  /// 降级显示的公式源码（等宽红字）。
  pw.Widget _degradedText(String tex) => pw.Text(
        tex,
        style: pw.TextStyle(
          fontSize: 8.5,
          font: pw.Font.courier(),
          color: PdfColors.red800,
        ),
      );
}

/// 一段混排内容被排成哪些"块"。
sealed class PdfBlock {
  const PdfBlock();
}

/// 一段**行内**内容：文字与行内公式，合成一个段落排。
class InlineRun extends PdfBlock {
  final List<MarkdownPiece> pieces;
  const InlineRun(this.pieces);
}

/// 一个**独立**公式（`$$...$$`）：居中独占一块。
class DisplayFormula extends PdfBlock {
  final String tex;
  const DisplayFormula(this.tex);
}

/// 把切好的片段分组：连续的行内内容并成一段，独立公式各自成块。
///
/// 抽成顶层函数是为了**能单测**：用户反馈的"换行过多"本质就是
/// "一句话题干被分成了几个块"，而这件事不需要渲染 PDF 就能断言。
/// 见 `test/paper_export_test.dart` 的「PDF 排版」一组。
List<PdfBlock> groupPieces(List<MarkdownPiece> pieces) {
  final out = <PdfBlock>[];
  var current = <MarkdownPiece>[];

  void flush() {
    // 段落结尾的悬空空白丢掉。
    //
    // 只在**没有换行**时丢：`$x$  ` 尾巴上的两个空格没有任何信息，
    // 留着却可能正好压满一行、多折出一个空行。而 `"正文\n\n"` 里的
    // 换行是原文的段落分隔，丢了会把两段并成一段。
    while (current.isNotEmpty) {
      final last = current.last;
      final dangling = last is TextPiece &&
          last.text.trim().isEmpty &&
          !last.text.contains('\n');
      if (!dangling) break;
      current.removeLast();
    }
    if (current.isEmpty) return;
    out.add(InlineRun(List.unmodifiable(current)));
    current = <MarkdownPiece>[];
  }

  for (final p in pieces) {
    if (p is FormulaPiece && p.display) {
      flush();
      out.add(DisplayFormula(p.tex));
      continue;
    }
    // 段落开头的纯空白片段不单独成块（否则会多出一堆空行）
    if (p is TextPiece && p.text.trim().isEmpty && current.isEmpty) continue;
    current.add(p);
  }
  flush();

  return out;
}
