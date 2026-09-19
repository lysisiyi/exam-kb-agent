/// 图谱与大纲共用的**节点外观**定义（配色 + 名称）。
///
/// 两处各写一份配色的话，"章节"在两个视图里会慢慢变成两种颜色 ——
/// 用户在两个视图之间切换时就得重新认一遍图例。
library;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'knowledge_graph_layout.dart' show GraphNodeKind;

/// 节点底色。
Color nodeFill(GraphNodeKind k) => switch (k) {
      GraphNodeKind.root => AppColors.primaryStrong,
      GraphNodeKind.section => AppColors.primary,
      GraphNodeKind.chapter => AppColors.primaryWeak,
      GraphNodeKind.unit => AppColors.purpleWeak,
      GraphNodeKind.leaf => AppColors.surface,
    };

/// 节点描边。
Color nodeBorder(GraphNodeKind k) => switch (k) {
      GraphNodeKind.root => AppColors.primaryStrong,
      GraphNodeKind.section => AppColors.primary,
      GraphNodeKind.chapter => AppColors.primarySoft,
      GraphNodeKind.unit => AppColors.purple.withValues(alpha: 0.35),
      GraphNodeKind.leaf => AppColors.line,
    };

/// 节点文字色。
Color nodeInk(GraphNodeKind k) => switch (k) {
      GraphNodeKind.root || GraphNodeKind.section => Colors.white,
      GraphNodeKind.chapter => AppColors.primaryStrong,
      GraphNodeKind.unit => AppColors.purple,
      GraphNodeKind.leaf => AppColors.ink1,
    };

/// 节点角色的中文名（图例与无障碍标签用）。
String nodeKindLabel(GraphNodeKind k) => switch (k) {
      GraphNodeKind.root => '科目',
      GraphNodeKind.section => '分段',
      GraphNodeKind.chapter => '章节',
      GraphNodeKind.unit => '小节',
      GraphNodeKind.leaf => '知识点',
    };

/// 考频数字的颜色（三档：高频红、中频橙、其余灰）。
Color weightInk(double? w) {
  if (w == null) return AppColors.ink3;
  if (w >= 0.85) return AppColors.danger;
  if (w >= 0.6) return AppColors.warningInk;
  return AppColors.ink3;
}
