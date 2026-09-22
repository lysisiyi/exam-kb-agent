/// 全局依赖注入（Riverpod providers）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform/startup_log.dart';
import '../data/db/database.dart';
import '../data/error_causes.dart';
import '../data/index/index_builder.dart';
import '../data/knowledge/knowledge_repository.dart';
import '../data/markdown/problem_store.dart';
import '../domain/fsrs/fsrs_scheduler.dart';
import '../domain/knowledge/knowledge_point.dart';
import '../domain/paper/paper_template.dart';
import '../features/chat/chat_prompt.dart';
import '../features/problems/problems_page.dart' show ProblemView;
import '../services/chat/chat_agent.dart';
import '../services/chat/chat_store.dart';
import '../services/chat/chat_tools.dart';
import '../services/chat/chat_writes.dart';
import '../services/library/problem_service.dart';
import '../services/llm/dio_http_adapter.dart';
import '../services/llm/llm_client.dart';
import '../services/llm/llm_settings.dart';
import '../services/llm/provider_registry.dart';
import '../services/paper/paper_repository.dart';
import '../services/profile/mastery_service.dart';
import '../services/review/reminder_service.dart';
import '../services/review/review_repository.dart';
import '../services/tagger/knowledge_recall.dart';
import '../services/tagger/tag_cache_store.dart';

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

/// 知识点召回器。
///
/// ## 为什么必须按本体缓存，而不是每题 new 一个
///
/// [KnowledgeRecall] 的构造函数要遍历全部叶子（数一 200+）预计算 IDF、
/// 公式分词与别名索引 —— 那是刻意的（它自己的注释写着"召回是热点路径"）。
/// 早先 `KnowledgeTagger` 就是在 `tag()` 里面 new 的，于是"预计算"退化成
/// "每题算一遍"（见 `knowledge_tagger.dart` 的 `_recall` 注释）。
/// 这里同样把它挂在本体上：本体不换，召回器不重建。
///
/// ## 界面侧用它做什么
///
/// 「AI 为什么这么判」面板拿它做**实时重算**：召回是纯规则、不含 LLM、
/// 毫秒级，所以随时重算既免费又确定 —— 这正是召回层当初被设计成规则
/// 而非 LLM 的理由之一（可解释、可复算）。
final knowledgeRecallProvider = FutureProvider<KnowledgeRecall>((ref) async {
  final kb = await ref.watch(knowledgeBaseProvider.future);
  return KnowledgeRecall(knowledge: kb);
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

/// 启动时增量同步索引：把**外部直接放进题库目录**的 md 文件收进库。
///
/// 为什么需要：`rebuild()` 只在保存/导入后被调用，而题库目录是**事实源**
/// —— 用户（或转换工具）往 `problems/` 里放文件，重启后必须能看到。
/// 增量按 mtime 跳过已同步文件，200 题的库全程毫秒级。
///
/// **刻意不阻塞启动**：DevShell watch 到它才开始跑；失败只记日志 ——
/// md 是事实源，索引随时可以重建。测试里如果不想碰真实文件系统，
/// override 这个 provider 为 `AsyncValue.data(null)` 即可。
final startupIndexSyncProvider = FutureProvider<IndexReport?>((ref) async {
  try {
    final db = await ref.watch(databaseProvider.future);
    final store = await ref.watch(problemStoreProvider.future);
    final kb = ref.watch(knowledgeBaseProvider).valueOrNull;
    final report =
        await IndexBuilder(db: db, store: store, knowledge: kb).rebuild();
    if (report.added > 0 || report.updated > 0 || report.removed > 0) {
      StartupLog.log('启动索引同步：新增 ${report.added} / 更新 '
          '${report.updated} / 移除 ${report.removed}（失败 ${report.failed}）');
    }
    return report;
  } catch (e) {
    StartupLog.log('启动索引同步失败（不阻断启动）：$e');
    return null;
  }
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
  // 词表用于"错因对症"这一维（见 PaperRepository.drillCauseIds）。
  // 加载失败退化成 empty，那时组卷行为与引入该维度之前完全一致。
  final causes = await ref.watch(errorCauseCatalogProvider.future);
  return PaperRepository(db: db, causes: causes);
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
  // 错因词表只用于**队列的次序修正**（见 ReviewRepository.causes）。
  // 它加载失败会退化成 empty，那时排序等同于该维度引入之前 —— 不会报错。
  final causes = await ref.watch(errorCauseCatalogProvider.future);
  return ReviewRepository(db: db, store: store, causes: causes);
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

/// 对话助手用的客户端。配置不可用时为 null。
///
/// ## 为什么与 [ingestClientProvider] 分开
///
/// 两者的**能力要求不同**：导入走视觉接口（要发图 / PDF），
/// 对话走纯文本 + 流式 + 多轮。合成一个的话，
/// 任何一边加参数都会牵连另一边 —— 而它们的失效方式完全不一样
/// （导入发错可以重试，对话吐了一半就不能重试了）。
///
/// ## 用量为什么在这里接，而不是像导入那样在页面里建客户端
///
/// 对话是**多轮、多会话**的，调用点会散落在重试、续聊、历史回看各处。
/// 挂在客户端上就不会漏 —— 每一轮真实调用各记一条，
/// 与 `tables.dart` 里"这张表的行数就是真实调用次数"那句一致。
///
/// ⚠️ 流式下部分服务商不返回用量，那些轮次会记成 0 token
/// （行数仍然准确）。详见 `LlmClient.chatStream` 的方法头。
final chatClientProvider = Provider<LlmClient?>((ref) {
  final cfg = ref.watch(llmConfigProvider);
  if (cfg == null) return null;

  final adapter = DioHttpAdapter();
  ref.onDispose(adapter.close);

  return LlmClient(
    config: cfg,
    http: adapter,
    onUsage: (usage) {
      // 记账是旁路：写不进去也绝不能影响用户已经看到的回复。
      // 所以这里不 await、失败就丢 —— 少一条账远好过对话崩掉。
      try {
        ref
            .read(databaseProvider.future)
            .then((db) => UsageLedger(db).record(
                  provider: cfg.providerId,
                  usage: usage,
                  purpose: 'chat',
                ))
            .ignore();
      } catch (_) {
        // 见上
      }
    },
  );
});

/// 对话记录仓。
final chatStoreProvider = FutureProvider<ChatStore>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return ChatStore(db);
});

// ─────────────────────────────────────────────────────────────────────────────
// 对话助手的工具（P2 只读 + P3 提议写操作）
// ─────────────────────────────────────────────────────────────────────────────

/// 助手能调用的工具集合。
///
/// ## 这里为什么只有数据库是"现在就取"的
///
/// 其余依赖（题目仓库、复习仓库、画像服务、知识点本体）都传**加载函数**，
/// 真正的解析发生在某个工具第一次要用它时。理由见 `chat_tools.dart`
/// 文件头那份说明 —— 一句话：大部分对话用不到它们，而它们都不便宜。
///
/// 副作用是这一层变得很轻：唯一的真实依赖是数据库，而它在测试里
/// 向来被换成内存库。于是页面测试不需要额外搭一套文件系统。
///
/// ## 写工具在这里、写入能力不在这里
///
/// 下面有四个"写"工具，但它们的 `run` 一步都不写库 —— 只产出提案。
/// 真正的写入在 [chatWriteExecutorProvider]，**只有界面上的「确认」按钮
/// 会读它**。这个 provider 交给模型的东西里没有任何一条能改数据。
final chatToolsProvider = FutureProvider<ChatToolRegistry>((ref) async {
  final db = await ref.watch(databaseProvider.future);

  /// 拿本体；失败返回 null（而不是抛）。
  ///
  /// 见 [KnowledgeLoader]：本体坏了的时候，工具仍应能用，
  /// 只是考点名退化成 id。
  Future<KnowledgeBase?> kbOrNull() async {
    try {
      return await ref.read(knowledgeBaseProvider.future);
    } catch (_) {
      return null;
    }
  }

  /// 错因词表；失败返回 null（显示时退化成 id）。
  Future<ErrorCauseCatalog?> causesOrNull() async {
    try {
      return await ref.read(errorCauseCatalogProvider.future);
    } catch (_) {
      return null;
    }
  }

  /// 录入服务。**这里不用 `problemServiceProvider`** —— 那个 provider 在
  /// 构造时用 `valueOrNull` 取本体，本体还没载入时它会永久持有一个
  /// `knowledge == null` 的实例，于是保存时不再校验考点 id、
  /// 索引也不会写上 `primary_kp_name`。写操作值得多一次 await。
  Future<ProblemService> loadProblemService() async {
    final store = await ref.read(problemStoreProvider.future);
    return ProblemService(db: db, store: store, knowledge: await kbOrNull());
  }

  return ChatToolRegistry([
    // 只读
    WrongProblemsTool(db),
    GetProblemTool(
      db: db,
      loadStore: () => ref.read(problemStoreProvider.future),
      loadKnowledge: kbOrNull,
    ),
    KnowledgePointsTool(() => ref.read(knowledgeBaseProvider.future)),
    ProfileTool(
      loadService: () => ref.read(masteryServiceProvider.future),
      loadKnowledge: () => ref.read(knowledgeBaseProvider.future),
    ),
    DueReviewTool(
      loadRepo: () => ref.read(reviewRepositoryProvider.future),
      loadKnowledge: kbOrNull,
    ),
    // 写（只提议，不落库）
    CreateProblemTool(
      loadService: loadProblemService,
      loadKnowledge: kbOrNull,
      loadCauses: causesOrNull,
    ),
    UpdateProblemTool(
      loadService: loadProblemService,
      loadKnowledge: kbOrNull,
      loadCauses: causesOrNull,
    ),
    DeleteProblemTool(
      loadService: loadProblemService,
      loadKnowledge: kbOrNull,
    ),
    ComposePaperTool(
      loadService: loadProblemService,
      loadPaper: () => ref.read(paperRepositoryProvider.future),
    ),
  ]);
});

/// 写操作的执行器。**只在用户点了确认之后被调用。**
///
/// 它与 [chatToolsProvider] 刻意分开，是为了让"模型能碰到的东西"与
/// "能改数据的东西"在代码上也是两样东西 —— 前者是工具，后者是这个。
/// 页面拿得到它，模型拿不到。
final chatWriteExecutorProvider = FutureProvider<ChatWriteExecutor>((ref) async {
  final db = await ref.watch(databaseProvider.future);

  Future<KnowledgeBase?> kbOrNull() async {
    try {
      return await ref.read(knowledgeBaseProvider.future);
    } catch (_) {
      return null;
    }
  }

  Future<ErrorCauseCatalog?> causesOrNull() async {
    try {
      return await ref.read(errorCauseCatalogProvider.future);
    } catch (_) {
      return null;
    }
  }

  return ChatWriteExecutor(
    loadService: () async {
      final store = await ref.read(problemStoreProvider.future);
      return ProblemService(db: db, store: store, knowledge: await kbOrNull());
    },
    loadKnowledge: kbOrNull,
    loadPaper: () => ref.read(paperRepositoryProvider.future),
    loadCauses: causesOrNull,
  );
});

/// 对话助手的工具循环。
///
/// ## 服务商不支持工具时不是"报错"，而是"没有工具"
///
/// `tools` 为空时，这个循环的行为与 P1 的纯聊天**完全一致**
/// （请求体里不会出现 `tools` 字段）。这样页面只需要一条代码路径，
/// 而不是"支持工具时走这套、不支持时走那套" —— 后者必然有一半
/// 长期没人跑，坏掉也发现不了。
///
/// 代价是用户看不出"这个服务商用不了工具"，所以页面上要**单独说**
/// 这件事（见对话页顶部的能力说明），而不是靠这里静默降级。
final chatAgentProvider = FutureProvider<ChatAgent?>((ref) async {
  final client = ref.watch(chatClientProvider);
  if (client == null) return null;

  final registry = await ref.watch(chatToolsProvider.future);
  // P4 起三家协议都能传工具；supportsTools 为假只剩"服务商 id 不认识"
  // 一种情形。在这里清空而不是让请求层抛异常：配置残缺时对话
  // 至少还能聊天，不至于整页不可用。
  final withTools = client.supportsTools;
  return ChatAgent(
    client: client,
    tools: withTools ? registry : ChatToolRegistry.empty,
    // ⚠️ 提示词必须与"真的有没有传 tools"一致。
    // 不一致的话模型会假装自己查过（见 `chat_prompt.dart` 的文件头）。
    system: chatSystemPrompt(withTools: withTools),
  );
});
