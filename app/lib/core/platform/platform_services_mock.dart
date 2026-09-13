/// 平台服务的 Mock 实现。
///
/// ## 用途
/// 1. **单元测试** —— 不需要真机就能测业务逻辑
/// 2. **开发期占位** —— 在具体平台实现写好之前，App 也能跑起来
/// 3. **降级兜底** —— 某个平台不支持某能力时（如 PC 没有拍照场景），
///    用 Mock 返回"不支持"，UI 层据此隐藏入口
///
/// ⚠️ **绝不要把 Mock 实现带进 Release 构建。** 见 `platform_services.dart`
/// 的 `PlatformServices.install` 调用点。
library;

import 'dart:async';
import 'dart:typed_data';

import 'platform_services.dart';

/// 内存版安全存储。测试用，进程退出即丢。
class MockSecureStore implements SecureStore {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);

  @override
  Future<void> deleteAll() async => _data.clear();

  @override
  Future<String?> readMasked(String key) async {
    final v = _data[key];
    if (v == null || v.isEmpty) return null;
    if (v.length <= 8) return '••••';
    return '${v.substring(0, 3)}••••••••${v.substring(v.length - 4)}';
  }
}

/// 不产生任何通知的通知服务。
class MockNotifyService implements NotifyService {
  final List<({String title, String body})> sent = [];

  /// 可配置的权限状态，便于测试"用户拒绝通知"的分支。
  bool permissionGranted;

  MockNotifyService({this.permissionGranted = true});

  @override
  Future<bool> requestPermission() async => permissionGranted;

  @override
  Future<void> scheduleDailyReminder({
    required int hour,
    required int minute,
    required int dueCount,
  }) async {}

  @override
  Future<void> show({
    required String title,
    required String body,
    String? payload,
  }) async {
    sent.add((title: title, body: body));
  }

  @override
  Future<void> cancelAll() async {}
}

/// 返回固定结果的 OCR 服务。
class MockOcrService implements OcrService {
  final OcrResult result;
  final bool available;
  final Object? throwOnRecognize;

  MockOcrService({
    this.result = const OcrResult(
      blocks: [
        OcrBlock(
          text: '设 f(x) 在 [0,1] 上连续，且 ∫₀¹ f(x)dx = 0，f(1)=0。',
          bbox: [0.05, 0.05, 0.95, 0.35],
          confidence: 0.93,
        ),
        OcrBlock(
          text: '证明：存在 ξ ∈ (0,1)，使得 f(ξ)=0。',
          bbox: [0.05, 0.40, 0.95, 0.55],
          confidence: 0.88,
        ),
      ],
      engine: 'mock',
      elapsedMs: 12,
      overallConfidence: 0.90,
    ),
    this.available = true,
    this.throwOnRecognize,
  });

  @override
  bool get isAvailable => available;

  @override
  Future<OcrResult> recognizeText(Uint8List imageBytes) async {
    if (throwOnRecognize != null) throw throwOnRecognize!;
    return result;
  }

  @override
  Future<void> dispose() async {}
}

/// 不产生任何图片的来源服务。
///
/// 默认全部返回"不支持 / 空"，适合测试与"功能裁剪"的场景。
/// 需要模拟选择的测试可以继承后覆写。
class MockImageSourceService implements ImageSourceService {
  final bool camera;
  final bool directory;

  MockImageSourceService({this.camera = false, this.directory = true});

  @override
  bool get supportsCamera => camera;

  @override
  bool get supportsDirectoryPicker => directory;

  @override
  Future<PickedFile?> pickFromCamera() async {
    if (!camera) throw UnsupportedError('本平台不支持拍照');
    return null;
  }

  @override
  Future<PickedFile?> pickImage() async => null;

  @override
  Future<List<PickedFile>> pickMultipleImages() async => const [];

  @override
  Future<List<PickedFile>> pickPdfs() async => const [];

  @override
  Future<List<PickedFile>> pickDirectory() async {
    if (!directory) throw UnsupportedError('本平台不支持文件夹选择');
    return const [];
  }
}

/// 组装一整套 Mock 服务。
PlatformServices mockPlatformServices({
  OcrService? ocr,
  ImageSourceService? imageSource,
  SecureStore? secureStore,
  NotifyService? notify,
}) =>
    PlatformServices(
      ocr: ocr ?? MockOcrService(),
      imageSource: imageSource ?? MockImageSourceService(),
      secureStore: secureStore ?? MockSecureStore(),
      notify: notify ?? MockNotifyService(),
    );
