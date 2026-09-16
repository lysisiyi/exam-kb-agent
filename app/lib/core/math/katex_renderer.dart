/// 基于 `katex` 的公式渲染器。
///
/// ## 架构位置
///
/// `MathRenderer`（抽象）→ 本文件（实现）→ `katex` + `katex_dart`（底层）。
/// 换渲染库时只换本文件，业务代码不动 —— 这正是那层抽象存在的理由。
///
/// ## 为什么不用 `renderToSvg`
///
/// `katex_dart` 能吐 SVG，但实测每条公式 **460 KiB**（其中 99.8% 是内嵌
/// KaTeX 字体 base64）、`renderToSvg` 0.92 ms/式。列表滚动时不可接受。
/// 而 `katex` 的 `KatexBoxPainter extends CustomPainter` 直接画 Canvas，
/// 只需要 `renderToBox` 的 **0.245 ms/式**，且不产任何中间字符串。
///
/// ## 中文怎么处理
///
/// `\text{中文}` 在 KaTeX 字体里没有字形。详见 `latex_text_split.dart`：
/// 能安全摘出来的（96.1%）摘成普通文本交给 Flutter 排，
/// 摘不掉的（`\left..\right` 内、环境内、命令参数、上下标）原样交给 katex。
///
/// ## 缓存
///
/// 本类**不自己做缓存** —— 那是 `CachedMathRenderer` 的职责，两者可自由组合。
/// 在这里再缓一份只会让"到底哪一层在缓存"变得难查。
library;

import 'package:flutter/material.dart';
import 'package:katex/katex.dart' as katex;

import 'latex_text_split.dart';
import 'math_renderer.dart';

/// 用 `katex` 渲染公式。
class KatexRenderer implements MathRenderer {
  /// 是否把 `\text{中文}` 摘出来交给 Flutter 排。
  ///
  /// 默认开。留成参数是为了在真机上对比两种行为 —— 字体回退到底行不行
  /// 在 widget 测试里验证不了（测试用 Ahem 字体，所有字形都是方框），
  /// 只能靠真机截图。
  final bool splitCjk;

  /// 解析失败时的降级样式（等宽红字，与 `katex` 自带兜底一致）。
  final Color fallbackColor;

  const KatexRenderer({
    this.splitCjk = true,
    this.fallbackColor = const Color(0xFFCC0000),
  });

  @override
  Widget render(
    String latex, {
    MathStyle style = MathStyle.inline,
    MathRenderOptions options = MathRenderOptions.none,
  }) {
    final display = style == MathStyle.display;
    final base = options.fontSize ?? (display ? 16.0 : 14.0);

    // 见 [_scaleFor]：公式必须自己乘上系统字号，因为 `katex` 内部的
    // `TextPainter` 不带 `TextScaler`（而旁边的中文由 Flutter 自动缩放）。
    final widget = Builder(
      builder: (context) => _renderTex(
        latex,
        display: display,
        mathFontSize: base * scaleFor(context),
        textFontSize: base,
        color: options.color,
      ),
    );

    if (!display) return widget;
    // 独立公式：居中 + 上下留白（与纯文本兜底渲染器的行为一致）
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(child: widget),
    );
  }

  @override
  Widget renderMarkdown(
    String markdown, {
    MathRenderOptions options = MathRenderOptions.none,
  }) {
    final base = options.fontSize ?? 14.0;

    // 外面这层 Builder 只为了拿到 context 读系统字号。
    // 缓存层（`CachedMathRenderer`）存的就是这个 Builder，而它依赖
    // `MediaQuery` —— 用户改系统字号时 MediaQuery 变化会把这一层标脏，
    // 于是公式跟着重排。缩放为 1.0（绝大多数情况）时代价只是一个 Builder。
    return Builder(
      builder: (context) {
        final spans = _parseInline(
          markdown,
          base,
          options.color,
          mathFontSize: base * scaleFor(context),
        );

        final text = Text.rich(
          TextSpan(children: spans),
          style: TextStyle(
            fontSize: base,
            color: options.color,
            height: 1.9,
          ),
        );

        // `selectable` 时包一层可选区 —— 让用户能复制 LaTeX 源码。
        return options.selectable ? SelectionArea(child: text) : text;
      },
    );
  }

  @override
  bool supports(String latex) => true;

  @override
  String get name => splitCjk ? 'katex(+cjk-split)' : 'katex';

  /// 系统字号缩放系数。
  ///
  /// ## 为什么公式必须自己乘
  ///
  /// 混排时中文走普通 `TextSpan`，由 `Text.rich` 按 `MediaQuery.textScaler`
  /// **自动**缩放；而数学走 `WidgetSpan` 里的 `katex.Math`，它内部的
  /// `TextPainter` 不带 scaler（见 katex 的 `_RenderInlineMath._measure`：
  /// `boxSizePx(_box, _fontSize)`）。
  ///
  /// 结果是：系统字号调到 150% 时，同一条公式里**数学还是 1x、中文已经 1.5x**，
  /// 看起来像排版坏了。
  ///
  /// ⚠️ 只缩放**传给 katex 的字号**，不能连外围 `TextSpan` 一起乘 ——
  /// 那些 span 会被 Flutter 再缩放一次，变成双重缩放。
  static double scaleFor(BuildContext context) {
    final s = MediaQuery.textScalerOf(context).scale(1.0);
    // 防御：异常值不该让公式消失
    return (s.isFinite && s > 0) ? s : 1.0;
  }

  // ───────────────────────────────────────────────────────────────────────
  // 内部
  // ───────────────────────────────────────────────────────────────────────

  /// 渲染一条公式，失败时降级为源码。
  ///
  /// [mathFontSize] 是交给 katex 的字号（**已乘过系统缩放**）；
  /// [textFontSize] 是旁边中文用的字号（**未乘**，由 Flutter 自己缩放）。
  /// 两者分开正是为了不双重缩放，见 [scaleFor]。
  Widget _renderTex(
    String tex, {
    required bool display,
    required double mathFontSize,
    required double textFontSize,
    Color? color,
    Key? key,
  }) {
    if (!splitCjk) {
      return katex.Math(
        tex,
        key: key,
        displayMode: display,
        fontSize: mathFontSize,
        color: color,
      );
    }

    final chunks = splitLatexText(tex);
    if (chunks.length == 1 && chunks.first is LatexChunk) {
      return katex.Math(
        tex,
        key: key,
        displayMode: display,
        fontSize: mathFontSize,
        color: color,
      );
    }

    // 中英混排：用 RichText 把 katex 片段与中文交替排出来。
    // `mathSpan` 会给出行内公式的基线，所以中文与公式能自然对齐。
    return Text.rich(
      TextSpan(
        children: [
          for (final c in chunks)
            switch (c) {
              LatexChunk(:final tex) => katex.mathSpan(
                  tex,
                  displayMode: display,
                  fontSize: mathFontSize,
                  color: color,
                ),
              TextChunk(:final text) => TextSpan(
                  text: text,
                  style: TextStyle(fontSize: textFontSize, color: color),
                ),
            },
        ],
      ),
      key: key,
    );
  }

  /// 解析 Markdown 里的 `$...$` / `$$...$$`，产出 `InlineSpan` 列表。
  ///
  /// ## 范围说明
  ///
  /// 这里只处理**公式与文本的混排**，不做完整的 Markdown（粗体、列表、
  /// 引用）。理由：项目里 Markdown 只用于题干/答案/解析，而它们的实际用法
  /// 是"一段话 + 几个公式"；引入一个 Markdown 包会为了 5% 的语料
  /// 增加一层依赖和一个需要长期跟进的抽象。
  ///
  /// 需要完整 Markdown 时（例如将来要渲染列表和图片），
  /// 在这里接 `flutter_markdown` 的 builder 即可，本方法就是那个接缝。
  List<InlineSpan> _parseInline(
    String src,
    double textFontSize,
    Color? color, {
    required double mathFontSize,
  }) {
    final spans = <InlineSpan>[];
    final buffer = StringBuffer();

    void flushText() {
      if (buffer.isEmpty) return;
      spans.add(TextSpan(
        text: buffer.toString(),
        // 中文用**未缩放**的字号：`Text.rich` 会按 MediaQuery 自己缩放它，
        // 这里再乘一次就变成双重缩放
        style: TextStyle(fontSize: textFontSize, color: color),
      ));
      buffer.clear();
    }

    var i = 0;
    while (i < src.length) {
      if (src[i] != r'$') {
        buffer.write(src[i]);
        i++;
        continue;
      }

      // `$$...$$` 优先于 `$...$`
      final isDisplay = src.startsWith(r'$$', i);
      final delim = isDisplay ? r'$$' : r'$';
      final close = src.indexOf(delim, i + delim.length);
      if (close < 0) {
        // 没有收尾的美元符 —— 当普通文本，别吞掉内容
        buffer.write(src[i]);
        i++;
        continue;
      }

      final tex = src.substring(i + delim.length, close);
      if (tex.trim().isEmpty) {
        buffer.write(src.substring(i, close + delim.length));
        i = close + delim.length;
        continue;
      }

      flushText();
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: _renderTex(
          tex,
          display: isDisplay,
          mathFontSize: mathFontSize,
          textFontSize: textFontSize,
          color: color,
        ),
      ));
      i = close + delim.length;
    }

    flushText();
    if (spans.isEmpty) {
      return [
        TextSpan(
          text: src,
          style: TextStyle(fontSize: textFontSize, color: color),
        ),
      ];
    }
    return spans;
  }
}
