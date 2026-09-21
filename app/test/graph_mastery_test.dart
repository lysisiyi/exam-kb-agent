/// A2：图谱的**状态层**（掌握度着色）不变量。
///
/// ## 这个文件守的是什么
///
/// 图谱在此之前只表达**结构**（这是什么：科目 / 章节 / 知识点），
/// 不表达**状态**（我对它掌握得怎么样）。加上状态层之后，
/// 两件事必须能分开验证：
///
/// 1. **`null` 不等于 `0`** —— "还没复习过"绝不能被染成"完全不会"的颜色。
///    这是本项目反复立过的一条纪律（画像页的"空槽表示空缺"、
///    "没有复习数据的条不画 0% 进度条"），这里照搬。
/// 2. 状态色只改**底色与描边**，文字色一个字节都不动 ——
///    否则"最该读的东西给最深的字"会被悄悄破坏，而且是**静默**破坏
///    （测试挂了才发现，但那已经晚了）。
/// 3. 新底色仍然过 WCAG AA —— 用 `knowledge_palette_test` 同一把尺子。
/// 4. 分档只作用于**叶子**：章节与分段没有掌握度这个概念。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/features/knowledge/knowledge_graph_layout.dart'
    show GraphNodeKind;
import 'package:kaoyan_math_agent/features/knowledge/knowledge_graph_view.dart';
import 'package:kaoyan_math_agent/features/knowledge/knowledge_node_style.dart';
import 'package:kaoyan_math_agent/services/profile/mastery_service.dart';

import 'support/contrast.dart';
import 'support/knowledge_fixture.dart';

/// 一个带掌握度的考点。
KpMastery _m(
  String id, {
  double? mastery,
  int problems = 3,
  int reviewed = 2,
  int wrong = 1,
}) =>
    KpMastery(
      kpId: id,
      kpName: id,
      problemCount: problems,
      reviewedCount: reviewed,
      wrongCount: wrong,
      mastery: mastery,
    );

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 1200, height: 800, child: child),
      ),
    );

/// 取某个节点卡片上第一个有底色的 `Container` 的颜色。
///
/// 图谱节点是"Container + BoxDecoration"，底色就是掌握度状态的落点。
Color? _fillOf(WidgetTester tester, String nodeId) {
  final containers = tester.widgetList<Container>(find.descendant(
    of: find.byKey(ValueKey('graph-node-$nodeId')),
    matching: find.byType(Container),
  ));
  for (final c in containers) {
    final d = c.decoration;
    if (d is BoxDecoration && d.color != null) return d.color;
  }
  return null;
}

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  group('分档（阈值是视觉刻度，不是诊断线）', () {
    test('三段边界', () {
      expect(masteryBandOf(0.0), MasteryBand.weak);
      expect(masteryBandOf(0.39), MasteryBand.weak);
      expect(masteryBandOf(0.40), MasteryBand.shaky);
      expect(masteryBandOf(0.69), MasteryBand.shaky);
      expect(masteryBandOf(0.70), MasteryBand.solid);
      expect(masteryBandOf(1.0), MasteryBand.solid);
    });

    test('null 是"未知"，不是"0"', () {
      expect(masteryBandOf(null), MasteryBand.unknown,
          reason: '把"还没复习"画成"完全不会"，是本项目最忌讳的那类错误');
      expect(masteryBandOf(0.0), isNot(MasteryBand.unknown));
    });

    test('越界值被夹住，不会掉出三档之外', () {
      expect(masteryBandOf(-1), MasteryBand.weak);
      expect(masteryBandOf(2.5), MasteryBand.solid);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('状态配色', () {
    test('未知时与结构配色**完全一致**（一个字段都不许变）', () {
      const leaf = GraphNodeKind.leaf;
      final base = nodeThemeOf(leaf);
      final unknown = masteryThemeOf(leaf, null);

      expect(unknown.fill, base.fill);
      expect(unknown.border, base.border);
      expect(unknown.onFillInk, base.onFillInk);
      expect(unknown.textInk, base.textInk);
      expect(unknown.accent, base.accent);
    });

    test('有数据时只换底色与描边，文字色一律不动', () {
      const leaf = GraphNodeKind.leaf;
      final base = nodeThemeOf(leaf);

      for (final m in [0.1, 0.5, 0.9]) {
        final themed = masteryThemeOf(leaf, m);

        expect(themed.onFillInk, base.onFillInk,
            reason: '掌握 $m 时改动了节点文字色 —— '
                '"最该读的东西给最深的字"就是靠这一条守住的');
        expect(themed.textInk, base.textInk,
            reason: '大纲行文字色不该被掌握度影响');

        // 但底色必须真的换了，否则这个维度等于没做
        expect(themed.fill, isNot(base.fill), reason: '掌握 $m 时底色没变');
      }
    });

    test('三档底色互不相同（否则等于只做了两档）', () {
      final fills = [
        for (final m in [0.1, 0.5, 0.9]) masteryThemeOf(GraphNodeKind.leaf, m).fill,
      ];
      expect(fills.toSet(), hasLength(3));
    });

    test('章节 / 分段 / 科目不受掌握度影响（它们没有这个概念）', () {
      for (final k in [
        GraphNodeKind.root,
        GraphNodeKind.section,
        GraphNodeKind.chapter,
        GraphNodeKind.unit,
      ]) {
        final base = nodeThemeOf(k);
        final themed = masteryThemeOf(k, 0.1);
        expect(themed.fill, base.fill, reason: '$k 不该被掌握度染色');
        expect(themed.onFillInk, base.onFillInk);
      }
    });

    test('三档底色上的文字对比度仍然过 WCAG AA', () {
      const leaf = GraphNodeKind.leaf;
      final ink = nodeThemeOf(leaf).onFillInk;

      for (final m in [0.1, 0.5, 0.9]) {
        final fill = masteryThemeOf(leaf, m).fill;
        final ratio = contrast(ink, fill);
        expect(ratio, greaterThanOrEqualTo(wcagAa),
            reason: '掌握 $m 的底色 ${fill.toARGB32().toRadixString(16)} 上，'
                '文字只有 ${ratio.toStringAsFixed(2)}:1');
      }
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('图谱渲染', () {
    testWidgets('有复习数据时，叶子染上状态色', (tester) async {
      final kb = math1LikeKb();
      const target = 'math1.calc.limit.taylor';

      await tester.pumpWidget(_wrap(KnowledgeGraphView(
        kb: kb,
        masteryByKpId: {target: _m(target, mastery: 0.9)},
      )));
      await tester.pump();

      expect(_fillOf(tester, target), masteryBandFill(MasteryBand.solid));
    });

    testWidgets('没复习过的叶子保持结构色（不是"0%"的色）', (tester) async {
      final kb = math1LikeKb();
      const target = 'math1.calc.limit.lhopital';

      await tester.pumpWidget(_wrap(KnowledgeGraphView(
        kb: kb,
        masteryByKpId: {target: _m(target, mastery: null)},
      )));
      await tester.pump();

      expect(_fillOf(tester, target), nodeThemeOf(GraphNodeKind.leaf).fill,
          reason: 'mastery == null 必须是"还没复习"的样子，'
              '而不是被画成"薄弱"');
    });

    testWidgets('章节节点不会被染色（掌握度按知识点聚合）', (tester) async {
      final kb = math1LikeKb();
      const chapter = 'math1.calc.limit';

      await tester.pumpWidget(_wrap(KnowledgeGraphView(
        kb: kb,
        masteryByKpId: {chapter: _m(chapter, mastery: 0.1)},
      )));
      await tester.pump();

      expect(_fillOf(tester, chapter), nodeThemeOf(GraphNodeKind.chapter).fill);
    });

    testWidgets('一条复习数据都没有时，图例不提掌握度', (tester) async {
      final kb = math1LikeKb();
      const target = 'math1.calc.limit.taylor';

      await tester.pumpWidget(_wrap(KnowledgeGraphView(
        kb: kb,
        masteryByKpId: {target: _m(target, mastery: null)},
      )));
      await tester.pump();

      expect(find.text('稳固'), findsNothing);
      expect(find.text('薄弱'), findsNothing);
      expect(find.text('不牢'), findsNothing);
      // 结构图例仍然要在
      expect(find.text('知识点'), findsOneWidget);
    });

    testWidgets('有数据时图例把三档都列出来（否则颜色没有解释）', (tester) async {
      final kb = math1LikeKb();
      final ids = [
        'math1.calc.limit.taylor', // 稳固
        'math1.calc.limit.lhopital', // 不牢
        'math1.calc.limit.eq_infinitesimal', // 薄弱
      ];

      await tester.pumpWidget(_wrap(KnowledgeGraphView(
        kb: kb,
        masteryByKpId: {
          ids[0]: _m(ids[0], mastery: 0.9),
          ids[1]: _m(ids[1], mastery: 0.5),
          ids[2]: _m(ids[2], mastery: 0.1),
        },
      )));
      await tester.pump();

      expect(find.text('稳固'), findsOneWidget);
      expect(find.text('不牢'), findsOneWidget);
      expect(find.text('薄弱'), findsOneWidget);
    });

    testWidgets('完全不给掌握度 map 时，图谱照常画得出来（不崩、不上色）', (tester) async {
      final kb = math1LikeKb();
      await tester.pumpWidget(_wrap(KnowledgeGraphView(kb: kb)));
      await tester.pump();

      expect(find.text('知识点'), findsOneWidget);
      expect(find.text('稳固'), findsNothing);
      expect(_fillOf(tester, 'math1.calc.limit.taylor'),
          nodeThemeOf(GraphNodeKind.leaf).fill);
    });
  });
}
