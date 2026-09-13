/// 桌面窗口初始化。
///
/// ## 为什么需要它
///
/// 没有它时，Windows 上窗口可以被拖到比内容还窄 —— 录入页的表单会被压到
/// 只剩一条缝，看起来像"界面坏了"。宽度断点（`core/layout/breakpoints.dart`）
/// 只能换布局，不能阻止窗口被拖到不可用。
///
/// 所以这里做两件事：**起手给一个合理尺寸**，**设一个最小尺寸**。
///
/// ## 为什么单独一个文件、且要可注入
///
/// 这段代码只在 `main()` 里跑一次，而 `main()` 是测试覆盖不到的地方
/// （测试不经过它 —— 这正是"两个编译错误全绿通过"那次事故的原因，
/// 见 PROGRESS T21）。把策略抽成可注入的小函数，就能把"策略是什么"
/// 和"插件在真机上是否响应"分开对待。
///
/// ## 失败必须静默降级
///
/// 窗口尺寸是**体验**，不是功能。拿不到窗口管理器时（非桌面平台、
/// 插件未注册、平台通道异常）绝不能阻止 App 启动 ——
/// 用户宁可看到一个小窗口，也不要看到一个起不来的应用。
library;

// `Size` 来自 dart:ui（`window_manager` 的签名用的也是它）。
// 这里不引 `package:flutter/material.dart` —— 一个平台辅助文件
// 不该把整个 widget 层拉进来。
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import 'capabilities.dart';

/// 最小窗口尺寸。
///
/// 420 宽略小于 compact 断点（600），也就是允许用户拖到"手机竖屏"布局，
/// 但不再更窄 —— 再窄题干就会折成很难读的窄条。
const Size kMinWindowSize = Size(420, 600);

/// 起手窗口尺寸。
const Size kPreferredWindowSize = Size(1280, 840);

/// 初始化桌面窗口。非桌面平台、或插件不可用时**静默返回**。
///
/// 生产调用点不要传参。传参只用于测试：
/// [isDesktop] 覆盖平台判定，[ensureInitialized] / [setMinimumSize] /
/// [readyToShow] 覆盖插件调用。
Future<void> initDesktopWindow({
  bool? isDesktop,
  Future<void> Function()? ensureInitialized,
  Future<void> Function(Size minSize)? setMinimumSize,
  Future<void> Function(WindowOptions options)? readyToShow,
}) async {
  if (!(isDesktop ?? PlatformCapabilities.isDesktopOS)) return;

  // 三步各自独立地失败。合在一个 try 里的话，"设最小尺寸"失败会连
  // "显示窗口"一起跳过 —— 结果是一个尺寸不受约束的窗口，
  // 而这恰恰是这段代码要防的事。
  await _guard('初始化', ensureInitialized ?? windowManager.ensureInitialized);
  await _guard(
    '设置最小尺寸',
    () => (setMinimumSize ?? windowManager.setMinimumSize)(kMinWindowSize),
  );
  await _guard(
    '显示窗口',
    () => (readyToShow ?? _defaultReadyToShow)(_windowOptions),
  );
}

/// 跑一步窗口操作，失败只记日志。
///
/// 见类文档：窗口尺寸是体验，不是功能，绝不能阻止 App 启动。
Future<void> _guard(String step, Future<void> Function() action) async {
  try {
    await action();
  } catch (e) {
    debugPrint('[窗口] $step 失败，沿用系统默认：$e');
  }
}

const WindowOptions _windowOptions = WindowOptions(
  size: kPreferredWindowSize,
  center: true,
  minimumSize: kMinWindowSize,
  title: '考研数学错题 Agent',
);

Future<void> _defaultReadyToShow(WindowOptions options) =>
    windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
