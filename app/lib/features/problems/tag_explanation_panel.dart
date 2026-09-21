/// 标注依据面板 —— 「AI 为什么这么判」。
///
/// ## 它补的是"判了但看不见"这个缺口
///
/// 标注链路一直在产出两样**能解释结论**的东西：
///
/// 1. **召回层**（`KnowledgeRecall`）给出的候选排名与**逐条命中原因**
///    （`RecallCandidate.reasons`："公式匹配 ×0.83"、"名称命中「…」"…）
/// 2. **模型**给出的 `confidence`（对 primary 判断的把握，见 `tag_prompt.dart`）
///
/// 但这两样在界面上一次都没露过 —— `features/problems/` 下此前
/// grep `reasons|confidence` 零命中。用户看不到 AI 判得对不对，
/// 也就无从纠正：一个判错的主考点会一路影响复习队列与组卷。
///
/// ## 为什么这里读的是"实时重算"而不是"当时的判断"
///
/// 会写进题目文件（frontmatter）的只有 `ai_tagged` / `ai_confidence` /
/// `needs_review` 与 `knowledge` 列表（见 `problem_store.dart`）。
/// 模型的 `reason`（一句话判断依据）与召回候选的 `reasons`
/// **都没有落库** —— 前者随 `TagResult` 一起丢了，后者本来就只是中间产物。
///
/// 好在召回层是**纯规则、不含 LLM、毫秒级**的，可以随时按当前知识库重算。
/// 所以这个面板说的是两件不同的事，并在末尾把边界写清楚：
///
/// | 区块 | 说的是什么 | 可信度 |
/// |---|---|---|
/// | 「标注结果」 | 题目文件里**确实存了什么** | 事实，来自磁盘 |
/// | 「召回重算」 | 知识库**现在**会召回什么、为什么 | 可复算的推理过程，非模型原话 |
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_fonts.dart';
import '../../core/theme/app_theme.dart';
import '../../data/markdown/problem_markdown.dart';
import '../../domain/knowledge/knowledge_point.dart';
import '../../services/tagger/knowledge_recall.dart';

/// 折叠区外壳：负责「取召回器」与「懒加载」。
///
/// 与纯展示的 [TagExplanationView] 分开，是为了让后者不依赖任何 provider
/// —— 召回结果可以手工构造，测试就能直接断言渲染内容。
class TagExplanationPanel extends ConsumerStatefulWidget {
  final Problem problem;

  const TagExplanationPanel({super.key, required this.problem});

  @override
  ConsumerState<TagExplanationPanel> createState() =>
      _TagExplanationPanelState();
}

class _TagExplanationPanelState extends ConsumerState<TagExplanationPanel> {
  /// 是否已展开。
  ///
  /// ## 为什么要等展开才去取召回器
  ///
  /// `KnowledgeRecall` 的构造要遍历全部叶子（数一 200+）预计算 IDF 与
  /// 分词，而详情页每次打开都会 rebuild。不懒加载的话，光"看一眼题目"
  /// 都要付一遍这个成本 —— 而多数时候用户并不关心判据。
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Header(
          expanded: _expanded,
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        if (_expanded) ...[
          const SizedBox(height: 10),
          _buildBody(),
        ],
      ],
    );
  }

  Widget _buildBody() {
    final async = ref.watch(knowledgeRecallProvider);
    final kb = ref.watch(knowledgeBaseProvider).valueOrNull;

    // 召回算不出来时**照样渲染上半截** —— 「题目文件里存了什么」不依赖
    // 知识库，把它一起藏掉等于因为一个次要区块失败而丢掉主要信息。
    return async.when(
      loading: () => TagExplanationView(
        problem: widget.problem,
        recallNote: '正在按当前知识库重算召回…',
      ),
      error: (e, _) => TagExplanationView(
        problem: widget.problem,
        recallNote: '知识库没能载入，无法重算召回：$e',
      ),
      data: (recall) => TagExplanationView(
        problem: widget.problem,
        recall: recall.recall(widget.problem),
        knowledge: kb,
      ),
    );
  }
}

/// 面板正文（纯展示，不依赖 provider）。
class TagExplanationView extends StatelessWidget {
  final Problem problem;

  /// 召回重算结果。为 null 时表示**还没算出来或算不出来**，
  /// 此时用 [recallNote] 说明原因，而不是渲染一张空表。
  final RecallResult? recall;

  /// [recall] 为空时的说明（加载中 / 失败原因）。
  final String? recallNote;

  /// 用于把知识点 id 显示成名字。为 null 时退化成只显示 id。
  final KnowledgeBase? knowledge;

  const TagExplanationView({
    super.key,
    required this.problem,
    this.recall,
    this.recallNote,
    this.knowledge,
  }) : assert(recall != null || recallNote != null,
            '召回结果与说明至少要有一个，否则这一块会变成空白');

  /// 知识库里的 id → 名字；查不到就退回 id 本身。
  ///
  /// 不隐藏查不到的 id：它本身就是一条线索
  /// （本体更新过、或这道题来自另一个科目的命名空间）。
  String _nameOf(String id) => knowledge?.byId[id]?.name ?? id;

  @override
  Widget build(BuildContext context) {
    final primaryId = problem.primaryKnowledge?.id;
    final secondaries =
        problem.knowledge.where((k) => !k.isPrimary).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Block(
          title: '标注结果（题目文件里存的）',
          children: [
            _Row(
              label: '来源',
              value: problem.aiTagged ? 'AI 标注' : '手工填写',
            ),
            if (problem.aiTagged) ...[
              _Row(
                label: '把握',
                value: problem.aiConfidence == null
                    ? '未记录'
                    : '${(problem.aiConfidence! * 100).round()}%',
                note: problem.aiConfidence == null
                    ? '旧版本写入的题目可能没有这个字段'
                    : '模型对「主考点判断」的把握，不是对答案对错的把握',
              ),
              _Row(
                label: '复核',
                value: problem.needsReview ? '当时被判为需人工确认' : '未要求复核',
                note: problem.needsReview
                    ? '说明把握低于当时模型的门槛，或校验出过阻断性问题'
                    : null,
              ),
            ] else
              const _Note(
                '这道题的考点是手工填的，没有经过模型 —— '
                '所以没有"模型判据"可看。下面仍可按当前知识库重算召回。',
              ),
            if (primaryId != null)
              _Row(label: '主考点', value: '${_nameOf(primaryId)}  $primaryId')
            else
              const _Row(label: '主考点', value: '未填'),
            _Row(
              label: '次考点',
              value: secondaries.isEmpty
                  ? '无'
                  : secondaries
                      .map((k) =>
                          '${_nameOf(k.id)}（${k.relevance.toStringAsFixed(2)}）')
                      .join('、'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _Block(
          title: '召回重算（按当前知识库，实时）',
          children: recall == null
              ? [_Note(recallNote!)]
              : _recallRows(recall!, primaryId),
        ),
        const SizedBox(height: 12),
        const _BoundaryNote(),
      ],
    );
  }

  List<Widget> _recallRows(RecallResult r, String? primaryId) {
    if (r.isEmpty) {
      return const [
        _Note(
          '重算得到 0 个候选 —— 当前科目的知识点本体可能没载入，'
          '或还没编好。召回为空时标注本身也无法进行。',
        ),
      ];
    }

    final rank = primaryId == null
        ? -1
        : r.candidates.indexWhere((c) => c.point.id == primaryId);
    final shown = r.candidates.take(_maxShownCandidates).toList();

    return [
      _Row(
        label: '候选',
        value: '${r.candidates.length} / ${r.totalLeaves} 个叶子'
            '（覆盖 ${(r.coverage * 100).toStringAsFixed(1)}%）',
        note: '召回只负责把全部叶子筛成一小撮候选，选谁由模型决定',
      ),
      _Row(label: '命中', value: _hitSummary(r)),
      if (primaryId != null)
        rank >= 0
            ? _Row(
                label: '主考点',
                value: '在候选里排第 ${rank + 1} / ${r.candidates.length} 位'
                    '（得分 ${r.candidates[rank].score.toStringAsFixed(2)}）',
              )
            : const _Row(
                label: '主考点',
                value: '不在当前候选里',
                note: '标注时模型只被允许在候选里挑，所以这种不一致通常是'
                    '本体更新过、或考点被手工改过 —— 值得看一眼',
              ),
      const SizedBox(height: 2),
      for (var i = 0; i < shown.length; i++) ...[
        if (i > 0) const SizedBox(height: 6),
        _CandidateRow(
          index: i,
          candidate: shown[i],
          name: _nameOf(shown[i].point.id),
          isPrimary: shown[i].point.id == primaryId,
        ),
      ],
      if (r.candidates.length > shown.length) ...[
        const SizedBox(height: 6),
        _Note('只列出前 ${shown.length} 个，共 ${r.candidates.length} 个候选。'),
      ],
    ];
  }

  /// 各策略的命中统计，只列非零项。
  String _hitSummary(RecallResult r) {
    final parts = <String>[
      if (r.formulaHits > 0) '公式 ${r.formulaHits}',
      if (r.nameHits > 0) '名称 ${r.nameHits}',
      if (r.aliasHits > 0) '别名 ${r.aliasHits}',
      if (r.chapterFloorAdded > 0) '章节保底 ${r.chapterFloorAdded}',
    ];
    if (parts.isEmpty) return '没有任何策略命中';
    return parts.join(' · ');
  }
}

/// 最多列出的候选条数。
///
/// 不列满 25 个：面板要回答的是"为什么是这几个"，
/// 而不是把召回表原样倒出来 —— 后者只会让人放弃阅读。
const int _maxShownCandidates = 6;

// ─────────────────────────────────────────────────────────────────────────────
// 零件
// ─────────────────────────────────────────────────────────────────────────────

/// 可点开的标题行。
class _Header extends StatelessWidget {
  final bool expanded;
  final VoidCallback onTap;

  const _Header({required this.expanded, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface2,
      borderRadius: AppRadius.rMd,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.rMd,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
          decoration: BoxDecoration(
            borderRadius: AppRadius.rMd,
            border: Border.all(color: AppColors.line),
          ),
          child: Row(
            children: [
              const Icon(Icons.psychology_outlined,
                  size: 16, color: AppColors.primaryStrong),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'AI 为什么这么判',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: AppFonts.bold,
                    color: AppColors.ink1,
                  ),
                ),
              ),
              Text(
                expanded ? '收起' : '展开',
                style: const TextStyle(fontSize: 11.5, color: AppColors.ink3),
              ),
              const SizedBox(width: 2),
              AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 160),
                child: const Icon(Icons.expand_more,
                    size: 18, color: AppColors.ink3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一个小节。
class _Block extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _Block({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.rMd,
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: AppFonts.bold,
              color: AppColors.ink3,
            ),
          ),
          const SizedBox(height: 9),
          ...children,
        ],
      ),
    );
  }
}

/// 「标签 + 值（+ 可选注解）」一行。
class _Row extends StatelessWidget {
  final String label;
  final String value;

  /// 灰字补充说明，跟在值后面另起一行。
  final String? note;

  const _Row({required this.label, required this.value, this.note});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 46,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                height: 1.7,
                fontWeight: AppFonts.bold,
                color: AppColors.ink3,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.7,
                    color: AppColors.ink2,
                  ),
                ),
                if (note != null)
                  Text(
                    note!,
                    style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.65,
                      color: AppColors.ink3,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 一条候选：名次 + 名称 + id + 得分 + 命中原因。
class _CandidateRow extends StatelessWidget {
  final int index;
  final RecallCandidate candidate;
  final String name;

  /// 是否是题目当前记的主考点。
  final bool isPrimary;

  const _CandidateRow({
    required this.index,
    required this.candidate,
    required this.name,
    required this.isPrimary,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
      decoration: BoxDecoration(
        color: isPrimary ? AppColors.primaryWeak : AppColors.surface2,
        borderRadius: AppRadius.rSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${index + 1}.',
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  fontWeight: AppFonts.bold,
                  color: AppColors.ink3,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.6,
                    fontWeight: AppFonts.bold,
                    color:
                        isPrimary ? AppColors.primaryStrong : AppColors.ink1,
                  ),
                ),
              ),
              if (isPrimary) ...[
                const SizedBox(width: 6),
                const Text(
                  '本题主考点',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: AppFonts.bold,
                    color: AppColors.primaryStrong,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${candidate.point.id} · 得分 ${candidate.score.toStringAsFixed(2)}',
            style: const TextStyle(
              fontSize: 11,
              height: 1.6,
              color: AppColors.ink3,
            ),
          ),
          Text(
            candidate.reasons.isEmpty
                ? '（没有记录命中原因）'
                : candidate.reasons.join(' · '),
            style: const TextStyle(
              fontSize: 11.5,
              height: 1.65,
              color: AppColors.ink2,
            ),
          ),
        ],
      ),
    );
  }
}

/// 灰底提示。
class _Note extends StatelessWidget {
  final String text;

  const _Note(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 4),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 11.5,
            height: 1.7,
            color: AppColors.ink3,
          ),
        ),
      );
}

/// 边界说明：把"可复算的推理"与"模型原话"分开，别让用户误读。
class _BoundaryNote extends StatelessWidget {
  const _BoundaryNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppRadius.rMd,
        border: Border.all(color: AppColors.line),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '怎么读这块内容',
            style: TextStyle(
              fontSize: 12,
              fontWeight: AppFonts.bold,
              color: AppColors.ink3,
            ),
          ),
          SizedBox(height: 6),
          Text(
            '· 召回是纯规则算的（不含模型），所以能随时重算、也能逐条解释；'
            '它只负责把两百多个考点筛成一小撮候选。',
            style: TextStyle(
              fontSize: 11.5,
              height: 1.75,
              color: AppColors.ink3,
            ),
          ),
          Text(
            '· 模型的「一句话判断依据」没有写进题目文件，所以这里看不到'
            '模型自己怎么说的 —— 只看得到它给出的把握与最终挑中的考点。',
            style: TextStyle(
              fontSize: 11.5,
              height: 1.75,
              color: AppColors.ink3,
            ),
          ),
          Text.rich(
            TextSpan(
              style: TextStyle(
                fontSize: 11.5,
                height: 1.75,
                color: AppColors.ink3,
              ),
              children: [
                TextSpan(text: '· 重算用的是'),
                TextSpan(
                  text: '当前',
                  style: TextStyle(fontWeight: AppFonts.bold),
                ),
                TextSpan(
                    text: '知识库。本体更新过的话，结果可能与标注当时不同。'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
