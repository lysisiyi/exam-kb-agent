/// 测试用的字体装载。
///
/// ## 为什么需要它
///
/// `flutter test` 默认只给一个**占位字体**（FlutterTest / Ahem）：
/// 每个字形都画成一个**实心方框**。对纯文本断言没影响（`find.text` 比的是
/// 字符串不是像素），但有两件事会被它毁掉：
///
/// 1. **公式位图**：KaTeX 的公式是靠字形**画**出来的。字体装不上，
///    光栅化出来就是一排黑块 —— 导出的 PDF 里公式全变黑块。
/// 2. 任何"看像素"的断言。
///
/// 这正是"样张里公式都是黑色色块"的成因：**样张是在测试里生成的**，
/// 而测试环境没有真的数学字体。
///
/// 真实 App 不受影响：`katex` 包的 `pubspec.yaml` 声明了 20 个 KaTeX 字体
/// （SIL OFL），构建系统会把它们打进资产并注册，`KatexBoxPainter` 用
/// `fontFamily: 'KaTeX_<name>'` + `package: 'katex'` 选中它们。
///
/// ## 为什么从 `FontManifest.json` 读而不是写死名单
///
/// 那份 manifest 就是**构建系统实际打包的那一份**（`rootBundle` 里就有）。
/// 于是"katex 不再声明字体"这类真实故障会让这里**什么都装不上**，
/// 依赖它的断言随之变红 —— 而不是安静地退回黑块、测试照样全绿。
/// 写死名单就失去了这个性质。
library;

import 'dart:convert';

// `FontLoader` 在 services.dart 里，**不在** flutter_test 里 ——
// 写 `import 'package:flutter_test/flutter_test.dart' show FontLoader;`
// 会报 undefined_shown_name。
import 'package:flutter/services.dart' show FontLoader, rootBundle;

/// 已装载的家族名（重复调用时跳过，`FontLoader` 重复注册会浪费不少时间）。
final Set<String> _loaded = {};

/// 把**所有**由本包依赖提供的字体装进测试环境。
///
/// 目前实际起作用的是 `katex` 的 20 个数学字体；写成"扫全 manifest"是为了
/// 将来引入别的带字体的包时不用再改这里。
///
/// 返回装载的家族数 —— 便于测试断言"确实装上了东西"。
///
/// ## 为什么是"按需调用"而不是全局自动装
///
/// Flutter 支持 `test/flutter_test_config.dart` 在**所有**测试前跑一段代码，
/// 把这件事做成全局的。**没有那样做**，因为装上真字体之后**文字度量会变**
/// （占位字体每个字形都是等宽方框，真字体的字宽/字高完全不同），
/// 那些依赖排版的断言（换行、溢出、列表项高度）会跟着变 ——
/// 而它们与"公式画得对不对"毫无关系。为了一个目的去动全局环境，
/// 代价是几十个不相关的用例要重新校准。
///
/// 所以只在**真的需要看像素**的地方显式调用：
/// `paper_export_test.dart` 里的公式墨迹断言与样张生成。
/// 将来若引入 golden 测试，那时再考虑全局装载 —— 那时度量变化是**要的**。
Future<int> loadBundledFonts() async {
  final raw = await rootBundle.loadString('FontManifest.json');
  final manifest = jsonDecode(raw);
  if (manifest is! List) return 0;

  var loaded = 0;
  for (final entry in manifest) {
    if (entry is! Map) continue;
    final family = entry['family']?.toString() ?? '';
    // 只装**包提供的**字体（`packages/<pkg>/<family>`）。
    // 应用自身声明的字体在测试里同样不会自动装，但当前项目一个都没有
    // （中文字体是运行时从系统读的，不走资产）。
    if (!family.startsWith('packages/')) continue;
    if (_loaded.contains(family)) {
      loaded++;
      continue;
    }

    final fonts = entry['fonts'];
    if (fonts is! List) continue;

    final loader = FontLoader(family);
    var added = 0;
    for (final f in fonts) {
      if (f is! Map) continue;
      final asset = f['asset']?.toString();
      if (asset == null || asset.isEmpty) continue;
      loader.addFont(rootBundle.load(asset));
      added++;
    }
    if (added == 0) continue;

    await loader.load();
    _loaded.add(family);
    loaded++;
  }
  return loaded;
}

/// 仅供测试：清掉"已装载"标记（正常情况下不需要）。
void resetLoadedFonts() => _loaded.clear();
