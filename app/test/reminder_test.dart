/// 每日复习提醒测试。
///
/// ## 为什么这个服务值得单独测
///
/// 它的失败方式全是"静默"的：
/// - **该提醒不提醒** → 用户不会知道，只会忘掉复习
/// - **不该提醒却提醒** → 用户会去关掉它，而不是留着
/// - **忘了持久化"今天提醒过了"** → 一天开五次应用被烦五次
///
/// 这三条都不会报错，只能靠断言盯住。而"每次重启都重复提醒"
/// 恰恰是 `ReminderScheduler` 只在内存里记日期时的真实后果。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/platform/notify_service_windows.dart';
import 'package:kaoyan_math_agent/services/review/reminder_service.dart';

import 'support/test_env.dart';

void main() {
  late TempLibrary env;

  setUp(() async {
    env = await TempLibrary.create();
  });

  tearDown(() => env.dispose());

  ReminderService service({int? hour = 20, int? minute = 0}) =>
      ReminderService(
        db: env.db,
        scheduler: ReminderScheduler(hour: hour, minute: minute),
      );

  // ───────────────────────────────────────────────────────────────────────────
  group('何时该提醒', () {
    test('到点且有卡片 → 提醒', () async {
      final d = await service()
          .decide(dueCount: 5, now: DateTime(2024, 6, 1, 20, 30));

      expect(d.notify, isTrue);
      expect(d.dueCount, 5);
      expect(d.at, '20:00');
    });

    test('没到点 → 不提醒', () async {
      final d = await service()
          .decide(dueCount: 5, now: DateTime(2024, 6, 1, 19, 59));
      expect(d.notify, isFalse);
    });

    test('没有到期卡片 → 不提醒（提醒空手会训练用户忽略它）', () async {
      final d = await service()
          .decide(dueCount: 0, now: DateTime(2024, 6, 1, 23, 0));
      expect(d.notify, isFalse);
    });

    test('关掉提醒 → 永远不提醒', () async {
      final s = service(hour: null, minute: null);
      final d = await s.decide(dueCount: 9, now: DateTime(2024, 6, 1, 23, 0));
      expect(d.notify, isFalse);
    });

    test('刚刚到点就算到点（边界不吞掉这一分钟）', () async {
      final d = await service()
          .decide(dueCount: 1, now: DateTime(2024, 6, 1, 20, 0));
      expect(d.notify, isTrue);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('一天只提醒一次', () {
    test('markNotified 之后同一天不再提醒', () async {
      final s = service();
      final now = DateTime(2024, 6, 1, 20, 30);

      expect((await s.decide(dueCount: 3, now: now)).notify, isTrue);
      await s.markNotified(now: now);
      expect((await s.decide(dueCount: 3, now: now)).notify, isFalse);
    });

    test('跨天自动恢复', () async {
      final s = service();
      await s.markNotified(now: DateTime(2024, 6, 1, 20, 30));

      final nextDay = DateTime(2024, 6, 2, 20, 30);
      expect((await s.decide(dueCount: 3, now: nextDay)).notify, isTrue);
    });

    test('重启应用不会重复提醒（这是必须落盘的原因）', () async {
      final now = DateTime(2024, 6, 1, 20, 30);

      final first = service();
      await first.markNotified(now: now);

      // 模拟重启：新实例，重新 load
      final afterRestart = service();
      await afterRestart.load();

      expect(
        (await afterRestart.decide(dueCount: 3, now: now)).notify,
        isFalse,
        reason: '不落盘的话每次重启都会再提醒一次 —— 一天开五次就被烦五次',
      );
    });

    test('设置写进了 meta_entries，而不是只在内存里', () async {
      await service().markNotified(now: DateTime(2024, 6, 1, 20, 30));
      final raw = await env.db.readMeta(kReminderMetaKey);
      expect(raw, isNotNull);
      // 键名必须与 `ReminderScheduler.restoreFromJson` 读的一致 ——
      // 这里曾经写成 `last=`，导致"今天提醒过了"永远恢复不出来
      expect(raw, contains('lastNotified=2024-06-01'));
      expect(raw, contains('hour=20'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('设置损坏时的降级', () {
    test('meta 里是垃圾 → 退回默认设置，不抛异常', () async {
      await env.db.writeMeta(kReminderMetaKey, '这不是设置');
      final s = service();
      await s.load(); // 不抛

      expect(s.scheduler.enabled, isTrue, reason: '应当保持默认（20:00 开）');
      final d = await s.decide(dueCount: 1, now: DateTime(2024, 6, 1, 21, 0));
      expect(d.notify, isTrue);
    });

    test('没有记录 → 用默认设置', () async {
      final s = service();
      await s.load();
      expect(s.scheduler.hour, 20);
      expect(s.scheduler.minute, 0);
    });

    test('存了自定义时间 → 载入后生效', () async {
      final custom = ReminderService(
        db: env.db,
        scheduler: ReminderScheduler(hour: 7, minute: 30),
      );
      await custom.markNotified(now: DateTime(2024, 6, 1, 7, 30));

      final reloaded = ReminderService(
        db: env.db,
        scheduler: ReminderScheduler(hour: 99, minute: 99),
      );
      await reloaded.load();

      expect(reloaded.scheduler.hour, 7);
      expect(reloaded.scheduler.minute, 30);
      final d = await reloaded.decide(
        dueCount: 1,
        now: DateTime(2024, 6, 2, 7, 30),
      );
      expect(d.at, '7:30');
    });
  });
}
