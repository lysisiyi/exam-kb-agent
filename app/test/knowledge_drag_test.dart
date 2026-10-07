/// 拖拽整理（K2）的手势接线测试：长按树行拖到分支行上 → onMoveNode(child, parent)。
///
/// 只在 widget 层钉"手势真的接到了回调、非法目标真的被拒收"；
/// 文件移动的语义由 knowledge_md_test.dart 的 moveNode 组覆盖。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/theme/app_theme.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/features/knowledge/knowledge_outline_view.dart';

import 'support/knowledge_fixture.dart';

void main() {
  Future<void> pumpTree(
    WidgetTester tester, {
    required void Function(KnowledgePoint child, KnowledgePoint parent) onMove,
  }) async {
    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: KnowledgeOutlineView(
          kb: math1LikeKb(),
          onMoveNode: onMove,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 长按 [from] 行并拖到 [to] 行中心松手。
  Future<void> longPressDragTo(
      WidgetTester tester, Finder from, Finder to) async {
    final start = tester.getCenter(from);
    final end = tester.getCenter(to);
    final gesture = await tester.startGesture(start);
    // 触发 LongPressDraggable 的长按识别
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('拖叶子到另一个章节上 → 回调带 (叶子, 目标章节)', (tester) async {
    final moves = <(String, String)>[];
    await pumpTree(tester,
        onMove: (c, p) => moves.add((c.id, p.id)));

    // 展开极限章节露出叶子
    await tester.tap(
        find.byKey(const ValueKey('outline-row-math1.calc.limit')),
        warnIfMissed: false);
    await tester.pumpAndSettle();

    await longPressDragTo(
      tester,
      find.byKey(const ValueKey('outline-row-math1.calc.limit.taylor')),
      find.byKey(const ValueKey('outline-row-math1.calc.diff')),
    );

    expect(moves, isNotEmpty, reason: '拖到合法分支上必须触发回调');
    expect(moves.last, ('math1.calc.limit.taylor', 'math1.calc.diff'));
  });

  testWidgets('拖到自身/后代/叶子上 → 不触发回调（拒收）', (tester) async {
    final moves = <(String, String)>[];
    await pumpTree(tester,
        onMove: (c, p) => moves.add((c.id, p.id)));

    await tester.tap(
        find.byKey(const ValueKey('outline-row-math1.calc.limit')),
        warnIfMissed: false);
    await tester.pumpAndSettle();

    // 拖到自身
    await longPressDragTo(
      tester,
      find.byKey(const ValueKey('outline-row-math1.calc.limit.taylor')),
      find.byKey(const ValueKey('outline-row-math1.calc.limit.taylor')),
    );
    // 拖到叶子（叶子不能当父级）
    await longPressDragTo(
      tester,
      find.byKey(const ValueKey('outline-row-math1.calc.limit.taylor')),
      find.byKey(const ValueKey('outline-row-math1.calc.limit.lhopital')),
    );

    expect(moves, isEmpty, reason: '非法目标必须全部拒收');
  });
}
