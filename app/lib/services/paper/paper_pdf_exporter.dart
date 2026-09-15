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

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

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
  /// 要知道那是**数据的问题**（那条 LaTeX 不合法），不是 App 坏了。
  final int degradedFormulas;

  /// 正文里含中文字符。
  ///
  /// `pdf` 包默认字体不含中日韩字形，所以这种情况要在结果里提示。
  /// 不提示的话用户会拿到一份满是空白的 PDF 而不知道为什么。
  final bool hasChinese;

  const PdfExportResult({
    required this.path,
    required this.bytes,
    required this.problems,
    this.degradedFormulas = 0,
    this.hasChinese = false,
  });

  String get sizeText {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  String get summary => '导出了 $problems 道题 · $sizeText';

  /// 需要提醒用户的事（可能为空）。
  List<String> get caveats => [
        if (hasChinese) _chineseCaveat,
        if (degradedFormulas > 0)
          '$degradedFormulas 处公式的 LaTeX 不合法，已降级为等宽源码显示。',
      ];

  static const String _chineseCaveat =
      '正文含中文，而 PDF 内置字体不含中文字形 —— 中文可能显示异常或缺失。'
      '需要完整中文排版时，请先用「设置 → 导出题库」导出 Markdown 包。';
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
  bool _sawChinese = false;

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
    _degraded = 0;
    _sawChinese = false;

    final body = await _buildBody(paper, layout);

    final doc = pw.Document(
      title: title ?? paper.template.name,
      author: '考研数学错题 Agent',
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
      hasChinese: _sawChinese,
    );
  }

  /// 只渲染第一页的字节，用于"导出前看一眼"而不落盘。
  Future<int> estimateBytes(PaperResult paper, PaperLayout layout) async {
    final body = await _buildBody(paper, layout);
    final doc = pw.Document();
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
      // 也不要让这道题在 PDF 里凭空消失
      _note(item.stemText);
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
  Future<void> _markdown(
    String src,
    pw.TextStyle base, {
    required double indent,
    required List<pw.Widget> out,
  }) async {
    _note(src);

    for (final p in splitMarkdownPieces(src)) {
      switch (p) {
        case TextPiece(:final text):
          final t = text.trim();
          if (t.isEmpty) continue;
          out.add(pw.Padding(
            padding: pw.EdgeInsets.only(left: indent, top: 1, bottom: 1),
            child: pw.Text(t, style: base),
          ));

        case FormulaPiece(:final tex, :final display):
          final img = await rasterizer.rasterize(
            tex,
            fontSize: display ? 14 : 10.5,
            displayMode: display,
          );
          if (img == null) {
            _degraded++;
            out.add(pw.Padding(
              padding: pw.EdgeInsets.only(left: indent, top: 1, bottom: 1),
              child: pw.Text(
                tex,
                style: pw.TextStyle(
                  fontSize: 8.5,
                  font: pw.Font.courier(),
                  color: PdfColors.red800,
                ),
              ),
            ));
            continue;
          }
          final image = pw.Image(
            pw.MemoryImage(img.png),
            width: img.width,
            height: img.height,
          );
          out.add(pw.Padding(
            padding: pw.EdgeInsets.only(
              left: display ? 0 : indent,
              top: display ? 4 : 1,
              bottom: display ? 4 : 1,
            ),
            child: display
                ? pw.Center(child: image)
                : pw.Align(alignment: pw.Alignment.centerLeft, child: image),
          ));
      }
    }
  }

  /// 记下这段文本里有没有中文。
  void _note(String s) {
    if (_sawChinese) return;
    for (final r in s.runes) {
      if ((r >= 0x4E00 && r <= 0x9FFF) ||
          (r >= 0x3000 && r <= 0x303F) ||
          (r >= 0xFF00 && r <= 0xFFEF)) {
        _sawChinese = true;
        return;
      }
    }
  }
}
