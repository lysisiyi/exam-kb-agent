/// Windows 端侧 OCR —— **暂未实现**，这是有意的设计决定。
///
/// ## 为什么不实现
/// Windows 的文字识别走 WinRT 的 `Windows.Media.Ocr`，这需要
/// C++/WinRT 原生插件 + Dart Native Assets 构建。
///
/// 现有第三方包（`platform_ocr`、`flutter_ocr_native`）都能做，但：
///
/// 1. **构建风险**：Native Assets 需要现场编译 C++。一旦编译失败，
///    **整个 App 都构建不出来** —— 为了一个次要功能赌上主流程不划算。
/// 2. **收益有限**：PC 版的录入主路径是「从 PDF/图片批量导入」，
///    不是"拍一张识别一张"。端侧 OCR 的真实用武之地在移动端。
/// 3. **公式仍要上云**：端侧 OCR 只能识别普通文本，数学公式必须走
///    云端公式识别 API（UniMERNet 级别的模型跑不在端侧）。
///    所以即使实现了端侧 OCR，录入链路也不会因此完整。
///
/// ## 替代路径
/// - **手输 LaTeX**（公式快捷键盘）—— V1 已规划，覆盖率 100%
/// - **粘贴 LaTeX** —— 支持
/// - **云端多模态识别** —— 用用户自己的 API Key 调 Vision 模型，
///   链路短、无需原生编译（M4 实现）
///
/// ## 何时补上
/// 等 M4 录入闭环验证通过、且移动端需求明确后再做。
/// 届时只需替换 [PlatformServices.ocr] 的注入，调用方不用改。
library;

import 'dart:typed_data';

import 'platform_services.dart';

/// 不可用的 OCR 实现。
///
/// `isAvailable` 恒为 false，UI 据此隐藏"识别图片中的文字"入口，
/// 而不是弹一个失败对话框。
class UnavailableOcrService implements OcrService {
  const UnavailableOcrService();

  @override
  bool get isAvailable => false;

  @override
  Future<OcrResult> recognizeText(Uint8List imageBytes) async {
    throw const OcrException(
      'Windows 版暂不支持端侧文字识别。\n'
      '可选替代方案：\n'
      '  1. 用公式键盘手动输入\n'
      '  2. 粘贴已有的 LaTeX\n'
      '  3. 配置 API Key 后使用云端识别（M4 提供）',
    );
  }

  @override
  Future<void> dispose() async {}
}
