/// 一个知识点的详情卡片。
///
/// 大纲视图（就地展开）与图谱视图（底部面板）共用同一份 ——
/// 两处各写一遍的话，同一个考点在两种视图里显示的信息迟早不一致。
library;

import 'package:flutter/material.dart';

import '../../core/math/math_renderer.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/knowledge/knowledge_point.dart';

/// 知识点详情：定义 / 核心公式 / 常见陷阱 / 考频 / 别名。
class KnowledgeLeafDetail extends StatelessWidget {
  final KnowledgePoint leaf;

  /// 所属章节名（列表里显示，避免用户忘了自己在看哪一章）。
  final String? chapterName;

  const KnowledgeLeafDetail({
    super.key,
    required this.leaf,
    this.chapterName,
  });

  @override
  Widget build(BuildContext context) {
    final renderer = MathRendering.renderer;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bg,
        borderRadius: AppRadius.rMd,
      ),
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  leaf.name,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                ),
              ),
              if (leaf.examWeight != null) _WeightPill(weight: leaf.examWeight!),
            ],
          ),
          if (chapterName != null) ...[
            const SizedBox(height: 3),
            Text(chapterName!, style: AppTypography.caption),
          ],
          if (leaf.definition != null && leaf.definition!.isNotEmpty) ...[
            const SizedBox(height: 9),
            renderer.renderMarkdown(
              leaf.definition!,
              options: const MathRenderOptions(fontSize: 12.5),
            ),
          ],
          if (leaf.formulas.isNotEmpty) ...[
            const SizedBox(height: 10),
            const _MiniLabel('核心公式'),
            const SizedBox(height: 5),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final f in leaf.formulas) _FormulaChip(latex: f),
              ],
            ),
          ],
          if (leaf.commonTraps.isNotEmpty) ...[
            const SizedBox(height: 10),
            const _MiniLabel('常见陷阱'),
            const SizedBox(height: 4),
            for (final t in leaf.commonTraps)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(Icons.warning_amber_rounded,
                          size: 13, color: AppColors.warning),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        t.replaceAll('★ ', ''),
                        style: const TextStyle(
                          fontSize: 11.5,
                          height: 1.6,
                          color: AppColors.warningInk,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              _Fact(
                label: '考频',
                value: leaf.examYears.isEmpty
                    ? '暂无数据'
                    : '近 ${leaf.examYears.length} 次考过',
              ),
              _Fact(
                label: '最近',
                value: leaf.examYears.isEmpty ? '—' : '${leaf.examYears.last} 年',
              ),
              _Fact(
                label: '题型',
                value: leaf.typicalQtypes.isEmpty
                    ? '—'
                    : leaf.typicalQtypes.map(_qtypeLabel).join(' / '),
              ),
            ],
          ),
          if (leaf.aliases.isNotEmpty) ...[
            const SizedBox(height: 10),
            const _MiniLabel('召回别名'),
            const SizedBox(height: 4),
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [
                for (final a in leaf.aliases.take(12))
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.surface2,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      a,
                      style: const TextStyle(fontSize: 10.5, color: AppColors.ink2),
                    ),
                  ),
              ],
            ),
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

class _MiniLabel extends StatelessWidget {
  final String text;
  const _MiniLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: AppColors.ink3,
          letterSpacing: 0.4,
        ),
      );
}

class _FormulaChip extends StatelessWidget {
  final String latex;
  const _FormulaChip({required this.latex});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.line),
      ),
      // 公式可能很长（\frac{\partial z}{\partial x}），窄屏上要能横向滚
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: MathRendering.renderer.render(latex, style: MathStyle.inline),
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

class _Fact extends StatelessWidget {
  final String label;
  final String value;
  const _Fact({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ',
            style: const TextStyle(fontSize: 11, color: AppColors.ink3)),
        Text(value,
            style: const TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.ink2)),
      ],
    );
  }
}
