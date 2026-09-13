/// 响应式布局断点系统。
///
/// ## 为什么按宽度而不是按设备判断
/// `if (Platform.isAndroid)` 这种写法会导致：
/// - Windows 窗口被拖窄时布局不变，内容被挤爆
/// - iPad Split View（只占半屏）无法适配
/// - 以后加 macOS / iOS 时到处要改判断
///
/// 按宽度断点则天然覆盖全部场景：手机、平板、Split View、桌面任意窗口尺寸。
///
/// ## 四档断点
/// | 断点 | 宽度 | 布局 | 典型场景 |
/// |---|---|---|---|
/// | compact  | < 600  | 单栏 + 底部导航 | 手机竖屏 |
/// | medium   | 600–900 | 单栏 + 侧边图标条 | 手机横屏 / 平板小窗 |
/// | expanded | 900–1200 | 双栏（列表 + 详情） | iPad 竖屏 / Split View |
/// | large    | ≥ 1200 | 三栏（导航 + 列表 + 详情） | PC / iPad 横屏 |
library;

import 'package:flutter/widgets.dart';

/// 布局断点。
enum LayoutBreakpoint {
  /// 手机竖屏。单栏，底部导航。
  compact,

  /// 手机横屏 / 平板窄窗。单栏 + 侧边图标导航条。
  medium,

  /// iPad 竖屏 / Split View。双栏：列表 + 详情。
  expanded,

  /// PC / iPad 横屏。三栏：导航 + 列表 + 详情。
  large;

  /// 是否显示常驻的左侧导航栏（而非底部 Tab）。
  bool get showSideNavigation => this == expanded || this == large;

  /// 是否同时显示列表与详情（双栏以上）。
  bool get showTwoPane => this == expanded || this == large;

  /// 是否显示第三栏（详情右侧的辅助信息栏）。
  bool get showThreePane => this == large;

  /// 侧边导航是完整文字版还是只有图标。
  bool get sideNavigationHasLabels => this == large;

  /// 列表栏的建议宽度。
  double get listPaneWidth => switch (this) {
        LayoutBreakpoint.expanded => 320,
        LayoutBreakpoint.large => 348,
        _ => double.infinity,
      };

  /// 内容区最大宽度。超宽屏（如 2560px）上限制阅读宽度，避免行长过长。
  double get maxContentWidth => switch (this) {
        LayoutBreakpoint.compact => double.infinity,
        LayoutBreakpoint.medium => 720,
        LayoutBreakpoint.expanded => 900,
        LayoutBreakpoint.large => 1024,
      };
}

/// 断点阈值（逻辑像素）。
class Breakpoints {
  const Breakpoints._();

  static const double compactMax = 600;
  static const double mediumMax = 900;
  static const double expandedMax = 1200;

  /// 由可用宽度解析出断点。
  static LayoutBreakpoint of(double width) {
    if (width < compactMax) return LayoutBreakpoint.compact;
    if (width < mediumMax) return LayoutBreakpoint.medium;
    if (width < expandedMax) return LayoutBreakpoint.expanded;
    return LayoutBreakpoint.large;
  }
}

/// 把当前断点注入 widget 树，供任意层级读取。
///
/// ```dart
/// // 顶层包一次（例如 MaterialApp.builder 或每个页面的根）：
/// ResponsiveScope(
///   builder: (context, bp) => MyScreen(),
/// )
///
/// // 子树内任意位置读取：
/// final bp = BreakpointScope.of(context);
/// if (bp.showTwoPane) { ... }
/// ```
class BreakpointScope extends InheritedWidget {
  final LayoutBreakpoint breakpoint;
  final double width;
  final double height;

  const BreakpointScope({
    super.key,
    required this.width,
    required this.height,
    required this.breakpoint,
    required super.child,
  });

  /// 由尺寸构造，自动推导断点。
  factory BreakpointScope.fromSize({
    Key? key,
    required Size size,
    required Widget child,
  }) =>
      BreakpointScope(
        key: key,
        width: size.width,
        height: size.height,
        breakpoint: Breakpoints.of(size.width),
        child: child,
      );

  /// 读取当前断点（订阅变化，尺寸变化时会重建）。
  static LayoutBreakpoint of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<BreakpointScope>();
    assert(
      scope != null,
      'BreakpointScope 未找到。请在更高层用 ResponsiveScope 或 BreakpointScope.fromSize 包裹。',
    );
    return scope?.breakpoint ?? LayoutBreakpoint.compact;
  }

  /// 读取当前断点但不订阅变化。适合在回调、事件处理里使用。
  static LayoutBreakpoint read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<BreakpointScope>()?.breakpoint ??
      LayoutBreakpoint.compact;

  /// 读取完整尺寸信息（不订阅）。
  static Size? sizeOf(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<BreakpointScope>();
    if (scope == null) return null;
    return Size(scope.width, scope.height);
  }

  @override
  bool updateShouldNotify(BreakpointScope oldWidget) =>
      oldWidget.breakpoint != breakpoint ||
      oldWidget.width != width ||
      oldWidget.height != height;
}

/// 自动读取最近约束并注入 [BreakpointScope] 的便捷组件。
///
/// 页面根节点包一层即可，不需要自己写 `LayoutBuilder`。
class ResponsiveScope extends StatelessWidget {
  final Widget Function(BuildContext context, LayoutBreakpoint bp) builder;

  const ResponsiveScope({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        final bp = Breakpoints.of(width);
        return BreakpointScope(
          width: width,
          height: height,
          breakpoint: bp,
          child: builder(ctx, bp),
        );
      },
    );
  }
}

/// 按断点选择不同 widget。未提供的档位自动向下一档回退。
class BreakpointSwitcher extends StatelessWidget {
  final Widget Function() compact;
  final Widget Function()? medium;
  final Widget Function()? expanded;
  final Widget Function()? large;

  const BreakpointSwitcher({
    super.key,
    required this.compact,
    this.medium,
    this.expanded,
    this.large,
  });

  @override
  Widget build(BuildContext context) {
    final bp = BreakpointScope.of(context);
    return switch (bp) {
      LayoutBreakpoint.compact => compact(),
      LayoutBreakpoint.medium => (medium ?? compact)(),
      LayoutBreakpoint.expanded => (expanded ?? medium ?? compact)(),
      LayoutBreakpoint.large => (large ?? expanded ?? medium ?? compact)(),
    };
  }
}
