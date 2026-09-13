/// M3 评测：Top-1 准确率与召回率。
///
/// ## 为什么必须先建评测基线
///
/// 我在项目规划阶段就定了一条硬指标：**知识点标注 Top-1 准确率 ≥ 80%**。
/// 达不到就要调整方案（收紧知识点粒度，或改成"给候选让用户选"）。
///
/// 没有基线就无从判断"标注质量好不好"—— 只能凭感觉，
/// 而感觉在 226 个知识点、357 个叶子节点的规模下完全不可靠。
///
/// ## 两层评测
///
/// | 层 | 需要 LLM | 现在能跑 | 说明 |
/// |---|---|---|---|
/// | **召回率** | ❌ | ✅ | 金标准答案在不在召回出的 25 个候选里 |
/// | **Top-1 准确率** | ✅ | ⚠️ 需真实 Key | LLM 从候选中选出的主考点是否正确 |
///
/// **召回率是天花板**：如果金标准答案没进候选，LLM 再强也选不对。
/// 所以召回率评测本身就有独立价值，且完全离线。
library;

import 'dart:convert';
import 'dart:io';

import '../../data/markdown/problem_markdown.dart';
import '../../domain/knowledge/knowledge_point.dart';
import '../tagger/knowledge_recall.dart';
import '../tagger/knowledge_tagger.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 数据模型
// ─────────────────────────────────────────────────────────────────────────────

/// 一道金标准评测题：人工标注了正确的主考点。
class GoldProblem {
  final String id;
  final String stem;
  final QuestionType qtype;

  /// 人工标注的主考点 id（正确答案）。
  final String primaryKpId;

  /// 人工标注的次考点（可选，用于评估次考点质量）。
  final List<String> secondaryKpIds;

  final int difficulty;
  final String? source;

  /// 标注者备注（如"这题有争议"），用于分析错例。
  final String? note;

  const GoldProblem({
    required this.id,
    required this.stem,
    this.qtype = QuestionType.solve,
    required this.primaryKpId,
    this.secondaryKpIds = const [],
    this.difficulty = 2,
    this.source,
    this.note,
  });

  Problem toProblem() => Problem(
        id: id,
        fingerprint: 'gold-$id',
        stem: stem,
        qtype: qtype,
        difficulty: difficulty,
        source: source,
      );

  factory GoldProblem.fromJson(Map<String, dynamic> j) => GoldProblem(
        id: j['id']?.toString() ?? '',
        stem: j['stem']?.toString() ?? '',
        qtype: QuestionType.fromId(j['qtype']?.toString()),
        primaryKpId: j['primary_kp_id']?.toString() ?? '',
        secondaryKpIds: (j['secondary_kp_ids'] as List? ?? [])
            .map((e) => e.toString())
            .toList(),
        difficulty: (j['difficulty'] as num?)?.toInt() ?? 2,
        source: j['source']?.toString(),
        note: j['note']?.toString(),
      );
}

/// 单题评测结果。
class EvalItem {
  final GoldProblem gold;

  /// 召回出的候选 id（有序）。
  final List<String> recalled;

  /// 召回排名（金标准答案在候选里的位置，1-based；未召回为 null）。
  final int? recallRank;

  /// LLM 选出的主考点（未跑 LLM 时为 null）。
  final String? predicted;

  /// 置信度。
  final double? confidence;

  /// 是否进了人工确认队列。
  final bool needsReview;

  /// 失败原因（如 LLM 调用失败）。
  final String? failure;

  const EvalItem({
    required this.gold,
    required this.recalled,
    this.recallRank,
    this.predicted,
    this.confidence,
    this.needsReview = false,
    this.failure,
  });

  /// 召回是否命中。
  bool get recallHit => recallRank != null;

  /// Top-1 是否正确。
  bool? get top1Correct {
    if (predicted == null) return null;
    // 主考点正确，或预测的是人工标注的次考点之一也算"部分正确"？
    // 不算 —— Top-1 要求严格命中主考点。
    return predicted == gold.primaryKpId;
  }

  /// 是否"可接受"：Top-1 命中主考点，或命中了人工标注的次考点。
  bool? get acceptable {
    if (predicted == null) return null;
    return predicted == gold.primaryKpId ||
        gold.secondaryKpIds.contains(predicted);
  }
}

/// 评测报告。
class EvalReport {
  final List<EvalItem> items;

  /// 是否跑了 LLM。
  final bool llmEvaluated;

  /// 知识点叶子总数（评估召回难度）。
  final int totalLeaves;

  const EvalReport({
    required this.items,
    this.llmEvaluated = false,
    this.totalLeaves = 0,
  });

  int get total => items.length;

  /// 召回率：金标准答案出现在候选里的比例。
  double get recallRate {
    if (total == 0) return 0;
    return items.where((i) => i.recallHit).length / total;
  }

  /// Top-1 召回率：金标准答案排在候选**第一位**的比例。
  ///
  /// 这是比"召回率"更强的指标 —— 排第一说明规则匹配质量高。
  double get top1RecallRate {
    if (total == 0) return 0;
    return items.where((i) => i.recallRank == 1).length / total;
  }

  /// Top-3 召回率。
  double get top3RecallRate {
    if (total == 0) return 0;
    return items
            .where((i) => i.recallRank != null && i.recallRank! <= 3)
            .length /
        total;
  }

  /// LLM Top-1 准确率。未跑 LLM 时返回 null。
  double? get top1Accuracy {
    if (!llmEvaluated) return null;
    final judged = items.where((i) => i.top1Correct != null).toList();
    if (judged.isEmpty) return null;
    return judged.where((i) => i.top1Correct!).length / judged.length;
  }

  /// LLM 可接受率（命中主考点或人工标注的次考点）。
  double? get acceptableRate {
    if (!llmEvaluated) return null;
    final judged = items.where((i) => i.acceptable != null).toList();
    if (judged.isEmpty) return null;
    return judged.where((i) => i.acceptable!).length / judged.length;
  }

  /// 进人工确认队列的比例。太高说明置信度门槛过严或模型太弱。
  double? get reviewRate {
    if (!llmEvaluated) return null;
    final judged = items.where((i) => i.predicted != null).toList();
    if (judged.isEmpty) return null;
    return judged.where((i) => i.needsReview).length / judged.length;
  }

  /// 调用失败的比例。
  double get failureRate {
    if (total == 0) return 0;
    return items.where((i) => i.failure != null).length / total;
  }

  /// 召回失败的题目（金标准答案没进候选）—— 这些是最该看的错例。
  List<EvalItem> get recallMisses =>
      items.where((i) => !i.recallHit).toList();

  /// Top-1 预测错误的题目。
  List<EvalItem> get top1Errors =>
      items.where((i) => i.top1Correct == false).toList();

  /// 人类可读报告。
  String summary() {
    final b = StringBuffer();
    b.writeln('=' * 66);
    b.writeln('M3 知识点标注评测报告');
    b.writeln('=' * 66);
    b.writeln('样本数：$total   知识点叶子总数：$totalLeaves');
    b.writeln();
    b.writeln('── 召回层（纯规则，无需 LLM）──');
    b.writeln('  召回率   (答案∈候选)  ：${_pct(recallRate)}');
    b.writeln('  Top-1 召回(答案排第1)  ：${_pct(top1RecallRate)}');
    b.writeln('  Top-3 召回             ：${_pct(top3RecallRate)}');
    b.writeln();

    if (llmEvaluated) {
      b.writeln('── 判定层（LLM）──');
      b.writeln('  Top-1 准确率           ：${_pctOrDash(top1Accuracy)}');
      b.writeln('  可接受率(含次考点)      ：${_pctOrDash(acceptableRate)}');
      b.writeln('  进入人工确认队列        ：${_pctOrDash(reviewRate)}');
      b.writeln('  调用失败率             ：${_pct(failureRate)}');
      b.writeln();
      b.writeln('  目标：Top-1 准确率 ≥ 80%');
      final acc = top1Accuracy;
      if (acc != null) {
        b.writeln(acc >= 0.80
            ? '  ✅ 达标'
            : '  ⚠️ 未达标 —— 需要收紧知识点粒度，或改为"给候选让用户选"');
      }
    } else {
      b.writeln('（未跑 LLM 判定层：需要配置 API Key）');
    }

    if (recallMisses.isNotEmpty) {
      b.writeln();
      b.writeln('── 召回失败（金标准答案未进候选，${recallMisses.length} 题）──');
      for (final m in recallMisses.take(10)) {
        b.writeln('  ${m.gold.id}  期望 ${m.gold.primaryKpId}');
        if (m.gold.note != null) b.writeln('      备注：${m.gold.note}');
      }
    }

    if (top1Errors.isNotEmpty) {
      b.writeln();
      b.writeln('── Top-1 预测错误（${top1Errors.length} 题）──');
      for (final e in top1Errors.take(10)) {
        b.writeln('  ${e.gold.id}');
        b.writeln('      期望 ${e.gold.primaryKpId}');
        b.writeln('      预测 ${e.predicted}  (conf=${e.confidence})');
      }
    }

    return b.toString();
  }

  static String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';
  static String _pctOrDash(double? v) => v == null ? '—' : _pct(v);
}

// ─────────────────────────────────────────────────────────────────────────────
// 评测器
// ─────────────────────────────────────────────────────────────────────────────

/// M3 评测器。
class TaggerEvaluator {
  final KnowledgeBase knowledge;

  /// 可选的标注引擎。为 null 时只跑召回层评测。
  final KnowledgeTagger? tagger;

  final RecallConfig recallConfig;

  const TaggerEvaluator({
    required this.knowledge,
    this.tagger,
    this.recallConfig = RecallConfig.defaults,
  });

  /// 跑评测。
  ///
  /// [limit] 限制样本数（便于先用小样本快速验证）。
  /// [onProgress] 每题回调，用于显示进度（LLM 评测较慢）。
  Future<EvalReport> evaluate(
    List<GoldProblem> goldSet, {
    int? limit,
    void Function(int done, int total)? onProgress,
  }) async {
    final items = <EvalItem>[];
    final set = limit == null ? goldSet : goldSet.take(limit).toList();
    final recaller = KnowledgeRecall(
      knowledge: knowledge,
      config: recallConfig,
    );
    final llmEvaluated = tagger != null;

    for (var i = 0; i < set.length; i++) {
      final gold = set[i];
      final problem = gold.toProblem();

      // ── 召回层 ──
      final recall = recaller.recall(problem);
      final recalledIds = recall.candidates.map((c) => c.point.id).toList();
      final rank = recalledIds.indexOf(gold.primaryKpId);
      final recallRank = rank >= 0 ? rank + 1 : null;

      // ── 判定层 ──
      String? predicted;
      double? confidence;
      var needsReview = false;
      String? failure;

      if (tagger != null) {
        try {
          final outcome = await tagger!.tag(problem);
          if (outcome.ok) {
            predicted = outcome.result!.primaryKpId;
            confidence = outcome.result!.confidence;
            needsReview = outcome.result!
                .needsReview(tagger!.client.config.confidenceThreshold);
          } else {
            failure = outcome.failure;
          }
        } catch (e) {
          failure = '$e';
        }
      }

      items.add(EvalItem(
        gold: gold,
        recalled: recalledIds,
        recallRank: recallRank,
        predicted: predicted,
        confidence: confidence,
        needsReview: needsReview,
        failure: failure,
      ));

      onProgress?.call(i + 1, set.length);
    }

    return EvalReport(
      items: items,
      llmEvaluated: llmEvaluated,
      totalLeaves: knowledge.leaves.length,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 金标准集加载
// ─────────────────────────────────────────────────────────────────────────────

/// 金标准集。
class GoldSet {
  final String version;
  final String note;
  final List<GoldProblem> problems;

  const GoldSet({
    required this.version,
    required this.note,
    required this.problems,
  });

  factory GoldSet.fromJson(Map<String, dynamic> j) => GoldSet(
        version: j['version']?.toString() ?? '0',
        note: j['note']?.toString() ?? '',
        problems: (j['problems'] as List? ?? [])
            .whereType<Map<Object?, Object?>>()
            .map((m) => GoldProblem.fromJson(m.cast<String, dynamic>()))
            .where((p) => p.id.isNotEmpty && p.primaryKpId.isNotEmpty)
            .toList(),
      );

  static GoldSet? loadFromFile(String path) {
    final f = File(path);
    if (!f.existsSync()) return null;
    try {
      final j = jsonDecode(f.readAsStringSync());
      if (j is! Map) return null;
      return GoldSet.fromJson(j.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }
}
