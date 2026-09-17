/// 试卷导出与组卷数据层测试。
///
/// ## 这里要守的三件事
///
/// 1. **PDF 真的能生成**，且三种版式的内容差异符合设计
///    （试卷版式**不能**含答案 —— 含了就等于泄题）
/// 2. **非法 LaTeX 降级但不丢内容**，并且记账
/// 3. **组卷结果落库后能读回来**，参数快照包含"偏离模板在哪"
///
/// ## 为什么 PDF 断言看的是"字节流里有没有那段文字"
///
/// 没法在测试里"看" PDF。但 `pdf` 包会把文本以可提取的形式写进内容流，
/// 所以用拉丁字母做的探针文字（`ANSWER-MARKER`）能在原始字节里搜到 ——
/// 用它判断"答案到底有没有被写进去"是可靠的。
///
/// ⚠️ **探针必须用拉丁字母**，理由不是"中文没字形"（T43 已修好），
/// 而是：中文字体走 TrueType 的 `/Encoding /Identity-H`，正文里写的是
/// **字形序号（GID）** 而不是字符码 —— 汉字本身在字节流里搜不到。
/// 这是 CID 字体的正常编码方式，不是缺陷。
///
/// 「中文到底有没有被嵌进去」由 `T43：中文能正常嵌进 PDF` 那一组
/// 用 `/FontFile2` 来判定（见那组的说明）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/platform/system_fonts.dart';
import 'package:kaoyan_math_agent/data/db/database.dart';
import 'package:kaoyan_math_agent/data/markdown/problem_markdown.dart';
import 'package:kaoyan_math_agent/domain/paper/paper_models.dart';
import 'package:kaoyan_math_agent/services/paper/formula_rasterizer.dart';
import 'package:kaoyan_math_agent/services/paper/paper_composer.dart';
import 'package:kaoyan_math_agent/services/paper/paper_pdf_exporter.dart';
import 'package:kaoyan_math_agent/services/paper/paper_repository.dart';

import 'support/test_env.dart';

/// 造一份能直接导出的小卷。
PaperTemplate _template() => const PaperTemplate(
      id: 'test.small',
      name: 'Test Paper',
      description: '',
      totalScore: 15,
      durationMinutes: 30,
      seats: [
        PaperSeat(
            no: 1,
            sectionName: '选择题',
            qtype: 'choice',
            score: 5,
            targetDifficulty: 1),
        PaperSeat(
            no: 2,
            sectionName: '解答题',
            qtype: 'solve',
            score: 10,
            targetDifficulty: 2),
      ],
    );

/// 造一份已落位的组卷结果（不经过引擎，便于精确控制内容）。
PaperResult _result({List<PaperItem>? items}) {
  final t = _template();
  return PaperResult(
    template: t,
    subject: 'math1',
    items: items ??
        [
          PaperItem(
            seat: t.seats[0],
            problemId: 'p-1',
            stemText: '第一题题干',
            actualDifficulty: 1,
          ),
          PaperItem(
            seat: t.seats[1],
            problemId: 'p-2',
            stemText: '第二题题干',
            actualDifficulty: 2,
            wrongCount: 3,
          ),
        ],
  );
}

/// 从 PDF 里抽出可搜索的文本。
///
/// ## 为什么不能直接搜原始字节
///
/// `pdf` 包默认把内容流做 **Flate 压缩**，所以 `readAsBytes` 出来的东西
/// 里搜不到任何文字 —— 实测搜什么都是 `%PDF-1.5`。必须先把流解压。
///
/// 这里刻意用"解压全部 stream 再拼起来搜"的粗办法：PDF 的文本会被拆成
/// 多个 `Tj` 片段（字距调整会把一个词切开），所以**不要**指望搜到跨片段的
/// 长字符串 —— 探针文字要短、要连续。
String extractPdfText(List<int> bytes) {
  final raw = Uint8List.fromList(bytes);
  final out = StringBuffer();
  // 逐字节找 `stream` … `endstream`，中间那段试着按 zlib 解压
  for (var i = 0; i < raw.length - 6; i++) {
    if (!_matches(raw, i, 'stream')) continue;
    var start = i + 6;
    if (start < raw.length && raw[start] == 0x0D) start++;
    if (start < raw.length && raw[start] == 0x0A) start++;

    final end = _indexOf(raw, 'endstream', start);
    if (end < 0) break;

    // 去掉尾随换行
    var stop = end;
    while (stop > start && (raw[stop - 1] == 0x0A || raw[stop - 1] == 0x0D)) {
      stop--;
    }
    if (stop > start) {
      try {
        // `dart:io` 自带 zlib 编解码 —— PDF 的 FlateDecode 就是 zlib 流。
        // 早先这里用的是 `package:archive` 的 `ZLibDecoder`，为了一个
        // 测试函数引一个包不值得（而且它当时被声明成无界的 `archive: any`）。
        final decoded = zlib.decode(raw.sublist(start, stop));
        out.write(latin1.decode(decoded));
      } catch (_) {
        // 不是 zlib 流（或本来就是明文）就直接用原文
        out.write(latin1.decode(raw.sublist(start, stop), allowInvalid: true));
      }
    }
    i = end;
  }
  // 兜底：把原始字节也并进来，明文 PDF 的情况同样能搜到
  out.write(latin1.decode(raw, allowInvalid: true));
  return out.toString();
}

bool _matches(Uint8List b, int at, String s) {
  if (at + s.length > b.length) return false;
  for (var i = 0; i < s.length; i++) {
    if (b[at + i] != s.codeUnitAt(i)) return false;
  }
  return true;
}

int _indexOf(Uint8List b, String s, int from) {
  for (var i = from; i + s.length <= b.length; i++) {
    if (_matches(b, i, s)) return i;
  }
  return -1;
}

void main() {
  late TempLibrary env;
  late Directory outDir;

  setUp(() async {
    env = await TempLibrary.create();
    outDir = await Directory.systemTemp.createTemp('dsh-pdf-');
  });

  tearDown(() async {
    await env.dispose();
    try {
      await outDir.delete(recursive: true);
    } catch (_) {}
  });

  /// 直接用 Markdown 文件当题目来源，绕开数据库。
  Future<Problem?> loadFromStore(String id) async {
    final r = await env.store.read(id);
    return r.problem;
  }

  PaperPdfExporter exporter() => PaperPdfExporter(loadProblem: loadFromStore);

  // ───────────────────────────────────────────────────────────────────────────
  group('T43：中文能正常嵌进 PDF', () {
    // ## 这一组在验什么
    //
    // 缺陷是"PDF 内置字体不含中文字形 → 中文渲染成空白"。`pdf` 包遇到
    // 画不出来的字符时会插一个**占位空白**，并且只在 debug 下 `print`
    // 一句提示 —— 所以它长期没被发现：文件照常生成、测试照常通过、
    // 只有人眼能看到那份卷子上是空的。
    //
    // 修法是给文档主题挂 `fontFallback`（取本机已装的中文字体）。
    // 于是"中文有没有真的被嵌入"这件事可以**从 PDF 字节里读出来**：
    // 嵌入的 TrueType 会在字体描述里留下 `/FontFile2`，
    // 而 Helvetica 是 PDF 标准 14 字体之一、**从不嵌入**。
    // 所以"有没有 `/FontFile2`"就是"中文有没有字形"的可判定代理。

    /// PDF 里有没有嵌入 TrueType 字体。
    bool embedsTtf(List<int> bytes) =>
        _indexOf(Uint8List.fromList(bytes), 'FontFile2', 0) >= 0;

    test('含中文的 PDF 会嵌入 TrueType 中文字体（走 CID 路径）', () async {
      final cjk = SystemFonts.findCjk();
      if (cjk == null) {
        // 英文/精简版 Windows 上确实一个中文字体都没有。
        // 那条分支由下面「一个中文字体都没有时必须如实提示」覆盖。
        return;
      }

      await seedProblems(env, [
        const SeedProblem(id: 'p-1', stem: r'求 $\lim_{x\to0}$ 的值。'),
        const SeedProblem(id: 'p-2', stem: '证明该函数连续。'),
      ]);

      final f = File('${outDir.path}/cjk.pdf');
      final r = await exporter()
          .export(paper: _result(), layout: PaperLayout.answers, target: f);
      final bytes = await f.readAsBytes();

      expect(embedsTtf(bytes), isTrue,
          reason: 'PDF 里没有 /FontFile2 —— 说明中文还是渲染成占位空白');
      expect(_indexOf(Uint8List.fromList(bytes), '/Identity-H', 0),
          greaterThanOrEqualTo(0),
          reason: '中文应当走 CID 字体（Identity-H 编码）');
      expect(r.hasCjkFont, isTrue);
    });

    test('嵌入的是**子集**：整份 PDF 比字体文件本身小', () async {
      // 这条是"不随包内置字体"这个决定的关键论据：
      // `pdf` 包只写用到的字形，所以 PDF 不会变成 9 MB。
      // 哪天它改成了整包嵌入，这条会立刻红。
      final cjk = SystemFonts.findCjk();
      if (cjk == null) return;

      await seedProblems(env, [
        const SeedProblem(id: 'p-1', stem: '求极限的值。'),
        const SeedProblem(id: 'p-2', stem: '证明该函数连续。'),
      ]);

      final f = File('${outDir.path}/subset.pdf');
      final r = await exporter()
          .export(paper: _result(), layout: PaperLayout.answers, target: f);

      expect(r.bytes, lessThan(2 * 1024 * 1024),
          reason: '一份两题的小卷嵌完字体不该超过 2 MB');
      expect(r.bytes, lessThan(cjk.lengthSync()),
          reason: '整份 PDF 比源字体文件还大，说明嵌入的不是子集');
    });

    test('拉丁探针仍然按原样可搜（字体编码没把普通文本弄坏）', () async {
      await seedProblems(env, [
        const SeedProblem(id: 'p-1', stem: 'PLAIN-ASCII-STEM'),
        const SeedProblem(id: 'p-2', stem: 'ANOTHER-ASCII-STEM'),
      ]);

      final f = File('${outDir.path}/latin.pdf');
      final r = await exporter()
          .export(paper: _result(), layout: PaperLayout.exam, target: f);

      final text = extractPdfText(await f.readAsBytes());
      expect(text.contains('PLAIN-ASCII-STEM'), isTrue,
          reason: '挂了 fontFallback 之后拉丁字母应当仍走 Helvetica');
      expect(r.bytes, lessThan(2 * 1024 * 1024));
    });

    test('一个中文字体都没有时必须如实提示，并给出出路', () {
      // 直接构造结果来验文案：这台开发机上有黑体，跑不出"没有字体"那条分支，
      // 而"安静地输出一堆空白"正是这个缺陷当初难被发现的原因。
      const noFont = PdfExportResult(
        path: 'x.pdf',
        bytes: 0,
        problems: 0,
        hasChinese: true,
        hasCjkFont: false,
      );
      expect(
          noFont.caveats.any((c) => c.contains('没有找到可用的中文字体')), isTrue);
      expect(noFont.caveats.any((c) => c.contains('语言和区域')), isTrue,
          reason: '要给出具体出路，不能只说"中文可能异常"');

      const withFont = PdfExportResult(
        path: 'x.pdf',
        bytes: 0,
        problems: 0,
        hasChinese: true,
        hasCjkFont: true,
      );
      expect(withFont.caveats, isEmpty, reason: '修好了就不该再提示');
    });

    test('生成三份样张供人眼确认（DSH_PDF_SAMPLE=1 时才跑）', () async {
      // ## 为什么要有这一条
      //
      // 上面几条断言证明的是"/FontFile2 在、子集不大、拉丁没坏" ——
      // 它们**不能**证明"中文看起来是对的"。排版观感只有人眼能判。
      //
      // 所以这里把真实样张写到工作区根目录（不在仓库里、不会被提交），
      // 让用户直接打开看。默认不跑：随手往盘上写文件不是好习惯。
      //
      // ```powershell
      // $env:DSH_PDF_SAMPLE = "1"; flutter test test/paper_export_test.dart
      // ```
      if (Platform.environment['DSH_PDF_SAMPLE'] != '1') return;

      await seedProblems(env, [
        const SeedProblem(
          id: 'p-1',
          stem: r'设函数 $f(x)$ 在闭区间 $[a,b]$ 上连续，在开区间 $(a,b)$ 内可导，'
              r'且 $f(a)=f(b)$。证明：存在 $\xi\in(a,b)$，使 $f^{\prime}(\xi)=0$。',
          answer: r'由罗尔定理即得。',
          solution: r'因为 $f$ 在 $[a,b]$ 上连续、在 $(a,b)$ 内可导，且两端点函数值相等，'
              r'故满足罗尔定理的三个条件，结论成立。',
          primaryKpId: 'math1.calc.diff.rolle',
          primaryKpName: '罗尔定理',
          difficulty: 2,
          wrongCount: 3,
        ),
        const SeedProblem(
          id: 'p-2',
          stem: r'求 $\displaystyle\lim_{x\to0}\frac{\sin x-x\cos x}{x^{3}}$。',
          answer: r'$\dfrac{1}{3}$',
          solution: r'用泰勒展开：$\sin x=x-\dfrac{x^3}{6}+o(x^3)$，'
              r'$\cos x=1-\dfrac{x^2}{2}+o(x^2)$，代入得极限为 $\dfrac13$。',
          primaryKpId: 'math1.calc.limit.taylor',
          primaryKpName: '泰勒展开',
          difficulty: 3,
          wrongCount: 1,
        ),
      ]);

      // 写到**仓库之外**的工作区根目录：`flutter test` 的 cwd 是 `app/`，
      // 所以上两级才是工作区（`…/Project`）。写进仓库的话它会变成
      // 未跟踪文件，早晚有人误提交。
      final out = Directory(
        '${Directory.current.parent.parent.path}'
        '${Platform.pathSeparator}pdf-sample',
      );
      if (!out.existsSync()) out.createSync(recursive: true);

      for (final layout in PaperLayout.values) {
        final f = File('${out.path}${Platform.pathSeparator}${layout.label}.pdf');
        final r = await exporter().export(
          paper: _result(),
          layout: layout,
          target: f,
        );
        // ignore: avoid_print
        print('[pdf-sample] ${f.path}  ${r.sizeText}  '
            '中文字体=${r.hasCjkFont}  提示=${r.caveats.length} 条');
      }
      // ignore: avoid_print
      print('[pdf-sample] 打开看看：中文有没有正常显示、公式清不清楚、'
          '试卷版式有没有留够演算空间');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('PDF 导出', () {
    /// 种两道题：一道带公式与英文答案标记，一道纯文本。
    Future<void> seed() async {
      await seedProblems(env, [
        const SeedProblem(
          id: 'p-1',
          stem: r'求 $\lim_{x\to0}\frac{\sin x}{x}$ 的值。',
          answer: r'$1$',
          solution: r'用等价无穷小：$\sin x \sim x$。',
          difficulty: 1,
        ),
        const SeedProblem(
          id: 'p-2',
          stem: r'设 $f(x)=x^2$，求 $f^{\prime}(x)$。',
          answer: 'ANSWER-MARKER-2X',
          solution: '幂函数求导法则。',
          difficulty: 2,
          wrongCount: 3,
        ),
      ]);
    }

    test('三种版式都能生成出非空 PDF', () async {
      await seed();
      for (final layout in PaperLayout.values) {
        final f = File('${outDir.path}/${layout.name}.pdf');
        final r = await exporter().export(
          paper: _result(),
          layout: layout,
          target: f,
        );
        expect(r.bytes, greaterThan(1000), reason: '${layout.label} 太小，像空文件');
        expect(f.existsSync(), isTrue);
        expect(await f.readAsBytes(), isNotEmpty);
      }
    });

    test('试卷版式**不含**答案 —— 含了就是泄题', () async {
      await seed();
      final exam = File('${outDir.path}/exam.pdf');
      final answers = File('${outDir.path}/answers.pdf');

      await exporter()
          .export(paper: _result(), layout: PaperLayout.exam, target: exam);
      await exporter()
          .export(paper: _result(), layout: PaperLayout.answers, target: answers);

      final examText = extractPdfText(await exam.readAsBytes());
      final ansText = extractPdfText(await answers.readAsBytes());

      expect(ansText.contains('ANSWER-MARKER-2X'), isTrue,
          reason: '解析卷必须含答案');
      expect(examText.contains('ANSWER-MARKER-2X'), isFalse,
          reason: '试卷版式含答案 = 泄题');
    });

    test('解析卷含解析，试卷版式不含', () async {
      await seed();
      // 拉丁探针的理由见文件头的说明（中文走 GID，搜不到字符）
      await seedProblems(env, [
        const SeedProblem(
          id: 'p-3',
          stem: 'stem',
          solution: 'SOLUTION-MARKER',
        ),
      ]);
      final t = _template();
      final r = PaperResult(
        template: t,
        subject: 'math1',
        items: [
          PaperItem(
            seat: t.seats[1],
            problemId: 'p-3',
            stemText: 'stem',
            actualDifficulty: 2,
          ),
        ],
      );

      final exam = File('${outDir.path}/e2.pdf');
      final ans = File('${outDir.path}/a2.pdf');
      await exporter().export(paper: r, layout: PaperLayout.exam, target: exam);
      await exporter()
          .export(paper: r, layout: PaperLayout.answers, target: ans);

      expect(extractPdfText(await ans.readAsBytes()), contains('SOLUTION-MARKER'));
      expect(extractPdfText(await exam.readAsBytes()),
          isNot(contains('SOLUTION-MARKER')));
    });

    test('公式正常时不计降级；非法 LaTeX 计降级且不丢内容', () async {
      await seedProblems(env, [
        const SeedProblem(
          id: 'bad',
          stem: r'这条公式不合法：$\undefinedcommand{x}$',
        ),
      ]);
      final t = _template();
      final r = PaperResult(
        template: t,
        subject: 'math1',
        items: [
          PaperItem(
            seat: t.seats[1],
            problemId: 'bad',
            stemText: 'bad',
            actualDifficulty: 2,
          ),
        ],
      );

      final result = await exporter().export(
        paper: r,
        layout: PaperLayout.exam,
        target: File('${outDir.path}/bad.pdf'),
      );

      expect(result.degradedFormulas, 1, reason: '非法 LaTeX 必须被记账');
      // 降级成源码文本 —— "不丢内容"比"好看"重要
      final text = extractPdfText(await File('${outDir.path}/bad.pdf').readAsBytes());
      expect(text, contains('undefinedcommand'));
    });

    test('中文的提示只在**找不到字体**时出现（T43 之后）', () async {
      // ⚠️ 这条此前断言的是"含中文就一定提示中文可能显示异常" ——
      // 那是 T43 未修时的行为。现在反过来：
      // 找得到中文字体就**不该**再提示（否则用户以为还有问题），
      // 找不到才必须说，并给出出路。两个分支都验。
      await seed();
      final r = await exporter().export(
        paper: _result(),
        layout: PaperLayout.exam,
        target: File('${outDir.path}/cn.pdf'),
      );
      expect(r.hasChinese, isTrue);

      final warned = r.caveats.any((c) => c.contains('中文字体'));
      if (SystemFonts.findCjk() == null) {
        expect(warned, isTrue,
            reason: '没有字体却不说 —— 用户会拿到一份满是空白的 PDF 而不知道为什么');
      } else {
        expect(warned, isFalse, reason: '字体找得到就不该再提示中文有问题');
        expect(r.hasCjkFont, isTrue);
      }
    });

    test('组卷说明会附在末尾（偏离模板的地方要留痕）', () async {
      await seed();
      final base = _result();
      final r = PaperResult(
        template: base.template,
        subject: base.subject,
        items: base.items,
        emptySeats: [base.template.seats.first],
        warnings: const ['第 1 题期望难度 1，实际抽到 3'],
      );
      final out = await exporter().export(
        paper: r,
        layout: PaperLayout.exam,
        target: File('${outDir.path}/warn.pdf'),
      );
      expect(out.problems, 2);
      // 说明文字是中文，搜不到；但导出不应因此崩
      expect(out.bytes, greaterThan(1000));
    });

    test('空卷子也能导出（不崩、给出说明）', () async {
      final r = PaperResult(
        template: _template(),
        subject: 'math1',
        items: const [],
      );
      final out = await exporter().export(
        paper: r,
        layout: PaperLayout.exam,
        target: File('${outDir.path}/empty.pdf'),
      );
      expect(out.problems, 0);
      expect(out.bytes, greaterThan(500));
    });

    test('题目在库里读不到时用摘要兜底，不让这道题凭空消失', () async {
      final t = _template();
      final r = PaperResult(
        template: t,
        subject: 'math1',
        items: [
          PaperItem(
            seat: t.seats[1],
            problemId: 'does-not-exist',
            stemText: 'FALLBACK-STEM',
            actualDifficulty: 2,
          ),
        ],
      );
      final out = await exporter().export(
        paper: r,
        layout: PaperLayout.exam,
        target: File('${outDir.path}/missing.pdf'),
      );
      expect(out.problems, 1);
      final text = extractPdfText(await File('${outDir.path}/missing.pdf').readAsBytes());
      expect(text, contains('FALLBACK-STEM'));
    });

    test('错题本版式按考点分组，错得多的排前面', () async {
      final t = _template();
      final r = PaperResult(
        template: t,
        subject: 'math1',
        items: [
          PaperItem(
            seat: t.seats[0],
            problemId: 'a',
            stemText: 'KP-ONE-STEM',
            primaryKpName: '考点一',
            actualDifficulty: 1,
            wrongCount: 1,
          ),
          PaperItem(
            seat: t.seats[1],
            problemId: 'b',
            stemText: 'KP-TWO-STEM',
            primaryKpName: '考点二',
            actualDifficulty: 2,
            wrongCount: 9,
          ),
        ],
      );
      final f = File('${outDir.path}/wb.pdf');
      await exporter()
          .export(paper: r, layout: PaperLayout.wrongBook, target: f);

      final text = extractPdfText(await f.readAsBytes());
      // 两个考点都在
      expect(text, contains('KP-ONE-STEM'));
      expect(text, contains('KP-TWO-STEM'));
      // 错得多的（考点二）应排在前面
      expect(text.indexOf('KP-TWO-STEM'), lessThan(text.indexOf('KP-ONE-STEM')),
          reason: '错题本该把错得多的考点排在前面');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('公式光栅化', () {
    test('合法公式能出图，且尺寸合理', () async {
      final r = FormulaRasterizer(pixelRatio: 2);
      final img = await r.rasterize(r'\frac{1}{2}', fontSize: 14);
      expect(img, isNotNull);
      expect(img!.png.length, greaterThan(50));
      expect(img.width, greaterThan(0));
      expect(img.height, greaterThan(0));
    });

    test('同一公式第二次走缓存', () async {
      final r = FormulaRasterizer();
      await r.rasterize(r'x^2');
      expect(r.cacheSize, 1);
      await r.rasterize(r'x^2');
      expect(r.cacheSize, 1, reason: '同一个公式不该渲两遍');
    });

    test('不同字号算不同的缓存项', () async {
      final r = FormulaRasterizer();
      await r.rasterize(r'x^2', fontSize: 14);
      await r.rasterize(r'x^2', fontSize: 20);
      expect(r.cacheSize, 2);
    });

    test('非法 LaTeX 返回 null，不抛异常', () async {
      final r = FormulaRasterizer();
      expect(await r.rasterize(r'\undefinedcommand{x}'), isNull);
      expect(await r.rasterize(r'\text{缺收尾花括号'), isNull);
    });

    test('含中文的公式也能出图（不依赖字体回退，走的是光栅化）', () async {
      final r = FormulaRasterizer();
      final img = await r.rasterize(r'\text{为偶函数}');
      expect(img, isNotNull);
      expect(img!.png.length, greaterThan(50));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('Markdown 切分（PDF 与屏幕必须用同一套规则）', () {
    test('行内与独立公式分别识别', () {
      final p = splitMarkdownPieces(r'前 $a$ 中 $$b$$ 后');
      expect(p.whereType<FormulaPiece>().length, 1 + 1);
      final formulas = p.whereType<FormulaPiece>().toList();
      expect(formulas[0].display, isFalse);
      expect(formulas[1].display, isTrue);
      expect(formulas[0].tex, 'a');
      expect(formulas[1].tex, 'b');
    });

    test('没有收尾美元符时不吞内容', () {
      final p = splitMarkdownPieces(r'孤立的 $ 符号');
      expect(p.whereType<FormulaPiece>(), isEmpty);
      expect(p.whereType<TextPiece>().single.text, contains('符号'));
    });

    test('纯文本原样返回', () {
      final p = splitMarkdownPieces('就是一句话');
      expect(p.length, 1);
      expect(p.single, isA<TextPiece>());
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('组卷数据层', () {
    test('候选池带上用户的错题次数与考点掌握度', () async {
      await seedProblems(env, [
        const SeedProblem(
          id: 'p-1',
          stem: '题一',
          primaryKpId: 'kp-a',
          primaryKpName: '考点A',
          wrongCount: 4,
        ),
        const SeedProblem(
          id: 'p-2',
          stem: '题二',
          primaryKpId: 'kp-a',
          primaryKpName: '考点A',
          wrongCount: 0,
        ),
      ]);

      final repo = PaperRepository(db: env.db, templatesJson: '{}');
      final pool = await repo.candidates(subject: 'math1');

      expect(pool.length, 2);
      final one = pool.firstWhere((c) => c.problemId == 'p-1');
      expect(one.wrongCount, 4);
      // 主考点 id 来自 problem_knowledge —— 不依赖本体是否载入。
      // 这一条盯的是一个真 bug：早先从索引的 primary_kp_name 取考点，
      // 本体没载入时它是 null，于是所有题落进同一个聚合桶，
      // 掌握度聚合静默失效。
      expect(one.primaryKpId, 'kp-a');
      expect(one.kpMastery, isNotNull);
      // 展示名：索引里没有冗余名时回退成 id，而不是 null
      expect(one.primaryKpName, 'kp-a');
    });

    test('onlyWrong 只保留做错过的题', () async {
      await seedProblems(env, [
        const SeedProblem(id: 'p-1', stem: '一', wrongCount: 3),
        const SeedProblem(id: 'p-2', stem: '二', wrongCount: 0),
      ]);
      final repo = PaperRepository(db: env.db, templatesJson: '{}');
      final pool = await repo.candidates(subject: 'math1', onlyWrong: true);
      expect(pool.map((c) => c.problemId).toList(), ['p-1']);
    });

    test('科目过滤生效', () async {
      await seedProblems(env, [const SeedProblem(id: 'p-1', stem: '一')]);
      final repo = PaperRepository(db: env.db, templatesJson: '{}');
      expect(await repo.candidates(subject: 'math2'), isEmpty);
      expect(await repo.candidates(subject: 'math1'), isNotEmpty);
    });

    test('模板从注入的 JSON 载入（不依赖 asset bundle）', () async {
      const json = '''
      {"templates":{"math1":{"real_exam":{
        "id":"math1.real_exam","name":"真题结构全卷","total_score":150,
        "duration_minutes":180,
        "sections":[{"qtype":"choice","name":"选择题","count":2,
                     "score_per_item":5,"difficulty":[1,2]}]}}}}''';
      final repo = PaperRepository(db: env.db, templatesJson: json);
      final t = await repo.templates(subject: 'math1');
      expect(t.error, isNull);
      expect(t.kinds, contains('real_exam'));
      expect(t['real_exam']!.seats.length, 2);
      expect(t['real_exam']!.totalScore, 150);
    });

    test('模板 JSON 坏掉时返回空表，并且**带上错误原因**', () async {
      // 只返回空表是不够的：界面会把"数据坏了"显示成
      // "这个科目还没有可用模板" —— 用户会一直等一个不会出现的模板，
      // 而真相是随包数据坏了。所以错误原因必须传出去。
      final repo = PaperRepository(db: env.db, templatesJson: '这不是 JSON');
      final bad = await repo.templates(subject: 'math1');
      expect(bad.isEmpty, isTrue);
      expect(bad.isOk, isFalse);
      expect(bad.error, isNotNull);
      expect((await repo.labels()).difficulty, isEmpty);
    });

    test('组卷结果落库后能读回来，且参数快照完整', () async {
      await seedProblems(env, [
        const SeedProblem(id: 'p-1', stem: '一'),
        const SeedProblem(id: 'p-2', stem: '二'),
      ]);
      final repo = PaperRepository(db: env.db, templatesJson: '{}');
      final result = _result();

      final id = await repo.save(result, title: '我的卷子');
      expect(id, startsWith('paper-'));

      final rows = await repo.history();
      expect(rows.length, 1);
      final row = rows.single;
      expect(row.title, '我的卷子');
      expect(row.subject, 'math1');
      expect(row.totalScore, 15);
      // 快照里要能看出"这份卷子是按什么组的、偏离模板在哪"
      expect(row.config, contains('test.small'));
      expect(row.config, contains('hasEstimatedScores'));
      expect(row.items, contains('p-1'));
      expect(row.items, contains('"score":5'));
    });

    test('history 按时间倒序', () async {
      final repo = PaperRepository(db: env.db, templatesJson: '{}');
      await repo.save(_result(), title: '早', now: DateTime(2024, 1, 1));
      await repo.save(_result(), title: '晚', now: DateTime(2024, 6, 1));

      final rows = await repo.history();
      expect(rows.map((r) => r.title).toList(), ['晚', '早']);
    });

    test('删除卷子', () async {
      final repo = PaperRepository(db: env.db, templatesJson: '{}');
      final id = await repo.save(_result());
      expect((await repo.history()).length, 1);
      await repo.delete(id);
      expect(await repo.history(), isEmpty);
    });

    test('默认标题带模板名与日期，不含内部 id', () async {
      final repo = PaperRepository(db: env.db, templatesJson: '{}');
      await repo.save(_result(), now: DateTime(2024, 6, 1, 14, 5));
      final row = (await repo.history()).single;
      expect(row.title, contains('Test Paper'));
      expect(row.title, contains('6月1日'));
      expect(row.title, contains('14:05'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('端到端：从题库组一份卷再导出', () {
    test('错题专练：任意题型模板能真的填上题位', () async {
      await seedProblems(env, [
        const SeedProblem(id: 'c1', stem: '选择题干', wrongCount: 2),
        const SeedProblem(id: 's1', stem: '解答题干', wrongCount: 1),
      ]);
      // 把题型改成 choice/solve（种数据默认都是 solve）
      await (env.db.update(env.db.problemsIndex)
            ..where((t) => t.id.equals('c1')))
          .write(const ProblemsIndexCompanion(qtype: Value('choice')));

      final repo = PaperRepository(db: env.db, templatesJson: '{}');
      final pool = await repo.candidates(subject: 'math1');

      // 错题专练的题位是"不限题型"的，所以两种题型都该被抽到
      const t = PaperTemplate(
        id: 'wrong',
        name: '错题专练',
        description: '',
        seats: [
          PaperSeat(no: 1, sectionName: '错题', qtype: PaperSeat.anyQtype),
          PaperSeat(no: 2, sectionName: '错题', qtype: PaperSeat.anyQtype),
        ],
      );
      final result = const PaperComposer().compose(
        request: const PaperRequest(template: t, subject: 'math1'),
        pool: pool,
      );

      expect(result.isComplete, isTrue,
          reason: '不限题型的题位应当能吃下任何题型的题');
      expect(result.items.length, 2);
      // 分值由题位决定（null → 估算），不该因此产生难度警告
      expect(result.warnings.where((w) => w.contains('期望难度')), isEmpty);
    });
  });
}
