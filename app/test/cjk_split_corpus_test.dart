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
    // 实测（2026-03-16）为 96%+。掉到 90% 以下说明判定过保守，
    // 中文会以方框形式出现 —— 那是用户直接看得见的问题。
    expect(rate, greaterThan(0.90),
        reason: '摘分率只有 ${(rate * 100).toStringAsFixed(1)}%'
            '（$splittable/$withCjk）—— 保守过头了');
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

  test('中文摘分不会把公式切成"只剩中文"（除非公式本来就只有中文）', () {
    for (final tex in corpus) {
      if (!canSplit(tex)) continue;
      final chunks = splitLatexText(tex);
      final onlyText = chunks.every((c) => c is TextChunk);
      if (onlyText) {
        // 允许：公式整体就是 \text{...}
        expect(tex.trimLeft().startsWith(r'\text'), isTrue,
            reason: '公式「$tex」被切成了纯文本，但它的 LaTeX 部分不见了');
      }
    }
  });
}

bool _hasCjk(String s) {
  for (final r in s.runes) {
    if (r >= 0x4E00 && r <= 0x9FFF) return true;
    if (r >= 0x3400 && r <= 0x4DBF) return true;
  }
  return false;
}
