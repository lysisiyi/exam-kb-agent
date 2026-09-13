/// 平台服务装配。
///
/// 把各平台的具体实现组装成 [PlatformServices]，供 `main()` 一次性注入。
/// 这是**唯一**需要知道"当前是什么平台、要装哪套实现"的地方 ——
/// 业务代码只通过 [PlatformServices.instance] 访问抽象接口。
///
/// ## 加新平台时要改什么
/// 只需在这里加一个分支 + 一个实现文件，业务代码零改动。
library;

import 'package:flutter/foundation.dart';

import 'capabilities.dart';
import 'image_source_windows.dart';
import 'notify_service_windows.dart';
import 'ocr_service_stub.dart';
import 'platform_services.dart';
import 'platform_services_mock.dart';
import 'secure_store_windows.dart';

/// 按当前平台装配服务。
///
/// 返回实际装配结果的说明，便于 `main()` 打印诊断信息。
Future<PlatformServices> installPlatformServices({
  bool forceMock = false,
}) async {
  if (forceMock) {
    final services = mockPlatformServices();
    PlatformServices.install(services);
    return services;
  }

  // Windows 桌面：真实实现
  if (PlatformCapabilities.isWindows) {
    final services = PlatformServices(
      // 端侧 OCR 暂不实现，见 ocr_service_stub.dart 的说明
      ocr: const UnavailableOcrService(),
      imageSource: const ImageSourceServiceWindows(),
      secureStore: SecureStoreWindows(),
      // 系统 Toast 暂不实现，提醒走应用内调度（ReminderScheduler）
      notify: NotifyServiceWindows(),
    );
    PlatformServices.install(services);
    return services;
  }

  // 其他平台（macOS / Linux / Android / iOS）：V1 尚未实现，
  // 先注入 Mock 保证能跑起来，而不是崩溃。
  //
  // ⚠️ 加平台时不要忘了在这里补真实实现，否则会静默降级为 Mock ——
  //    那时"保存 API Key 后重启丢失"这类问题会很难查。
  debugPrint(
    '[PlatformServices] ${PlatformCapabilities.name} 平台尚未实现，'
    '已注入 Mock 实现（数据不会持久化）。',
  );
  final services = mockPlatformServices();
  PlatformServices.install(services);
  return services;
}

/// 当前平台能力的可读摘要，用于「关于」页与诊断。
String describePlatformCapabilities() {
  final lines = <String>[
    '平台：${PlatformCapabilities.name}',
    '鼠标键盘交互：${PlatformCapabilities.usesDesktopInteractions ? "是" : "否"}',
    '拍照录入：${PlatformCapabilities.hasCamera ? "支持" : "不支持"}',
    '文件夹批量导入：${PlatformCapabilities.supportsDirectoryPicker ? "支持" : "不支持"}',
  ];

  if (PlatformServices.isInstalled) {
    final s = PlatformServices.instance;
    lines.add('端侧 OCR：${s.ocr.isAvailable ? "可用（${s.ocr.runtimeType}）" : "不可用"}');
    lines.add('安全存储：${s.secureStore.runtimeType}');
    if (s.notify is NotifyServiceWindows) {
      final n = s.notify as NotifyServiceWindows;
      lines.add('系统通知：${n.isAvailable ? "可用" : "不可用（改用应用内提醒）"}');
    }
  }

  return lines.join('\n');
}
