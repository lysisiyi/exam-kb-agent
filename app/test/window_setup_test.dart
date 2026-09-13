/// 桌面窗口初始化测试。
///
/// ## 为什么这段代码需要测试
///
/// 它只在 `main()` 里跑一次，而 `main()` 是**测试覆盖不到的地方** ——
/// 项目已经因此吃过一次亏：`lib/main.dart` 有两个编译错误，
/// 而 295 个测试全绿（见 PROGRESS T21）。窗口初始化比那两个错误更隐蔽：
/// 它不会编译失败，只会在真机上"窗口尺寸不对"或"应用起不来"。
///
/// 所以把策略抽成 `initDesktopWindow()` 并注入假的插件调用，验证三件事：
/// **非桌面平台不碰插件**、**桌面平台会设最小尺寸**、
/// **插件抛异常时不影响启动**。
library;

import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/platform/window_setup.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  group('窗口初始化', () {
    test('非桌面平台完全不碰插件', () async {
      var ensured = false;
      var sized = false;

      await initDesktopWindow(
        isDesktop: false,
        ensureInitialized: () async => ensured = true,
        setMinimumSize: (_) async => sized = true,
        readyToShow: (_) async {},
      );

      expect(ensured, isFalse, reason: '移动端没有窗口概念，不该调窗口插件');
      expect(sized, isFalse);
    });

    test('桌面平台会锁最小尺寸，并带上起手尺寸', () async {
      Size? applied;
      WindowOptions? shown;

      await initDesktopWindow(
        isDesktop: true,
        ensureInitialized: () async {},
        setMinimumSize: (s) async => applied = s,
        readyToShow: (o) async => shown = o,
      );

      expect(applied, kMinWindowSize);
      expect(shown, isNotNull);
      expect(shown!.size, kPreferredWindowSize);
      expect(shown!.minimumSize, kMinWindowSize);
      expect(shown!.center, isTrue);
    });

    test('最小尺寸必须容得下 compact 断点下的表单', () {
      // 420 是刻意选的：略小于 compact 断点 600，允许"手机竖屏"布局，
      // 但不允许窄到把题干折成难读的窄条。这条断言是防止有人把它调小。
      expect(kMinWindowSize.width, greaterThanOrEqualTo(400));
      expect(kMinWindowSize.height, greaterThanOrEqualTo(560));
      expect(kPreferredWindowSize.width, greaterThan(kMinWindowSize.width));
    });

    test('插件抛异常时静默降级 —— 窗口尺寸是体验，不是功能', () async {
      // 不抛出去就算通过：抛了的话 App 就起不来了
      await initDesktopWindow(
        isDesktop: true,
        ensureInitialized: () async => throw StateError('插件未注册'),
        setMinimumSize: (_) async {},
        readyToShow: (_) async {},
      );
    });

    test('某一步失败不拖累后续步骤', () async {
      // 三步各自独立地失败。合在一个 try 里的话，"设最小尺寸"失败会连
      // "显示窗口"一起跳过 —— 那会留下一个尺寸不受约束的窗口，
      // 而这正是这段代码要防的事。
      WindowOptions? shown;

      await initDesktopWindow(
        isDesktop: true,
        ensureInitialized: () async {},
        setMinimumSize: (_) async => throw StateError('平台通道异常'),
        readyToShow: (o) async => shown = o,
      );

      expect(shown, isNotNull, reason: '前一步失败不该阻止窗口被显示出来');
    });
  });
}
