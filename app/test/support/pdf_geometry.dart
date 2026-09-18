/// 从导出的 PDF 字节里量排版几何：文字行基线、图片框。
///
/// ## 为什么测试里要解 PDF 内容流
///
/// 行内公式的**垂直对齐**是这份导出器里唯一用普通断言覆盖不到的性质。
/// 它取决于 `pdf` 包 `WidgetSpan.baseline` 的锚点约定 —— 那里锚的是控件
/// **底边**（把底边放在 `文字基线 + baseline` 处），而不是 Flutter 文档里
/// 的"顶到自己基线的距离"。约定用错了**不会有任何报错**：
/// 公式只是静静地整体浮高一个图片高度（约 12pt，正好一行），
/// 单元测试全绿、PDF 照常生成，只有量真实产出才发现。
///
/// 所以这里解析 PDF 内容流，把"对齐"变成可以断言的两个数：
/// 文字基线 y、公式图片框的上下边 y。
///
/// ## 解析范围
///
/// 只用本导出器会碰到的算子：`q` / `Q` / `cm`（当前变换矩阵的平移）、
/// `Td` / `Tm`（文字定位）、`TJ`（画字）、`Do`（画图）。
/// 内容流是 Flate 压缩的，用 `dart:io` 的 `zlib` 解开即可。
///
/// `pdf` 包换了输出格式的话这些量会**直接失败**（找不到图、基线数不对），
/// 不会悄悄放过 —— 这正是想要的行为。
///
/// ⚠️ 已知局限：
/// - 算子是用正则从内容流里挑的，没有做完整的 PDF 词法分析。
///   如果某段可见文字里正好出现独立的 `q`/`Q` 会干扰矩阵栈。测试里用的
///   中文题干不会出现这种情况。
/// - 只解析**含 `BT`（有文字绘制）**的内容流。纯图页会被跳过 ——
///   本导出器每一页都有文字，够用；要用在别处得先补这一条。
library;

import 'dart:convert';
import 'dart:io';

/// 一条文字行：页内绝对基线 y，以及这一行画了几个字形。
class PdfTextLine {
  const PdfTextLine(this.baselineY, this.glyphs);

  /// 基线在页面坐标系里的 y（单位 pt，PDF 的 y 轴向上）。
  final double baselineY;

  /// 这一行画了多少个字形（用来滤掉空行）。
  final int glyphs;
}

/// 一个图片框：左下角 + 尺寸，页内绝对坐标。
class PdfImageBox {
  const PdfImageBox({
    required this.left,
    required this.bottom,
    required this.width,
    required this.height,
  });

  final double left;

  /// 图片**底边**的 y（PDF 的 y 轴向上，所以这是较小的那个 y）。
  final double bottom;

  final double width;
  final double height;

  double get top => bottom + height;
  double get centerY => bottom + height / 2;
}

/// 一页内容流里量到的几何。
class PdfPageGeometry {
  PdfPageGeometry(this.lines, this.images);

  final List<PdfTextLine> lines;
  final List<PdfImageBox> images;

  /// 每一条文字行，按基线从高到低（页面从上到下）。
  List<PdfTextLine> get linesTopDown {
    final out = [...lines]..sort((a, b) => b.baselineY.compareTo(a.baselineY));
    return out;
  }
}

// 数字（可带负号与小数点）。注意：下面的正则要**插值**，所以用普通字符串，
// 不能用 `r'...'`（原始字符串不插值，会把 `$_num` 原样写进正则）。
const String _num = r'[0-9.\-]+';
final RegExp _ops = RegExp(
  // `q` / `Q` 要避开可见文字里的字母
  '(?<q>(?<![A-Za-z0-9])q(?![A-Za-z0-9]))'
  '|(?<pop>(?<![A-Za-z0-9])Q(?![A-Za-z0-9]))'
  '|(?<cm>(?<c1>$_num) (?<c2>$_num) (?<c3>$_num) '
      '(?<c4>$_num) (?<c5>$_num) (?<c6>$_num) cm)'
  '|(?<td>(?<tdx>$_num) (?<tdy>$_num) Td)'
  '|(?<tm>$_num $_num $_num $_num (?<t5>$_num) (?<t6>$_num) Tm)'
  '|(?<tj>\\[(?<arr>[^\\]]*)\\]TJ)'
  '|(?<do>/[A-Za-z0-9]+ Do)',
);

final RegExp _hexOrLit = RegExp(r'<[0-9A-Fa-f]+>|\([^)]*\)');

/// 量出 PDF 里每一页的文字行与图片框。
List<PdfPageGeometry> measurePdf(List<int> bytes) {
  final out = <PdfPageGeometry>[];
  for (final content in _contentStreams(bytes)) {
    out.add(_measurePage(content));
  }
  return out;
}

/// 解压出所有带文字绘制的页面内容流。
Iterable<String> _contentStreams(List<int> raw) sync* {
  for (var i = 0; i < raw.length - 6; i++) {
    if (!_matches(raw, i, 'stream')) continue;
    var start = i + 6;
    if (start < raw.length && raw[start] == 0x0D) start++;
    if (start < raw.length && raw[start] == 0x0A) start++;
    final end = _indexOf(raw, 'endstream', start);
    if (end < 0) break;

    var stop = end;
    while (stop > start && (raw[stop - 1] == 0x0A || raw[stop - 1] == 0x0D)) {
      stop--;
    }
    if (stop > start) {
      try {
        final text = latin1.decode(zlib.decode(raw.sublist(start, stop)));
        if (text.contains('BT')) yield text;
      } catch (_) {
        // 不是 zlib 流（图片、字体文件等）：跳过
      }
    }
    i = end;
  }
}

PdfPageGeometry _measurePage(String content) {
  final lines = <PdfTextLine>[];
  final images = <PdfImageBox>[];

  // 图形状态栈：只跟踪平移分量（本文件里的矩阵线性部分只有单位阵与缩放）
  final stack = <List<double>>[];
  var tx = 0.0, ty = 0.0;
  var tdY = 0.0;
  var lastA = 1.0, lastD = 1.0;

  for (final m in _ops.allMatches(content)) {
    if (m.namedGroup('q') != null) {
      stack.add([tx, ty]);
    } else if (m.namedGroup('pop') != null) {
      if (stack.isNotEmpty) {
        final p = stack.removeLast();
        tx = p[0];
        ty = p[1];
      }
    } else if (m.namedGroup('cm') != null) {
      // `a b c d e f cm`：a/d 是缩放（图片的宽高），e/f 是平移
      lastA = double.parse(m.namedGroup('c1')!);
      lastD = double.parse(m.namedGroup('c4')!);
      tx += double.parse(m.namedGroup('c5')!);
      ty += double.parse(m.namedGroup('c6')!);
    } else if (m.namedGroup('td') != null) {
      tdY = double.parse(m.namedGroup('tdy')!);
    } else if (m.namedGroup('tm') != null) {
      tdY = double.parse(m.namedGroup('t6')!);
    } else if (m.namedGroup('tj') != null) {
      final g = _glyphs(m.namedGroup('arr')!);
      if (g > 0) lines.add(PdfTextLine(_round(ty + tdY), g));
    } else if (m.namedGroup('do') != null) {
      images.add(
        PdfImageBox(
          left: _round(tx),
          bottom: _round(ty),
          width: _round(lastA.abs()),
          height: _round(lastD.abs()),
        ),
      );
    }
  }

  return PdfPageGeometry(lines, images);
}

/// `[...]TJ` 里画了几个字形：Identity-H 的 `<hex>` 两字节一个，
/// 拉丁文本走 `(literal)`。
int _glyphs(String arr) {
  var n = 0;
  for (final item in _hexOrLit.allMatches(arr)) {
    final s = item.group(0)!;
    n += s.startsWith('<') ? (s.length - 2) ~/ 4 : s.length - 2;
  }
  return n;
}

double _round(double v) => (v * 100).roundToDouble() / 100;

bool _matches(List<int> b, int at, String s) {
  if (at + s.length > b.length) return false;
  for (var i = 0; i < s.length; i++) {
    if (b[at + i] != s.codeUnitAt(i)) return false;
  }
  return true;
}

int _indexOf(List<int> b, String s, int from) {
  for (var i = from; i + s.length <= b.length; i++) {
    if (_matches(b, i, s)) return i;
  }
  return -1;
}
