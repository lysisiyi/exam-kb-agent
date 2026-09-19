/// 知识库页：**图谱**与**大纲**两种视图 + 用户要求的两个交互。
///
/// ## 用户明确要的两件事
///
/// - **鼠标滚轮调整查看尺寸**（缩放）
/// - **鼠标箭头点按换查看位置**（拖动平移）
///
/// 这两条只能在 widget 测试里验：直接发 `PointerScrollEvent` 和拖动事件，
/// 然后断言**变换矩阵真的变了**（而不是只断言"控件存在"）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/layout/breakpoints.dart';
import 'package:kaoyan_math_agent/core/providers.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/features/knowledge/knowledge_graph_view.dart';
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

void main() {
  /// 起一页知识库（图谱模式是默认）。
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

  TransformationController controllerOf(WidgetTester tester) =>
      tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;

  group('页头', () {
    testWidgets('章节数不再是 0 —— 即使数据里的 level 写错了', (tester) async {
      await pumpPage(tester);

      expect(tester.takeException(), isNull);
      // 夹具里章节的 level 故意是 2；这一格必须显示 3 章
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('stat-章节')),
          matching: find.text('3'),
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

    testWidgets('两种查看方式都在，默认图谱', (tester) async {
      await pumpPage(tester);

      expect(find.text('图谱'), findsOneWidget);
      expect(find.text('大纲'), findsOneWidget);
      expect(find.byType(KnowledgeGraphView), findsOneWidget);
      expect(find.byType(KnowledgeOutlineView), findsNothing);
    });
  });

  group('图谱视图：滚轮缩放 + 拖动平移', () {
    testWidgets('滚轮缩放改变缩放系数（向上放大 / 向下缩小）', (tester) async {
      await pumpPage(tester);
      final tc = controllerOf(tester);
      final before = tc.value.getMaxScaleOnAxis();

      // 滚轮向上 = 放大
      final center = tester.getCenter(find.byType(InteractiveViewer));
      await tester.sendEventToBinding(
        PointerScrollEvent(position: center, scrollDelta: const Offset(0, -100)),
      );
      await tester.pumpAndSettle();

      final zoomedIn = tc.value.getMaxScaleOnAxis();
      expect(zoomedIn, greaterThan(before),
          reason: '滚轮向上应当放大（用户要的"调整查看尺寸"）');

      // 滚轮向下 = 缩小
      await tester.sendEventToBinding(
        PointerScrollEvent(
            position: center, scrollDelta: const Offset(0, 200)),
      );
      await tester.pumpAndSettle();
      expect(tc.value.getMaxScaleOnAxis(), lessThan(zoomedIn));
    });

    testWidgets('缩放以光标位置为焦点：焦点处的画布坐标不动', (tester) async {
      await pumpPage(tester);
      final tc = controllerOf(tester);
      final focus = tester.getTopLeft(find.byType(InteractiveViewer)) +
          const Offset(200, 300);
      final sceneBefore = tc.toScene(focus - tester.getTopLeft(find.byType(InteractiveViewer)));

      await tester.sendEventToBinding(
        PointerScrollEvent(position: focus, scrollDelta: const Offset(0, -120)),
      );
      await tester.pumpAndSettle();

      final sceneAfter =
          tc.toScene(focus - tester.getTopLeft(find.byType(InteractiveViewer)));
      expect((sceneAfter - sceneBefore).distance, lessThan(1.5),
          reason: '滚轮缩放应当以光标为焦点，否则用户会觉得"视图乱跑"');
    });

    testWidgets('拖动平移改变平移量（缩放系数不变）', (tester) async {
      await pumpPage(tester);
      final tc = controllerOf(tester);
      final scaleBefore = tc.value.getMaxScaleOnAxis();
      final txBefore = tc.value.getTranslation();

      final center = tester.getCenter(find.byType(InteractiveViewer));
      final gesture = await tester.startGesture(center);
      await tester.pump();
      await gesture.moveBy(const Offset(-120, -80));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      final txAfter = tc.value.getTranslation();
      expect((txAfter - txBefore).length, greaterThan(20),
          reason: '拖动应当平移画布（用户要的"换查看位置"）');
      expect(tc.value.getMaxScaleOnAxis(), closeTo(scaleBefore, 0.001),
          reason: '平移不该改变缩放');
    });

    testWidgets('放大/缩小按钮与百分比显示', (tester) async {
      await pumpPage(tester);
      final tc = controllerOf(tester);
      final before = tc.value.getMaxScaleOnAxis();

      await tester.tap(find.byTooltip('放大（也可以用滚轮）'));
      await tester.pumpAndSettle();
      expect(tc.value.getMaxScaleOnAxis(), greaterThan(before));

      await tester.tap(find.byTooltip('缩小（也可以用滚轮）'));
      await tester.pumpAndSettle();
      expect(tc.value.getMaxScaleOnAxis(), closeTo(before, 0.001));

      // 百分比跟着变换走
      expect(find.textContaining('%'), findsOneWidget);

      // 适合宽度：贴左上角（tx = 16）；看全整树：整幅居中 —— 小图两者
      // 缩放都是 100%，所以断言平移量而不是缩放
      await tester.tap(find.byTooltip('适应宽度'));
      await tester.pumpAndSettle();
      expect(tc.value.getTranslation().x, closeTo(16, 0.5));

      await tester.tap(find.byTooltip('看全整树'));
      await tester.pumpAndSettle();
      final viewport = tester.getSize(find.byType(InteractiveViewer));
      expect(tc.value.getTranslation().x, greaterThan(16),
          reason: '看全整树应当把窄图居中，而不是贴在左边');
      expect(tc.value.getTranslation().y, greaterThan(0));
      expect(viewport.width, 1280);
    });

    testWidgets('点节点会选中并显示详情，再点关闭收起', (tester) async {
      await pumpPage(tester);

      // 用 key 定位节点卡片：页面上"高频考点"标签里也有同名文字
      await tester.tap(find.byKey(const ValueKey('graph-node-math1.calc.limit.taylor')));
      await tester.pumpAndSettle();

      // 详情面板里应当有这个考点的定义与别名
      expect(find.textContaining('这是 泰勒公式求极限 的定义'), findsOneWidget);
      expect(find.textContaining('召回别名'), findsOneWidget);

      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.textContaining('这是 泰勒公式求极限 的定义'), findsNothing);
    });

    testWidgets('点章节节点显示分支摘要（挂了多少考点）', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.byKey(const ValueKey('graph-node-math1.calc.limit')));
      await tester.pumpAndSettle();

      expect(find.textContaining('3 个知识点'), findsWidgets);
      expect(find.textContaining('math1.calc.limit'), findsWidgets);
    });

    testWidgets('详情比面板高时，底部提示"下面还有内容"', (tester) async {
      // 真机上的表现：面板有高度上限，公式被切在边缘又看不出能滚 ——
      // 用户会直接判定成"公式显示不完整"
      await pumpPage(tester, kb: realMath1OrSkip(), size: const Size(1000, 620));
      final node = find.byKey(const ValueKey('graph-node-math1.calc.limit.func'));
      if (node.evaluate().isEmpty) {
        markTestSkipped('没有真实本体数据');
        return;
      }
      // 数一的图很宽，先把整树缩进视口，节点才点得到
      await tester.tap(find.byTooltip('看全整树'));
      await tester.pumpAndSettle();

      await tester.tap(node);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('panel-more-hint')), findsOneWidget);
      expect(find.text('下面还有内容，可滚动查看'), findsOneWidget);
    });
  });

  group('大纲视图', () {
    Future<void> pumpOutline(WidgetTester tester, {Size? size}) async {
      await pumpPage(tester, size: size ?? const Size(1280, 900));
      await tester.tap(find.text('大纲'));
      await tester.pumpAndSettle();
    }

    testWidgets('切到大纲：分级编号 + 默认展开到章节', (tester) async {
      await pumpOutline(tester);

      expect(find.byType(KnowledgeOutlineView), findsOneWidget);
      expect(find.byType(KnowledgeGraphView), findsNothing);
      expect(tester.takeException(), isNull);

      // 编号从顶层之下开始：分段 1 / 2，章节 1.1 / 1.2（章节按 id 排序，
      // 也就是考纲顺序：diff 在 limit 前面）
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('outline-row-math1.calc')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('outline-row-math1.calc.diff')),
          matching: find.text('1.1'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('outline-row-math1.calc.limit')),
          matching: find.text('1.2'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('outline-row-math1.linalg.eigen')),
          matching: find.text('2.1'),
        ),
        findsOneWidget,
      );

      // 默认展开到章节：章节名可见，叶子收起
      expect(find.text('极限与连续'), findsWidgets);
      expect(find.byKey(const ValueKey('outline-row-math1.calc.limit.taylor')),
          findsNothing);
    });

    testWidgets('展开章节后能看到叶子，再点叶子看详情', (tester) async {
      await pumpOutline(tester);

      await tester.tap(find.byKey(const ValueKey('outline-row-math1.calc.limit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('outline-row-math1.calc.limit.taylor')),
          findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('outline-row-math1.calc.limit.taylor')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('outline-detail-math1.calc.limit.taylor')),
        findsOneWidget,
      );
      expect(find.textContaining('这是 泰勒公式求极限 的定义'), findsOneWidget);

      // 再点一次收起详情
      await tester.tap(find.byKey(const ValueKey('outline-row-math1.calc.limit.taylor')));
      await tester.pumpAndSettle();
      expect(find.textContaining('这是 泰勒公式求极限 的定义'), findsNothing);
    });

    testWidgets('全部展开 / 收起到分段', (tester) async {
      await pumpOutline(tester);

      await tester.tap(find.text('全部展开'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('outline-row-math1.linalg.eigen.similarity')),
          findsOneWidget);

      await tester.tap(find.text('收起到分段'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('outline-row-math1.linalg.eigen.similarity')),
          findsNothing);
      // 章节行仍然在（收起到分段 = 章节可见、叶子收起）
      expect(find.byKey(const ValueKey('outline-row-math1.linalg.eigen')),
          findsOneWidget);
    });

    testWidgets('窄屏不溢出', (tester) async {
      await pumpOutline(tester, size: const Size(560, 800));
      expect(tester.takeException(), isNull);
    });
  });

  group('窄屏下的图谱', () {
    testWidgets('560px 宽：图例与操作栏不重叠、不溢出', (tester) async {
      await pumpPage(tester, size: const Size(560, 800));

      expect(tester.takeException(), isNull);
      final legend = tester.getRect(find.byType(Wrap).first);
      final toolbar = tester.getRect(find.byTooltip('放大（也可以用滚轮）'));
      // 两者在水平方向不能有交集
      expect(
        legend.right <= toolbar.left || toolbar.right <= legend.left,
        isTrue,
        reason: '图例（${legend.right}）与操作栏（${toolbar.left}）横向重叠了',
      );
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
            knowledgeBaseProvider.overrideWith(
                (ref) async => throw StateError('模拟载入失败')),
          ],
          child: BreakpointScope.fromSize(
            size: const Size(1200, 800),
            child: const MaterialApp(home: Scaffold(body: KnowledgePage())),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('知识点本体载入失败'), findsOneWidget);
      expect(find.text('重新载入'), findsOneWidget);
    });

    testWidgets('数三那种 5 层树在图谱里也能画出来', (tester) async {
      await pumpPage(tester, kb: math3LikeKb());
      expect(tester.takeException(), isNull);
      expect(find.text('无穷小比较'), findsWidgets);
    });

    testWidgets('数据缺陷（分段没挂在根上）不显示空白', (tester) async {
      await pumpPage(tester, kb: orphanKb());
      expect(tester.takeException(), isNull);
      // 兜底之后仍然能看见分段与叶子
      expect(find.text('高等数学'), findsWidgets);
      expect(find.text('泰勒展开'), findsWidgets);
    });

    // 真实本体有 164 个节点 / 141 个叶子 —— 夹具再像也代替不了它。
    // 「章节 0」这个缺陷就是被"夹具与真实数据不一致"掩盖过去的。
    testWidgets('真实 math1 本体：图谱与大纲都画得出来', (tester) async {
      final f = File('../data/knowledge_points/math1.json');
      if (!f.existsSync()) {
        markTestSkipped('数据文件不存在（请在仓库根或 app/ 下运行测试）');
        return;
      }
      final kb = KnowledgeBase.fromJson(
        (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>(),
      );

      await pumpPage(tester, kb: kb);
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('stat-章节')),
          matching: find.text('19'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('stat-知识点')),
          matching: find.text('141'),
        ),
        findsOneWidget,
      );

      // 切到大纲：19 章都在（默认展开到章节一级）
      await tester.tap(find.text('大纲'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('outline-row-math1.calc.limit')),
        findsOneWidget,
      );
      // 叶子默认收起
      expect(
        find.byKey(const ValueKey('outline-row-math1.calc.limit.taylor')),
        findsNothing,
      );
    });
  });
}
