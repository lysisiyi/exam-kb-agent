/// 一个知识点的详情卡片。
///
/// 大纲视图（就地展开）与图谱视图（底部面板）共用同一份 ——
/// 两处各写一遍的话，同一个考点在两种视图里显示的信息迟早不一致。
///
/// ## 排版原则（用户反馈"公式和知识排版要有条理、增强可读性"）
///
/// 1. **每节都有标题**，标题带一条细线延伸到右边 —— 扫一眼就知道
///    这段是定义、那段是公式、下面是陷阱，而不是一坨同权重的文字。
/// 2. **公式一行一条并编号**：长公式先按顶层 `\quad` 拆（
///    见 `splitTopLevelQuad`），再交给 [KnowledgeFormulaRow] 保证
///    **永远不会被裁掉**。同一组公式的续行不重复编号。
/// 3. **陷阱编号列出**：`1. 2. 3.`，条与条之间留空，不再挤成一堆。
/// 4. **考频/题型这类字段左右对齐**成两列表，值不会因为标签长度不齐。
library;

import 'package:flutter/material.dart';

import '../../core/math/latex_text_split.dart';
import '../../core/math/math_renderer.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/knowledge/knowledge_point.dart';
import 'knowledge_formula_row.dart';
import 'knowledge_node_style.dart';

/// 知识点详情：定义 / 核心公式 / 常见陷阱 / 考频 / 别名。
class KnowledgeLeafDetail extends StatelessWidget {
  final KnowledgePoint leaf;

  /// 所属章节名（配合学科分段显示成面包屑，避免用户忘了在看哪一章）。
  final String? chapterName;

  /// 学科分段名（可选，用于面包屑的第一段）。
  final String? sectionName;

  const KnowledgeLeafDetail({
    super.key,
    required this.leaf,
    this.chapterName,
    this.sectionName,
  });

  @override
  Widget build(BuildContext context) {
    // 公式先按顶层 \quad 拆开，再逐条渲染 —— 见 splitTopLevelQuad 的说明
    final formulas = <String>[
      for (final f in leaf.formulas) ...splitTopLevelQuad(f),
    ];
    // 别名分两类：含 LaTeX 记号的要渲染成公式，纯文字保持 chip
    final latexAliases = [
      for (final a in leaf.aliases)
        if (_looksLikeLatex(a)) a,
    ];
    final textAliases = [
      for (final a in leaf.aliases)
        if (!_looksLikeLatex(a)) a,
    ];
    final crumbs = [
      if (sectionName != null && sectionName!.isNotEmpty) sectionName!,
      if (chapterName != null && chapterName!.isNotEmpty) chapterName!,
    ];

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bg,
        borderRadius: AppRadius.rMd,
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 标题 ──────────────────────────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  leaf.name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),
              ),
              if (leaf.examWeight != null) _WeightPill(weight: leaf.examWeight!),
            ],
          ),
          if (crumbs.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(crumbs.join(' › '), style: AppTypography.caption),
          ],

          // ── 定义 ──────────────────────────────────────────────────────
          if (leaf.definition != null && leaf.definition!.isNotEmpty) ...[
            const _SectionTitle('定义'),
            MathRendering.renderer.renderMarkdown(
              leaf.definition!,
              options: const MathRenderOptions(fontSize: 12.5),
            ),
          ],

          // ── 核心公式 ──────────────────────────────────────────────────
          if (formulas.isNotEmpty) ...[
            _SectionTitle('核心公式', count: formulas.length),
            for (var i = 0; i < formulas.length; i++)
              KnowledgeFormulaRow(
                key: ValueKey('formula-${leaf.id}-$i'),
                tex: formulas[i],
                index: i + 1,
                fontSize: 12.5,
              ),
          ],

          // ── 常见陷阱 ──────────────────────────────────────────────────
          if (leaf.commonTraps.isNotEmpty) ...[
            _SectionTitle('常见陷阱', count: leaf.commonTraps.length),
            for (var i = 0; i < leaf.commonTraps.length; i++)
              _TrapItem(index: i + 1, text: leaf.commonTraps[i]),
          ],

          // ── 考频 / 题型 ───────────────────────────────────────────────
          const _SectionTitle('考频与题型'),
          _FactRow(
            label: '考频',
            value: leaf.examYears.isEmpty
                ? '暂无数据'
                : '近 ${leaf.examYears.length} 次考过',
          ),
          _FactRow(
            label: '最近',
            value: leaf.examYears.isEmpty ? '—' : '${leaf.examYears.last} 年',
          ),
          _FactRow(
            label: '题型',
            value: leaf.typicalQtypes.isEmpty
                ? '—'
                : leaf.typicalQtypes.map(_qtypeLabel).join(' / '),
          ),

          // ── 别名 ──────────────────────────────────────────────────────
          if (leaf.aliases.isNotEmpty) ...[
            _SectionTitle('召回别名', count: leaf.aliases.length),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '题干里可能这样写 —— 别名命中也会把这个考点召回给 AI',
                style: _secondary(11),
              ),
            ),
            // 文字别名（「极值」「二重积分」这类）用 chip 排；
            // **符号别名是 LaTeX**（实测 768 条里 182 条含 `\`/`_`/`^`），
            // 早先按普通文字显示 = 给用户看源码。现在按公式渲染，
            // 并且走同一套"不会被裁"的排版。
            if (textAliases.isNotEmpty)
              Wrap(
                spacing: 5,
                runSpacing: 5,
                children: [
                  for (final a in textAliases.take(12)) _AliasChip(text: a),
                  if (textAliases.length > 12)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text('+${textAliases.length - 12}',
                          style: _secondary(11)),
                    ),
                ],
              ),
            if (latexAliases.isNotEmpty) ...[
              if (textAliases.isNotEmpty) const SizedBox(height: 8),
              for (final a in latexAliases)
                KnowledgeFormulaRow(
                  key: ValueKey('alias-formula-${leaf.id}-$a'),
                  tex: a,
                  fontSize: 13,
                ),
            ],
          ],
        ],
      ),
    );
  }
}

String _qtypeLabel(String q) => switch (q) {
      'choice' => '选择',
      'fill' => '填空',
      'solve' => '解答',
      'proof' => '证明',
      _ => q,
    };

/// 这条别名看起来是 LaTeX 吗？
///
/// 判据取保守方向：出现反斜杠命令、上下标、或 `$` 就按公式渲染。
/// 误判成公式的后果只是"多渲染一条"（文字改名也能被 katex 排出来），
/// 而**漏判**的后果是用户又看到一串源码 —— 两害相权取其轻。
bool _looksLikeLatex(String s) =>
    s.contains(r'\') || s.contains('_') || s.contains('^') || s.contains(r'$');

/// 卡片里的次要文字：比 `AppTypography.caption` 深一档。
///
/// `caption` 用的是 `ink3`，白底上只有 **3.2:1**，低于 AA 的 4.5:1；
/// 卡片里的面包屑、说明、计数都属于"要读的文字"，所以显式用 ink2。
TextStyle _secondary(double size) =>
    TextStyle(fontSize: size, color: kSecondaryInk);

/// 从本体里取出该考点的面包屑（学科分段 › 章节）。
///
/// 两个视图都要用它，所以放在这里 —— 各自写一遍迟早会不一致
/// （比如一个显示"高等数学 › 极限与连续"，另一个只显示章节名）。
({String? section, String? chapter}) detailBreadcrumb(
  KnowledgeBase kb,
  String leafId,
) {
  final path = kb.pathTo(leafId);
  // 叶子在第 4 段（数三在第 5 段，中间多个"节"），所以从后往前数：
  // 自身之前的那一级是章节，再往前一级是学科分段。
  final before =
      path.length >= 2 ? path.sublist(0, path.length - 1) : const <KnowledgePoint>[];
  final chapter = before.isNotEmpty ? before.last.name : null;
  final section = before.length >= 2 ? before[before.length - 2].name : null;
  return (section: section, chapter: chapter);
}

/// 小节标题：`标题 ────────`。
///
/// 细线不是装饰 —— 它把"标题"和"内容"在视觉上分开，卡片长了以后
/// 一眼能看出这一段的边界在哪。
class _SectionTitle extends StatelessWidget {
  final String text;
  final int? count;

  const _SectionTitle(this.text, {this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 13, bottom: 7),
      child: Row(
        children: [
          Text(
            text,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppColors.ink3,
              letterSpacing: 0.6,
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 5),
            Text(
              '$count 条',
              style: const TextStyle(fontSize: 10.5, color: AppColors.ink4),
            ),
          ],
          const SizedBox(width: 8),
          const Expanded(child: Divider(height: 1, thickness: 1)),
        ],
      ),
    );
  }
}

/// 陷阱一条。
class _TrapItem extends StatelessWidget {
  final int index;
  final String text;

  const _TrapItem({required this.index, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.warning_amber_rounded,
                size: 13, color: AppColors.warning),
          ),
          const SizedBox(width: 5),
          SizedBox(
            width: 15,
            child: Text(
              '$index.',
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: AppColors.warningInk,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            child: Text(
              text.replaceAll('★ ', ''),
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.65,
                color: AppColors.warningInk,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一个字段：标签列定宽，值左对齐 —— 多个字段叠起来就是一张对齐的表。
class _FactRow extends StatelessWidget {
  final String label;
  final String value;

  const _FactRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 40,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11.5, color: AppColors.ink3),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: AppColors.ink2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WeightPill extends StatelessWidget {
  final double weight;
  const _WeightPill({required this.weight});

  @override
  Widget build(BuildContext context) {
    final color = weight >= 0.85
        ? AppColors.danger
        : weight >= 0.6
            ? AppColors.warning
            : AppColors.ink3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '考频 ${weight.toStringAsFixed(2)}',
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _AliasChip extends StatelessWidget {
  final String text;
  const _AliasChip({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 10.5, color: AppColors.ink2),
      ),
    );
  }
}
