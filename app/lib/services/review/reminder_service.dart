/// 应用内每日复习提醒。
///
/// ## 为什么是"应用内"而不是系统通知
///
/// 见 `notify_service_windows.dart` 的类文档：Windows Toast 未 MSIX 打包时
/// `cancel()` 无效，而 `flutter_local_notifications` 又不支持重复通知 ——
/// "每天 20:00 提醒" 交不出去。所以提醒只能由应用自己在运行时判断。
///
/// **诚实的代价**：应用没运行就不会提醒。这一点必须在 UI 上如实告知，
/// 而不是给一个静默失效的开关。
///
/// ## 为什么必须持久化"今天提醒过了"
///
/// `ReminderScheduler` 里那一天的判断只在内存里。若不落盘，
/// 用户每次重启应用都会再被提醒一次 —— 一天开五次就被烦五次，
/// 最后他会去关掉提醒，而不是留着它。所以"上次提醒日期"写进
/// `meta_entries`，这个服务就是那层持久化。
library;

import '../../core/platform/notify_service_windows.dart';
import '../../data/db/database.dart';
/// 提醒设置的存储键。
const String kReminderMetaKey = 'daily_reminder';

/// 一次提醒判断的结果。
class ReminderDecision {
  /// 是否应当现在提醒。
  final bool notify;

  /// 待复习卡片数（UI 文案要用）。
  final int dueCount;

  /// 提醒时间（`HH:mm`），仅用于文案。
  final String at;

  const ReminderDecision({
    required this.notify,
    required this.dueCount,
    required this.at,
  });

  static const ReminderDecision none =
      ReminderDecision(notify: false, dueCount: 0, at: '');
}

/// 每日提醒服务：读设置 → 判断该不该提醒 → 记下"已提醒"。
class ReminderService {
  final AppDatabase db;

  /// 判断逻辑本身。可注入以便测试固定时间。
  final ReminderScheduler scheduler;

  ReminderService({required this.db, ReminderScheduler? scheduler})
      : scheduler = scheduler ?? ReminderScheduler();

  /// 从 `meta_entries` 载入设置。没有记录时用默认值（20:00 开）。
  Future<void> load() async {
    final raw = await db.readMeta(kReminderMetaKey);
    if (raw == null || raw.isEmpty) return; // 保持默认
    try {
      final j = _decode(raw);
      // 解析不出任何键 = 内容损坏。此时**不能**把空 map 交给
      // `restoreFromJson`：那会把设置清成"关闭"，用户会以为提醒功能坏了。
      if (j.isEmpty) return;
      scheduler.restoreFromJson(j);
    } catch (_) {
      // 设置坏了就退回默认，不让它阻塞复习页
    }
  }

  /// 该不该提醒。[dueCount] 为 0 时不提醒 —— 没有要复习的东西，
  /// 提醒只会训练用户忽略它。
  Future<ReminderDecision> decide({
    required int dueCount,
    DateTime? now,
  }) async {
    if (!scheduler.enabled || dueCount <= 0) return ReminderDecision.none;
    if (!scheduler.shouldNotifyNow(now ?? DateTime.now())) {
      return ReminderDecision.none;
    }
    final h = scheduler.hour!;
    final m = scheduler.minute!;
    return ReminderDecision(
      notify: true,
      dueCount: dueCount,
      at: '$h:${m.toString().padLeft(2, '0')}',
    );
  }

  /// 记下"今天已提醒"。必须调用，否则同一天会反复提醒。
  Future<void> markNotified({DateTime? now}) async {
    scheduler.markNotified(now ?? DateTime.now());
    try {
      await db.writeMeta(kReminderMetaKey, _encode(scheduler.toJson()));
    } catch (_) {
      // 写不进去只会导致今天多提醒一次，不值得让调用方处理异常
    }
  }
}

/// 极小的设置序列化。
///
/// 只存三个标量。这里**刻意不用 `dart:convert`** 也不引 codegen——
/// 一个三字段的设置引入一套 JSON 依赖不划算，而手写映射在这里是可读的。
///
/// ⚠️ **键名必须与 `ReminderScheduler.restoreFromJson` 读的键完全一致。**
/// 这里踩过一次：编码写成 `last=`，解码回的是 `last`，
/// 而 `restoreFromJson` 找的是 `lastNotified` —— 于是"今天提醒过了"
/// 永远恢复不出来。表现是每次重启都重复提醒，且**没有任何报错**。
/// 所以键名一律用 `toJson()` 里的名字，不做缩写。
String _encode(Map<String, dynamic> m) {
  final hour = m['hour'];
  final minute = m['minute'];
  final last = m['lastNotified'];
  return 'hour=$hour;minute=$minute;lastNotified=${last ?? ''}';
}

Map<String, dynamic> _decode(String s) {
  final out = <String, dynamic>{};
  for (final part in s.split(';')) {
    final i = part.indexOf('=');
    if (i <= 0) continue;
    final k = part.substring(0, i);
    final v = part.substring(i + 1);
    if (k == 'hour' || k == 'minute') {
      out[k] = int.tryParse(v);
    } else if (k == 'lastNotified') {
      out[k] = v.isEmpty ? null : v;
    }
  }
  return out;
}
