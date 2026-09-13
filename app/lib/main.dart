/// 考研数学错题 Agent —— 应用入口。
///
/// 启动顺序（每一步都可能失败，因此都要能优雅降级）：
/// 1. 绑定 Flutter engine
/// 2. 装配平台服务（Windows 真实实现 / 其他平台 Mock）
/// 3. 注入公式渲染器
/// 4. 打开数据库（失败不阻塞 UI，知识库仍可浏览）
/// 5. 启动
library;

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/math/katex_renderer.dart';
import 'core/math/math_renderer.dart';
import 'core/platform/platform_bootstrap.dart';
import 'core/platform/platform_services.dart';
// ⚠️ 必须直接 import：Dart 不允许使用"传递性导入"里的符号，
// `platform_bootstrap.dart` 内部用了 mockPlatformServices 不等于本文件能用。
// 少了这一行会编译失败（lib/main.dart 报 undefined_function），
// 而 `flutter test` 不会发现 —— 测试不经过 main()。
import 'core/platform/platform_services_mock.dart';
import 'core/platform/window_setup.dart';
import 'core/theme/app_theme.dart';
import 'dev_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── 窗口 ──────────────────────────────────────────────────────────────
  // 给一个合理的起手尺寸并锁住最小尺寸，否则窗口能被拖到比表单还窄。
  // 非桌面平台或插件不可用时静默返回，此时用系统默认尺寸。
  await initDesktopWindow();

  // ── 平台服务 ──────────────────────────────────────────────────────────
  // 失败不能阻止启动：最低限度是"知识库能看、公式能渲染"。
  try {
    await installPlatformServices();
    debugPrint('[启动] 平台服务已装配\n${describePlatformCapabilities()}');
  } catch (e, st) {
    // 退回 Mock，保证 App 能起来
    PlatformServices.install(mockPlatformServices());
    debugPrint('[启动] 平台服务装配失败，已退回 Mock：$e\n$st');
  }

  // ── 公式渲染 ──────────────────────────────────────────────────────────
  // 底层是 `katex`（KaTeX 的 Flutter 封装：纯 Dart 解析 + CustomPainter
  // 画 Canvas，**不产 SVG**）；外面套一层 `CachedMathRenderer`。
  //
  // ⚠️ **缓存层不能省**。错题本列表 / 复习页走的都是 `renderMarkdown()`，
  // 每一项题干有 3–5 个公式；不缓存就等于滚动时反复解析 LaTeX，
  // 而"5000 题滚动不掉帧"是 V1 的验收项之一。
  MathRendering.install(CachedMathRenderer(const KatexRenderer()));

  runApp(ProviderScope(child: KaoyanApp(initialTab: _initialTabFromEnv())));
}

/// 开发期开关：`DSH_INITIAL_TAB=3` 让 App 直接开在「录入」页。
///
/// 存在的理由：本项目的界面在自动化环境里**无法交互**（GUI 进程会被回收），
/// 所以"某页一打开就崩"只能靠人去点。有了它，直接开在目标页就能抓到真实报错。
/// 解析失败一律退回 0，绝不让一个环境变量把 App 弄崩。
int _initialTabFromEnv() {
  final raw = Platform.environment['DSH_INITIAL_TAB'];
  if (raw == null) return 0;
  final n = int.tryParse(raw.trim());
  if (n == null || n < 0) return 0;
  return n;
}

class KaoyanApp extends StatelessWidget {
  final int initialTab;

  const KaoyanApp({super.key, this.initialTab = 0});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '考研数学错题 Agent',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: DevShell(initialIndex: initialTab),
    );
  }
}
