/// 截屏与帧级去重（V3_PLAN §4.1）。
///
/// 管线：全屏截图（`screen_capturer`）→ 按课时区域裁剪 → 感知哈希（aHash）→
/// 与上一帧比较，没换画面就不烧视觉调用。
///
/// 纯函数（裁剪 / 哈希 / 汉明距离）放在这里可单测；
/// 平台截图本身在测试环境不可用，接口隔离为 [ScreenCaptureService]。
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:screen_capturer/screen_capturer.dart' as sc;

/// 一次截屏的产物。
class CapturedFrame {
  final Uint8List jpegBytes;
  final int width;
  final int height;
  const CapturedFrame(this.jpegBytes, this.width, this.height);
}

/// 课时截图区域（相对全屏的像素矩形）。
class CaptureRect {
  final int x, y, w, h;
  const CaptureRect(this.x, this.y, this.w, this.h);

  static CaptureRect? tryParse(String? s) {
    if (s == null) return null;
    final parts = s.split(',').map((e) => int.tryParse(e.trim())).toList();
    if (parts.length != 4 || parts.any((e) => e == null || e < 0)) return null;
    final r = CaptureRect(parts[0]!, parts[1]!, parts[2]!, parts[3]!);
    if (r.w < 40 || r.h < 40) return null;
    return r;
  }

  @override
  String toString() => '$x,$y,$w,$h';
}

/// 平台截屏接口。真实实现走 `screen_capturer`；测试注入假实现。
abstract interface class ScreenCaptureService {
  /// 全屏截图（JPEG）。失败（无权限/无屏幕）返回 null，**不抛异常**——
  /// 伴学循环里截屏失败应当跳过这一帧并在 UI 如实提示，而不是中断会话。
  Future<CapturedFrame?> captureFullScreen();
}

/// `screen_capturer` 真实实现（Windows 走 Graphics Capture）。
class ScreenCaptureServiceImpl implements ScreenCaptureService {
  /// copyToClipboard 必须关：默认实现会**清空并占用剪贴板**，
  /// 伴学每 5 分钟劫持一次剪贴板，用户复制东西会莫名丢。
  @override
  Future<CapturedFrame?> captureFullScreen() async {
    try {
      final tmp = File(
          '${Directory.systemTemp.path}/yanban-frame-${DateTime.now().millisecondsSinceEpoch}.png');
      final result = await sc.ScreenCapturer.instance.capture(
        mode: sc.CaptureMode.screen,
        imagePath: tmp.path,
        copyToClipboard: false,
      );
      Uint8List? bytes = result?.imageBytes;
      if (bytes == null && tmp.existsSync()) bytes = tmp.readAsBytesSync();
      if (tmp.existsSync()) tmp.deleteSync();
      if (bytes == null || bytes.isEmpty) return null;
      final info = img.decodeImage(bytes);
      if (info == null) return null;
      final jpg = Uint8List.fromList(img.encodeJpg(info, quality: 88));
      return CapturedFrame(jpg, info.width, info.height);
    } catch (_) {
      return null; // 截屏失败如实返回 null，由会话层提示
    }
  }
}

/// 按区域裁剪 JPEG，返回新 JPEG。区域越界部分自动收缩。
CapturedFrame cropFrame(CapturedFrame frame, CaptureRect rect) {
  final image = img.decodeImage(frame.jpegBytes);
  if (image == null) return frame;
  final x = min(rect.x, image.width);
  final y = min(rect.y, image.height);
  final w = min(rect.w, image.width - x);
  final h = min(rect.h, image.height - y);
  if (w < 40 || h < 40) return frame;
  final cropped = img.copyCrop(image, x: x, y: y, width: w, height: h);
  final bytes = Uint8List.fromList(img.encodeJpg(cropped, quality: 82));
  return CapturedFrame(bytes, w, h);
}

/// 64 位平均哈希（aHash）：缩到 8×8 灰度，按均值出位。
int aHashOfJpeg(Uint8List jpegBytes) {
  final image = img.decodeImage(jpegBytes);
  if (image == null) return 0;
  final small = img.copyResize(image, width: 8, height: 8,
      interpolation: img.Interpolation.average);
  var sum = 0;
  final gray = List<int>.filled(64, 0);
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 8; x++) {
      final p = small.getPixel(x, y);
      // getLuminanceRgb 在 image 4.x 返回 num（可能整数运算溢出到 double）
      final g = img.getLuminanceRgb(p.r.toInt(), p.g.toInt(), p.b.toInt()).toInt();
      gray[y * 8 + x] = g;
      sum += g;
    }
  }
  final mean = sum ~/ 64;
  var hash = 0;
  for (var i = 0; i < 64; i++) {
    if (gray[i] > mean) hash |= 1 << i;
  }
  return hash;
}

/// 两帧哈希的汉明距离。
int hammingDistance(int a, int b) {
  var v = a ^ b;
  var count = 0;
  while (v != 0) {
    v &= v - 1;
    count++;
  }
  return count;
}

/// 与上一帧比，距离小于 [threshold] 视为"画面没换"——跳过，不烧调用。
/// 幻灯片式网课一半以上的定时截图是重复帧；这个判断让免费档频控更宽裕。
bool frameUnchanged(int lastHash, int currentHash, {int threshold = 6}) =>
    lastHash != 0 && hammingDistance(lastHash, currentHash) < threshold;

/// 区域内边距：裁剪时往里收一点，避开窗口边框与播放器控制条。
const uiEdgeInsets = EdgeInsetsLike(2, 2, 2, 60);

class EdgeInsetsLike {
  final int left, top, right, bottom;
  const EdgeInsetsLike(this.left, this.top, this.right, this.bottom);

  CaptureRect inset(CaptureRect r) => CaptureRect(
      r.x + left, r.y + top,
      max(40, r.w - left - right), max(40, r.h - top - bottom));
}
