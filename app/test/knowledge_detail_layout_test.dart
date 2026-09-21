/// 知识点详情卡：**公式不许被静默裁掉** + 排版可读性。
///
/// ## 为什么要有这一条
///
/// 用户反馈"知识库有些公式显示不完整，比如极限等公式"。查下来：本体的公式
/// 平均 64 字符、最长 227 字符，而早先的写法是把公式塞进一个 `Wrap` 里的
/// 固定框 —— 比框宽的部分被 `SingleChildScrollView` **裁掉，而且界面上
/// 没有任何提示**。用户看到的是一条断掉的公式。
///
/// 现在的规则是三分支：放得下就原样、只超一点就轻微缩小、超太多就横向
/// 拖动**并显示提示**。这一组测试守的就是"任何一条公式都不会在无提示的
/// 情况下被裁"。
///
/// ## 2026-09-21：公式字号 14 → 16 后，这条断言换了写法
///
/// 原来它断言「700px 下**没有一行**需要横滑」，依据是"单条最宽 691px
/// （14px 下），700px 的卡缩到 92% 就放得下"。
///
/// 字号提到 16 之后，同一条公式变成约 790px，而卡片里的公式行实际可用宽
/// 只有约 609px（要减掉卡片内边距 28、序号列 20、复制按钮 19）——
/// 需要缩到 0.77，低于 `kFormulaMinScale`(0.85)，于是转成横滑。
///
/// **这是放大的物理必然**：容器宽度不变、字大了 14%，能"原样放下"的公式
/// 必然变少。但**横滑并不是缺陷** —— 它是三分支里"明确告知用户可拖动"
/// 的那一档。真正要守的从来不是"零横滑"，而是：
///
/// 1. **绝不静默裁切**：需要横滑的每一条都必须带提示（下面第二条用例）
/// 2. **横滑占比不失控**：否则"公式太大"会把详情卡变成一片滚动区
///
/// 所以这里改成断言这两件事，而不是"零横滑"。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/math/katex_renderer.dart';
import 'package:kaoyan_math_agent/core/math/latex_text_split.dart';
import 'package:kaoyan_math_agent/core/math/math_renderer.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/features/knowledge/knowledge_formula_row.dart';
import 'package:kaoyan_math_agent/features/knowledge/knowledge_leaf_detail.dart';

KnowledgeBase? loadKb() {
  final f = File('../data/knowledge_points/math1.json');
  if (!f.existsSync()) return null;
  return KnowledgeBase.fromJson(
    (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>(),
  );
}

/// 把一张详情卡塞进指定宽度的卡片里渲染。
Future<void> pumpCard(
  WidgetTester tester, {
  required KnowledgePoint leaf,
  required double width,
  String? section,
  String? chapter,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width - 24,
            child: SingleChildScrollView(
              child: KnowledgeLeafDetail(
                leaf: leaf,
                sectionName: section,
                chapterName: chapter,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 卡片里所有**需要横向拖动**的公式块（返回它们的 tex）。
List<String> scrolledFormulaTex(WidgetTester tester) {
  final out = <String>[];
  for (final el in find.byType(SingleChildScrollView).evaluate()) {
    final scv = el.widget as SingleChildScrollView;
    if (scv.scrollDirection != Axis.horizontal) continue;
    final key = scv.key;
    final state = tester.state<ScrollableState>(
      find.descendant(
        of: find.byWidget(scv),
        matching: find.byType(Scrollable),
      ),
    );
    if (state.position.maxScrollExtent > 0.5) {
      // key 形如 formula-scroll-<tex>
      out.add(key is ValueKey<String>
          ? (key.value).replaceFirst('formula-scroll-', '')
          : '<无 key>');
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KnowledgeBase kb;
  final data = loadKb();
  final hasData = data != null;

  setUp(() {
    if (hasData) kb = data;
    MathRendering.install(const KatexRenderer());
  });
  tearDown(MathRendering.reset);

  group('公式不被静默裁掉', () {
    testWidgets('整册语料 @700px：横滑占比极小，且绝无"无提示的裁切"',
        (tester) async {
      if (!hasData) {
        markTestSkipped('数据文件不存在');
        return;
      }
      // 分母只算「核心公式」的片段数。别名公式（也是公式行）没有计入，
      // 所以算出来的占比是**偏保守的上界** —— 宁可严一点。
      var rows = 0;
      var scrolled = 0;
      final missingHint = <String>[];
      final worst = <(int, String)>[];

      for (final leaf in kb.leaves) {
        await pumpCard(tester, leaf: leaf, width: 700);
        rows += [
          for (final f in leaf.formulas) ...splitTopLevelQuad(f),
        ].length;

        final s = scrolledFormulaTex(tester);
        scrolled += s.length;
        if (s.isNotEmpty) worst.add((s.length, leaf.name));

        for (final tex in s) {
          // 提示的 key 由 FittedFormula 的横滑分支挂出
          if (find.byKey(ValueKey('formula-scroll-hint-$tex')).evaluate().isEmpty) {
            missingHint.add('${leaf.name} / $tex');
          }
        }
      }

      expect(rows, greaterThan(500),
          reason: '语料样本只有 $rows 条公式，这条用例失去意义（数据变了吗）');

      // ① 核心不变量：需要横滑的公式**必须**带提示 —— 一条都不能漏。
      //    这是"公式被静默裁掉"这个老问题的真正防线。
      expect(missingHint, isEmpty,
          reason: '这些公式既溢出又没有提示（用户看到的就是"断掉的公式"）：'
              '${missingHint.take(5).join(' | ')}');

      // ② 横滑占比不失控：13px→16px 之后超宽公式会变多，但不能多到
      //    把详情卡变成一片滚动区。
      final ratio = scrolled / rows;
      worst.sort((a, b) => b.$1.compareTo(a.$1));
      expect(ratio, lessThan(0.02),
          reason: '${(ratio * 100).toStringAsFixed(2)}%（$scrolled/$rows）'
              '的公式在 700px 下需要横滑 —— 太多了。'
              '最严重的是「${worst.isEmpty ? '—' : worst.first.$2}」');
    });

    testWidgets('窄卡 @420px：需要横滑的公式**必须**带上"可拖动"提示',
        (tester) async {
      if (!hasData) {
        markTestSkipped('数据文件不存在');
        return;
      }
      // 挑公式最长的几个知识点（按拆分后的片段宽度排）
      final ranked = <(double, KnowledgePoint)>[];
      for (final leaf in kb.leaves) {
        var maxW = 0.0;
        for (final f in leaf.formulas) {
          for (final p in splitTopLevelQuad(f)) {
            final w = formulaWidth(p, kFormulaFontSize) ?? 0;
            if (w > maxW) maxW = w;
          }
        }
        ranked.add((maxW, leaf));
      }
      ranked.sort((a, b) => b.$1.compareTo(a.$1));
      final sample = ranked.take(14).map((e) => e.$2).toList();

      var checkedScrollable = 0;
      for (final leaf in sample) {
        await pumpCard(tester, leaf: leaf, width: 420);
        final scrolled = scrolledFormulaTex(tester);
        for (final tex in scrolled) {
          checkedScrollable++;
          expect(
            find.byKey(ValueKey('formula-scroll-hint-$tex')),
            findsOneWidget,
            reason: '「${leaf.name}」有一条公式被裁掉了却没有提示：$tex',
          );
        }
      }
      // 这条用例本身也要有"确实遇到了超宽公式"的样本，否则等于没测
      expect(checkedScrollable, greaterThan(0),
          reason: '420px 下一条超宽公式都没遇到？样本选错了');
    });

    testWidgets('超宽公式的提示文案可读、且带图标', (tester) async {
      if (!hasData) {
        markTestSkipped('数据文件不存在');
        return;
      }
      // 取**拆分后**仍然最宽的那一片（二维正态分布那条 216 字符、没有
      // 顶层 \quad 可拆）—— 它才是真正需要横滑的情况。
      var best = <String>[];
      var bestW = 0.0;
      for (final leaf in kb.leaves) {
        for (final f in leaf.formulas) {
          for (final p in splitTopLevelQuad(f)) {
            final w = formulaWidth(p, kFormulaFontSize) ?? 0;
            if (w > bestW) {
              bestW = w;
              best = [leaf.id, p];
            }
          }
        }
      }
      expect(bestW, greaterThan(500),
          reason: '最宽的片段才 $bestW px —— 语料变了？');

      await pumpCard(tester, leaf: kb.byId[best[0]]!, width: 420);
      expect(find.textContaining('按住左右拖动'), findsWidgets);
      expect(find.byIcon(Icons.swipe), findsWidgets);
    });

    testWidgets('两种极端宽度都不溢出（无 RenderFlex overflow 异常）',
        (tester) async {
      if (!hasData) {
        markTestSkipped('数据文件不存在');
        return;
      }
      final leaf = kb.leaves.firstWhere((l) => l.formulas.length >= 5);
      for (final w in [1200.0, 380.0]) {
        await pumpCard(tester, leaf: leaf, width: w);
        expect(tester.takeException(), isNull, reason: '$w px 下报错了');
      }
    });
  });

  group('排版可读性', () {
    testWidgets('每节都有标题，公式与陷阱都编号', (tester) async {
      if (!hasData) {
        markTestSkipped('数据文件不存在');
        return;
      }
      final leaf = kb.leaves.firstWhere((l) => l.formulas.length >= 3);
      await pumpCard(tester, leaf: leaf, width: 900);

      // 小节标题
      expect(find.text('定义'), findsOneWidget);
      expect(find.text('核心公式'), findsOneWidget);
      expect(find.text('考频与题型'), findsOneWidget);
      if (leaf.commonTraps.isNotEmpty) {
        expect(find.text('常见陷阱'), findsOneWidget);
      }
      if (leaf.aliases.isNotEmpty) {
        expect(find.text('召回别名'), findsOneWidget);
      }

      // 公式条数与小节标题上的计数一致（拆分后可能多于 leaf.formulas）
      final pieces = [
        for (final f in leaf.formulas) ...splitTopLevelQuad(f),
      ];
      expect(find.text('${pieces.length} 条'), findsWidgets);
      // 序号 1..N 都在
      for (var i = 1; i <= math.min(pieces.length, 9); i++) {
        expect(find.text('$i'), findsWidgets, reason: '缺公式序号 $i');
      }
    });

    testWidgets('面包屑显示"学科分段 › 章节"', (tester) async {
      if (!hasData) {
        markTestSkipped('数据文件不存在');
        return;
      }
      final leaf = kb.byId['math1.calc.limit.func']!;
      final crumb = detailBreadcrumb(kb, leaf.id);
      expect(crumb.section, '高等数学');
      expect(crumb.chapter, '极限与连续');

      await pumpCard(
        tester,
        leaf: leaf,
        width: 900,
        section: crumb.section,
        chapter: crumb.chapter,
      );
      expect(find.text('高等数学 › 极限与连续'), findsOneWidget);
    });

    testWidgets('每条公式都有复制源码的入口', (tester) async {
      if (!hasData) {
        markTestSkipped('数据文件不存在');
        return;
      }
      final leaf = kb.byId['math1.calc.limit.two_important']!;
      await pumpCard(tester, leaf: leaf, width: 900);

      final pieces = [
        for (final f in leaf.formulas) ...splitTopLevelQuad(f),
      ];
      // 逐行按 key 定位：别名里的 LaTeX 现在也会渲染成公式行（也带复制按钮），
      // 所以只数"核心公式"这几行的 key，不用图标总数
      for (var i = 0; i < pieces.length; i++) {
        expect(find.byKey(ValueKey('formula-${leaf.id}-$i')), findsOneWidget,
            reason: '第 ${i + 1} 条核心公式缺行');
      }
      expect(find.byIcon(Icons.copy_all_outlined),
          findsAtLeastNWidgets(pieces.length));
    });

    testWidgets('LaTeX 别名渲染成公式，不再给用户看源码', (tester) async {
      if (!hasData) {
        markTestSkipped('数据文件不存在');
        return;
      }
      // 数列极限的别名里有 \lim_{n\to\infty}a_n 这类符号写法
      final leaf = kb.byId['math1.calc.limit.seq']!;
      final latexAliases = [
        for (final a in leaf.aliases)
          if (a.contains(r'\') || a.contains('_') || a.contains('^')) a,
      ];
      expect(latexAliases, isNotEmpty, reason: '这个知识点应当有符号别名');

      await pumpCard(tester, leaf: leaf, width: 900);
      for (final a in latexAliases) {
        expect(
          find.byKey(ValueKey('alias-formula-${leaf.id}-$a')),
          findsOneWidget,
          reason: '符号别名没有按公式渲染：$a',
        );
      }
      // 纯文字别名仍然走 chip（不出现 alias-formula- 前缀的行）
      for (final a in leaf.aliases.where((a) => !latexAliases.contains(a))) {
        expect(find.byKey(ValueKey('alias-formula-${leaf.id}-$a')), findsNothing);
      }
    });
  });
}
