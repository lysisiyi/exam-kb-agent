/// Web / 未知平台的兜底实现。
///
/// 这个文件在 Web 构建时被选中（见 `capabilities.dart` 的条件导入）。
library;

/// 平台能力探测。
class PlatformCapabilities {
  const PlatformCapabilities._();

  /// 是否运行在传统桌面操作系统上（Windows / macOS / Linux）。
  static bool get isDesktopOS => false;

  /// 是否运行在移动操作系统上（Android / iOS）。
  static bool get isMobileOS => false;

  static bool get isWindows => false;
  static bool get isMacOS => false;
  static bool get isLinux => false;
  static bool get isAndroid => false;
  static bool get isIOS => false;
  static bool get isWeb => true;

  /// 是否应启用鼠标/键盘交互（悬停、右键菜单、快捷键）。
  ///
  /// 注意：**不要用它来决定布局**。布局一律用宽度断点
  /// （见 `core/layout/breakpoints.dart`）。这个标志只用于
  /// "是否画悬停高亮""是否注册 Ctrl+X 快捷键"这类交互层判断。
  static bool get usesDesktopInteractions => false;

  /// 是否具备摄像头拍照路径。
  static bool get hasCamera => false;

  /// 是否支持文件系统目录选择（批量导入题库）。
  static bool get supportsDirectoryPicker => false;

  /// 人类可读的平台名，用于日志与错误上报。
  static String get name => 'web';

  /// 数据目录建议名。
  static String get appDataFolderName => 'kaoyan_math_agent';
}
