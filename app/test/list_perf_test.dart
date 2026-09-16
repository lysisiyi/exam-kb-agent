/// 5000 题的列表性能**实测**。
///
/// 对应 `docs/V1_PLAN.md` 验收表里那一条：
/// 「错题本列表 5000 题滚动不掉帧（**可用脚本灌数据测试**）」。
///
/// ## 这个文件里哪些数字可信，哪些不可信（重要）
///
/// 诚实地说清楚，免得以后有人拿这里的数字当帧率：
///
/// | 指标 | 可信吗 | 为什么 |
/// |---|---|---|
/// | 数据层读取 + 排序耗时 | ✅ 可信 | 纯 Dart + sqlite，与真机同一条代码路径 |
/// | 一次查询读进来多少字节 | ✅ 可信 | 列选择优化前后可直接对比 |
/// | 滚动时**活着**的列表项数量 | ✅ 可信 | 证明 5000 题下懒加载没有退化成全量构建 |
/// | 「每屏 xx ms」 | ❌ **不可信** | widget 测试的 `pump` 包含测试框架自身开销，数量级高于真机帧时间。只用于**同环境前后对比** |
///
/// 所以下面**不对帧时间下断言** —— 那只会得到一条会随机失败的用例。
/// 真正的"掉不掉帧"必须在真机上用 DevTools 看（已记进 PROGRESS 的待办）。
///
/// 默认只灌 200 题；要跑满 5000 时设环境变量 `DSH_PERF=1`。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/layout/breakpoints.dart';
import 'package:kaoyan_math_agent/core/providers.dart';
import 'package:kaoyan_math_agent/data/db/database.dart';
import 'package:kaoyan_math_agent/data/index/index_builder.dart';
import 'package:kaoyan_math_agent/features/problems/problems_page.dart';

import 'support/test_env.dart';

/// 灌多少题。跑满 5000 的开关是环境变量 `DSH_PERF=1`。
int get _seedCount => Platform.environment['DSH_PERF'] == '1' ? 5000 : 200;

/// 一段接近真实的题干（含公式与中文），用于生成有代表性大小的
/// `stem_text` 与 `search_tokens`。
///
/// ⚠️ 这里**不能**用 `r'...'` 原始字符串：原始字符串只关掉**反斜杠**转义，
/// `$` 照样是插值 —— 写成 `r'$f(x)$'` 会被当成"插值变量 f"，直接编译不过。
/// 所以用普通字符串 + `\$` 转义美元符 + `\\` 转义 LaTeX 反斜杠。
/// （也别在里面写两个连续单引号：那会被当成字符串结束 + 新字符串开始。）
const String _stemTemplate =
    '设函数 \$f(x)\$ 在闭区间 \$[a,b]\$ 上连续，在开区间内可导，'
    '且 \$f(a)=f(b)\$，证明存在 \$\\xi\\in(a,b)\$ 使 \$f(\\xi)=0\$。';

/// 直接写索引表灌数据。
///
/// ## 为什么不走 `seedProblems`（写 Markdown + 重建索引）
///
/// 这个测试量的是**列表读数据**的成本，不是导入的成本。
/// 走 `seedProblems` 要写 [n] 个 `.md` 文件再全量重建索引，
/// 5000 题时那一步本身就要几十秒 —— 而它对被测对象毫无贡献。
/// 直接把行写进去，测的就是生产里那条查询。
Future<void> _seedIndex(AppDatabase db, int n, {bool withState = true}) async {
  await db.batch((b) {
    b.insertAll(db.problemsIndex, [
      for (var i = 0; i < n; i++)
        ProblemsIndexCompanion.insert(
          id: 'p-$i',
          fingerprint: 'fp-$i',
          subject: 'math1',
          qtype: 'solve',
          difficulty: Value(i % 3 + 1),
          source: const Value('2023 年数学一'),
          sourceType: const Value('real_exam'),
          filePath: 'problems/p-$i.md',
          stemText: '$_stemTemplate 第 $i 题。',
          // 生产里这一列是 `SearchableText.fromProblem` 的产物（逐字分词）。
          // 它比 stem_text 大得多，而列表一个字符都不用 —— 这正是要量的那列。
          searchTokens: Value(CjkTokenizer.space('$_stemTemplate 第 $i 题。')),
          primaryKpName: const Value('洛必达法则'),
          primaryKpWeight: const Value(0.8),
          parseWarnings: const Value('["这是解析期产生的警告，列表同样用不到"]'),
          createdAt: Value(DateTime(2024, 1, 1).add(Duration(minutes: i))),
          fileModifiedAt: Value(DateTime(2024, 1, 1)),
        ),
    ]);
  });

  if (!withState) return;
  await db.batch((b) {
    b.insertAll(db.userProblemState, [
      for (var i = 0; i < n; i++)
        UserProblemStateCompanion.insert(
          problemId: 'p-$i',
          wrongCount: Value(i % 7),
          firstSeen: Value(DateTime(2024, 1, 1)),
        ),
    ]);
  });
}

void main() {
  late TempLibrary env;

  setUp(() async {
    env = await TempLibrary.create();
  });

  tearDown(() => env.dispose());

  test('灌数据：$_seedCount 题写入耗时（参照值，不是被优化对象）', () async {
    final sw = Stopwatch()..start();
    await _seedIndex(env.db, _seedCount);
    sw.stop();
    // ignore: avoid_print
    print('[perf] 灌 $_seedCount 题：${sw.elapsedMilliseconds} ms');
    expect(sw.elapsedMilliseconds, lessThan(60000));
  });

  test('列选择：全表 vs 只取列表用得到的列', () async {
    // 这是本文件里最有价值的一条。`problemListProvider` 只需要 8 列，
    // 而 `SELECT *` 会把 `search_tokens`（逐字加空格的全文）与
    // `parse_warnings` 一起读出来 —— 两者列表都用不到。
    await _seedIndex(env.db, _seedCount);

    Future<(int, Duration)> timeQuery(String sql) async {
      final sw = Stopwatch()..start();
      final rows = await env.db.customSelect(sql).get();
      sw.stop();
      return (rows.length, sw.elapsed);
    }

    final (nAll, tAll) = await timeQuery('SELECT * FROM problems_index');
    final (nSome, tSome) = await timeQuery(
      'SELECT id, stem_text, primary_kp_name, difficulty, source, '
      'needs_review, ai_tagged, created_at FROM problems_index',
    );

    expect(nAll, _seedCount);
    expect(nSome, _seedCount);

    // ignore: avoid_print
    print('[perf] 全表 SELECT *：${tAll.inMilliseconds} ms');
    // ignore: avoid_print
    print('[perf] 只取 8 列：${tSome.inMilliseconds} ms');
    final ratio = tAll.inMicroseconds == 0
        ? 0.0
        : tSome.inMicroseconds / tAll.inMicroseconds;
    // ignore: avoid_print
    print('[perf] 列选择收益：${((1 - ratio) * 100).toStringAsFixed(0)}%');

    // 只断言"窄查询不会更慢" —— 这在任何机器上都该成立，
    // 且一旦有人把列选择改回全表，差值会在打印里一眼看到。
    expect(tSome.inMicroseconds,
        lessThanOrEqualTo((tAll.inMicroseconds * 1.2).round() + 2000));
  });

  test('列表数据构建：$_seedCount 题的读取 + 排序耗时', () async {
    await _seedIndex(env.db, _seedCount);

    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => env.db),
    ]);
    addTearDown(container.dispose);

    // ⚠️ 取 **3 次里的最小值**，不是平均值。
    //
    // 这台机器上单次测量的抖动很大（同一份代码在两次运行里量到
    // 163 ms 和 205 ms，差了 25%）。最小值最接近"这段代码本身的代价"，
    // 而平均值把机器当时的负载也算进来了 —— 用它做前后对比会得出
    // 错误的结论（比如"优化之后变慢了"）。
    //
    // ⚠️ 每次必须先 `invalidate`。provider 会把结果缓存住 ——
    // 不失效的话第二次 `read` 量到的是**缓存命中**（0 ms），
    // 那是个假数字（我第一版就是这么写错的）。
    Future<int> bestOf(int runs, ProblemView view) async {
      var best = 1 << 30;
      for (var i = 0; i < runs; i++) {
        container.invalidate(problemListProvider(view));
        final sw = Stopwatch()..start();
        await container.read(problemListProvider(view).future);
        sw.stop();
        if (sw.elapsedMilliseconds < best) best = sw.elapsedMilliseconds;
      }
      return best;
    }

    for (final view in ProblemView.values) {
      final ms = await bestOf(3, view);
      final rows = await container.read(problemListProvider(view).future);
      expect(rows.length, _seedCount);
      // ignore: avoid_print
      print('[perf] 列表数据（${view.label}）最优：$ms ms');
    }
  });

  testWidgets('5000 题下列表仍然懒加载（不是一次性建完）', (tester) async {
    await tester.runAsync(() => _seedIndex(env.db, _seedCount));

    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) async => env.db),
        ],
        child: BreakpointScope.fromSize(
          size: const Size(1100, 900),
          child: const MaterialApp(home: Scaffold(body: ProblemsPage())),
        ),
      ),
    );
    // 数据是异步来的，等到列表真的出现
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byType(ListView).evaluate().isNotEmpty) break;
    }
    expect(tester.takeException(), isNull);
    expect(find.byType(ListView), findsWidgets, reason: '列表没起来');

    /// 当前**活着**的列表项数量。
    ///
    /// 这是可断言的那部分"懒加载"：如果哪天有人把 `ListView.separated`
    /// 换成 `ListView(children: [...])` 或加了个 `shrinkWrap: true`，
    /// 这个数会直接跳到 $_seedCount，而这正是"5000 题必卡"的成因。
    int alive() => find.byType(InkWell).evaluate().length;

    final atRest = alive();
    // ignore: avoid_print
    print('[perf] 首屏活着列表项：$atRest / $_seedCount');
    expect(atRest, lessThan(100),
        reason: '一屏不可能放下上百项 —— 超过说明列表不再是懒加载的');

    for (var i = 0; i < 10; i++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -600));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);

    final afterScroll = alive();
    // ignore: avoid_print
    print('[perf] 滚动 10 屏后活着列表项：$afterScroll / $_seedCount');
    expect(afterScroll, lessThan(100),
        reason: '滚过的项必须被回收，否则内存会随滚动一直涨');
  });
}
