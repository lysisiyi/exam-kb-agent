/// 图谱布局的几何不变量。
///
/// ## 为什么布局要单独测
///
/// 图谱"看起来对不对"很难断言，但**坐标的几条性质**可以：
///
/// - 同一列里节点不重叠（重叠 = 文字叠在一起，读不出来）
/// - 父节点的中心落在自己子节点的纵向范围内（否则连线会横穿别人）
/// - 叶子的行号连续且按 id 顺序（漏行会出现莫名的空档，乱序则不像目录）
/// - 画布包得住所有节点（否则边缘节点被裁掉）
/// - 命中测试与 `pathTo` 与坐标一致（点不中就等于点不了）
///
/// 这些性质一旦破坏，图会"看着怪"，而 widget 测试抓不到那种"怪"。
library;

import 'dart:ui' show Offset, Rect;

import 'package:flutter/painting.dart' show TextStyle;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/features/knowledge/knowledge_graph_layout.dart';

import 'support/knowledge_fixture.dart';

/// 确定性测量：按字符数估宽（中文算 1em、其余算 0.58em）。
///
/// 系数按 [TextStyle.fontSize] 缩放 —— 度量与渲染必须同源，
/// 字号一变这里就得跟着变（这正是签名带上 `TextStyle` 的原因）。
double measure(String text, TextStyle style) {
  final size = style.fontSize ?? 12;
  var w = 0.0;
  for (final r in text.runes) {
    w += r > 0x2E80 ? size : size * 0.58;
  }
  return w;
}

KnowledgeGraph layoutOf(
  KnowledgeBase kb, {
  GraphStyle style = const GraphStyle(),
}) =>
    buildKnowledgeGraph(kb, measure: measure, style: style);

void main() {
  final kb = math1LikeKb();
  final g = layoutOf(kb);

  test('每个节点都有坐标，连线数 = 节点数 - 1（一棵树）', () {
    expect(g.nodes.length, kb.nodes.length);
    expect(g.indexById.length, kb.nodes.length);
    expect(g.edges.length, kb.nodes.length - 1);
    for (final n in g.nodes) {
      expect(n.rect.width, greaterThan(0));
      expect(n.rect.height, greaterThan(0));
    }
  });

  test('叶子行号连续，且按 id 顺序（= 考纲顺序）', () {
    final leaves = g.nodes.where((n) => n.kind == GraphNodeKind.leaf).toList()
      ..sort((a, b) => a.row.compareTo(b.row));

    expect(leaves.length, kb.leaves.length);
    for (var i = 0; i < leaves.length; i++) {
      expect(leaves[i].row, i.toDouble(), reason: '第 $i 个叶子的行号不连续');
    }
    final idsInRowOrder = leaves.map((n) => n.id).toList();
    final idsSorted = [...idsInRowOrder]..sort();
    expect(idsInRowOrder, idsSorted, reason: '行序必须与 id 序一致');
  });

  test('同一列里任意两个节点的纵向区间不重叠', () {
    final byDepth = <int, List<GraphNode>>{};
    for (final n in g.nodes) {
      byDepth.putIfAbsent(n.depth, () => []).add(n);
    }
    for (final entry in byDepth.entries) {
      final col = entry.value..sort((a, b) => a.rect.top.compareTo(b.rect.top));
      for (var i = 1; i < col.length; i++) {
        expect(
          col[i].rect.top,
          greaterThanOrEqualTo(col[i - 1].rect.bottom),
          reason: '第 ${entry.key} 列：${col[i - 1].id} 与 ${col[i].id} 重叠',
        );
      }
    }
  });

  test('父节点的中心落在子节点的纵向范围内', () {
    for (final e in g.edges) {
      final p = g.nodes[e.parent];
      final kids = g.edges.where((x) => x.parent == e.parent).toList();
      final centers = kids.map((x) => g.nodes[x.child].centerY).toList();
      final lo = centers.reduce((a, b) => a < b ? a : b);
      final hi = centers.reduce((a, b) => a > b ? a : b);
      expect(p.centerY, greaterThanOrEqualTo(lo - 0.001),
          reason: '${p.id} 的中心高出了自己的子节点范围');
      expect(p.centerY, lessThanOrEqualTo(hi + 0.001),
          reason: '${p.id} 的中心低出了自己的子节点范围');
    }
  });

  test('画布包得住所有节点', () {
    final bounds = Rect.fromLTWH(0, 0, g.size.width, g.size.height);
    for (final n in g.nodes) {
      expect(bounds.contains(n.rect.topLeft), isTrue, reason: '${n.id} 左上角出界');
      expect(bounds.contains(n.rect.bottomRight - const Offset(0.01, 0.01)),
          isTrue,
          reason: '${n.id} 右下角出界');
    }
  });

  test('列号与 id 段数一致（层级不能错位）', () {
    for (final n in g.nodes) {
      expect(n.depth, n.point.idDepth, reason: '${n.id} 的列号与 id 段数不符');
    }
  });

  test('命中测试点得中', () {
    for (final n in g.nodes) {
      expect(g.hitTest(n.rect.center)?.id, n.id);
    }
    // 空白处不该命中
    expect(g.hitTest(Offset(g.size.width - 1, g.size.height - 1)), isNull);
  });

  test('pathTo 给出从根到目标的完整链条', () {
    const leaf = 'math1.calc.limit.taylor';
    final path = g.pathTo(leaf).map((i) => g.nodes[i].id).toList();
    expect(path, ['math1', 'math1.calc', 'math1.calc.limit', leaf]);
    expect(g.pathTo('不存在'), isEmpty);
    // 根本身的路径就是它自己
    expect(g.pathTo('math1').map((i) => g.nodes[i].id).toList(), ['math1']);
  });

  test('两次布局结果完全一致（可复现）', () {
    final a = layoutOf(kb);
    final b = layoutOf(kb);
    for (var i = 0; i < a.nodes.length; i++) {
      expect(a.nodes[i].rect, b.nodes[i].rect);
    }
  });

  test('数三那种 5 层树也画得出来，且「节」被归为 unit', () {
    final kb3 = math3LikeKb();
    final g3 = layoutOf(kb3);
    expect(g3.nodes.length, kb3.nodes.length);
    expect(g3.maxDepth, 5);
    expect(g3.nodeOf('math3.calc.limit.seq')!.kind, GraphNodeKind.unit);
    expect(g3.nodeOf('math3.calc.limit')!.kind, GraphNodeKind.chapter);
    expect(g3.nodeOf('math3.calc')!.kind, GraphNodeKind.section);
    expect(g3.nodeOf('math3')!.kind, GraphNodeKind.root);
  });

  test('行高变大 → 画布变高（缩放的量纲正确）', () {
    final tight = layoutOf(kb, style: const GraphStyle(rowHeight: 20));
    final loose = layoutOf(kb, style: const GraphStyle(rowHeight: 40));
    expect(loose.size.height, greaterThan(tight.size.height));
    // 宽度只与最长标题有关，不随行高变化
    expect(loose.size.width, tight.size.width);
  });
}
