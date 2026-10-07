/// 知识点树（V3 两栏编辑器的**左栏**，对齐 docs/design/ui/ui_knowledge.png）。
///
/// 只有树本身：展开/收起、状态点（已填/骨架）、优先级星、拖拽把手、
/// 选中高亮；**详情一律走 `onSelect` 交给右栏**——旧版把详情内联展开在
/// 行下方（"点叶子就地铺一屏"），参考图是"左树右详情"两栏，已重构掉。
///
/// 行是**扁平化之后交给 `ListView.builder`** 的：展开数百叶子时会有
/// 三百多行，必须懒构建。
library;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../domain/knowledge/knowledge_point.dart';
import '../../services/profile/mastery_service.dart';
import 'knowledge_graph_layout.dart' show graphKindOf;
import 'knowledge_node_style.dart';
import 'knowledge_sizes.dart';

/// 大纲视图。
class KnowledgeOutlineView extends StatefulWidget {
  final KnowledgeBase kb;

  /// 错题数（kpId → KpMastery）。叶子行用它的 problemCount 显示"N 题"
  /// 徽标；报告没就绪时传空表，徽标整体不出现（与图谱同一口径）。
  final Map<String, KpMastery> masteryByKpId;

  /// 点行回调（两栏编辑器：左树右详情）。分支行点击 = 选中 + 展开切换。
  final ValueChanged<KnowledgePoint>? onSelect;

  /// 当前选中的节点 id（该行高亮）。
  final String? selectedId;

  /// 编辑动作（K2）：新建子节点 / 重命名 / 删除。null = 菜单不出现。
  final void Function(KnowledgePoint parent)? onCreateChild;
  final void Function(KnowledgePoint node)? onRename;
  final void Function(KnowledgePoint node)? onDelete;

  const KnowledgeOutlineView({
    super.key,
    required this.kb,
    this.masteryByKpId = const {},
    this.onSelect,
    this.selectedId,
    this.onCreateChild,
    this.onRename,
    this.onDelete,
  });

  @override
  State<KnowledgeOutlineView> createState() => _KnowledgeOutlineViewState();
}

class _KnowledgeOutlineViewState extends State<KnowledgeOutlineView> {
  /// 展开了的分支节点 id。
  late Set<String> _expanded;

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
              return _OutlineRowTile(
                key: ValueKey('outline-row-${r.node.id}'),
                row: r,
                expanded: _expanded.contains(r.node.id),
                selected: widget.selectedId == r.node.id,
                problemCount:
                    widget.masteryByKpId[r.node.id]?.problemCount ?? 0,
                onCreateChild: widget.onCreateChild == null
                    ? null
                    : () => widget.onCreateChild!(r.node),
                onRename: widget.onRename == null
                    ? null
                    : () => widget.onRename!(r.node),
                onDelete: widget.onDelete == null
                    ? null
                    : () => widget.onDelete!(r.node),
                onTap: () {
                  widget.onSelect?.call(r.node);
                  if (!r.node.isLeaf) _toggle(r.node.id);
                },
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
      final expanded = _expanded.contains(node.id);

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
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onCreateChild;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

    /// 该考点的错题数（0 = 没有题，徽标不显示）。
  final int problemCount;

  const _OutlineRowTile({
    super.key,
    required this.row,
    required this.expanded,
    required this.selected,
    required this.problemCount,
    required this.onTap,
    this.onCreateChild,
    this.onRename,
    this.onDelete,
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
              // 选中行高亮（参考图里被点中的行是暖色底）
              color: selected ? AppColors.primaryWeak : null,
            ),
            // 窄树（<300px 可用宽）时折叠星级/meta/权重三列：固定列 + 缩进
            // 已占满，硬摆必溢出。桌面宽（参考图场景）照常全显。
            child: LayoutBuilder(builder: (context, cons) {
              final wide = cons.maxWidth >= 300;
              return Row(
              children: [
                // 拖拽把手（参考图的 ⋮⋮）。K2 编辑器接线前只是视觉占位，
                // tooltip 如实说明。
                const Tooltip(
                  message: '拖拽整理（随 K2 编辑器接线）',
                  child: Icon(Icons.drag_indicator,
                      size: 13, color: AppColors.ink4),
                ),
                const SizedBox(width: 2),
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
                      // 手账风状态点（对齐参考图的四色点）：有定义=实心绿（已填）、
                      // 没有=空心灰（骨架）。与页头「骨架/已填」chips 同一口径
                      // （definition 是否为空），扫树即可看出哪些还没填。
                      : Center(
                          child: Container(
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _isFilled(node)
                                  ? AppColors.success
                                  : null,
                              border: _isFilled(node)
                                  ? null
                                  : Border.all(
                                      color: AppColors.ink4, width: 1.5),
                            ),
                          ),
                        ),
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
                // 优先级星（参考图叶子行 "★★"）—— 只在有考频数据时出现
                if (wide && starsOf(node.examWeight).isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(starsOf(node.examWeight),
                      style: const TextStyle(
                          fontSize: 9.5, color: AppColors.warning)),
                ],
                if (wide) const SizedBox(width: 8),
                // 说明文字必须可压缩（Flexible+ellipsis）：左树固定 430
                // （窄窗 45%），行内固定列已占 ~180px，自然宽的文本会溢出。
                if (!wide) const SizedBox.shrink() else if (isBranch)
                  Flexible(
                    child: Text(
                      row.childCount == 0 ? '空' : '${row.leafCount} 个考点',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: KnowledgeSizes.secondary,
                          color: kSecondaryInk),
                    ),
                  )
                else
                  Flexible(
                    child: Text(
                      // 错题数与考频并列：一个说"这个考点多重要"，
                      // 一个说"你在这里攒了多少题"。没有题时不显示 ——
                      // "0 题"和"还没录过"是两个意思（与画像的空槽同一口径）。
                      _leafMetaText(node, problemCount),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: KnowledgeSizes.secondary,
                          color: kSecondaryInk),
                    ),
                  ),
                if (wide) const SizedBox(width: 6),
                if (wide)
                SizedBox(
                  width: 40,
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
                if (onCreateChild != null ||
                    onRename != null ||
                    onDelete != null)
                  SizedBox(
                    width: 26,
                    child: PopupMenuButton<String>(
                      tooltip: '编辑节点',
                      padding: EdgeInsets.zero,
                      iconSize: 15,
                      icon: const Icon(Icons.more_horiz, color: AppColors.ink3),
                      onSelected: (v) {
                        switch (v) {
                          case 'child':
                            onCreateChild?.call();
                          case 'rename':
                            onRename?.call();
                          case 'delete':
                            onDelete?.call();
                        }
                      },
                      itemBuilder: (_) => [
                        if (onCreateChild != null)
                          const PopupMenuItem(
                              value: 'child', child: Text('新建子节点')),
                        if (onRename != null)
                          const PopupMenuItem(
                              value: 'rename', child: Text('重命名')),
                        if (onDelete != null)
                          const PopupMenuItem(
                              value: 'delete', child: Text('删除')),
                      ],
                    ),
                  ),
              ],
              );
            }),
          ),
        ),
      ),
    );
  }
}

/// 树头（参考图第一行）："── 学科名（拖拽整理，id 不变）──" + 展开/收起。
///
/// 旧版这里是"题数概览 + 高频考点 Top 10 + 两个带字按钮" —— 参考图没有
/// Top10（页头 chips 已给数量），带字按钮在 430 定宽下会溢出，一并换成
/// 紧凑图标钮。
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '── ${kb.subjectName}（拖拽整理，id 不变）──',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: KnowledgeSizes.secondary,
                  color: kSecondaryInk,
                  letterSpacing: 0.4),
            ),
          ),
          IconButton(
            tooltip: '全部展开',
            onPressed: onExpandAll,
            icon: const Icon(Icons.unfold_more, size: 17),
            visualDensity: VisualDensity.compact,
            color: kSecondaryInk,
          ),
          IconButton(
            tooltip: '收起到分段',
            onPressed: onCollapseAll,
            icon: const Icon(Icons.unfold_less, size: 17),
            visualDensity: VisualDensity.compact,
            color: kSecondaryInk,
          ),
        ],
      ),
    );
  }
}


/// 这个叶子"填了没有"——有定义即已填（与页头 chips、md status 同口径）。
bool _isFilled(KnowledgePoint node) =>
    (node.definition ?? '').trim().isNotEmpty;

/// 叶子行的右侧说明：错题数与考频并列。没题时不显示"0 题"
/// （"0 题"与"还没录过"是两个意思——与画像的空槽同一口径）。
String _leafMetaText(KnowledgePoint node, int problemCount) {
  final parts = <String>[
    if (problemCount > 0) '$problemCount 题',
    if (node.examYears.isNotEmpty) '考过 ${node.examYears.length} 次',
  ];
  return parts.join(' · ');
}
