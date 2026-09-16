/// F7 掌握度画像：聚合、排序、错因分布、曲线。
///
/// ## 这个文件里最重要的一条：掌握度必须**读时重算**
///
/// `user_problem_state.mastery` 存的是**打分那一刻**的可提取性，
/// 而可提取性会随时间衰减，列里的值不会跟着变（T37）。
///
/// 用它做画像不是"略有偏差"，是**系统性失真**：拖得越久没复习的考点
/// 越被高估 —— 而那恰恰是最该补的。下面第 1、2 条测试专门钉这件事。
library;

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/data/db/database.dart';
import 'package:kaoyan_math_agent/data/error_causes.dart';
import 'package:kaoyan_math_agent/domain/fsrs/fsrs_scheduler.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/services/profile/mastery_service.dart';

import 'support/test_env.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 夹具
// ─────────────────────────────────────────────────────────────────────────────

/// 一个够用的本体：1 个科目 → 1 个分段 → 2 个章节 → 3 个叶子。
KnowledgeBase buildKb() {
  const nodes = <KnowledgePoint>[
    KnowledgePoint(id: 'math1', name: '数学一', level: 1),
    KnowledgePoint(
        id: 'math1.calc', name: '高等数学', level: 2, parentId: 'math1'),
    KnowledgePoint(
        id: 'math1.calc.limit',
        name: '极限',
        level: 3,
        parentId: 'math1.calc',
        examWeight: 0.9),
    KnowledgePoint(
        id: 'math1.calc.deriv',
        name: '导数',
        level: 3,
        parentId: 'math1.calc',
        examWeight: 0.4),
    KnowledgePoint(
        id: 'math1.calc.limit.taylor',
        name: '泰勒展开',
        level: 4,
        parentId: 'math1.calc.limit',
        isLeaf: true,
        examWeight: 0.8),
    KnowledgePoint(
        id: 'math1.calc.limit.lhopital',
        name: '洛必达法则',
        level: 4,
        parentId: 'math1.calc.limit',
        isLeaf: true,
        examWeight: 0.7),
    KnowledgePoint(
        id: 'math1.calc.deriv.rules',
        name: '求导法则',
        level: 4,
        parentId: 'math1.calc.deriv',
        isLeaf: true,
        examWeight: 0.5),
  ];
  return KnowledgeBase(
    subject: 'math1',
    subjectName: '数学一',
    version: 'test',
    nodes: nodes,
  );
}

/// 建一张 FSRS 卡：给定稳定度与"上次复习距今多少天"。
String fsrsJson({required double stability, required int daysAgo, DateTime? now}) {
  final t = (now ?? DateTime(2024, 6, 10, 12)).subtract(Duration(days: daysAgo));
  return jsonEncode(FsrsCard(
    due: t.add(const Duration(days: 30)),
    stability: stability,
    difficulty: 5,
    reps: 3,
    state: CardState.review,
    lastReview: t,
  ).toJson());
}

/// 往库里塞一道题（索引行 + 主/次考点关联 + 可选状态行）。
Future<void> seedOne(
  TempLibrary env, {
  required String id,
  String? primaryKp,
  List<String> secondaryKps = const [],
  String? primaryKpName,
  int wrongCount = 0,
  String? fsrsState,
  double masterySnapshot = 0,
  List<String>? errorCauses,
  DateTime? createdAt,
}) async {
  await env.db.into(env.db.problemsIndex).insert(
        ProblemsIndexCompanion.insert(
          id: id,
          fingerprint: 'fp-$id',
          subject: 'math1',
          qtype: 'solve',
          filePath: 'problems/$id.md',
          stemText: '题目 $id',
          primaryKpName: Value(primaryKpName),
          errorCauses:
              Value(errorCauses == null ? null : jsonEncode(errorCauses)),
          createdAt: Value(createdAt ?? DateTime(2024, 1, 1)),
        ),
      );

  if (primaryKp != null) {
    await env.db.into(env.db.problemKnowledge).insert(
          ProblemKnowledgeCompanion.insert(
            problemId: id,
            kpId: primaryKp,
            role: const Value('primary'),
          ),
        );
  }
  for (final k in secondaryKps) {
    await env.db.into(env.db.problemKnowledge).insert(
          ProblemKnowledgeCompanion.insert(
            problemId: id,
            kpId: k,
            role: const Value('secondary'),
          ),
        );
  }

  if (fsrsState == null && wrongCount == 0) return;
  await env.db.into(env.db.userProblemState).insert(
        UserProblemStateCompanion.insert(
          problemId: id,
          wrongCount: Value(wrongCount),
          firstSeen: Value(DateTime(2024, 1, 1)),
          fsrsState: Value(fsrsState),
          mastery: Value(masterySnapshot),
        ),
      );
}

void main() {
  late TempLibrary env;
  final kb = buildKb();
  final now = DateTime(2024, 6, 10, 12);

  setUp(() async {
    env = await TempLibrary.create();
  });

  tearDown(() => env.dispose());

  MasteryService service({ErrorCauseCatalog? causes}) => MasteryService(
        db: env.db,
        // 去掉 fuzzing 让结果可复现；desiredRetention 用默认 0.9
        scheduler: FsrsScheduler(enableFuzzing: false),
        causes: causes,
      );

  // ═══════════════════════════════════════════════════════════════════════════
  group('T37：掌握度读时重算', () {
    test('用的是重算值，不是状态行里那个快照', () async {
      // 状态行里写着"掌握 0.95"（打分那一刻的乐观值），
      // 而卡片的稳定度很小、已经 40 天没复习 —— 真实掌握度远低于此。
      await seedOne(
        env,
        id: 'p-1',
        primaryKp: 'math1.calc.limit.taylor',
        fsrsState: fsrsJson(stability: 2.0, daysAgo: 40, now: now),
        masterySnapshot: 0.95,
      );

      final report =
          await service().build(knowledge: kb, now: now, topKp: 10);
      final kp = report.weakest.single;

      expect(kp.mastery, isNotNull);
      expect(kp.mastery, lessThan(0.5),
          reason: '稳定度 2 天、40 天没复习，真实掌握度必然很低');
      expect(kp.mastery, isNot(closeTo(0.95, 0.01)),
          reason: '绝不能读那个快照列 —— 那正是 T37');
    });

    test('时间越往后推，同一个库算出的掌握度越低（会衰减）', () async {
      await seedOne(
        env,
        id: 'p-1',
        primaryKp: 'math1.calc.limit.taylor',
        fsrsState: fsrsJson(stability: 10.0, daysAgo: 1, now: now),
      );

      final svc = service();
      final day1 = (await svc.build(knowledge: kb, now: now)).weakest.single;
      final day30 = (await svc.build(
        knowledge: kb,
        now: now.add(const Duration(days: 30)),
      ))
          .weakest
          .single;

      expect(day1.mastery!, greaterThan(day30.mastery!),
          reason: '同一个库在不同时间点必须算出不同的掌握度 —— '
              '否则说明读的还是那个不会变的快照');
      expect(day1.mastery!, greaterThan(0.8));
    });

    test('新卡不算"掌握度为 0"，而是"没有可谈的掌握度"', () async {
      // 这条很关键：把新卡当成 0 会让"最薄弱考点"全变成
      // 还没开始复习的章节 —— 排序就废了。
      await seedOne(env, id: 'p-1', primaryKp: 'math1.calc.limit.taylor');

      final report =
          await service().build(knowledge: kb, now: now, topKp: 10);
      final kp = report.weakest.single;

      expect(kp.mastery, isNull);
      expect(kp.reviewedCount, 0);
      expect(kp.problemCount, 1, reason: '题还是算进去的');
      expect(kp.weakness, 0, reason: '没有数据就不参与薄弱排序');
      expect(report.newProblems, 1);
      expect(report.hasReviewData, isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  group('主考点聚合', () {
    test('只统计主考点，次考点不吃这道题的分', () async {
      // 一道题主考点是 A、次考点是 B。B 不该因为"被提到过"就进入薄弱榜。
      await seedOne(
        env,
        id: 'p-1',
        primaryKp: 'math1.calc.limit.taylor',
        secondaryKps: ['math1.calc.deriv.rules'],
        wrongCount: 5,
        fsrsState: fsrsJson(stability: 2.0, daysAgo: 30, now: now),
      );

      final report =
          await service().build(knowledge: kb, now: now, topKp: 10);
      final ids = report.weakest.map((k) => k.kpId).toList();

      expect(ids, contains('math1.calc.limit.taylor'));
      expect(ids, isNot(contains('math1.calc.deriv.rules')),
          reason: '次考点不该因为被提到就进薄弱榜');
    });

    test('本体没载入导致 primary_kp_name 为 null 时，聚合照样正确', () async {
      // ⚠️ 这条守的是一个真实踩过的坑：早先想用
      // `problems_index.primary_kp_name` 反推考点，而那一列是本体载入时
      // 冗余写入的 —— 本体没载入时它是 null，于是所有题落进同一个桶，
      // **掌握度聚合静默失效**（排序看着有结果，其实全是一样的数）。
      //
      // 正确来源只能是 `problem_knowledge` 的 role == 'primary'。
      // 组卷那边踩过一模一样的坑（PaperRepository.candidates）。
      await seedOne(
        env,
        id: 'p-1',
        primaryKp: 'math1.calc.limit.taylor',
        primaryKpName: null, // ← 本体没载入时的样子
        wrongCount: 3,
        fsrsState: fsrsJson(stability: 2.0, daysAgo: 30, now: now),
      );
      await seedOne(
        env,
        id: 'p-2',
        primaryKp: 'math1.calc.deriv.rules',
        primaryKpName: null,
        wrongCount: 1,
        fsrsState: fsrsJson(stability: 20.0, daysAgo: 1, now: now),
      );

      final report =
          await service().build(knowledge: kb, now: now, topKp: 10);

      expect(report.weakest.length, 2,
          reason: '两道不同的考点必须落进两个桶，而不是一个');
      expect(
        report.weakest.map((k) => k.kpId).toSet(),
        {'math1.calc.limit.taylor', 'math1.calc.deriv.rules'},
      );
    });

    test('同一个考点下多道题取平均，并报出"几道题平均出来的"', () async {
      await seedOne(
        env,
        id: 'p-1',
        primaryKp: 'math1.calc.limit.taylor',
        fsrsState: fsrsJson(stability: 2.0, daysAgo: 30, now: now),
      );
      await seedOne(
        env,
        id: 'p-2',
        primaryKp: 'math1.calc.limit.taylor',
        fsrsState: fsrsJson(stability: 60.0, daysAgo: 1, now: now),
      );
      await seedOne(env, id: 'p-3', primaryKp: 'math1.calc.limit.taylor');

      final report =
          await service().build(knowledge: kb, now: now, topKp: 10);
      final kp = report.weakest.single;

      expect(kp.problemCount, 3);
      expect(kp.reviewedCount, 2, reason: '第三道是新卡，不参与平均');
      expect(kp.mastery, isNotNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  group('薄弱点排序', () {
    test('掌握度低优先，错得多加分；log 压缩避免长尾压倒一切', () async {
      // A：掌握度很低、错 2 次      → 最该补
      // B：掌握度中等、错 20 次     → 长期顽疾
      // C：掌握度很高、没错过        → 不需要管
      await seedOne(
        env,
        id: 'a',
        primaryKp: 'math1.calc.limit.taylor',
        wrongCount: 2,
        fsrsState: fsrsJson(stability: 1.0, daysAgo: 60, now: now),
      );
      await seedOne(
        env,
        id: 'b',
        primaryKp: 'math1.calc.limit.lhopital',
        wrongCount: 20,
        fsrsState: fsrsJson(stability: 8.0, daysAgo: 5, now: now),
      );
      await seedOne(
        env,
        id: 'c',
        primaryKp: 'math1.calc.deriv.rules',
        wrongCount: 0,
        fsrsState: fsrsJson(stability: 200.0, daysAgo: 1, now: now),
      );

      final report =
          await service().build(knowledge: kb, now: now, topKp: 10);
      final order = report.weakest.map((k) => k.kpId).toList();

      expect(order.first, 'math1.calc.limit.taylor',
          reason: '掌握度最低的那个必须排第一');
      expect(order.last, 'math1.calc.deriv.rules',
          reason: '掌握度高又没错过的排最后');
      // log 压缩的意义：错 20 次不能把"掌握度更低"的 A 压下去
      expect(report.weakest.first.wrongCount, lessThan(20));
    });

    test('没有复习数据的考点排在最后，但**不丢掉**', () async {
      await seedOne(
        env,
        id: 'a',
        primaryKp: 'math1.calc.limit.taylor',
        fsrsState: fsrsJson(stability: 2.0, daysAgo: 30, now: now),
      );
      await seedOne(env, id: 'b', primaryKp: 'math1.calc.deriv.rules');

      final report =
          await service().build(knowledge: kb, now: now, topKp: 10);
      expect(report.weakest.length, 2);
      expect(report.weakest.last.kpId, 'math1.calc.deriv.rules');
      expect(report.weakest.last.mastery, isNull);
    });

    test('weakness 公式就是文档里写的那一个', () {
      const kp = KpMastery(
        kpId: 'x',
        kpName: 'x',
        mastery: 0.25,
        wrongCount: 3,
      );
      // (1 − 0.25) × (1 + log2(1 + 3)) = 0.75 × 3 = 2.25
      expect(kp.weakness, closeTo(2.25, 1e-9));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  group('章节上卷', () {
    test('叶子数据上卷到章节，且各章题数之和等于总题数', () async {
      await seedOne(
        env,
        id: 'p-1',
        primaryKp: 'math1.calc.limit.taylor',
        wrongCount: 4,
        fsrsState: fsrsJson(stability: 2.0, daysAgo: 30, now: now),
      );
      await seedOne(
        env,
        id: 'p-2',
        primaryKp: 'math1.calc.deriv.rules',
        fsrsState: fsrsJson(stability: 50.0, daysAgo: 1, now: now),
      );
      // 没有主考点的题
      await seedOne(env, id: 'p-3');

      final report =
          await service().build(knowledge: kb, now: now, topKp: 10);

      final limit =
          report.chapters.firstWhere((c) => c.chapterId == 'math1.calc.limit');
      expect(limit.chapterName, '极限');
      expect(limit.problemCount, 1);
      expect(limit.wrongCount, 4);

      // 未标注的那一组要单独出现，且排在最后
      final unlabeled =
          report.chapters.where((c) => c.chapterId.isEmpty).toList();
      expect(unlabeled, hasLength(1));
      expect(unlabeled.single.chapterName, kUnlabeledChapterName);
      expect(report.chapters.last.chapterId, isEmpty);

      // 守恒：各章题数之和 == 总题数
      final sum =
          report.chapters.fold<int>(0, (n, c) => n + c.problemCount);
      expect(sum, report.totalProblems);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  group('错因分布', () {
    test('按题数降序，并翻成中文名', () async {
      const catalog = ErrorCauseCatalog(causes: [
        ErrorCause(
          id: 'sign',
          name: '符号错误',
          short: '符号',
          definition: '',
        ),
        ErrorCause(
          id: 'idea',
          name: '思路错误',
          short: '思路',
          definition: '',
        ),
      ]);
      await seedOne(env, id: 'p-1', errorCauses: ['sign', 'idea']);
      await seedOne(env, id: 'p-2', errorCauses: ['sign']);
      await seedOne(env, id: 'p-3', errorCauses: ['sign']);

      final report = await service(causes: catalog)
          .build(knowledge: kb, now: now, topKp: 10);

      expect(report.causes.first.causeId, 'sign');
      expect(report.causes.first.causeName, '符号错误');
      expect(report.causes.first.problemCount, 3);
      expect(report.causes[1].causeId, 'idea');
      expect(report.causes[1].problemCount, 1);
    });

    test('认不出的错因 id 显示 id 本身，不显示空白', () async {
      await seedOne(env, id: 'p-1', errorCauses: ['legacy_id']);
      final report = await service(causes: const ErrorCauseCatalog())
          .build(knowledge: kb, now: now, topKp: 10);
      expect(report.causes.single.causeName, 'legacy_id');
    });

    test('索引里错因列为空的题数要报出来（迁移后旧题就是这样）', () async {
      // schema v4 才加的列，旧行会一直是空的。一份只统计了新题的分布
      // 看起来有数据、实际是错的 —— 所以必须能提示"不完整"。
      await seedOne(env, id: 'p-1', errorCauses: ['sign']);
      await seedOne(env, id: 'p-2');
      await seedOne(env, id: 'p-3');

      final report =
          await service().build(knowledge: kb, now: now, topKp: 10);
      expect(report.missingCauseData, 2);
    });

    test('索引里的错因 JSON 坏掉不会让整张画像挂掉', () async {
      await env.db.into(env.db.problemsIndex).insert(
            ProblemsIndexCompanion.insert(
              id: 'bad',
              fingerprint: 'fp-bad',
              subject: 'math1',
              qtype: 'solve',
              filePath: 'problems/bad.md',
              stemText: '坏的',
              errorCauses: const Value('这不是 JSON'),
            ),
          );
      final report =
          await service().build(knowledge: kb, now: now, topKp: 10);
      expect(report.causes, isEmpty);
      expect(report.totalProblems, 1);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  group('掌握度曲线', () {
    Future<void> seedLog(DateTime at, int rating) => env.db
        .into(env.db.reviewLogs)
        .insert(ReviewLogsCompanion.insert(
          problemId: 'p-1',
          rating: rating,
          reviewedAt: Value(at),
        ));

    test('固定 30 个点，空白的天也留着', () async {
      await seedLog(DateTime(2024, 6, 8, 9), 4);
      await seedLog(DateTime(2024, 6, 10, 9), 1);

      final report =
          await service().build(knowledge: kb, now: now, topKp: 10);

      expect(report.trend, hasLength(kTrendDays));
      // 最后一天是"今天"
      expect(report.trend.last.day, DateTime(2024, 6, 10));
      expect(report.trend.last.reviews, 1);
      // 中间那天没有复习记录，但**留在序列里** ——
      // 去掉它会把"停了半个月"画成一条连续的线
      final emptyDay = report.trend
          .firstWhere((p) => p.day == DateTime(2024, 6, 9));
      expect(emptyDay.reviews, 0);
      expect(emptyDay.passRate, 0);
    });

    test('过关率是精确的 passed/reviews，不是从平均评分反推的', () async {
      // 一天里一次"忘了"(1) + 一次"轻松"(4)：平均评分 2.5，
      // 但真实过关率是 1/2。反推会得到 0.5 —— 巧合而已。
      // 换成三次"忘了" + 一次"轻松"：平均 1.75 → 反推 0.25，
      // 而真实过关率是 1/4 = 0.25 …… 也是巧合。
      // 所以直接用计数，不做任何反推。
      await seedLog(DateTime(2024, 6, 10, 9), 1);
      await seedLog(DateTime(2024, 6, 10, 10), 2);
      await seedLog(DateTime(2024, 6, 10, 11), 2);
      await seedLog(DateTime(2024, 6, 10, 12), 4);

      final report =
          await service().build(knowledge: kb, now: now, topKp: 10);
      final today = report.trend.last;

      expect(today.reviews, 4);
      expect(today.passed, 3);
      expect(today.passRate, closeTo(0.75, 1e-9));
      expect(today.avgRating, closeTo(2.25, 1e-9));
    });

    test('30 天之前的记录不进曲线', () async {
      await seedLog(DateTime(2024, 4, 1, 9), 4);
      final report =
          await service().build(knowledge: kb, now: now, topKp: 10);
      expect(report.trend.every((p) => p.reviews == 0), isTrue);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  group('总览与空态', () {
    test('空题库不崩，给出明确的空态', () async {
      final report =
          await service().build(knowledge: kb, now: now, topKp: 10);
      expect(report.isEmpty, isTrue);
      expect(report.weakest, isEmpty);
      expect(report.causes, isEmpty);
      expect(report.overallMastery, isNull);
      expect(report.overallText, contains('还没有复习记录'));
      expect(report.trend, hasLength(kTrendDays));
    });

    test('全局平均只统计有复习记录的题', () async {
      await seedOne(
        env,
        id: 'p-1',
        primaryKp: 'math1.calc.limit.taylor',
        fsrsState: fsrsJson(stability: 100.0, daysAgo: 1, now: now),
      );
      await seedOne(env, id: 'p-2', primaryKp: 'math1.calc.deriv.rules');
      await seedOne(env, id: 'p-3');

      final report =
          await service().build(knowledge: kb, now: now, topKp: 10);
      expect(report.totalProblems, 3);
      expect(report.reviewedProblems, 1);
      expect(report.newProblems, 2);
      expect(report.overallMastery, isNotNull);
    });

    test('顽固错题按"错 ≥3 次"计', () async {
      await seedOne(env, id: 'p-1', wrongCount: 3);
      await seedOne(env, id: 'p-2', wrongCount: 2);
      await seedOne(env, id: 'p-3', wrongCount: 9);

      final report =
          await service().build(knowledge: kb, now: now, topKp: 10);
      expect(report.stubbornProblems, 2);
      expect(kStubbornWrongThreshold, 3);
    });

    test('topKp 限制返回条数', () async {
      for (var i = 0; i < 5; i++) {
        await seedOne(
          env,
          id: 'p-$i',
          primaryKp: 'math1.calc.limit.taylor',
          fsrsState: fsrsJson(stability: 2.0, daysAgo: 30, now: now),
        );
      }
      await seedOne(
        env,
        id: 'q',
        primaryKp: 'math1.calc.deriv.rules',
        fsrsState: fsrsJson(stability: 2.0, daysAgo: 30, now: now),
      );
      final report =
          await service().build(knowledge: kb, now: now, topKp: 1);
      expect(report.weakest, hasLength(1));
    });
  });
}
