/// 组卷页测试。
///
/// ## 这一页要守的是"参数真的会传到引擎上"
///
/// 组卷页有一堆开关（科目、模板、三个偏好、难度宽容度）。这些开关最容易
/// 出的错不是崩溃，而是**接了但没传**：界面上点得动，实际组卷用的是默认值。
/// 这种 bug 从截图上看不出来，只能靠断言"点了之后抽出什么题"来抓。
library;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/layout/breakpoints.dart';
import 'package:kaoyan_math_agent/core/providers.dart';
import 'package:kaoyan_math_agent/data/db/database.dart';
import 'package:kaoyan_math_agent/features/paper/paper_page.dart';
import 'package:kaoyan_math_agent/services/paper/paper_repository.dart';

import 'support/test_env.dart';

/// 一份最小可用的模板 JSON：2 选择 + 1 解答。
const _templatesJson = '''
{
  "version": "t",
  "difficulty_labels": {"1": "基础", "2": "综合", "3": "拓展"},
  "qtype_labels": {"choice": "选择题", "fill": "填空题", "solve": "解答题"},
  "templates": {
    "math1": {
      "real_exam": {
        "id": "math1.real_exam",
        "name": "真题结构全卷",
        "description": "完整模拟",
        "total_score": 20,
        "duration_minutes": 180,
        "sections": [
          {"qtype": "choice", "name": "选择题", "count": 2,
           "score_per_item": 5, "difficulty": [1, 2]},
          {"qtype": "solve", "name": "解答题", "count": 1,
           "score_per_item": 10, "difficulty": [2]}
        ]
      }
    }
  }
}
''';

void main() {
  late TempLibrary env;

  Future<void> seed(WidgetTester tester) async {
    await tester.runAsync(() async {
      env = await TempLibrary.create();
      // 模板要 2 选择 + 1 解答，所以每种题型都要有富余
      // 难度也要铺开：模板第 1 个选择题位是难度 1，第 2 个是 2
      await seedProblems(env, [
        const SeedProblem(id: 'c1', stem: 'CH1', wrongCount: 0, difficulty: 1),
        const SeedProblem(id: 'c2', stem: 'CH2', wrongCount: 1, difficulty: 2),
        const SeedProblem(id: 'c3', stem: 'CH3', wrongCount: 2, difficulty: 1),
        const SeedProblem(id: 's1', stem: 'SO1', wrongCount: 2, difficulty: 2),
        const SeedProblem(id: 's2', stem: 'SO2', wrongCount: 5, difficulty: 2),
      ]);
      // seedProblems 默认都是 solve，把 c* 改成 choice
      for (final id in ['c1', 'c2', 'c3']) {
        await (env.db.update(env.db.problemsIndex)..where((t) => t.id.equals(id)))
            .write(const ProblemsIndexCompanion(qtype: Value('choice')));
      }
    });
    addTearDown(() async {
      await tester.runAsync(env.dispose);
    });
  }

  Future<void> pump(WidgetTester tester, {Size size = const Size(1100, 1000)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) async => env.db),
          problemStoreProvider.overrideWith((ref) async => env.store),
          paperRepositoryProvider.overrideWith(
            (ref) async => PaperRepository(
              db: env.db,
              templatesJson: _templatesJson,
            ),
          ),
        ],
        child: BreakpointScope.fromSize(
          size: size,
          child: const MaterialApp(home: Scaffold(body: PaperPage())),
        ),
      ),
    );
    // 模板是异步载入的，多推几帧让它落地
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('页面能起来并列出模板', (tester) async {
    await seed(tester);
    await pump(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('智能组卷'), findsOneWidget);
    expect(find.text('真题结构全卷'), findsOneWidget);
    // 模板元信息要显示出来，用户才知道这是什么卷。
    // 用 findsWidgets 而不是 findsOneWidget：组卷后预览头部也会出现同样的
    // 数字（"满分 20 分 · 共 3 题"），那条断言的目的只是"信息露出来了"。
    expect(find.textContaining('3 题'), findsWidgets);
    expect(find.textContaining('20 分'), findsWidgets);
    expect(find.textContaining('180 分钟'), findsWidgets);
  });

  testWidgets('没选模板时组卷按钮禁用', (tester) async {
    await seed(tester);
    await pump(tester);

    final btn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '组卷'),
    );
    expect(btn.onPressed, isNull, reason: '没选模板就组卷是没意义的');
  });

  testWidgets('选模板 → 组卷 → 出预览', (tester) async {
    await seed(tester);
    await pump(tester);

    await tester.tap(find.text('真题结构全卷'));
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, '组卷'));
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(tester.takeException(), isNull);
    expect(find.text('试卷预览'), findsOneWidget);
    // 三个题位都该填上（题库里每种题型都有富余）
    expect(find.textContaining('CH'), findsNWidgets(2));
    expect(find.textContaining('SO'), findsOneWidget);
  });

  testWidgets('预览里显示难度与考点（用户要能核对卷子像不像真题）', (tester) async {
    await seed(tester);
    await pump(tester);
    await tester.tap(find.text('真题结构全卷'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '组卷'));
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }

    // 标签来自模板文件的 difficulty_labels，不是硬编码在 UI 里
    expect(find.text('基础'), findsWidgets);
    expect(find.text('综合'), findsWidgets);
    // 分值与错题次数
    expect(find.text('5 分'), findsWidgets);
    expect(find.text('错 5 次'), findsOneWidget);
  });

  testWidgets('题量不足时把差异显示出来，不让用户自己数', (tester) async {
    await tester.runAsync(() async {
      env = await TempLibrary.create();
      // 只给 1 个选择题，模板要 2 个 + 1 个解答题
      await seedProblems(env, [const SeedProblem(id: 'c1', stem: 'CH1')]);
      await (env.db.update(env.db.problemsIndex)
            ..where((t) => t.id.equals('c1')))
          .write(const ProblemsIndexCompanion(qtype: Value('choice')));
    });
    addTearDown(() async {
      await tester.runAsync(env.dispose);
    });

    await pump(tester);
    await tester.tap(find.text('真题结构全卷'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '组卷'));
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.text('这份卷子与模板的差异'), findsOneWidget);
    expect(find.textContaining('题库不足'), findsOneWidget);
  });

  testWidgets('空题库也能组卷（不崩，给出空卷提示）', (tester) async {
    await tester.runAsync(() async {
      env = await TempLibrary.create();
      await seedProblems(env, const []);
    });
    addTearDown(() async {
      await tester.runAsync(env.dispose);
    });

    await pump(tester);
    await tester.tap(find.text('真题结构全卷'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '组卷'));
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(tester.takeException(), isNull);
    expect(find.textContaining('0/3'), findsOneWidget);
  });

  testWidgets('窄屏不溢出', (tester) async {
    await seed(tester);
    await pump(tester, size: const Size(420, 900));
    expect(tester.takeException(), isNull);
  });

  testWidgets('模板载入失败时给出可读提示而不是崩', (tester) async {
    await tester.runAsync(() async {
      env = await TempLibrary.create();
      await seedProblems(env, const []);
    });
    addTearDown(() async {
      await tester.runAsync(env.dispose);
    });

    tester.view.physicalSize = const Size(1100, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) async => env.db),
          problemStoreProvider.overrideWith((ref) async => env.store),
          // 坏 JSON：模板表为空
          paperRepositoryProvider.overrideWith(
            (ref) async =>
                PaperRepository(db: env.db, templatesJson: '这不是 JSON'),
          ),
        ],
        child: BreakpointScope.fromSize(
          size: const Size(1100, 1000),
          child: const MaterialApp(home: Scaffold(body: PaperPage())),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(tester.takeException(), isNull);
    expect(find.textContaining('还没有可用模板'), findsOneWidget);
  });
}
