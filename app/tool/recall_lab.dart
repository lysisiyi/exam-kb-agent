// 召回实验台 —— 调召回策略时的快速迭代工具。
//
// ## 为什么不用 `flutter test` 迭代
//
// 召回策略的调参需要**看每一道题的失败细节**：期望的知识点排在几名、
// 拿到多少分、命中了哪些策略、候选集里前五是哪些。
// `flutter test` 只给汇总数字，看不到这些。
//
// 本工具是纯 Dart（不依赖 Flutter binding），所以：
//
//     cd app && dart run tool/recall_lab.dart --misses
//
// 比 `flutter test` 快得多，且可以随时改召回代码立刻看到效果。
//
// ## 用法
//
//     dart run tool/recall_lab.dart                 # 汇总报告
//     dart run tool/recall_lab.dart --misses        # 只列召回失败的题，带诊断
//     dart run tool/recall_lab.dart --rank          # 列出每题期望知识点的排名
//     dart run tool/recall_lab.dart --candidates 5  # 失败题打印前 5 个候选
library;

import 'dart:convert';
import 'dart:io';

import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/services/tagger/evaluator.dart';
import 'package:kaoyan_math_agent/services/tagger/knowledge_recall.dart';

void main(List<String> argv) {
  final args = _Args(argv);

  final repoRoot = _findRepoRoot();
  if (repoRoot == null) {
    stderr.writeln('找不到仓库根目录（需要 data/ 目录）。请在仓库根或 app/ 下运行。');
    exit(2);
  }

  final kbFile = File('${repoRoot.path}/data/knowledge_points/${args.subject}.json');
  final goldFile = File('${repoRoot.path}/data/eval/${args.goldSet}.json');
  for (final f in [kbFile, goldFile]) {
    if (!f.existsSync()) {
      stderr.writeln('缺少数据文件：${f.path}');
      exit(2);
    }
  }

  final knowledge = KnowledgeBase.fromJson(
    (jsonDecode(kbFile.readAsStringSync()) as Map).cast<String, dynamic>(),
  );
  final gold = GoldSet.fromJson(
    (jsonDecode(goldFile.readAsStringSync()) as Map).cast<String, dynamic>(),
  );

  final recaller = KnowledgeRecall(knowledge: knowledge);
  final misses = <_Row>[];
  final rows = <_Row>[];

  for (final p in gold.problems) {
    final recall = recaller.recall(p.toProblem());
    final ids = recall.candidates.map((c) => c.point.id).toList();
    final idx = ids.indexOf(p.primaryKpId);
    final row = _Row(
      gold: p,
      rank: idx >= 0 ? idx + 1 : null,
      candidates: recall.candidates,
      result: recall,
    );
    rows.add(row);
    if (idx < 0) misses.add(row);
  }

  final hit = rows.where((r) => r.rank != null).length;
  final top3 = rows.where((r) => r.rank != null && r.rank! <= 3).length;
  final avgCand =
      rows.isEmpty ? 0.0 : rows.map((r) => r.candidates.length).sum / rows.length;

  stdout.writeln('=' * 72);
  stdout.writeln('召回实验台  ${args.subject}  ${knowledge.leaves.length} 个叶子  '
      '${rows.length} 道金标准题');
  stdout.writeln('=' * 72);
  stdout.writeln('召回率   ${(hit / rows.length * 100).toStringAsFixed(1)}%  '
      '($hit/${rows.length})');
  stdout.writeln('Top-3    ${(top3 / rows.length * 100).toStringAsFixed(1)}%');
  stdout.writeln('平均候选 ${avgCand.toStringAsFixed(1)}');

  if (args.rank || args.misses) {
    stdout.writeln();
    stdout.writeln('── 逐题 ──');
    for (final r in rows) {
      final rank = r.rank == null ? 'MISS' : '#${r.rank}';
      final flag = r.rank == null
          ? '✗'
          : (r.rank! <= 3 ? '✓' : '~');
      stdout.writeln('$flag ${r.gold.id.padRight(9)} $rank'.padRight(24) +
          r.gold.primaryKpId);
    }
  }

  if (misses.isNotEmpty) {
    stdout.writeln();
    stdout.writeln('── 召回失败诊断（${misses.length} 题）──');
    for (final r in misses) {
      stdout.writeln();
      stdout.writeln('${r.gold.id}  期望 ${r.gold.primaryKpId}');
      final kp = knowledge.byId[r.gold.primaryKpId];
      if (kp != null) {
        stdout.writeln('    名称：「${kp.name}」  别名：${kp.aliases}');
        stdout.writeln('    公式：${kp.formulas.take(3).toList()}');
      }
      stdout.writeln('    题干：${r.gold.stem.replaceAll('\n', ' ')}');
      stdout.writeln('    本节候选数：${r.result.candidates.length}  '
          '公式命中 ${r.result.formulaHits} / 名称命中 ${r.result.nameHits} / '
          '别名命中 ${r.result.aliasHits} / 保底 ${r.result.chapterFloorAdded}');
      if (args.candidates > 0) {
        stdout.writeln('    前 ${args.candidates} 个候选：');
        for (final c in r.candidates.take(args.candidates)) {
          stdout.writeln('      ${c.score.toStringAsFixed(2).padLeft(6)}  '
              '${c.point.id}  ${c.reasons.join("; ")}');
        }
      }
    }
  }

  exit(misses.isEmpty && args.strict ? 1 : 0);
}

/// 简单参数解析。
class _Args {
  final String subject;
  final String goldSet;
  final bool misses;
  final bool rank;
  final int candidates;
  final bool strict;

  _Args(List<String> argv)
      : subject = _val(argv, '--subject') ?? 'math1',
        goldSet = _val(argv, '--set') ?? 'gold_set',
        misses = argv.contains('--misses'),
        rank = argv.contains('--rank') || argv.contains('--misses'),
        candidates = int.tryParse(_val(argv, '--candidates') ?? '0') ?? 0,
        strict = argv.contains('--strict');

  static String? _val(List<String> argv, String key) {
    for (var i = 0; i < argv.length - 1; i++) {
      if (argv[i] == key) return argv[i + 1];
      if (argv[i].startsWith('$key=')) return argv[i].substring(key.length + 1);
    }
    return null;
  }
}

class _Row {
  final GoldProblem gold;
  final int? rank;
  final List<RecallCandidate> candidates;
  final RecallResult result;

  const _Row({
    required this.gold,
    required this.rank,
    required this.candidates,
    required this.result,
  });
}

/// 找到包含 `data/` 的仓库根目录。
Directory? _findRepoRoot() {
  for (final base in ['.', '..', '../..']) {
    final d = Directory('$base/data/knowledge_points');
    if (d.existsSync()) return Directory(base).absolute;
  }
  return null;
}

extension on Iterable<int> {
  int get sum => fold(0, (a, b) => a + b);
}
