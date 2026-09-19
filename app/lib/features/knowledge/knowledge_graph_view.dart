/// 知识点图谱视图：可缩放、可拖动的树形目录。
///
/// ## 交互（用户要的就是这两件事）
///
/// | 操作 | 效果 |
/// |---|---|
/// | 鼠标滚轮 | 缩放（以光标位置为焦点） |
/// | 按住拖动 | 平移画布 |
/// | 点击节点 | 选中：高亮它到根的整条路径，下方显示详情 |
///
/// 滚轮缩放与拖动平移都由 [InteractiveViewer] 提供（它在桌面端把
/// `PointerScrollEvent` 换算成 `exp(-dy / scaleFactor)` 的缩放，
/// 触控板滚动则当平移 —— 正好是 PC 上的习惯用法）。这里的活是：
/// 量文字宽度、算坐标、画连线、画节点、给"适应宽度/看全整树"按钮。
///
/// ## 为什么节点用 widget 而不是 CustomPainter 画
///
/// 一张图里有两三百个节点。用 `CustomPainter` 画文字要自己为每个节点
/// 建 `TextPainter` 并处理命中测试；用 `Positioned` + 普通 widget 则
/// 文字、省略号、悬停提示、点击都是现成的。整棵树只有几百个节点，
/// 这个量级 widget 方案完全撑得住。
library;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../domain/knowledge/knowledge_point.dart';
import 'knowledge_graph_layout.dart';
import 'knowledge_leaf_detail.dart';
import 'knowledge_node_style.dart';

/// 图谱视图。
class KnowledgeGraphView extends StatefulWidget {
  final KnowledgeBase kb;

  const KnowledgeGraphView({super.key, required this.kb});

  @override
  State<KnowledgeGraphView> createState() => _KnowledgeGraphViewState();
}

class _KnowledgeGraphViewState extends State<KnowledgeGraphView> {
  static const double _minScale = 0.05;
  static const double _maxScale = 2.0;

  final TransformationController _tc = TransformationController();
  final Map<String, double> _measureCache = {};

  /// 布局参数（字号、行高、内边距）。做成字段是为了将来能加"紧凑/宽松"档。
  static const GraphStyle _style = GraphStyle();

  KnowledgeGraph? _graph;
  KnowledgeBase? _graphFor;

  String? _selectedId;
  Size _viewport = Size.zero;
  bool _fittedOnce = false;

  @override
  void didUpdateWidget(KnowledgeGraphView old) {
    super.didUpdateWidget(old);
    if (!identical(old.kb, widget.kb)) {
      _graph = null;
      _graphFor = null;
      _measureCache.clear();
      _selectedId = null;
      _fittedOnce = false;
    }
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  /// 量一段标题的宽度（按当前字号）。结果缓存 —— 同一层里同名节点不多，
  /// 但整棵树有几百个节点，重复量同一串不划算。
  double _measure(String text) {
    final hit = _measureCache[text];
    if (hit != null) return hit;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: _style.fontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final w = tp.width;
    tp.dispose();
    _measureCache[text] = w;
    return w;
  }

  KnowledgeGraph _ensureGraph() {
    final cached = _graph;
    if (cached != null && identical(_graphFor, widget.kb)) return cached;
    _measureCache.clear();
    final g = buildKnowledgeGraph(
      widget.kb,
      measure: _measure,
      style: _style,
    );
    _graph = g;
    _graphFor = widget.kb;
    return g;
  }

  // ── 视图变换 ─────────────────────────────────────────────────────────────

  /// 把整棵树缩放到"宽度刚好放得下"—— 打开图谱时的默认视图。
  ///
  /// 为什么不默认"看全整树"：数一有 141 个叶子，纵向四千多像素，
  /// 看全之后字小到读不出来。默认适应宽度、纵向靠拖动浏览更实用。
  void _fitWidth(KnowledgeGraph g) {
    if (_viewport.width <= 0) return;
    final scale = ((_viewport.width - 32) / g.size.width)
        .clamp(_minScale, 1.0)
        .toDouble();
    _tc.value = Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(0, 3, 16)
      ..setEntry(1, 3, 8);
  }

  /// 看全整树（宽高都比一遍）。
  void _fitAll(KnowledgeGraph g) {
    if (_viewport.width <= 0) return;
    final sx = (_viewport.width - 32) / g.size.width;
    final sy = (_viewport.height - 32) / g.size.height;
    final scale = (sx < sy ? sx : sy).clamp(_minScale, 1.0).toDouble();
    final tx = (_viewport.width - g.size.width * scale) / 2;
    final ty = (_viewport.height - g.size.height * scale) / 2;
    _tc.value = Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(0, 3, tx)
      ..setEntry(1, 3, ty);
  }

  /// 以视口中心为焦点缩放 [factor] 倍。
  void _zoomBy(double factor) {
    if (_viewport.width <= 0) return;
    final m = _tc.value;
    final cur = m.getMaxScaleOnAxis();
    final next = (cur * factor).clamp(_minScale, _maxScale).toDouble();
    if ((next - cur).abs() < 1e-6) return;

    // 视口中心当前对应的**画布坐标**，缩放后让它仍落在视口中心
    final center = Offset(_viewport.width / 2, _viewport.height / 2);
    final scene = _tc.toScene(center);
    _tc.value = Matrix4.identity()
      ..setEntry(0, 0, next)
      ..setEntry(1, 1, next)
      ..setEntry(0, 3, center.dx - scene.dx * next)
      ..setEntry(1, 3, center.dy - scene.dy * next);
  }

  void _select(GraphNode? n) {
    setState(() => _selectedId = n?.id);
  }

  @override
  Widget build(BuildContext context) {
    final g = _ensureGraph();

    return LayoutBuilder(
      builder: (ctx, c) {
        _viewport = Size(c.maxWidth, c.maxHeight);
        if (!_fittedOnce && c.maxWidth > 0) {
          _fittedOnce = true;
          // 首帧之后再动 controller（build 里改状态会被框架断言拦下）
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _fitWidth(g);
          });
        }

        final selected = _selectedId == null ? null : g.nodeOf(_selectedId!);
        final Set<int> path = _selectedId == null
            ? const <int>{}
            : g.pathTo(_selectedId!).toSet();

        return Stack(
          children: [
            Positioned.fill(
              child: ClipRect(
                child: InteractiveViewer(
                  transformationController: _tc,
                  minScale: _minScale,
                  maxScale: _maxScale,
                  // 缩到很小时也要能在四周拖一点，否则边缘节点够不着
                  boundaryMargin: const EdgeInsets.all(600),
                  constrained: false,
                  child: SizedBox(
                    width: g.size.width,
                    height: g.size.height,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // 连线画在节点下面
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _EdgePainter(
                              graph: g,
                              highlighted: path,
                              dimOthers: _selectedId != null,
                            ),
                          ),
                        ),
                        for (final n in g.nodes)
                          Positioned.fromRect(
                            rect: n.rect,
                            child: _GraphNodeCard(
                              // 稳定的 key：测试与"定位到某个节点"都用它
                              key: ValueKey('graph-node-${n.id}'),
                              node: n,
                              selected: n.id == _selectedId,
                              dimmed: _selectedId != null &&
                                  !path.contains(g.indexById[n.id] ?? -1),
                              onTap: () => _select(n),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 图例与操作栏放在**同一行**：各自 Positioned(left/right) 的话，
            // 窄窗口上两者会叠在一起（560px 宽时它们加起来刚好超过一屏）
            Positioned(
              left: 12,
              right: 12,
              top: 12,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Flexible(child: _Legend()),
                  const Spacer(),
                  const SizedBox(width: 8),
                  _Toolbar(
                    controller: _tc,
                    onZoomIn: () => _zoomBy(1.25),
                    onZoomOut: () => _zoomBy(1 / 1.25),
                    onFitWidth: () => _fitWidth(g),
                    onFitAll: () => _fitAll(g),
                  ),
                ],
              ),
            ),
            if (selected != null)
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: _SelectionPanel(
                  kb: widget.kb,
                  node: selected,
                  graph: g,
                  onClose: () => _select(null),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 操作栏
// ─────────────────────────────────────────────────────────────────────────────

class _Toolbar extends StatelessWidget {
  final TransformationController controller;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFitWidth;
  final VoidCallback onFitAll;

  const _Toolbar({
    required this.controller,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFitWidth,
    required this.onFitAll,
  });

  @override
  Widget build(BuildContext context) {
    return _Glass(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 百分比跟着变换走：只重建这一小块，不重建几百个节点
          ValueListenableBuilder<Matrix4>(
            valueListenable: controller,
            builder: (ctx, m, _) => SizedBox(
              width: 52,
              child: Text(
                '${(m.getMaxScaleOnAxis() * 100).round()}%',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.ink2,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          _ToolButton(
            icon: Icons.remove,
            tooltip: '缩小（也可以用滚轮）',
            onPressed: onZoomOut,
          ),
          _ToolButton(
            icon: Icons.add,
            tooltip: '放大（也可以用滚轮）',
            onPressed: onZoomIn,
          ),
          const _ToolDivider(),
          _ToolButton(
            icon: Icons.width_normal,
            tooltip: '适应宽度',
            onPressed: onFitWidth,
          ),
          _ToolButton(
            icon: Icons.fit_screen_outlined,
            tooltip: '看全整树',
            onPressed: onFitAll,
          ),
          const _ToolDivider(),
          if (_showHints(context))
            const Padding(
              padding: EdgeInsets.only(right: 10, left: 2),
              child: Text(
                '滚轮缩放 · 拖动平移',
                style: TextStyle(fontSize: 11, color: AppColors.ink3),
              ),
            ),
        ],
      ),
    );
  }
}

/// 窄窗口上这段提示会把图例挤没，所以只在宽屏显示（按钮本身有 tooltip）。
bool _showHints(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= 900;

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _ToolButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(7),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 17, color: AppColors.ink2),
        ),
      ),
    );
  }
}

class _ToolDivider extends StatelessWidget {
  const _ToolDivider();

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 18,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: AppColors.line,
      );
}

/// 半透明小面板（操作栏 / 图例共用）。
class _Glass extends StatelessWidget {
  final Widget child;
  const _Glass({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.94),
        borderRadius: AppRadius.rMd,
        border: Border.all(color: AppColors.line),
        boxShadow: AppShadows.s1,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: child,
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    return _Glass(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        child: Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            for (final k in const [
              GraphNodeKind.root,
              GraphNodeKind.section,
              GraphNodeKind.chapter,
              GraphNodeKind.unit,
              GraphNodeKind.leaf,
            ])
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: nodeFill(k),
                      borderRadius: BorderRadius.circular(2.5),
                      border: Border.all(color: nodeBorder(k)),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    nodeKindLabel(k),
                    style: const TextStyle(fontSize: 11, color: AppColors.ink2),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 节点外观见 `knowledge_node_style.dart`（与大纲视图共用一份配色）
// ─────────────────────────────────────────────────────────────────────────────

class _GraphNodeCard extends StatelessWidget {
  final GraphNode node;
  final bool selected;
  final bool dimmed;
  final VoidCallback onTap;

  const _GraphNodeCard({
    super.key,
    required this.node,
    required this.selected,
    required this.dimmed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final kind = node.kind;
    final ink = nodeInk(kind);
    final w = node.point.examWeight;

    return Opacity(
      opacity: dimmed ? 0.35 : 1,
      child: Material(
        type: MaterialType.transparency,
        child: Tooltip(
          message: '${node.point.name}\n${node.point.id}',
          waitDuration: const Duration(milliseconds: 600),
          child: InkWell(
            onTap: onTap,
            borderRadius: AppRadius.rSm,
            child: Container(
              decoration: BoxDecoration(
                color: nodeFill(kind),
                borderRadius: AppRadius.rSm,
                border: Border.all(
                  color: selected ? AppColors.warning : nodeBorder(kind),
                  width: selected ? 2 : 1,
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 9),
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      node.point.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: kind == GraphNodeKind.leaf
                            ? FontWeight.w500
                            : FontWeight.w700,
                        color: ink,
                      ),
                    ),
                  ),
                  if (kind == GraphNodeKind.leaf && w != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      w.toStringAsFixed(2),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: w >= 0.85
                            ? AppColors.danger
                            : w >= 0.6
                                ? AppColors.warningInk
                                : AppColors.ink3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 连线
// ─────────────────────────────────────────────────────────────────────────────

class _EdgePainter extends CustomPainter {
  final KnowledgeGraph graph;
  final Set<int> highlighted;
  final bool dimOthers;

  const _EdgePainter({
    required this.graph,
    required this.highlighted,
    required this.dimOthers,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final normal = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..color = AppColors.ink4.withValues(alpha: dimOthers ? 0.35 : 0.75);
    final hot = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = AppColors.warning;

    for (final e in graph.edges) {
      final p = graph.nodes[e.parent];
      final c = graph.nodes[e.child];
      // 从父节点右边缘到子节点左边缘，走一段三次贝塞尔（像树一样张开）
      final a = Offset(p.rect.right, p.centerY);
      final b = Offset(c.rect.left, c.centerY);
      final dx = (b.dx - a.dx) * 0.45;
      final path = Path()
        ..moveTo(a.dx, a.dy)
        ..cubicTo(a.dx + dx, a.dy, b.dx - dx, b.dy, b.dx, b.dy);
      final onPath = highlighted.contains(e.parent) && highlighted.contains(e.child);
      canvas.drawPath(path, onPath && dimOthers ? hot : normal);
    }
  }

  @override
  bool shouldRepaint(_EdgePainter old) =>
      !identical(old.graph, graph) ||
      old.dimOthers != dimOthers ||
      old.highlighted.length != highlighted.length ||
      !old.highlighted.containsAll(highlighted);
}

// ─────────────────────────────────────────────────────────────────────────────
// 选中详情
// ─────────────────────────────────────────────────────────────────────────────

class _SelectionPanel extends StatelessWidget {
  final KnowledgeBase kb;
  final GraphNode node;
  final KnowledgeGraph graph;
  final VoidCallback onClose;

  const _SelectionPanel({
    required this.kb,
    required this.node,
    required this.graph,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final leafCount = kb.leafCountUnder(node.id);
    final crumbs = kb
        .pathTo(node.id)
        .where((n) => n.id != node.id)
        .map((n) => n.name)
        .join(' › ');

    return Material(
      type: MaterialType.transparency,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 260),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.97),
          borderRadius: AppRadius.rLg,
          border: Border.all(color: AppColors.line),
          boxShadow: AppShadows.s2,
        ),
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(_kindIcon(node.kind), size: 15, color: AppColors.primaryStrong),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    node.point.name,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                ),
                if (crumbs.isNotEmpty)
                  Flexible(
                    child: Text(
                      crumbs,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: AppTypography.caption,
                    ),
                  ),
                IconButton(
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 17),
                  tooltip: '关闭',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Flexible(
              child: SingleChildScrollView(
                child: node.kind == GraphNodeKind.leaf
                    ? KnowledgeLeafDetail(
                        leaf: node.point,
                        chapterName: kb.byId[node.point.chapterId]?.name,
                      )
                    : _BranchSummary(
                        kb: kb,
                        node: node,
                        leafCount: leafCount,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

IconData _kindIcon(GraphNodeKind k) => switch (k) {
      GraphNodeKind.root => Icons.account_tree_outlined,
      GraphNodeKind.section => Icons.folder_outlined,
      GraphNodeKind.chapter => Icons.topic_outlined,
      GraphNodeKind.unit => Icons.subdirectory_arrow_right,
      GraphNodeKind.leaf => Icons.circle_outlined,
    };

/// 分支节点的摘要：挂了多少考点、考频、下面有哪些子节点。
class _BranchSummary extends StatelessWidget {
  final KnowledgeBase kb;
  final GraphNode node;
  final int leafCount;

  const _BranchSummary({
    required this.kb,
    required this.node,
    required this.leafCount,
  });

  @override
  Widget build(BuildContext context) {
    final kids = kb.childrenOf[node.id] ?? const <KnowledgePoint>[];
    final w = node.point.examWeight;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 14,
          runSpacing: 4,
          children: [
            Text('$leafCount 个知识点',
                style: const TextStyle(fontSize: 11.5, color: AppColors.ink2)),
            if (kids.isNotEmpty)
              Text('${kids.length} 个下级',
                  style: const TextStyle(fontSize: 11.5, color: AppColors.ink2)),
            if (w != null)
              Text('考频 ${w.toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 11.5, color: AppColors.ink2)),
            Text(node.point.id, style: AppTypography.mono),
          ],
        ),
        if (kids.isNotEmpty) ...[
          const SizedBox(height: 9),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final k in kids)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.bg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.line),
                  ),
                  child: Text(
                    '${k.name}${k.isLeaf ? '' : ' (${kb.leafCountUnder(k.id)})'}',
                    style: const TextStyle(fontSize: 11, color: AppColors.ink2),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
