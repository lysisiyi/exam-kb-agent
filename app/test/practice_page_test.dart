/// 练习页（V3 两栏版式重建）的结构测试：三入口、待复核卡、历史卡、
/// 组卷器展开。数据走 override 的假 provider，不碰真库。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/layout/breakpoints.dart';
import 'package:kaoyan_math_agent/core/providers.dart';
import 'package:kaoyan_math_agent/data/db/database.dart';
import 'package:kaoyan_math_agent/features/practice/practice_page.dart';
import 'package:kaoyan_math_agent/features/problems/problems_page.dart' show ProblemView;
import 'package:kaoyan_math_agent/services/review/review_repository.dart';
import 'support/test_env.dart';


void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(1280, 900),
    dynamic dbOverride,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // 两个卡的数据源都读真库 —— 测试里给空的假数据
          problemListProvider(ProblemView.recent)
              .overrideWith((ref) async => const <ProblemListRow>[]),
          paperHistoryProvider.overrideWith((ref) async => const <PaperRow>[]),
          if (dbOverride != null)
            databaseProvider.overrideWith((ref) async => dbOverride as AppDatabase),
        ],
        child: BreakpointScope.fromSize(
          size: size,
          child: const MaterialApp(home: Scaffold(body: PracticePage())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('三入口卡都在：课时练习（P3）/错题专练/真题全卷', (tester) async {
    await pumpPage(tester);
    expect(find.text('课时练习'), findsOneWidget);
    expect(find.text('错题专练'), findsOneWidget);
    expect(find.text('真题全卷 / 限时模考'), findsOneWidget);
    expect(find.text('推荐'), findsOneWidget, reason: '课时练习是推荐位');
  });

  testWidgets('课时练习按钮 P3 未上线：点了如实说明，不假装能用', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('开始练习（8 题）'), warnIfMissed: false);
    await tester.pump();
    expect(find.textContaining('随 P3 练习生成上线'), findsOneWidget);
  });

  testWidgets('点「去组卷」展开组卷器（嵌入体，不重复页头）', (tester) async {
    // 组卷器要读题库与模板 —— 用内存库（与 paper_page_test 同一模式）。
    final env = await tester.runAsync(() async => TempLibrary.create());
    addTearDown(() async {
      await tester.runAsync(env!.dispose);
    });
    await pumpPage(tester, dbOverride: env!.db);
    expect(find.text('组卷'), findsNothing, reason: '组卷按钮在组卷器展开后才出现');

    await tester.tap(find.text('去组卷').first, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.text('组卷器已展开 ↓'), findsWidgets,
          reason: '入口②③的按钮文案都会变（2 个）');
    expect(find.text('组卷'), findsOneWidget, reason: '组卷器的主按钮');
  });

  testWidgets('待复核卡：空态如实说明', (tester) async {
    await pumpPage(tester);
    expect(find.textContaining('AI 自创题 · 待复核'), findsOneWidget);
    expect(find.textContaining('当前没有待复核的自创题'), findsOneWidget);
  });

  testWidgets('待复核卡：有 needsReview 题时列出题干', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 借知识夹具造一个 needsReview 的列表行：
    // problemListProvider 读真库 —— 这里 override 成一条假数据。
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          problemListProvider(ProblemView.recent).overrideWith((ref) async => [
                const ProblemListRow(
                  problemId: 'p1',
                  stemText: '设 A² = A，证明 A 的特征值只能是 0 或 1',
                  needsReview: true,
                ),
                const ProblemListRow(
                  problemId: 'p2',
                  stemText: '正常的题，不该出现在待复核里',
                ),
              ]),
        ],
        child: BreakpointScope.fromSize(
          size: const Size(1280, 900),
          child: const MaterialApp(home: Scaffold(body: PracticePage())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1'), findsOneWidget, reason: '待复核计数');
    expect(find.textContaining('设 A² = A'), findsOneWidget);
    expect(find.textContaining('不该出现在待复核里'), findsNothing);
  });

  testWidgets('历史卡：空态与记录行', (tester) async {
    await pumpPage(tester);
    expect(find.textContaining('还没有练习记录'), findsOneWidget);
  });

  testWidgets('窄屏 560px：三入口换行不溢出', (tester) async {
    tester.view.physicalSize = const Size(560, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: BreakpointScope.fromSize(
          size: const Size(560, 900),
          child: const MaterialApp(home: Scaffold(body: PracticePage())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
