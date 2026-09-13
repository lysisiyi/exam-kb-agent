/// 运行平台能力探测。
///
/// 通过**条件导入**在编译期选择实现，因此：
/// - 桌面/移动端构建时 `dart:io` 可用，走 [_io] 实现
/// - Web 构建时 `dart:io` 不可用，自动回落到 [_stub]，**不会编译失败**
///
/// 所有需要判断"当前平台是什么"的代码都应通过这里，而不是直接
/// `import 'dart:io'` —— 否则以后加 Web 版会编译不过。
library;

export 'capabilities_stub.dart'
    if (dart.library.io) 'capabilities_io.dart';
