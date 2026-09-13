/// Windows 通知实现 —— **降级为应用内提醒**。
///
/// ## 为什么不用 `flutter_local_notifications`
///
/// 踩过的坑：项目最初引入了 `flutter_local_notifications 17.2.4`，
/// 但**该版本的 Windows 支持还不存在** ——
/// `WindowsInitializationSettings` / `InitializationSettings(windows:)`
/// 都不存在，编译期直接报 `No named parameter with the name 'windows'`。
/// Windows 支持是后续版本才加入的。
///
/// ## 为什么最终选择"不做系统 Toast"
///
/// 即使升级到支持的版本，Windows Toast 仍有两个硬限制：
///
/// 1. **取消通知需要 MSIX 打包身份**。未用 MSIX 安装时 `cancel()` 无效、
///    `getActiveNotifications()` 返回空。
/// 2. **不支持重复通知**。`periodicallyShow` 直接抛 `UnsupportedError`，
///    "每天 20:00 提醒复习"无法交给系统。
///
/// 而真正可靠的提醒机制是**应用内调度**（见 [ReminderScheduler]）：
/// 应用运行时判断是否到点、今天是否已提醒过。这套逻辑完全跨平台，
/// 不依赖任何原生能力。
///
/// 因此本实现的目标不是"发通知"，而是**如实报告当前能力**，
/// 让 UI 能告诉用户"提醒需要应用在运行"，而不是给一个静默失效的开关。
///
/// ## 将来要加系统 Toast 时
/// 升级 `flutter_local_notifications` 到支持 Windows 的版本，
/// 然后只需替换本文件 —— 调用方通过 [NotifyService] 抽象访问，不用改。
library;

import 'package:flutter/foundation.dart';

import 'platform_services.dart';

/// Windows 通知服务（降级实现）。
class NotifyServiceWindows implements NotifyService {
  /// 记录通过 [show] 发出的通知，便于开发期观察与测试断言。
  ///
  /// 生产环境中这些通知只在调试日志里出现，不打断用户。
  final List<({String title, String body})> dispatched = [];

  bool _permissionDecided = false;

  /// 是否具备系统 Toast 能力。
  ///
  /// 当前恒为 `false` —— 见类文档。UI 应据此把"系统通知"开关置灰，
  /// 并显示"应用内提醒可用"。
  bool get isAvailable => false;

  @override
  Future<bool> requestPermission() async {
    _permissionDecided = true;
    // Windows 没有运行时通知权限弹窗（用户在系统设置里控制）。
    // 由于我们不使用系统 Toast，这里如实返回 false。
    return false;
  }

  @override
  Future<void> scheduleDailyReminder({
    required int hour,
    required int minute,
    required int dueCount,
  }) async {
    // Windows 不支持平台级重复提醒；每日提醒由 [ReminderScheduler]
    // 在应用内处理。这里显式留空而不是抛异常 ——
    // 调用方不需要为平台差异写分支。
    debugPrint(
      '[Notify] Windows 无系统级每日提醒；已交由应用内调度。'
      '（设定时间 $hour:${minute.toString().padLeft(2, '0')}，待复习 $dueCount 题）',
    );
  }

  @override
  Future<void> show({
    required String title,
    required String body,
    String? payload,
  }) async {
    // 记录但不弹窗。理由：
    // - 没有系统 Toast 能力时，弹一个自定义窗口会打断用户且难以定位
    // - 应用内已有更合适的反馈位（状态栏提示、任务列表）
    dispatched.add((title: title, body: body));
    debugPrint('[Notify] $title — $body');
  }

  @override
  Future<void> cancelAll() async {
    dispatched.clear();
  }

  /// 是否已请求过权限（用于 UI 首次引导）。
  bool get permissionDecided => _permissionDecided;
}

/// 应用内提醒调度。
///
/// ## 为什么需要它
/// 纯本地架构 + Windows 通知限制，意味着"每天提醒复习"不能交给系统。
/// 必须由应用自己判断：**当前是否已过提醒点、今天是否已提醒过**。
///
/// ## 局限（要如实告知用户）
/// 应用没运行时无法提醒。这是架构的必然结果，不是缺陷 ——
/// UI 上应写明"提醒需要应用在运行"。
class ReminderScheduler {
  /// 每日提醒时间（小时，0–23）。null 表示关闭提醒。
  int? hour;
  int? minute;

  /// 今天是否已提醒过（按日期比较，跨天自动重置）。
  DateTime? _lastNotifiedDate;

  ReminderScheduler({this.hour = 20, this.minute = 0});

  bool get enabled => hour != null && minute != null;

  /// 今天是否已提醒过。
  bool get notifiedToday => _lastNotifiedDate != null;

  /// 判断此刻是否该提醒。
  ///
  /// 返回 true 表示"已过提醒点且今天还没提醒过"。
  bool shouldNotifyNow(DateTime now) {
    if (!enabled) return false;

    final today = DateTime(now.year, now.month, now.day);
    final last = _lastNotifiedDate;
    if (last != null &&
        last.year == today.year &&
        last.month == today.month &&
        last.day == today.day) {
      return false; // 今天已提醒
    }

    final reminderAt = today.add(Duration(hours: hour!, minutes: minute!));
    return !now.isBefore(reminderAt);
  }

  /// 标记"今天已提醒"。
  void markNotified(DateTime now) {
    _lastNotifiedDate = DateTime(now.year, now.month, now.day);
  }

  /// 序列化（交给 `meta_entries` 表持久化）。
  ///
  /// 必须持久化：否则每次重启 App 都会重复提醒一次。
  Map<String, dynamic> toJson() => {
        'hour': hour,
        'minute': minute,
        'lastNotified': _lastNotifiedDate?.toIso8601String(),
      };

  void restoreFromJson(Map<String, dynamic> j) {
    hour = (j['hour'] as num?)?.toInt();
    minute = (j['minute'] as num?)?.toInt();
    final last = j['lastNotified']?.toString();
    _lastNotifiedDate = last == null ? null : DateTime.tryParse(last);
  }
}
