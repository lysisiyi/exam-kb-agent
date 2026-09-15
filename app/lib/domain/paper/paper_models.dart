/// 组卷协议：模板、请求、结果。
///
/// ## 为什么要先写协议而不是直接写算法
///
/// 组卷有三个互相拉扯的目标（覆盖薄弱点 / 匹配难度 / 满足结构约束），
/// 任何实现都要在这些目标之间取舍。如果协议里不说清"哪些是硬约束、
/// 哪些是软偏好"，算法就没法判断什么时候该放弃一个偏好。
///
/// 所以这里把两件事分开：
/// - **硬约束**：题型、分值、题量。违反了卷子就是错的。
/// - **软偏好**：薄弱考点、考频权重、难度匹配、考点多样性。
///   在题量不够时按优先级依次放弃，并**如实报告放弃了什么**。
///
/// 最后一条是这一层的核心：**组卷不能偷偷降级**。
/// 用户拿到一份"150 分的卷子"，必须能知道它到底是不是真的按真题结构出的。
library;

/// 一个题位（试卷上的一道题）。
class PaperSeat {
  /// 题号（从 1 开始，跨 section 连续）。
  final int no;

  /// 所属大题名，如「选择题」。
  final String sectionName;

  /// 题型 id：`choice` / `fill` / `solve` / `proof`，
  /// 或通配符 [anyQtype]（「错题专练」用它 —— 那道大题不限题型）。
  final String qtype;

  /// 本题分值。null 表示"由抽到的题决定"（错题专练的 `score_per_item` 就是 null）。
  final int? score;

  /// 期望难度（1 基础 / 2 综合 / 3 拓展）。null 表示不限
  /// （错题专练的 `difficulty` 也是 null）。
  final int? targetDifficulty;

  const PaperSeat({
    required this.no,
    required this.sectionName,
    required this.qtype,
    this.score,
    this.targetDifficulty,
  });

  /// 不限定题型。
  static const String anyQtype = 'any';

  bool get isAnyQtype => qtype == anyQtype;
}

/// 分值为 null 的题位（错题专练）按这个数估分。
///
/// 为什么不给真实分值：那道大题的说明里写了"难度与分值不固定，由抽到的
/// 题目决定"。组卷时还没抽题，所以给不出真实值 —— 用一个明确标注为
/// 「估算」的默认分，并在结果里说明，比编一个看起来精确的假分值诚实。
const int kFallbackScorePerItem = 5;

/// 一个组卷模板。
class PaperTemplate {
  final String id;
  final String name;
  final String description;

  /// 总分。`null` 表示"按实际选中的题累加"（错题专练就是这样）。
  final int? totalScore;

  /// 建议时长（分钟）。
  final int? durationMinutes;

  /// 全部题位，已按题号顺序展开。
  final List<PaperSeat> seats;

  const PaperTemplate({
    required this.id,
    required this.name,
    required this.description,
    required this.seats,
    this.totalScore,
    this.durationMinutes,
  });

  int get questionCount => seats.length;

  /// 题型 → 题量。
  Map<String, int> get countsByQtype {
    final m = <String, int>{};
    for (final s in seats) {
      m[s.qtype] = (m[s.qtype] ?? 0) + 1;
    }
    return m;
  }

  /// 题型 → 分值合计。分值为 null 的题位按 [kFallbackScorePerItem] 估。
  Map<String, int> get scoresByQtype {
    final m = <String, int>{};
    for (final s in seats) {
      m[s.qtype] = (m[s.qtype] ?? 0) + (s.score ?? kFallbackScorePerItem);
    }
    return m;
  }
}

/// 组卷请求。
class PaperRequest {
  final PaperTemplate template;

  /// 科目。
  final String subject;

  /// 难度匹配的宽容度：
  /// - `0` = 必须精确匹配目标难度
  /// - `1` = 允许相邻一档（默认，题量不足时的现实选择）
  /// - `2` = 完全不管难度
  final int difficultyTolerance;

  /// 是否优先抽「用户做错过的题」。
  final bool preferWrong;

  /// 是否优先抽「薄弱考点」（掌握度低的）。
  final bool preferWeak;

  /// 考频权重的加权强度。0 = 不偏向高频考点。
  final double weightStrength;

  /// 是否避免同一考点在一份卷子里重复出现。
  final bool diversify;

  /// 已用过的题目 id（避免重复出卷）。
  final Set<String> excludeProblemIds;

  const PaperRequest({
    required this.template,
    required this.subject,
    this.difficultyTolerance = 1,
    this.preferWrong = true,
    this.preferWeak = true,
    this.weightStrength = 0.6,
    this.diversify = true,
    this.excludeProblemIds = const {},
  });
}

/// 一个题位的落位结果。
class PaperItem {
  final PaperSeat seat;
  final String problemId;

  /// 题干（用于预览与导出，不读 Markdown 文件）。
  final String stemText;

  final String? primaryKpName;

  /// 实际难度。可能与 [PaperSeat.targetDifficulty] 不同 ——
  /// 差别会在 [PaperResult.warnings] 里如实记录。
  final int actualDifficulty;

  /// 用户在这道题上的历史（用于"错题加权"的说明）。
  final int wrongCount;

  /// 本题分值。题位没给分值时（错题专练）为 null，展示时按
  /// [kFallbackScorePerItem] 估并标注。
  int? get score => seat.score;

  const PaperItem({
    required this.seat,
    required this.problemId,
    required this.stemText,
    required this.actualDifficulty,
    this.primaryKpName,
    this.wrongCount = 0,
  });
}

/// 组卷结果。
class PaperResult {
  final PaperTemplate template;
  final String subject;

  /// 已落位的题目，按题号顺序。**可能少于**模板题位数。
  final List<PaperItem> items;

  /// 空座位：题量不够时没能填上的题位。
  ///
  /// 单独列出来而不是静默缩短试卷：一份"22 题的卷子"交了 15 题，
  /// 用户必须知道少了哪 7 个题位、分别是什么题型。
  final List<PaperSeat> emptySeats;

  /// 降级说明。用户要能知道这份卷子偏离模板在哪里。
  final List<String> warnings;

  const PaperResult({
    required this.template,
    required this.subject,
    required this.items,
    this.emptySeats = const [],
    this.warnings = const [],
  });

  /// 实际总分。分值为 null 的题位按 [kFallbackScorePerItem] 估。
  int get totalScore =>
      items.fold(0, (sum, it) => sum + (it.seat.score ?? kFallbackScorePerItem));

  /// 分值里是否含估算（错题专练这类模板）。UI 上要标注出来。
  bool get hasEstimatedScores => items.any((it) => it.seat.score == null);

  /// 是否完整（所有题位都填上了）。
  bool get isComplete => emptySeats.isEmpty;

  /// 按大题分组，供导出时分节排版。
  Map<String, List<PaperItem>> get bySection {
    final m = <String, List<PaperItem>>{};
    for (final it in items) {
      m.putIfAbsent(it.seat.sectionName, () => []).add(it);
    }
    return m;
  }

  String get summary {
    final parts = <String>[
      '${items.length}/${template.questionCount} 题',
      '$totalScore 分',
      if (emptySeats.isNotEmpty) '缺 ${emptySeats.length} 题',
      if (warnings.isNotEmpty) '${warnings.length} 条调整',
    ];
    return parts.join(' · ');
  }
}
