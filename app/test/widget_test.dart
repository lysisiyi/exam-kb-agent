/// 应用骨架的冒烟测试。
///
/// 原始的 `widget_test.dart` 由 `flutter create` 生成，引用的是模板里的 `MyApp`
/// 与计数器示例，本项目并不存在这些内容。这里替换成针对真实入口的测试。
///
/// 目的：确认主题能构建、响应式外壳在两个极端断点下都不抛异常。
/// 这是「地基」级别的验证 —— 一旦挂了，说明平台抽象层或断点系统出了问题。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/platform/platform_services.dart';
import 'package:kaoyan_math_agent/core/platform/platform_services_mock.dart';
import 'package:kaoyan_math_agent/core/theme/app_theme.dart';
import 'package:kaoyan_math_agent/dev_shell.dart';

void main() {
  setUp(() {
    // 测试环境注入 Mock 平台服务，避免依赖真机能力。
    PlatformServices.reset();
    PlatformServices.install(mockPlatformServices());
  });

  tearDown(PlatformServices.reset);

  test('主题能构建且关键 token 到位', () {
    final theme = AppTheme.light();
    expect(theme.useMaterial3, isTrue);
    expect(theme.colorScheme.primary, AppColors.primary);
    expect(theme.scaffoldBackgroundColor, AppColors.bg);
  });

  testWidgets('导航外壳能渲染（compact 断点：手机竖屏）', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const DevShell(),
        ),
      ),
    );
    await tester.pump();

    // 底部导航应出现「错题本」标签
    expect(find.text('错题本'), findsWidgets);
  });

  testWidgets('导航外壳能渲染（large 断点：PC 三栏）', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const DevShell(),
        ),
      ),
    );
    await tester.pump();

    // 侧边栏应显示应用名
    expect(find.text('数学错题 Agent'), findsWidgets);
  });
}
