/// 组卷引擎。
///
/// ## 问题定义
///
/// 给一批题位（每个题位有题型与难度目标），从题库里选题目填进去，
/// 使：
/// - **硬约束**：题型必须一致（选择题的位置不能放解答题）
/// - 软偏好按优先级：① 用户的薄弱考点 ② 做错过的题 ③ 考频高的考点
///   ④ 难度贴合题位目标 ⑤ 考点多样性（同一考点别在一份卷里刷屏）
///   ⑥ **错因对症**（"错题专练"里优先选重做本题真有用的题，见 `_score` ⑥）
///
/// ## 为什么用贪心，而不是精确求解
///
/// 这是**指派问题**，理论上可以用匈牙利算法或整数规划求最优。
/// 但个人题库是几百到几千条量级，而 V1_PLAN 明确写了「够用就好」：
/// 贪心（按优先级给每个题位选当前得分最高的题）在毫秒级出结果，
/// 质量差距用户感知不到。
///
/// ⚠️ **没有回溯。** 这里的注释曾经写着"贪心 + 少量回溯（选不出时退一步换掉）"，
/// 但代码里从来没有回溯：某个题位挑不出题时**直接**进 `emptySeats`
/// （见 `compose` 的主循环），不会回头换掉前面已经放好的题。
/// 所以"题位填不满"是**必然**会发生的结果，而不是兜底 ——
/// 这也正是所有空位都必须记进 `emptySeats`、所有放宽都必须记进
/// `warnings` 的原因：用户得能从界面上一眼看出来。
///
/// 真到 V2 要换 OR-Tools CP-SAT 时，**只需要换本文件** ——
/// 协议在 `paper_models.dart`，与算法无关。
///
/// ## 一个必须守住的纪律：不静默降级
///
/// 题量不够时这份卷子一定不完美。实现里所有"放宽"都记进 `warnings`，
/// 所有填不上的题位都进 `emptySeats`。用户拿到一份"150 分真题结构卷"，
/// 必须能知道它到底哪里不像真题 —— 而不是自己数出来少了 7 题。
library;

import '../../domain/paper/paper_models.dart';

/// 参与组卷的一道候选题。与数据库行解耦，便于测试。
class Candidate {
  final String problemId;
  final String stemText;
  final String qtype;
  final int difficulty;
  final String subject;

  /// 主考点 id（可能为空 —— 未标注的题）。
  final String? primaryKpId;
  final String? primaryKpName;

  /// 主考点考频权重 0–1（索引里冗余存的，取不到时为 null）。
  final double? primaryKpWeight;

  /// 用户在这道题上累计做错次数（0 表示没做错过）。
  final int wrongCount;

  /// 用户在这个考点上的掌握度 0–1（取不到时为 null）。
  final double? kpMastery;

  /// 这道题标的错因 id（用户侧，如 `['concept', 'calc']`）。
  ///
  /// 空列表表示"没标错因"（不是"没错"）—— 打分时**不惩罚也不奖励**，
  /// 否则没标错因的题会被系统性排到最后，而它们恰恰是用户需要
  /// 被提醒去补标注的那批（与 `_kpUsed` 对未标注题的处理同一理由）。
  final List<String> errorCauseIds;

  const Candidate({
    required this.problemId,
    required this.stemText,
    required this.qtype,
    required this.difficulty,
    required this.subject,
    this.primaryKpId,
    this.primaryKpName,
    this.primaryKpWeight,
    this.wrongCount = 0,
    this.kpMastery,
    this.errorCauseIds = const [],
  });
}

/// 组卷引擎。
class PaperComposer {
  /// 是否允许把某个题位换成**其它题型**的题。
  ///
  /// 默认 false。理由见 `compose` 里关于"题型是硬约束"的说明 ——
  /// 把填空题换成解答题会让整份卷子的结构失真（分值、时长全变）。
  final bool allowTypeMismatch;

  const PaperComposer({this.allowTypeMismatch = false});

  /// 同一个考点在本卷里已被用过时，每次降低多少分。
  ///
  /// ## 这个数是怎么定下来的（不是拍脑袋）
  ///
  /// 实测踩过：最初用 1.2，结果"错 5 次"的题带来的优势（约 5.4 分）
  /// 远大于 1.2 的惩罚，于是**同一个考点的题被连抽 4 次**，
  /// 多样性形同虚设。
  ///
  /// 算一下需要多大才能真正起效。只看"错题优势"这一项：
  /// `wrong=N` 得 `(1 + log2(N+1)) * 1.5`，`wrong=0` 得 0。
  /// 所以
  /// - 要让"错 1 次"的题输给没用过的考点：惩罚 > 1.5
  /// - 要压住"错 3 次"：惩罚 > 3.0
  /// - 要压住"错 5 次"：惩罚 > 5.4
  ///
  /// 取 5.5 会矫枉过正：那等于"用过一次的考点一律不再选"，
  /// 而题库小的时候这会让卷子填不满。所以取 **2.6**：
  /// 压得住"错 1–2 次"的轻微优势，压不住"错 5 次"这种强信号 ——
  /// 后者本来就该优先出（用户错得最多的题正是最该练的）。
  ///
  /// 真正保证多样性的是下面那个**两级排序**，这个惩罚只是第二级里的微调。
  static const double _diversityPenalty = 2.6;

  /// 「错题专练」里，重做本题**真的有用**的题（`remedy == requiz`）拿到的加分。
  ///
  /// 量级是照着别的项定的，不是拍脑袋：薄弱考点满值 3.0、错一次的题 3.0、
  /// 考频满值约 1.2。取 1.5 意味着它**能改变次序，但压不过"错得更多"**
  /// —— 前者是"这道题更对症"，后者是"这道题更该练"，后者优先级更高。
  static const double _requizBonus = 1.5;

  /// 同上，属于「需专项训练」的题（`remedy == drill`）拿到的减分。
  ///
  /// 用减分而不是**排除**：个人题库是几百条量级，排除会让"错题专练"
  /// 直接凑不满 15 题。降权的效果是"有对症的题时优先对症的"，
  /// 而不是"题库里有一半题不许出"。
  static const double _drillPenalty = 1.5;

  /// 组一份卷。
  PaperResult compose({
    required PaperRequest request,
    required List<Candidate> pool,
  }) {
    final warnings = <String>[];
    final items = <PaperItem>[];
    final usedIds = <String>{};
    final usedKps = <String, int>{};
    final openSeats = <PaperSeat>[];
    var diversifiedSkips = 0;

    // 按题号顺序填 —— 难度是"从易到难"给的，顺序填才能保住那个递进感
    for (final seat in request.template.seats) {
      // 候选筛选。三层，按"能不能妥协"排序：
      //
      // 1. 题型匹配（或题位不限题型）—— **硬约束**
      // 2. 未被本卷用过、未在排除集中、科目一致 —— 硬约束
      // 3. 难度在宽容度内 —— 软约束，不满足时放宽并记账
      //
      // ⚠️ 第 1 条为什么是硬的（实测踩过）：`wrong_only` 的题位 qtype 是
      // `any`（不限题型）。如果把它当成"匹配任何题型"，那么当题库里没有
      // 选择题时，一个 `any` 题位的题会被填进**选择题**的空位 ——
      // 填空题的位置上出现解答题，而分值仍是填空的 5 分。
      // 那份卷子的结构就是假的，而用户看不出来。
      // 宁可留空并提示"题库里没有足够的填空题"。
      final typeOk = allowTypeMismatch
          ? (Candidate c) => true
          : (Candidate c) => seat.isAnyQtype || c.qtype == seat.qtype;

      final candidates = pool
          .where((c) =>
              typeOk(c) &&
              c.subject == request.subject &&
              !usedIds.contains(c.problemId) &&
              !request.excludeProblemIds.contains(c.problemId))
          .toList();

      if (candidates.isEmpty) {
        openSeats.add(seat);
        continue;
      }

      // 第一轮：在难度宽容度内挑。题位不限难度（错题专练）时这一轮不过滤。
      final target = seat.targetDifficulty;
      var tier = target == null
          ? candidates
          : candidates
              .where((c) =>
                  (c.difficulty - target).abs() <= request.difficultyTolerance)
              .toList();

      if (tier.isEmpty) {
        // 第二轮：放宽到"整卷任意难度"，但要记账
        tier = candidates;
        _noteDifficultyRelaxed(warnings, seat);
      }

      // 第三轮：优先挑"考点还没在本卷出现过"的题。
      //
      // ⚠️ 这一层必须排在打分**之前**，不能只靠打分里的惩罚项：
      // 惩罚是固定值，而"错题优势"随错题次数增长，错得足够多的考点
      // 会把惩罚压过去。实测就是这样被连抽 4 次的。
      final fresh = tier.where((c) => !_kpUsed(c, usedKps)).toList();
      if (fresh.isNotEmpty && request.diversify) {
        if (fresh.length < tier.length) diversifiedSkips++;
        tier = fresh;
      }

      // 打分排序，取最优
      tier.sort((a, b) =>
          _score(b, request, usedKps, target).compareTo(_score(a, request, usedKps, target)));

      final pick = tier.first;
      usedIds.add(pick.problemId);
      if (pick.primaryKpId != null) {
        usedKps[pick.primaryKpId!] = (usedKps[pick.primaryKpId!] ?? 0) + 1;
      }
      // 只在题位**指定了**难度、而抽到的题不符时才记账。
      // 题位不限难度时（target == null）不存在"不符"这回事 ——
      // 早先这里直接和 null 比，会给每个题位都刷一条无意义的警告。
      if (target != null && pick.difficulty != target) {
        _noteDifficultyMismatch(warnings, seat, pick);
      }

      items.add(PaperItem(
        seat: seat,
        problemId: pick.problemId,
        stemText: pick.stemText,
        primaryKpName: pick.primaryKpName,
        actualDifficulty: pick.difficulty,
        wrongCount: pick.wrongCount,
      ));
    }

    _noteMissing(warnings, openSeats);
    _noteTemplateScoreDrift(warnings, request.template);
    if (diversifiedSkips > 0) {
      warnings.add('为分散考点，$diversifiedSkips 个题位改用了其它考点的题');
    }

    return PaperResult(
      template: request.template,
      subject: request.subject,
      items: items,
      emptySeats: openSeats,
      warnings: warnings,
    );
  }

  /// 这个候选题的考点是否已经在本卷里用过。
  ///
  /// 没有考点的题（未标注）一律视为"可用" —— 它们不参与多样性判断，
  /// 否则未标注的题会被系统性排到最后，而它们恰恰是用户需要被提醒
  /// 去补标注的那批。
  static bool _kpUsed(Candidate c, Map<String, int> usedKps) {
    final kp = c.primaryKpId;
    if (kp == null || kp.isEmpty) return false;
    return (usedKps[kp] ?? 0) > 0;
  }

  // ───────────────────────────────────────────────────────────────────────
  // 打分
  // ───────────────────────────────────────────────────────────────────────

  /// 一道题对某个题位的得分。越大越该选。
  ///
  /// 各项都归一化到 0–1 再加权，这样权重才可解释
  /// （否则"考频权重 0.8"和"错题次数 5"量级差太远，后者会压死前者）。
  double _score(
    Candidate c,
    PaperRequest req,
    Map<String, int> usedKps,
    int? targetDifficulty,
  ) {
    var s = 0.0;

    // ① 薄弱考点：掌握度越低越优先。
    //    掌握度未知（没复习过）时给 0.5 —— 既不是"已掌握"也不是"确定薄弱"。
    if (req.preferWeak) {
      final m = c.kpMastery ?? 0.5;
      s += (1.0 - m) * 3.0;
    }

    // ② 做错过的题：错得越多越优先。用对数压一下，
    //    否则"错 10 次"会把其它所有因素都盖掉，卷子变成只看错题次数。
    if (req.preferWrong && c.wrongCount > 0) {
      s += (1.0 + _log2(c.wrongCount + 1)) * 1.5;
    }

    // ③ 考频权重：高频考点优先
    final w = c.primaryKpWeight;
    if (w != null && w > 0) {
      s += w * 2.0 * req.weightStrength;
    }

    // ④ 难度贴合：正好命中题位目标给满分，每差一档扣 1.0。
    //    题位不限难度时给一个中性值 1.0（不奖不罚）。
    //
    //    这一项与 `difficultyTolerance` 是**两件事**：宽容度决定
    //    "哪些题有资格进候选"，这一项决定"进了候选之后谁更靠前"。
    //    少了它，一档之内的候选就变成随机挑 —— 而"由易到难递进"正是
    //    真题手感的一部分（模板的 difficulty 数组就是为此按题号给的）。
    s += targetDifficulty == null
        ? 1.0
        : 2.0 - (c.difficulty - targetDifficulty).abs() * 1.0;

    // ⑤ 考点多样性：本卷里已经出现过的考点降权。
    //
    //    这只是**微调** —— 真正保证多样性的是 `compose` 里的第三轮过滤
    //    （优先挑考点还没出现过的题）。这里保留一个惩罚项，是为了在
    //    "所有候选的考点都已用过"时，让用得少的那一方仍然占优。
    if (req.diversify && c.primaryKpId != null) {
      final n = usedKps[c.primaryKpId!] ?? 0;
      if (n > 0) s -= n * _diversityPenalty;
    }

    // ⑥ 错因对症：错题专练出的是"重做本题"，所以要看这题**当初错在哪**。
    //
    //    `calc`（计算失误）/ `reading`（审题错误）/ `time`（时间不够）
    //    三类错因的处方里明确写着"不要靠继续刷题解决"（见
    //    `data/error_causes.json` 的 `not_action`）。所以在这份卷子里
    //    它们**降权**而不是被排除（理由见 `_drillPenalty`）。
    //
    //    这不是说 drill 类的题不该练，而是说**它不该在这一页练**：
    //    限时计算与审题流程是另外两种训练，占着"错题专练"的题位，
    //    等于让用户用最贵的方式（重做整道综合题）去练一个更便宜的技能。
    //
    //    ⚠️ 只在「错题专练」类请求上生效（`req.usesErrorCause`）：
    //    真题全卷与限时模考考的是**覆盖面**，按错因挑题会让卷子偏离
    //    真题结构 —— 而结构正是那两个模板存在的全部意义。
    if (req.usesErrorCause && c.errorCauseIds.isNotEmpty) {
      final drill = c.errorCauseIds.any(req.drillCauseIds.contains);
      s += drill ? -_drillPenalty : _requizBonus;
    }

    return s;
  }

  static double _log2(double x) {
    // 不引 dart:math 只为一次换底
    var r = 0.0;
    var v = x;
    while (v >= 2) {
      v /= 2;
      r += 1;
    }
    return r;
  }

  // ───────────────────────────────────────────────────────────────────────
  // 降级记账
  // ───────────────────────────────────────────────────────────────────────

  static void _noteDifficultyRelaxed(List<String> w, PaperSeat seat) {
    final msg = '第 ${seat.no} 题（${seat.sectionName}）没有难度 '
        '${seat.targetDifficulty} 的题可抽，已放宽到任意难度';
    if (!w.contains(msg)) w.add(msg);
  }
  static void _noteDifficultyMismatch(
      List<String> w, PaperSeat seat, Candidate pick) {
    final msg = '第 ${seat.no} 题期望难度 ${seat.targetDifficulty}，'
        '实际抽到 ${pick.difficulty}';
    if (!w.contains(msg)) w.add(msg);
  }

  /// 模板自己声明的总分，与它各题位分值之和对不上时报出来。
  ///
  /// 这个检查不是多余的洁癖：`exam_templates.json` 的 `real_exam` 曾经
  /// 声明 150 分，而三个大题加起来是 50 + 30 + 72 = **152** ——
  /// 模板列表上写着"满分 150"，预览与 PDF 里印的却是 152。
  /// 数据写错一次就会有第二次，所以让引擎自己盯着这个不变量：
  /// 对不上时用户至少能从"组卷说明"里看到。
  static void _noteTemplateScoreDrift(List<String> w, PaperTemplate t) {
    final declared = t.totalScore;
    if (declared == null) return; // 错题专练：总分本就由抽到的题决定
    final sum = t.seats.fold<int>(
        0, (s, seat) => s + (seat.score ?? kFallbackScorePerItem));
    if (sum == declared) return;
    w.add('模板「${t.name}」声明满分 $declared 分，但各题位分值合计为 $sum 分 —— '
        '这是模板数据的问题，请以此处的 $sum 分为准');
  }

  static void _noteMissing(List<String> w, List<PaperSeat> empty) {
    if (empty.isEmpty) return;
    final byType = <String, int>{};
    for (final s in empty) {
      // 不限题型的题位单独归类，否则会显示成"any 3 题"这种内部术语
      byType[s.isAnyQtype ? '不限题型' : _qtypeName(s.qtype)] =
          (byType[s.isAnyQtype ? '不限题型' : _qtypeName(s.qtype)] ?? 0) + 1;
    }
    final detail = byType.entries.map((e) => '${e.key} ${e.value} 题').join('、');
    w.add('题库不足：还有 ${empty.length} 个题位没填上（$detail）—— '
        '多选题库里的题，或换用更短的模板');
  }

  /// 内部题型 id → 用户看得懂的中文。
  ///
  /// 提示语是给用户看的，不该出现 `choice` / `solve` 这种内部标识。
  static String _qtypeName(String id) => switch (id) {
        'choice' => '选择题',
        'fill' => '填空题',
        'solve' => '解答题',
        'proof' => '证明题',
        _ => id,
      };
}
