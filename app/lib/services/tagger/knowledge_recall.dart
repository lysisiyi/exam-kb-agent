/// 知识点召回层。
///
/// ## 为什么需要召回，而不是把全部知识点塞进 prompt
///
/// 数学一有 **207 个叶子知识点**。若全部塞进 prompt：
/// - 每个知识点带定义/公式，约 150 token → **31000 token**，成本和延迟都爆炸
/// - 候选太多，LLM 选择准确率反而下降（"选项过载"）
///
/// 所以采用**两阶段**：
/// ```
/// 阶段 1（本文件）：规则 + 关键词 + IDF 加权，从 207 个里粗筛出 ~25 个候选
/// 阶段 2（tagger）：LLM 从这 25 个里精挑，输出主考点 + 次考点
/// ```
///
/// ## 召回策略
/// 纯规则，**不用 LLM** —— 快（毫秒级）、免费、可解释、可单测。
///
/// 1. **公式成分匹配（IDF 加权）**：把公式切成数学 token，按 token 稀有度加权
/// 2. **名称匹配**：知识点名出现在题干里
/// 3. **定义关键词匹配**：定义里的术语出现在题干里
/// 4. **章节保底**：每个章节至少保留 N 个候选，防止"全盘召回失败"
/// 5. **题型过滤**：知识点声明的题型与题目不符时降权
library;

import 'dart:math' as math;

import '../../data/markdown/problem_markdown.dart';
import '../../domain/knowledge/knowledge_point.dart';

/// 一个召回候选，带得分与命中原因（用于调试与解释）。
class RecallCandidate {
  final KnowledgePoint point;

  /// 综合得分。越高越可能是考点。
  final double score;

  /// 命中原因，用于 debug 与人工复核时理解"为什么它被选中"。
  final List<String> reasons;

  const RecallCandidate({
    required this.point,
    required this.score,
    this.reasons = const [],
  });

  @override
  String toString() =>
      '${point.id} (${score.toStringAsFixed(2)}) ${reasons.join("; ")}';
}

/// 召回结果。
class RecallResult {
  final List<RecallCandidate> candidates;

  /// 召回总数（召回前的叶子总数）。
  final int totalLeaves;

  /// 各策略的命中统计，用于评估召回质量。
  final int formulaHits;
  final int nameHits;

  /// 别名命中的叶子数（不含名称本身命中）。
  final int aliasHits;
  final int chapterFloorAdded;

  const RecallResult({
    required this.candidates,
    required this.totalLeaves,
    this.formulaHits = 0,
    this.nameHits = 0,
    this.aliasHits = 0,
    this.chapterFloorAdded = 0,
  });

  bool get isEmpty => candidates.isEmpty;

  /// 候选覆盖率，用于诊断"召回是否失败"。
  double get coverage =>
      totalLeaves == 0 ? 0 : candidates.length / totalLeaves;

  /// 是否所有候选中最高分都很低（说明匹配质量差，可能需要人工介入）。
  double get topScore => candidates.isEmpty ? 0 : candidates.first.score;

  @override
  String toString() => 'RecallResult(${candidates.length}/$totalLeaves, '
      'formula=$formulaHits name=$nameHits alias=$aliasHits '
      'floor=$chapterFloorAdded)';
}

/// 召回配置。
class RecallConfig {
  /// 最终返回的候选数量。
  final int maxCandidates;

  /// 每个章节至少保留的候选数（章节保底）。
  final int minPerChapter;

  /// **真命中少于这个数**时才启用章节保底。
  ///
  /// ## 为什么需要这道闸门
  ///
  /// 保底的设计目的是兜住"全盘召回失败"（题干和任何知识点名都没有共同
  /// 子串），而不是给每次标注垫底。而数学一有 **19 章**：每章保底 2 个
  /// 就是 38 个，而 [maxCandidates] 只有 25 —— 保底会把候选表**永远塞满**。
  ///
  /// 这个后果一直没被发现，因为章节判据过去取的是 `level == 3`，
  /// 而数一的章节标的是 level 2 → 保底对数一**完全没生效**（见
  /// `KnowledgeBase.chapters`）。判据修好之后实测（67 道金标准题）：
  ///
  /// | | 平均候选数 |
  /// |---|---|
  /// | 保底不生效（修复前） | 9.1 – 14.5 |
  /// | 保底生效且无闸门 | **25.0（顶到上限）** |
  ///
  /// 而 T17 的 Top-1 准确率正是在 9–15 个候选下测出来的。没有闸门，
  /// 每次标注的 prompt 会涨两三倍，且把十几个低相关候选塞给模型。
  ///
  /// 有了闸门：正常题目（命中 ≥ 5 个）回到实测条件，
  /// 只有"几乎什么都没匹配上"的题目才拿到保底候选。
  final int floorTriggerHits;

  /// 公式匹配的权重。
  final double formulaWeight;

  /// 知识点名匹配的权重。
  final double nameWeight;

  /// **别名**匹配的权重。
  ///
  /// 为什么低于 [nameWeight]：别名是"知识点名的一部分"或"符号写法"，
  /// 比全名宽泛。例如别名「极值」会同时命中「单调性、极值与最值」
  /// 与「多元函数极值与最值」—— 它证明"相关"，但不证明"就是它"。
  ///
  /// 权重只需要够**进候选**（召回率），精挑交给 LLM。
  final double aliasWeight;

  /// 定义中关键词匹配的权重。
  final double definitionWeight;

  /// 命中常见陷阱的权重。
  final double trapWeight;

  /// 考频权重的影响系数（高频考点更可能是考点）。
  final double examWeightFactor;

  /// 题型不符时的惩罚系数（乘性）。
  final double qtypeMismatchPenalty;

  /// 低于该分数视为"没匹配上"，不参与排序（但章节保底仍可能捞回）。
  final double minScoreThreshold;

  const RecallConfig({
    this.maxCandidates = 25,
    this.minPerChapter = 2,
    this.floorTriggerHits = 5,
    this.formulaWeight = 3.0,
    this.nameWeight = 4.0,
    this.aliasWeight = 3.0,
    this.definitionWeight = 1.0,
    this.trapWeight = 1.5,
    this.examWeightFactor = 0.8,
    this.qtypeMismatchPenalty = 0.6,
    this.minScoreThreshold = 0.5,
  });

  static const RecallConfig defaults = RecallConfig();
}

/// 知识点召回器。
class KnowledgeRecall {
  final KnowledgeBase knowledge;
  final RecallConfig config;

  /// token → 逆文档频率权重，在构造时按整个知识点本体预计算。
  ///
  /// ## 为什么需要 IDF 加权
  ///
  /// 实测踩过的坑：最初按"公式 token 重叠个数"打分，结果
  /// `\frac`、`\lambda`、`\lim`、`x` 这些**通用符号**出现在大量知识点里，
  /// 导致几乎每道题都能匹配到几十个知识点（实测 formulaHits=134）。
  ///
  /// 后果：真正相关的知识点被淹没在噪声里，实测召回率只有 66.7%。
  ///
  /// 修正：按 token 在全库中的出现频率给权重 ——
  /// - `\lambda` 出现在很多知识点 → 权重低
  /// - `\lambda E-A`（特征方程）只出现在少数知识点 → 权重高
  ///
  /// 这是信息检索里的经典 IDF 思路，对"公式成分匹配"同样适用。
  late final Map<String, double> _tokenIdf = _buildIdf();

  /// token 出现过的知识点数量（用于计算 IDF）。
  late final Map<String, int> _tokenDocCount = _buildTokenDocCount();

  /// 每个叶子可参与**公式匹配**的素材：公式 + 符号别名，已切好 token。
  ///
  /// 预计算的理由：召回是热点路径，每道题都要遍历全部叶子的全部公式。
  /// 早期版本在 `_matchFormulas` 里现场调 `_mathTokens`，等于对 198 个叶子
  /// 反复分词几万次。符号别名让素材量再涨 30%，不预计算会明显变慢。
  late final Map<String, List<Set<String>>> _formulas = {
    for (final kp in knowledge.leaves) kp.id: _buildFormulas(kp),
  };

  /// 每个叶子的**文本型别名**（不含反斜杠的那些）。
  late final Map<String, List<String>> _phraseAliases = {
    for (final kp in knowledge.leaves)
      kp.id: kp.aliases.where((a) => !a.contains(r'\')).toList(growable: false),
  };

  KnowledgeRecall({
    required this.knowledge,
    this.config = RecallConfig.defaults,
  });

  /// 该叶子可参与公式匹配的全部素材（公式 + 符号别名），已切好 token。
  ///
  /// 别名与公式在匹配时**没有区别** —— 都是"这个知识点会出现的数学写法"。
  /// 分开只体现在数据生成侧（哪条是人工写的符号签名）。
  List<Set<String>> _buildFormulas(KnowledgePoint kp) => [
        for (final f in kp.formulas) _mathTokens(f),
        for (final a in kp.aliases)
          if (a.contains(r'\')) _mathTokens(a),
      ];

  /// 统计每个 token 出现在多少个知识点里。
  ///
  /// ⚠️ 素材必须与 `_buildFormulaTokens` **完全一致**（公式 + 符号别名），
  /// 否则 IDF 会按一个集合算、按另一个集合用，权重失真。
  Map<String, int> _buildTokenDocCount() {
    final counts = <String, int>{};
    for (final kp in knowledge.leaves) {
      final tokens = <String>{};
      for (final f in kp.formulas) {
        tokens.addAll(_mathTokens(f));
      }
      for (final a in kp.aliases) {
        if (a.contains(r'\')) tokens.addAll(_mathTokens(a));
      }
      // 定义里的数学符号也算（有些知识点只有定义没公式）
      if (kp.definition != null) {
        tokens.addAll(_mathTokens(kp.definition!));
      }
      for (final t in tokens) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    return counts;
  }

  /// 由文档频率推导 IDF 权重。
  ///
  /// 公式：`idf = log(1 + N / (1 + df))`，再归一化到 [0.1, 1.0]。
  /// 只在少数知识点出现的 token 权重接近 1；到处都是的降到 0.1。
  Map<String, double> _buildIdf() {
    final n = knowledge.leaves.length;
    if (n == 0) return {};

    final maxRaw = math.log(1 + n / 2.0); // df=1
    final minRaw = math.log(1 + n / (1 + n)); // df=N
    final span = maxRaw - minRaw;

    final out = <String, double>{};
    for (final entry in _tokenDocCount.entries) {
      final raw = math.log(1 + n / (1 + entry.value));
      final norm = span <= 0 ? 1.0 : (raw - minRaw) / span;
      // 映射到 [0.1, 1.0]：即使最常见的 token 也保留一点权重
      out[entry.key] = 0.1 + 0.9 * norm.clamp(0.0, 1.0);
    }
    return out;
  }

  /// 对一道题做召回。
  RecallResult recall(Problem problem) {
    final leaves = knowledge.leaves;
    if (leaves.isEmpty) {
      return const RecallResult(candidates: [], totalLeaves: 0);
    }

    // 预处理题干：抽出可匹配的文本与公式片段
    final haystack = _extractHaystack(problem);

    final byChapter = <String, List<RecallCandidate>>{};
    var formulaHits = 0;
    var nameHits = 0;
    var aliasHits = 0;

    final scored = <RecallCandidate>[];

    for (final kp in leaves) {
      final reasons = <String>[];
      var score = 0.0;

      // 1. 公式匹配（含符号别名）
      final formulaScore = _matchFormulas(kp, haystack);
      if (formulaScore > 0) {
        score += formulaScore * config.formulaWeight;
        reasons.add('公式匹配 ×$formulaScore');
        formulaHits++;
      }

      // 2. 知识点名匹配
      if (_containsName(haystack.plainText, kp.name)) {
        score += config.nameWeight;
        reasons.add('名称命中「${kp.name}」');
        nameHits++;
      }

      // 3. 别名匹配
      //
      // 这是 T15 的修复点。题干不含知识点名的题（"设 X~N(0,1)…"）
      // 在策略 1、2 上全部落空，只能靠别名把正确答案捞进候选。
      final aliasHitsHere = _matchAliases(haystack.plainText, kp);
      if (aliasHitsHere.isNotEmpty) {
        score += config.aliasWeight * aliasHitsHere.length;
        reasons.add('别名命中${aliasHitsHere.map((a) => '「$a」').join()}');
        aliasHits++;
      }

      // 4. 定义关键词匹配
      final defScore = _matchDefinition(haystack.plainText, kp);
      if (defScore > 0) {
        score += defScore * config.definitionWeight;
        reasons.add('定义关键词 ×$defScore');
      }

      // 5. 陷阱匹配（题目常直接描述易错点）
      final trapScore = _matchTraps(haystack.plainText, kp);
      if (trapScore > 0) {
        score += trapScore * config.trapWeight;
        reasons.add('陷阱匹配 ×$trapScore');
      }

      // 6. 考频加权（高频考点本身就更可能是答案）
      if (score > 0 && kp.examWeight != null) {
        score += kp.examWeight! * config.examWeightFactor;
      }

      // 7. 题型不符惩罚
      if (score > 0 && !_qtypeCompatible(kp, problem.qtype)) {
        score *= config.qtypeMismatchPenalty;
        reasons.add('题型不符（×${config.qtypeMismatchPenalty}）');
      }

      if (score < config.minScoreThreshold) continue;

      final cand = RecallCandidate(point: kp, score: score, reasons: reasons);
      scored.add(cand);
      byChapter.putIfAbsent(kp.chapterId, () => []).add(cand);
    }

    // 排序：分数降序，同分时考频高的优先，再同则按 id 保证稳定
    scored.sort(_compareCandidates);

    // 章节保底：每个章节至少捞 minPerChapter 个（即使分数低于阈值）
    var floorAdded = 0;
    final selectedIds = <String>{for (final c in scored) c.point.id};

    if (config.minPerChapter > 0 && scored.length < config.floorTriggerHits) {
      // 按章节遍历所有叶子，补齐每章不足的部分
      for (final chapter in knowledge.chapters) {
        final chapterLeafIds = knowledge.leafIdsUnder(chapter.id);
        if (chapterLeafIds.isEmpty) continue;

        final alreadyIn =
            chapterLeafIds.where(selectedIds.contains).length;
        if (alreadyIn >= config.minPerChapter) continue;

        // 该章内还没入选的叶子，按考频降序挑
        final need = config.minPerChapter - alreadyIn;
        final extras = leaves
            .where((kp) =>
                chapterLeafIds.contains(kp.id) && !selectedIds.contains(kp.id))
            .toList()
          ..sort((a, b) =>
              (b.examWeight ?? 0).compareTo(a.examWeight ?? 0));

        for (final kp in extras.take(need)) {
          final cand = RecallCandidate(
            point: kp,
            score: 0.1, // 保底候选给一个低分，排序时排在真正命中之后
            reasons: const ['章节保底'],
          );
          scored.add(cand);
          selectedIds.add(kp.id);
          floorAdded++;
        }
      }
    }

    // 最终再排序一次（保底候选与命中候选混在一起）
    scored.sort(_compareCandidates);

    return RecallResult(
      candidates: scored.take(config.maxCandidates).toList(),
      totalLeaves: leaves.length,
      formulaHits: formulaHits,
      nameHits: nameHits,
      aliasHits: aliasHits,
      chapterFloorAdded: floorAdded,
    );
  }

  // ───────────────────────────────────────────────────────────────────────
  // 匹配策略
  // ───────────────────────────────────────────────────────────────────────

  /// 从题目抽出可匹配的内容。
  _Haystack _extractHaystack(Problem problem) {
    final parts = <String>[
      problem.stem,
      if (problem.answer != null) problem.answer!,
      if (problem.solution != null) problem.solution!,
      for (final o in problem.options) o,
      problem.source ?? '',
    ];
    final full = parts.join('\n');

    // 抽出 LaTeX 片段：$...$ / $$...$$ / \(...\) / \[...\]
    final latex = <String>[];
    for (final re in [
      RegExp(r'\$\$([\s\S]*?)\$\$'),
      RegExp(r'\$([^$\n]+)\$'),
      RegExp(r'\\\(([\s\S]*?)\\\)'),
      RegExp(r'\\\[([\s\S]*?)\\\]'),
    ]) {
      for (final m in re.allMatches(full)) {
        final t = m.group(1)?.trim();
        if (t != null && t.isNotEmpty) latex.add(t);
      }
    }

    // 归一化文本：去 LaTeX 命令，只留可读内容用于名称匹配
    final plain = _stripLatex(full);

    return _Haystack(
      raw: full,
      plainText: plain,
      latexFragments: latex,
      // 预先把每个片段切成 token 集合，避免在 226 个知识点 × N 个公式
      // 的内层循环里重复分词（这是热点路径）。
      latexTokens: latex.map(_mathTokens).toList(),
    );
  }

  /// 公式匹配（IDF 加权）。
  ///
  /// ## 为什么不做整式子串匹配
  /// 实测踩过这个坑：题目里是 `\frac{1-\cos x}{x^2}`，
  /// 而知识点公式是 `1-\cos x \sim \frac{x^2}{2}` —— **两者不互为子串**，
  /// 整式匹配命中率为 0。
  ///
  /// ## 为什么必须 IDF 加权
  /// 退一步做"token 重叠计数"也不行：`\frac`、`\lambda`、`x` 这些通用符号
  /// 出现在大量知识点里，实测让几乎每道题都匹配到几十个知识点
  /// （formulaHits=134），真正的答案被淹没，召回率只有 66.7%。
  ///
  /// 修正后：按 token 稀有度加权 —— `\lambda` 权重低，`\lambda E-A` 权重高。
  ///
  /// 返回加权命中强度 0–1。
  double _matchFormulas(KnowledgePoint kp, _Haystack h) {
    final kpFormulas = _formulas[kp.id];
    if (kpFormulas == null || kpFormulas.isEmpty || h.latexTokens.isEmpty) {
      return 0;
    }

    var best = 0.0;
    for (final kpTokens in kpFormulas) {
      if (kpTokens.isEmpty) continue;

      // 该公式的 token 权重总和（作为分母）
      var totalWeight = 0.0;
      for (final t in kpTokens) {
        totalWeight += _idfOf(t);
      }
      if (totalWeight <= 0) continue;

      for (final fragTokens in h.latexTokens) {
        if (fragTokens.isEmpty) continue;

        // 分子：题目中出现且被知识点拥有的 token 权重和
        var matchedWeight = 0.0;
        for (final t in kpTokens) {
          if (fragTokens.contains(t)) matchedWeight += _idfOf(t);
        }
        if (matchedWeight <= 0) continue;

        final ratio = matchedWeight / totalWeight;
        final shared = kpTokens.intersection(fragTokens);
        final overlapCount = shared.length;

        // ── 闸门 0：重合里必须至少有一个 LaTeX 命令 ──
        //
        // 这是留出验证集（gold_set_holdout.json）暴露出来的问题。
        // 单字母变量（`x`、`y`、`d`、`n`）在数学题里无处不在，
        // 只共享它们等于**零信息**，但覆盖率可以很高，于是轻松过关：
        //
        // ```
        // 题干「求 ∫x ln x dx」的 token 是 {\int, x, \ln, d}
        // 知识点「数字特征的综合应用」的符号别名 D(X) → token {d, x}
        //   → 重合 {d, x}，覆盖率 1.0，拿 3 分
        //   → 把一个概率论知识点排到了积分题候选的前列
        // ```
        //
        // 这类噪声多了会挤掉真答案（候选上限 25）：
        // 留出集上 ho-008、ho-009 都是这样被挤掉的。
        //
        // 判据：token 只有三类 —— `\命令`、数字（已剔除）、单字母。
        // 所以"至少一个以反斜杠开头"就等价于"至少有一个真正的数学运算"。
        if (!shared.any((t) => t.startsWith(r'\'))) continue;

        // ── 精度闸门 ──
        //
        // 同一数据集（198 叶子 / 15 题金标准）上实测过三套方案：
        //
        // | 方案 | 召回率 |
        // |---|---|
        // | 纯重叠计数，只对 1-token 设限 | 73.3% |
        // | 分级阈值（当前） | 见下 |
        // | 高阈值 + 签名 token 双闸门 | 60.0% |
        //
        // 教训：**简单分级阈值优于"聪明"的语义闸门**。
        // 数学公式的 token 分布很平坦 —— 没有哪个 LaTeX 命令独占某个知识点
        // （`\theta` 同时属于极坐标、参数方程、三角函数），
        // 所以"靠稀有 token 识别概念"的前提不成立。
        //
        // 规则：重叠越少，要求的覆盖率越高。
        //
        // ── 正面教训：别为"符号别名"放宽闸门 ──
        //
        // 试过给符号别名单独放宽一档（理由：别名是人工签名，
        // 允许被代入具体函数，覆盖率天然偏低）。**实测是负收益**：
        // 召回率从 93.3% 降到 86.7%。
        //
        // ```
        // 题干 y'+2xy=x 的 token 是 {x, y}
        // 放宽到 0.75 后，「微分与高阶导数」的别名 \mathrm{d}y=f'(x)\mathrm{d}x
        // 仅凭共享 {x, y} 就以 0.46 过关（门槛 0.55×0.75=0.4125），
        // 把真正的答案挤出了 25 个候选之外
        // ```
        //
        // 结论：**只共享单字母变量（x、y）的重合没有任何信息量**，
        // 任何低于 0.55 的门槛都只是在放大噪声。
        // gold-010（y'+2xy=x → 一阶线性微分方程）的正确修法是
        // 在 `alias_overrides.json` 里补「微分方程」「通解」两个**文本**别名 ——
        // 题干里本来就有这两个词，是数据缺了，不是阈值错了。
        if (overlapCount >= 3) {
          if (ratio < 0.40) continue;
        } else if (overlapCount == 2) {
          if (ratio < 0.55) continue;
        } else {
          final only = shared.first;
          if (!_isDistinctiveToken(only) ||
              _idfOf(only) < 0.60 ||
              ratio < 0.65) {
            continue;
          }
        }

        best = best > ratio ? best : ratio;
        if (best >= 1.0) return 1.0;
      }
    }
    return best;
  }

  /// 取 token 的 IDF 权重。未知 token 给一个中等偏高值
  /// （说明它没在知识点库里出现过，可能是题目特有的，有一定信息量）。
  double _idfOf(String token) => _tokenIdf[token] ?? 0.7;

  /// 把 LaTeX 片段切成数学 token。
  ///
  /// 产出三类 token：
  /// - LaTeX 命令：`\frac`、`\lim`、`\sin`、`\to`、`\sim` …
  /// - 数字：`1`、`2`、`0`
  /// - 单字母变量：`x`、`n`、`f`
  ///
  /// 刻意**不**产出复合结构（如 `\frac{1}{2}` 整体），因为结构在题目里
  /// 会被改写；成分才是稳定的。稀有度由 IDF 负责区分。
  static Set<String> _mathTokens(String latex) {
    final norm = _normalizeLatex(latex);
    final tokens = <String>{};

    // LaTeX 命令
    for (final m in RegExp(r'\\[a-zA-Z]+').allMatches(norm)) {
      tokens.add(m.group(0)!);
    }
    // 裸的命令转义符
    for (final m in RegExp(r'\\[^a-zA-Z]').allMatches(norm)) {
      tokens.add(m.group(0)!);
    }
    // 数字（含小数）
    for (final m in RegExp(r'\d+(?:\.\d+)?').allMatches(norm)) {
      tokens.add(m.group(0)!);
    }
    // 单字母变量（去掉已被命令占用的部分）
    final withoutCommands = norm.replaceAll(RegExp(r'\\[a-zA-Z]+'), ' ');
    for (final m in RegExp(r'[a-z]').allMatches(withoutCommands)) {
      tokens.add(m.group(0)!);
    }

    // 过滤掉纯数字 token —— 它们在数学题里到处都是（如分母的 2、3），
    // 区分度极低，留着只会制造噪声。
    tokens.removeWhere((t) => RegExp(r'^\d+(\.\d+)?$').hasMatch(t));

    return tokens;
  }

  /// 该 token 是否足够有辨识度，可以在"仅重叠 1 个"时也算命中。
  ///
  /// LaTeX 命令（`\frac`、`\lim`）有辨识度；单个字母 `x` 没有。
  static bool _isDistinctiveToken(String t) => t.startsWith(r'\');

  /// 别名匹配：返回命中的别名（最多 3 个，够表达"为什么相关"即可）。
  ///
  /// ## 只用"包含"，不做模糊
  ///
  /// 别名是**刻意设计**的目标串：派生片段来自知识点名，
  /// 符号别名来自领域映射。它们就应该**逐字出现**在题干里。
  /// 加模糊匹配（编辑距离/同义词）只会引入不可解释的噪声 ——
  /// 而"可解释"是召回层选规则而非 LLM 的核心理由之一。
  ///
  /// ## 为什么命中多个别名要累加权重
  ///
  /// 一道题同时出现「极值」和「驻点」时，命中两个别名比只命中一个
  /// 更可能是真的考这个知识点。但必须**限幅**：
  /// 别名「单调性、极值、最值」天然会命中多个片段，
  /// 不封顶的话一个知识点靠别名单条就能压过真有公式命中的知识点。
  List<String> _matchAliases(String text, KnowledgePoint kp) {
    final aliases = _phraseAliases[kp.id];
    if (aliases == null || aliases.isEmpty) return const [];

    final normalized = _normalizeForMatch(text);
    final hits = <String>[];
    for (final a in aliases) {
      if (_containsName(normalized, a)) {
        hits.add(a);
        if (hits.length >= _maxAliasHits) break;
      }
    }
    return hits;
  }

  /// 单个别名策略最多计几个命中（限幅，见 [_matchAliases]）。
  static const int _maxAliasHits = 2;

  /// 知识点名是否出现在文本里（做了宽松匹配）。
  bool _containsName(String text, String name) {
    if (name.isEmpty) return false;
    final n = _normalizeForMatch(name);
    if (n.length < 2) return false;
    return _normalizeForMatch(text).contains(n);
  }

  /// 定义关键词匹配：取定义里的"实词"片段做包含检查。
  double _matchDefinition(String text, KnowledgePoint kp) {
    final def = kp.definition;
    if (def == null || def.isEmpty) return 0;

    final normalizedText = _normalizeForMatch(text);
    var hits = 0.0;

    // 提取定义里的关键术语：连续的中文串（2–6 字）与英文术语
    final terms = _extractTerms(def);
    for (final t in terms) {
      if (normalizedText.contains(t)) hits += 1;
      if (hits >= 4) break; // 命中 4 个术语已经足够确信
    }
    return hits;
  }

  /// 常见陷阱匹配。
  double _matchTraps(String text, KnowledgePoint kp) {
    if (kp.commonTraps.isEmpty) return 0;

    final normalizedText = _normalizeForMatch(text);
    var hits = 0.0;
    for (final trap in kp.commonTraps) {
      // 陷阱文本通常较长且带 ★ 前缀，取其关键术语
      final clean = trap.replaceAll('★', '').trim();
      final terms = _extractTerms(clean);
      var termHits = 0;
      for (final t in terms) {
        if (normalizedText.contains(t)) termHits++;
      }
      // 命中 2 个以上术语才算一次陷阱匹配，避免噪音
      if (termHits >= 2) hits += 1;
      if (hits >= 2) break;
    }
    return hits;
  }

  /// 题型是否兼容。
  bool _qtypeCompatible(KnowledgePoint kp, QuestionType qtype) {
    if (kp.typicalQtypes.isEmpty) return true; // 未声明则不限制
    return kp.typicalQtypes.contains(qtype.id);
  }

  // ───────────────────────────────────────────────────────────────────────
  // 文本工具
  // ───────────────────────────────────────────────────────────────────────

  /// 去掉 LaTeX 命令，留下人能读的部分。
  static String _stripLatex(String s) {
    var out = s;
    out = out.replaceAll(RegExp(r'\$\$?'), ' ');
    out = out.replaceAll(RegExp(r'\\[a-zA-Z]+\*?'), ' ');
    out = out.replaceAll(RegExp(r'\\[^a-zA-Z]'), ' ');
    out = out.replaceAll(RegExp(r'[{}]'), ' ');
    return out;
  }

  /// LaTeX 归一化（用于公式匹配）。
  ///
  /// 消除排版性差异：空白、`\left`/`\right`、`\dfrac`/`\frac`、`\displaystyle`。
  static String _normalizeLatex(String s) {
    var out = s;
    out = out.replaceAll(RegExp(r'\s+'), '');
    out = out.replaceAll(RegExp(r'\\(left|right|big|Big|bigg|Bigg)'), '');
    out = out.replaceAll(RegExp(r'\\[dt]frac'), r'\frac');
    out = out.replaceAll(
      RegExp(r'\\(displaystyle|textstyle|limits|nolimits|quad|qquad)'),
      '',
    );
    // 拆掉纯排版包装，只留内容：`\mathrm{d}x` → `dx`。
    //
    // 不拆的话 `\mathrm` 本身会变成一个 token，而它是**排版命令、不是数学运算**，
    // 于是"公式重合里至少要有一个 LaTeX 命令"这条闸门会被它骗过去：
    //
    // ```
    // 题干 ∫x ln x dx        → token {\int, \ln, \mathrm, x, d}
    // 噪声别名 \mathrm{D}(X)  → token {\mathrm, d, x}
    // 重合 {\mathrm, d, x} → 含有"LaTeX 命令"→ 闸门放行 → 假阳性
    // ```
    //
    // 用 replaceAllMapped 而不是 replaceAll(r'$1')：Dart 的 replaceAll
    // **不支持反向引用**，`$1` 会被当字面量插进去。（这个坑本项目已经踩过一次）
    out = out.replaceAllMapped(
      RegExp(r'\\(?:mathrm|text|mathbf|boldsymbol|operatorname|mbox)\{([^{}]*)\}'),
      (m) => m.group(1)!,
    );
    out = out.replaceAll(RegExp(r'\\mathrm\{d\}'), 'd');
    out = out.replaceAll(RegExp(r'\\text\{d\}'), 'd');
    out = out.replaceAll(RegExp(r'\\,|\\;|\\!'), '');
    return out.toLowerCase();
  }

  /// 归一化用于子串匹配：去掉标点与空白，转小写。
  static String _normalizeForMatch(String s) {
    return s
        .replaceAll(RegExp(r'''[\s,.;:!?()\[\]{}<>~\-—_/\\|"'`、。，；：！？（）【】《》]'''), '')
        .toLowerCase();
  }

  /// 从一段中文/英文文本里提取关键术语。
  ///
  /// 中文没有词边界，所以这里用"连续汉字串 + 英文数字串"作为候选术语，
  /// 并过滤掉过于宽泛的功能词。
  static List<String> _extractTerms(String text) {
    final terms = <String>[];

    // 连续汉字（2–8 字）
    for (final m in RegExp(r'[\u4e00-\u9fff]{2,8}').allMatches(text)) {
      final t = m.group(0)!;
      if (_isStopTerm(t)) continue;
      terms.add(t);
    }
    // 英文/数字术语
    for (final m in RegExp(r'[A-Za-z][A-Za-z0-9_]{2,}').allMatches(text)) {
      terms.add(m.group(0)!.toLowerCase());
    }

    // 去重，长术语优先（更具体）
    final unique = terms.toSet().toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    return unique;
  }

  /// 过滤过于宽泛的词，它们在任何数学文本里都出现，没有区分度。
  static bool _isStopTerm(String t) {
    const stop = {
      '定义', '定理', '公式', '方法', '常用', '注意', '例如', '可以', '需要',
      '条件', '结论', '证明', '计算', '求解', '函数', '一个', '这个', '如果',
      '那么', '因此', '所以', '其中', '对于', '以及', '或者', '并且', '使得',
      '存在', '任意', '所有', '满足', '取值', '结果',
    };
    return stop.contains(t);
  }

  /// 候选排序：分数 > 考频 > id（保证稳定）。
  static int _compareCandidates(RecallCandidate a, RecallCandidate b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    final byWeight =
        (b.point.examWeight ?? 0).compareTo(a.point.examWeight ?? 0);
    if (byWeight != 0) return byWeight;
    return a.point.id.compareTo(b.point.id);
  }
}

/// 内部用的匹配素材。
class _Haystack {
  final String raw;
  final String plainText;
  final List<String> latexFragments;

  /// 每个 LaTeX 片段切成的数学 token 集合。预计算以避免热点路径重复分词。
  final List<Set<String>> latexTokens;

  const _Haystack({
    required this.raw,
    required this.plainText,
    required this.latexFragments,
    required this.latexTokens,
  });
}
