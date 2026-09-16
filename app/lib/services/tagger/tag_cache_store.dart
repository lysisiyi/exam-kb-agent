/// AI 标注缓存与用量台账的落地实现。
///
/// ## 这两个东西为什么放在一起
///
/// 它们都只服务于一件事：**让用户看得见自己的 AI 花费**。
/// 缓存决定"这次要不要花钱"，台账记录"这次花了多少"。
/// 分开写的话，"命中缓存不记账"这条规则会散落在两处，迟早不同步。
///
/// ## 缓存不是必需功能
///
/// 缓存表可以随时清空、删库重建，最坏后果是下次标注重新调用一次 API。
/// 所以这里的读写**全部吞掉异常**：缓存出问题绝不应当让标注失败。
/// 台账同理 —— 记不上账也不能让用户已经拿到手的标注结果作废。
library;

import 'package:drift/drift.dart';

import '../../data/db/database.dart';
import '../llm/llm_client.dart';
import 'knowledge_tagger.dart';
import 'tag_prompt.dart';

/// 基于 SQLite 的标注缓存。
///
/// 遵守 [TagCache] 接口，因此 `KnowledgeTagger` 不需要知道它存在。
class SqliteTagCache implements TagCache {
  final AppDatabase db;

  /// 当前模型名。读缓存时要求模型一致，否则视为未命中（并顺手覆盖）。
  ///
  /// 传 null 表示"不按模型区分" —— 只建议在测试里这么用。
  final String? model;

  const SqliteTagCache({required this.db, this.model});

  @override
  Future<TagResult?> get(String fingerprint) async {
    if (fingerprint.isEmpty) return null;
    try {
      final row = await (db.select(db.tagCacheEntries)
            ..where((t) => t.fingerprint.equals(fingerprint)))
          .getSingleOrNull();
      if (row == null) return null;

      // 换模型后旧结果不再可信：T17 实测不同模型 Top-1 差 3–5 个百分点，
      // 静默复用旧模型的标注会让用户以为"换模型没用"。
      if (model != null && row.model != model) return null;

      // 用统一的编解码器，避免这里再写一份 TagResult ↔ JSON 的映射
      // （那份映射一旦和 `TagResultCodec` 不同步，缓存就会读出错的结果）
      return TagResultCodec.decode(row.result);
    } catch (_) {
      // 缓存损坏/表不存在 —— 当作未命中，让调用方走真实标注
      return null;
    }
  }

  @override
  Future<void> put(String fingerprint, TagResult result) async {
    if (fingerprint.isEmpty) return;
    try {
      await db.into(db.tagCacheEntries).insertOnConflictUpdate(
            TagCacheEntriesCompanion.insert(
              fingerprint: fingerprint,
              result: TagResultCodec.encode(result),
              model: Value(model ?? ''),
            ),
          );
    } catch (_) {
      // 写缓存失败不该让标注失败 —— 用户已经拿到结果了
    }
  }

  /// 当前缓存条数。
  ///
  /// 用 `COUNT(*)` 而不是"取回全部行再数长度"：缓存上限没有限制，
  /// 而每次打开 AI 配置对话框都会调它一次。
  ///
  /// ⚠️ 返回 **null 表示读不到**，而不是 0。
  ///
  /// 早先这里 catch 之后返回 0，于是"数据库被锁住 / 表损坏"与
  /// "确实还没缓存过"在界面上长得一模一样 —— 面板会**自信地**
  /// 显示"0 道题缓存"。用户据此以为缓存没生效，而真实原因是读不出来。
  Future<int?> count() async {
    try {
      final row = await db
          .customSelect('SELECT COUNT(*) AS c FROM tag_cache_entries')
          .getSingle();
      return row.read<int>('c');
    } catch (_) {
      return null;
    }
  }

  /// 清空缓存。
  Future<void> clear() async {
    try {
      await db.delete(db.tagCacheEntries).go();
    } catch (_) {
      // 同上：清理失败不值得打断用户
    }
  }
}

/// 用量汇总。
class UsageSummary {
  /// 真实调用次数（不含命中缓存）。
  final int calls;

  final int inputTokens;
  final int outputTokens;

  /// 费用估算（元）。价目表里没有的模型不计入，因此这是**下界**。
  final double costYuan;

  final DateTime? firstAt;
  final DateTime? lastAt;

  /// 读库失败的原因。非空表示这份汇总**不可信**。
  ///
  /// 有它才能把"读不出来"和"确实没花过钱"分开 —— 早先两者都会走到
  /// `describeUsage` 的空态分支，于是数据库出问题时面板显示的是
  /// 「还没有调用过 AI」，一个**看起来完全正常**的谎。
  final String? error;

  const UsageSummary({
    this.calls = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.costYuan = 0,
    this.firstAt,
    this.lastAt,
    this.error,
  });

  bool get hasError => error != null;

  int get totalTokens => inputTokens + outputTokens;

  bool get isEmpty => calls == 0 && !hasError;

  /// 平均每道题的 token（用于"再标 100 道大概要多少钱"的估算）。
  double get tokensPerCall => calls == 0 ? 0 : totalTokens / calls;

  double get costPerCall => calls == 0 ? 0 : costYuan / calls;
}

/// AI 用量台账。
class UsageLedger {
  final AppDatabase db;

  const UsageLedger(this.db);

  /// 记一次真实调用。
  ///
  /// 命中缓存的调用**不要**调这里 —— 那种情况没花钱，
  /// 记进去会让"我花了多少"这个数字虚高。
  Future<void> record({
    required String provider,
    required LlmUsage usage,
    String purpose = 'tag',
    DateTime? now,
  }) async {
    if (usage.fromCache) return;
    try {
      await db.into(db.llmUsageEntries).insert(
            LlmUsageEntriesCompanion.insert(
              provider: provider,
              model: Value(usage.model),
              purpose: Value(purpose),
              inputTokens: Value(usage.inputTokens),
              outputTokens: Value(usage.outputTokens),
              costYuan: Value(usage.costYuan),
              createdAt: Value(now ?? DateTime.now()),
            ),
          );
    } catch (_) {
      // 同上：记不上账不该影响用户已经拿到的结果
    }
  }

  /// 汇总。[since] 为 null 表示全部历史。
  Future<UsageSummary> summary({DateTime? since}) async {
    try {
      final rows = await db.select(db.llmUsageEntries).get();
      final kept =
          since == null ? rows : rows.where((r) => !r.createdAt.isBefore(since));

      var inTok = 0;
      var outTok = 0;
      var cost = 0.0;
      var calls = 0;
      DateTime? first;
      DateTime? last;

      for (final r in kept) {
        calls++;
        inTok += r.inputTokens;
        outTok += r.outputTokens;
        cost += r.costYuan ?? 0;
        if (first == null || r.createdAt.isBefore(first)) first = r.createdAt;
        if (last == null || r.createdAt.isAfter(last)) last = r.createdAt;
      }

      return UsageSummary(
        calls: calls,
        inputTokens: inTok,
        outputTokens: outTok,
        costYuan: cost,
        firstAt: first,
        lastAt: last,
      );
    } catch (e) {
      // 见 [UsageSummary.error]：不能把"读不出来"伪装成"没花过钱"
      return UsageSummary(error: '$e');
    }
  }

  /// 最近 [limit] 条明细，最新的在前。
  Future<List<LlmUsageRow>> recent({int limit = 20}) async {
    try {
      return await (db.select(db.llmUsageEntries)
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
            ..limit(limit))
          .get();
    } catch (_) {
      return const [];
    }
  }

  Future<void> clear() async {
    try {
      await db.delete(db.llmUsageEntries).go();
    } catch (_) {}
  }
}

/// 一笔账的展示文案。UI 与测试共用，避免两处各写一份格式化。
String describeUsage(UsageSummary s) {
  // ⚠️ 读库失败必须**说出来**，不能落到下面的空态分支。
  // 否则数据库出问题时面板显示「还没有调用过 AI」——
  // 一个看起来完全正常、但会让用户以为自己没花钱的谎。
  if (s.hasError) return '用量读取失败：${s.error}';
  if (s.isEmpty) return '还没有调用过 AI';
  final cost = s.costYuan < 0.01
      ? '<0.01'
      : s.costYuan.toStringAsFixed(2);
  return '${s.calls} 次调用 · ${s.totalTokens} tokens · 约 ¥$cost';
}

/// 缓存条数的展示文案。`null` 表示读不到。
String describeCacheCount(int? count) {
  if (count == null) return '本地缓存条数读取失败';
  if (count == 0) return '';
  return '本地已缓存 $count 道题的标注结果 —— 重复录入同一道题不会再花 token。';
}
