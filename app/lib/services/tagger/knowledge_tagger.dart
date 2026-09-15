/// 知识点标注引擎 —— 编排「召回 → 判定 → 校验 → 缓存」。
///
/// ## 完整流程
/// ```
/// 题目
///  ├─ 查缓存（按 fingerprint）───── 命中 → 直接返回，零成本
///  └─ 未命中
///      ├─ 阶段 1：规则召回 226 → 25 个候选
///      ├─ 阶段 2：LLM 从候选中选主/次考点
///      ├─ 阶段 3：严格校验（id 必须在候选集里）
///      │    └─ 校验失败 → 带上错误信息重试（最多 3 次）
///      └─ 写入缓存
/// ```
///
/// ## 为什么缓存是必需的
/// BYOK 模式下花的是**用户自己的钱**。同一个 fingerprint 的题
/// （比如用户重复录入、或同一道真题在多个文件里）只该标注一次。
/// 缓存命中时 `LlmUsage.fromCache` 为 true，UI 可显示"本题已缓存，未消耗额度"。
library;

import 'dart:convert';

import '../../data/markdown/problem_markdown.dart';
import '../../domain/knowledge/knowledge_point.dart';
import '../llm/llm_client.dart';
import '../llm/robust_json.dart';
import 'knowledge_recall.dart';
import 'tag_prompt.dart';

/// 一次标注的完整结果。
class TagOutcome {
  /// 标注结果。解析彻底失败时为 null。
  final TagResult? result;

  /// 本次消耗（命中缓存时为 [LlmUsage.cached]）。
  final LlmUsage usage;

  /// 召回结果（可用于 UI 展示"为什么选这些候选"）。
  final RecallResult recall;

  /// 尝试次数。
  final int attempts;

  /// 是否来自缓存。
  final bool fromCache;

  /// 失败原因（result 为 null 时非空）。
  final String? failure;

  const TagOutcome({
    this.result,
    required this.usage,
    required this.recall,
    this.attempts = 0,
    this.fromCache = false,
    this.failure,
  });

  bool get ok => result != null;

  @override
  String toString() => 'TagOutcome(${ok ? result : "FAILED: $failure"}, '
      'attempts=$attempts, cache=$fromCache, '
      'tokens=${usage.totalTokens})';
}

/// 标注缓存接口。
abstract class TagCache {
  Future<TagResult?> get(String fingerprint);
  Future<void> put(String fingerprint, TagResult result);
}

/// 内存缓存（测试用，也可作为运行期的一级缓存）。
class MemoryTagCache implements TagCache {
  final Map<String, TagResult> _m = {};

  @override
  Future<TagResult?> get(String fingerprint) async => _m[fingerprint];

  @override
  Future<void> put(String fingerprint, TagResult result) async {
    _m[fingerprint] = result;
  }

  int get size => _m.length;
  void clear() => _m.clear();
}

/// 标注引擎。
class KnowledgeTagger {
  final KnowledgeBase knowledge;
  final LlmClient client;
  final TagCache? cache;
  final RecallConfig recallConfig;

  /// 校验失败后的最大重试次数（含首次尝试）。
  final int maxAttempts;

  /// 召回器。**按本体建一次**，不是每题重建。
  ///
  /// ## 这里是 M7 之前必须修的一处性能问题
  ///
  /// `KnowledgeRecall` 的构造函数要遍历全部叶子预计算 IDF、公式分词与
  /// 别名索引 —— 那是刻意的，它自己的注释写着"召回是热点路径，
  /// 不预计算会明显变慢"。但早先这个对象是在 `tag()` **里面** new 的，
  /// 于是"预计算"退化成"每题算一遍"：141 个叶子 × 若干次正则，
  /// 单题约 7000 次正则；批量导入 100 题就是 70 万次，5000 题是 3500 万次。
  ///
  /// 本体的生命周期与 tagger 一致（一次标注会话里不会换本体），
  /// 所以缓存在这里既正确又简单。
  late final KnowledgeRecall _recall = KnowledgeRecall(
    knowledge: knowledge,
    config: recallConfig,
  );

  KnowledgeTagger({
    required this.knowledge,
    required this.client,
    this.cache,
    this.recallConfig = RecallConfig.defaults,
    this.maxAttempts = 3,
  });

  /// 标注一道题。
  Future<TagOutcome> tag(Problem problem) async {
    // ── 阶段 0：缓存 ──
    //
    // ⚠️ 缓存键只有 (fingerprint, model)，**不含科目**。而 fingerprint 只看题干，
    // 数一/数三共用大量高数内容的题干 → 同一个 fingerprint 在两个科目下
    // 可能指向不同的知识点 id 命名空间（`math1.*` / `math3.*`）。
    // 所以命中缓存后必须回到**当前本体**再校验一次：
    // 否则用户会拿到另一个科目的考点 id，保存时被 `validate()` 挡下来
    // （"主考点不在知识点本体里"），而反复点「AI 标注」只会一直拿到同一个
    // 缓存结果 —— 零成本、零提示、死循环。
    final fingerprint = problem.fingerprint;
    if (cache != null && fingerprint.isNotEmpty) {
      final hit = await cache!.get(fingerprint);
      if (hit != null && knowledge.byId.containsKey(hit.primaryKpId)) {
        return TagOutcome(
          result: hit,
          usage: LlmUsage.cached,
          recall: const RecallResult(candidates: [], totalLeaves: 0),
          fromCache: true,
        );
      }
    }

    // ── 阶段 1：召回 ──
    final recall = _recall.recall(problem);

    if (recall.isEmpty) {
      return TagOutcome(
        usage: const LlmUsage(),
        recall: recall,
        failure: '召回为空：该科目的知识点本体可能未加载',
      );
    }

    final candidateIds = {for (final c in recall.candidates) c.point.id};
    final builder = TagPromptBuilder(knowledge: knowledge);
    var (system, user) = builder.build(problem: problem, recall: recall);

    // 原始 prompt 留一份。重试时以**它**为基准拼接，而不是在上一次的结果上
    // 继续追加 —— 否则第 3 次尝试的 prompt 里会带着两份过时的模型输出，
    // 既白烧 token，又让模型分不清该改哪一份。
    final baseUser = user;

    var usage = const LlmUsage();
    TagResult? lastResult;
    final allWarnings = <String>[];

    // ── 阶段 2 + 3：判定与校验（带重试） ──
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      ChatResponse resp;
      try {
        resp = await client.chat(ChatRequest(
          system: system,
          user: user,
          jsonMode: true,
          // 标注任务要稳定，温度压到很低
          temperature: 0.1,
        ));
      } on LlmException catch (e) {
        return TagOutcome(
          usage: usage,
          recall: recall,
          attempts: attempt,
          failure: '${e.kind.name}：${e.message}\n建议：${e.kind.advice}',
        );
      }

      usage = usage + resp.usage;

      // 解析（三重保险）
      final extracted = RobustJson.extract(resp.text);
      if (!extracted.ok) {
        allWarnings.addAll(extracted.warnings);
        if (attempt < maxAttempts) {
          user = _retryPrompt(baseUser, resp.text, extracted.warnings);
          continue;
        }
        return TagOutcome(
          usage: usage,
          recall: recall,
          attempts: attempt,
          failure: '模型输出无法解析为 JSON（尝试 $attempt 次）。'
              '${extracted.warnings.take(2).join("；")}',
        );
      }

      final result = TagResult.fromJson(
        extracted.value!,
        candidateIds: candidateIds,
        defaultConfidence: 0.5,
        extractionStrategy: extracted.strategy,
      );
      lastResult = result;
      allWarnings.addAll(result.warnings);

      // 校验：primary 必须有效且不在候选集外
      final blocking =
          result.warnings.where(TagResult.isBlockingWarning).toList();
      if (blocking.isEmpty) {
        // 有效结果：写缓存并返回
        if (cache != null && fingerprint.isNotEmpty) {
          await cache!.put(fingerprint, result);
        }
        return TagOutcome(
          result: result,
          usage: usage,
          recall: recall,
          attempts: attempt,
        );
      }

      // 有阻断性问题 → 带错误信息重试
      if (attempt < maxAttempts) {
        user = _retryPrompt(baseUser, resp.text, blocking);
        continue;
      }
    }

    // 用尽重试次数：返回最后的结果（标记警告），让上层决定是否进人工队列。
    //
    // ⚠️ **刻意不写缓存**。这个结果的 `warnings` 里有阻断性问题
    // （primary 不在候选集、primary 缺失等），也就是"这次标注没成功"。
    // 把它缓存起来等于把一次失败固化：用户再点一次「AI 标注」会秒回同一个
    // 坏结果、不花 token、也不再重试 —— 而正确的期待恰恰是"重试一次"。
    if (lastResult != null) {
      return TagOutcome(
        result: lastResult,
        usage: usage,
        recall: recall,
        attempts: maxAttempts,
      );
    }

    return TagOutcome(
      usage: usage,
      recall: recall,
      attempts: maxAttempts,
      failure: '标注失败：${allWarnings.take(3).join("；")}',
    );
  }

  /// 构造重试 prompt：把上次的输出与错误回传，让模型自我修正。
  ///
  /// 这比"原样重发"有效得多 —— 模型能看到自己错在哪。
  String _retryPrompt(String original, String lastOutput, List<String> problems) {
    final b = StringBuffer(original);
    b.writeln();
    b.writeln();
    b.writeln('---');
    b.writeln('## 上次输出有问题，请修正');
    b.writeln();
    b.writeln('你上次的输出：');
    b.writeln('```');
    b.writeln(lastOutput.length > 800
        ? '${lastOutput.substring(0, 800)}…'
        : lastOutput);
    b.writeln('```');
    b.writeln();
    b.writeln('问题：');
    for (final p in problems) {
      b.writeln('- $p');
    }
    b.writeln();
    b.writeln('请重新输出，**只输出合法 JSON**，不要任何解释或代码块标记。'
        'primary.kp_id 必须是候选列表中真实存在的 id。');
    return b.toString();
  }
}

/// 把一个 [TagResult] 应用回 [Problem]。
///
/// 之所以独立成函数而不是写在 tagger 里：题目的知识点字段是
/// **内容**（要写进 Markdown 文件），而用户状态是另一回事。
/// 这个函数只负责把标注结果转成题目字段。
///
/// [confidenceThreshold] **必须由调用方给出**。这里曾经用一个硬编码的
/// 0.70，注释还写着"用与 tagger 一致的规则判断门槛" —— 而实际生效的门槛是
/// 校准出来的 0.90 / 0.92 / 0.95（见 `provider_registry.dart`）。
/// 0.70 会把几乎所有低置信结果都标成"不用复核"，而这是一个**要写进
/// Markdown frontmatter** 的字段：一旦写错，将来没有任何地方能发现它错了。
/// 与其留一个能静默出错的默认值，不如要求调用方显式传。
Problem applyTagResult(
  Problem problem,
  TagResult tag, {
  required double confidenceThreshold,
}) {
  final refs = <KnowledgeRef>[
    KnowledgeRef(id: tag.primaryKpId, role: 'primary', relevance: 1.0),
  ];
  // 次考点去重：主考点本身、以及次考点之间都可能重复。
  // 重复项会变成 frontmatter 里两条一模一样的 knowledge 项，
  // 并在派生表 `problem_knowledge` 里留下两行重复关联。
  final seen = <String>{tag.primaryKpId};
  for (final s in tag.secondary) {
    if (s.kpId.isEmpty || !seen.add(s.kpId)) continue;
    refs.add(KnowledgeRef(id: s.kpId, role: 'secondary', relevance: s.relevance));
  }

  return problem.copyWith(
    knowledge: refs,
    difficulty: tag.difficulty,
    // 题目里的 error_causes 是 AI 预判的易错点。
    // 若题目已有用户填写的错因（一般不会），不覆盖 —— 但题目属性本身
    // 就是"易错点"语义，所以这里直接写入。
    errorCauses: tag.errorCauses,
    aiTagged: true,
    aiConfidence: tag.confidence,
    needsReview: tag.needsReview(confidenceThreshold),
  );
}

/// 序列化/反序列化标注结果（用于写 `ai_cache` 表或日志）。
abstract final class TagResultCodec {
  const TagResultCodec._();

  static String encode(TagResult r) => jsonEncode({
        'primary': r.primaryKpId,
        'confidence': r.confidence,
        'secondary': [
          for (final s in r.secondary) {'kp_id': s.kpId, 'relevance': s.relevance},
        ],
        'difficulty': r.difficulty,
        'error_causes': r.errorCauses,
        'reason': r.reason,
        'strategy': r.extractionStrategy,
        'warnings': r.warnings,
      });

  static TagResult? decode(String s) {
    try {
      final j = jsonDecode(s);
      if (j is! Map) return null;
      final m = j.cast<String, dynamic>();
      final primary = m['primary']?.toString() ?? '';
      return TagResult.fromJson(
        {
          'primary': {
            'kp_id': m['primary'],
            'confidence': m['confidence'],
          },
          'secondary': m['secondary'],
          'difficulty': m['difficulty'],
          'error_causes': m['error_causes'],
          'reason': m['reason'],
        },
        // 反序列化时不校验候选集（缓存里的结果已经校验过了）
        candidateIds: {
          primary,
          for (final s in (m['secondary'] as List? ?? []))
            if (s is Map) s['kp_id']?.toString() ?? '',
        },
        defaultConfidence: 0.5,
        extractionStrategy: m['strategy']?.toString() ?? 'cache',
        // ⚠️ 必须把警告带回来。早先 encode 写了 `warnings` 而 decode 从不读它，
        // 于是缓存命中时 `needsReview` 只剩置信度一条判据：
        // 一个"primary 不在候选集里"的阻断性结果，第一次会要求人工确认，
        // 第二次（命中缓存）却静默通过 —— 而且用户看到的还是
        // "命中本地缓存，未消耗 token"，完全没有察觉。
        priorWarnings: (m['warnings'] as List? ?? const [])
            .map((w) => w.toString())
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }
}
