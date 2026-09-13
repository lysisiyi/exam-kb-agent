/// 知识点标注的 Prompt 构建。
///
/// ## 核心原则：让 LLM 做**选择题**，不做填空题
///
/// 如果让模型自由输出知识点名称，用三个月你会得到 2000 个同义标签
/// （"中值定理"/"微分中值定理"/"Lagrange 中值定理"），永远聚不起来。
///
/// 所以：
/// 1. 候选带 **id** 注入 prompt，模型只能从这些 id 里选
/// 2. 要求输出 JSON，字段固定
/// 3. 输出后用 [TagResult.fromJson] 严格校验 id 是否在候选集里
/// 4. 校验失败 → 重试 → 仍失败则进人工确认队列
///
/// ## 为什么把定义和公式也塞进候选
/// 只给知识点名字（如"等价无穷小替换"）时，模型主要靠名字猜。
/// 加上定义与公式后，模型能做**语义比对**而不是字符串匹配，
/// 实测对边界模糊的题（如"洛必达 vs 泰勒"）区分度提升明显。
library;

import '../../data/markdown/problem_markdown.dart';
import '../../domain/knowledge/knowledge_point.dart';
import 'knowledge_recall.dart';

/// 错因的受控取值（与 `data/error_causes.json` 一致）。
///
/// ⚠️ 这里的注释要区分两个概念：
/// - 题目 frontmatter 里的 `error_causes` 是 **AI 预判的易错点**（这题容易怎么错）
/// - 用户状态里的 `error_causes` 是 **用户自己的错因**（我为什么错）
/// 两者含义不同，不要混用。本文件生成的是前者。
const List<String> kErrorCauseIds = [
  'concept', // 概念不清
  'calc', // 计算失误
  'idea', // 思路缺失
  'reading', // 审题错误
  'method', // 方法选择错误
  'time', // 时间不够
];

/// 题型 id → 中文，用于 prompt。
const Map<String, String> kQtypeLabels = {
  'choice': '选择题',
  'fill': '填空题',
  'solve': '解答题',
  'proof': '证明题',
};

/// 构建标注用的 system + user prompt。
class TagPromptBuilder {
  final KnowledgeBase knowledge;

  /// 候选知识点数量上限（由召回层给出，这里只是读取）。
  final int maxCandidates;

  const TagPromptBuilder({
    required this.knowledge,
    this.maxCandidates = 25,
  });

  /// system prompt：定义角色与输出格式。
  ///
  /// 刻意写得**短而硬**：约束比解释更有效。
  static String systemPrompt({required int candidateCount}) => '''
你是考研数学命题与阅卷专家，负责为题目标注考点。

任务：从给定的候选知识点中，选出这道题考查的知识点。

## 标注规则

1. `primary`：**有且仅有一个**主考点，是这道题最核心的考查目标。
   如果题目综合了多个知识点，选**命题人最想考的那个**，而不是解题时最后用到的那步。

2. `secondary`：0–3 个次考点，是解题过程中确实用到的辅助知识点。
   不要为了凑数填写。简单的题可以没有次考点。

3. `difficulty`：
   - 1 = 基础（直接套公式/定义即可）
   - 2 = 综合（需要两步以上推理，或需结合两个知识点）
   - 3 = 拓展（需要构造、技巧性变形，或非常规思路）

4. `error_causes`：预判这道题**学生容易怎么错**（不是判断做题者错在哪）。
   可多选，从固定列表中取值：concept / calc / idea / reading / method / time

5. `confidence`：你对 primary 判断的把握，0–1 之间的小数。
   **请如实评估**：如果候选中没有真正合适的，confidence 给低值（<0.5），
   并在 reason 里说明。低置信度会被送去人工确认，这不是失败，而是诚实。

## 硬性约束

- `primary.kp_id` **必须是候选列表中的 id**，不能自创新 id。
- 只输出 JSON，不要任何解释文字、不要 markdown 代码块。
- 字段名严格如下，不要增删。

## 输出格式

```json
{
  "primary": {"kp_id": "候选中的 id", "confidence": 0.92},
  "secondary": [{"kp_id": "候选中的 id", "relevance": 0.6}],
  "difficulty": 2,
  "error_causes": ["idea"],
  "reason": "一句话说明判断依据，不超过 40 字"
}
```

候选共 $candidateCount 个。''';

  /// user prompt：题目内容 + 候选知识点。
  String userPrompt({
    required Problem problem,
    required RecallResult recall,
  }) {
    final b = StringBuffer();

    // ── 题目 ──
    b.writeln('## 题目');
    b.writeln();
    if (problem.source != null && problem.source!.isNotEmpty) {
      b.writeln('来源：${problem.source}');
    }
    b.writeln('题型：${kQtypeLabels[problem.qtype.id] ?? problem.qtype.id}');
    b.writeln();
    b.writeln(_stripForPrompt(problem.stem).trim());

    if (problem.options.isNotEmpty) {
      b.writeln();
      for (final o in problem.options) {
        b.writeln(o);
      }
    }

    // 答案与解析能显著提升判断质量（模型能看到解题路径用了什么）
    if (problem.answer != null && problem.answer!.trim().isNotEmpty) {
      b.writeln();
      b.writeln('## 参考答案');
      b.writeln(_stripForPrompt(problem.answer!).trim());
    }
    if (problem.solution != null && problem.solution!.trim().isNotEmpty) {
      b.writeln();
      b.writeln('## 解析');
      // 解析可能很长，截断以控制 token
      final sol = _stripForPrompt(problem.solution!).trim();
      b.writeln(sol.length > 1200 ? '${sol.substring(0, 1200)}…' : sol);
    }

    // ── 候选知识点 ──
    b.writeln();
    b.writeln('## 候选知识点（${recall.candidates.length} 个）');
    b.writeln();

    for (var i = 0; i < recall.candidates.length; i++) {
      final kp = recall.candidates[i].point;
      b.writeln('[${i + 1}] ${kp.id}');
      b.writeln('    名称：${kp.name}');
      if (kp.definition != null && kp.definition!.isNotEmpty) {
        // 定义截断到 120 字，保留核心区分信息
        final d = kp.definition!.trim();
        b.writeln('    定义：${d.length > 120 ? "${d.substring(0, 120)}…" : d}');
      }
      if (kp.formulas.isNotEmpty) {
        final f = kp.formulas.take(2).join('  |  ');
        b.writeln('    公式：${f.length > 160 ? "${f.substring(0, 160)}…" : f}');
      }
      b.writeln();
    }

    b.writeln('请从上述 ${recall.candidates.length} 个候选中选择，'
        'primary.kp_id 必须是上面出现过的 id。');

    return b.toString();
  }

  /// 组装完整的 [system, user]。
  (String system, String user) build({
    required Problem problem,
    required RecallResult recall,
  }) =>
      (
        systemPrompt(candidateCount: recall.candidates.length),
        userPrompt(problem: problem, recall: recall),
      );

  /// 去掉 Markdown 的图片语法（模型看不见图，留着只会干扰）。
  static String _stripForPrompt(String s) {
    var out = s;
    // 图片：完全去掉（alt 文本对数学题帮助有限，且可能误导）
    out = out.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ');
    // 链接：保留文字
    out = out.replaceAllMapped(
      RegExp(r'\[([^\]]*)\]\([^)]*\)'),
      (m) => m.group(1) ?? '',
    );
    return out;
  }
}

/// 标注结果。
class TagResult {
  /// 主考点 id。
  final String primaryKpId;

  /// 主考点置信度 0–1。
  final double confidence;

  /// 次考点。
  final List<({String kpId, double relevance})> secondary;

  /// 难度 1–3。
  final int difficulty;

  /// 预判易错点（受控词表子集）。
  final List<String> errorCauses;

  /// 模型给出的判断依据。
  final String reason;

  /// 校验过程中产生的问题（非致命）。
  final List<String> warnings;

  /// JSON 提取使用的策略，用于统计各服务商输出质量。
  final String extractionStrategy;

  const TagResult({
    required this.primaryKpId,
    required this.confidence,
    this.secondary = const [],
    this.difficulty = 2,
    this.errorCauses = const [],
    this.reason = '',
    this.warnings = const [],
    this.extractionStrategy = '',
  });

  /// 是否需要人工确认。
  ///
  /// 判据：置信度低于配置门槛，或校验时发现明显问题。
  bool needsReview(double threshold) =>
      confidence < threshold || warnings.any(isBlockingWarning);

  /// 该警告是否属于"必须重试或人工介入"的阻断性问题。
  ///
  /// ## 区分阻断与提示很重要
  ///
  /// **阻断**（结果不可用，必须重试）：
  /// - `primary` 缺失或为空 → 没有主考点，整个结果无意义
  /// - `primary.kp_id` 不在候选集 → 违反硬性约束，结果不可信
  ///
  /// **非阻断**（结果可用，忽略即可）：
  /// - 次考点不在候选集 → 主考点仍是对的，少一个次考点不影响使用
  /// - 错因不在受控词表 → 忽略该错因
  /// - `difficulty` 越界（已夹住）
  /// - 置信度按百分数解释
  ///
  /// ## 踩过的坑
  /// 最初用 `w.contains('不在候选集')` 做判断，结果**次考点**不在候选集时
  /// 也触发重试 —— 实测导致一次本可成功（且主考点完全正确）的标注
  /// 白白重试 3 次，浪费用户 3 倍 token，最后还是同一个结果。
  static bool isBlockingWarning(String w) =>
      w.contains('primary.kp_id') ||
      w.contains('缺少 primary') ||
      w.contains('primary 是');

  /// 从模型输出的 JSON 构造，并**严格校验**。
  ///
  /// [candidateIds] 是召回层给出的合法 id 集合 —— 不在其中的一律拒绝。
  factory TagResult.fromJson(
    Map<String, dynamic> j, {
    required Set<String> candidateIds,
    required double defaultConfidence,
    required String extractionStrategy,
  }) {
    final warnings = <String>[];

    // ── primary ──
    var primaryId = '';
    var confidence = defaultConfidence;

    final primaryRaw = j['primary'];
    if (primaryRaw is Map) {
      final p = primaryRaw.cast<String, dynamic>();
      primaryId = (p['kp_id'] ?? p['id'] ?? p['kpId'] ?? '').toString().trim();
      final c = p['confidence'];
      if (c is num) {
        confidence = c.toDouble();
      } else if (c is String) {
        confidence = double.tryParse(c.trim()) ?? defaultConfidence;
      }
    } else if (primaryRaw is String) {
      // 容忍模型直接给字符串
      primaryId = primaryRaw.trim();
      warnings.add('primary 是字符串而非对象');
    } else {
      warnings.add('缺少 primary 字段');
    }

    if (primaryId.isEmpty) {
      warnings.add('primary.kp_id 为空');
    } else if (!candidateIds.contains(primaryId)) {
      warnings.add('primary.kp_id「$primaryId」不在候选集里');
    }

    // 归一化置信度。
    //
    // 模型可能给三种量纲：0–1 小数（规范）、0–100 百分数、或越界值。
    // 判据：
    // - ≤1 视为小数，直接用
    // - (1, 100] 视为百分数，除以 100
    // - >100 视为越界，夹到 1.0
    //
    // ⚠️ 注意 1< c ≤100 里的**小整数**（如 5）会被解释成 5% —— 这是
    // 有意为之：模型若真的想表达"0.5 的把握"却写成 5，那本身就是错误输出，
    // 解释成 5% 并让它落入低置信度（进人工确认）比当成 100% 更安全。
    if (confidence > 1.0) {
      confidence = confidence > 100.0 ? 1.0 : confidence / 100.0;
    }
    confidence = confidence.clamp(0.0, 1.0);

    // ── secondary ──
    final secondary = <({String kpId, double relevance})>[];
    final secRaw = j['secondary'];
    if (secRaw is List) {
      for (final item in secRaw) {
        String id = '';
        var rel = 0.5;
        if (item is Map) {
          final m = item.cast<String, dynamic>();
          id = (m['kp_id'] ?? m['id'] ?? '').toString().trim();
          final r = m['relevance'];
          if (r is num) {
            rel = r.toDouble();
          } else if (r is String) {
            rel = double.tryParse(r.trim()) ?? 0.5;
          }
        } else if (item is String) {
          id = item.trim();
        }
        if (id.isEmpty) continue;
        if (id == primaryId) continue; // 主考点不该重复出现在次考点里
        if (!candidateIds.contains(id)) {
          warnings.add('次考点「$id」不在候选集里，已忽略');
          continue;
        }
        if (rel > 1.0) rel = rel > 100 ? 1.0 : rel / 100.0;
        secondary.add((kpId: id, relevance: rel.clamp(0.0, 1.0)));
        if (secondary.length >= 3) break; // 最多 3 个
      }
    }

    // ── difficulty ──
    var difficulty = 2;
    final d = j['difficulty'];
    if (d is num) {
      difficulty = d.round();
    } else if (d is String) {
      difficulty = int.tryParse(d.trim()) ?? 2;
    }
    if (difficulty < 1 || difficulty > 3) {
      warnings.add('difficulty=$difficulty 越界，已夹到 [1,3]');
      difficulty = difficulty.clamp(1, 3);
    }

    // ── error_causes ──
    final causes = <String>[];
    final ecRaw = j['error_causes'] ?? j['errorCauses'];
    if (ecRaw is List) {
      for (final c in ecRaw) {
        final id = c.toString().trim().toLowerCase();
        if (kErrorCauseIds.contains(id)) {
          if (!causes.contains(id)) causes.add(id);
        } else if (id.isNotEmpty) {
          warnings.add('错因「$id」不在受控词表里，已忽略');
        }
      }
    } else if (ecRaw is String && ecRaw.trim().isNotEmpty) {
      for (final part in ecRaw.split(RegExp(r'[,、;；\s]+'))) {
        final id = part.trim().toLowerCase();
        if (kErrorCauseIds.contains(id) && !causes.contains(id)) {
          causes.add(id);
        }
      }
    }

    // ── reason ──
    final reason = (j['reason'] ?? j['rationale'] ?? '').toString().trim();

    return TagResult(
      primaryKpId: primaryId,
      confidence: confidence,
      secondary: secondary,
      difficulty: difficulty,
      errorCauses: causes,
      reason: reason.length > 200 ? '${reason.substring(0, 200)}…' : reason,
      warnings: warnings,
      extractionStrategy: extractionStrategy,
    );
  }

  @override
  String toString() => 'TagResult(primary=$primaryKpId, '
      'conf=${confidence.toStringAsFixed(2)}, '
      'secondary=${secondary.length}, diff=$difficulty, '
      'causes=$errorCauses${warnings.isEmpty ? "" : ", warnings=${warnings.length}"})';
}
