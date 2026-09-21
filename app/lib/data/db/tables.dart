/// Drift 数据库 schema。
///
/// ## 数据架构（重要）
///
/// 本项目采用**双层存储**，理解这一点才能看懂这里的表设计：
///
/// ```
/// 题目内容  →  Markdown 文件（事实源，人类可读、可 Git、可迁移）
/// 用户状态  →  SQLite（高频写、需事务）
/// 查询加速  →  SQLite 索引（可从 Markdown 全量重建）
/// ```
///
/// 因此本文件里的表分两类：
///
/// | 表 | 类别 | 能否重建 |
/// |---|---|---|
/// | `problems_index` | 题目内容的**索引** | ✅ 可从 Markdown 全量重建 |
/// | `problem_knowledge` | 知识点关联的**索引** | ✅ 同上 |
/// | `problems_fts` | FTS5 全文索引 | ✅ 同上 |
/// | `user_problem_state` | **用户状态**（事实源） | ❌ **必须备份** |
/// | `review_logs` | **复习历史**（事实源） | ❌ **必须备份** |
/// | `papers` | 组卷记录 | ❌ 建议备份 |
///
/// ⚠️ **绝不能把用户状态写进 Markdown。** 一旦 `wrong_count` / `fsrs_state`
/// 落进 `.md`，会同时陷入「高频重写文件」与「索引无法重建」两个坑。
library;

import 'package:drift/drift.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 题目内容索引（可从 Markdown 重建）
// ─────────────────────────────────────────────────────────────────────────────

/// 题目索引表。
///
/// 这里存的是**派生索引**，题目内容的事实源永远是 `problems/*.md`。
/// 整个表删掉不会丢任何数据，只是要重建一次。
///
/// 各列分工（容易记混，特此写明）：
/// - [stemText] —— **给人看的题干摘要**（剥 Markdown、保留 LaTeX），列表页直接用
/// - [searchTokens] —— **给 FTS5 用的倒排输入**（已做 CJK 逐字分词）。
///   FTS5 索引的是这一列而不是 [stemText]，原因见 `database.dart` 里的 DDL 注释
@DataClassName('ProblemIndexRow')
class ProblemsIndex extends Table {
  /// SQLite 隐式 rowid 的显式声明。
  ///
  /// ⚠️ Dart 列名**不能**叫 `rowid` —— 那会生成与 SQLite 隐式 rowid 同名的列，
  /// 造成 `problems_index.rowid` 语义歧义（而且 FTS5 external-content 表
  /// 要求 `content_rowid` 指向一个真实的整数主键）。
  ///
  /// 这里用 `ftsRowId` 作 Dart 名、`named('rowid')` 把 SQL 列名固定为 `rowid`，
  /// 既避免了歧义，又让 FTS5 的 `content_rowid='rowid'` 正常工作。
  IntColumn get ftsRowId => integer().named('rowid').autoIncrement()();

  /// 题目业务 id，如 `2023-shu1-T18`。全局唯一。
  TextColumn get id => text().unique()();

  /// 去重指纹（16 位十六进制）。
  TextColumn get fingerprint => text()();

  /// `math1` / `math2` / `math3`
  TextColumn get subject => text()();

  /// `choice` / `fill` / `solve` / `proof`
  TextColumn get qtype => text()();

  /// 1 基础 · 2 综合 · 3 拓展
  IntColumn get difficulty => integer().withDefault(const Constant(2))();

  TextColumn get source => text().nullable()();

  /// `real_exam` / `mock` / `textbook` / `self_made` / `unknown`
  TextColumn get sourceType => text().withDefault(const Constant('unknown'))();

  IntColumn get sourceYear => integer().nullable()();

  /// Markdown 文件相对路径（相对 library 根目录）。
  TextColumn get filePath => text()();

  /// 题干纯文本（去 Markdown 标记），保留原始可读形式。
  ///
  /// 用于展示、调试与将来的高亮。**不参与 FTS 索引** ——
  /// 见 [searchTokens] 的说明。
  TextColumn get stemText => text()();

  /// 供 FTS5 索引的**分词后**文本。
  ///
  /// ⚠️ 这里存的是 `CjkTokenizer.space()` 处理过的版本 —— 中文逐字加空格。
  /// 原因：FTS5 的 `unicode61` 分词器按空白切词，中文句子没有空格会变成
  /// 单个巨型 token，导致中文检索完全失效（实测确认）。
  ///
  /// 之所以另起一列而不是复用 [stemText]：加空格后的文本**不可逆**
  /// （无法区分"原本就有空格"与"为分词而加的空格"），
  /// 保留原始版本才能正确展示与调试。
  ///
  /// 索引与查询必须使用**同一套分词规则**，详见 `CjkTokenizer`。
  TextColumn get searchTokens => text().withDefault(const Constant(''))();

  /// 主考点的考频权重。冗余存放是为了让组卷/排序能纯 SQL 完成，
  /// 不必回查知识点本体文件。
  RealColumn get primaryKpWeight => real().nullable()();

  /// 主考点名称。同样用于展示与排序的便捷性。
  TextColumn get primaryKpName => text().nullable()();

  /// 解析期产生的警告（JSON 数组字符串）。非空表示需人工复核。
  TextColumn get parseWarnings => text().nullable()();

  /// 题目的错因（`error_causes`）—— **JSON 数组字符串**，如 `["sign","idea"]`。
  ///
  /// ⚠️ 这是**题目属性**（"这题容易在哪里错"，录入时用户勾选或 AI 预判），
  /// 与 `user_problem_state.error_causes`（"我这次为什么错"）不是一回事。
  ///
  /// 为什么要冗余进索引：`画像` 要统计**错因分布**，而它是一张聚合表。
  /// 不冗余的话，算一次分布就得读 5000 个 Markdown 文件 ——
  /// 而索引表本来就是为"不必回头读 Markdown"而存在的。
  ///
  /// schema v4 新增。它同样是**派生数据**（可从 Markdown 重建），
  /// 所以迁移只需加一列 + 重建索引，不涉及任何用户数据。
  TextColumn get errorCauses => text().nullable()();

  BoolColumn get needsReview =>
      boolean().withDefault(const Constant(false))();

  BoolColumn get aiTagged => boolean().withDefault(const Constant(false))();

  RealColumn get aiConfidence => real().nullable()();

  DateTimeColumn get createdAt => dateTime().nullable()();

  /// 文件最后修改时间。用于增量重建索引：只重解析 mtime 变化的文件。
  DateTimeColumn get fileModifiedAt => dateTime().nullable()();

  /// 索引行自身的插入/更新时间。
  DateTimeColumn get indexedAt =>
      dateTime().withDefault(currentDateAndTime)();
}

/// 题目 ↔ 知识点关联。多对多。
@DataClassName('ProblemKnowledgeRow')
class ProblemKnowledge extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 对应 [ProblemsIndex.id]。
  TextColumn get problemId => text()();

  /// 知识点 id，必须在知识点本体中存在。
  TextColumn get kpId => text()();

  /// `primary`（有且仅有一个）或 `secondary`。
  TextColumn get role => text().withDefault(const Constant('secondary'))();

  /// 相关度 0–1。
  RealColumn get relevance => real().withDefault(const Constant(1.0))();
}

// ─────────────────────────────────────────────────────────────────────────────
// 用户状态（事实源，必须备份）
// ─────────────────────────────────────────────────────────────────────────────

/// 用户与题目的关系：错误次数、FSRS 状态、掌握度。
///
/// V1 是单机单人，因此没有 `userId`。将来加多用户时这里加一列并调整主键。
@DataClassName('UserProblemStateRow')
class UserProblemState extends Table {
  /// 题目 id。一道题只有一条状态记录。
  TextColumn get problemId => text()();

  /// 累计做错次数。
  IntColumn get wrongCount => integer().withDefault(const Constant(1))();

  DateTimeColumn get firstSeen =>
      dateTime().withDefault(currentDateAndTime)();

  DateTimeColumn get lastWrong => dateTime().nullable()();

  /// FSRS 卡片状态，`FsrsCard.toJson()` 的 JSON 字符串。
  ///
  /// 不拆成独立列的原因：FSRS 的字段集会随算法版本变化（21 个权重、
  /// 新增字段等），拆列意味着每次算法升级都要改 schema。整块 JSON 更稳。
  TextColumn get fsrsState => text().nullable()();

  /// 掌握度 0–1，由 FSRS 的可提取性推算。
  RealColumn get mastery => real().withDefault(const Constant(0.0))();

  /// 错因（受控词表的多选），JSON 数组字符串。
  ///
  /// ⚠️ 这是**用户状态**（"我为什么错"），不是题目属性。
  /// 题干里的 `error_causes` 是 AI 预判的**易错点**，两者含义不同。
  TextColumn get errorCauses => text().withDefault(const Constant('[]'))();

  /// 用户笔记。
  TextColumn get note => text().nullable()();

  /// 是否已收藏/标记为顽固错题。
  BoolColumn get starred => boolean().withDefault(const Constant(false))();

  /// 一道题只能有一条状态记录。
  ///
  /// ⚠️ 这个主键是**后补的**。初版忘了声明，于是 `problem_id` 只是个普通列 ——
  /// 而文档与业务逻辑都假设"一题一行"。后果是复习打分时
  /// `insertOnConflictUpdate` 没有冲突目标可用，只能退化成
  /// "先查再写"，双击评分按钮这类并发写入就会写出重复行，
  /// 于是同一道题有两条 FSRS 状态，复习队列出现重复卡片。
  ///
  /// 修它需要一次迁移（见 `database.dart` 的 `_migrateToV2`），
  /// 因为 SQLite 不能给已有表 `ALTER TABLE ... ADD PRIMARY KEY`，
  /// 只能建新表 + 拷数据 + 换名。
  @override
  Set<Column> get primaryKey => {problemId};
}

/// 复习历史。每次复习一条。
@DataClassName('ReviewLogRow')
class ReviewLogs extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 题目 id。冗余存放以便直接按题查询，避免 join [UserProblemState]。
  TextColumn get problemId => text()();

  /// 1 = 忘了 · 2 = 吃力 · 3 = 轻松（对应 `Rating.value` 的子集）。
  IntColumn get rating => integer()();

  /// 本次作答耗时（毫秒）。用于分析"会做但慢"这类问题。
  IntColumn get elapsedMs => integer().nullable()();

  /// 复习时距离上次复习的天数。
  IntColumn get elapsedDays => integer().nullable()();

  /// 本次安排的下次间隔天数。
  IntColumn get scheduledDays => integer().nullable()();

  /// 复习后的稳定性与难度快照，便于回放分析算法行为。
  RealColumn get stabilityAfter => real().nullable()();
  RealColumn get difficultyAfter => real().nullable()();

  DateTimeColumn get reviewedAt =>
      dateTime().withDefault(currentDateAndTime)();
}

// ─────────────────────────────────────────────────────────────────────────────
// 组卷记录
// ─────────────────────────────────────────────────────────────────────────────

/// 一次组卷的配置与结果快照。
@DataClassName('PaperRow')
class Papers extends Table {
  TextColumn get id => text()();

  TextColumn get title => text()();

  TextColumn get subject => text()();

  /// 组卷参数快照，JSON。
  TextColumn get config => text()();

  /// 选中的题目与分值，JSON 数组 `[{problemId, no, score}]`。
  TextColumn get items => text()();

  IntColumn get totalScore => integer().nullable()();

  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

// ─────────────────────────────────────────────────────────────────────────────
// AI 标注缓存与用量台账
// ─────────────────────────────────────────────────────────────────────────────

/// AI 标注结果的本地缓存。
///
/// ## 为什么按"指纹"缓存而不是按题目 id
///
/// 指纹是**题干内容**的哈希（见 `domain/fingerprint.dart`），与题目 id 无关。
/// 同一道题在不同设备/不同批次录入时会拿到不同 id，但指纹相同 ——
/// 按指纹缓存才能跨批次复用，也才能命中"用户重复录入同一道题"这个高频场景。
///
/// ## 为什么存 [model]
///
/// 同一道题换一个模型标注，结果可能不同（T17 实测：dev 集上不同模型的
/// Top-1 差 3–5 个百分点）。缓存如果不记模型，用户换模型后会一直拿到
/// 旧模型的结果，且**毫无察觉**。所以读缓存时要求模型一致，不一致就重标。
///
/// ## 这张表可以被安全删除
///
/// 它只是省钱的缓存，删掉只会让下次标注重新走一遍 API，不会丢用户数据。
@DataClassName('TagCacheRow')
class TagCacheEntries extends Table {
  /// 题目指纹。
  TextColumn get fingerprint => text()();

  /// 标注结果 `TagResult.toJson()` 的 JSON 字符串。
  TextColumn get result => text()();

  /// 产出这个结果的模型名（用于换模型后失效）。
  TextColumn get model => text().withDefault(const Constant(''))();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {fingerprint};
}

/// AI 调用用量台账。每次真正发出请求记一条。
///
/// ## 为什么值得单独记一张表
///
/// BYOK 模式下用户自己付费 —— 那么"我到底花了多少"必须**在本地算得出来**，
/// 而不是让用户去服务商后台对账。这也让"标注一道题平均花多少钱"
/// 变成可回答的问题（`UsageLedger.summary()`）。
///
/// 命中缓存时**不记**（没花钱），所以这张表的行数就是真实调用次数。
@DataClassName('LlmUsageRow')
class LlmUsageEntries extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 服务商 id，如 `deepseek`。
  TextColumn get provider => text()();

  /// 模型名。
  TextColumn get model => text().withDefault(const Constant(''))();

  /// 本次调用的用途，如 `tag`。将来还有 `solve` / `paper` 等。
  TextColumn get purpose => text().withDefault(const Constant('tag'))();

  IntColumn get inputTokens => integer().withDefault(const Constant(0))();
  IntColumn get outputTokens => integer().withDefault(const Constant(0))();

  /// 费用估算（元）。null 表示该模型不在价目表里。
  RealColumn get costYuan => real().nullable()();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

// ─────────────────────────────────────────────────────────────────────────────
// 同步元数据
// ─────────────────────────────────────────────────────────────────────────────

/// 键值元数据表。记录索引重建时间、schema 版本等。
@DataClassName('MetaRow')
class MetaEntries extends Table {
  TextColumn get key => text()();

  TextColumn get value => text()();

  DateTimeColumn get updatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {key};
}

// ─────────────────────────────────────────────────────────────────────────────
// 对话助手
// ─────────────────────────────────────────────────────────────────────────────
//
// ## 为什么对话记录进 SQLite 而不是 Markdown
//
// 这个项目的既定分工是「Markdown 是事实源、SQLite 是状态」。
// 对话属于**状态**而不是事实：它是"跟模型的往返经过"，
// 不是"关于某道题的、需要人工编辑与版本管理的知识"。
// 落成 Markdown 会有两个坏处：
// ① 每条回复都要过一次文件系统与小作文解析，而流式是逐字写的 ——
//    写一百次文件只为了一句回答；
// ② 题库目录会被一堆聊天记录淹掉，用户在"文件即数据"的心智里
//    会以为这些也是要维护的题目。
//
// ## 这两张表可以安全删除
//
// 删掉只会让用户丢失聊天记录，不影响错题本、复习进度、知识库。

/// 一次对话会话。
@DataClassName('ChatSessionRow')
class ChatSessions extends Table {
  /// 会话 id（本机生成的随机串）。
  TextColumn get id => text()();

  /// 标题。取首条用户消息的前若干个字 —— 让历史列表一眼能认出来。
  /// **允许为空**（首条消息还没发出时就会先建会话）。
  TextColumn get title => text().withDefault(const Constant(''))();

  /// 建会话时用的模型。换模型之后回看旧会话时，
  /// 能知道"这段话是谁说的"（不同模型的风格差别很明显）。
  TextColumn get model => text().withDefault(const Constant(''))();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// 最后一条消息的时间。历史列表按它倒序 ——
  /// 用 `createdAt` 排序的话，接着聊旧会话不会把它顶上去。
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// 会话里的一条消息。
@DataClassName('ChatMessageRow')
class ChatMessages extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get sessionId => text()();

  /// `user` 或 `assistant`。
  ///
  /// 存字符串而不是整数枚举：这张表将来要能被人直接打开看，
  /// 而 `2` 是什么意思三个月后没人记得。
  TextColumn get role => text()();

  TextColumn get content => text()();

  /// 这条回复**是否没写完**。
  ///
  /// ## 为什么必须有这个字段
  ///
  /// 流式回复是逐字落库的：用户随时可能关窗口、拔网线、或者按停。
  /// 那一刻已经落盘的内容是**半句话**，而如果把它当成一条正常回复，
  /// 下次打开看到的是一句莫名其妙断掉的话，用户会以为
  /// "模型怎么变笨了"，而真相是我们把一次中断伪装成了完整回答。
  ///
  /// 有了它，界面可以如实标注"这条回复被中断了"。
  BoolColumn get interrupted => boolean().withDefault(const Constant(false))();

  /// 这条消息的用量。用户消息恒为 0。
  ///
  /// ⚠️ 流式下这些数**可能为 0 而不是真的没花钱** ——
  /// 部分服务商的流式接口不返回用量（见 `LlmClient.chatStream` 的说明）。
  /// 所以它只用来做"大概花了多少"的参考，不能当账本。
  IntColumn get inputTokens => integer().withDefault(const Constant(0))();

  IntColumn get outputTokens => integer().withDefault(const Constant(0))();

  RealColumn get costYuan => real().nullable()();

  /// 这条回复**查过什么**。JSON 数组，如
  /// `[{"name":"query_wrong_problems","args":"kp=中值定理","ok":true,"summary":"查到 12 道错题"}]`。
  ///
  /// ## 为什么值得占一列
  ///
  /// 有了工具之后，助手说的话**有出处了** —— 但出处不可见时它就等于没有：
  /// 用户看到"你在中值定理上错得最多"这句话，没有任何办法判断它是
  /// 查出来的还是编的。存下这条记录，重开会话时仍能看到
  /// "这句结论背后查了哪些东西"。
  ///
  /// ⚠️ **只存摘要，不存工具返回的正文**（见 `ToolTraceItem` 的说明）：
  /// 正文动辄几 KB，而它不会再被显示。
  ///
  /// 这一列同样是**派生信息**：删掉只影响"这条回复的溯源"，不影响内容。
  ///
  /// schema v6 新增，可空 —— 旧行自然为 null，界面按"没有记录"处理。
  TextColumn get toolTrace => text().nullable()();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
