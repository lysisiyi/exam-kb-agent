/// 把公式渲成 PNG 图片，供 PDF 嵌入。
///
/// ## 为什么不直接在 PDF 里写字形
///
/// `pdf` 包用的是它自己那套字体（Helvetica 等），要画数学排版就得拿到
/// KaTeX 的字体文件、自己走一遍箱树、算好每个字形的坐标与字号。
/// 那条路的产出**几乎肯定会和屏幕上不一样** —— 两份独立的排版实现，
/// 迟早有一处对不上。
///
/// 改用 Flutter 自己的光栅化：`KatexBoxPainter` 画到离屏画布 → PNG →
/// 嵌进 PDF。代价是 PDF 里的公式是位图（放大看会糊），换来的是
/// **PDF 与屏幕逐像素一致**，而且不需要找字体文件。
///
/// ## 分辨率
///
/// 按 [pixelRatio] 放大光栅化再在 PDF 里缩回去。打印是 300 dpi 量级，
/// 所以默认 4.0 —— 一个 14px 的公式会按 56px 渲染。
/// 位图因此比矢量方案大，但一页 PDF 通常只有几十个公式，可接受。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:katex/katex.dart' as katex;
import 'package:katex_dart/katex_dart.dart' show KatexOptions, renderToBox;

/// 一张渲好的公式图。
class FormulaImage {
  final Uint8List png;

  /// 以逻辑像素计的尺寸（PDF 排版按它摆位）。
  final double width;
  final double height;

  const FormulaImage({
    required this.png,
    required this.width,
    required this.height,
  });

  double get aspectRatio => height == 0 ? 1 : width / height;
}

/// 公式光栅化器（带缓存）。
///
/// 缓存按 `公式 + 字号` 作键：一份卷子里同一个公式可能出现多次
/// （比如题干和解析里各一次），没必要渲两遍。
class FormulaRasterizer {
  final double pixelRatio;

  /// 公式文字颜色。
  final Color color;

  /// 缓存条数上限。见 [_remember]。
  final int maxEntries;

  final Map<String, FormulaImage> _cache = {};
  final List<String> _order = [];

  FormulaRasterizer({
    this.pixelRatio = 4.0,
    this.color = const Color(0xFF000000),
    this.maxEntries = 400,
  });

  int get cacheSize => _cache.length;

  /// 光栅化一条公式。失败返回 null —— 调用方负责降级成源码文本。
  Future<FormulaImage?> rasterize(
    String tex, {
    double fontSize = 14,
    bool displayMode = false,
  }) async {
    final key = '$fontSize|$displayMode|$tex';
    final hit = _cache[key];
    if (hit != null) return hit;

    try {
      final box = renderToBox(tex, options: KatexOptions(displayMode: displayMode));
      final logical = katex.boxSizePxPadded(box, fontSize);
      if (logical.width <= 0 || logical.height <= 0) return null;

      final w = (logical.width * pixelRatio).ceil();
      final h = (logical.height * pixelRatio).ceil();
      if (w <= 0 || h <= 0 || w > 8000 || h > 8000) return null;

      final recorder = ui.PictureRecorder();
      // 从 (0,0) 开始画：`boxSizePxPadded` 已经把 ink 溢出算进尺寸，
      // 而 painter 的 `inkPadEm` 会把原点挪到内边距之后
      final canvas = Canvas(
        recorder,
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      );
      canvas.scale(pixelRatio);
      // 白底：PDF 页面本身就是白的，透明底在阅读器里可能变黑
      canvas.drawRect(
        Rect.fromLTWH(0, 0, logical.width, logical.height),
        Paint()..color = const Color(0xFFFFFFFF),
      );
      katex.KatexBoxPainter(
        box,
        fontSize: fontSize,
        color: color,
        inkPadEm: katex.kInkOverflowPadEm,
      ).paint(canvas, logical);

      final picture = recorder.endRecording();
      final image = await picture.toImage(w, h);
      picture.dispose();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return null;

      final out = FormulaImage(
        png: data.buffer.asUint8List(),
        width: logical.width,
        // PDF 里按逻辑像素排，所以要减掉两边内边距之外的视觉高度吗？
        // 不减：内边距是刻意的防裁切余量，保留它排版更稳（见 kInkOverflowPadEm）
        height: logical.height,
      );
      _remember(key, out);
      return out;
    } catch (_) {
      // 非法 LaTeX：返回 null，调用方降级成源码文本
      return null;
    }
  }

  /// 记进缓存，并在超出上限时按 LRU 淘汰。
  ///
  /// ## 为什么必须有上限
  ///
  /// 缓存的每一份都是**原始 PNG 字节**（4 倍光栅化，一条公式几 KB 到几十 KB）。
  /// 早先这个 Map 没有上限：导出一册 5000 题的题库时，所有见过的公式都会
  /// 一直留在内存里 —— 那是几十 MB 级别的常驻，而且**永远不会被释放**，
  /// 因为导出器本身的寿命就是整个 App 会话。
  ///
  /// 400 条足够覆盖"一份卷子里公式重复出现"这个真实的复用场景
  /// （一份卷子 22 题，每题的题干/答案/解析里公式会重复），
  /// 又不会让内存随题库规模增长。
  void _remember(String key, FormulaImage img) {
    if (_cache.containsKey(key)) {
      _order.remove(key);
    }
    _cache[key] = img;
    _order.add(key);

    while (_order.length > maxEntries) {
      _cache.remove(_order.removeAt(0));
    }
  }
}

/// 把一段「Markdown + LaTeX 混排」拆成文本与公式交替的片段。
///
/// 与 `KatexRenderer._parseInline` 的切分规则保持一致（`$...$` 行内、
/// `$$...$$` 独立）—— 两边如果规则不同，PDF 与屏幕就会不一致。
sealed class MarkdownPiece {
  const MarkdownPiece();
}

class TextPiece extends MarkdownPiece {
  final String text;
  const TextPiece(this.text);
}

class FormulaPiece extends MarkdownPiece {
  final String tex;
  final bool display;
  const FormulaPiece(this.tex, {this.display = false});
}

/// 切分。没有公式时返回单个 [TextPiece]。
List<MarkdownPiece> splitMarkdownPieces(String src) {
  final out = <MarkdownPiece>[];
  final buffer = StringBuffer();

  void flush() {
    if (buffer.isEmpty) return;
    out.add(TextPiece(buffer.toString()));
    buffer.clear();
  }

  var i = 0;
  while (i < src.length) {
    if (src[i] != r'$') {
      buffer.write(src[i]);
      i++;
      continue;
    }
    final isDisplay = src.startsWith(r'$$', i);
    final delim = isDisplay ? r'$$' : r'$';
    final close = src.indexOf(delim, i + delim.length);
    if (close < 0) {
      // 没有收尾 —— 当普通文本，别把后面的内容吞掉
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
    flush();
    out.add(FormulaPiece(tex, display: isDisplay));
    i = close + delim.length;
  }

  flush();
  if (out.isEmpty) out.add(TextPiece(src));
  return out;
}
