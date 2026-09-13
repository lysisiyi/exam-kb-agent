/// 自适应导航外壳。
///
/// 同一份代码在四档断点下呈现不同导航形态：
///
/// | 断点 | 导航 | 场景 |
/// |---|---|---|
/// | compact  | 底部 Tab | 手机竖屏 |
/// | medium   | 左侧图标条（NavigationRail） | 手机横屏 / 窄窗 |
/// | expanded | 左侧图标 + 文字 | iPad 竖屏 / Split View |
/// | large    | 左侧完整侧边栏 | PC / iPad 横屏 |
///
/// 桌面端额外获得：键盘快捷键、悬停高亮、工具提示。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../layout/breakpoints.dart';
import '../platform/capabilities.dart';
import '../theme/app_theme.dart';

/// 一个导航目的地。
class NavDestination {
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final String? shortcutHint;
  final int? badgeCount;

  /// 惰性构建页面，避免一次性创建所有页面。
  final Widget Function() builder;

  const NavDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.builder,
    this.shortcutHint,
    this.badgeCount,
  });
}

/// 自适应导航外壳。
class AdaptiveShell extends StatefulWidget {
  final List<NavDestination> destinations;
  final int initialIndex;
  final String appTitle;

  /// 侧边栏底部的用户信息区（可选）。
  final Widget? sidebarFooter;

  const AdaptiveShell({
    super.key,
    required this.destinations,
    this.initialIndex = 0,
    this.appTitle = '数学错题 Agent',
    this.sidebarFooter,
  });

  @override
  State<AdaptiveShell> createState() => _AdaptiveShellState();
}

class _AdaptiveShellState extends State<AdaptiveShell> {
  late int _index = widget.initialIndex;
  final _focusNode = FocusNode(debugLabel: 'adaptive-shell');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _select(int i) {
    if (i < 0 || i >= widget.destinations.length || i == _index) return;
    setState(() => _index = i);
  }

  /// 处理键盘快捷键：Ctrl+1..9 切换导航。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (!HardwareKeyboard.instance.isControlPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    for (var i = 0; i < widget.destinations.length && i < 9; i++) {
      if (key == LogicalKeyboardKey(0x00000031 + i)) {
        _select(i);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return ResponsiveScope(
      builder: (context, bp) {
        final body = IndexedStack(
          index: _index,
          children: [
            for (var i = 0; i < widget.destinations.length; i++)
              // 未访问过的页面不构建，省内存也不做无谓的 IO
              _LazyPage(builder: widget.destinations[i].builder, active: i == _index),
          ],
        );

        final content = switch (bp) {
          LayoutBreakpoint.compact => _buildCompact(body, bp),
          LayoutBreakpoint.medium => _buildMedium(body, bp),
          LayoutBreakpoint.expanded ||
          LayoutBreakpoint.large =>
            _buildExpanded(body, bp),
        };

        // 桌面端注册快捷键
        if (PlatformCapabilities.usesDesktopInteractions) {
          return Focus(
            focusNode: _focusNode,
            autofocus: true,
            onKeyEvent: _onKey,
            child: content,
          );
        }
        return content;
      },
    );
  }

  // ── compact：底部 Tab ──────────────────────────────────────────────────

  Widget _buildCompact(Widget body, LayoutBreakpoint bp) {
    return Scaffold(
      body: SafeArea(bottom: false, child: body),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.line)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 62,
            child: Row(
              children: [
                for (var i = 0; i < widget.destinations.length; i++)
                  Expanded(child: _compactItem(i)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _compactItem(int i) {
    final d = widget.destinations[i];
    final selected = i == _index;
    final color = selected ? AppColors.primary : AppColors.ink4;

    return InkWell(
      onTap: () => _select(i),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _BadgedIcon(
            icon: selected ? d.selectedIcon : d.icon,
            color: color,
            count: d.badgeCount,
            size: 23,
          ),
          const SizedBox(height: 4),
          Text(
            d.label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  // ── medium：图标导航条 ─────────────────────────────────────────────────

  Widget _buildMedium(Widget body, LayoutBreakpoint bp) {
    return Scaffold(
      body: Row(
        children: [
          Container(
            width: 76,
            color: AppColors.sidebar,
            child: Column(
              children: [
                const SizedBox(height: 14),
                _AppMark(compact: true),
                const SizedBox(height: 14),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [
                      for (var i = 0; i < widget.destinations.length; i++)
                        _railItem(i),
                    ],
                  ),
                ),
                if (widget.sidebarFooter != null) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: widget.sidebarFooter,
                  ),
                ],
              ],
            ),
          ),
          const VerticalDivider(width: 1, color: AppColors.line),
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _railItem(int i) {
    final d = widget.destinations[i];
    final selected = i == _index;
    final color = selected ? AppColors.primaryStrong : AppColors.ink2;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? AppColors.primaryWeak : Colors.transparent,
        borderRadius: AppRadius.rMd,
        child: InkWell(
          borderRadius: AppRadius.rMd,
          onTap: () => _select(i),
          child: SizedBox(
            height: 54,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _BadgedIcon(
                  icon: selected ? d.selectedIcon : d.icon,
                  color: color,
                  count: d.badgeCount,
                  size: 21,
                ),
                const SizedBox(height: 3),
                Text(
                  d.label,
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── expanded / large：完整侧边栏 ───────────────────────────────────────

  Widget _buildExpanded(Widget body, LayoutBreakpoint bp) {
    final showLabels = bp.sideNavigationHasLabels;
    final width = showLabels ? 216.0 : 84.0;

    return Scaffold(
      body: Row(
        children: [
          Container(
            width: width,
            color: AppColors.sidebar,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 16, 12, 14),
                  child: _AppMark(compact: !showLabels),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    children: [
                      for (var i = 0; i < widget.destinations.length; i++)
                        showLabels ? _sideItem(i, showLabels: true) : _railItem(i),
                    ],
                  ),
                ),
                if (widget.sidebarFooter != null) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                    child: widget.sidebarFooter,
                  ),
                ],
              ],
            ),
          ),
          const VerticalDivider(width: 1, color: AppColors.line),
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _sideItem(int i, {required bool showLabels}) {
    final d = widget.destinations[i];
    final selected = i == _index;
    final color = selected ? AppColors.primaryStrong : AppColors.ink2;

    final tile = Material(
      color: selected ? AppColors.primaryWeak : Colors.transparent,
      borderRadius: AppRadius.rMd,
      child: InkWell(
        borderRadius: AppRadius.rMd,
        onTap: () => _select(i),
        hoverColor: AppColors.surface2,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          child: Row(
            children: [
              Icon(
                selected ? d.selectedIcon : d.icon,
                size: 19,
                color: color,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  d.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
              if (d.badgeCount != null && d.badgeCount! > 0)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: selected ? AppColors.primary : AppColors.danger,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${d.badgeCount}',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              if (d.shortcutHint != null && d.badgeCount == null) ...[
                const SizedBox(width: 6),
                Text(
                  d.shortcutHint!,
                  style: const TextStyle(fontSize: 10, color: AppColors.ink4),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: showLabels ? tile : Tooltip(message: d.label, child: tile),
    );
  }
}

/// 惰性页面：只在首次可见时构建，之后保留状态。
///
/// ⚠️ `IndexedStack` 会构建它的**所有**子节点，所以"懒惰"必须由这里实现，
/// 不能指望 `IndexedStack`。把 [active] 去掉（写成常量 `true`）会让每个 Tab
/// 在启动时全部构建：知识库、复习、错题本三个页面同时开始各自的异步加载，
/// 既拖慢启动，也让"某个页面一打开就崩"更难定位。
class _LazyPage extends StatefulWidget {
  final Widget Function() builder;

  /// 是否至少被选中过一次。
  final bool active;

  const _LazyPage({required this.builder, required this.active});

  @override
  State<_LazyPage> createState() => _LazyPageState();
}

class _LazyPageState extends State<_LazyPage> {
  Widget? _child;

  @override
  Widget build(BuildContext context) {
    if (widget.active) _child ??= widget.builder();
    return _child ?? const SizedBox.shrink();
  }
}

/// 带角标的图标。
class _BadgedIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final int? count;
  final double size;

  const _BadgedIcon({
    required this.icon,
    required this.color,
    this.count,
    this.size = 22,
  });

  @override
  Widget build(BuildContext context) {
    if (count == null || count! <= 0) {
      return Icon(icon, size: size, color: color);
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon, size: size, color: color),
        Positioned(
          right: -6,
          top: -4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
            decoration: BoxDecoration(
              color: AppColors.danger,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              count! > 99 ? '99+' : '$count',
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                height: 1.3,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 应用标识。
class _AppMark extends StatelessWidget {
  final bool compact;

  const _AppMark({this.compact = false});

  @override
  Widget build(BuildContext context) {
    final mark = Container(
      width: 31,
      height: 31,
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(9),
      ),
      alignment: Alignment.center,
      child: const Text(
        'M',
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );

    if (compact) return Center(child: mark);

    return Row(
      children: [
        mark,
        const SizedBox(width: 9),
        const Expanded(
          child: Text(
            '数学错题 Agent',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}
