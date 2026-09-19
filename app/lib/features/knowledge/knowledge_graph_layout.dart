/// 知识点图谱的**布局计算**（纯函数，不依赖 widget，可单测）。
///
/// ## 为什么单独抽出来
///
/// 图谱"画得对不对"和"点得中不中"都取决于这份坐标。把它做成纯函数后，
/// 下面这些性质可以用普通断言钉住，不需要渲染：
///
/// - 同一层里任意两个节点的**垂直区间不重叠**（否则文字会叠在一起）
/// - 父节点的中心**落在子节点区间之内**（否则连线会横穿别人）
/// - 叶子的行号按 id 顺序**连续**（否则图里会出现莫名的空档）
/// - 画布尺寸**包得住**所有节点
///
/// ## 布局算法
///
/// 从左到右分层（1 层一列），叶子按中序遍历顺序各占一行，父节点取
/// 子节点行的**中点**。这不是完整的 Reingold–Tilford，但对我们这种
/// "层数少（4–5）、叶子多（一两百）"的树足够：叶子永远不重叠，
/// 父节点也永远在自己子树的叶子范围内。
///
/// ## 为什么叶子按 id 顺序
///
/// `KnowledgeBase.childrenOf` 已按 id 排序，而 id 的书写顺序就是考纲顺序
/// （见 `_groupByParent` 的注释）。所以中序遍历出来的行序天然是"教材顺序"。
library;

import 'dart:ui' show Offset, Rect, Size;

import '../../domain/knowledge/knowledge_point.dart';

/// 节点在图里的角色 —— 决定配色与"要不要显示考频徽标"。
enum GraphNodeKind {
  /// 科目根，如 `math1`。
  root,

  /// 学科分段，如 `math1.calc`。
  section,

  /// 章节，如 `math1.calc.limit`。
  chapter,

  /// 更深的分支（数三的「节」，如 `math3.calc.limit.seq`）。
  unit,

  /// 知识点叶子（唯一能被标注为考点的）。
  leaf,
}

/// 一个节点在画布上的位置与尺寸。
class GraphNode {
  final KnowledgePoint point;
  final GraphNodeKind kind;

  /// 第几列（科目根为 1）。
  final int depth;

  /// 行号（叶子是整数序号；分支取子节点均值，所以有小数）。
  final double row;

  final Rect rect;

  const GraphNode({
    required this.point,
    required this.kind,
    required this.depth,
    required this.row,
    required this.rect,
  });

  String get id => point.id;
  double get centerY => rect.center.dy;

  @override
  String toString() =>
      'GraphNode(${point.id}, $kind, col=$depth, row=$row, ${rect.left.toStringAsFixed(1)},'
      '${rect.top.toStringAsFixed(1)} ${rect.width.toStringAsFixed(0)}x${rect.height.toStringAsFixed(0)})';
}

/// 一条父子连线。
class GraphEdge {
  /// 在 [KnowledgeGraph.nodes] 里的下标。
  final int parent;
  final int child;

  const GraphEdge(this.parent, this.child);
}

/// 布局参数。
class GraphStyle {
  /// 节点标题字号。宽度是按它量出来的，所以改字号要重新布局。
  final double fontSize;

  /// 每个叶子占的行高（含间隙）。
  final double rowHeight;

  /// 节点内边距（文字到边框）。
  final double paddingH;
  final double paddingV;

  /// 列间距。
  final double columnGap;

  /// 节点宽度下限 / 上限（太长的名字截断，靠悬停提示看全）。
  final double minNodeWidth;
  final double maxNodeWidth;

  /// 画布四周留白。
  final double margin;

  const GraphStyle({
    this.fontSize = 12,
    this.rowHeight = 27,
    this.paddingH = 10,
    this.paddingV = 5,
    this.columnGap = 34,
    this.minNodeWidth = 96,
    this.maxNodeWidth = 210,
    this.margin = 20,
  });

  /// 节点高度（所有节点一样高，连线看起来才整齐）。
  double get nodeHeight => fontSize * 1.35 + paddingV * 2;
}

/// 布局结果。
class KnowledgeGraph {
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;

  /// 画布尺寸（包含留白）。
  final Size size;

  /// id → nodes 下标。
  final Map<String, int> indexById;

  /// 最大列数。
  final int maxDepth;

  const KnowledgeGraph({
    required this.nodes,
    required this.edges,
    required this.size,
    required this.indexById,
    required this.maxDepth,
  });

  GraphNode? nodeOf(String id) {
    final i = indexById[id];
    return i == null ? null : nodes[i];
  }

  /// 命中测试（点在哪个节点上）。
  GraphNode? hitTest(Offset p) {
    for (final n in nodes) {
      if (n.rect.contains(p)) return n;
    }
    return null;
  }

  /// 从根到该节点的连线下标（用来高亮一条路径）。
  ///
  /// 返回 nodes 下标的顺序列表（含起点与终点）；找不到时返回空列表。
  List<int> pathTo(String id) {
    final target = indexById[id];
    if (target == null) return const [];
    final parentOf = <int, int>{for (final e in edges) e.child: e.parent};
    final out = <int>[target];
    var cur = target;
    var guard = 0;
    while (parentOf.containsKey(cur) && guard++ < 32) {
      cur = parentOf[cur]!;
      out.insert(0, cur);
    }
    return out;
  }
}

/// 量一段文字的宽度。widget 层传 TextPainter 的实现，测试传确定性实现。
typedef MeasureText = double Function(String text);

/// 按 [kb] 算出一份图谱布局。
///
/// [measure] 用来量节点标题宽度（决定每列多宽）。[style] 决定行高与内边距。
KnowledgeGraph buildKnowledgeGraph(
  KnowledgeBase kb, {
  required MeasureText measure,
  GraphStyle style = const GraphStyle(),
}) {
  // ── 1. 中序遍历，确定每个叶子的行号 ────────────────────────────────────
  final entries = <_Entry>[];
  final childrenOf = kb.childrenOf;

  // 起点：正常是科目根；根存在但没有子节点时退到顶层节点
  // （见 KnowledgeBase.traversalRoots）。列号一律按 id 段数算，
  // 保证列与层严格对应。
  final starts = kb.traversalRoots;

  var leafRow = 0.0;
  final visited = <String>{};

  double walk(KnowledgePoint node, int depth) {
    if (!visited.add(node.id)) return leafRow; // 防环（数据坏了也不至于死循环）

    final kids = node.isLeaf
        ? const <KnowledgePoint>[]
        : (childrenOf[node.id] ?? const <KnowledgePoint>[]);

    double row;
    if (kids.isEmpty) {
      row = leafRow;
      leafRow += 1;
    } else {
      var sum = 0.0;
      for (final k in kids) {
        sum += walk(k, depth + 1);
      }
      row = sum / kids.length;
    }

    entries.add(_Entry(node: node, depth: depth, row: row));
    return row;
  }

  for (final s in starts) {
    walk(s, s.idDepth);
  }

  // 按列分组 → 每列宽度 = 该列最长标题（夹在上下限之间）
  final widthByDepth = <int, double>{};
  for (final e in entries) {
    final w = measure(e.node.name) + style.paddingH * 2;
    final clamped = w.clamp(style.minNodeWidth, style.maxNodeWidth);
    final prev = widthByDepth[e.depth] ?? 0;
    if (clamped > prev) widthByDepth[e.depth] = clamped;
  }

  // ── 2. 列起点 ─────────────────────────────────────────────────────────
  final depthList = widthByDepth.keys.toList()..sort();
  final leftByDepth = <int, double>{};
  var cursor = style.margin;
  for (final d in depthList) {
    leftByDepth[d] = cursor;
    cursor += widthByDepth[d]! + style.columnGap;
  }
  final contentWidth = cursor - style.columnGap + style.margin;

  // ── 3. 行号 → 坐标 ────────────────────────────────────────────────────
  final nodes = <GraphNode>[];
  final indexById = <String, int>{};
  for (final e in entries) {
    final rect = Rect.fromLTWH(
      leftByDepth[e.depth] ?? style.margin,
      style.margin + e.row * style.rowHeight,
      widthByDepth[e.depth] ?? style.minNodeWidth,
      style.nodeHeight,
    );
    indexById[e.node.id] = nodes.length;
    nodes.add(GraphNode(
      point: e.node,
      kind: graphKindOf(e.node),
      depth: e.depth,
      row: e.row,
      rect: rect,
    ));
  }

  // ── 4. 连线 ───────────────────────────────────────────────────────────
  final edges = <GraphEdge>[];
  for (final e in entries) {
    final pi = indexById[e.node.id];
    if (pi == null || e.node.isLeaf) continue;
    for (final k in childrenOf[e.node.id] ?? const <KnowledgePoint>[]) {
      final ci = indexById[k.id];
      if (ci != null) edges.add(GraphEdge(pi, ci));
    }
  }

  final height =
      style.margin * 2 + (leafRow == 0 ? 1 : leafRow - 1) * style.rowHeight +
          style.nodeHeight;

  return KnowledgeGraph(
    nodes: nodes,
    edges: edges,
    size: Size(contentWidth, height),
    indexById: indexById,
    maxDepth: depthList.isEmpty ? 1 : depthList.last,
  );
}

/// 节点角色：由 **id 深度 + 是否叶子** 决定（不看 `level` 字段）。
/// 大纲视图与图谱视图共用它，两边的"这是章节还是小节"才不会打架。
GraphNodeKind graphKindOf(KnowledgePoint p) {
  if (p.isLeaf) return GraphNodeKind.leaf;
  if (p.idDepth <= 2) {
    return p.parentId == null ? GraphNodeKind.root : GraphNodeKind.section;
  }
  return p.idDepth == 3 ? GraphNodeKind.chapter : GraphNodeKind.unit;
}

class _Entry {
  final KnowledgePoint node;
  final int depth;
  final double row;
  const _Entry({required this.node, required this.depth, required this.row});
}
