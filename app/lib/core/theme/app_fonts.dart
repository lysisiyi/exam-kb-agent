/// 全局字体族链 —— 界面、等宽两条链的**唯一来源**。
///
/// ## 为什么需要集中声明
///
/// 这个项目此前**没有任何一处指定过中文字体族**：`AppTheme.light()` 构造
/// `ThemeData` 时没给 `fontFamily`，`AppTypography` 十来个 token 里只有
/// `mono` 写了 `'monospace'` —— 而 `'monospace'` **不是 Windows 上真实
/// 存在的字体族名**（Windows 的等宽字体叫 `Consolas`、`Courier New`），
/// 于是它的解析结果落在平台默认字体上，具体是哪个**不写在代码里**。
/// 结果是同一屏上的中文落在**四套互不相干的字体链**里：
///
/// | 文本来源 | 实际字体链 |
/// |---|---|
/// | 普通 `Text` | Flutter 默认字体 → Skia 隐式回退 |
/// | `mono` 样式 | 平台默认（族名未解析）→ 又一次回退 |
/// | 公式里摘出来的 `\text{中文}` | 继承外层样式（同样未指定字体） |
/// | 公式里摘不掉的 `\text{中文}` | `KaTeX_xxx`（无汉字字形、无 fallback） |
///
/// 用户看到的现象是「**字体类型不定**」：同一段中文在不同位置笔画粗细、
/// 字形都不一样。至于路径里的中文会不会变成方框，取决于各条链的隐式
/// 回退有没有命中 —— 那是一个**不由本项目控制**的结果，
/// 而显式声明把它变成了确定的。这正是这个文件存在的理由。
///
/// ## 为什么是这几条
///
/// - `Microsoft YaHei UI` —— 中文 Windows 的界面默认字体，优先用它
/// - `Microsoft YaHei` —— 上面那个的正文版，非 UI 场景的补充
/// - `Segoe UI` —— 系统拉丁字体，保证英文与数字的字形观感
/// - `SimHei` / `SimSun` —— 精简版 Windows 可能没装雅黑，黑体/宋体兜底
///
/// 这些字体**都是系统自带的**，不随包分发 —— 与 PDF 导出取本机中文字体
/// 是同一条原则（见 `core/platform/system_fonts.dart`）。
///
/// ## 某个字体不存在会怎样
///
/// Flutter 会把链上的家族**逐个试过来**，全都没有时才退回引擎默认。
/// 也就是说这条链**只会比不写更好**，不会因为某个字体缺失而变差 ——
/// 这也是敢把 5 个家族写进 fallback 的原因。
library;

import 'dart:ui' show FontWeight;

/// 字体族链。改这里就改了全应用。
abstract final class AppFonts {
  const AppFonts._();

  /// 界面字体链的首选家族。
  ///
  /// 单独列出来是因为 `ThemeData.fontFamily` 只接受**一个**名字，
  /// 链的其余部分要交给 `fontFamilyFallback`。
  static const String sans = 'Microsoft YaHei UI';

  /// 界面字体的后备链（**不含**首选）。
  static const List<String> sansFallback = [
    'Microsoft YaHei',
    'Segoe UI',
    'SimHei',
    'SimSun',
  ];

  /// 等宽字体首选。
  ///
  /// Consolas 是 Windows 上字宽与分辨率都合适的等宽字体，
  /// 用来显示 LaTeX 源码与文件路径。
  static const String mono = 'Consolas';

  /// 等宽字体的后备链。
  ///
  /// ⚠️ **这一条不是可选项**。`'monospace'` 在 Windows 上不是一个能解析的
  /// 字体族名，族名不落地就意味着"这段路径用哪个字体"不由代码决定；
  /// 而项目用等宽字体渲染的两处恰恰可能含中文：设置页的题库目录
  /// （`D:\我的题库\...`）与导出的目标目录。显式给出 Consolas +
  /// 中文回退，那两处的字体就从"看平台心情"变成确定的。
  static const List<String> monoFallback = [
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'SimHei',
  ];

  // ── 字重 ────────────────────────────────────────────────────────────────
  //
  // ## 依据（解析字体文件的名字表得来，不是推测）
  //
  // | 文件 | 族名 | 字重 |
  // |---|---|---|
  // | `msyh.ttc` | `Microsoft YaHei UI` | Regular |
  // | `msyhbd.ttc` | `Microsoft YaHei UI` | Bold |
  // | `msyhl.ttc` | `Microsoft YaHei UI Light` | Regular（**另一个族名**） |
  //
  // 也就是 [sans] 这个族**只有 Regular 与 Bold**（Light 是独立族名，
  // 不属于本族）。**没有 500，也没有 600。**
  //
  // ## 为什么必须只写这两个
  //
  // 请求一个不存在的字重**不会报错**，引擎按 CSS 规则取最近的现有字重：
  // `w500 → Regular`、`w600 → Bold`。于是代码写的和实际渲染的不是一回事 ——
  // 标 `w600` 的人以为是"半粗"，拿到手的是完整的 **Bold**。
  //
  // 这件事是可以量出来的。在用户反馈的那张图谱截图上（那一版还没声明
  // 字体族）实测：分支节点标 `w700`、叶子标 `w500`，同一个汉字（`数`、`分`）
  // 的笔画墨迹质量只差 **5%**，而真 Bold 与 Regular 该差 40% 以上 ——
  // 字重层级等于没生效。所以字重**不要靠"近似"**，只写真实存在的两个。
  //
  // 想要"半粗"就得换一个真有 Medium/Semibold 的族（如 Source Han Sans）。
  // 本项目的原则是用系统自带字体、不随包分发，所以不引入 —— 层级改用
  // 结构（色块/色条）与颜色表达，见 `knowledge_node_style.dart`。
  static const FontWeight regular = FontWeight.w400;
  static const FontWeight bold = FontWeight.w700;
}
