/// 用**真实语料**校验中文摘分：把 data/ 里三个本体文件的全部公式跑一遍。
///
/// ## 为什么需要它
///
/// 手写用例只能覆盖我想到的情况。真实语料有 1400 条公式、写法千奇百怪
/// （`\text` 连着写、嵌在环境里、当上下标用……），是唯一能回答
/// "到底多少条中文能安全摘出来"的依据。
///
/// 这个测试同时守住两条线：
/// - **摘分率**不能掉（掉说明保守过头了，中文会变方框）
/// - **不该摘的不能摘**（摘错会破坏公式结构 → 整条降级成源码，更糟）
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/math/latex_text_split.dart';
import 'package:katex_dart/katex_dart.dart' show KatexOptions, renderToBox;

/// 从本体 JSON 里递归取全部公式。
List<String> _loadCorpus() {
  final out = <String>[];
  final dir = Directory('assets/data/knowledge_points');
  if (!dir.existsSync()) return out;

  for (final name in ['math1.json', 'math2.json', 'math3.json']) {
    final f = File('${dir.path}/$name');
    if (!f.existsSync()) continue;
    final data = json.decode(f.readAsStringSync()) as Map<String, dynamic>;
    void walk(dynamic node) {
      if (node is! Map) return;
      for (final f in (node['formulas'] as List? ?? const [])) {
        if (f is String) out.add(f);
      }
      for (final c in (node['children'] as List? ?? const [])) {
        walk(c);
      }
    }

    for (final n in (data['nodes'] as List? ?? const [])) {
      walk(n);
    }
  }
  return out;
}

void main() {
  final corpus = _loadCorpus();

  test('语料可用（assets 已同步）', () {
    expect(corpus, isNotEmpty,
        reason: 'assets/data 里没有本体 —— 先跑 python tools/data/sync_assets.py');
    expect(corpus.length, greaterThan(1000));
  });

  test('含中文的公式里，绝大多数能安全摘出中文', () {
    var withCjk = 0;
    var splittable = 0;

    for (final tex in corpus) {
      if (!_hasCjk(tex)) continue;
      withCjk++;
      if (canSplit(tex)) splittable++;
    }

    expect(withCjk, greaterThan(500), reason: '含中文的公式应当是几百条量级');

    final rate = splittable / withCjk;
    // 2026-09-21 实测 592/610 = 97.0%。阈值定在 96%：
    // 掉下去说明某条安全判据写严了，中文会退回方框 —— 用户直接看得见。
    //
    // 剩下的 18 条是**结构上不能摘**的（8 命令参数 / 5 `\left..\right` /
    // 3 上下标 / 2 环境），摘了会把公式切坏、变成红色乱码，比方框更糟。
    expect(rate, greaterThan(0.96),
        reason: '摘分率只有 ${(rate * 100).toStringAsFixed(1)}%'
            '（$splittable/$withCjk）—— 是不是哪条安全判据写严了？');
  });

  test('摘分结果结构自洽：TextChunk 非空、LatexChunk 可交给 katex', () {
    for (final tex in corpus) {
      if (!canSplit(tex)) continue;
      final chunks = splitLatexText(tex);
      for (final c in chunks) {
        switch (c) {
          case TextChunk(:final text):
            expect(text, isNotEmpty, reason: '公式「$tex」切出了空文本片段');
          case LatexChunk(:final tex):
            expect(tex, isNotEmpty, reason: '公式「$tex」切出了空 LaTeX 片段');
        }
      }
    }
  });

  test('每一个 LatexChunk 都能被 katex 单独解析', () {
    // ⚠️ 这是本文件里**最重要**的一条断言，也是最容易被漏掉的一条。
    //
    // 只检查"片段非空"是不够的。曾经有一个真实缺陷长期潜伏：
    // `_isTopLevel` 靠"`\text` 紧挨着的前一个字符是什么"来判断它能不能
    // 被摘出来，于是对"第二个参数"这类写法全部误判 ——
    //
    //   \frac{A\ \text{包含的样本点数}}{\text{样本点总数}}
    //                          ↑ 前面是 `}`，判定返回"可以摘"
    //
    // 切出来的是 `\frac{A\ ` / `}{` / `}`，**每一段单独都不能解析**，
    // katex 于是把整条公式降级成红色的原始 LaTeX。
    // 也就是说：这个功能本意是"让中文别显示成方框"，实际效果却是把
    // 排版完全正常的公式变成乱码 —— 而"摘分率 96%"这个指标毫无异常。
    //
    // 唯一能抓住它的问题是："每一段自己能不能解析"。
    var checked = 0;
    for (final tex in corpus) {
      if (!canSplit(tex)) continue;
      for (final c in splitLatexText(tex)) {
        if (c is! LatexChunk) continue;
        checked++;
        expect(
          () => renderToBox(c.tex, options: const KatexOptions()),
          returnsNormally,
          reason: '公式「$tex」切出的 LaTeX 片段「${c.tex}」不能单独解析 —— '
              '这会让整条公式在界面上变成红色乱码',
        );
      }
    }
    expect(checked, greaterThan(100), reason: '没有检查到足够多的 LaTeX 片段');
  });

  test('中文摘分不会把公式切成"只剩中文"（除非公式本来就只有中文）', () {
    for (final tex in corpus) {
      if (!canSplit(tex)) continue;
      final chunks = splitLatexText(tex);
      final onlyText = chunks.every((c) => c is TextChunk);
      if (!onlyText) continue;

      // 两种正常情形：
      // 1. 公式整体就是 `\text{...}`；
      // 2. 公式整体就是**裸中文**（一个反斜杠都没有），本来就没有 LaTeX 部分。
      final wrapped = tex.trimLeft().startsWith(r'\text');
      final bareCjk = !tex.contains(r'\');
      expect(wrapped || bareCjk, isTrue,
          reason: '公式「$tex」被切成了纯文本，但它的 LaTeX 部分不见了');
    }
  });

  group('裸中文（没有 \\text 包裹）', () {
    test('顶层裸中文能被摘出来', () {
      final chunks = splitLatexText(r'无解\iff r(A)<r(A|b)');
      expect(
        chunks.whereType<TextChunk>().map((c) => c.text).join(),
        '无解',
      );
      expect(
        chunks.whereType<LatexChunk>().map((c) => c.tex).join(),
        r'\iff r(A)<r(A|b)',
      );
    });

    test('夹在数学记号之间的裸中文也能摘', () {
      final chunks = splitLatexText(r'f(x)=0无解');
      expect(chunks.whereType<TextChunk>().map((c) => c.text).join(), '无解');
      expect(chunks.first, isA<LatexChunk>());
    });

    test('花括号里的裸中文不摘（摘了会切出不能解析的残片）', () {
      for (final tex in [
        r'x_{旧}=P\,x_{新}',
        r'\frac{旧}{新}',
        r'\sqrt[3]{旧}',
      ]) {
        expect(
          splitLatexText(tex),
          hasLength(1),
          reason: '「$tex」在花括号里，不该被摘',
        );
        expect(splitLatexText(tex).single, isA<LatexChunk>());
      }
    });

    test('紧贴命令名的裸中文不摘 —— 那是命令的参数', () {
      // `\overline解`：TeX 允许参数不带花括号，摘掉就留下缺参数的
      // `\overline`，katex 抛错 → 整条公式变红色乱码，比方框更糟。
      for (final tex in [
        r'\overline解',
        r'\mathbf解',
        r'\sqrt解',
      ]) {
        expect(
          splitLatexText(tex),
          hasLength(1),
          reason: '「$tex」的中文是命令参数，不该被摘',
        );
      }
    });

    test('但独立记号和命令之间的裸中文可以摘', () {
      // `\mathbf A解`：`\mathbf` 只吃 `A`，后面的 `解` 是独立文本。
      final chunks = splitLatexText(r'\mathbf A解');
      expect(chunks.whereType<TextChunk>().map((c) => c.text).join(), '解');
      expect(chunks.first, isA<LatexChunk>());
    });

    test('摘出来的裸中文片段，其余部分仍能被 katex 解析', () {
      for (final tex in [
        r'无解\iff r(A)<r(A|b)',
        r'f(x)=0无解',
        r'\mathbf A解',
        r'中值定理\Rightarrow f\prime(\xi)=0',
      ]) {
        for (final c in splitLatexText(tex)) {
          if (c is! LatexChunk || c.tex.isEmpty) continue;
          expect(
            () => renderToBox(c.tex, options: const KatexOptions()),
            returnsNormally,
            reason: '「$tex」切出的片段「${c.tex}」不能单独解析',
          );
        }
      }
    });
  });
}

bool _hasCjk(String s) {
  for (final r in s.runes) {
    if (r >= 0x4E00 && r <= 0x9FFF) return true;
    if (r >= 0x3400 && r <= 0x4DBF) return true;
  }
  return false;
}
