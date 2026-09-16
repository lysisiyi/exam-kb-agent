/// 全局依赖注入（Riverpod providers）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/database.dart';
import '../data/error_causes.dart';
import '../data/index/index_builder.dart';
import '../data/knowledge/knowledge_repository.dart';
import '../data/markdown/problem_store.dart';
import '../domain/fsrs/fsrs_scheduler.dart';
import '../domain/knowledge/knowledge_point.dart';
import '../domain/paper/paper_template.dart';
import '../features/problems/problems_page.dart' show ProblemView;
import '../services/library/problem_service.dart';
import '../services/llm/dio_http_adapter.dart';
import '../services/llm/llm_client.dart';
import '../services/llm/llm_settings.dart';
import '../services/llm/provider_registry.dart';
import '../services/paper/paper_repository.dart';
import '../services/profile/mastery_service.dart';
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
// 组卷
// ─────────────────────────────────────────────────────────────────────────────

/// 组卷数据层：模板载入、候选池、卷子持久化。
final paperRepositoryProvider = FutureProvider<PaperRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return PaperRepository(db: db);
});

/// 当前科目的组卷模板（键是 kind：`real_exam` / `quick_mock` / `wrong_only`）。
///
/// 返回 [PaperTemplatesResult] 而不是裸 Map：模板 JSON 损坏与
/// "这个科目没有模板"必须能分开，否则界面会把前者说成后者（见该类注释）。
final paperTemplatesProvider = FutureProvider.family<PaperTemplatesResult, String>(
        (ref, subject) async {
  final repo = await ref.watch(paperRepositoryProvider.future);
  return repo.templates(subject: subject);
});

/// 模板文件里的展示标签（难度/题型的中文名）。
final paperLabelsProvider = FutureProvider<PaperLabels>((ref) async {
  final repo = await ref.watch(paperRepositoryProvider.future);
  return repo.labels();
});

/// 已保存的卷子历史。
final paperHistoryProvider = FutureProvider<List<PaperRow>>((ref) async {
  final repo = await ref.watch(paperRepositoryProvider.future);
  return repo.history();
});

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
/// 5000 题时这一步约 100–140 ms（实测见 `test/list_perf_test.dart`），
/// 是**打开页签的一次性开销**，不在滚动路径上 ——
/// 列表本身是 `ListView.separated`，5000 题下同时存活的项只有 12–13 个。
final problemListProvider =
    FutureProvider.family<List<ProblemListRow>, ProblemView>((ref, view) async {
  final db = await ref.watch(databaseProvider.future);
  final t = db.problemsIndex;

  // ⚠️ **只取列表用得到的 8 列**，不要 `select(t).get()`。
  //
  // `problems_index` 里有两列很大、而列表一个字符都不用：
  // - `search_tokens`：逐字加空格的全文（CJK 分词产物），比 stem_text 大好几倍
  // - `parse_warnings`：解析期警告的 JSON
  //
  // 5000 题实测：全表读 51 ms，只取这 8 列 28 ms —— **省掉 45%**
  // （`test/list_perf_test.dart` 里有这条对比，改回全表会被它打印出来）。
  final q = db.selectOnly(t)
    ..addColumns([
      t.id,
      t.stemText,
      t.primaryKpName,
      t.difficulty,
      t.source,
      t.needsReview,
      t.aiTagged,
      t.createdAt,
    ]);

  final rows = await q.get();
  final states = await db.select(db.userProblemState).get();
  final byId = {for (final s in states) s.problemId: s};

  // 掌握度**读时重算**（T37）。整个列表用同一个 `now`，
  // 保证同一屏里各行的"此刻"是一致的 —— 逐行各自取 DateTime.now()
  // 会让相差几毫秒的行算在不同的时间点上（虽然差异极小，
  // 但"同一屏用同一个基准"是更干净的定义）。
  final now = DateTime.now();
  final scheduler = FsrsScheduler();

  final out = [
    for (final r in rows)
      ProblemListRow(
        problemId: r.read(t.id) ?? '',
        stemText: r.read(t.stemText) ?? '',
        primaryKpName: r.read(t.primaryKpName),
        difficulty: r.read(t.difficulty) ?? 2,
        source: r.read(t.source),
        needsReview: r.read(t.needsReview) ?? false,
        aiTagged: r.read(t.aiTagged) ?? false,
        createdAt: r.read(t.createdAt),
        state: byId[r.read(t.id)],
        mastery: masteryNowOf(byId[r.read(t.id)], scheduler, now) ?? 0,
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
      // ⚠️ 先把每道题的到期时间**算一次**存下来，再排序。
      //
      // 不要在比较器里直接调 `dueOfState`：那会对同一行反复做 JSON 解码，
      // 总次数是 O(n log n) 量级 —— 5000 道题约 25 万次解码，
      // 而这个排序要的只是一个整数的大小关系。由于 `dueQueueProvider`
      // 之外没人做去抖，这段代码就卡在"点一下待复习"那一下。
      final dueAt = <String, int>{
        for (final r in out)
          r.problemId: dueOfState(r.state)?.millisecondsSinceEpoch ?? 0,
      };

      // 新卡（没有 fsrs_state，记 0）永远算"待复习"，排在已安排的前面
      final cutoff = now.millisecondsSinceEpoch;
      final due = out
          .where((r) {
            final at = dueAt[r.problemId]!;
            return at == 0 || at <= cutoff;
          })
          .toList()
        ..sort((a, b) {
          final da = dueAt[a.problemId]!;
          final dbb = dueAt[b.problemId]!;
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
///
/// ## 为什么是 `autoDispose`
///
/// 它是按查询串分家的 family。用户敲「罗尔定理」是 4 个字符 ——
/// 不去抖的话每次按键都建一个实例，而**非 autoDispose 的 family 实例
/// 会一直留在容器里**：敲 20 个字符就攒下 20 份结果（每份最多 100 条
/// `SearchHit`），而且它们永远不会被用到第二次。
/// 加上去抖（见 `problems_page.dart`）之后，一次搜索通常只建 1 个实例，
/// 松手后立刻回收。
final problemSearchProvider = FutureProvider.autoDispose
    .family<List<SearchHit>, String>((ref, query) async {
  final q = query.trim();
  if (q.isEmpty) return const [];
  final db = await ref.watch(databaseProvider.future);
  return ProblemSearch(db).search(q, limit: 100);
});

// ─────────────────────────────────────────────────────────────────────────────
// 掌握度画像（F7）
// ─────────────────────────────────────────────────────────────────────────────

/// 画像服务。
///
/// ⚠️ 它**不缓存**报告，因为报告的全部价值就在于"说的是此刻的情况"。
/// 缓存一份 = 把 T37 那个"快照会过期"的问题换个地方重演。
/// 缓存在 provider 层（同一个 `now` 只算一次），重建时自然失效。
final masteryServiceProvider = FutureProvider<MasteryService>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  final catalog = await ref.watch(errorCauseCatalogProvider.future);
  return MasteryService(
    db: db,
    // 关掉 fuzzing：画像要的是可复现的数字，不是抖动的间隔
    scheduler: FsrsScheduler(enableFuzzing: false),
    causes: catalog,
  );
});

/// 一份画像报告。
///
/// 每次 `invalidate` 都重新算（打开页面 / 复习完一批之后）。
/// 它要读全表 + 逐题解 FSRS 状态，五千题量级约几十毫秒 ——
/// 与错题本列表是同一档开销，可以接受。
final masteryReportProvider = FutureProvider<MasteryReport>((ref) async {
  final svc = await ref.watch(masteryServiceProvider.future);
  final kb = await ref.watch(knowledgeBaseProvider.future);
  return svc.build(knowledge: kb);
});

// ─────────────────────────────────────────────────────────────────────────────
// AI 配置（BYOK）
// ─────────────────────────────────────────────────────────────────────────────

/// 当前 LLM 配置。未配置 / 解密失败时是 [LlmSettings.none]。
///
/// 抽成 provider 而不是每处各自 `LlmSettingsStore().load()`：
/// 批量导入页要**在选完文件后立刻**判断"当前模型能不能读图片"，
/// 而录入页的 AI 按钮也要读同一份配置。两处各读一次的话，
/// 用户在设置里改完模型，只有一部分界面会跟着变。
final llmSettingsProvider = FutureProvider<LlmSettings>((ref) async {
  return const LlmSettingsStore().load();
});

/// 配置完整到可以发请求时的 [LlmConfig]，否则 null。
///
/// ⚠️ 注意它**不判断视觉能力** —— 那是 `LlmConfig.visionSupport` 的事，
/// 用于标注与提炼之外的其他调用（如纯文本任务）也可能只需要"配置完整"。
final llmConfigProvider = Provider<LlmConfig?>((ref) {
  final s = ref.watch(llmSettingsProvider).valueOrNull;
  if (s == null || !s.isConfigured) return null;
  final cfg = s.toConfig();
  final (ok, _) = cfg.validate();
  return ok ? cfg : null;
});

/// 批量导入用的客户端。配置不可用时为 null。
///
/// 单独一个 provider（而不是复用标注引擎内部那个）是因为导入用的是
/// **视觉**接口，与标注的文本接口是两条路：能力要求不同，
/// 报错要给的建议也不同。
final ingestClientProvider = Provider<LlmClient?>((ref) {
  final cfg = ref.watch(llmConfigProvider);
  if (cfg == null) return null;
  // ⚠️ 必须自己拿着适配器实例才能在 provider 销毁时关掉它。
  // 写成 `LlmClient(http: DioHttpAdapter())` 的话那个 Dio 实例
  // 就没人引用了 —— `close()` 再也没有调用者，连接池只能等 GC。
  final adapter = DioHttpAdapter();
  ref.onDispose(adapter.close);
  return LlmClient(config: cfg, http: adapter);
});
