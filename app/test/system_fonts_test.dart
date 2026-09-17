/// 系统字体查找（T43 的取字体那一步）。
///
/// ## 为什么值得单独测
///
/// 这条链路是"PDF 里的中文能不能显示"的唯一来源，而它有**两种**正常结局：
/// 找得到（中文正常）与找不到（降级 + 如实提示）。
/// 后者在装了中文字体的开发机上跑不出来，所以测试必须**两个结局都接受**，
/// 只断言"不管哪种结局，行为都必须是明确的、不抛异常的"。
///
/// 另外还要守住一条纪律：**绝不硬编码 `C:\Windows`** ——
/// 系统盘不一定是 C:。见 `SystemFonts.fontDir` 用 `%SystemRoot%`。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/platform/system_fonts.dart';

void main() {
  group('SystemFonts', () {
    test('字体目录从 %SystemRoot% 推导，不硬编码 C 盘', () {
      final dir = SystemFonts.fontDir();
      if (!Platform.isWindows) {
        expect(dir, isNull, reason: '非 Windows 上不该假装能找到系统字体');
        return;
      }
      expect(dir, isNotNull);
      expect(dir!.path.toLowerCase(), contains('fonts'));
      expect(dir.existsSync(), isTrue);
      // 关键：路径来自环境变量而不是字面量
      final root = Platform.environment['SystemRoot'] ??
          Platform.environment['WINDIR'];
      expect(dir.path.toLowerCase(), startsWith(root!.toLowerCase()));
    });

    test('候选顺序里只有单一 TTF（pdf 包不支持 TTC）', () {
      // 宋体 simsun.ttc 与微软雅黑 msyh.ttc 都是 TTC，
      // `pdf` 包的 TtfParser 处理不了 —— 列进来会在运行期拿到空字体。
      // 这条测试是给"下次有人想加宋体"的人看的。
      for (final name in SystemFonts.candidates) {
        expect(name.toLowerCase().endsWith('.ttf'), isTrue,
            reason: '$name 不是单一 TTF，pdf 包读不了');
      }
      expect(SystemFonts.candidates, isNotEmpty);
    });

    test('findCjk 要么给出候选里的文件，要么明确说没有', () {
      final f = SystemFonts.findCjk();

      if (f == null) {
        // 英文/精简版 Windows：这是**正常结局**，不是失败。
        // 真正的错误是"找不到却不说"，那由
        // paper_export_test.dart 的 caveat 断言守住。
        return;
      }

      expect(f.existsSync(), isTrue);
      expect(
        SystemFonts.candidates.map((c) => c.toLowerCase()),
        contains(f.uri.pathSegments.last.toLowerCase()),
        reason: '返回了候选列表以外的文件',
      );
      // 一个正经的中文字体不会只有几十 KB
      expect(f.lengthSync(), greaterThan(500 * 1024),
          reason: '${f.path} 太小了，不像完整的中文字体');
    });

    test('loadCjk 读出非空字节；没有字体时返回 null 而不抛', () async {
      final bytes = await SystemFonts.loadCjk();
      final f = SystemFonts.findCjk();

      if (f == null) {
        expect(bytes, isNull);
        return;
      }
      expect(bytes, isNotNull);
      expect(bytes!.length, f.lengthSync());
      // TrueType 的 magic：0x00010000 或 'true' / 'ttcf'
      final magic = (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
      expect(magic == 0x00010000 || magic == 0x74727565, isTrue,
          reason: '读出来的不是 TrueType 文件（magic=0x${magic.toRadixString(16)}）');
    });
  });
}
