/// 知识库页（V3 两栏编辑器）：**严格按参考图 `docs/design/ui/ui_knowledge.png`
/// 重构后的结构测试**。
///
/// 版式：页头（学科 chip + 骨架/已填 chips + 三个动作）→ 下一步建议横幅 →
/// 左树（状态点/星级/选中高亮）｜右详情（叶子=详情卡、分支=分支摘要）。
///
/// 旧版是「图谱/大纲」模式切换 + 叶子行内联详情；图谱的缩放/平移/图例
/// 等测试已随该版式一起移除（图谱的纯布局逻辑仍由
/// `knowledge_graph_layout_test.dart` 覆盖）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/layout/breakpoints.dart';
import 'package:kaoyan_math_agent/core/providers.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/features/knowledge/knowledge_leaf_detail.dart';
import 'package:kaoyan_math_agent/features/knowledge/knowledge_outline_view.dart';
import 'package:kaoyan_math_agent/features/knowledge/knowledge_page.dart';

import 'support/knowledge_fixture.dart';

/// 真实本体（数一）。数据不在时返回合成夹具，调用方按 id 是否存在自行跳过。
KnowledgeBase realMath1OrSkip() {
  final f = File('../data/knowledge_points/math1.json');
  if (!f.existsSync()) return math1LikeKb();
  return KnowledgeBase.fromJson(
    (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>(),
  );
}

/// 把 `math1.calc.limit.taylor` 清成“骨架”（无定义）——测建议横幅与状态点。
KnowledgeBase kbWithSkeletonLeaf() {
  final base = math1LikeKb();
  return KnowledgeBase(
    subject: base.subject,
    subjectName: base.subjectName,
    version: 'test',
    nodes: [
      for (final n in base.nodes)
        if (n.id == 'math1.calc.limit.taylor')
          KnowledgePoint(
            id: n.id,
            name: n.name,
            level: n.level,
            parentId: n.parentId,
            isLeaf: true,
            examWeight: n.examWeight,
          )
        else
          n,
    ],
  );
}

void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(1280, 900),
    KnowledgeBase? kb,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeBaseProvider.overrideWith((ref) async => kb ?? math1LikeKb()),
        ],
        child: BreakpointScope.fromSize(
          size: size,
          child: const MaterialApp(home: Scaffold(body: KnowledgePage())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('页头与建议横幅（参考图第一二行）', () {
    testWidgets('章节数不看 level 字段（夹具里章节的 level 故意写错）', (tester) async {
      await pumpPage(tester);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('stat-章节')),
          matching: find.text('3'), // limit / diff / eigen
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('stat-知识点')),
          matching: find.text('5'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('骨架/已填 chips 计数正确（全填）', (tester) async {
      await pumpPage(tester);
      expect(find.text('已填 5'), findsOneWidget);
      expect(find.text('骨架 0'), findsOneWidget);
    });

    testWidgets('骨架/已填 chips 计数正确（一个骨架）', (tester) async {
      await pumpPage(tester, kb: kbWithSkeletonLeaf());
      expect(find.text('已填 4'), findsOneWidget);
      expect(find.text('骨架 1'), findsOneWidget);
    });

    testWidgets('下一步建议横幅：给出骨架叶子；点「去看」右栏切到它', (tester) async {
      await pumpPage(tester, kb: kbWithSkeletonLeaf());
      expect(find.textContaining('下一步建议：'), findsOneWidget);
      expect(find.textContaining('泰勒公式求极限'), findsWidgets, reason: '横幅里要点名');

      await tester.tap(find.text('去看'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('detail-math1.calc.limit.taylor')),
        findsOneWidget,
        reason: '点「去看」右栏应切到该节点详情',
      );
    });

    testWidgets('全部填好时横幅消失（没有“下一步”可建议）', (tester) async {
      await pumpPage(tester);
      expect(find.textContaining('下一步建议：'), findsNothing);
    });

    testWidgets('三个动作按钮都在（导入题目/梳理/新建学科）', (tester) async {
      await pumpPage(tester);
      expect(find.text('导入题目'), findsOneWidget);
      expect(find.text('AI 梳理本章'), findsOneWidget);
      expect(find.text('新建学科（向导）'), findsOneWidget);
    });
  });

  group('两栏：左树 + 右详情', () {
    testWidgets('默认选中第一个骨架叶子；全填时用第一个叶子', (tester) async {
      // 全填：leaves 保持夹具插入序，第一个是 taylor
      await pumpPage(tester);
      expect(find.byKey(const ValueKey('detail-math1.calc.limit.taylor')),
          findsOneWidget);
    });

    testWidgets('展开章节后点叶子行 → 右栏切换到该叶子', (tester) async {
      await pumpPage(tester);
      expect(find.byKey(const ValueKey('outline-row-math1.calc.limit.taylor')),
          findsNothing, reason: '默认只展开到章节，叶子收起');

      await tester.tap(
          find.byKey(const ValueKey('outline-row-math1.calc.limit')),
          warnIfMissed: false);
      await tester.pumpAndSettle();

      await tester.tap(
          find.byKey(const ValueKey('outline-row-math1.calc.limit.taylor')),
          warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('detail-math1.calc.limit.taylor')),
          findsOneWidget);
    });

    testWidgets('点分支行 → 右栏显示分支摘要（考点数与子节点清单）', (tester) async {
      await pumpPage(tester);
      await tester.tap(
          find.byKey(const ValueKey('outline-row-math1.calc.limit')),
          warnIfMissed: false);
      await tester.pumpAndSettle();

      // limit 分支下 3 个叶子（taylor/lhopital/eq_infinitesimal），都填了
      expect(find.textContaining('这一支共 3 个考点'), findsOneWidget);
      expect(find.textContaining('已填 3'), findsOneWidget);
    });

    testWidgets('树行显示优先级星（有考频数据的叶子）', (tester) async {
      await pumpPage(tester);
      await tester.tap(
          find.byKey(const ValueKey('outline-row-math1.calc.limit')),
          warnIfMissed: false);
      await tester.pumpAndSettle();
      // 夹具里 limit 下的叶子权重都 ≥ 0.85 → ★★★
      expect(find.text('★★★'), findsWidgets);
    });

    testWidgets('骨架叶子的状态点是空心（与已填的实心区分）', (tester) async {
      await pumpPage(tester, kb: kbWithSkeletonLeaf());
      await tester.tap(
          find.byKey(const ValueKey('outline-row-math1.calc.limit')),
          warnIfMissed: false);
      await tester.pumpAndSettle();
      final dots = tester
          .widgetList<Container>(find.byType(Container))
          .where((c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).shape == BoxShape.circle)
          .toList();
      expect(
          dots.where((c) => (c.decoration as BoxDecoration).color == null),
          isNotEmpty,
          reason: '骨架节点应有空心状态点');
    });
  });

  group('边界', () {
    testWidgets('本体载入失败：给出错误与重试，而不是空白', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeBaseProvider
                .overrideWith((ref) async => throw StateError('坏掉了')),
          ],
          child: const MaterialApp(home: Scaffold(body: KnowledgePage())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('知识本体载入失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('窄屏 560px：两栏收窄不溢出', (tester) async {
      await pumpPage(tester, size: const Size(560, 800));
      expect(tester.takeException(), isNull);
      expect(find.byType(KnowledgeOutlineView), findsOneWidget);
      expect(find.byType(KnowledgeLeafDetail), findsOneWidget);
    });

    testWidgets('真实 math1 本体：整页能渲染（树 + 详情）', (tester) async {
      final kb = realMath1OrSkip();
      final hasReal = kb.byId.containsKey('math1.calc.limit.eq_infinitesimal');
      if (!hasReal) {
        markTestSkipped('真实本体不在，跳过');
        return;
      }
      await pumpPage(tester, kb: kb);
      expect(tester.takeException(), isNull);
      expect(find.byType(KnowledgeOutlineView), findsOneWidget);
    });

    testWidgets('数据缺陷（分段游离）也能渲染', (tester) async {
      await pumpPage(tester, kb: orphanKb());
      expect(tester.takeException(), isNull);
    });
  });
}
