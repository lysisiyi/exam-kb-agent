/// 掌握度画像：把"我哪里不行"算出来。
///
/// ## 这一层要回答的问题
///
/// 错题本告诉你"我错过哪些题"，复习页告诉你"今天该复习什么"，
/// 但都不回答**"我最该补哪里"**。那是聚合问题：把几百道题的复习状态
/// 上卷到知识点与章节上，才能排出"最薄弱的考点"。
///
/// ## ⚠️ 掌握度必须**读时重算**，不能读 `user_problem_state.mastery`（T37）
///
/// 那一列存的是**打分那一刻**算出的可提取性。可提取性会随时间衰减 ——
/// 这是 FSRS 的基本假设 —— 而列里的值**不会**跟着变。
///
/// 后果不是"略有偏差"，而是**画像系统性失真**：一道 30 天前复习过、
/// 当时掌握 90% 的题，今天可能只剩 40%，而快照一直说 90%。
/// 于是"薄弱点"排不出来 —— 越是拖久了没复习的考点，越是被高估，
/// 而那恰恰是用户最该看到的。
///
/// 所以这里用 `FsrsScheduler.retrievability(card, now)` 按**当前时间**
/// 重算。代价是解一次 JSON + 一次幂运算（五千条也就几十毫秒），
/// 换来的是"画像说的是今天的情况"。
///
/// ## 为什么是"平均"而不是"最低"
///
/// 一个考点下有 10 道题，其中 1 道掌握 10%、9 道 90% —— 这个考点到底行不行？
/// 取最低会把任何一道失手题变成"整个考点薄弱"，取平均又会被数量稀释。
///
/// 这里取**平均**，但把 `wrongCount` 与 `reviewedCount` 一起报出来，
/// 让排序公式与界面都能看见"这个平均是几道题平均出来的"。
/// 不假装一个数就能概括一切。
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../data/db/database.dart';
import '../../data/error_causes.dart';
import '../../domain/fsrs/fsrs_scheduler.dart';
import '../../domain/knowledge/knowledge_point.dart';

/// 错几次算"顽固错题"。与 mockup 里"错≥3次"的标注一致。
const int kStubbornWrongThreshold = 3;

/// 掌握度曲线的天数。
const int kTrendDays = 30;

/// 没有主考点的题归到这个名字下。
///
/// 单独列出来而不是丢掉：丢掉的话"各章节题数之和"对不上总题数，
/// 而用户会拿这个差额去问"我那 12 道题去哪了"。
const String kUnlabeledChapterName = '未标注考点的题';

/// 一个知识点的掌握情况。
class KpMastery {
  final String kpId;
  final String kpName;

  /// 所属章节（第 3 段 id）与章节名。取不到时为 null。
  final String? chapterId;
  final String? chapterName;

  /// 题库里挂在这个考点下的题数。
  final int problemCount;

  /// 其中有**可算掌握度**的题数（复习过、且 FSRS 状态完好）。
  ///
  /// ⚠️ 必须一起报出来：只报一个平均掌握度，用户会以为它是 10 道题的结论，
  /// 而实际上可能只有 1 道复习过。`reviewedCount / problemCount`
  /// 就是这条信息的诚实版本。
  final int reviewedCount;

  /// 累计错误次数（该考点下所有题之和）。
  final int wrongCount;

  /// 错 ≥ [kStubbornWrongThreshold] 次的题数（"顽固错题"）。
  final int stubbornCount;

  /// **此刻**的平均掌握度 0–1。null 表示这个考点下一道题都没复习过。
  final double? mastery;

  /// 考频权重。用于界面标注"高频"。
  final double? examWeight;

  const KpMastery({
    required this.kpId,
    required this.kpName,
    this.chapterId,
    this.chapterName,
    this.problemCount = 0,
    this.reviewedCount = 0,
    this.wrongCount = 0,
    this.stubbornCount = 0,
    this.mastery,
    this.examWeight,
  });

  /// 有没有可用的复习数据。
  bool get hasData => reviewedCount > 0 && mastery != null;

  /// 薄弱度评分。**越大越薄弱**。
  ///
  /// ## 这个公式是怎么来的（不是拍的）
  ///
  /// ```
  /// weakness = (1 − mastery) × (1 + log2(1 + wrongCount))
  /// ```
  ///
  /// - **掌握度低是主因**：`(1 − mastery)` 就是它，满分 1。
  /// - **错得多说明它反复暴露问题**：乘上 `(1 + log2(1 + wrongCount))`。
  /// - **为什么用 log**：错次数是长尾分布（有人某道题错 20 次）。
  ///   不压缩的话"错 20 次、掌握 60%"会压过"错 2 次、掌握 10%" ——
  ///   而后者显然更该补。log2 让它缓慢增长：1→2、3→3、7→4、15→5。
  /// - **错 0 次时因子为 1**：纯掌握度仍然说话，不会被错次数绑架。
  ///
  /// ⚠️ 这是**启发式**，不是定理。验收标准写的是"薄弱点排序符合主观感受"，
  /// 而主观感受只能由用户用一段时间来判。所以界面把两个组成项
  /// （掌握度、错次数）都显示出来 —— 排序理由可核对，
  /// 用户不认同也能看出是哪个数导致的。
  double get weakness {
    final m = mastery;
    if (m == null) return 0;
    return (1 - m.clamp(0.0, 1.0)) * (1 + log2(1 + wrongCount.toDouble()));
  }

  /// 掌握度的百分比文案。
  String get masteryText =>
      mastery == null ? '未复习' : '掌握 ${(mastery! * 100).round()}%';

  @override
  String toString() => 'KpMastery($kpName, mastery=$mastery, '
      'wrong=$wrongCount, reviewed=$reviewedCount/$problemCount)';
}

/// 一个章节的掌握情况（把叶子上的数据上卷）。
class ChapterMastery {
  final String chapterId;
  final String chapterName;
  final int problemCount;
  final int reviewedCount;
  final int wrongCount;
  final double? mastery;
  final double? examWeight;

  const ChapterMastery({
    required this.chapterId,
    required this.chapterName,
    this.problemCount = 0,
    this.reviewedCount = 0,
    this.wrongCount = 0,
    this.mastery,
    this.examWeight,
  });

  double get weakness {
    final m = mastery;
    if (m == null) return 0;
    return (1 - m.clamp(0.0, 1.0)) * (1 + log2(1 + wrongCount.toDouble()));
  }

  String get masteryText =>
      mastery == null ? '未复习' : '掌握 ${(mastery! * 100).round()}%';
}

/// 错因分布的一项。
class CauseStat {
  final String causeId;
  final String causeName;

  /// 带这个错因的题数。
  final int problemCount;

  /// 这些题的累计错误次数。
  final int wrongCount;

  const CauseStat({
    required this.causeId,
    required this.causeName,
    this.problemCount = 0,
    this.wrongCount = 0,
  });
}

/// 掌握度曲线上的一个点（一天）。
class TrendPoint {
  final DateTime day;

  /// 当天复习次数。
  final int reviews;

  /// 当天"做出来了"的次数（评分 ≥ 2，即不是"忘了"）。
  ///
  /// 存**次数**而不是比率：比率可以由 [passRate] 现算，
  /// 而次数是原始数据，将来想换一种口径也不用改存储。
  final int passed;

  /// 当天平均评分（1 = 忘了 · 2 = 吃力 · 4 = 轻松）。没复习时为 0。
  final double avgRating;

  const TrendPoint({
    required this.day,
    this.reviews = 0,
    this.passed = 0,
    this.avgRating = 0,
  });

  /// 当天"做出来了"的比例。
  ///
  /// 这个数是**精确**的（passed / reviews），不是从平均评分反推的 ——
  /// 平均评分 2.5 既可能是"一半忘了、一半轻松"，也可能是"全部吃力"，
  /// 反推出来的比率会是编的。
  double get passRate => reviews == 0 ? 0 : passed / reviews;
}

/// 画像总览。
class MasteryReport {
  /// 最薄弱的考点，**已按 [KpMastery.weakness] 降序**。
  ///
  /// ⚠️ 这是**截断过**的列表（只取前 `topKp` 个），用于"最薄弱"那一段 UI。
  /// 需要逐点查全部考点时用 [kps]。
  final List<KpMastery> weakest;

  /// **全部**考点的掌握情况（含没有复习记录的，它们的 `mastery` 为 null）。
  ///
  /// 与 [weakest] 的唯一区别是**不截断**。知识库图谱要按掌握度给 270 个
  /// 叶子逐个着色，需要的就是"全量 + 可逐点查" —— 用截断列表会导致
  /// 大部分节点没有颜色，而"没有颜色"与"没复习过"在界面上长得一样。
  ///
  /// 顺序与 [weakest] 同源（薄弱度降序），调用方一般按 `kpId` 建索引。
  final List<KpMastery> kps;

  /// 按章节聚合（含没有复习数据的章节，便于看出"哪一章还没碰"）。
  final List<ChapterMastery> chapters;

  /// 错因分布，按题数降序。
  final List<CauseStat> causes;

  /// 掌握度曲线（最近 [kTrendDays] 天，含没复习的空白天）。
  final List<TrendPoint> trend;

  final int totalProblems;

  /// 至少复习过一次的题数。
  final int reviewedProblems;

  /// 从未复习过的新卡数。
  final int newProblems;

  /// 错 ≥ [kStubbornWrongThreshold] 次的题数。
  final int stubbornProblems;

  /// 全局平均掌握度（只统计有复习记录的题）。null 表示一条都没有。
  final double? overallMastery;

  /// **索引里错因列为空的题数**。
  ///
  /// schema v4 才加的 `error_causes` 列，旧行会一直是空的（增量重建按
  /// mtime 跳过未改动的文件）。非零时画像必须提示"错因分布不完整，
  /// 建议重建索引" —— 一份只统计了新题的分布看起来有数据，实际是错的。
  final int missingCauseData;

  const MasteryReport({
    this.weakest = const [],
    this.kps = const [],
    this.chapters = const [],
    this.causes = const [],
    this.trend = const [],
    this.totalProblems = 0,
    this.reviewedProblems = 0,
    this.newProblems = 0,
    this.stubbornProblems = 0,
    this.overallMastery,
    this.missingCauseData = 0,
  });

  bool get isEmpty => totalProblems == 0;
  bool get hasReviewData => reviewedProblems > 0;

  String get overallText => overallMastery == null
      ? '还没有复习记录'
      : '平均掌握 ${(overallMastery! * 100).round()}%';
}

/// 从用户状态行算出**此刻**的掌握度。
///
/// null = 无从谈起（新卡 / FSRS 状态损坏 / 没有状态行）。
///
/// 抽成顶层函数是为了让**画像与错题本列表用同一套逻辑** ——
/// 两处各写一遍的话，一处按读时重算、一处读快照列，
/// 同一个考点在列表里显示"掌握 90%"、在画像里显示"掌握 40%"，
/// 而用户完全无法判断该信哪个。
double? masteryNowOf(
  UserProblemStateRow? state,
  FsrsScheduler scheduler,
  DateTime now,
) {
  if (state == null) return null;
  final card = cardOf(state);
  if (card == null) return null;
  final r = scheduler.retrievability(card, now);
  // `retrievability` 对新卡 / 无稳定性返回 0 —— 那是"没有信息"，
  // 不是"掌握度为 0"。当成 0 会把一堆没复习过的题算成"完全不会"，
  // 于是"最薄弱考点"全变成没有复习记录的章节。
  return r <= 0 ? null : r;
}

/// 解析 FSRS 状态。损坏时当作新卡（与 `ReviewRepository` 同一策略）。
FsrsCard? cardOf(UserProblemStateRow s) {
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

/// 画像服务。**纯读**，不改任何数据。
class MasteryService {
  final AppDatabase db;

  /// 调度器。注入是为了在测试里固定时间、去掉 fuzzing。
  final FsrsScheduler scheduler;

  /// 错因词表（id → 中文名）。为 null 时直接用 id 展示。
  final ErrorCauseCatalog? causes;

  MasteryService({
    required this.db,
    FsrsScheduler? scheduler,
    this.causes,
  }) : scheduler = scheduler ?? FsrsScheduler();

  /// 算出一份画像。
  ///
  /// [now] 用于掌握度重算 —— 传它是为了让测试能固定"现在"。
  Future<MasteryReport> build({
    required KnowledgeBase knowledge,
    DateTime? now,
    int topKp = 20,
  }) async {
    final ts = now ?? DateTime.now();

    // ── 主考点映射 ─────────────────────────────────────────────────────
    //
    // ⚠️ 只能来自 `problem_knowledge` 的 `role == 'primary'`。
    //
    // **不能**用 `problems_index.primary_kp_name` 反推：那一列是本体载入时
    // 冗余写入的，本体没载入时是 null（见 `IndexBuilder._upsert`），
    // 于是所有题会落进同一个桶 —— 掌握度聚合会**静默失效**
    // （排序看着有结果，其实全是一样的数）。组卷那边踩过一模一样的坑，
    // 见 `PaperRepository.candidates`。
    final links = await db.select(db.problemKnowledge).get();
    final primaryKpOf = <String, String>{};
    for (final l in links) {
      if (l.role == 'primary') primaryKpOf[l.problemId] = l.kpId;
    }

    final indexRows = await db.select(db.problemsIndex).get();
    final states = await db.select(db.userProblemState).get();
    final stateById = {for (final s in states) s.problemId: s};

    // ── 逐题：算出**此刻**的掌握度 ──────────────────────────────────────
    var reviewed = 0;
    var fresh = 0;
    var stubborn = 0;
    var missingCauses = 0;
    var masterySum = 0.0;

    final byKp = <String, _Acc>{};
    final byChapter = <String, _Acc>{};

    for (final row in indexRows) {
      final state = stateById[row.id];
      final wrong = state?.wrongCount ?? 0;

      if (row.errorCauses == null || row.errorCauses!.isEmpty) {
        missingCauses++;
      }

      final m = masteryOf(state, ts);
      if (m == null) {
        // 新卡（或 FSRS 状态损坏）：没有可谈的掌握度
        if (state == null || _cardOf(state) == null) fresh++;
      } else {
        reviewed++;
        masterySum += m;
      }

      if (wrong >= kStubbornWrongThreshold) stubborn++;

      final kpId = primaryKpOf[row.id];

      // 考点聚合：只统计**主考点**。
      //
      // 一道题可能挂多个次考点，把它们全算进去会让次考点吃到大题的分，
      // 被排到薄弱榜前面 —— 而用户并没有在那里反复出错。
      // 主考点才是"这道题在考什么"。
      if (kpId != null && kpId.isNotEmpty) {
        final acc = byKp.putIfAbsent(kpId, _Acc.new);
        acc.add(problemCount: 1, wrongCount: wrong, mastery: m);
        if (wrong >= kStubbornWrongThreshold) acc.stubbornCount++;
      }

      // 章节聚合：直接按题算，**不经过考点** —— 否则没标注考点的题
      // 会从章节统计里消失，各章之和就对不上总题数了。
      final node = kpId == null ? null : knowledge.byId[kpId];
      final chapterId = node?.chapterId ?? kpId;
      final chapterAcc = byChapter.putIfAbsent(
        chapterId ?? '',
        _Acc.new,
      );
      chapterAcc.add(problemCount: 1, wrongCount: wrong, mastery: m);
    }

    // ── 考点列表与排序 ────────────────────────────────────────────────
    final kpList = <KpMastery>[];
    for (final e in byKp.entries) {
      final node = knowledge.byId[e.key];
      final chapterId = node?.chapterId;
      kpList.add(KpMastery(
        kpId: e.key,
        kpName: node?.name ?? e.key,
        chapterId: chapterId,
        chapterName:
            chapterId == null ? null : knowledge.byId[chapterId]?.name,
        problemCount: e.value.problemCount,
        reviewedCount: e.value.reviewedCount,
        wrongCount: e.value.wrongCount,
        stubbornCount: e.value.stubbornCount,
        mastery: e.value.mastery,
        examWeight: node?.examWeight,
      ));
    }

    // 薄弱度降序。没有复习数据的 weakness = 0，会排在最后 ——
    // 但**不丢掉**："这一章还没碰过"本身是信息。
    kpList.sort((a, b) {
      final w = b.weakness.compareTo(a.weakness);
      if (w != 0) return w;
      final byWrong = b.wrongCount.compareTo(a.wrongCount);
      if (byWrong != 0) return byWrong;
      return a.kpId.compareTo(b.kpId);
    });

    // ── 章节列表 ──────────────────────────────────────────────────────
    final chapterList = [
      for (final e in byChapter.entries)
        ChapterMastery(
          chapterId: e.key,
          chapterName: e.key.isEmpty
              ? kUnlabeledChapterName
              : (knowledge.byId[e.key]?.name ?? e.key),
          problemCount: e.value.problemCount,
          reviewedCount: e.value.reviewedCount,
          wrongCount: e.value.wrongCount,
          mastery: e.value.mastery,
          examWeight: knowledge.byId[e.key]?.examWeight,
        ),
    ]..sort((a, b) {
        // 未标注那一组恒定放最后：它不是章节，不该跟章节比薄弱度
        if (a.chapterId.isEmpty != b.chapterId.isEmpty) {
          return a.chapterId.isEmpty ? 1 : -1;
        }
        final w = b.weakness.compareTo(a.weakness);
        return w != 0 ? w : a.chapterId.compareTo(b.chapterId);
      });

    return MasteryReport(
      weakest: kpList.take(topKp).toList(),
      kps: kpList,
      chapters: chapterList,
      causes: _causeStats(indexRows, stateById),
      trend: await _trend(ts),
      totalProblems: indexRows.length,
      reviewedProblems: reviewed,
      newProblems: fresh,
      stubbornProblems: stubborn,
      overallMastery: reviewed == 0 ? null : masterySum / reviewed,
      missingCauseData: missingCauses,
    );
  }

  /// 一道题**此刻**的掌握度。null = 无从谈起（新卡 / 状态损坏）。
  ///
  /// 转发到 [masteryNowOf] —— 画像与错题本列表共用同一份实现。
  double? masteryOf(UserProblemStateRow? state, DateTime now) =>
      masteryNowOf(state, scheduler, now);

  /// 错因分布。
  List<CauseStat> _causeStats(
    List<ProblemIndexRow> rows,
    Map<String, UserProblemStateRow> stateById,
  ) {
    final byCause = <String, _Acc>{};
    for (final row in rows) {
      final raw = row.errorCauses;
      if (raw == null || raw.isEmpty) continue;
      final wrong = stateById[row.id]?.wrongCount ?? 0;
      for (final id in _decodeCauses(raw)) {
        byCause.putIfAbsent(id, _Acc.new).add(
              problemCount: 1,
              wrongCount: wrong,
            );
      }
    }

    final out = [
      for (final e in byCause.entries)
        CauseStat(
          causeId: e.key,
          causeName: causes?.nameOf(e.key) ?? e.key,
          problemCount: e.value.problemCount,
          wrongCount: e.value.wrongCount,
        ),
    ]..sort((a, b) {
        final byCount = b.problemCount.compareTo(a.problemCount);
        return byCount != 0 ? byCount : a.causeId.compareTo(b.causeId);
      });
    return out;
  }

  /// 复习曲线：最近 [kTrendDays] 天，**含没复习的空白天**。
  ///
  /// 空白的天要留在序列里 —— 去掉它们会把"停了半个月"画成一条连续的线，
  /// 而那正是用户最需要看见的信息。
  Future<List<TrendPoint>> _trend(DateTime now) async {
    final start = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: kTrendDays - 1));

    final logs = await (db.select(db.reviewLogs)
          ..where((t) => t.reviewedAt.isBiggerOrEqualValue(start)))
        .get();

    // 按**本地日**分组
    final byDay = <DateTime, List<int>>{};
    for (final l in logs) {
      final d = DateTime(
        l.reviewedAt.year,
        l.reviewedAt.month,
        l.reviewedAt.day,
      );
      byDay.putIfAbsent(d, () => []).add(l.rating);
    }

    final out = <TrendPoint>[];
    for (var i = 0; i < kTrendDays; i++) {
      final day = start.add(Duration(days: i));
      final ratings = byDay[day] ?? const <int>[];
      out.add(TrendPoint(
        day: day,
        reviews: ratings.length,
        // 评分 1 = 忘了；≥2（吃力 / 轻松）都算做出来了
        passed: ratings.where((r) => r >= 2).length,
        avgRating: ratings.isEmpty
            ? 0
            : ratings.reduce((a, b) => a + b) / ratings.length,
      ));
    }
    return out;
  }

  static List<String> _decodeCauses(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is List) {
        return v
            .map((e) => e?.toString() ?? '')
            .where((e) => e.isNotEmpty)
            .toList();
      }
    } catch (_) {
      // 索引里的 JSON 坏了不该让整张画像挂掉
    }
    return const [];
  }

  /// 解析 FSRS 状态。损坏时当作新卡（与 `ReviewRepository` 同一策略）。
  static FsrsCard? _cardOf(UserProblemStateRow s) => cardOf(s);
}

/// 聚合累加器。
class _Acc {
  int problemCount = 0;
  int reviewedCount = 0;
  int wrongCount = 0;
  int stubbornCount = 0;
  double masterySum = 0;

  void add({int problemCount = 0, int wrongCount = 0, double? mastery}) {
    this.problemCount += problemCount;
    this.wrongCount += wrongCount;
    if (mastery != null) {
      masterySum += mastery;
      reviewedCount++;
    }
  }

  double? get mastery => reviewedCount == 0 ? null : masterySum / reviewedCount;
}

/// 以 2 为底的对数。不引 `dart:math` 只为一次换底
/// （与 `PaperComposer._log2` 同一写法）。
double log2(double x) {
  var r = 0.0;
  var v = x;
  while (v >= 2) {
    v /= 2;
    r += 1;
  }
  return r;
}
