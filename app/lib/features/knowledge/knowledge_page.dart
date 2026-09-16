/// 知识库页面 —— V1 开发期的「地基验收页」。
///
/// 这一页的用途不是最终形态，而是**证明数据层真的跑通了**：
/// 知识点本体能载入、能按层级展开、考频权重能读出来。
///
/// M2 完成后，它会被真正的「知识点图谱」页面替换。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/breakpoints.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/state_views.dart';
import '../../domain/knowledge/knowledge_point.dart';

class KnowledgePage extends ConsumerWidget {
  const KnowledgePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kbAsync = ref.watch(knowledgeBaseProvider);

    return kbAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, st) => _ErrorView(error: e),
      data: (kb) => _LoadedView(kb: kb),
    );
  }
}

class _ErrorView extends ConsumerWidget {
  final Object error;
  const _ErrorView({required this.error});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 复用统一的错误态，但重试要**多做一步**：清掉 `KnowledgeRepository`
    // 的内部缓存。只 invalidate provider 不够 —— 单例仓库会把上次的失败
    // 结果一直留在 `_cache` 里，重试永远拿到同一个错误。
    return AppErrorView(
      title: '知识点本体载入失败',
      error: error,
      onRetry: () {
        ref.read(knowledgeRepositoryProvider).clear();
        ref.invalidate(knowledgeBaseProvider);
      },
      retryLabel: '重新载入',
    );
  }
}

class _LoadedView extends ConsumerWidget {
  final KnowledgeBase kb;
  const _LoadedView({required this.kb});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bp = BreakpointScope.of(context);
    final wide = bp.showTwoPane;

    final header = SliverToBoxAdapter(child: _Summary(kb: kb));
    final list = _ChapterList(kb: kb);

    return CustomScrollView(
      slivers: [
        header,
        if (wide)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            sliver: list,
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: list,
          ),
      ],
    );
  }
}

class _Summary extends StatelessWidget {
  final KnowledgeBase kb;
  const _Summary({required this.kb});

  @override
  Widget build(BuildContext context) {
    final stats = <({String label, String value})>[
      (label: '章节', value: '${kb.chapters.length}'),
      (label: '知识点', value: '${kb.leaves.length}'),
      (
        label: '含公式',
        value: '${kb.leaves.where((l) => l.formulas.isNotEmpty).length}'
      ),
      (
        label: '有考频数据',
        value: '${kb.leaves.where((l) => l.examYears.isNotEmpty).length}'
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(kb.subjectName, style: AppTypography.pageTitle),
          const SizedBox(height: 6),
          Text(
            '知识点本体 v${kb.version} · 这是 AI 标注的受控词表',
            style: AppTypography.caption,
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (ctx, c) {
              final cols = c.maxWidth > 720 ? 4 : 2;
              return GridView.count(
                crossAxisCount: cols,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 11,
                crossAxisSpacing: 11,
                childAspectRatio: 1.9,
                children: [
                  for (final s in stats) _StatTile(label: s.label, value: s.value),
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 14),
          const Text('高频考点 Top 10（按考频权重）',
              style: AppTypography.sectionTitle),
          const SizedBox(height: 10),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final kp in kb.leavesByWeight(limit: 10))
                _WeightChip(kp: kp),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  const _StatTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.rMd,
        boxShadow: AppShadows.s1,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w700,
              height: 1.1,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 5),
          Text(label, style: AppTypography.caption),
        ],
      ),
    );
  }
}

class _WeightChip extends StatelessWidget {
  final KnowledgePoint kp;
  const _WeightChip({required this.kp});

  @override
  Widget build(BuildContext context) {
    final w = kp.examWeight ?? 0;
    final color = w >= 0.85
        ? AppColors.danger
        : w >= 0.6
            ? AppColors.warning
            : AppColors.ink2;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            kp.name,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            w.toStringAsFixed(2),
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: color.withValues(alpha: 0.75),
            ),
          ),
        ],
      ),
    );
  }
}

/// 章节 → 知识点 的两级列表。
class _ChapterList extends StatelessWidget {
  final KnowledgeBase kb;
  const _ChapterList({required this.kb});

  @override
  Widget build(BuildContext context) {
    // 学科分段 → 章节
    final sections = kb.childrenOf[kb.subject] ?? const <KnowledgePoint>[];

    return SliverList.builder(
      itemCount: sections.length,
      itemBuilder: (ctx, i) => _SectionBlock(kb: kb, section: sections[i]),
    );
  }
}

class _SectionBlock extends StatelessWidget {
  final KnowledgeBase kb;
  final KnowledgePoint section;
  const _SectionBlock({required this.kb, required this.section});

  @override
  Widget build(BuildContext context) {
    final chapters = kb.childrenOf[section.id] ?? const <KnowledgePoint>[];
    final leafCount = chapters.fold<int>(
      0,
      (sum, c) => sum + kb.leafIdsUnder(c.id).length,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppRadius.rLg,
          boxShadow: AppShadows.s1,
        ),
        // ⚠️ 必须给 ExpansionTile 一个**自己的 Material 祖先**。
        //
        // ExpansionTile 内部就是 ListTile，而 ListTile 会把背景与水波纹
        // 画在"最近的 Material 祖先"上。这里的 Container 带白底，
        // 直接包着它就会让水波纹被压在下面 —— Flutter 会因此抛出断言：
        //
        //   ListTile background color or ink splashes may be invisible.
        //   The ListTile is wrapped in a DecoratedBox that has a background color.
        //
        // 断言抛出后整棵子树会被替换成错误框（真机上表现为"这块是空的"）。
        // `MaterialType.transparency` 不引入新底色，只是把 Material 祖先
        // 挪到 DecoratedBox 内层，于是水波纹画在白底之上、可见。
        child: Material(
          type: MaterialType.transparency,
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              initiallyExpanded: false,
              tilePadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              title: Text(section.name, style: AppTypography.sectionTitle),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  '${chapters.length} 章 · $leafCount 个知识点',
                  style: AppTypography.caption,
                ),
              ),
              children: [
                for (final ch in chapters) _ChapterBlock(kb: kb, chapter: ch),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChapterBlock extends StatelessWidget {
  final KnowledgeBase kb;
  final KnowledgePoint chapter;
  const _ChapterBlock({required this.kb, required this.chapter});

  @override
  Widget build(BuildContext context) {
    final leaves = (kb.childrenOf[chapter.id] ?? const <KnowledgePoint>[])
        .where((n) => n.isLeaf)
        .toList();

    // 同样需要自己的 Material 祖先：章节块嵌在学科分段的白色卡片里，
    // 而 ExpansionTile 内部是 ListTile（原因见 _SectionBlock 的注释）。
    return Material(
      type: MaterialType.transparency,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 8),
          childrenPadding: const EdgeInsets.only(left: 8, right: 4, bottom: 8),
          title: Text(
            chapter.name,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Row(
              children: [
                Text('${leaves.length} 个考点', style: AppTypography.caption),
                const SizedBox(width: 10),
                _WeightPill(weight: chapter.examWeight),
              ],
            ),
          ),
          children: [
            for (final leaf in leaves) _LeafTile(leaf: leaf),
          ],
        ),
      ),
    );
  }
}

class _WeightPill extends StatelessWidget {
  final double? weight;
  const _WeightPill({this.weight});

  @override
  Widget build(BuildContext context) {
    if (weight == null) return const SizedBox.shrink();
    final w = weight!;
    final color = w >= 0.85
        ? AppColors.danger
        : w >= 0.6
            ? AppColors.warning
            : AppColors.ink3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        '考频 ${w.toStringAsFixed(2)}',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _LeafTile extends StatelessWidget {
  final KnowledgePoint leaf;
  const _LeafTile({required this.leaf});

  @override
  Widget build(BuildContext context) {
    final qtypes = leaf.typicalQtypes.join(' · ');
    final years = leaf.examYears.isEmpty
        ? '暂无考频'
        : '考过 ${leaf.examYears.length} 次 · 最近 ${leaf.examYears.last}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.bg,
          borderRadius: AppRadius.rMd,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    leaf.name,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _WeightPill(weight: leaf.examWeight),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              [if (qtypes.isNotEmpty) qtypes, years].join(' · '),
              style: AppTypography.caption,
            ),
            if (leaf.definition != null) ...[
              const SizedBox(height: 8),
              Text(
                leaf.definition!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.7,
                  color: AppColors.ink2,
                ),
              ),
            ],
            if (leaf.commonTraps.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 13, color: AppColors.warning),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      leaf.commonTraps.first.replaceAll('★ ', ''),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        height: 1.6,
                        color: AppColors.warningInk,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
