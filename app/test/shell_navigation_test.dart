/// 导航外壳 + 页面切换的集成测试。
///
/// ## 为什么必须有这个文件
///
/// 用户在 App 里点「录入」看到的是空白，而 `entry_page_test.dart` 全绿 ——
/// 差别在于后者**直接挂 EntryPage 并手写了一个 `BreakpointScope`**，
/// 把"外壳是否真的提供了断点""切换导航是否真的换页"这些**真实链路**绕过去了。
///
/// 这个文件不绕：挂的就是 `DevShell` 本身，操作就是点击导航项。
/// 凡是"单测绿、真机白"的问题，都得在这里现形。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/providers.dart';
import 'package:kaoyan_math_agent/core/platform/platform_services.dart';
import 'package:kaoyan_math_agent/core/platform/platform_services_mock.dart';
import 'package:kaoyan_math_agent/data/error_causes.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/dev_shell.dart';
import 'package:kaoyan_math_agent/features/entry/entry_page.dart';
import 'package:kaoyan_math_agent/features/knowledge/knowledge_page.dart';

KnowledgeBase _kb() => KnowledgeBase(
      subject: 'math1',
      subjectName: '数学一',
      version: 't',
      nodes: const [
        KnowledgePoint(id: 'math1', name: '数学一', level: 1, isLeaf: false),
        KnowledgePoint(
            id: 'math1.calc', name: '高等数学', level: 2,
            parentId: 'math1', isLeaf: false),
        KnowledgePoint(
            id: 'math1.calc.limit', name: '极限', level: 3,
            parentId: 'math1.calc', isLeaf: false),
        KnowledgePoint(
          id: 'math1.calc.limit.lhopital',
          name: '洛必达法则',
          level: 4,
          parentId: 'math1.calc.limit',
          isLeaf: true,
          examWeight: 0.8,
          definition: '求未定式极限的法则。',
          formulas: ['x'],
        ),
      ],
    );

const _catalog = ErrorCauseCatalog(
  version: 't',
  causes: [
    ErrorCause(
      id: 'concept',
      name: '概念不清',
      short: '概念不清',
      definition: '对适用条件理解错误。',
    ),
  ],
);

/// 挂真实的 DevShell。
Future<void> _pumpShell(
  WidgetTester tester, {
  Size surface = const Size(1440, 900),
}) async {
  // 外壳会读平台能力（决定要不要注册桌面快捷键），所以需要平台服务。
  PlatformServices.install(mockPlatformServices());
  addTearDown(PlatformServices.reset);

  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        knowledgeBaseProvider.overrideWith((ref) async => _kb()),
        errorCauseCatalogProvider.overrideWith((ref) async => _catalog),
      ],
      child: const MaterialApp(home: DevShell()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('外壳能起来，默认停在知识库', (tester) async {
    await _pumpShell(tester);

    expect(find.byType(KnowledgePage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点「录入」真的换到录入页（不是空白）', (tester) async {
    await _pumpShell(tester);

    // 侧边栏的导航项
    await tester.tap(find.text('录入').first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: '切换导航时抛异常 → 真机上就是"什么都没出现"');

    final entry = find.byType(EntryPage);
    expect(entry, findsOneWidget, reason: '录入页没有被挂上');

    // 关键：页面里真的有东西 —— 题干输入框、公式键盘、保存按钮
    expect(find.text('题干'), findsOneWidget);
    expect(find.text('分式'), findsOneWidget, reason: '公式键盘没渲染出来');
    expect(find.textContaining('保存并继续录下一题'), findsOneWidget);
    expect(find.text('题干不能为空'), findsOneWidget, reason: '校验提示没渲染出来');
  });

  testWidgets('连续切换多个 Tab 再回录入，仍然正常', (tester) async {
    await _pumpShell(tester);

    for (final label in ['错题本', '组卷', '今日复习', '录入']) {
      await tester.tap(find.text(label).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '切到「$label」时抛异常');
    }

    expect(find.byType(EntryPage), findsOneWidget);
    expect(find.text('分式'), findsOneWidget);
  });

  testWidgets('窄屏（底部 Tab）也能切到录入', (tester) async {
    await _pumpShell(tester, surface: const Size(420, 860));

    await tester.tap(find.text('录入').first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(EntryPage), findsOneWidget);
    // 窄屏不挂右侧预览
    expect(find.textContaining('渲染器：'), findsNothing);
  });

  testWidgets('宽屏切到录入能看到右侧预览面板', (tester) async {
    await _pumpShell(tester);

    await tester.tap(find.text('录入').first);
    await tester.pumpAndSettle();

    expect(find.text('预览'), findsOneWidget);
    expect(find.textContaining('渲染器：'), findsOneWidget);
  });
}
