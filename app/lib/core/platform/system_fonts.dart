/// 系统里可用的中文字体（用于把中文嵌进 PDF）。
///
/// ## 为什么用**系统已装**的字体，而不是随包内置
///
/// T43 记的是"导出的 PDF 里中文缺字形"。当初的结论是"两条出路都不划算"：
/// 联网下载（`PdfGoogleFonts`，破纯本地的承诺）或自带字体（+5–10 MB 包体）。
///
/// 看清 `pdf` 包的实际行为之后，这个二选一是假的：
///
/// 1. **`pdf` 包在写文件时只嵌入用到的字形** —— 它自带
///    `Font SubSetting CN` 测试。所以**PDF 文件本身不会变大**，
///    变的只是安装包。
/// 2. **中文 Windows 上这些字体本来就在** `%SystemRoot%\Fonts`。
///    读取用户机器上已装的字体、把用到的字形嵌进用户自己的文档，
///    是任何 Windows 程序打印时都在做的事，**不涉及再分发字体文件**。
///
/// 于是既不用联网、也不用给安装包加 10 MB。
///
/// ## 为什么只列单一 TTF
///
/// ⚠️ `pdf` 包的 `TtfParser` **不支持 TTC**（字体集合）——
/// 它的源码里没有任何一处处理 `ttcf` 头。而**宋体**（`simsun.ttc`）与
/// **微软雅黑**（`msyh.ttc`）都是 TTC。
///
/// 所以虽然宋体才是中文试卷的惯例正文体，这里用不了它，
/// 只能退到黑体（`simhei.ttf`，单一 TTF，笔画清晰，印刷可读）。
/// 这是本方案唯一的实质让步，写在这里免得下次有人以为忘了宋体。
///
/// ## 找不到字体时怎么办
///
/// 英文/精简版 Windows 可能一个都没有。此时返回 null，
/// **调用方必须如实告知**（见 `PaperPdfExporter` 的 caveats）——
/// 安静地输出一堆空白方框，正是这个缺陷当初难被发现的原因。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// 系统字体查找。全部方法**不抛异常**。
abstract final class SystemFonts {
  const SystemFonts._();

  /// 候选中文字体，按偏好顺序。
  ///
  /// 只列**单一 TTF**（TTC 不被 `pdf` 包支持，见文件头说明）：
  /// - `simhei.ttf` 黑体：简体中文 Windows 默认安装，笔画清晰
  /// - `simkai.ttf` 楷体
  /// - `simfang.ttf` 仿宋
  /// - `Deng.ttf` 等线（Win10+）
  static const List<String> candidates = [
    'simhei.ttf',
    'simkai.ttf',
    'simfang.ttf',
    'Deng.ttf',
  ];

  /// 字体目录。取不到 Windows 目录时返回 null。
  ///
  /// 用 `%SystemRoot%` 而不是硬编码 `C:\Windows` ——
  /// 系统盘不一定是 C:（虽然实践中几乎都是）。
  static Directory? fontDir() {
    final root =
        Platform.environment['SystemRoot'] ?? Platform.environment['WINDIR'];
    if (root == null || root.isEmpty) return null;
    return Directory(p.join(root, 'Fonts'));
  }

  /// 找第一个存在的候选字体。找不到返回 null。
  static File? findCjk() {
    final dir = fontDir();
    if (dir == null) return null;
    for (final name in candidates) {
      try {
        final f = File(p.join(dir.path, name));
        if (f.existsSync()) return f;
      } catch (_) {
        // 某个候选读不到就试下一个，不要让一个坏候选毁掉整条链
        continue;
      }
    }
    return null;
  }

  /// 读出中文字体的字节。找不到或读失败都返回 null（**不抛**）。
  ///
  /// 导出 PDF 不该因为"这台机器没有中文字体"而失败 ——
  /// 那种情况应当降级 + 如实告知。
  static Future<Uint8List?> loadCjk() async {
    try {
      final f = findCjk();
      if (f == null) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }
}
