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

import 'package:flutter/painting.dart' show FontFeature, FontWeight, TextStyle;

import '../../core/theme/app_fonts.dart';
import '../../domain/knowledge/knowledge_point.dart';
import 'knowledge_sizes.dart';

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
///
/// ## ⚠️ 这里同时是**渲染**参数的唯一来源
///
/// 早先布局与渲染各自写着"节点文字长什么样"：
///
/// | | 布局（本文件） | 渲染（`knowledge_graph_view.dart`） |
/// |---|---|---|
/// | 字号 | 12 | **12.5** |
/// | 字重 | w600 | **叶子 w500 / 分支 w700** |
/// | 水平内边距 | 10 | **9** |
/// | 考频数字 | **完全没算** | 10.5 + 6 间距 |
///
/// 于是"量的和排的不是一个东西"：列宽按 12/w600 算出来，实际排的是
/// 12.5/w700 —— 宽了；而叶子节点还要额外塞进一个考频徽标。结果就是
/// **节点名字莫名被省略号截断**（宽度算少了），读者却只看得到
/// "名字怎么没了"，看不到原因。
///
/// 现在节点的 [textStyleOf] / [weightStyle] / [paddingH] 只有这一份定义，
/// 布局用它量宽、渲染用它排版，两者**在结构上不可能再分叉**。
class GraphStyle {
  /// 节点标题字号。宽度是按它量出来的，所以改字号要重新布局。
  final double fontSize;

  /// 叶子行高的显式覆盖值。null 表示由 [nodeHeight] 派生。
  final double? _rowHeightOverride;

  /// 节点内边距（文字到边框）。
  final double paddingH;
  final double paddingV;

  /// 列间距。
  final double columnGap;

  /// 节点宽度下限 / 上限（太长的名字截断，靠悬停提示看全）。
  ///
  /// ## 上限为什么是 240 而不是 210
  ///
  /// 字号从 12 提到 14 之后，同一个名字宽了 17%，顶到上限而被省略号截断的
  /// 节点数会**成倍增加**。上限必须跟着字号走。
  ///
  /// 实测（math1 真实数据，164 个节点，`knowledge_size_test.dart` 里那条
  /// "顶到宽度上限的节点占比"就是它的固化）：
  ///
  /// | 字号 | 上限 | 被截断的节点 |
  /// |---|---|---|
  /// | 12（改前） | 210（改前） | 11 / 164 = 6.7% |
  /// | 14 | 210 | **40 / 164 = 24.4%** |
  /// | 14 | **240** | **11 / 164 = 6.7%** |
  ///
  /// 也就是说 240 把"名字被吃掉"这件事精确地拉回了改前的水平。
  ///
  /// ## 但上限不是越大越好
  ///
  /// 列宽直接决定画布宽度，而画布越宽，"适应宽度"把整棵树缩得越小 ——
  /// **字反而变小**，与"放大字号"的初衷相反。所以上限只加到刚好抵消
  /// 字号增长（12→14 是 +17%，210×1.17 ≈ 246，取整 240）。
  final double minNodeWidth;
  final double maxNodeWidth;

  /// 画布四周留白。
  final double margin;

  /// 节点名与考频数字之间的间距。
  final double weightGap;

  const GraphStyle({
    this.fontSize = KnowledgeSizes.title,
    double? rowHeight,
    this.paddingH = 10,
    this.paddingV = 5,
    this.columnGap = 34,
    this.minNodeWidth = 96,
    this.maxNodeWidth = 240,
    this.margin = 20,
    this.weightGap = 6,
  }) : _rowHeightOverride = rowHeight;

  /// 节点高度（所有节点一样高，连线看起来才整齐）。
  double get nodeHeight => fontSize * 1.35 + paddingV * 2;

  /// 相邻叶子的行距。
  static const double rowGap = 3;

  /// 叶子行高。
  ///
  /// 默认由 [nodeHeight] 派生（+ [rowGap]），**刻意不再写成独立字面量**：
  /// 它必须大于 [nodeHeight]，否则同一列相邻节点的矩形会重叠、文字压在一起。
  ///
  /// 早先它是写死的 27，而 nodeHeight 由字号派生成 26.2 —— 只差 0.8px，
  /// 所以"字号一改就重叠"这颗雷一直没响。现在两者绑定，
  /// 改字号时行高自动跟上。
  double get rowHeight => _rowHeightOverride ?? nodeHeight + rowGap;

  /// 各角色的字重。
  ///
  /// **层级靠字重表达，不靠字号** —— 同一张图里字号必须一致，
  /// 否则就是用户反馈的"字尺寸深浅不一"。见 [KnowledgeSizes] 的说明。
  ///
  /// 只允许 [AppFonts.regular] / [AppFonts.bold] 两个值：`Microsoft YaHei UI`
  /// 这个族**只提供 Regular 与 Bold**，写 `w500` 会被静默近似成 Regular、
  /// 写 `w600` 会近似成 Bold —— 代码意图与实际渲染不符。依据见
  /// `app_fonts.dart` 里 [AppFonts.bold] 的注释（实测数据）。
  FontWeight fontWeightOf(GraphNodeKind kind) =>
      kind == GraphNodeKind.leaf ? AppFonts.regular : AppFonts.bold;

  /// 节点名在 **度量** 与 **渲染** 共用的样式。
  ///
  /// 必须带 `fontWeight`：它直接影响字形宽度。此前度量统一用 w600、
  /// 而渲染用 w500/w700，是"量排不同源"的第一条成因。
  ///
  /// 也必须带**字体链**：度量用的 `TextPainter` 没有 widget 树可以继承，
  /// 不带 `fontFamily` 就落到平台默认字体上，量出来的宽度与渲染层
  /// （继承 `ThemeData.fontFamily`）不同。两边都从这里取才真正同源。
  TextStyle textStyleOf(GraphNodeKind kind) => TextStyle(
        fontFamily: AppFonts.sans,
        fontFamilyFallback: AppFonts.sansFallback,
        fontSize: fontSize,
        fontWeight: fontWeightOf(kind),
      );

  /// 考频数字的样式（叶子节点右侧的徽标）。
  ///
  /// 它也算进节点宽度 —— 早先没算，导致叶子名字被截断。
  ///
  /// ## 为什么字重与名字一致（Regular），而不是加粗
  ///
  /// 加粗会造出**同一行里两种字重**：名字 Regular、徽标 Bold。
  /// 在用户给的截图上量过：考频数字（`0.76`、`0.96`）比它左边的名字更"实" ——
  /// 一行之内一小一大、一轻一重，正是"深浅不一"的来源之一。
  ///
  /// 考频的重要性**交给颜色**（[weightInk]：高频红 / 中频橙 / 其余中性），
  /// 这也是本项目在其他地方已经用过的手法 —— 层级由结构（色块）与颜色表达，
  /// 字重只用来区分**分支与叶子**这两种结构角色。
  ///
  /// **数字仍用等宽数字**：上下相邻节点的考频才能对齐成一列，扫读快得多。
  TextStyle get weightStyle => const TextStyle(
        fontFamily: AppFonts.sans,
        fontFamilyFallback: AppFonts.sansFallback,
        fontSize: KnowledgeSizes.secondary,
        fontWeight: AppFonts.regular,
        fontFeatures: [FontFeature.tabularFigures()],
      );
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

  /// 生成这张图用的样式。
  ///
  /// 渲染层（`_GraphNodeCard`）**必须**从这里取字号、字重与内边距 ——
  /// 它自己再写一遍就等于把"量的和排的不是一个东西"重新引入。
  final GraphStyle style;

  const KnowledgeGraph({
    required this.nodes,
    required this.edges,
    required this.size,
    required this.indexById,
    required this.maxDepth,
    required this.style,
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
///
/// ⚠️ 必须带上 [TextStyle]：字重会改变字形宽度，而同一列里叶子走 w500、
/// 分支走 w700 —— 早先度量只有一个 `String` 参数，只能统一按 w600 量，
/// 于是量出来的宽度**无论怎么改都不等于渲染宽度**。
typedef MeasureText = double Function(String text, TextStyle style);

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
    final kind = graphKindOf(e.node);
    // 用**该角色自己的样式**量 —— 字重不同、宽度不同（叶子 w500 / 分支 w700）
    var w = measure(e.node.name, style.textStyleOf(kind)) + style.paddingH * 2;

    // 叶子节点右侧还挂着一个考频徽标，它的宽度也必须算进来。
    // 早先这里没算，于是"名字 + 间距 + 徽标"被硬塞进"名字宽 + 内边距"的框里
    // —— 装不下，名字就被省略号吃掉一截。
    final weight = e.node.examWeight;
    if (kind == GraphNodeKind.leaf && weight != null) {
      w += style.weightGap +
          measure(weight.toStringAsFixed(2), style.weightStyle);
    }

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
    style: style,
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
