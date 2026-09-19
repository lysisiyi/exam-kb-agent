/// 长公式按顶层 `\quad` 拆分。
///
/// ## 守两件事
///
/// 1. **只在顶层拆**：花括号里、`\left..\right` 里、环境里的 `\quad`
///    不能动 —— 拆开就不是一对括号了，公式会变成红色乱码。
/// 2. **一个字符都不能丢**（除了分隔符本身与它的空白）——
///    拆分的目的是"排得下"，不是"删内容"。
///
/// 另外拿**真实语料**跑一遍：824 条公式拆出来的每一段都必须能被 katex 解析。
/// 这条比"拆了多少条"重要得多（`cjk_split_corpus_test` 的同类教训：
/// 切坏公式可以长期潜伏，而切分率看着还很漂亮）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/math/latex_text_split.dart';
import 'package:katex_dart/katex_dart.dart';

/// 拆开再拼回去（用空格代替分隔符），用来比较"内容有没有丢"。
String rejoin(List<String> parts) =>
    parts.join(' ').replaceAll(RegExp(r'\s+'), '');

String stripSeparators(String tex) => tex
    .replaceAll(r'\qquad', '')
    .replaceAll(r'\quad', '')
    .replaceAll(RegExp(r'\s+'), '');

void main() {
  group('拆分规则', () {
    test('顶层 \\quad 与 \\qquad 都拆', () {
      expect(splitTopLevelQuad(r'a=1\quad b=2'), ['a=1', 'b=2']);
      expect(splitTopLevelQuad(r'a=1\qquad b=2'), ['a=1', 'b=2']);
      expect(splitTopLevelQuad(r'a\quad b\qquad c'), ['a', 'b', 'c']);
    });

    test('没有分隔符时原样返回', () {
      expect(splitTopLevelQuad(r'x^2+y^2=1'), [r'x^2+y^2=1']);
    });

    test('花括号里的 \\quad 不拆（那是命令参数）', () {
      expect(splitTopLevelQuad(r'\frac{a\quad b}{c}'), [r'\frac{a\quad b}{c}']);
    });

    test('\\left..\\right 里的 \\quad 不拆（拆开括号就不成对）', () {
      const tex = r'\left(\frac{0}{0}\quad\frac{\infty}{\infty}\right)';
      expect(splitTopLevelQuad(tex), [tex]);
    });

    test('环境里的 \\quad 不拆', () {
      const tex = r'\begin{cases}a\quad b\\c\end{cases}';
      expect(splitTopLevelQuad(tex), [tex]);
    });

    test('上下标里的 \\quad 不拆', () {
      expect(splitTopLevelQuad(r'x_{\quad y}'), [r'x_{\quad y}']);
    });

    test('\\quadratic 这种更长的命令不是分隔符', () {
      expect(splitTopLevelQuad(r'a\quadratic b'), [r'a\quadratic b']);
    });

    test('空片段被丢掉（连续两个分隔符不会产出空行）', () {
      expect(splitTopLevelQuad(r'a\quad\quad b'), ['a', 'b']);
    });

    test('拼接回去不丢字符', () {
      const cases = [
        r'a=1\quad b=2',
        r'\sin x\sim x,\quad \tan x\sim x,\quad \arcsin x\sim x',
        r'\frac{\partial u}{\partial x}=-\frac{\frac{\partial(F,G)}{\partial(x,v)}}{\frac{\partial(F,G)}{\partial(u,v)}},\quad \frac{\partial v}{\partial x}=0',
        r'\sigma\ \text{已知}:\ \left(\bar X\pm u_{\alpha/2}\frac{\sigma}{\sqrt n}\right);\qquad \sigma\ \text{未知}:\ \left(\bar X\pm t_{\alpha/2}(n-1)\frac{S}{\sqrt n}\right)',
      ];
      for (final tex in cases) {
        final parts = splitTopLevelQuad(tex);
        expect(rejoin(parts), stripSeparators(tex),
            reason: '拆分后内容对不上：$tex');
      }
    });
  });

  group('真实语料（824 条公式）', () {
    test('拆出来的每一段都能被 katex 解析', () {
      final f = File('../data/knowledge_points/math1.json');
      if (!f.existsSync()) {
        markTestSkipped('数据文件不存在（请在仓库根或 app/ 下运行测试）');
        return;
      }
      final j = jsonDecode(f.readAsStringSync()) as Map;
      final nodes = (j['nodes'] as List).cast<Map<String, dynamic>>();

      var formulas = 0;
      var parts = 0;
      var splitCount = 0;
      final broken = <String>[];

      for (final n in nodes) {
        if (n['is_leaf'] != true) continue;
        for (final raw in (n['formulas'] as List? ?? const [])) {
          final tex = raw.toString();
          formulas++;
          final pieces = splitTopLevelQuad(tex);
          if (pieces.length > 1) splitCount++;
          for (final p in pieces) {
            parts++;
            try {
              renderToBox(p, options: const KatexOptions());
            } catch (e) {
              broken.add('${n['id']} → $p\n     ($e)');
            }
          }
        }
      }

      // ignore: avoid_print
      print('[quad] 公式 $formulas 条 → 片段 $parts 个（$splitCount 条被拆开）');
      expect(formulas, greaterThan(800), reason: '语料没读到？');
      expect(broken, isEmpty,
          reason: '拆分后有 ${broken.length} 段无法解析 —— '
              '拆坏公式会让整条变成红色乱码：\n${broken.take(5).join('\n')}');
      expect(splitCount, greaterThan(200),
          reason: '只有 $splitCount 条被拆开，说明顶层判定过严（数据里大量用 \\quad 并列）');
    });
  });
}
