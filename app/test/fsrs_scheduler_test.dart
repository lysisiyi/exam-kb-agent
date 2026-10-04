import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/domain/fsrs/fsrs_scheduler.dart';

void main() {
  final t0 = DateTime(2026, 3, 15, 9, 0);

  group('FsrsScheduler · 初始状态', () {
    test('新卡是 learning、reps 为 0、due 为空', () {
      final card = FsrsCard.newCard();
      expect(card.state, CardState.learning);
      expect(card.reps, 0);
      expect(card.due, isNull);
      expect(card.isNew, isTrue);
    });

    test('新卡立即可复习', () {
      final s = FsrsScheduler();
      expect(s.isDue(FsrsCard.newCard(), t0), isTrue);
    });
  });

  group('FsrsScheduler · 记忆模型', () {
    test('保持率随间隔单调递减，且在 t=0 时为 1', () {
      final s = FsrsScheduler();
      const stability = 10.0;

      expect(s.retrievabilityOf(stability, 0), closeTo(1.0, 1e-9));

      final r1 = s.retrievabilityOf(stability, 5);
      final r2 = s.retrievabilityOf(stability, 20);
      final r3 = s.retrievabilityOf(stability, 100);

      expect(r1, greaterThan(r2));
      expect(r2, greaterThan(r3));
      expect(r3, greaterThan(0));
    });

    test('间隔等于 stability 时，保持率应接近 90%', () {
      // 这是 FSRS 的定义性质：R(S, S) ≈ 0.9
      final s = FsrsScheduler();
      const stability = 30.0;
      final r = s.retrievabilityOf(stability, 30);
      expect(r, closeTo(0.9, 0.01));
    });

    test('初始难度随评级升高而降低（Easy 的难度更低）', () {
      final s = FsrsScheduler();
      final dForgot = s.initialDifficulty(Rating.forgot);
      final dHard = s.initialDifficulty(Rating.hard);
      final dEasy = s.initialDifficulty(Rating.easy);

      expect(dForgot, greaterThan(dHard));
      expect(dHard, greaterThan(dEasy));
    });

    test('初始难度与后续难度都夹在 [1, 10]', () {
      final s = FsrsScheduler();
      for (final r in Rating.values) {
        final d = s.initialDifficulty(r);
        expect(d, inInclusiveRange(1.0, 10.0));
      }
      // 连续 50 次 forgot 不应把难度推到 10 以上
      var d = 5.0;
      for (var i = 0; i < 50; i++) {
        d = s.nextDifficulty(d, Rating.forgot);
      }
      expect(d, inInclusiveRange(1.0, 10.0));
    });
  });

  group('FsrsScheduler · 复习流程', () {
    test('首次「吃力」→ 进入 review 状态，due 在未来', () {
      final s = FsrsScheduler();
      final out = s.review(FsrsCard.newCard(), Rating.hard, t0);

      expect(out.card.state, CardState.review);
      expect(out.card.reps, 1);
      expect(out.card.lapses, 0);
      expect(out.card.due, isNotNull);
      expect(out.card.due!.isAfter(t0), isTrue);
      expect(out.card.stability, greaterThan(0));
    });

    test('首次「忘了」→ 仍在 learning，且当天稍后再来（10 分钟）', () {
      final s = FsrsScheduler();
      final out = s.review(FsrsCard.newCard(), Rating.forgot, t0);

      expect(out.card.state, CardState.learning);
      expect(out.card.lapses, 1);
      expect(out.intervalDays, 0);
      expect(out.card.due, t0.add(const Duration(minutes: 10)));
    });

    test('连续「轻松」会让间隔单调增长', () {
      final s = FsrsScheduler(random: _NoJitter());
      var card = FsrsCard.newCard();
      var now = t0;
      final intervals = <int>[];

      for (var i = 0; i < 6; i++) {
        final out = s.review(card, Rating.easy, now);
        card = out.card;
        intervals.add(out.intervalDays);
        now = card.due!;
      }

      // 前几次允许相等（首次可能算出同一天），整体必须递增
      expect(intervals.last, greaterThan(intervals.first));
      for (var i = 1; i < intervals.length; i++) {
        expect(intervals[i], greaterThanOrEqualTo(intervals[i - 1]));
      }
    });

    test('「轻松」的间隔严格大于「吃力」', () {
      final s = FsrsScheduler(random: _NoJitter());
      final a = s.review(FsrsCard.newCard(), Rating.hard, t0);
      final b = s.review(FsrsCard.newCard(), Rating.easy, t0);
      expect(b.intervalDays, greaterThan(a.intervalDays));
    });

    test('复习失败会增加 lapses 并进入 relearning', () {
      final s = FsrsScheduler(random: _NoJitter());
      final first = s.review(FsrsCard.newCard(), Rating.easy, t0);
      final second = s.review(
        first.card,
        Rating.forgot,
        t0.add(Duration(days: first.intervalDays)),
      );

      expect(second.card.lapses, 1);
      expect(second.card.state, CardState.relearning);
      expect(second.intervalDays, 0, reason: 'lapse 后当天要重练');
    });

    test('遗忘后稳定性受上限封顶，必然低于遗忘前', () {
      // py-fsrs 的 post-lapse 语义是 min(长程项, S/e^(w17·w18))：遗忘后的
      // 新稳定性不得超过原稳定性的 95%（1/1.0507）。历史实现曾把这个上限
      // 当乘数乘进长程项，导致成熟卡片点「忘了」反而被排到更远（S=10 时
      // 约 10 倍）——彼时旧注释据此声称"遗忘后稳定性可能高于原值"，那是
      // bug 的产物，不是 FSRS 的性质。数值对拍见 fsrs_pyfsrs_parity_test.dart。
      final s = FsrsScheduler(random: _NoJitter());
      final first = s.review(FsrsCard.newCard(), Rating.easy, t0);
      final lapsed = s.review(
        first.card,
        Rating.forgot,
        t0.add(const Duration(days: 1)),
      );

      expect(lapsed.card.stability, isNotNull);
      expect(lapsed.card.stability, greaterThan(0));
      expect(lapsed.card.stability, lessThan(36500));
      expect(
        lapsed.card.stability,
        lessThan(first.card.stability!),
        reason: '遗忘后稳定性必须低于遗忘前（封顶语义的必然结果）',
      );
      expect(lapsed.card.difficulty, inInclusiveRange(1.0, 10.0));
      expect(lapsed.card.lapses, 1);
      expect(lapsed.card.state, CardState.relearning);
    });

    test('难度高的卡片遗忘后稳定性会下降', () {
      // 构造方式很关键：
      // - 若用 easy 起步，D₀(easy)=1.0（难度极低），遗忘后稳定性反而上升。
      // - 若连续 forgot，稳定性会被压到地板值 0.01（clamp(0.01, 36500)），
      //   后续"增长/下降"的断言都失去意义。
      //
      // 正确做法：hard 起步（D₀(hard)≈5.11），正常复习建立记忆，
      // 再用一次遗忘把难度抬到 7 以上并在短间隔内失败。
      final s = FsrsScheduler(random: _NoJitter());

      final first = s.review(FsrsCard.newCard(), Rating.hard, t0);
      expect(first.card.difficulty, greaterThan(4.0), reason: 'hard 起点难度应偏高');

      final passed = s.review(
        first.card,
        Rating.hard,
        t0.add(Duration(days: first.intervalDays)),
      );
      final stabilityAfterPass = passed.card.stability!;
      expect(stabilityAfterPass, greaterThan(first.card.stability!));

      // 高难度卡片在短间隔内遗忘 → 稳定性应下降
      final lapsed = s.review(
        passed.card,
        Rating.forgot,
        passed.card.due!.add(const Duration(days: 1)),
      );
      expect(lapsed.card.difficulty, greaterThan(6.0));
      expect(
        lapsed.card.stability,
        lessThan(stabilityAfterPass),
        reason: '高难度 + 短间隔内遗忘，稳定性应下降',
      );
      expect(lapsed.card.lapses, 1);
    });

    test('越早遗忘，稳定性损失越大（间距效应）', () {
      // FSRS 的 stabilityAfterForget 含 exp((1−R)·w[14])：
      // R 越大（越是"还没到点就忘了"）→ 新稳定性越低。
      final s = FsrsScheduler(random: _NoJitter());

      // 用连续 forgot 构造高难度卡片，让衰减项占主导
      var card = FsrsCard.newCard();
      var now = t0;
      for (var i = 0; i < 3; i++) {
        card = s.review(card, Rating.forgot, now).card;
        now = now.add(const Duration(minutes: 10));
      }
      final passed = s.review(card, Rating.hard, now).card;
      final base = passed.stability!;

      final early = s.stabilityAfterForget(
        passed.difficulty!,
        base,
        s.retrievabilityOf(base, 1),
      );
      final late = s.stabilityAfterForget(
        passed.difficulty!,
        base,
        s.retrievabilityOf(base, 20),
      );

      expect(early, lessThan(late),
          reason: '1 天后就忘，比 20 天后才忘，损失更大');
    });

    test('稳定性随成功复习累积增长', () {
      final s = FsrsScheduler(random: _NoJitter());
      var card = FsrsCard.newCard();
      var now = t0;
      var prevStability = 0.0;

      for (var i = 0; i < 5; i++) {
        final out = s.review(card, Rating.easy, now);
        expect(out.card.stability!, greaterThan(prevStability));
        prevStability = out.card.stability!;
        card = out.card;
        now = card.due!;
      }
    });
  });

  group('FsrsCard · 序列化', () {
    test('toJson → fromJson 往返无损', () {
      final s = FsrsScheduler(random: _NoJitter());
      final out = s.review(FsrsCard.newCard(), Rating.hard, t0);
      final card = out.card;

      final restored = FsrsCard.fromJson(card.toJson());

      expect(restored.state, card.state);
      expect(restored.reps, card.reps);
      expect(restored.lapses, card.lapses);
      expect(restored.stability, closeTo(card.stability!, 1e-9));
      expect(restored.difficulty, closeTo(card.difficulty!, 1e-9));
      expect(restored.scheduledDays, card.scheduledDays);
      expect(restored.due!.toUtc(), card.due!.toUtc());
    });

    test('fromJson 能容忍缺失字段', () {
      final restored = FsrsCard.fromJson(<String, dynamic>{});
      expect(restored.state, CardState.learning);
      expect(restored.reps, 0);
      expect(restored.stability, isNull);
      expect(restored.due, isNull);
    });
  });

  group('Rating · 映射', () {
    test('三档标签正确', () {
      expect(Rating.forgot.label, '忘了');
      expect(Rating.hard.label, '吃力');
      expect(Rating.easy.label, '轻松');
    });

    test('历史数据里的 Good(3) 能安全降级为 Hard', () {
      expect(Rating.fromValue(3), Rating.hard);
      expect(Rating.fromValue(99), Rating.hard);
    });
  });

  group('间隔上限', () {
    test('maximumInterval 生效', () {
      final s = FsrsScheduler(maximumInterval: 30, random: _NoJitter());
      var card = FsrsCard.newCard();
      var now = t0;
      for (var i = 0; i < 10; i++) {
        final out = s.review(card, Rating.easy, now);
        expect(out.intervalDays, lessThanOrEqualTo(30));
        card = out.card;
        now = card.due!;
      }
    });
  });
}

/// 固定随机数，让模糊化失效，保证测试可复现。
class _NoJitter implements math.Random {
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0.5;
  @override
  int nextInt(int max) => 0;
}
