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
import '../../services/profile/mastery_service.dart';
import 'knowledge_graph_layout.dart';
import 'knowledge_leaf_detail.dart';
import 'knowledge_node_style.dart';
import 'knowledge_sizes.dart';

/// 图谱视图。
class KnowledgeGraphView extends StatefulWidget {
  final KnowledgeBase kb;

  /// 每个知识点的掌握情况，按 `kpId` 索引。
  ///
  /// **空 map = 不做掌握度着色**，所有节点保持结构配色 ——
  /// 与"这个考点还没复习过"在视觉上是同一个样子。刻意如此：
  /// "还不知道"与"没有数据"不该长得不一样（否则用户会把
  /// "我还没开始"读成"我全都不会"）。
  final Map<String, KpMastery> masteryByKpId;

  const KnowledgeGraphView({
    super.key,
    required this.kb,
    this.masteryByKpId = const {},
  });

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

  /// 量一段标题的宽度。结果缓存 —— 同一层里同名节点不多，
  /// 但整棵树有几百个节点，重复量同一串不划算。
  ///
  /// [style] 由 [GraphStyle] 给出，**与渲染层用的是同一个对象**：
  /// 字号、字重、字体链三项都会改变宽度，少一项就又是一次"量排不同源"。
  double _measure(String text, TextStyle style) {
    // 缓存键必须含字号与字重 —— 换个字重量同一个字符串，结果并不相同
    final key = '${style.fontSize}|${style.fontWeight?.value}|$text';
    final hit = _measureCache[key];
    if (hit != null) return hit;
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final w = tp.width;
    tp.dispose();
    _measureCache[key] = w;
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

        // 至少有一个考点复习过，掌握度这一层才画得出来。
        // 全都没复习过 → 图例不提掌握度，节点也全是结构色。
        final hasMastery =
            widget.masteryByKpId.values.any((m) => m.mastery != null);

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
                              // 字号/字重/内边距都从布局结果里取 ——
                              // 与"量宽度"用的是同一份，见 GraphStyle 的说明
                              style: g.style,
                              // 掌握度（只有叶子会有值）。null = 不上状态色。
                              mastery: widget.masteryByKpId[n.id],
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
                  Flexible(child: _Legend(withMastery: hasMastery)),
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
                  fontSize: KnowledgeSizes.secondary,
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
                // 用 kSecondaryInk 而非 ink3：ink3 白底上只有 3.2:1，低于 AA
                style: TextStyle(
                    fontSize: KnowledgeSizes.secondary, color: kSecondaryInk),
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
  /// 有没有任何节点上了掌握度色。
  ///
  /// 没有时**不显示掌握度图例** —— 一份写着"稳固/不牢/薄弱"、
  /// 却在图上一个对应颜色都找不到的图例，只会让人以为界面坏了。
  final bool withMastery;

  const _Legend({this.withMastery = false});

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
                      color: nodeThemeOf(k).fill,
                      borderRadius: BorderRadius.circular(2.5),
                      border: Border.all(color: nodeThemeOf(k).border),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    nodeKindLabel(k),
                    // 图例也是要读的文字：用 ink2（ink3 只有 3.2:1）
                    style: const TextStyle(
                        fontSize: KnowledgeSizes.secondary,
                        color: kSecondaryInk),
                  ),
                ],
              ),
            // 掌握度图例。它回答的是另一个问题（"我对它掌握得怎么样"），
            // 所以用一根竖线跟前面那组"这是什么"分开。
            if (withMastery) ...[
              Container(width: 1, height: 11, color: AppColors.line),
              for (final b in const [
                MasteryBand.weak,
                MasteryBand.shaky,
                MasteryBand.solid,
              ])
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: masteryBandFill(b),
                        borderRadius: BorderRadius.circular(2.5),
                        border: Border.all(
                          color: masteryBandInk(b).withValues(alpha: 0.38),
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      masteryBandLabel(b),
                      style: const TextStyle(
                          fontSize: KnowledgeSizes.secondary,
                          color: kSecondaryInk),
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

// ─────────────────────────────────────────────────────────────────────────────
// 节点外观见 `knowledge_node_style.dart`（与大纲视图共用一份配色）
// ─────────────────────────────────────────────────────────────────────────────

/// 悬停提示：全名 + id +（有复习数据时）掌握情况。
///
/// 全名放在**第一行**：节点宽度有上限，长名字会被省略号截断，
/// 而悬停是看全称的唯一途径。
///
/// 后面那句"3/7 题有记录"不是装饰 —— 一个由 1 道题算出的 62%
/// 与由 7 道题算出的 62% 可信度完全不同，只给百分比就是在暗示
/// 一个它没有的精度（这是画像页早就立下的纪律，这里照搬）。
String _tooltipFor(KnowledgePoint p, KpMastery? m) {
  final lines = <String>[p.name, p.id];
  if (m == null) return lines.join('\n');

  if (m.mastery != null) {
    final pct = (m.mastery! * 100).round();
    lines.add(
      '掌握 $pct% · ${m.reviewedCount}/${m.problemCount} 题有记录'
      '${m.wrongCount > 0 ? ' · 累计错 ${m.wrongCount} 次' : ''}',
    );
  } else if (m.problemCount > 0) {
    lines.add('收录 ${m.problemCount} 题，尚未复习过');
  }
  return lines.join('\n');
}

class _GraphNodeCard extends StatelessWidget {
  final GraphNode node;

  /// 与布局同源的样式。**不要在这里写死字号或字重** ——
  /// 那正是"量的和排的不是一个东西"的来源（见 `GraphStyle` 的注释）。
  final GraphStyle style;

  /// 这个知识点的掌握情况。null 或 `mastery == null` 时**不上状态色**。
  final KpMastery? mastery;

  final bool selected;
  final bool dimmed;
  final VoidCallback onTap;

  const _GraphNodeCard({
    super.key,
    required this.node,
    required this.style,
    this.mastery,
    required this.selected,
    required this.dimmed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final kind = node.kind;
    // 结构配色 + 掌握度状态。只改底色/描边，文字色不动（见 masteryThemeOf）。
    final theme = masteryThemeOf(kind, mastery?.mastery);
    final ink = theme.onFillInk;
    final w = node.point.examWeight;

    return Opacity(
      opacity: dimmed ? 0.35 : 1,
      child: Material(
        type: MaterialType.transparency,
        child: Tooltip(
          message: _tooltipFor(node.point, mastery),
          waitDuration: const Duration(milliseconds: 600),
          child: InkWell(
            onTap: onTap,
            borderRadius: AppRadius.rSm,
            child: Container(
              decoration: BoxDecoration(
                color: theme.fill,
                borderRadius: AppRadius.rSm,
                border: Border.all(
                  color: selected ? AppColors.warning : theme.border,
                  width: selected ? 2 : 1,
                ),
              ),
              // 内边距与布局量宽时用的是同一个值（style.paddingH）
              padding: EdgeInsets.symmetric(horizontal: style.paddingH),
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      node.point.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style.textStyleOf(kind).copyWith(color: ink),
                    ),
                  ),
                  if (kind == GraphNodeKind.leaf && w != null) ...[
                    // 这个徽标也占宽度，已经在 buildKnowledgeGraph 里算进列宽了
                    SizedBox(width: style.weightGap),
                    Text(
                      w.toStringAsFixed(2),
                      style: style.weightStyle.copyWith(color: weightInk(w)),
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

class _SelectionPanel extends StatefulWidget {
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
  State<_SelectionPanel> createState() => _SelectionPanelState();
}

class _SelectionPanelState extends State<_SelectionPanel> {
  /// 详情比面板高时，底部给一条"还有内容"的提示。
  ///
  /// 为什么值得单独做：面板有高度上限，内容被硬切在边缘时**看不出还能滚** ——
  /// 用户反馈的"公式显示不完整"里就有这种情况（公式的下半截在面板外）。
  final ScrollController _scroll = ScrollController();
  bool _hasMore = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_checkMore);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkMore());
  }

  @override
  void didUpdateWidget(_SelectionPanel old) {
    super.didUpdateWidget(old);
    if (old.node.id != widget.node.id) {
      _hasMore = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkMore());
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_checkMore);
    _scroll.dispose();
    super.dispose();
  }

  void _checkMore() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final more = p.maxScrollExtent - p.pixels > 8;
    if (more != _hasMore && mounted) setState(() => _hasMore = more);
  }

  @override
  Widget build(BuildContext context) {
    final kb = widget.kb;
    final node = widget.node;
    final leafCount = kb.leafCountUnder(node.id);
    final crumbs = kb
        .pathTo(node.id)
        .where((n) => n.id != node.id)
        .map((n) => n.name)
        .join(' › ');
    final leafCrumb = detailBreadcrumb(kb, node.point.id);

    return Material(
      type: MaterialType.transparency,
      child: Container(
        // 面板高度：详情卡有 600–900px 高，早先卡在 260px 时用户只能看见
        // 定义和一个开头 —— 看着就像"公式被切掉了"。改成跟着窗口给，
        // 上限 45% 视口高（图谱本身还剩一半可见）。
        constraints: BoxConstraints(
          maxHeight: (MediaQuery.sizeOf(context).height * 0.45)
              .clamp(220.0, 460.0),
        ),
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
                    style: const TextStyle(
                        fontSize: KnowledgeSizes.title,
                        fontWeight: FontWeight.w700),
                  ),
                ),
                if (crumbs.isNotEmpty)
                  Flexible(
                    child: Text(
                      crumbs,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      // caption 默认用 ink3（3.2:1，低于 AA）—— 面包屑是要读的
                      style: const TextStyle(
                          fontSize: KnowledgeSizes.secondary,
                          color: kSecondaryInk),
                    ),
                  ),
                IconButton(
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close, size: 17),
                  tooltip: '关闭',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Flexible(
              child: Stack(
                children: [
                  SingleChildScrollView(
                    controller: _scroll,
                    child: node.kind == GraphNodeKind.leaf
                        ? KnowledgeLeafDetail(
                            leaf: node.point,
                            sectionName: leafCrumb.section,
                            chapterName: leafCrumb.chapter,
                          )
                        : _BranchSummary(
                            kb: kb,
                            node: node,
                            leafCount: leafCount,
                          ),
                  ),
                  // 被高度上限截住时明确告诉用户"下面还有" ——
                  // 硬切在边缘的话，看不出还能滚（用户会以为公式不完整）
                  if (_hasMore)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: Container(
                          key: const ValueKey('panel-more-hint'),
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                AppColors.surface.withValues(alpha: 0),
                                AppColors.surface,
                              ],
                            ),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.keyboard_arrow_down,
                                  size: 14, color: kSecondaryInk),
                              SizedBox(width: 3),
                              Text(
                                '下面还有内容，可滚动查看',
                                style: TextStyle(
                                    fontSize: KnowledgeSizes.secondary,
                                    color: kSecondaryInk),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
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
                style: const TextStyle(
                    fontSize: KnowledgeSizes.secondary,
                    color: kSecondaryInk)),
            if (kids.isNotEmpty)
              Text('${kids.length} 个下级',
                  style: const TextStyle(
                      fontSize: KnowledgeSizes.secondary,
                      color: kSecondaryInk)),
            if (w != null)
              Text('考频 ${w.toStringAsFixed(2)}',
                  style: const TextStyle(
                      fontSize: KnowledgeSizes.secondary,
                      color: kSecondaryInk)),
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
                    style: const TextStyle(
                        fontSize: KnowledgeSizes.secondary,
                        color: kSecondaryInk),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
