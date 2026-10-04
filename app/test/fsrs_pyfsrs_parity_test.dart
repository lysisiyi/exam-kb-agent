import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/domain/fsrs/fsrs_scheduler.dart';

import 'support/fsrs_pyfsrs_fixtures.dart';

/// 与 py-fsrs 6.3.2（FSRS-6 参考实现）的**数值对拍**。
///
/// 为什么要有这个文件：`fsrs_scheduler_test.dart` 里的断言是不变量
/// （stability > 0、单调之类），它们对"公式写错了但仍在合理区间"的
/// 情况全盲——历史上 post-lapse 公式把封顶写成乘数、衰减常数停在
/// FSRS-5，两类错误都活着通过了全部不变量测试。这里用参考实现的
/// 固定输入输出把**每一个公式**钉死：参考实现一升级（或有人改公式），
/// 这里第一个红。
///
/// 对拍范围是**数学**（稳定性/难度/保持率/间隔），不含排程 UX：
/// Dart 移植把「忘了 → 10 分钟后重练」定为产品决定，与 py-fsrs
/// 空 learning-steps 时的整天间隔不同，故 due/state 不参与对拍。
void main() {
  // 与基准生成脚本同一配置：关模糊化，其余全默认。
  final s = FsrsScheduler(enableFuzzing: false);

  void expectGrid(
    List<List<double>> grid,
    double Function(List<double> row) actual,
    String name,
  ) {
    for (var i = 0; i < grid.length; i++) {
      final row = grid[i];
      expect(
        actual(row),
        closeTo(row.last, 1e-9),
        reason: '$name 第 $i 行输入 ${row.sublist(0, row.length - 1)}',
      );
    }
  }

  group('纯函数对拍（py-fsrs 6.3.2 固定输出）', () {
    test('stabilityAfterForget：min(长程项, 0.95·S) 封顶', () {
      expectGrid(
        fsrsForgetGrid,
        (row) => s.stabilityAfterForget(row[0], row[1], row[2]),
        'forget',
      );
    });

    test('stabilityAfterRecall：hard 惩罚与 easy 奖励交替覆盖', () {
      var isHard = true;
      expectGrid(fsrsRecallGrid, (row) {
        final r = s.stabilityAfterRecall(
          row[0],
          row[1],
          row[2],
          isHard ? Rating.hard : Rating.easy,
        );
        isHard = !isHard;
        return r;
      }, 'recall');
    });

    test('stabilityAfterShortTerm：Again 不设下限，其余增益 ≥ 1', () {
      expectGrid(
        fsrsShortTermGrid,
        (row) =>
            s.stabilityAfterShortTerm(row[0], Rating.fromValue(row[1].toInt())),
        'short-term',
      );
    });

    test('nextDifficulty：均值回归目标取未夹取的 D₀(easy)', () {
      expectGrid(
        fsrsDifficultyGrid,
        (row) => s.nextDifficulty(row[0], Rating.fromValue(row[1].toInt())),
        'difficulty',
      );
    });

    test('retrievabilityOf：衰减指数用 w[20]，R(S,S)=0.9', () {
      expectGrid(
        fsrsRetrievabilityGrid,
        (row) => s.retrievabilityOf(row[0], row[1].toInt()),
        'retrievability',
      );
    });

    test('intervalFromStability：与 py-fsrs _next_interval 一致', () {
      expectGrid(
        fsrsIntervalGrid,
        (row) => s.intervalFromStability(row[0]).toDouble(),
        'interval',
      );
    });

    test('初始稳定性与初始难度', () {
      expectGrid(
        fsrsInitialStability,
        (row) => s.initialStability(Rating.fromValue(row[0].toInt())),
        'initialStability',
      );
      expectGrid(
        fsrsInitialDifficulty,
        (row) => s.initialDifficulty(Rating.fromValue(row[0].toInt())),
        'initialDifficulty',
      );
    });
  });

  group('场景对拍（多步复习的稳定性/难度演化）', () {
    // 场景定义见 fixtures 文件头与生成脚本；时间线（[rating, 小时, 分钟]）。
    // 场景只用 Again/Hard/Easy：Dart 的三档枚举没有 Good(3)（历史数据按
    // hard 降级），Good 的数学已由纯函数网格（hard/easy 两乘数）覆盖。
    // A: Again → +10min Again → +10min Easy（全同日，走短期路径）
    // B: Easy → +5d Hard → +12d Hard → +3d Easy → +30d Again → +10min Easy
    //    （长程召回 + 难度漂移 + 遗忘封顶 + 遗忘后同日恢复）
    // C: Hard → +3d Hard → +8d Again → +10min Again → +24h1min Hard →
    //    +23h11min Easy（短期/长程的 1 天边界两侧各踩一次）
    const timelines = <String, List<List<int>>>{
      'A': [
        [1, 0, 0],
        [1, 0, 10],
        [4, 0, 20],
      ],
      'B': [
        [4, 0, 0],
        [2, 5 * 24, 0],
        [2, 17 * 24, 0],
        [4, 20 * 24, 0],
        [1, 50 * 24, 0],
        [4, 50 * 24, 10],
      ],
      'C': [
        [2, 0, 0],
        [2, 3 * 24, 0],
        [1, 11 * 24, 0],
        [1, 11 * 24, 10],
        [2, 12 * 24, 11],
        [4, 12 * 24 + 23, 11],
      ],
    };

    test('每步的稳定性与难度与 py-fsrs 逐位一致', () {
      timelines.forEach((name, steps) {
        final expected = fsrsScenarios[name]!;
        expect(steps.length, expected.length, reason: '场景 $name 步数不一致');

        var card = FsrsCard.newCard();
        final t0 = DateTime.utc(2026, 1, 15, 8, 0);

        for (var i = 0; i < steps.length; i++) {
          final rating = Rating.fromValue(steps[i][0]);
          final now =
              t0.add(Duration(hours: steps[i][1], minutes: steps[i][2]));
          final out = s.review(card, rating, now);
          card = out.card;

          expect(
            card.stability,
            closeTo(expected[i][1], 1e-9),
            reason: '场景 $name 第 $i 步（rating=$rating）稳定性',
          );
          expect(
            card.difficulty,
            closeTo(expected[i][2], 1e-9),
            reason: '场景 $name 第 $i 步（rating=$rating）难度',
          );
        }
      });
    });
  });

  test('遗忘封顶语义：任意输入下 S′ ≤ S/e^(w17·w18) ≈ 0.95·S', () {
    // 历史实现把 py-fsrs 的 min(...) 封顶写成了乘数，成熟卡片点「忘了」
    // 会被排到比遗忘前更远（S=10 时约 10 倍）。这条断言是它的回归闸门。
    const p = FsrsScheduler.defaultParameters;
    final capFactor = math.exp(p[17] * p[18]); // ≈ 1.0507

    for (final row in fsrsForgetGrid) {
      final got = s.stabilityAfterForget(row[0], row[1], row[2]);
      expect(
        got,
        lessThanOrEqualTo(row[1] / capFactor + 1e-12),
        reason: 'S=${row[1]} 时遗忘后稳定性超出封顶',
      );
      expect(got, lessThanOrEqualTo(row[1] + 1e-12), reason: 'S′ 不应超过 S');
    }
  });

  test('同日复习走短期路径：做对不掉稳定性，再忘会掉', () {
    // 旧实现里同日重练走长程公式：R=1 → 增长项为 0，稳定性纹丝不动。
    final t0 = DateTime.utc(2026, 6, 1, 9, 0);

    final first = s.review(FsrsCard.newCard(), Rating.hard, t0);
    final again10minLater = s.review(
      first.card,
      Rating.hard,
      t0.add(const Duration(minutes: 10)),
    );
    expect(
      again10minLater.card.stability,
      closeTo(first.card.stability!, 1e-12),
      reason: '同日「吃力」的增益被抬到下限 1，稳定性应保持',
    );

    final forgotAgain = s.review(
      first.card,
      Rating.forgot,
      t0.add(const Duration(minutes: 10)),
    );
    expect(
      forgotAgain.card.stability!,
      lessThan(first.card.stability!),
      reason: '同日再忘应通过短期路径降低稳定性',
    );
  });
}
