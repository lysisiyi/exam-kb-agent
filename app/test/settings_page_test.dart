/// 设置页测试。
///
/// ## 这一页容易出的错不是崩溃，而是"说了不该说的话"
///
/// 它是用户唯一能看到"我的数据在哪、导出到底导出了什么"的地方，
/// 所以断言的重点是**文案的诚实度**：
/// - 必须说清导出是只读快照（否则用户以为能双向同步）
/// - 必须点明复习进度只在本地数据库（否则用户以为导出=完整备份）
/// - 三条路径必须真的显示出来（用户要能自己去那个文件夹看）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/layout/breakpoints.dart';
import 'package:kaoyan_math_agent/core/providers.dart';
import 'package:kaoyan_math_agent/features/settings/settings_page.dart';

import 'support/test_env.dart';

void main() {
  late TempLibrary env;

  Future<void> seed(WidgetTester tester) async {
    await tester.runAsync(() async {
      env = await TempLibrary.create();
      await seedProblems(env, [
        const SeedProblem(id: 'p-1', stem: '一题', wrongCount: 2),
      ]);
    });
    addTearDown(() async {
      await tester.runAsync(env.dispose);
    });
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) async => env.db),
          problemStoreProvider.overrideWith((ref) async => env.store),
          libraryPathsProvider.overrideWith((ref) async => env.paths),
        ],
        child: BreakpointScope.fromSize(
          size: const Size(1100, 900),
          child: const MaterialApp(home: Scaffold(body: SettingsPage())),
        ),
      ),
    );
    // 路径是异步读的，多推几帧让它落地
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('页面能起来并给出导出入口', (tester) async {
    await seed(tester);
    await pump(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('导出题库'), findsOneWidget);
    expect(find.textContaining('选择文件夹并导出'), findsOneWidget);
  });

  testWidgets('如实说明"只读快照"与"复习进度只在本地"', (tester) async {
    await seed(tester);
    await pump(tester);

    expect(find.textContaining('只读快照'), findsOneWidget,
        reason: '不说这句，用户会以为导出后能在 Obsidian 里双向编辑');
    expect(find.textContaining('复习进度'), findsWidgets,
        reason: '不说这句，用户会以为导出=完整备份，换电脑才发现进度没了');
  });

  testWidgets('说明 Obsidian 不需要插件', (tester) async {
    await seed(tester);
    await pump(tester);

    expect(find.textContaining('Obsidian'), findsWidgets);
    expect(find.textContaining('不需要装插件'), findsOneWidget);
  });

  testWidgets('三条数据路径都显示出来，且可选中复制', (tester) async {
    await seed(tester);
    await pump(tester);

    // 路径是 SelectableText，用户要能复制走
    final selectables = tester.widgetList<SelectableText>(
      find.byType(SelectableText),
    );
    final texts = selectables.map((s) => s.data ?? '').toList();
    expect(texts.any((t) => t.endsWith('problems')), isTrue,
        reason: '题目目录要显示出来');
    expect(texts.any((t) => t.endsWith('images')), isTrue,
        reason: '图片目录要显示出来');
    expect(texts.any((t) => t.endsWith('index.sqlite')), isTrue,
        reason: '索引库路径要显示出来（备份进度靠它）');
  });

  testWidgets('窄屏不溢出', (tester) async {
    await seed(tester);
    tester.view.physicalSize = const Size(420, 860);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) async => env.db),
          problemStoreProvider.overrideWith((ref) async => env.store),
          libraryPathsProvider.overrideWith((ref) async => env.paths),
        ],
        child: BreakpointScope.fromSize(
          size: const Size(420, 860),
          child: const MaterialApp(home: Scaffold(body: SettingsPage())),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(tester.takeException(), isNull);
  });
}
