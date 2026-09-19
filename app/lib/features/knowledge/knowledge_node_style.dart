/// 知识点节点与文字的**唯一**配色来源（图谱与大纲共用）。
///
/// ## 为什么必须只有一份
///
/// 用户反馈"图谱和大纲的字体颜色深浅不一"。查下来是两处各写各的：
///
/// | 语义 | 图谱 | 大纲（改前） |
/// |---|---|---|
/// | 章节名 | `primaryStrong` 蓝 | `ink1` 近黑 |
/// | 叶子名 | `ink1` 近黑（17.8:1） | `ink2` 灰（8.2:1） |
/// | 叶子编号 | — | `ink3`（**3.2:1，低于 AA**） |
///
/// 同一个"叶子"在两个视图里差了两档深浅，而层级本来是**同一件事**，
/// 不该由两处各自决定。所以这里给每种角色定义一套完整外观，
/// 两个视图只能从 [nodeThemeOf] 取。
///
/// ## 五个字段各自负责什么
///
/// - [NodeTheme.fill] / [NodeTheme.border]：图谱里的节点卡片
/// - [NodeTheme.onFillInk]：节点卡片上的文字（必须与 fill 有对比）
/// - [NodeTheme.textInk]：大纲行里白底上的**名字**颜色
/// - [NodeTheme.accent]：编号 / 小圆点 / 左侧色条
///
/// 层级靠**字重 + accent 色条**表达，不靠把叶子调浅 —— 调浅会让叶子
/// 读起来像禁用态，而叶子才是用户真正要读的东西。
///
/// ## 对比度是硬约束
///
/// [textInk] 与 [accent] 在白底上、[onFillInk] 在自己的 fill 上，
/// 都必须 ≥ 4.5:1（WCAG AA 正文标准）。这条由
/// `test/knowledge_palette_test.dart` 守着 —— 以后谁再把颜色调浅会被测试拦住。
library;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'knowledge_graph_layout.dart' show GraphNodeKind;

/// 一种角色的完整外观。
class NodeTheme {
  /// 图谱节点底色。
  final Color fill;

  /// 图谱节点描边。
  final Color border;

  /// 图谱节点上的文字色（画在 [fill] 上）。
  final Color onFillInk;

  /// 大纲行里白底上的名字色。
  final Color textInk;

  /// 编号 / 圆点 / 左侧色条。
  final Color accent;

  const NodeTheme({
    required this.fill,
    required this.border,
    required this.onFillInk,
    required this.textInk,
    required this.accent,
  });
}

/// 角色的外观。**两个视图都必须走这里**。
NodeTheme nodeThemeOf(GraphNodeKind k) => switch (k) {
      // 科目与学科分段：实心深底 + 白字（图谱里是"大标题"的角色）
      GraphNodeKind.root => const NodeTheme(
          fill: AppColors.primaryStrong,
          border: AppColors.primaryStrong,
          onFillInk: Colors.white,
          textInk: AppColors.ink1,
          accent: AppColors.primaryStrong,
        ),
      GraphNodeKind.section => const NodeTheme(
          fill: AppColors.primary,
          border: AppColors.primary,
          onFillInk: Colors.white,
          textInk: AppColors.ink1,
          accent: AppColors.primary,
        ),
      // 章节：浅蓝底 + 蓝字。白底上 6.9:1
      GraphNodeKind.chapter => const NodeTheme(
          fill: AppColors.primaryWeak,
          border: AppColors.primarySoft,
          onFillInk: AppColors.primaryStrong,
          textInk: AppColors.primaryStrong,
          accent: AppColors.primaryStrong,
        ),
      // 小节（数三的「节」）：浅紫底 + 紫字
      GraphNodeKind.unit => NodeTheme(
          fill: AppColors.purpleWeak,
          border: AppColors.purple.withValues(alpha: 0.35),
          onFillInk: AppColors.purple,
          textInk: AppColors.purple,
          accent: AppColors.purple,
        ),
      // 知识点：白底 + 近黑字 —— **最该读的东西给最深的字**
      GraphNodeKind.leaf => const NodeTheme(
          fill: AppColors.surface,
          border: AppColors.line,
          onFillInk: AppColors.ink1,
          textInk: AppColors.ink1,
          accent: AppColors.ink2,
        ),
    };

/// 角色中文名（图例用）。
String nodeKindLabel(GraphNodeKind k) => switch (k) {
      GraphNodeKind.root => '科目',
      GraphNodeKind.section => '分段',
      GraphNodeKind.chapter => '章节',
      GraphNodeKind.unit => '小节',
      GraphNodeKind.leaf => '知识点',
    };

/// 次要文字（面包屑、说明、计数）的颜色。
///
/// 用 [AppColors.ink2] 而不是 `ink3`：`ink3` 在白底上只有 **3.2:1**，
/// 低于 AA 的 4.5:1 —— 这个项目里 `AppTypography.caption` 用的就是 ink3，
/// 所以在知识点卡片/大纲里凡是"要读的文字"都显式用这个常量。
const Color kSecondaryInk = AppColors.ink2;

/// 考频数字的颜色（高频红、中频橙、其余中性）。
Color weightInk(double? w) {
  if (w == null) return kSecondaryInk;
  if (w >= 0.85) return AppColors.danger;
  if (w >= 0.6) return AppColors.warningInk;
  return kSecondaryInk;
}
