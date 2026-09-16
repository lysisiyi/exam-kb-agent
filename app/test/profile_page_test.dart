/// 画像页测试。
///
/// ## 这一页要守的三件事
///
/// 1. **空题库时说人话**，而不是显示一堆 0 或空白
/// 2. **"掌握 X%" 旁边必须能看见样本量** —— 一个由 1 道题算出的 30%
///    和一个由 12 道题算出的 30% 可信度完全不同，只给百分比是在
///    暗示一个它没有的精度
/// 3. **错因数据不完整必须提示**（schema v4 之后旧题的错因列是空的），
///    否则用户看到的是一份"只统计了新题"的分布，而它看起来很正常
library;

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/layout/breakpoints.dart';
import 'package:kaoyan_math_agent/core/providers.dart';
import 'package:kaoyan_math_agent/data/db/database.dart';
import 'package:kaoyan_math_agent/data/error_causes.dart';
import 'package:kaoyan_math_agent/domain/fsrs/fsrs_scheduler.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/features/profile/profile_page.dart';

import 'support/test_env.dart';

const _kbJson = '''
{
  "subject": "math1",
  "subject_name": "数学一",
  "version": "test",
  "nodes": [
    {"id":"math1","name":"数学一","level":1},
    {"id":"math1.calc","name":"高等数学","level":2,"parent_id":"math1"},
    {"id":"math1.calc.limit","name":"极限","level":3,"parent_id":"math1.calc"},
    {"id":"math1.calc.limit.taylor","name":"泰勒展开","level":4,
     "parent_id":"math1.calc.limit","is_leaf":true,"exam_weight":0.8}
  ]
}
''';

/// 直接塞一道题（索引 + 主考点关联 + 状态行）。
Future<void> seed(
  AppDatabase db, {
  required String id,
  String? kp,
  int wrong = 0,
  String? fsrs,
  List<String>? causes,
}) async {
  await db.into(db.problemsIndex).insert(
        ProblemsIndexCompanion.insert(
          id: id,
          fingerprint: 'fp-$id',
          subject: 'math1',
          qtype: 'solve',
          filePath: 'problems/$id.md',
          stemText: '题目 $id',
          errorCauses: Value(causes == null ? null : jsonEncode(causes)),
        ),
      );
  if (kp != null) {
    await db.into(db.problemKnowledge).insert(
          ProblemKnowledgeCompanion.insert(
            problemId: id,
            kpId: kp,
            role: const Value('primary'),
          ),
        );
  }
  if (fsrs == null && wrong == 0) return;
  await db.into(db.userProblemState).insert(
        UserProblemStateCompanion.insert(
          problemId: id,
          wrongCount: Value(wrong),
          fsrsState: Value(fsrs),
        ),
      );
}

String fsrs({required double stability, required int daysAgo}) {
  final t = DateTime.now().subtract(Duration(days: daysAgo));
  return jsonEncode(FsrsCard(
    due: t.add(const Duration(days: 30)),
    stability: stability,
    difficulty: 5,
    reps: 3,
    state: CardState.review,
    lastReview: t,
  ).toJson());
}

void main() {
  late TempLibrary env;

  /// 建临时库 → 灌数据 → 挂页面。
  ///
  /// ⚠️ 灌数据必须**在 `pump` 里面**做：`env` 是每个用例新建的，
  /// 在 `pump` 之前调 `seed(env.db, ...)` 拿到的是**上一个用例**已经
  /// `dispose` 过的库 —— 报错是 "Can't re-open a database after closing it"，
  /// 看起来像产品缺陷，其实是夹具顺序错了。
  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1200, 1000),
    Future<void> Function()? seedFn,
  }) async {
    await tester.runAsync(() async {
      env = await TempLibrary.create();
      if (seedFn != null) await seedFn();
    });
    addTearDown(() async {
      await tester.runAsync(env.dispose);
    });

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) async => env.db),
          knowledgeBaseProvider.overrideWith((ref) async =>
              KnowledgeBase.fromJson(
                  jsonDecode(_kbJson) as Map<String, dynamic>)),
          errorCauseCatalogProvider.overrideWith(
              (ref) async => const ErrorCauseCatalog()),
        ],
        child: BreakpointScope.fromSize(
          size: size,
          child: const MaterialApp(home: Scaffold(body: ProfilePage())),
        ),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('空题库：给出去哪录题的指引，而不是一堆 0', (tester) async {
    await pump(tester);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('画像无从谈起'), findsOneWidget);
    expect(find.textContaining('「录入」'), findsOneWidget);
  });

  testWidgets('有题但没有复习记录：说明"复习几轮之后才有意义"', (tester) async {
    await pump(
      tester,
      seedFn: () => seed(env.db, id: 'p-1', kp: 'math1.calc.limit.taylor'),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('总览'), findsOneWidget);
    expect(find.textContaining('还没有复习记录'), findsWidgets);
    // 1 道题在"题库"里
    expect(find.text('1 题'), findsWidgets);
  });

  testWidgets('薄弱榜显示掌握度与错次数，并且带样本量', (tester) async {
    await pump(tester, seedFn: () async {
      await seed(
        env.db,
        id: 'p-1',
        kp: 'math1.calc.limit.taylor',
        wrong: 5,
        fsrs: fsrs(stability: 2.0, daysAgo: 30),
      );
      await seed(
        env.db,
        id: 'p-2',
        kp: 'math1.calc.limit.taylor',
        wrong: 1,
        fsrs: fsrs(stability: 30.0, daysAgo: 1),
      );
    });

    expect(tester.takeException(), isNull);
    expect(find.text('泰勒展开'), findsWidgets);
    expect(find.text('错 6 次'), findsWidgets);
    // ⚠️ 样本量必须出现：2/2 题有记录
    expect(find.text('2/2 题有记录'), findsWidgets);
    // 章节名也要露出来（用户要知道这是哪一章的）
    expect(find.text('极限'), findsWidgets);
  });

  testWidgets('总览里的"平均掌握"标注了只统计有复习记录的题', (tester) async {
    await pump(tester, seedFn: () async {
      await seed(
        env.db,
        id: 'p-1',
        kp: 'math1.calc.limit.taylor',
        fsrs: fsrs(stability: 50.0, daysAgo: 1),
      );
      await seed(env.db, id: 'p-2', kp: 'math1.calc.limit.taylor');
    });

    expect(tester.takeException(), isNull);
    expect(find.text('只统计有复习记录的题'), findsOneWidget);
    expect(find.text('从未复习'), findsOneWidget);
  });

  testWidgets('错因数据不完整时必须提示，不能默默给一份看起来正常的分布',
      (tester) async {
    await pump(tester, seedFn: () async {
      await seed(env.db, id: 'p-1', causes: ['sign']);
      // 这道题没有错因数据（迁移后旧题的样子）
      await seed(env.db, id: 'p-2');
      await seed(env.db, id: 'p-3');
    });

    expect(tester.takeException(), isNull);
    expect(find.textContaining('没有错因数据'), findsOneWidget);
    expect(find.textContaining('重建'), findsWidgets);
  });

  testWidgets('窄屏不溢出（两列会退化成一列）', (tester) async {
    await pump(
      tester,
      size: const Size(480, 900),
      seedFn: () => seed(
        env.db,
        id: 'p-1',
        kp: 'math1.calc.limit.taylor',
        wrong: 2,
        fsrs: fsrs(stability: 5.0, daysAgo: 10),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('最薄弱的考点'), findsOneWidget);
  });
}
