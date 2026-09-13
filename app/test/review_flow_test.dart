/// 复习链路测试：`ReviewRepository` + 复习页。
///
/// ## 这个文件守的是什么
///
/// FSRS 算法本身有 `fsrs_scheduler_test.dart` 保着，那一层是纯函数。
/// 这一层要守的是**落地**：到期队列怎么排、打分怎么写回状态行、
/// 复习日志有没有留、卡片对账会不会重复建卡。
///
/// 其中有一条是上一版的真实缺陷：`user_problem_state` 当初漏了主键，
/// 于是 `insertOnConflictUpdate` 没有冲突目标可用 —— 同一道题会写出两条
/// FSRS 状态，复习队列里出现重复卡片。下面用"连续两次打分"直接盯住它。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/layout/breakpoints.dart';
import 'package:kaoyan_math_agent/core/providers.dart';
import 'package:kaoyan_math_agent/domain/fsrs/fsrs_scheduler.dart';
import 'package:kaoyan_math_agent/features/review/review_page.dart';
import 'package:kaoyan_math_agent/services/review/review_repository.dart';

import 'support/test_env.dart';

void main() {
  late TempLibrary env;
  late ReviewRepository repo;

  setUp(() async {
    env = await TempLibrary.create();
    repo = ReviewRepository(db: env.db, store: env.store);
  });

  tearDown(() => env.dispose());

  // ───────────────────────────────────────────────────────────────────────────
  group('卡片对账（ensureCards）', () {
    test('索引里有、状态表里没有的题会被补建成新卡', () async {
      final report = await seedProblems(env, [
        const SeedProblem(
          id: 'p-1',
          stem: r'求 $\lim_{x\to0}\frac{\sin x}{x}$',
          answer: r'$1$',
          wrongCount: null, // 只有题目，没有状态行
        ),
        const SeedProblem(id: 'p-2', stem: '第二题', wrongCount: null),
      ]);
      expect(report.isClean, isTrue, reason: report.summary);

      expect(await env.db.select(env.db.userProblemState).get(), isEmpty);

      final created = await repo.ensureCards();
      expect(created, 2);

      final states = await env.db.select(env.db.userProblemState).get();
      expect(states.length, 2);
      // 新建的卡必须是**新卡**：fsrs_state 留空，而不是写一个空对象
      expect(states.every((s) => s.fsrsState == null), isTrue);
    });

    test('对账是幂等的：跑两次不会多出卡片', () async {
      await seedProblems(env, [
        const SeedProblem(id: 'p-1', stem: '第一题', wrongCount: null),
      ]);

      expect(await repo.ensureCards(), 1);
      expect(await repo.ensureCards(), 0, reason: '第二次不该再建卡');
      expect((await env.db.select(env.db.userProblemState).get()).length, 1);
    });

    test('已有状态行的题不会被覆盖', () async {
      await seedProblems(env, [
        const SeedProblem(id: 'p-1', stem: '第一题', wrongCount: 7),
      ]);

      expect(await repo.ensureCards(), 0);
      final s = (await env.db.select(env.db.userProblemState).get()).single;
      expect(s.wrongCount, 7, reason: '对账不该改已有状态');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('到期队列', () {
    test('逾期最久的排在新卡前面', () async {
      final now = DateTime(2024, 6, 1, 9);
      await seedProblems(env, [
        // 新卡（没有 fsrs 状态）
        const SeedProblem(id: 'p-new', stem: '新卡', wrongCount: 1),
        // 逾期 10 天
        SeedProblem(
          id: 'p-overdue',
          stem: '逾期卡',
          card: FsrsCard(
            due: now.subtract(const Duration(days: 10)),
            stability: 5,
            difficulty: 5,
            reps: 3,
            lapses: 0,
            state: CardState.review,
          ),
        ),
        // 逾期 2 天
        SeedProblem(
          id: 'p-soon',
          stem: '刚到期',
          card: FsrsCard(
            due: now.subtract(const Duration(days: 2)),
            stability: 5,
            difficulty: 5,
            reps: 3,
            lapses: 0,
            state: CardState.review,
          ),
        ),
        // 还没到期（不该进队列）
        SeedProblem(
          id: 'p-future',
          stem: '还没到',
          card: FsrsCard(
            due: now.add(const Duration(days: 30)),
            stability: 5,
            difficulty: 5,
            reps: 3,
            lapses: 0,
            state: CardState.review,
          ),
        ),
      ]);

      final queue = await repo.dueQueue(now: now);
      expect(queue.map((c) => c.problemId).toList(),
          ['p-overdue', 'p-soon', 'p-new']);
      expect(queue.where((c) => c.problemId == 'p-future'), isEmpty);

      // 逾期天数算对了（队列顺序之外，UI 上要显示这个数）
      expect(queue.first.overdueDays(now), 10);
      expect(queue.last.isNew, isTrue);
    });

    test('队列会读出题干内容（Markdown 是事实源）', () async {
      await seedProblems(env, [
        const SeedProblem(
          id: 'p-1',
          stem: r'求 $\lim_{x\to0}\frac{\sin x}{x}$',
          answer: r'$1$',
          solution: '用等价无穷小。',
        ),
      ]);

      final queue = await repo.dueQueue();
      expect(queue.single.problem, isNotNull);
      expect(queue.single.problem!.answer, r'$1$');
      expect(queue.single.problem!.solution, '用等价无穷小。');
      expect(queue.single.loadError, isNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('打分', () {
    test('「忘了」会让错误次数 +1，并排到最短的间隔', () async {
      await seedProblems(env, [
        const SeedProblem(id: 'p-1', stem: '第一题', wrongCount: 1),
      ]);

      final now = DateTime(2024, 6, 1, 9);
      final r = await repo.grade(
        problemId: 'p-1',
        rating: Rating.forgot,
        elapsedMs: 4200,
        now: now,
      );

      expect(r.wrongCount, 2);
      expect(r.nextDue.isAfter(now), isTrue);
      // 第一次「忘了」走的是**学习步**（分钟级），不是天级间隔 ——
      // 所以这里断言"排到了未来"，而不是硬要求 >= 1 天
      expect(r.nextDue.difference(now).inMinutes, greaterThanOrEqualTo(1));
      expect(r.mastery, inInclusiveRange(0, 1));

      final s = (await env.db.select(env.db.userProblemState).get()).single;
      expect(s.wrongCount, 2);
      expect(s.fsrsState, isNotNull);
      expect(s.lastWrong, isNotNull);
    });

    test('做出来了就不算错：吃力/轻松不加错误次数', () async {
      await seedProblems(env, [
        const SeedProblem(id: 'p-1', stem: '第一题', wrongCount: 3),
      ]);

      final hard = await repo.grade(problemId: 'p-1', rating: Rating.hard);
      expect(hard.wrongCount, 3, reason: '做出来了是进展，不该计错');

      final easy = await repo.grade(problemId: 'p-1', rating: Rating.easy);
      expect(easy.wrongCount, 3);
      // 第一轮可能都落在学习步（分钟级），此时两天数都是 0；
      // 只要求"轻松不比吃力更早"
      expect(easy.nextDue.isBefore(hard.nextDue), isFalse,
          reason: '「轻松」的下次到期不该早于「吃力」');
    });

    test('每次打分都留一条复习日志', () async {
      await seedProblems(env, [
        const SeedProblem(id: 'p-1', stem: '第一题', wrongCount: 1),
      ]);

      await repo.grade(problemId: 'p-1', rating: Rating.forgot, elapsedMs: 9000);
      await repo.grade(problemId: 'p-1', rating: Rating.easy, elapsedMs: 3000);

      final logs = await env.db.select(env.db.reviewLogs).get();
      expect(logs.length, 2);
      expect(logs.map((l) => l.rating).toList(), [1, 4]);
      expect(logs.first.elapsedMs, 9000);
      // 快照字段是将来跑优化器的输入，不能是空的
      expect(logs.every((l) => l.stabilityAfter != null), isTrue);
      expect(logs.every((l) => l.difficultyAfter != null), isTrue);
    });

    test('连续打分不会写出重复状态行（主键回归）', () async {
      await seedProblems(env, [
        const SeedProblem(id: 'p-1', stem: '第一题', wrongCount: 1),
      ]);

      // 模拟用户连点：这两次写入之间没有"先查再写"的窗口
      await Future.wait([
        repo.grade(problemId: 'p-1', rating: Rating.easy),
        repo.grade(problemId: 'p-1', rating: Rating.hard),
      ]);

      final states = await env.db.select(env.db.userProblemState).get();
      expect(states.length, 1,
          reason: '同一道题出现多条状态行 → 复习队列会出现重复卡片');
      expect(states.single.problemId, 'p-1');
    });

    test('新卡（没有状态行）也能直接打分', () async {
      await seedProblems(env, [
        const SeedProblem(id: 'p-1', stem: '第一题', wrongCount: null),
      ]);

      final r = await repo.grade(problemId: 'p-1', rating: Rating.easy);
      expect(r.wrongCount, 0, reason: '新卡第一次做对了，不该凭空多一次错');
      expect((await env.db.select(env.db.userProblemState).get()).length, 1);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('统计', () {
    test('新卡计入 dueNow，未来 7 天分布按 due 落桶', () async {
      final now = DateTime(2024, 6, 1, 9);
      await seedProblems(env, [
        const SeedProblem(id: 'p-new', stem: '新卡', wrongCount: 1),
        SeedProblem(
          id: 'p-today',
          stem: '今天到期',
          card: FsrsCard(
            due: now.subtract(const Duration(hours: 1)),
            stability: 5,
            difficulty: 5,
            reps: 2,
            lapses: 0,
            state: CardState.review,
          ),
        ),
        SeedProblem(
          id: 'p-3d',
          stem: '3 天后',
          card: FsrsCard(
            due: now.add(const Duration(days: 3)),
            stability: 5,
            difficulty: 5,
            reps: 2,
            lapses: 0,
            state: CardState.review,
          ),
        ),
        SeedProblem(
          id: 'p-30d',
          stem: '一个月后',
          card: FsrsCard(
            due: now.add(const Duration(days: 30)),
            stability: 5,
            difficulty: 5,
            reps: 2,
            lapses: 0,
            state: CardState.review,
          ),
        ),
      ]);

      final s = await repo.stats(now: now);
      expect(s.totalCards, 4);
      expect(s.newCards, 1);
      expect(s.dueNow, 2, reason: '新卡 + 今天到期');
      expect(s.upcoming.length, 7);
      expect(s.upcoming[0], greaterThanOrEqualTo(2), reason: '今天这一桶应有新卡');
      expect(s.upcoming[3], 1);
      expect(s.upcoming.reduce((a, b) => a + b), lessThan(4),
          reason: '30 天后的卡不该出现在 7 天分布里');
    });

    test('今天复习过的次数会被统计到', () async {
      await seedProblems(env, [
        const SeedProblem(id: 'p-1', stem: '第一题', wrongCount: 1),
      ]);
      expect((await repo.stats()).reviewedToday, 0);

      await repo.grade(problemId: 'p-1', rating: Rating.easy);
      expect((await repo.stats()).reviewedToday, 1);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('到期文案', () {
    test('describeDue 覆盖逾期 / 小时内 / 天后 / 月', () {
      final now = DateTime(2024, 6, 10, 12);
      expect(describeDue(null, now: now), '未安排');
      expect(describeDue(DateTime(2024, 6, 7), now: now), '已逾期 3 天');
      // 今天已过点 = 已到期
      expect(describeDue(DateTime(2024, 6, 10, 8), now: now), '已到期');
      // 不足 24 小时 → 说小时（跨零点的"明天早上"也走这一档，更精确）
      expect(describeDue(DateTime(2024, 6, 11), now: now), '12 小时后');
      // 日级分支
      expect(describeDue(DateTime(2024, 6, 12), now: now), '2 天后');
      expect(describeDue(DateTime(2024, 6, 16), now: now), '6 天后');
      expect(describeDue(DateTime(2024, 9, 10), now: now), '3 个月后');
    });

    test('分钟级间隔要说分钟 —— 说"今天"等于让人别管它', () {
      // FSRS 第一次评"忘了"会把下次排在 10 分钟后。若显示"今天"，
      // 用户会以为今天不用再看了，正好把刚安排的学习步抹掉。
      final now = DateTime(2024, 6, 10, 12, 0);
      expect(describeDue(DateTime(2024, 6, 10, 12, 10), now: now), '10 分钟后');
      expect(describeDue(DateTime(2024, 6, 10, 12, 0), now: now), '0 分钟后');
    });

    test('小时级间隔说小时，并说清是"今天"还是"明天"', () {
      final now = DateTime(2024, 6, 10, 12, 0);
      expect(describeDue(DateTime(2024, 6, 10, 18), now: now), '6 小时后');
      // 跨零点的卡：23:50 做完，下次 00:00 —— 那是明天，不是"今天"
      final late = DateTime(2024, 6, 10, 23, 50);
      expect(describeDue(DateTime(2024, 6, 11, 0, 30), now: late), '40 分钟后');
    });

    test('刚过期不说"已逾期 0 天"', () {
      final now = DateTime(2024, 6, 10, 12, 0);
      expect(describeDue(DateTime(2024, 6, 10, 11, 59), now: now), '已到期');
      expect(describeDue(DateTime(2024, 6, 9, 12, 0), now: now), '已逾期 1 天');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('复习页', () {
    // ⚠️ 这一组里的每一步真实 IO 都必须走 `tester.runAsync`。
    //
    // `testWidgets` 的函数体跑在**假异步时钟**里：`Directory.createTemp`、
    // 文件读写、sqlite 查询这些依赖真实事件循环的 Future **永远不会完成**，
    // 于是测试会在第一行 `await` 上静静挂住（10 分钟后报超时）。
    // 仓库层的 `test()` 不受影响 —— 它们不在假时钟里，所以上面那些用例
    // 可以直接 `await seedProblems(...)`。
    late TempLibrary env;

    /// 在假时钟里建临时库并种数据。
    Future<void> seedInAsync(WidgetTester tester, List<SeedProblem> seeds) async {
      await tester.runAsync(() async {
        env = await TempLibrary.create();
        await seedProblems(env, seeds);
      });
      addTearDown(() async {
        await tester.runAsync(env.dispose);
      });
    }

    /// 挂真实的 `ReviewPage`，数据源换成临时库。
    ///
    /// ## 为什么必须 `runAsync` + 手动 pump
    ///
    /// 同上的原因：复习页载入时要读 Markdown 文件。`pumpAndSettle` 在这里
    /// 也永远等不到（载入期间是无限动画的进度指示器），所以改成
    /// "`runAsync` 让真实事件循环跑一会儿 → `pump` 让界面重建"的交替循环。
    Future<void> pumpReview(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWith((ref) async => env.db),
            problemStoreProvider.overrideWith((ref) async => env.store),
          ],
          // 复习页按断点决定内边距，所以必须有 ResponsiveScope ——
          // 生产里由 AdaptiveShell 提供，测试里要自己包一层
          child: ResponsiveScope(
            builder: (context, bp) =>
                const MaterialApp(home: Scaffold(body: ReviewPage())),
          ),
        ),
      );

      for (var i = 0; i < 30; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
        if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
      }
      fail('复习页载入没有完成 —— 30 轮 runAsync 后还在转圈');
    }

    /// 有界 settle：交互之后推进若干帧（不用 `pumpAndSettle`，理由同上）。
    Future<void> settle(WidgetTester tester, {int frames = 8}) async {
      for (var i = 0; i < frames; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    testWidgets('答案默认隐藏，揭晓后才出现', (tester) async {
      await seedInAsync(tester, [
        const SeedProblem(
          id: 'p-1',
          stem: '求极限',
          answer: r'$1$',
          solution: '等价无穷小。',
        ),
      ]);

      await pumpReview(tester);

      expect(find.text('求极限'), findsOneWidget);
      expect(find.text('答案与解析已隐藏'), findsOneWidget);
      expect(find.text('揭晓答案'), findsOneWidget);
      expect(find.textContaining('等价无穷小'), findsNothing,
          reason: '没揭晓就泄漏答案，复习就失去意义了');
      // 三档打分不该在揭晓前出现
      expect(find.text('忘了'), findsNothing);

      await tester.tap(find.text('揭晓答案'));
      await settle(tester);

      expect(find.text('答案与解析已隐藏'), findsNothing);
      expect(find.text('忘了'), findsOneWidget);
      expect(find.text('吃力'), findsOneWidget);
      expect(find.text('轻松'), findsOneWidget);
    });

    testWidgets('打分推进到下一题，并写下 FSRS 状态', (tester) async {
      await seedInAsync(tester, [
        const SeedProblem(id: 'p-1', stem: '第一题题干', answer: 'A1'),
        const SeedProblem(id: 'p-2', stem: '第二题题干', answer: 'A2'),
      ]);

      await pumpReview(tester);
      expect(find.text('第一题题干'), findsOneWidget);

      await tester.tap(find.text('揭晓答案'));
      await settle(tester);
      await tester.tap(find.text('轻松'));
      await settle(tester);

      // 进到第二题
      expect(find.text('第二题题干'), findsOneWidget);
      expect(find.text('第一题题干'), findsNothing);

      // 状态真的写下去了
      final s = await tester.runAsync(() async =>
          (env.db.select(env.db.userProblemState)
                ..where((t) => t.problemId.equals('p-1')))
              .getSingle());
      expect(s!.fsrsState, isNotNull);
      final logs = await tester
          .runAsync(() async => env.db.select(env.db.reviewLogs).get());
      expect(logs!.length, 1);
    });

    testWidgets('队列为空时给出空态而不是空白页', (tester) async {
      await seedInAsync(tester, const []);

      await pumpReview(tester);

      // 一张卡都没有时说的是"错题本还是空的"，而不是"今天做完了" ——
      // 对着空白卡片说"做完了"会让人以为复习功能坏了
      expect(find.text('错题本还是空的'), findsOneWidget);
      expect(find.text('今天的复习做完了'), findsNothing);
      expect(find.text('重新检查'), findsOneWidget);
    });

    testWidgets('有卡但都不到期时说明下次什么时候来', (tester) async {
      final now = DateTime.now();
      await seedInAsync(tester, [
        SeedProblem(
          id: 'p-later',
          stem: '一个月后才复习',
          card: FsrsCard(
            due: now.add(const Duration(days: 30)),
            stability: 20,
            difficulty: 5,
            reps: 4,
            lapses: 0,
            state: CardState.review,
          ),
        ),
      ]);

      await pumpReview(tester);

      expect(find.text('今天的复习做完了'), findsOneWidget);
      // 用户真正想知道的是"什么时候再来"
      expect(find.textContaining('下次'), findsOneWidget);
    });

    testWidgets('跳过的题不写状态，也不进日志', (tester) async {
      await seedInAsync(tester, [
        const SeedProblem(id: 'p-1', stem: '第一题题干'),
        const SeedProblem(id: 'p-2', stem: '第二题题干'),
      ]);

      await pumpReview(tester);
      await tester.tap(find.text('跳过这题'));
      await settle(tester);

      expect(find.text('第二题题干'), findsOneWidget);
      final logs = await tester
          .runAsync(() async => env.db.select(env.db.reviewLogs).get());
      expect(logs, isEmpty);
      final states = await tester.runAsync(
          () async => env.db.select(env.db.userProblemState).get());
      expect(states!.every((s) => s.fsrsState == null), isTrue,
          reason: '跳过不该改 FSRS 状态');
    });
  });
}
