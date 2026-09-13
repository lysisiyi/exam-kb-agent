/// 原生平台（Windows / macOS / Linux / Android / iOS）的能力探测实现。
library;

import 'dart:io' show Platform;

/// 平台能力探测。
class PlatformCapabilities {
  const PlatformCapabilities._();

  /// 是否运行在传统桌面操作系统上（Windows / macOS / Linux）。
  static bool get isDesktopOS =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// 是否运行在移动操作系统上（Android / iOS）。
  static bool get isMobileOS => Platform.isAndroid || Platform.isIOS;

  static bool get isWindows => Platform.isWindows;
  static bool get isMacOS => Platform.isMacOS;
  static bool get isLinux => Platform.isLinux;
  static bool get isAndroid => Platform.isAndroid;
  static bool get isIOS => Platform.isIOS;
  static bool get isWeb => false;

  /// 是否应启用鼠标/键盘交互（悬停、右键菜单、快捷键）。
  ///
  /// ⚠️ **不要用它来决定布局**。布局一律用宽度断点
  /// （见 `core/layout/breakpoints.dart`）——否则 Windows 窗口被拖窄、
  /// 或 iPad 分屏时布局会崩。这个标志只用于交互层判断。
  static bool get usesDesktopInteractions => isDesktopOS;

  /// 是否具备摄像头拍照路径。
  ///
  /// PC 有摄像头硬件，但**用户不会对着电脑拍错题**，
  /// 所以桌面端判定为"没有拍照录入场景"。
  static bool get hasCamera => isMobileOS;

  /// 是否支持选择整个文件夹（批量导入题库）。
  ///
  /// 这是桌面端的核心优势：一次性导入几百道题。
  static bool get supportsDirectoryPicker => isDesktopOS;

  /// 人类可读的平台名，用于日志与错误上报。
  static String get name {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }

  /// 数据目录建议名。
  ///
  /// 实际路径必须用 `path_provider` 获取，**绝不要拼绝对路径**：
  /// - Windows: `%APPDATA%\kaoyan_math_agent`
  /// - macOS:   `~/Library/Application Support/kaoyan_math_agent`
  /// - iOS:     应用沙箱内，且受备份策略影响
  static String get appDataFolderName => 'kaoyan_math_agent';
}
