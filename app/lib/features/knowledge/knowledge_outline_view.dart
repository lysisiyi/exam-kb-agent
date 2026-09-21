/// 知识点大纲视图：常规的**顺序目录**（教材那种）。
///
/// ## 与图谱的分工
///
/// 图谱回答"这一科长什么样"，大纲回答"第几章第几节讲了什么"。
/// 大纲按 id 顺序（= 考纲书写顺序）逐行列出，带层级编号（`2.3.1`），
/// 可以逐级展开、点开某个考点的定义与公式。
///
/// 行是**扁平化之后交给 `ListView.builder`** 的：展开 141 个叶子时会有
/// 三百多行，必须懒构建。所以这里不用嵌套 ExpansionTile，而是自己维护
/// "哪些节点展开了"，每次重建只算一遍可见行。
library;

import 'package:flutter/material.dart';

import '../../core/theme/app_fonts.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/knowledge/knowledge_point.dart';
import 'knowledge_graph_layout.dart' show graphKindOf;
import 'knowledge_leaf_detail.dart';
import 'knowledge_node_style.dart';
import 'knowledge_sizes.dart';

/// 大纲视图。
class KnowledgeOutlineView extends StatefulWidget {
  final KnowledgeBase kb;
  const KnowledgeOutlineView({super.key, required this.kb});

  @override
  State<KnowledgeOutlineView> createState() => _KnowledgeOutlineViewState();
}

class _KnowledgeOutlineViewState extends State<KnowledgeOutlineView> {
  /// 展开了的分支节点 id。
  late Set<String> _expanded;

  /// 展开了详情的叶子 id。
  String? _openLeaf;

  @override
  void initState() {
    super.initState();
    _expanded = _defaultExpanded(widget.kb);
  }

  @override
  void didUpdateWidget(KnowledgeOutlineView old) {
    super.didUpdateWidget(old);
    if (!identical(old.kb, widget.kb)) {
      _expanded = _defaultExpanded(widget.kb);
      _openLeaf = null;
    }
  }

  /// 默认展开到**章节**一级：一打开就是一份能读完的目录（数一 19 行），
  /// 而不是 141 个叶子糊一屏。
  ///
  /// 所以展开的是「分段」及更上层（`idDepth <= 2`）—— 章节名作为行出现，
  /// 它们下面的叶子收起。
  Set<String> _defaultExpanded(KnowledgeBase kb) => {
        for (final n in kb.nodes)
          if (!n.isLeaf && n.idDepth <= 2) n.id,
      };

  void _toggle(String id) {
    setState(() {
      if (_expanded.contains(id)) {
        _expanded.remove(id);
      } else {
        _expanded.add(id);
      }
    });
  }

  void _expandAll() => setState(() {
        _expanded = {for (final n in widget.kb.nodes) if (!n.isLeaf) n.id};
      });

  void _collapseAll() => setState(() {
        // 起点（科目根）必须留在展开集合里，否则整棵树会塌成一行 ——
        // "收起到分段"意思是收起叶子，不是把目录整个关掉
        _expanded = {
          for (final n in [
            ...widget.kb.traversalRoots,
            ...widget.kb.topLevel,
          ])
            n.id,
        };
        _openLeaf = null;
      });
  @override
  Widget build(BuildContext context) {
    final kb = widget.kb;
    final rows = _flatten(kb);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _OutlineHeader(
          kb: kb,
          expandedCount: _expanded.length,
          onExpandAll: _expandAll,
          onCollapseAll: _collapseAll,
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 6, 12, 24),
            itemCount: rows.length,
            itemBuilder: (ctx, i) {
              final r = rows[i];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _OutlineRowTile(
                    // key 挂在**行**上（不是外层 Column）：测试要按 key 点击
                    // 这一行，而 Column 还包着展开的详情，中心点会落在详情里
                    key: ValueKey('outline-row-${r.node.id}'),
                    row: r,
                    expanded: _expanded.contains(r.node.id),
                    open: _openLeaf == r.node.id,
                    onTap: () {
                      if (r.node.isLeaf) {
                        setState(() => _openLeaf =
                            _openLeaf == r.node.id ? null : r.node.id);
                      } else {
                        _toggle(r.node.id);
                      }
                    },
                  ),
                  if (r.node.isLeaf && _openLeaf == r.node.id)
                    Padding(
                      padding: EdgeInsets.only(
                        left: _indent(r.depth) + 22,
                        right: 4,
                        bottom: 8,
                      ),
                      child: KnowledgeLeafDetail(
                        key: ValueKey('outline-detail-${r.node.id}'),
                        leaf: r.node,
                        sectionName: detailBreadcrumb(kb, r.node.id).section,
                        chapterName: detailBreadcrumb(kb, r.node.id).chapter,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  List<_OutlineRow> _flatten(KnowledgeBase kb) {
    final out = <_OutlineRow>[];

    void walk(KnowledgePoint node, int depth, String number) {
      final kids = node.isLeaf
          ? const <KnowledgePoint>[]
          : (kb.childrenOf[node.id] ?? const <KnowledgePoint>[]);
      final expanded = _expanded.contains(node.id) || _openLeaf == node.id;

      out.add(_OutlineRow(
        node: node,
        depth: depth,
        number: number,
        childCount: kids.length,
        leafCount: node.isLeaf ? 0 : kb.leafIdsUnder(node.id).length,
        expanded: expanded,
      ));

      if (!expanded) return;
      for (var i = 0; i < kids.length; i++) {
        // 父节点没编号（科目根）时，子节点自己从 1 开始编
        final childNo = number.isEmpty ? '${i + 1}' : '$number.${i + 1}';
        walk(kids[i], depth + 1, childNo);
      }
    }

    final starts = kb.traversalRoots;
    for (var i = 0; i < starts.length; i++) {
      final s = starts[i];
      // 科目根这一行不编号：教材里不会写"第 1 章 高等数学"再往下分"1.1"，
      // 编号从顶层之下开始（分段 = 1 / 2，章节 = 1.1 …）。
      walk(s, s.idDepth, s.id == kb.subject ? '' : '${i + 1}');
    }
    return out;
  }
}

double _indent(int depth) => (depth - 1) * 17.0;

class _OutlineRow {
  final KnowledgePoint node;
  final int depth;
  final String number;
  final int childCount;
  final int leafCount;
  final bool expanded;

  const _OutlineRow({
    required this.node,
    required this.depth,
    required this.number,
    required this.childCount,
    required this.leafCount,
    required this.expanded,
  });
}

class _OutlineRowTile extends StatelessWidget {
  final _OutlineRow row;
  final bool expanded;
  final bool open;
  final VoidCallback onTap;

  const _OutlineRowTile({
    super.key,
    required this.row,
    required this.expanded,
    required this.open,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final node = row.node;
    final kind = graphKindOf(node);
    // 名字/编号/圆点全部走**与图谱同一份**语义色板 —— 见 knowledge_node_style.dart
    final theme = nodeThemeOf(kind);
    final isBranch = !node.isLeaf;

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.rSm,
        child: Padding(
          padding: EdgeInsets.fromLTRB(_indent(row.depth), 0, 4, 0),
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              borderRadius: AppRadius.rSm,
              color: open && node.isLeaf ? AppColors.primaryWeak : null,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  child: isBranch
                      ? Icon(
                          expanded
                              ? Icons.keyboard_arrow_down
                              : Icons.keyboard_arrow_right,
                          size: 18,
                          color: kSecondaryInk,
                        )
                      : Icon(Icons.circle, size: 5, color: theme.accent),
                ),
                const SizedBox(width: 4),
                // 层级编号：教材里"第几章第几节"的那种，方便口头引用
                // ⚠️ 叶子编号早先用 ink3（3.2:1，低于 AA），现在与名字同档
                SizedBox(
                  width: 58,
                  child: Text(
                    row.number,
                    style: TextStyle(
                      fontSize: KnowledgeSizes.secondary,
                      fontWeight: FontWeight.w700,
                      color: theme.accent,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    node.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // 名字色**与图谱节点同源**（theme.textInk）：同一个叶子
                    // 在两个视图里深浅一致，层级靠字重 + accent 表达
                    //
                    // 字号也**与图谱同源**（`KnowledgeSizes.title`）：同一个
                    // 叶子在两个视图里大小一致。层级同样不靠字号表达 ——
                    // 靠字重（分支 w700 / 叶子 w400）。
                    style: TextStyle(
                      fontSize: KnowledgeSizes.title,
                      fontWeight: isBranch ? FontWeight.w700 : FontWeight.w400,
                      color: theme.textInk,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (isBranch)
                  Text(
                    row.childCount == 0 ? '空' : '${row.leafCount} 个考点',
                    style: const TextStyle(
                        fontSize: KnowledgeSizes.secondary,
                        color: kSecondaryInk),
                  )
                else
                  Text(
                    node.examYears.isEmpty
                        ? '暂无考频'
                        : '考过 ${node.examYears.length} 次',
                    style: const TextStyle(
                        fontSize: KnowledgeSizes.secondary,
                        color: kSecondaryInk),
                  ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 46,
                  child: node.examWeight == null
                      ? const SizedBox.shrink()
                      : Text(
                          node.examWeight!.toStringAsFixed(2),
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: KnowledgeSizes.secondary,
                            fontWeight: FontWeight.w700,
                            color: weightInk(node.examWeight),
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶部：题数概览 + 高频考点 + 展开/折叠。
class _OutlineHeader extends StatelessWidget {
  final KnowledgeBase kb;
  final int expandedCount;
  final VoidCallback onExpandAll;
  final VoidCallback onCollapseAll;

  const _OutlineHeader({
    required this.kb,
    required this.expandedCount,
    required this.onExpandAll,
    required this.onCollapseAll,
  });

  @override
  Widget build(BuildContext context) {
    final top = kb.leavesByWeight(limit: 10);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '${kb.chapters.length} 章 · ${kb.leaves.length} 个知识点',
                style: AppTypography.bodyStrong,
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: onExpandAll,
                icon: const Icon(Icons.unfold_more, size: 16),
                label: const Text('全部展开'),
              ),
              const SizedBox(width: 4),
              TextButton.icon(
                onPressed: onCollapseAll,
                icon: const Icon(Icons.unfold_less, size: 16),
                label: const Text('收起到分段'),
              ),
            ],
          ),
          if (top.isNotEmpty) ...[
            const SizedBox(height: 2),
            // caption 默认 ink3（白底 3.2:1，低于 AA）—— 这句是要读的说明
            const Text('高频考点 Top 10（按考频权重）',
                style: TextStyle(
                    fontSize: KnowledgeSizes.secondary, color: kSecondaryInk)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [for (final kp in top) _WeightChip(kp: kp)],
            ),
          ],
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

    return Tooltip(
      message: '${kp.name}\n${kp.id}',
      child: Container(
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
                fontSize: KnowledgeSizes.secondary,
                fontWeight: AppFonts.bold,
                color: color,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              w.toStringAsFixed(2),
              style: TextStyle(
                fontSize: KnowledgeSizes.secondary,
                fontWeight: FontWeight.w700,
                color: color.withValues(alpha: 0.75),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
