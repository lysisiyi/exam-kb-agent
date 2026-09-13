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
///
/// ## 为什么这里用假页面而不是真页面
///
/// 复习页和错题本页在 `initState` / 首次构建时就会开异步加载（读 sqlite、
/// 扫 Markdown 目录）。测试环境里没有 `path_provider` 的平台通道，
/// 真实的 `openDefaultDatabase()` 会一直挂着 —— 页面停在
/// `CircularProgressIndicator` 上，而 `pumpAndSettle` 等的是"动画停下来"，
/// 于是它永远不返回（表现为超时挂死，看起来很像"页面崩了"）。
///
/// 这个文件要验的是**导航外壳**：断点分档、点击换页、快捷键、侧边栏。
/// 那与页面里加载了什么无关，所以这里挂假的页面 —— 每个页面都**同步**
/// 渲染内容，不产生 spinner，不产生定时器。
///
/// 真页面由各自的测试文件覆盖：
/// `entry_page_test.dart` / `entry_flow_test.dart` / `problems_page_test.dart` /
/// `review_page_test.dart`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/platform/platform_services.dart';
import 'package:kaoyan_math_agent/core/platform/platform_services_mock.dart';
import 'package:kaoyan_math_agent/core/widgets/adaptive_shell.dart';
import 'package:kaoyan_math_agent/dev_shell.dart';
import 'package:kaoyan_math_agent/features/entry/entry_page.dart';
import 'package:kaoyan_math_agent/features/knowledge/knowledge_page.dart';
import 'package:kaoyan_math_agent/features/problems/problems_page.dart';
import 'package:kaoyan_math_agent/features/review/review_page.dart';

/// 一个同步渲染、零异步的假页面。
class _StubPage extends StatelessWidget {
  final String label;

  const _StubPage(this.label);

  @override
  Widget build(BuildContext context) => Center(child: Text('内容：$label'));
}

/// 某个 Tab 的页面是否**已经被构建过**。
///
/// 断言的是"外壳的惰性挂载策略"，而不是"页面上有没有字"：
/// `IndexedStack` 里切走的页面仍在树上（`Visibility.maintain` 用
/// `Opacity(0)` 而不是 `Offstage`），按 widget 类型数是最直接的。
///
/// 这里不去碰 `_LazyPage`（私有类型，测试里看不到）：
/// 直接数**页面自己**的 widget 实例即可，`_LazyPage` 只是手段。
Finder _pageOf(String label) => find.byWidgetPredicate(
      (w) => w is _StubPage && w.label == label,
      description: '假页面「$label」',
      skipOffstage: false,
    );

/// 挂一个使用假页面的外壳，全部异步依赖都不涉及。
Future<void> _pumpShell(
  WidgetTester tester, {
  Size surface = const Size(1440, 900),
  bool realShell = false,
}) async {
  // 外壳会读平台能力（决定要不要注册桌面快捷键），所以需要平台服务。
  PlatformServices.install(mockPlatformServices());
  addTearDown(PlatformServices.reset);

  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: realShell
            ? const DevShell()
            : AdaptiveShell(
                destinations: [
                  NavDestination(
                    label: '知识库',
                    icon: Icons.account_tree_outlined,
                    selectedIcon: Icons.account_tree,
                    builder: () => const _StubPage('知识库'),
                  ),
                  NavDestination(
                    label: '今日复习',
                    icon: Icons.home_outlined,
                    selectedIcon: Icons.home,
                    shortcutHint: 'Ctrl+2',
                    builder: () => const _StubPage('今日复习'),
                  ),
                  NavDestination(
                    label: '错题本',
                    icon: Icons.menu_book_outlined,
                    selectedIcon: Icons.menu_book,
                    shortcutHint: 'Ctrl+3',
                    builder: () => const _StubPage('错题本'),
                  ),
                  NavDestination(
                    label: '录入',
                    icon: Icons.add_box_outlined,
                    selectedIcon: Icons.add_box,
                    shortcutHint: 'Ctrl+4',
                    builder: () => const _StubPage('录入'),
                  ),
                  NavDestination(
                    label: '组卷',
                    icon: Icons.description_outlined,
                    selectedIcon: Icons.description,
                    shortcutHint: 'Ctrl+5',
                    builder: () => const _StubPage('组卷'),
                  ),
                ],
              ),
      ),
    ),
  );
  if (realShell) {
    // 真页面里有始终在动的指示器（循环进度条），`pumpAndSettle` 会永远等下去
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  } else {
    await tester.pumpAndSettle();
  }
}

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  group('外壳导航', () {
    testWidgets('外壳能起来，默认停在知识库', (tester) async {
      await _pumpShell(tester);

      expect(find.text('内容：知识库'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点导航项真的换页（不是空白）', (tester) async {
      await _pumpShell(tester);

      await tester.tap(find.text('录入').first);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: '切换导航时抛异常 → 真机上就是"什么都没出现"');
      expect(find.text('内容：录入'), findsOneWidget);
    });

    testWidgets('连续切换多个 Tab，每次都有内容', (tester) async {
      await _pumpShell(tester);

      for (final label in ['错题本', '组卷', '今日复习', '录入']) {
        await tester.tap(find.text(label).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '切到「$label」时抛异常');
        expect(find.text('内容：$label'), findsOneWidget,
            reason: '「$label」页没有渲染出内容');
      }
    });

    testWidgets('未访问过的页面不构建（惰性挂载）', (tester) async {
      await _pumpShell(tester);

      // 启动时只构建了知识库；其余四个 Tab 一次都没点过。
      expect(_pageOf('知识库'), findsOneWidget);
      for (final label in ['今日复习', '错题本', '录入', '组卷']) {
        expect(_pageOf(label), findsNothing,
            reason: '「$label」还没被点过就被构建了 —— 启动会白做一堆 IO');
      }

      await tester.tap(find.text('错题本').first);
      await tester.pumpAndSettle();
      expect(find.text('内容：错题本'), findsOneWidget);
      expect(_pageOf('错题本'), findsOneWidget);

      // 切回去：错题本的子树**仍然在树上**（`IndexedStack` 保留状态），
      // 只是变成不可见（`Visibility.maintain` 用透明度而不是 offstage）
      await tester.tap(find.text('知识库').first);
      await tester.pumpAndSettle();
      expect(find.text('内容：知识库'), findsOneWidget);
      expect(_pageOf('错题本'), findsOneWidget,
          reason: 'IndexedStack 应当保留已构建页面的状态');
    });

    testWidgets('窄屏（底部 Tab）也能切页', (tester) async {
      await _pumpShell(tester, surface: const Size(420, 860));

      await tester.tap(find.text('录入').first);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('内容：录入'), findsOneWidget);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('DevShell 真的挂上了页面（不是占位页）', () {
    testWidgets('每个导航项都指向真实页面类型', (tester) async {
      await _pumpShell(tester, realShell: true);

      final shell = tester.widget<AdaptiveShell>(find.byType(AdaptiveShell));
      final built = {
        for (final d in shell.destinations) d.label: d.builder().runtimeType,
      };

      // 这一条同时守住"占位页有没有被忘掉换掉"：
      // 复习和错题本在 M5 换成了真页面，组卷还是 M6 的占位页
      expect(built['知识库'], KnowledgePage);
      expect(built['今日复习'], ReviewPage);
      expect(built['错题本'], ProblemsPage);
      expect(built['录入'], EntryPage);
      expect(built['组卷'], isNot(EntryPage));

      // builder 每次调用都该给新实例（`_LazyPage` 只在首次构建时调用一次，
      // 之后复用同一个 widget —— 所以这里必须是新实例，不能是同一个常量）
      expect(shell.destinations[3].builder(), isA<EntryPage>());
    });

    testWidgets('真外壳里切到录入能挂上 EntryPage', (tester) async {
      await _pumpShell(tester, realShell: true);

      expect(find.byType(EntryPage), findsNothing, reason: '启动了但不是当前页');

      await tester.tap(find.text('录入').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull,
          reason: '切换导航时抛异常 → 真机上就是"什么都没出现"');
      expect(find.byType(EntryPage), findsOneWidget, reason: '录入页没有被挂上');

      // 录入页内部的渲染细节（公式键盘、预览面板、校验提示）
      // 由 `entry_page_test.dart` 覆盖；这里只验"外壳真的把它挂上了"。
    });
  });
}
