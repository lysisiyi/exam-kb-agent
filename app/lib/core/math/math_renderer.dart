/// 数学公式渲染抽象层。
///
/// ## 为什么必须抽象
/// Flutter 生态里的 LaTeX 渲染方案**全部有停维护风险**：
/// - `flutter_math` —— 2020 年后无更新，已废弃
/// - `flutter_math_fork` —— 最新版已是一年多以前
/// - `katex`（Dart 移植）—— 较新，但需实测确认
/// - `flutter_tex` —— 基于 MathJax，部分实现走 WebView
///
/// 渲染库是这类 App 的长期风险点。**不抽象就一定会在某次 Flutter 升级时被卡死。**
///
/// 因此业务代码一律通过 [MathRenderer] 渲染，底层用哪个包可以随时替换。
library;

import 'package:flutter/widgets.dart';

/// 公式的排版模式。
enum MathStyle {
  /// 行内公式，与文字同基线，可折行。
  inline,

  /// 独立公式，居中显示，不折行（超宽时横向滚动）。
  display,
}

/// 渲染配置。
class MathRenderOptions {
  /// 字号。null 表示继承父级样式。
  final double? fontSize;

  /// 文字颜色。
  final Color? color;

  /// 是否允许选中复制（用于让用户复制 LaTeX 源码）。
  final bool selectable;

  const MathRenderOptions({
    this.fontSize,
    this.color,
    this.selectable = false,
  });

  static const MathRenderOptions none = MathRenderOptions();
}

/// 公式渲染器接口。
///
/// 实现类必须满足：
/// 1. **不阻塞主线程** —— 解析必须在构建阶段保持廉价（配合缓存层）
/// 2. **解析失败不崩溃** —— 非法 LaTeX 应降级为等宽源码显示
/// 3. **无网络依赖** —— 纯本地渲染，离线可用
abstract class MathRenderer {
  /// 渲染单个公式。
  Widget render(
    String latex, {
    MathStyle style = MathStyle.inline,
    MathRenderOptions options = MathRenderOptions.none,
  });

  /// 渲染一段 Markdown + LaTeX 混排文本。
  ///
  /// 实现需要：
  /// - 识别 `$...$`（行内）与 `$$...$$`（独立）
  /// - 其余部分按 Markdown 基础语法渲染（粗体、斜体、列表、图片）
  /// - 支持 `![alt](path)` 图片
  Widget renderMarkdown(
    String markdown, {
    MathRenderOptions options = MathRenderOptions.none,
  });

  /// 该实现是否支持某个 LaTeX 宏/环境。
  ///
  /// 用于决定是否需要降级到备用渲染器。
  bool supports(String latex);

  /// 实现标识，用于日志与调试。
  String get name;
}

/// 渲染缓存：包一层 LRU，避免列表滚动时重复解析同一公式。
///
/// ## 为什么这是必须的
/// 错题本列表每一项可能有 3–5 个公式。如果每次滚动都重新解析 LaTeX，
/// **低端机必然掉帧**。这是本项目最大的性能风险，不是 CPU 不够。
class MathRenderCache {
  final int maxEntries;
  final Map<String, Widget> _cache = {};
  final List<String> _order = [];

  MathRenderCache({this.maxEntries = 400});

  /// 缓存键。
  ///
  /// 颜色用 `toARGB32()` 而非已废弃的 `.value` —— Flutter 3.27 起
  /// `Color.value` 被弃用（因为宽色域颜色无法用 32 位整数完整表示），
  /// 需要显式取 ARGB 时应用 `toARGB32()`。
  String _key(String latex, MathStyle style, MathRenderOptions o) =>
      '${style.name}|${o.fontSize}|${o.color?.toARGB32()}|${o.selectable}|$latex';

  /// 取缓存，未命中则用 [build] 生成并存入。
  Widget getOrBuild(
    String latex,
    MathStyle style,
    MathRenderOptions options,
    Widget Function() build,
  ) {
    final k = _key(latex, style, options);
    final hit = _cache[k];
    if (hit != null) return hit;

    final built = build();
    _cache[k] = built;
    _order.add(k);

    // 超出上限时按插入顺序淘汰最旧的
    while (_order.length > maxEntries) {
      final oldest = _order.removeAt(0);
      _cache.remove(oldest);
    }
    return built;
  }

  void clear() {
    _cache.clear();
    _order.clear();
  }

  int get size => _cache.length;
}

/// 带缓存的渲染器包装。业务代码应当用它，而不是直接用底层渲染器。
class CachedMathRenderer implements MathRenderer {
  final MathRenderer inner;
  final MathRenderCache cache;

  CachedMathRenderer(this.inner, {MathRenderCache? cache})
      : cache = cache ?? MathRenderCache();

  @override
  Widget render(
    String latex, {
    MathStyle style = MathStyle.inline,
    MathRenderOptions options = MathRenderOptions.none,
  }) =>
      cache.getOrBuild(
        latex,
        style,
        options,
        () => inner.render(latex, style: style, options: options),
      );

  @override
  Widget renderMarkdown(
    String markdown, {
    MathRenderOptions options = MathRenderOptions.none,
  }) =>
      inner.renderMarkdown(markdown, options: options);

  @override
  bool supports(String latex) => inner.supports(latex);

  @override
  String get name => 'cached(${inner.name})';
}

/// 兜底渲染器：不渲染公式，只把 LaTeX 源码用等宽字体显示。
///
/// 用途：
/// - 渲染库初始化失败时保证 App 不白屏
/// - 单元测试（避免依赖具体渲染实现）
class PlainTextMathRenderer implements MathRenderer {
  const PlainTextMathRenderer();

  @override
  Widget render(
    String latex, {
    MathStyle style = MathStyle.inline,
    MathRenderOptions options = MathRenderOptions.none,
  }) {
    final text = Text(
      latex,
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: options.fontSize ?? (style == MathStyle.display ? 14 : 13),
        color: options.color,
        height: 1.6,
      ),
    );
    return style == MathStyle.display
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Center(child: text),
          )
        : text;
  }

  @override
  Widget renderMarkdown(
    String markdown, {
    MathRenderOptions options = MathRenderOptions.none,
  }) =>
      Text(
        markdown,
        style: TextStyle(
          fontSize: options.fontSize ?? 14,
          color: options.color,
          height: 1.9,
        ),
      );

  @override
  bool supports(String latex) => true;

  @override
  String get name => 'plain';
}

/// 全局渲染器注册点。
///
/// `main()` 里注入具体实现，业务代码通过 [MathRendering.renderer] 取用。
class MathRendering {
  const MathRendering._();

  static MathRenderer? _renderer;

  static MathRenderer get renderer => _renderer ?? const PlainTextMathRenderer();

  static bool get isConfigured => _renderer != null;

  /// 注入实现。建议传入 [CachedMathRenderer] 包装后的实例。
  static void install(MathRenderer renderer) => _renderer = renderer;

  /// 仅供测试。
  static void reset() => _renderer = null;
}
