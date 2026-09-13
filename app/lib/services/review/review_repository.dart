/// 复习调度：把 FSRS 接到真实的卡片状态上。
///
/// ## 这一层存在的理由
///
/// `FsrsScheduler` 是**纯函数**：给一张卡和一次评分，算出下次该什么时候复习。
/// 它不知道卡片存在哪、不知道题目内容、不知道用户错了几次。
/// 本文件负责这些"落地"的事：
///
/// ```
/// 队列    user_problem_state   →  哪些卡该复习了
/// 内容    problems/*.md        →  题干、答案、解析（Markdown 是事实源）
/// 打分    FsrsScheduler        →  新的间隔与稳定性
/// 记账    review_logs          →  每次评分留一条，供将来跑优化器
/// ```
///
/// ## 一个刻意的取舍：到期判断在 Dart 里做，不在 SQL 里
///
/// `due` 是塞在 `fsrs_state` JSON 里的。要在 SQL 里筛"到期了没"，
/// 得把 FSRS 的字段拆成独立列 —— 而那样每次算法升级都要改 schema
/// （见 `tables.dart` 里 `fsrsState` 的说明）。
///
/// 所以这里读出全部状态行，在 Dart 里解析 JSON 并筛选。
/// 个人错题本是**几百到几千条**量级，一次全读 + 解析是毫秒级；
/// 换来的好处是 FSRS 字段集可以随便演进。真到几万条再考虑加冗余列。
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../data/db/database.dart';
import '../../data/markdown/problem_markdown.dart';
import '../../data/markdown/problem_store.dart';
import '../../domain/fsrs/fsrs_scheduler.dart';

/// 复习队列里的一张卡。
class DueCard {
  final String problemId;

  /// 题目内容。Markdown 读取失败时为 null（卡片仍会出现，只是看不了题）。
  final Problem? problem;

  /// 读取失败原因（[problem] 为 null 时非空）。
  final String? loadError;

  /// 当前 FSRS 状态。null 表示**新卡**（从未复习过）。
  final FsrsCard? card;

  /// 用户状态行（错题次数、笔记等）。
  final UserProblemStateRow state;

  /// 是否新卡。
  bool get isNew => card == null || card!.reps == 0;

  /// 到期时间（新卡为 null）。
  DateTime? get due => card?.due;

  /// 逾期天数（新卡为 0）。
  int overdueDays(DateTime now) {
    final d = due;
    if (d == null) return 0;
    final diff = now.difference(d).inDays;
    return diff > 0 ? diff : 0;
  }

  const DueCard({
    required this.problemId,
    required this.state,
    this.problem,
    this.card,
    this.loadError,
  });
}

/// 一次评分的结算结果。
class GradeResult {
  final String problemId;
  final Rating rating;

  /// 下次复习时间。
  final DateTime nextDue;

  /// 本次安排的天数。
  final int intervalDays;

  /// 评分后的稳定性与难度（用于 UI 展示"这张卡现在多牢"）。
  final double stability;
  final double difficulty;

  /// 复习后的可提取性（= 掌握度 0–1）。
  final double mastery;

  /// 累计做错次数。
  final int wrongCount;

  const GradeResult({
    required this.problemId,
    required this.rating,
    required this.nextDue,
    required this.intervalDays,
    required this.stability,
    required this.difficulty,
    required this.mastery,
    required this.wrongCount,
  });
}

/// 复习总览。
class ReviewStats {
  final int totalCards;
  final int dueNow;
  final int newCards;
  final int reviewedToday;

  /// 未来 7 天每天的到期数量（下标 0 = 今天）。
  final List<int> upcoming;

  /// **最早一张尚未到期**的卡的时间。
  ///
  /// 用途：空态文案。没有它就只能说"今天做完了"，
  /// 而用户真正想知道的是"那我什么时候再来"。
  /// 全都没到期时也如常返回该时间。
  final DateTime? nextDue;

  const ReviewStats({
    this.totalCards = 0,
    this.dueNow = 0,
    this.newCards = 0,
    this.reviewedToday = 0,
    this.upcoming = const [],
    this.nextDue,
  });

  /// 是否一张卡都没有（错题本空）。与"今天做完了"是两回事，文案要分开。
  bool get isEmpty => totalCards == 0;
}

/// 复习仓库。
class ReviewRepository {
  final AppDatabase db;
  final ProblemStore store;

  /// 调度器。可注入以便测试固定随机数（`enableFuzzing: false`）。
  final FsrsScheduler scheduler;

  ReviewRepository({
    required this.db,
    required this.store,
    FsrsScheduler? scheduler,
  }) : scheduler = scheduler ?? FsrsScheduler();

  // ───────────────────────────────────────────────────────────────────────
  // 卡片生命周期
  // ───────────────────────────────────────────────────────────────────────

  /// 为索引里**还没有状态行**的题目补建卡片。
  ///
  /// ## 为什么要"补建"而不是"保存时创建"
  ///
  /// 卡片也可能来自别的途径：批量导入（M7）、手工把 `.md` 拷进 `problems/`、
  /// 或者用户在旧版本里录的题。与其在每条写入路径上都记得建卡，
  /// 不如在打开复习页时做一次**对账**：索引里有、状态表里没有的，就补上。
  ///
  /// 对账是幂等的，代价是一次全表读 + 一次集合差。
  ///
  /// [wrongCount] 用于新建时的初始错误次数；已存在的卡片不动。
  Future<int> ensureCards({int wrongCount = 1, DateTime? now}) async {
    final rows = await db.select(db.problemsIndex).get();
    final states = await db.select(db.userProblemState).get();
    final known = {for (final s in states) s.problemId};

    final missing = rows.where((r) => !known.contains(r.id)).toList();
    if (missing.isEmpty) return 0;

    final ts = now ?? DateTime.now();
    await db.batch((b) {
      b.insertAll(
        db.userProblemState,
        [
          for (final r in missing)
            UserProblemStateCompanion.insert(
              problemId: r.id,
              wrongCount: Value(wrongCount),
              firstSeen: Value(ts),
              // fsrsState 留空 = 新卡，dueQueue 会把它排在前面
            ),
        ],
        mode: InsertMode.insertOrIgnore,
      );
    });
    return missing.length;
  }

  /// 标记一道题"又错了一次"（不进复习流程，直接记账）。
  ///
  /// 用途：用户在错题本里翻到一道题，随手记一次错。
  /// 这**不等于**复习评分 —— 复习评分走 [grade]，会更新 FSRS 间隔。
  Future<void> recordWrong(String problemId, {DateTime? now}) async {
    final ts = now ?? DateTime.now();
    final existing = await _stateOf(problemId);
    if (existing == null) {
      await db.into(db.userProblemState).insert(
            UserProblemStateCompanion.insert(
              problemId: problemId,
              firstSeen: Value(ts),
              lastWrong: Value(ts),
            ),
            mode: InsertMode.insertOrIgnore,
          );
    } else {
      await (db.update(db.userProblemState)
            ..where((t) => t.problemId.equals(problemId)))
          .write(UserProblemStateCompanion(
        wrongCount: Value(existing.wrongCount + 1),
        lastWrong: Value(ts),
      ));
    }
  }

  /// 删除一道题的状态行（题目被删时调用）。
  Future<void> forget(String problemId) async {
    await (db.delete(db.userProblemState)
          ..where((t) => t.problemId.equals(problemId)))
        .go();
  }

  // ───────────────────────────────────────────────────────────────────────
  // 队列
  // ───────────────────────────────────────────────────────────────────────

  /// 到期卡片队列。
  ///
  /// 排序：**逾期最久的排最前**，然后是新卡。
  /// 理由：逾期久的遗忘风险最高；新卡没有时间压力。
  Future<List<DueCard>> dueQueue({int limit = 30, DateTime? now}) async {
    final ts = now ?? DateTime.now();
    final states = await db.select(db.userProblemState).get();

    final due = <(UserProblemStateRow, FsrsCard?)>[];
    for (final s in states) {
      final card = _cardOf(s);
      if (card == null) {
        due.add((s, null)); // 新卡
      } else if (scheduler.isDue(card, ts)) {
        due.add((s, card));
      }
    }

    due.sort((a, b) {
      // 新卡排在有卡片的之后
      if (a.$2 == null && b.$2 != null) return 1;
      if (a.$2 != null && b.$2 == null) return -1;
      final da = a.$2?.due;
      final dbb = b.$2?.due;
      if (da == null || dbb == null) return a.$1.problemId.compareTo(b.$1.problemId);
      return da.compareTo(dbb); // 逾期越久（due 越早）越靠前
    });

    final out = <DueCard>[];
    for (final (state, card) in due.take(limit)) {
      final read = await store.read(state.problemId);
      out.add(DueCard(
        problemId: state.problemId,
        state: state,
        card: card,
        problem: read.problem,
        loadError: read.error,
      ));
    }
    return out;
  }

  /// 统计。用于复习页顶部与首页角标。
  Future<ReviewStats> stats({DateTime? now}) async {
    final ts = now ?? DateTime.now();
    final states = await db.select(db.userProblemState).get();

    var dueNow = 0;
    var fresh = 0;
    DateTime? nextDue;
    final upcoming = List<int>.filled(7, 0);

    for (final s in states) {
      final card = _cardOf(s);
      if (card == null || card.reps == 0) {
        fresh++;
        dueNow++; // 新卡随时可复习
        upcoming[0]++;
        continue;
      }
      if (scheduler.isDue(card, ts)) {
        dueNow++;
      }
      final d = card.due;
      if (d != null) {
        // 空态要告诉用户"下次什么时候来"：只记未到期的里最早的那张
        if (d.isAfter(ts) && (nextDue == null || d.isBefore(nextDue))) {
          nextDue = d;
        }
        final days = d.difference(DateTime(ts.year, ts.month, ts.day)).inDays;
        if (days >= 0 && days < 7) upcoming[days]++;
      }
    }

    final todayStart = DateTime(ts.year, ts.month, ts.day);
    final logs = await db.select(db.reviewLogs).get();
    final reviewedToday =
        logs.where((l) => !l.reviewedAt.isBefore(todayStart)).length;

    return ReviewStats(
      totalCards: states.length,
      dueNow: dueNow,
      newCards: fresh,
      reviewedToday: reviewedToday,
      upcoming: upcoming,
      nextDue: nextDue,
    );
  }

  // ───────────────────────────────────────────────────────────────────────
  // 打分
  // ───────────────────────────────────────────────────────────────────────

  /// 给一张卡打分，推进 FSRS 状态并记一条复习日志。
  ///
  /// 只支持三个评分（忘了 / 吃力 / 轻松）—— 见 `Rating` 的说明：
  /// 四档反馈在真实使用中用户分不清 Good 与 Easy，反而让调度变差。
  Future<GradeResult> grade({
    required String problemId,
    required Rating rating,
    int? elapsedMs,
    DateTime? now,
  }) async {
    final ts = now ?? DateTime.now();
    final existing = await _stateOf(problemId);

    final card = existing == null ? null : _cardOf(existing);
    final outcome = scheduler.review(
      card ?? const FsrsCard(),
      rating,
      ts,
    );

    final mastery = scheduler.retrievability(outcome.card, ts);

    // 只有"忘了"才算又错一次。
    // rating 为 吃力/轻松 说明用户做出来了 —— 那是进展，不该计错。
    final wrongCount =
        (existing?.wrongCount ?? 0) + (rating == Rating.forgot ? 1 : 0);

    // ⚠️ 用 insertOnConflictUpdate 而不是"先查再写"：
    // 后者在双击评分按钮时会写出两条状态行（`user_problem_state` 的主键
    // 就是为这件事补的，见 tables.dart）。
    await db.into(db.userProblemState).insertOnConflictUpdate(
          UserProblemStateCompanion.insert(
            problemId: problemId,
            wrongCount: Value(wrongCount),
            firstSeen: Value(existing?.firstSeen ?? ts),
            lastWrong: Value(rating == Rating.forgot ? ts : existing?.lastWrong),
            fsrsState: Value(jsonEncode(outcome.card.toJson())),
            mastery: Value(mastery),
            errorCauses: Value(existing?.errorCauses ?? '[]'),
            note: Value(existing?.note),
            starred: Value(existing?.starred ?? false),
          ),
        );

    await db.into(db.reviewLogs).insert(
          ReviewLogsCompanion.insert(
            problemId: problemId,
            rating: rating.value,
            elapsedMs: Value(elapsedMs),
            elapsedDays: Value(outcome.card.elapsedDays),
            scheduledDays: Value(outcome.intervalDays),
            stabilityAfter: Value(outcome.card.stability),
            difficultyAfter: Value(outcome.card.difficulty),
            reviewedAt: Value(ts),
          ),
        );

    return GradeResult(
      problemId: problemId,
      rating: rating,
      nextDue: outcome.card.due ?? ts,
      intervalDays: outcome.intervalDays,
      stability: outcome.card.stability ?? 0,
      difficulty: outcome.card.difficulty ?? 0,
      mastery: mastery,
      wrongCount: wrongCount,
    );
  }

  // ───────────────────────────────────────────────────────────────────────
  // 内部
  // ───────────────────────────────────────────────────────────────────────

  Future<UserProblemStateRow?> _stateOf(String problemId) =>
      (db.select(db.userProblemState)
            ..where((t) => t.problemId.equals(problemId)))
          .getSingleOrNull();

  /// 解析 FSRS 状态。损坏时当作新卡，而不是让整个复习页崩掉。
  static FsrsCard? _cardOf(UserProblemStateRow s) {
    final raw = s.fsrsState;
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      return FsrsCard.fromJson(j.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }
}

/// 供列表页/详情页共用的"下次复习"文案。
///
/// ## 为什么必须先看"分钟"，再看"天"
///
/// FSRS 在两种情况下会给出**分钟级**间隔：第一次评"忘了"，以及重学
/// （`intervalDays == 0` 时下次排在 10 分钟后，见 `FsrsScheduler.review`）。
/// 若直接按"距今天零点几天"算，今天 23:50 做完、下次 00:00 的卡会显示
/// "今天" —— 而那其实是明天。反过来，10 分钟后要复习的卡显示"今天"，
/// 等于告诉用户"今天不用管了"，正好把刚安排的学习步抹掉。
String describeDue(DateTime? due, {DateTime? now}) {
  if (due == null) return '未安排';
  final ts = now ?? DateTime.now();

  final minutes = due.difference(ts).inMinutes;
  if (minutes < 0) {
    // 逾期文案按天给：不足一天时说"刚过期"比"已逾期 0 天"诚实
    final overdueDays = -minutes ~/ (24 * 60);
    return overdueDays == 0 ? '已到期' : '已逾期 $overdueDays 天';
  }
  if (minutes < 60) return '$minutes 分钟后';
  if (minutes < 24 * 60) return '${minutes ~/ 60} 小时后';

  // 以下按"距今天零点几天"算 —— 到这里间隔已经 >= 1 天，
  // 日期差的舍入不再造成误导
  final days = due.difference(DateTime(ts.year, ts.month, ts.day)).inDays;
  if (days == 0) return '今天';
  if (days == 1) return '明天';
  if (days < 30) return '$days 天后';
  return '${(days / 30).round()} 个月后';
}

/// 从用户状态的 JSON 里取到期时间。
///
/// 解析失败返回 null —— 状态损坏时应当当成"新卡"，而不是让整个列表崩掉。
DateTime? dueOfState(UserProblemStateRow? state) {
  final raw = state?.fsrsState;
  if (raw == null || raw.isEmpty) return null;
  try {
    final j = jsonDecode(raw);
    if (j is Map) {
      final d = j['due'];
      if (d != null) return DateTime.tryParse(d.toString());
    }
  } catch (_) {
    // 见上文：损坏 = 新卡
  }
  return null;
}

/// 复习队列里的一道题摘要（列表页用，不读 Markdown 文件）。
class ProblemListRow {
  final String problemId;
  final String stemText;
  final String? primaryKpName;
  final int difficulty;
  final String? source;
  final bool needsReview;
  final bool aiTagged;
  final DateTime? createdAt;

  /// 用户状态（可能还没建卡）。
  final UserProblemStateRow? state;

  const ProblemListRow({
    required this.problemId,
    required this.stemText,
    this.primaryKpName,
    this.difficulty = 2,
    this.source,
    this.needsReview = false,
    this.aiTagged = false,
    this.createdAt,
    this.state,
  });

  int get wrongCount => state?.wrongCount ?? 0;
  double get mastery => state?.mastery ?? 0;
  bool get starred => state?.starred ?? false;
}
