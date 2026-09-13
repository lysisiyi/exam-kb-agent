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
    final size = options.fontSize ?? (display ? 16.0 : 14.0);

    final widget = _renderTex(latex, display: display, fontSize: size,
        color: options.color);

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
    final size = options.fontSize ?? 14.0;
    final spans = _parseInline(markdown, size, options.color);

    final text = Text.rich(
      TextSpan(children: spans),
      style: TextStyle(
        fontSize: size,
        color: options.color,
        height: 1.9,
      ),
    );

    // `selectable` 时包一层可选区 —— 让用户能复制 LaTeX 源码。
    return options.selectable ? SelectionArea(child: text) : text;
  }

  @override
  bool supports(String latex) => true;

  @override
  String get name => splitCjk ? 'katex(+cjk-split)' : 'katex';

  // ───────────────────────────────────────────────────────────────────────
  // 内部
  // ───────────────────────────────────────────────────────────────────────

  /// 渲染一条公式，失败时降级为源码。
  Widget _renderTex(
    String tex, {
    required bool display,
    required double fontSize,
    Color? color,
    Key? key,
  }) {
    if (!splitCjk) {
      return katex.Math(
        tex,
        key: key,
        displayMode: display,
        fontSize: fontSize,
        color: color,
      );
    }

    final chunks = splitLatexText(tex);
    if (chunks.length == 1 && chunks.first is LatexChunk) {
      return katex.Math(
        tex,
        key: key,
        displayMode: display,
        fontSize: fontSize,
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
                  fontSize: fontSize,
                  color: color,
                ),
              TextChunk(:final text) => TextSpan(
                  text: text,
                  style: TextStyle(fontSize: fontSize, color: color),
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
  List<InlineSpan> _parseInline(String src, double fontSize, Color? color) {
    final spans = <InlineSpan>[];
    final buffer = StringBuffer();

    void flushText() {
      if (buffer.isEmpty) return;
      spans.add(TextSpan(
        text: buffer.toString(),
        style: TextStyle(fontSize: fontSize, color: color),
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
          fontSize: fontSize,
          color: color,
        ),
      ));
      i = close + delim.length;
    }

    flushText();
    if (spans.isEmpty) {
      return [TextSpan(text: src, style: TextStyle(fontSize: fontSize, color: color))];
    }
    return spans;
  }
}
