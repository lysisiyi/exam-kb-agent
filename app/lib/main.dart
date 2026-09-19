/// 考试知识库 Agent（exam-kb-agent）—— 应用入口。
///
/// 启动顺序（每一步都可能失败，因此都要能优雅降级）：
/// 1. 绑定 Flutter engine
/// 2. 装配平台服务（Windows 真实实现 / 其他平台 Mock）
/// 3. 注入公式渲染器
/// 4. 打开数据库（失败不阻塞 UI，知识库仍可浏览）
/// 5. 启动
library;

import 'dart:io' show Directory, File, FileMode, Platform;

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
import 'core/platform/startup_log.dart';
import 'core/platform/window_setup.dart';
import 'core/theme/app_theme.dart';
import 'data/db/database.dart' show LibraryPaths;
import 'dev_shell.dart';

Future<void> main() async {
  // 启动进度探针。见 `_launchProbe` 的说明 —— 它是"应用走到哪一步死了"
  // 这个问题的唯一可靠答案。
  _launchProbe('main() 进入');

  WidgetsFlutterBinding.ensureInitialized();
  _launchProbe('engine 绑定完成');
  StartupLog.log('engine 绑定完成，开始启动');

  // 尽早接上运行期异常的出口。放在这里而不是最后：日志会先在内存里排队，
  // `StartupLog.bindTo` 之后补写进文件，所以早接不会丢任何一条。
  _installErrorHooks();

  // ── 窗口 ──────────────────────────────────────────────────────────────
  // 给一个合理的起手尺寸并锁住最小尺寸，否则窗口能被拖到比表单还窄。
  // 非桌面平台或插件不可用时静默返回，此时用系统默认尺寸。
  //
  // ⚠️ 这一步**必须是"尽力而为"**：窗口尺寸是体验，不是功能。
  // `initDesktopWindow` 内部已经把每步都包了 try，这里再兜一层，
  // 防止将来有人在里面加出会抛的代码。
  try {
    await initDesktopWindow();
    _launchProbe('窗口初始化完成');
    StartupLog.log('窗口初始化完成');
  } catch (e, st) {
    _launchProbe('窗口初始化失败: $e');
    StartupLog.error('窗口初始化抛异常（不阻断启动）', e, st);
  }

  // ── 数据目录（拿到之后立刻把日志落到文件）───────────────────────────
  try {
    final paths = await LibraryPaths.resolve();
    _launchProbe('数据目录: ${paths.root.path}');
    StartupLog.bindTo(paths.root);
    StartupLog.log('数据目录：${paths.root.path}');
  } catch (e, st) {
    _launchProbe('数据目录失败: $e');
    StartupLog.error('数据目录解析失败（日志暂时只在内存里）', e, st);
  }

  // ── 平台服务 ──────────────────────────────────────────────────────────
  // 失败不能阻止启动：最低限度是"知识库能看、公式能渲染"。
  try {
    await installPlatformServices();
    _launchProbe('平台服务已装配');
    StartupLog.log('平台服务已装配\n${describePlatformCapabilities()}');
  } catch (e, st) {
    // 退回 Mock，保证 App 能起来
    PlatformServices.install(mockPlatformServices());
    _launchProbe('平台服务退回 Mock: $e');
    StartupLog.error('平台服务装配失败，已退回 Mock', e, st);
  }

  // ── 公式渲染 ──────────────────────────────────────────────────────────
  // 底层是 `katex`（KaTeX 的 Flutter 封装：纯 Dart 解析 + CustomPainter
  // 画 Canvas，**不产 SVG**）；外面套一层 `CachedMathRenderer`。
  //
  // ⚠️ **缓存层不能省**。错题本列表 / 复习页走的都是 `renderMarkdown()`，
  // 每一项题干有 3–5 个公式；不缓存就等于滚动时反复解析 LaTeX，
  // 而"5000 题滚动不掉帧"是 V1 的验收项之一。
  MathRendering.install(CachedMathRenderer(const KatexRenderer()));
  _launchProbe('渲染器已注入');

  _launchProbe('准备 runApp');
  runApp(ProviderScope(child: ExamKbApp(initialTab: _initialTabFromEnv())));
  _launchProbe('runApp 已返回');
}

/// 把运行期异常接到 `startup.log` 上（T41）。
///
/// ## 为什么需要
///
/// 启动日志此前只覆盖**启动**链条。应用跑起来之后崩在某个页面里时，
/// 用户看到的只是"点了没反应"或"闪一下就没了" —— 而 Windows release 版
/// 没有 stdout，异常也不一定进事件日志。报障时**零线索**。
///
/// ## 两个钩子分工不同，缺一不可
///
/// | 钩子 | 覆盖 |
/// |---|---|
/// | `FlutterError.onError` | **框架内**的错误：build / layout / paint 抛异常、手势回调里抛异常 |
/// | `PlatformDispatcher.onError` | **框架外**的异步错误：没人 await 的 Future |
///
/// 只接前者会漏掉后者，而后者恰恰是"什么都没发生"那类故障的常见成因
/// （一个没 await 的写库操作失败，界面毫无反应）。
///
/// ## 两个钩子都**不吞**错误
///
/// 写日志是**追加**一条线索，不是替代原有行为：
/// - `FlutterError.onError` 交回框架原来的处理器（debug 下照常画红屏）
/// - `PlatformDispatcher.onError` 返回 `false`（= 未处理），让平台照旧处理。
///   返回 `true` 会让错误**静默消失** —— 那比崩溃更难查。
void _installErrorHooks() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    StartupLog.error(
      '【运行期异常】${details.library ?? 'flutter'}',
      details.exception,
      details.stack,
    );
    previous?.call(details);
  };

  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    StartupLog.error('【未捕获的异步异常】', error, stack);
    return false;
  };
}

/// 启动进度探针：把 [stage] 追加到一行文件里。
///
/// ## 为什么需要它
///
/// Windows 的 release 版 GUI 应用没有 stdout，而**异常退出时也不一定留下
/// 事件日志**（实测：应用程序日志里什么都没有）。于是"应用走到哪一步死了"
/// 从外面完全看不出来 —— 只能靠猜。
///
/// 这个探针只依赖 `dart:io`，不需要任何平台通道，所以它能在启动链条的最前面
/// 和最后面都跑通。**最后写下的那一行就是死点。**
/// 实测靠它定位到 `LibraryPaths.resolve()` 建目录被拒（errno 5）。
///
/// ## 默认关闭
///
/// 随手往系统临时目录写文件不是好习惯，所以默认不开。排查启动问题时设：
///
/// ```powershell
/// $env:DSH_STARTUP_PROBE = "1"; .\kaoyan_math_agent.exe
/// ```
///
/// 输出在 `%TEMP%\dsh_kaoyan_probe\stages.txt`。
void _launchProbe(String stage) {
  if (Platform.environment['DSH_STARTUP_PROBE'] != '1') return;
  try {
    final dir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}dsh_kaoyan_probe',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File('${dir.path}${Platform.pathSeparator}stages.txt').writeAsStringSync(
      '${DateTime.now().toIso8601String()}  $stage\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {
    // 探针写不进去不影响启动
  }
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

class ExamKbApp extends StatelessWidget {
  final int initialTab;

  const ExamKbApp({super.key, this.initialTab = 0});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '考试知识库 Agent',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: DevShell(initialIndex: initialTab),
    );
  }
}
