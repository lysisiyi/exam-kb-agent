/// 平台能力抽象层。
///
/// ## 为什么需要这一层
/// 端侧 OCR、图片选择、通知、安全存储这四件事，**每个平台的实现都不同**：
///
/// | 能力 | Windows | Android | iOS / macOS |
/// |---|---|---|---|
/// | 文字 OCR | WinRT `Windows.Media.Ocr` | Google ML Kit | Apple Vision |
/// | 图片选择 | `file_selector`（无相机） | 相机 + 相册 | 相机 + 相册 |
/// | 安全存储 | DPAPI | Keystore | Keychain |
/// | 通知 | 系统 Toast | 通知渠道 | UNUserNotification |
///
/// 如果直接调用具体包，以后加平台就要改遍调用方。
/// 这里定义接口，V1 只实现 Windows 版 + Mock 版，
/// 以后加平台只需补一个实现文件。
///
/// ## 使用方式
/// ```dart
/// final ocr = PlatformServices.instance.ocr;
/// final result = await ocr.recognizeText(imageBytes);
/// ```
library;

import 'dart:typed_data';

// ─────────────────────────────────────────────────────────────────────────────
// OCR
// ─────────────────────────────────────────────────────────────────────────────

/// OCR 识别出的一块文本。
class OcrBlock {
  /// 识别出的文本。
  final String text;

  /// 归一化坐标（0–1），顺序为 left, top, right, bottom。
  ///
  /// 使用归一化坐标而非像素坐标，这样图片被缩放后仍能准确定位。
  final List<double> bbox;

  /// 置信度 0–1。部分平台（如 WinRT OCR）不提供，则为 null。
  final double? confidence;

  const OcrBlock({
    required this.text,
    required this.bbox,
    this.confidence,
  });

  double get left => bbox.isNotEmpty ? bbox[0] : 0;
  double get top => bbox.length > 1 ? bbox[1] : 0;
  double get right => bbox.length > 2 ? bbox[2] : 0;
  double get bottom => bbox.length > 3 ? bbox[3] : 0;
}

/// 一次 OCR 的完整结果。
class OcrResult {
  /// 全部文本块，按阅读顺序排列。
  final List<OcrBlock> blocks;

  /// 使用的引擎标识，用于问题排查（如 `winrt`、`mlkit`、`vision`、`mock`）。
  final String engine;

  /// 耗时（毫秒）。
  final int elapsedMs;

  /// 整体置信度 0–1。无法计算时为 null。
  final double? overallConfidence;

  const OcrResult({
    required this.blocks,
    required this.engine,
    this.elapsedMs = 0,
    this.overallConfidence,
  });

  /// 空结果。
  static const OcrResult empty = OcrResult(blocks: [], engine: 'none');

  bool get isEmpty => blocks.isEmpty;
  bool get isNotEmpty => blocks.isNotEmpty;

  /// 把全部文本块按阅读顺序拼成多行文本。
  String get plainText => blocks.map((b) => b.text).join('\n');
}

/// 端侧文字识别。**只负责普通文本**，数学公式走云端链路（见 `services/ocr`）。
abstract class OcrService {
  /// 该平台是否支持端侧 OCR。
  bool get isAvailable;

  /// 识别图片中的文字。
  ///
  /// 失败时应抛出 [OcrException]，不要返回空结果掩盖错误。
  Future<OcrResult> recognizeText(Uint8List imageBytes);

  /// 释放底层资源。
  Future<void> dispose();
}

class OcrException implements Exception {
  final String message;
  final Object? cause;
  const OcrException(this.message, [this.cause]);
  @override
  String toString() => 'OcrException: $message${cause == null ? '' : ' ($cause)'}';
}

// ─────────────────────────────────────────────────────────────────────────────
// 图片 / 文件来源
// ─────────────────────────────────────────────────────────────────────────────

/// 用户选中的文件。
class PickedFile {
  final String path;
  final String name;
  final int sizeBytes;
  final Uint8List? bytes;

  const PickedFile({
    required this.path,
    required this.name,
    this.sizeBytes = 0,
    this.bytes,
  });
}

/// 图片来源。各平台能力差异最大的一个接口。
///
/// - 移动端：相机 + 相册
/// - **桌面端：只有文件选择器**（PC 上没有"对着屏幕拍题"的场景）
abstract class ImageSourceService {
  /// 是否支持拍照。
  bool get supportsCamera;

  /// 是否支持选择整个文件夹（批量导入题库，桌面端核心优势）。
  bool get supportsDirectoryPicker;

  /// 拍照。不支持时抛 [UnsupportedError]。
  Future<PickedFile?> pickFromCamera();

  /// 从相册 / 图片库选择单张。
  Future<PickedFile?> pickImage();

  /// 选择多张图片（批量导入）。
  Future<List<PickedFile>> pickMultipleImages();

  /// 选择若干 PDF（批量导入题库）。
  Future<List<PickedFile>> pickPdfs();

  /// 选择一个文件夹，返回其中的图片与 PDF 列表。
  ///
  /// 这是 PC 版的核心入口：一次导入整个题库文件夹。
  Future<List<PickedFile>> pickDirectory();
}

// ─────────────────────────────────────────────────────────────────────────────
// 安全存储（API Key）
// ─────────────────────────────────────────────────────────────────────────────

/// 安全存储。用于保存用户自带的 LLM API Key。
///
/// 实现要求：
/// - Windows → DPAPI
/// - Android → EncryptedSharedPreferences / Keystore
/// - iOS / macOS → Keychain
///
/// ⚠️ **绝不能把密钥写进普通配置文件或日志。**
abstract class SecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<void> deleteAll();

  /// 读取密钥的掩码形式，用于 UI 展示（如 `sk-••••••••3f2a`）。
  Future<String?> readMasked(String key);
}

// ─────────────────────────────────────────────────────────────────────────────
// 本地通知
// ─────────────────────────────────────────────────────────────────────────────

/// 本地通知。用于复习提醒。
///
/// 纯本地架构下**没有服务器推送**，因此所有提醒都是本地定时任务。
/// 局限：App 被彻底杀掉后，部分平台的定时通知可能不触发。
abstract class NotifyService {
  /// 请求通知权限，返回是否授予。
  Future<bool> requestPermission();

  /// 安排每日复习提醒。
  Future<void> scheduleDailyReminder({
    required int hour,
    required int minute,
    required int dueCount,
  });

  /// 立即发一条通知（如"标注完成"）。
  Future<void> show({
    required String title,
    required String body,
    String? payload,
  });

  /// 取消全部已安排的提醒。
  Future<void> cancelAll();
}

// ─────────────────────────────────────────────────────────────────────────────
// 服务聚合
// ─────────────────────────────────────────────────────────────────────────────

/// 平台服务聚合入口。
///
/// 由 `main.dart` 在启动时注入具体实现。
/// 测试时注入 Mock 实现即可，无需真机。
class PlatformServices {
  final OcrService ocr;
  final ImageSourceService imageSource;
  final SecureStore secureStore;
  final NotifyService notify;

  const PlatformServices({
    required this.ocr,
    required this.imageSource,
    required this.secureStore,
    required this.notify,
  });

  static PlatformServices? _instance;

  /// 全局实例。必须在 `main()` 里先调用 [install]。
  static PlatformServices get instance {
    final i = _instance;
    if (i == null) {
      throw StateError(
        'PlatformServices 尚未初始化。请在 main() 中先调用 '
        'PlatformServices.install(...)。',
      );
    }
    return i;
  }

  static bool get isInstalled => _instance != null;

  static void install(PlatformServices services) => _instance = services;

  /// 仅供测试使用。
  static void reset() => _instance = null;
}
