/// 全局依赖注入（Riverpod providers）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/database.dart';
import '../data/error_causes.dart';
import '../data/index/index_builder.dart';
import '../data/knowledge/knowledge_repository.dart';
import '../data/markdown/problem_store.dart';
import '../domain/knowledge/knowledge_point.dart';
import '../features/problems/problems_page.dart' show ProblemView;
import '../services/library/problem_service.dart';
import '../services/review/reminder_service.dart';
import '../services/review/review_repository.dart';

/// 当前选中的科目。
///
/// V1 先固定数学一；数二/数三的知识点编好后可通过 UI 切换。
final currentSubjectProvider = StateProvider<Subject>((ref) => Subject.math1);

/// 知识点本体仓库。
final knowledgeRepositoryProvider = Provider<KnowledgeRepository>(
  (ref) => KnowledgeRepository.instance,
);

/// 当前科目的知识点本体。异步载入，带缓存。
final knowledgeBaseProvider = FutureProvider<KnowledgeBase>((ref) async {
  final subject = ref.watch(currentSubjectProvider);
  return ref.watch(knowledgeRepositoryProvider).load(subject);
});

/// 已成功载入的全部科目（数二/数三可能尚未编好）。
final availableSubjectsProvider =
    FutureProvider<Map<Subject, KnowledgeBase>>((ref) async {
  return ref
      .watch(knowledgeRepositoryProvider)
      .loadAvailable(Subject.values);
});

/// 高频考点 Top N（按考频权重降序）。用于首页与组卷加权说明。
final topKnowledgePointsProvider =
    FutureProvider.family<List<KnowledgePoint>, int>((ref, limit) async {
  final kb = await ref.watch(knowledgeBaseProvider.future);
  return kb.leavesByWeight(limit: limit);
});

/// 当前知识点路径面包屑。
final knowledgePathProvider =
    Provider.family<List<KnowledgePoint>, String>((ref, id) {
  final kb = ref.watch(knowledgeBaseProvider).valueOrNull;
  if (kb == null) return const [];
  return kb.pathTo(id);
});

// ─────────────────────────────────────────────────────────────────────────────
// 题库（library）—— 录入闭环用的那一套
// ─────────────────────────────────────────────────────────────────────────────

/// 题库目录。首次访问时创建 `problems/` `images/` `index/` 等子目录。
final libraryPathsProvider = FutureProvider<LibraryPaths>(
  (ref) => LibraryPaths.resolve(),
);

/// 索引数据库（SQLite）。
///
/// 只存**用户状态与派生索引** —— 题目内容的事实源永远是 Markdown 文件。
/// 因此这个库整个删掉也不会丢数据，只会丢复习进度，
/// 而复习进度另有 `user_problem_state` 表保存。
final databaseProvider = FutureProvider<AppDatabase>((ref) async {
  final db = await openDefaultDatabase();
  // 应用退出时关掉，避免 Windows 上留下文件句柄
  ref.onDispose(db.close);
  return db;
});

/// 题目 Markdown 读写仓库。
final problemStoreProvider = FutureProvider<ProblemStore>((ref) async {
  final paths = await ref.watch(libraryPathsProvider.future);
  return ProblemStore(
    problemsDir: paths.problems,
    imagesDir: paths.images,
  );
});

/// 录入闭环服务。本体未载入时传 null（查重/索引依然可用，只是不校验知识点 id）。
final problemServiceProvider = FutureProvider<ProblemService>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  final store = await ref.watch(problemStoreProvider.future);
  final kb = ref.watch(knowledgeBaseProvider).valueOrNull;
  return ProblemService(db: db, store: store, knowledge: kb);
});

/// 错因受控词表。
final errorCauseCatalogProvider = FutureProvider<ErrorCauseCatalog>(
  (ref) => ErrorCauseRepository.instance.load(),
);

// ─────────────────────────────────────────────────────────────────────────────
// 复习（FSRS）
// ─────────────────────────────────────────────────────────────────────────────

/// 复习仓库：到期队列 + 打分 + 统计。
final reviewRepositoryProvider = FutureProvider<ReviewRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  final store = await ref.watch(problemStoreProvider.future);
  return ReviewRepository(db: db, store: store);
});

/// 复习总览（侧边栏角标、复习页顶部）。
final reviewStatsProvider = FutureProvider<ReviewStats>((ref) async {
  final repo = await ref.watch(reviewRepositoryProvider.future);
  return repo.stats();
});

/// 每日复习提醒。判断逻辑在 `ReminderService` 里，这里只负责装配。
final reminderServiceProvider = FutureProvider<ReminderService>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return ReminderService(db: db);
});

/// 到期队列。打开复习页时取一次。
///
/// 刻意**不**在这里 invalidate [reviewStatsProvider] —— 复习页自己会在
/// 载入完和每次打分后 invalidate。这个 provider 可能在 widget 构建期间
/// 被读取，在构建期间改动另一个 provider 会触发 Riverpod 的断言。
final dueQueueProvider = FutureProvider<List<DueCard>>((ref) async {
  final repo = await ref.watch(reviewRepositoryProvider.future);
  // 先对账：索引里有、状态表里没有的补建成新卡。
  // 放在这里而不是"保存时建卡"，是为了覆盖批量导入、手工拷贝 .md 等路径。
  await repo.ensureCards();
  return repo.dueQueue(limit: 30);
});

// ─────────────────────────────────────────────────────────────────────────────
// 错题本列表
// ─────────────────────────────────────────────────────────────────────────────

/// 错题本列表。按 [view] 排序/筛选取一次快照。
///
/// 刻意**不做**分页：个人错题本是几百到几千条量级，一次全读 + 排序
/// 比引入分页状态便宜得多，而且列表页的三种排序都要求全量。
final problemListProvider =
    FutureProvider.family<List<ProblemListRow>, ProblemView>((ref, view) async {
  final db = await ref.watch(databaseProvider.future);

  final rows = await db.select(db.problemsIndex).get();
  final states = await db.select(db.userProblemState).get();
  final byId = {for (final s in states) s.problemId: s};

  final out = [
    for (final r in rows)
      ProblemListRow(
        problemId: r.id,
        stemText: r.stemText,
        primaryKpName: r.primaryKpName,
        difficulty: r.difficulty,
        source: r.source,
        needsReview: r.needsReview,
        aiTagged: r.aiTagged,
        createdAt: r.createdAt,
        state: byId[r.id],
      ),
  ];

  switch (view) {
    case ProblemView.recent:
      out.sort((a, b) {
        final ca = a.createdAt?.millisecondsSinceEpoch ?? 0;
        final cb = b.createdAt?.millisecondsSinceEpoch ?? 0;
        final byTime = cb.compareTo(ca);
        return byTime != 0 ? byTime : a.problemId.compareTo(b.problemId);
      });
    case ProblemView.mostWrong:
      out.sort((a, b) {
        final byWrong = b.wrongCount.compareTo(a.wrongCount);
        return byWrong != 0 ? byWrong : a.problemId.compareTo(b.problemId);
      });
    case ProblemView.due:
      final now = DateTime.now();
      // 新卡（没有 fsrs_state）永远算"待复习"，排在已安排的前面
      final due = out.where((r) {
        final at = dueOfState(r.state);
        return at == null || !at.isAfter(now);
      }).toList()
        ..sort((a, b) {
          final da = dueOfState(a.state)?.millisecondsSinceEpoch ?? 0;
          final dbb = dueOfState(b.state)?.millisecondsSinceEpoch ?? 0;
          if (da == 0 && dbb != 0) return -1;
          if (da != 0 && dbb == 0) return 1;
          final byDue = da.compareTo(dbb);
          return byDue != 0 ? byDue : a.problemId.compareTo(b.problemId);
        });
      return due;
  }

  return out;
});

/// FTS5 全文检索。空查询返回空列表（调用方负责别搜空串）。
final problemSearchProvider =
    FutureProvider.family<List<SearchHit>, String>((ref, query) async {
  final q = query.trim();
  if (q.isEmpty) return const [];
  final db = await ref.watch(databaseProvider.future);
  return ProblemSearch(db).search(q, limit: 100);
});
