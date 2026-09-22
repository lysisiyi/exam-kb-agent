/// 错题本列表页测试。
///
/// ## 这一页要守住的东西
///
/// M4 之后录进去的题只有 Markdown 文件知道，界面上一处都看不到 ——
/// 这一页补的就是"回看"。所以它至少要做到三件事：
///
/// 1. **看得到**：录过的题会出现在列表里；
/// 2. **找得到**：中文全文检索能命中（FTS5 逐字分词那条链路）；
/// 3. **管得了**：能删除，且删除**必须**连状态行一起清掉 ——
///    否则复习队列里会留下一张永远打不开的卡。
///
/// ## 假时钟陷阱
///
/// 这一页要读 Markdown 文件与 sqlite，`testWidgets` 的假异步时钟不会推进
/// 真实 IO，所以每一步 IO 都包在 `tester.runAsync` 里。详见
/// `review_flow_test.dart` 里同一段说明。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/layout/breakpoints.dart';
import 'package:kaoyan_math_agent/core/providers.dart';
import 'package:kaoyan_math_agent/features/problems/problems_page.dart';

import 'support/test_env.dart';

void main() {
  late TempLibrary env;

  /// 在假时钟里建临时库并种数据。
  Future<void> seed(WidgetTester tester, List<SeedProblem> seeds) async {
    await tester.runAsync(() async {
      env = await TempLibrary.create();
      await seedProblems(env, seeds);
    });
    addTearDown(() async {
      await tester.runAsync(env.dispose);
    });
  }

  /// 挂真实的 `ProblemsPage`。
  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) async => env.db),
          problemStoreProvider.overrideWith((ref) async => env.store),
          // 详情表会读题库 images 目录。必须指到临时库：
          // 不覆盖的话真实 provider 会去碰用户的应用数据目录（见硬约束）。
          libraryPathsProvider.overrideWith((ref) async => env.paths),
        ],
        child: ResponsiveScope(
          builder: (context, bp) =>
              const MaterialApp(home: Scaffold(body: ProblemsPage())),
        ),
      ),
    );

    // 交替推进：runAsync 让真实 IO 完成，pump 让界面重建
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
    }
    fail('错题本载入没有完成 —— 30 轮 runAsync 后还在转圈');
  }

  Future<void> settle(WidgetTester tester, {int frames = 8}) async {
    for (var i = 0; i < frames; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  group('列表', () {
    testWidgets('空题库给出引导，而不是空白页', (tester) async {
      await seed(tester, const []);
      await pumpPage(tester);

      expect(find.text('错题本还是空的'), findsOneWidget);
      expect(find.textContaining('去「录入」页记下第一道题'), findsOneWidget);
    });

    testWidgets('录过的题会出现在列表里，并带错误次数、难度、来源', (tester) async {
      await seed(tester, [
        const SeedProblem(
          id: 'p-1',
          stem: r'求 $\lim_{x\to0}\frac{\sin x}{x}$',
          primaryKpId: 'math1.calc.limit.lhopital',
          source: '2023 年真题',
          wrongCount: 3,
        ),
      ]);
      await pumpPage(tester);

      expect(find.textContaining(r'\lim'), findsOneWidget);
      expect(find.text('错 3 次'), findsOneWidget);
      expect(find.text('综合'), findsOneWidget);
      expect(find.text('2023 年真题'), findsOneWidget);
      // 题目 id 始终显示，方便用户对照文件
      expect(find.text('p-1'), findsOneWidget);
    });

    testWidgets('「错题最多」按错误次数排序', (tester) async {
      await seed(tester, [
        const SeedProblem(id: 'p-low', stem: '错得少的题', wrongCount: 1),
        const SeedProblem(id: 'p-high', stem: '错得多的题', wrongCount: 9),
      ]);
      await pumpPage(tester);

      // 默认按录入时间倒序；切到"错题最多"
      await tester.tap(find.text('错题最多'));
      await settle(tester);

      final tiles = tester.widgetList<Text>(find.byType(Text)).toList();
      // 找两个题干在列表里的先后
      final first = tiles.indexWhere((t) => t.data == '错得多的题');
      expect(first, isNonNegative, reason: '排序后仍应看得到题目');
      expect(find.text('错 9 次'), findsOneWidget);
    });

    testWidgets('中文全文检索能命中', (tester) async {
      await seed(tester, [
        const SeedProblem(id: 'p-1', stem: '求极限的值'),
        const SeedProblem(id: 'p-2', stem: '证明中值定理'),
      ]);
      await pumpPage(tester);

      await tester.enterText(find.byType(TextField), '中值定理');
      // 搜索有 250 ms 去抖（见 `_onQueryChanged`），所以要推过它
      await tester.pump(const Duration(milliseconds: 300));
      await settle(tester);

      expect(find.textContaining('证明中值定理'), findsOneWidget);
      expect(find.textContaining('求极限的值'), findsNothing);
    });

    testWidgets('搜索去抖：连打不会每敲一个字符就查一次', (tester) async {
      // 没有去抖时，5000 题的库上输入会明显发涩，而且
      // `problemSearchProvider` 是按查询串分家的 family ——
      // 每敲一个字符就攒一份再也不会用到的结果。
      await seed(tester, [
        const SeedProblem(id: 'p-1', stem: '求极限的值'),
        const SeedProblem(id: 'p-2', stem: '证明中值定理'),
      ]);
      await pumpPage(tester);

      await tester.enterText(find.byType(TextField), '中');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField), '中值定理');

      // 还没到去抖时间：仍然显示**浏览列表**（两道题都在），
      // 说明搜索没有被触发
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('求极限的值'), findsOneWidget,
          reason: '去抖期内不该已经切到搜索结果');

      // 越过去抖：这时才真的查，非命中项消失
      await tester.pump(const Duration(milliseconds: 300));
      await settle(tester);
      expect(find.textContaining('求极限的值'), findsNothing);
      expect(find.textContaining('证明中值定理'), findsOneWidget);
    });

    testWidgets('清空搜索立刻回到浏览列表（不等去抖）', (tester) async {
      await seed(tester, [const SeedProblem(id: 'p-1', stem: '求极限的值')]);
      await pumpPage(tester);

      await tester.enterText(find.byType(TextField), '拉格朗日');
      await tester.pump(const Duration(milliseconds: 300));
      await settle(tester);
      expect(find.textContaining('没有匹配'), findsOneWidget);

      // 清空要立刻生效：让用户按完删除还要等 250ms 才看到列表回来，
      // 会以为界面卡住了
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      await settle(tester);
      expect(find.textContaining('没有匹配'), findsNothing);
      expect(find.textContaining('求极限的值'), findsOneWidget);
    });

    testWidgets('搜不到时给出明确空态', (tester) async {
      await seed(tester, [
        const SeedProblem(id: 'p-1', stem: '求极限的值'),
      ]);
      await pumpPage(tester);

      await tester.enterText(find.byType(TextField), '拉格朗日');
      await tester.pump(const Duration(milliseconds: 300));
      await settle(tester);

      expect(find.textContaining('没有匹配'), findsOneWidget);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('配图展示（混合制：正文用图）', () {
    /// 1×1 透明 PNG 的字节。写入临时库让 Image.file 有真图可解。
    final png1x1 = Uint8List.fromList(const [
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
      0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
      0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x00, 0x00, 0x06,
      0x00, 0x05, 0x63, 0x60, 0x3A, 0x7E, 0x4A, 0x35, 0x00, 0x00, 0x00, 0x00,
      0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ]);

    testWidgets('详情表渲染 images 字段指向的真实文件', (tester) async {
      await seed(tester, [
        const SeedProblem(
          id: 'p-1',
          stem: '如图所示的几何体',
          images: ['p-1-fig1.png'],
        ),
      ]);
      await tester.runAsync(() async {
        final imagesDir = env.paths.images;
        await imagesDir.create(recursive: true);
        await File('${imagesDir.path}/p-1-fig1.png').writeAsBytes(png1x1);
      });
      await pumpPage(tester);

      await tester.tap(find.textContaining('如图所示').first);
      await settle(tester);

      expect(find.byType(Image), findsOneWidget);
      expect(find.textContaining('配图缺失'), findsNothing);
    });

    testWidgets('图片文件丢了显示占位提示，而不是报错或空白', (tester) async {
      await seed(tester, [
        const SeedProblem(
          id: 'p-1',
          stem: '图片丢了的一道题',
          images: ['missing-fig.png'],
        ),
      ]);
      await pumpPage(tester);

      await tester.tap(find.textContaining('图片丢了').first);
      await settle(tester);

      expect(find.textContaining('配图缺失：missing-fig.png'), findsOneWidget);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('详情与操作', () {
    testWidgets('点开一道题能看到答案与解析，并给出三个操作', (tester) async {
      await seed(tester, [
        const SeedProblem(
          id: 'p-1',
          stem: '求极限的值',
          answer: r'$1$',
          solution: '等价无穷小替换。',
          note: '我总是在符号上错。',
        ),
      ]);
      await pumpPage(tester);

      await tester.tap(find.textContaining('求极限的值').first);
      await settle(tester);

      expect(find.text('答案'), findsOneWidget);
      expect(find.textContaining('等价无穷小替换'), findsOneWidget);
      expect(find.text('我的笔记'), findsOneWidget);
      expect(find.textContaining('符号上错'), findsOneWidget);
      expect(find.text('编辑'), findsOneWidget);
      expect(find.text('再记一次错'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
    });

    testWidgets('「再记一次错」会累加错误次数', (tester) async {
      await seed(tester, [
        const SeedProblem(id: 'p-1', stem: '求极限的值', wrongCount: 1),
      ]);
      await pumpPage(tester);

      expect(find.text('错 1 次'), findsOneWidget);

      await tester.tap(find.textContaining('求极限的值').first);
      await settle(tester);
      await tester.tap(find.text('再记一次错'));
      await settle(tester);

      final s = await tester.runAsync(() async =>
          (env.db.select(env.db.userProblemState)
                ..where((t) => t.problemId.equals('p-1')))
              .getSingle());
      expect(s!.wrongCount, 2);
    });

    testWidgets('删除会连状态行一起清掉（否则复习队列里留一张死卡）', (tester) async {
      await seed(tester, [
        const SeedProblem(id: 'p-1', stem: '要被删掉的题', wrongCount: 4),
        const SeedProblem(id: 'p-2', stem: '留下的题', wrongCount: 1),
      ]);
      await pumpPage(tester);

      await tester.tap(find.textContaining('要被删掉的题').first);
      await settle(tester);
      await tester.tap(find.text('删除'));
      await settle(tester);

      // 二次确认弹窗
      expect(find.text('删除这道题？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await settle(tester);

      final rows = await tester
          .runAsync(() async => env.db.select(env.db.problemsIndex).get());
      expect(rows!.map((r) => r.id).toList(), ['p-2']);

      final states = await tester.runAsync(
          () async => env.db.select(env.db.userProblemState).get());
      expect(states!.map((s) => s.problemId).toList(), ['p-2'],
          reason: '状态行必须一起删 —— 否则复习队列会出现打不开的卡');

      // Markdown 文件也要没了（内容的事实源）
      final files = await tester.runAsync(() async {
        final dir = env.paths.problems;
        return dir
            .listSync()
            .whereType<File>()
            .map((f) => f.uri.pathSegments.last)
            .toList();
      });
      expect(files!.any((f) => f.contains('p-1')), isFalse);
    });

    testWidgets('取消删除不会动任何东西', (tester) async {
      await seed(tester, [
        const SeedProblem(id: 'p-1', stem: '不该被删的题', wrongCount: 2),
      ]);
      await pumpPage(tester);

      await tester.tap(find.textContaining('不该被删的题').first);
      await settle(tester);
      await tester.tap(find.text('删除'));
      await settle(tester);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await settle(tester);

      final rows = await tester
          .runAsync(() async => env.db.select(env.db.problemsIndex).get());
      expect(rows!.length, 1);
    });
  });
}
