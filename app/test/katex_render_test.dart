/// 中文摘分器 + katex 渲染器测试。
///
/// ## 这个文件为什么重要
///
/// `\text{中文}` 在 KaTeX 字体里没有字形（实测：691 / 1523 条真实知识点公式
/// 至少有一个无字形字符）。切分器就是绕开这件事的唯一手段，而它有两种
/// 失败方式，都很隐蔽：
///
/// - **该切的没切** → 中文显示成方框（不会报错，测试若只断言"有 widget"就漏了）
/// - **不该切的切了** → 破坏公式结构（`\left..\right` 失去配对、环境被切断），
///   katex 直接解析失败 → 整条公式降级成源码
///
/// 所以下面把两侧都钉住：能切的那三类要切，不能切的那五类一个都不许动。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/math/katex_renderer.dart';
import 'package:kaoyan_math_agent/core/math/latex_text_split.dart';
import 'package:kaoyan_math_agent/core/math/math_renderer.dart';

/// 取出切分结果里的纯文本片段。
List<String> texts(String tex) =>
    splitLatexText(tex).whereType<TextChunk>().map((c) => c.text).toList();

/// 取出切分结果里的 LaTeX 片段。
List<String> latexs(String tex) =>
    splitLatexText(tex).whereType<LatexChunk>().map((c) => c.tex).toList();

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  group('中文摘分：该切的要切', () {
    test('整条公式就是一段中文', () {
      expect(texts(r'\text{为偶函数}'), ['为偶函数']);
      // 外壳去掉后不该留下空 LaTeX 片段（否则会多出零宽占位）
      expect(latexs(r'\text{为偶函数}'), isEmpty);
    });

    test('中文夹在公式中间', () {
      const tex = r'f\ \text{在}\ x_0\ \text{连续}';
      expect(texts(tex), ['在', '连续']);
      // 首尾都还有公式（`f\ ` 与 `\ x_0\ `、末尾为空不产出）
      expect(splitLatexText(tex).first, isA<LatexChunk>());
      expect(latexs(tex), [r'f\ ', r'\ x_0\ ']);
    });

    test('全角标点也算需要摘的内容', () {
      // 全角括号同样不在 KaTeX 字体里
      expect(texts(r'\text{（甲）}'), ['（甲）']);
      expect(texts(r'x\ \text{、}\ y'), ['、']);
    });

    test('中文里的嵌套花括号不会截断', () {
      // \text{集合 \{x\}} —— 转义花括号不参与配对
      expect(texts(r'\text{集合 \{x\}}'), [r'集合 \{x\}']);
    });

    test('同一段里多个中文会合并成一段', () {
      expect(texts(r'\text{甲}\text{乙}'), ['甲乙']);
      // 合并后只剩一个文本片段，不该是两段
      expect(splitLatexText(r'\text{甲}\text{乙}').length, 1);
    });

    test('没有中文的公式原样返回，不做任何改写', () {
      const plain = r'\lim_{x\to0}\frac{\sin x}{x}';
      final chunks = splitLatexText(plain);
      expect(chunks.length, 1);
      expect((chunks.single as LatexChunk).tex, plain);
      expect(canSplit(plain), isFalse);
    });

    test('canSplit 只对含中文的公式为真', () {
      expect(canSplit(r'\text{为偶函数}'), isTrue);
      expect(canSplit(r'a+b'), isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('中文摘分：不该切的一个都不许动', () {
    test(r'\left..\right 之间不切（伸缩括号会失去配对）', () {
      const tex = r'\left(\frac{0}{0}\ \text{或}\ \frac{\infty}{\infty}\right)';
      final chunks = splitLatexText(tex);
      expect(chunks.length, 1, reason: '整条必须原样交给 katex');
      expect((chunks.single as LatexChunk).tex, tex);
    });

    test(r'环境内部不切（会把 cases 切断）', () {
      const tex =
          r'\begin{cases}2\int_0^af(x)\,dx,&f\ \text{为偶函数}\\0,&f\ \text{为奇函数}\end{cases}';
      final chunks = splitLatexText(tex);
      expect(chunks.length, 1);
      expect(chunks.single, isA<LatexChunk>());
    });

    test(r'作为命令参数时不切（\xrightarrow 的参数）', () {
      const tex = r'|A|\xrightarrow{\text{初等行变换}}\prod_{i=1}^{n}a_{ii}';
      expect(splitLatexText(tex).length, 1);
    });

    test('作为下标时不切', () {
      const tex = r'S_{\text{侧}}=2\pi\int_a^b|f(x)|\,dx';
      expect(splitLatexText(tex).length, 1);
    });

    test('作为上标时不切', () {
      const tex = r'x^{\text{中}}';
      expect(splitLatexText(tex).length, 1);
    });

    test('花括号不配平时不妄自猜测（交给 katex 报错）', () {
      // 真实数据里出现过这种录入错误（已在 data/ 里修掉）
      const bad = r'\text{少了收尾花括号';
      expect(splitLatexText(bad).length, 1);
    });

    test(r'环境结束后可以切（\end 之后回到顶层）', () {
      const tex = r'\begin{pmatrix}a&b\\c&d\end{pmatrix}\ \text{记为}\ A';
      final chunks = splitLatexText(tex);
      expect(texts(tex), ['记为']);
      expect(chunks.length, 3, reason: '公式 / 文本 / 公式');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('KatexRenderer 基本契约', () {
    const r = KatexRenderer();

    test('name 反映是否开启摘分', () {
      expect(const KatexRenderer(splitCjk: true).name, contains('cjk-split'));
      expect(const KatexRenderer(splitCjk: false).name, 'katex');
    });

    test('supports 对任何输入都为真（失败时内部降级）', () {
      expect(r.supports(r'\frac{1}{2}'), isTrue);
      expect(r.supports('这不是 LaTeX'), isTrue);
    });

    testWidgets('渲染纯公式不抛异常', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: r.render(r'\frac{1}{2}')),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('渲染独立公式不抛异常', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: r.render(r'\int_0^1 x\,dx',
              style: MathStyle.display, options: const MathRenderOptions(fontSize: 20)),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('含中文的公式不抛异常（走摘分路径）', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: r.render(r'\text{为偶函数}')),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // 摘分后中文是以普通文本出现的 —— 这条断言同时证明走的是摘分路径
      expect(find.textContaining('为偶函数'), findsOneWidget);
    });

    testWidgets('摘不掉的公式不抛异常（原样交给 katex）', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: r.render(r'\left(\frac{0}{0}\ \text{或}\ \frac{\infty}{\infty}\right)'),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('非法 LaTeX 降级而不崩', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: r.render(r'\undefinedcommand{x}')),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('KatexRenderer.renderMarkdown', () {
    const r = KatexRenderer();

    testWidgets('识别行内公式，中英文混排能渲染出来', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: r.renderMarkdown(r'求 $\lim_{x\to0}\frac{\sin x}{x}$ 的值。'),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('求'), findsOneWidget);
      expect(find.textContaining('的值。'), findsOneWidget);
    });

    testWidgets('识别独立公式', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: r.renderMarkdown(r'有公式：$$\int_0^1 x\,dx = \frac12$$')),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('没有收尾美元符时不吞内容', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: r.renderMarkdown(r'这里有个孤立的 $ 符号')),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('孤立的'), findsOneWidget);
      expect(find.textContaining('符号'), findsOneWidget);
    });

    testWidgets('纯文本也能渲染', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: r.renderMarkdown('就是一句话，没有公式。')),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('就是一句话'), findsOneWidget);
    });

    testWidgets('selectable 包一层可选区', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: r.renderMarkdown('可选文本', options: const MathRenderOptions(selectable: true)),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(SelectionArea), findsOneWidget);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('与缓存层组合', () {
    testWidgets('CachedMathRenderer(KatexRenderer()) 能正常渲染', (tester) async {
      final cached = CachedMathRenderer(const KatexRenderer());
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: cached.renderMarkdown(r'极限 $\lim_{x\to0}x$ 与中文')),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(cached.name, contains('cached'));
    });
  });
}
