/// 桌宠悬浮窗（P2，V3_PLAN §5）：独立窗口，主窗口之外的"陪伴面"。
///
/// ## 交互（2026-10-05 用户定稿）
///
/// | 操作 | 行为 |
/// |---|---|
/// | 左键点击（不拖动） | 打开菜单（显示主窗口 / 开始或暂停伴学 / 隐藏 / 关闭） |
/// | 左键拖动 | 移动窗口（整身可拖） |
/// | 右键 | 播放动画（转个圈 + 气泡台词） |
/// | 中键 | 截图记录一条笔记（发给主窗口的伴学管道） |
///
/// ## 架构
///
/// 主窗口是大脑（截图/LLM/落盘都在那边），宠物窗口只是脸：
/// 这里把鼠标动作翻译成方法调用发给主窗口（pet→main 通道），
/// 主窗口用 `recordHotkeySignal` / `companionToggleSignal` 消费；
/// 反向通道（main→pet）推气泡文案。
library;

import 'dart:math' show sin;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/theme/app_theme.dart';

/// 桌宠窗口根。引擎侧已确认 `arguments` 以 `pet` 开头（见 main 的分流）。
class PetWindow extends StatefulWidget {
  /// 皮肤资产文件名（assets/pets/ 下）。null = 默认 zhipu。
  final String? skin;

  const PetWindow({super.key, this.skin});

  @override
  State<PetWindow> createState() => _PetWindowState();
}

class _PetWindowState extends State<PetWindow>
    with WindowListener, SingleTickerProviderStateMixin {
  String _bubble = '左键菜单 · 右键看我转圈 · 中键记一下 ✍';
  late final AnimationController _bounce;
  WindowController? _mainWindow;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _setupWindow();
    _bounce = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 650));
    // main → pet：气泡通道
    WindowController.fromCurrentEngine().then((c) {
      c.setWindowMethodHandler((call) async {
        if (call.method == 'bubble' && mounted) {
          final text = (call.arguments as Map?)?['text']?.toString();
          if (text != null && text.isNotEmpty) {
            setState(() => _bubble = text);
          }
        }
        return null;
      });
    });
    _findMainWindow();
  }

  Future<void> _findMainWindow() async {
    try {
      for (final c in await WindowController.getAll()) {
        if (c.arguments.isEmpty) {
          _mainWindow = c;
          return;
        }
      }
    } catch (_) {}
  }

  Future<void> _toMain(String method, [Map<String, dynamic>? args]) async {
    try {
      final c = _mainWindow ?? await _findMainWindowOf();
      await c?.invokeMethod(method, args);
    } catch (_) {
      // 主窗口不在（例如整个应用只剩桌宠）时静默——交互不因主窗口缺席而崩
    }
  }

  Future<WindowController?> _findMainWindowOf() async {
    for (final c in await WindowController.getAll()) {
      if (c.arguments.isEmpty) return c;
    }
    return null;
  }

  Future<void> _setupWindow() async {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(190, 240),
        minimumSize: Size(190, 240),
        maximumSize: Size(190, 240),
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: false,
        alwaysOnTop: true,
        skipTaskbar: true,
        backgroundColor: Colors.transparent,
      ),
      () async {
        await windowManager.show();
      },
    );
  }

  /// 右键：播放动画（缩放 + 摆动 0.65s），并把气泡切到动画台词。
  void _playAnimation() {
    setState(() => _bubble = '看我转个圈～ 🌀');
    _bounce.forward(from: 0).then((_) {
      if (mounted) {
        setState(() => _bubble = '转完啦，继续陪你学 ✨');
      }
    });
  }

  /// 中键：截图记录（交给主窗口的伴学管道）。
  void _record() {
    setState(() => _bubble = '记一下！📸 截图交给主窗口处理');
    _toMain('record');
  }

  /// 左键：菜单。
  Future<void> _openMenu(TapDownDetails pos) async {
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        pos.globalPosition.dx,
        pos.globalPosition.dy,
        pos.globalPosition.dx,
        pos.globalPosition.dy,
      ),
      items: const [
        PopupMenuItem(value: 'main', child: Text('显示主窗口')),
        PopupMenuItem(value: 'toggle', child: Text('开始 / 暂停伴学')),
        PopupMenuItem(value: 'hide', child: Text('隐藏桌宠（可在学习台重新召唤）')),
        PopupMenuItem(value: 'close', child: Text('关闭桌宠窗口')),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'main':
        await _toMain('showMain');
      case 'toggle':
        setState(() => _bubble = '伴学开关已交给主窗口');
        await _toMain('toggleCompanion');
      case 'hide':
        await windowManager.hide();
      case 'close':
        await windowManager.destroy();
      default:
        break;
    }
  }

  @override
  void dispose() {
    _bounce.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: Listener(
          // 中键/右键：Listener 才能拿到非主键（GestureDetector 只认主键）
          onPointerDown: (e) {
            if (e.buttons == kMiddleMouseButton) {
              _record();
            } else if (e.buttons == kSecondaryMouseButton) {
              _playAnimation();
            }
          },
          child: GestureDetector(
            // 左键点击（未拖动）→ 菜单；拖动 → 移动窗口
            onTapDown: _openMenu,
            onPanStart: (_) => windowManager.startDragging(),
            child: ColoredBox(
              color: Colors.transparent,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(color: AppColors.line),
                      boxShadow: AppShadows.s2,
                    ),
                    child: Text(_bubble,
                        style: const TextStyle(fontSize: 11.5, height: 1.4)),
                  ),
                  // 右键动画：缩放 + 摆动
                  AnimatedBuilder(
                    animation: _bounce,
                    builder: (context, child) {
                      final t = _bounce.value;
                      final scale =
                          1 + 0.18 * sin(t * 3.14159).abs().clamp(0.0, 1.0);
                      final angle = 0.20 * sin(t * 6.28318);
                      return Transform.rotate(
                        angle: angle,
                        child: Transform.scale(scale: scale, child: child),
                      );
                    },
                    child: Image.asset(
                        'assets/pets/${widget.skin ?? 'zhipu.png'}',
                        width: 130,
                        fit: BoxFit.contain),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
