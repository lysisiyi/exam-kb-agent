/// FSRS（Free Spaced Repetition Scheduler）调度器 —— 纯 Dart 实现。
///
/// 移植自 [py-fsrs](https://github.com/open-spaced-repetition/py-fsrs) 的核心调度逻辑
/// （FSRS-6 模型）。相比艾宾浩斯固定曲线，FSRS 会按用户的实际回忆表现动态调整
/// 每道题的复习间隔。
///
/// ## 为什么自己实现而不用现成包
/// 1. 本项目的复习对象是**数学题**，需要把三档反馈（忘了/吃力/轻松）映射成 rating；
/// 2. 需要与 Markdown/SQLite 双层存储的序列化格式配合；
/// 3. 避免引入 Dart 生态里维护状态不稳定的第三方包。
///
/// ## 未实现的部分（V2 再考虑）
/// - 参数优化器（`Optimizer`）：需要用用户的 `ReviewLog` 历史训练 21 个权重。
///   V1 使用 py-fsrs 的默认权重。
///
/// 默认权重取自 py-fsrs 的 `DEFAULT_PARAMETERS`。
library;

import 'dart:math' as math;

// ─────────────────────────────────────────────────────────────────────────────
// 公共类型
// ─────────────────────────────────────────────────────────────────────────────

/// 回忆质量评级。**只暴露三档**——Anki 的四档对普通用户是纯认知负担。
enum Rating {
  /// 完全不会 / 做错了。对应 FSRS 的 `Again`。
  forgot(1),

  /// 做出来了，但很费劲。对应 FSRS 的 `Hard`。
  hard(2),

  /// 一眼就有思路，流畅做对。对应 FSRS 的 `Easy`。
  easy(4);

  const Rating(this.value);
  final int value;

  static Rating fromValue(int v) => switch (v) {
        1 => Rating.forgot,
        2 => Rating.hard,
        4 => Rating.easy,
        // 用户历史数据里可能存在 Good(3)，按 Hard 处理以免崩
        3 => Rating.hard,
        _ => Rating.hard,
      };

  /// 中文短标签，用于 UI 按钮。
  String get label => switch (this) {
        Rating.forgot => '忘了',
        Rating.hard => '吃力',
        Rating.easy => '轻松',
      };
}

/// 卡片所处的学习阶段。
enum CardState {
  /// 新卡，从未复习过。
  learning,

  /// 复习中（已建立稳定记忆）。
  review,

  /// 复习失败后重新学习。
  relearning,
}

/// 单张卡片的调度状态。
///
/// 对应 `user_problem_state.fsrs_state`（JSON 列）的内容。
class FsrsCard {
  final DateTime? due;
  final double? stability;
  final double? difficulty;
  final int elapsedDays;
  final int scheduledDays;
  final int reps;
  final int lapses;
  final CardState state;
  final DateTime? lastReview;

  const FsrsCard({
    this.due,
    this.stability,
    this.difficulty,
    this.elapsedDays = 0,
    this.scheduledDays = 0,
    this.reps = 0,
    this.lapses = 0,
    this.state = CardState.learning,
    this.lastReview,
  });

  /// 全新的、从未复习过的卡片。
  factory FsrsCard.newCard() => const FsrsCard();

  bool get isNew => reps == 0 && state == CardState.learning;

  FsrsCard copyWith({
    DateTime? due,
    double? stability,
    double? difficulty,
    int? elapsedDays,
    int? scheduledDays,
    int? reps,
    int? lapses,
    CardState? state,
    DateTime? lastReview,
  }) =>
      FsrsCard(
        due: due ?? this.due,
        stability: stability ?? this.stability,
        difficulty: difficulty ?? this.difficulty,
        elapsedDays: elapsedDays ?? this.elapsedDays,
        scheduledDays: scheduledDays ?? this.scheduledDays,
        reps: reps ?? this.reps,
        lapses: lapses ?? this.lapses,
        state: state ?? this.state,
        lastReview: lastReview ?? this.lastReview,
      );

  Map<String, dynamic> toJson() => {
        'due': due?.toUtc().toIso8601String(),
        'stability': stability,
        'difficulty': difficulty,
        'elapsedDays': elapsedDays,
        'scheduledDays': scheduledDays,
        'reps': reps,
        'lapses': lapses,
        'state': state.name,
        'lastReview': lastReview?.toUtc().toIso8601String(),
      };

  factory FsrsCard.fromJson(Map<String, dynamic> j) => FsrsCard(
        due: _parseDate(j['due']),
        stability: (j['stability'] as num?)?.toDouble(),
        difficulty: (j['difficulty'] as num?)?.toDouble(),
        elapsedDays: (j['elapsedDays'] as num?)?.toInt() ?? 0,
        scheduledDays: (j['scheduledDays'] as num?)?.toInt() ?? 0,
        reps: (j['reps'] as num?)?.toInt() ?? 0,
        lapses: (j['lapses'] as num?)?.toInt() ?? 0,
        state: CardState.values.firstWhere(
          (s) => s.name == j['state'],
          orElse: () => CardState.learning,
        ),
        lastReview: _parseDate(j['lastReview']),
      );

  static DateTime? _parseDate(Object? v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }

  @override
  String toString() => 'FsrsCard(state: ${state.name}, reps: $reps, '
      'lapses: $lapses, stability: ${stability?.toStringAsFixed(2)}, '
      'difficulty: ${difficulty?.toStringAsFixed(2)}, due: $due)';
}

/// 一次复习的结果。
class ReviewOutcome {
  final FsrsCard card;

  /// 本次复习后，到下次复习前的间隔天数。
  final int intervalDays;

  const ReviewOutcome({required this.card, required this.intervalDays});
}

// ─────────────────────────────────────────────────────────────────────────────
// 调度器
// ─────────────────────────────────────────────────────────────────────────────

/// FSRS 调度器。
///
/// 用法：
/// ```dart
/// final s = FsrsScheduler();
/// final r = s.review(FsrsCard.newCard(), Rating.hard, DateTime.now());
/// print(r.card.due);           // 下次复习时间
/// print(s.retrievability(r.card, DateTime.now()));  // 当前记忆保持率
/// ```
class FsrsScheduler {
  /// FSRS-6 的 21 个权重。取自 py-fsrs 默认值。
  ///
  /// ⚠️ 在积累到足够的 `ReviewLog`（经验值 1000+ 条）之前**不要修改**，
  /// 手调这些参数几乎一定让调度变差。V2 会实现优化器自动拟合。
  static const List<double> defaultParameters = [
    0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194,
    0.001, 1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629,
    1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
  ];

  /// 期望记忆保持率。0.9 表示"当正确回忆的概率降到 90% 时就安排复习"。
  ///
  /// 调高 → 复习次数变多、记得更牢；调低 → 复习次数变少、可能忘。
  final double desiredRetention;

  /// 最大间隔天数（默认 100 年，等于不限制）。考研场景可设为 365。
  final int maximumInterval;

  /// 间隔模糊化：给计算出的间隔加一点随机扰动，避免大量卡片挤在同一天。
  final bool enableFuzzing;

  final List<double> w;

  FsrsScheduler({
    this.desiredRetention = 0.9,
    this.maximumInterval = 36500,
    this.enableFuzzing = true,
    List<double>? parameters,
    math.Random? random,
  })  : w = parameters ?? defaultParameters,
        _rand = random ?? math.Random();

  final math.Random _rand;

  static const double _decay = -0.5;

  /// 使 `R(t, S) = 0.9` 成立时的因子，推导见 FSRS 论文。
  static double get _factor => math.pow(0.9, 1 / _decay).toDouble() - 1;

  // ── 记忆模型 ──────────────────────────────────────────────────────────────

  /// 在间隔 [elapsedDays] 天后，记忆保持率 R ∈ (0, 1]。
  double retrievabilityOf(double stability, int elapsedDays) {
    if (stability <= 0) return 0;
    return math
        .pow(1 + _factor * elapsedDays / stability, _decay)
        .toDouble()
        .clamp(0.0, 1.0);
  }

  /// 已调度卡片的当前保持率。新卡返回 0。
  double retrievability(FsrsCard card, [DateTime? now]) {
    final s = card.stability;
    if (s == null || s <= 0 || card.lastReview == null) return 0;
    final days = _daysBetween(card.lastReview!, now ?? DateTime.now());
    return retrievabilityOf(s, days);
  }

  /// 初始稳定性 S₀(G)。G 为首次评级。
  double initialStability(Rating rating) => w[rating.value - 1].clamp(0.01, 36500);

  /// 初始难度 D₀(G)，并夹到 [1, 10]。
  double initialDifficulty(Rating rating) =>
      (w[4] - math.exp(w[5] * (rating.value - 1)) + 1).clamp(1.0, 10.0);

  /// 难度更新。用线性阻尼 + 均值回归，避免难度无限漂移。
  double nextDifficulty(double difficulty, Rating rating) {
    final deltaD = -w[6] * (rating.value - 3);
    final damped = difficulty + deltaD * (10 - difficulty) / 9;
    final target = initialDifficulty(Rating.easy); // 均值回归目标
    return (w[7] * target + (1 - w[7]) * damped).clamp(1.0, 10.0);
  }

  /// 成功回忆后的稳定性增长。
  double stabilityAfterRecall(
    double difficulty,
    double stability,
    double retrievability,
    Rating rating,
  ) {
    final hardPenalty = rating == Rating.hard ? w[15] : 1.0;
    final easyBonus = rating == Rating.easy ? w[16] : 1.0;
    final growth = math.exp(w[8]) *
        (11 - difficulty) *
        math.pow(stability, -w[9]) *
        (math.exp((1 - retrievability) * w[10]) - 1) *
        hardPenalty *
        easyBonus;
    return stability * (1 + growth);
  }

  /// 遗忘后的稳定性（lapse）。
  double stabilityAfterForget(
    double difficulty,
    double stability,
    double retrievability,
  ) {
    final sMin = math.max(stability / math.exp(w[17] * w[18]), 0.01);
    return w[11] *
        math.pow(difficulty, -w[12]) *
        (math.pow(stability + 1, w[13]) - 1) *
        math.exp((1 - retrievability) * w[14]) *
        sMin;
  }

  /// 由稳定性反推间隔天数。
  int intervalFromStability(double stability) {
    final raw = (stability / _factor) * (math.pow(desiredRetention, 1 / _decay) - 1);
    final days = raw.round().clamp(1, maximumInterval);
    return enableFuzzing ? _applyFuzz(days) : days;
  }

  // ── 主入口 ────────────────────────────────────────────────────────────────

  /// 对一张卡片执行一次复习，返回新的卡片状态与间隔。
  ReviewOutcome review(FsrsCard card, Rating rating, DateTime now) {
    final isFirst = card.state == CardState.learning && card.reps == 0;

    double stability;
    double difficulty;
    CardState nextState;
    int intervalDays;

    // 从卡片上次复习到现在的实际间隔
    final elapsed = card.lastReview == null
        ? 0
        : _daysBetween(card.lastReview!, now);

    if (isFirst) {
      stability = initialStability(rating);
      difficulty = initialDifficulty(rating);
      nextState =
          rating == Rating.forgot ? CardState.learning : CardState.review;
      intervalDays = rating == Rating.forgot
          ? 0 // 当天再来一次
          : intervalFromStability(stability);
    } else {
      final s = card.stability ?? initialStability(Rating.hard);
      final d = card.difficulty ?? initialDifficulty(Rating.hard);
      final r = retrievabilityOf(s, elapsed);

      difficulty = nextDifficulty(d, rating);

      if (rating == Rating.forgot) {
        stability = stabilityAfterForget(difficulty, s, r);
        nextState = CardState.relearning;
        intervalDays = 0; // 重学：当天再练
      } else {
        stability = stabilityAfterRecall(difficulty, s, r, rating);
        nextState = CardState.review;
        intervalDays = intervalFromStability(stability);
      }
    }

    stability = stability.clamp(0.01, 36500);

    // 间隔为 0 时，下次复习安排在 10 分钟后（同一天内再练一次）
    final due = intervalDays <= 0
        ? now.add(const Duration(minutes: 10))
        : now.add(Duration(days: intervalDays));

    return ReviewOutcome(
      card: card.copyWith(
        due: due,
        stability: stability,
        difficulty: difficulty,
        elapsedDays: elapsed,
        scheduledDays: intervalDays,
        reps: card.reps + 1,
        lapses: rating == Rating.forgot ? card.lapses + 1 : card.lapses,
        state: nextState,
        lastReview: now,
      ),
      intervalDays: intervalDays,
    );
  }

  /// 某张卡片现在是否到期需要复习。
  bool isDue(FsrsCard card, [DateTime? now]) {
    if (card.due == null) return true; // 新卡立即到期
    return !card.due!.isAfter(now ?? DateTime.now());
  }

  // ── 内部工具 ──────────────────────────────────────────────────────────────

  static int _daysBetween(DateTime a, DateTime b) {
    final d = b.difference(a).inHours / 24.0;
    return d < 0 ? 0 : d.floor();
  }

  /// FSRS 官方的间隔模糊算法：间隔越长，允许的抖动范围越大。
  /// 目的：避免大量卡片因为同一天录入而永远挤在同一天复习。
  int _applyFuzz(int days) {
    if (days < 2) return days;

    final (double minI, double maxI) = switch (days) {
      < 3 => (1, 1),
      < 5 => (1, 2),
      < 8 => (2, 3),
      < 13 => (3, 4),
      < 22 => (4, 5),
      < 40 => (5, 6),
      < 70 => (6, 7),
      < 110 => (7, 8),
      < 170 => (8, 9),
      < 260 => (9, 10),
      < 400 => (10, 11),
      _ => (11, 12),
    };

    final delta = maxI - minI;
    final jitter = delta <= 0 ? 0.0 : _rand.nextDouble() * delta - delta / 2;
    final newDays = (days + jitter).round();

    // 模糊化只允许小幅扰动：下限 1 天，上限不得超过原间隔（避免把间隔拉长）。
    return newDays.clamp(1, days);
  }
}
