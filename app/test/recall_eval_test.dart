/// M3 召回率评测 —— 用**真实知识点本体**跑真实评测。
///
/// ## 这是 M3 的验收标准
///
/// 项目规划阶段定的硬指标：**Top-1 准确率 ≥ 80%**，而召回率是它的天花板 ——
/// 金标准答案没进候选集的话，LLM 再强也选不对。
///
/// ## 四个金标准集，角色不能混
///
/// | 文件 | 题数 | 角色 | 实测 |
/// |---|---|---|---|
/// | `gold_set.json` | 15 | **开发集**（调权重时一直看它，数字不算泛化能力） | 100% |
/// | `gold_set_holdout.json` | 25 | 留出集（用它的失败改过 6 处别名，**已污染**） | 96% |
/// | `gold_set_final.json` | 15 | 第一次独立验证（首次测得 80%，据其诊断补了通用措辞） | 100% |
/// | `gold_set_verify.json` | 12 | 对外报数（首次 83.3%，补 1 处通用措辞后） | 91.7% |
///
/// 改动召回策略前请先读这张表：**在开发集上把数字调高不等于策略变好了**。
/// 新增验证集时不要回头改别名再跑 —— 那样它立刻退化成开发集。
///
/// ## 与生产代码一致
/// 测试读取的是**真实的** `math1.json`（198 个叶子）与真实金标准集，
/// 用的是生产同款的 [KnowledgeRecall]。所以这里跑出的数字就是真实性能。
///
/// ## 数据缺失时自动跳过
/// 若 `data/` 不存在（例如只拷贝了 `app/` 目录），测试跳过而不是失败 ——
/// 避免把"环境不全"误报成"功能坏了"。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/services/tagger/evaluator.dart';
import 'package:kaoyan_math_agent/services/tagger/knowledge_recall.dart';

/// 从仓库根目录定位数据文件。
///
/// `flutter test` 的工作目录是 `app/`，所以数据在 `../data/`。
/// 同时兼容从仓库根直接跑的情况。
File? _findDataFile(String relative) {
  for (final base in ['..', '.']) {
    final f = File('$base/$relative');
    if (f.existsSync()) return f;
  }
  return null;
}

Map<String, dynamic> _loadMap(String relative) =>
    (jsonDecode(_findDataFile(relative)!.readAsStringSync()) as Map)
        .cast<String, dynamic>();

/// 数据文件是否齐备。不齐时用例跳过。
bool get _hasData =>
    _findDataFile('data/knowledge_points/math1.json') != null &&
    _findDataFile('data/eval/gold_set.json') != null;

const _skipReason = '数据文件不存在（请在仓库根或 app/ 下运行测试，'
    '并确认 data/ 目录完整）';

/// 金标准集的角色定义（实测值 + 允许的回归余量）。
///
/// 阈值取"实测值减 1 题"：这些集合只有 12–25 题，单题波动就有 4–8 个百分点，
/// 卡死在实测值上会让测试变成噪声报警器。
class _GoldSetSpec {
  final String name;
  final String file;

  /// 实测召回率（记录用，不参与断言）。
  final double measured;

  /// 断言下限。
  final double floor;

  const _GoldSetSpec(this.name, this.file, this.measured, this.floor);
}

const _goldSets = <_GoldSetSpec>[
  _GoldSetSpec('开发集', 'data/eval/gold_set.json', 1.000, 0.90),
  _GoldSetSpec('留出集', 'data/eval/gold_set_holdout.json', 0.960, 0.88),
  _GoldSetSpec('独立验证集', 'data/eval/gold_set_final.json', 1.000, 0.90),
  _GoldSetSpec('报数集', 'data/eval/gold_set_verify.json', 0.917, 0.83),
];

void main() {
  group('M3 召回率评测（真实知识点本体 + 金标准集）', () {
    test('四个金标准集的 id 全部存在于知识点本体中', () {
      if (!_hasData) {
        markTestSkipped(_skipReason);
        return;
      }
      final knowledge = KnowledgeBase.fromJson(
        _loadMap('data/knowledge_points/math1.json'),
      );
      final ids = knowledge.byId.keys.toSet();

      final problems = <String>[];
      for (final spec in _goldSets) {
        if (_findDataFile(spec.file) == null) {
          problems.add('${spec.name}：文件不存在 ${spec.file}');
          continue;
        }
        final gold = GoldSet.fromJson(_loadMap(spec.file));
        for (final p in gold.problems) {
          if (!ids.contains(p.primaryKpId)) {
            problems.add('${spec.name} ${p.id}: primary=${p.primaryKpId}');
          }
          for (final s in p.secondaryKpIds) {
            if (!ids.contains(s)) {
              problems.add('${spec.name} ${p.id}: secondary=$s');
            }
          }
        }
      }

      expect(
        problems,
        isEmpty,
        reason: '金标准集有 ${problems.length} 个 id 不在本体里 —— '
            '评测会因此失真，必须先修正：\n${problems.take(10).join("\n")}',
      );
    });

    test('知识点本体无同章节同名叶子（避免 LLM 二选一掷硬币）', () {
      if (!_hasData) {
        markTestSkipped(_skipReason);
        return;
      }
      final knowledge = KnowledgeBase.fromJson(
        _loadMap('data/knowledge_points/math1.json'),
      );

      final seen = <String, String>{};
      final dupes = <String>[];
      for (final kp in knowledge.leaves) {
        final key = '${kp.parentId}|${kp.name}';
        final prev = seen[key];
        if (prev != null) {
          dupes.add('${kp.parentId} 下「${kp.name}」重复：$prev vs ${kp.id}');
        } else {
          seen[key] = kp.id;
        }
      }

      expect(
        dupes,
        isEmpty,
        reason: '发现 ${dupes.length} 组同名冗余，会让标注准确率人为下降：\n'
            '${dupes.take(10).join("\n")}',
      );
    });

    test('知识点本体的结构完整性', () {
      if (!_hasData) {
        markTestSkipped(_skipReason);
        return;
      }
      final knowledge = KnowledgeBase.fromJson(
        _loadMap('data/knowledge_points/math1.json'),
      );

      // 父节点必须存在
      final ids = knowledge.byId.keys.toSet();
      final dangling = <String>[];
      for (final n in knowledge.nodes) {
        final pid = n.parentId;
        if (pid != null && !ids.contains(pid)) {
          dangling.add('${n.id} -> $pid');
        }
      }
      expect(dangling, isEmpty, reason: '悬空 parent_id：${dangling.take(5)}');

      // 叶子必须有关键字段
      final incomplete = <String>[];
      for (final kp in knowledge.leaves) {
        if (kp.definition == null || kp.definition!.isEmpty) {
          incomplete.add('${kp.id} 缺 definition');
        }
        if (kp.formulas.isEmpty) {
          incomplete.add('${kp.id} 缺 formulas');
        }
      }
      expect(incomplete, isEmpty,
          reason: '${incomplete.length} 个叶子字段不全：${incomplete.take(5)}');

      // 考频权重应在合理范围
      for (final kp in knowledge.leaves) {
        final w = kp.examWeight;
        if (w != null) {
          expect(w, inInclusiveRange(0.0, 1.0),
              reason: '${kp.id} 的 exam_weight=$w 越界');
        }
      }
    });

    test('别名覆盖率：多数叶子要有别名（T15 的成果不能被无声回退）', () {
      if (!_hasData) {
        markTestSkipped(_skipReason);
        return;
      }
      final knowledge = KnowledgeBase.fromJson(
        _loadMap('data/knowledge_points/math1.json'),
      );

      final withAlias = knowledge.leaves.where((k) => k.aliases.isNotEmpty);
      final ratio = withAlias.length / knowledge.leaves.length;

      // 实测 144/198 = 72.7%。剩下的 54 个叶子名本身就是简单概念词
      // （「洛必达法则」「格林公式」），整名匹配已经够用。
      //
      // 这个断言的真实目的**不是**卡覆盖率，而是拦住一类静默事故：
      // 重跑 `merge_shards.py` 时别名整批被分片覆盖，且不报任何错。
      expect(
        ratio,
        greaterThanOrEqualTo(0.70),
        reason: '只有 ${(ratio * 100).toStringAsFixed(1)}% 的叶子带别名 —— '
            '别名很可能在合并/去重流程里被覆盖了。'
            '重跑 `python tools/data/gen_aliases.py --all` 并从 git 差异确认。',
      );

      // 符号别名（含反斜杠）是"题干只写符号"那一类题的命脉
      final withSymbol = knowledge.leaves
          .where((k) => k.aliases.any((a) => a.contains(r'\')));
      expect(
        withSymbol.length,
        greaterThanOrEqualTo(100),
        reason: '带符号别名的叶子只有 ${withSymbol.length} 个，'
            'alias_overrides.json 可能没被写进本体',
      );
    });

    // ── 召回率：四个集分别评测 ──
    //
    // 为什么不是一个集：单一集合上把阈值调到达标，等于把测试集变成训练集。
    // 四个集覆盖"调参用 / 诊断用 / 独立验证 / 报数"四种角色，
    // 每个集的下限都记录在 _goldSets 里。
    for (final spec in _goldSets) {
      test('召回率：${spec.name} ≥ ${(spec.floor * 100).toStringAsFixed(0)}%'
          '（实测 ${(spec.measured * 100).toStringAsFixed(1)}%）', () async {
        if (!_hasData || _findDataFile(spec.file) == null) {
          markTestSkipped('$_skipReason（或 ${spec.file} 不存在）');
          return;
        }
        final knowledge = KnowledgeBase.fromJson(
          _loadMap('data/knowledge_points/math1.json'),
        );
        final gold = GoldSet.fromJson(_loadMap(spec.file));

        expect(gold.problems.length, greaterThanOrEqualTo(10),
            reason: '${spec.name}样本太少，结论不可靠');

        final report = await TaggerEvaluator(knowledge: knowledge)
            .evaluate(gold.problems)
            .timeout(const Duration(seconds: 120));

        // ignore: avoid_print
        print('[${spec.name}] ${report.summary().split("\n").take(6).join(" | ")}');

        expect(
          report.recallRate,
          greaterThanOrEqualTo(spec.floor),
          reason: '${spec.name}召回率 '
              '${(report.recallRate * 100).toStringAsFixed(1)}% 跌破下限 '
              '${(spec.floor * 100).toStringAsFixed(0)}%。\n'
              '召回失败的题：\n'
              '${report.recallMisses.map((m) => '  ${m.gold.id} 期望 ${m.gold.primaryKpId}').join("\n")}',
        );

        // 自洽性校验：Top-3 召回**不可能高于**整体召回率
        // （"排在前三" 是 "在候选里" 的子集）。
        expect(
          report.top3RecallRate,
          lessThanOrEqualTo(report.recallRate + 1e-9),
          reason: 'Top-3 召回率不应高于整体召回率（逻辑上不可能）',
        );

        // 候选数量要合理（LLM 的 prompt 预算由它决定）
        final avg = report.items.isEmpty
            ? 0.0
            : report.items.map((i) => i.recalled.length).reduce((a, b) => a + b) /
                report.items.length;
        expect(avg, lessThanOrEqualTo(25.0));
      });
    }
  });
}
