// T17 评测台：跑真实的 LLM 知识点标注，测 **Top-1 准确率**。
//
// ## 为什么需要它
//
// 项目规划里 F4 的验收指标是「知识点标注 Top-1 准确率 ≥ 80%」。
// 这个数字**必须用真实 LLM 才能测**，而在此之前只测过召回率（规则层）。
//
// 界面里也能标注，但要一条条点、还看不到准确率。本工具一次跑完整个
// 金标准集并打印报告，是唯一能拿到这个指标的路径。
//
// ## 用法
//
//     cd app
//     dart run tool/tag_eval.dart --key=sk-xxxx
//     dart run tool/tag_eval.dart --key=sk-xxxx --set=gold_set_verify
//     DSH_LLM_API_KEY=sk-xxxx dart run tool/tag_eval.dart      # 或走环境变量
//
// 参数：
//     --key       API Key（**也可以走环境变量 DSH_LLM_API_KEY**）
//     --provider  服务商 id，默认 deepseek（见 provider_registry）
//     --model     覆盖默认模型名
//     --set       金标准集名，默认 gold_set
//     --limit     只跑前 N 题（先小样本试错，省 token）
//     --out       把逐题结果写成 JSON（便于事后分析错例）
//
// ## 安全
//
// **绝不打印完整 Key**，只打印掩码（`sk-••••••••3f2a`）。
// 逐题结果里也不含 Key。请求由本机直发服务商，不经过任何第三方。
library;

import 'dart:convert';
import 'dart:io';

import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/services/llm/dio_http_adapter.dart';
import 'package:kaoyan_math_agent/services/llm/llm_client.dart';
import 'package:kaoyan_math_agent/services/llm/provider_registry.dart';
import 'package:kaoyan_math_agent/services/tagger/evaluator.dart';
import 'package:kaoyan_math_agent/services/tagger/knowledge_tagger.dart';

Future<void> main(List<String> argv) async {
  final args = _Args(argv);

  if (args.key.isEmpty) {
    stderr.writeln(
      '缺少 API Key。两种给法：\n'
      '  dart run tool/tag_eval.dart --key=sk-xxxx\n'
      '  DSH_LLM_API_KEY=sk-xxxx dart run tool/tag_eval.dart\n'
      '\n'
      '可用服务商：${LlmProviders.all.map((p) => p.id).join(", ")}\n'
      '（默认 deepseek：国内可直连）',
    );
    exit(2);
  }

  final root = _findRepoRoot();
  if (root == null) {
    stderr.writeln('找不到仓库根目录（需要 data/）。请在仓库根或 app/ 下运行。');
    exit(2);
  }

  final kbFile = File('${root.path}/data/knowledge_points/math1.json');
  final goldFile = File('${root.path}/data/eval/${args.set}.json');
  for (final f in [kbFile, goldFile]) {
    if (!f.existsSync()) {
      stderr.writeln('缺少数据文件：${f.path}');
      exit(2);
    }
  }

  final knowledge = KnowledgeBase.fromJson(
    (jsonDecode(kbFile.readAsStringSync()) as Map).cast<String, dynamic>(),
  );
  var gold = GoldSet.fromJson(
    (jsonDecode(goldFile.readAsStringSync()) as Map).cast<String, dynamic>(),
  );
  if (args.limit != null && args.limit! < gold.problems.length) {
    gold = GoldSet(
      version: gold.version,
      note: gold.note,
      problems: gold.problems.take(args.limit!).toList(),
    );
  }

  final config = LlmConfig(
    providerId: args.provider,
    apiKey: args.key,
    modelOverride: args.model,
  );
  final (ok, problem) = config.validate();
  if (!ok) {
    stderr.writeln('配置不可用：$problem');
    exit(2);
  }

  stdout.writeln('=' * 74);
  stdout.writeln('T17 知识点标注评测（真实 LLM）');
  stdout.writeln('=' * 74);
  stdout.writeln('服务商      ${config.spec?.label ?? config.providerId}');
  stdout.writeln('模型        ${config.model}');
  stdout.writeln('Key         ${_mask(args.key)}');
  stdout.writeln('置信度门禁  ${config.confidenceThreshold}'
      '（${config.tier.name} 档）');
  stdout.writeln('知识点本体  ${knowledge.leaves.length} 个叶子');
  stdout.writeln('金标准集    ${args.set}（${gold.problems.length} 题）');
  stdout.writeln();

  final tagger = KnowledgeTagger(
    knowledge: knowledge,
    client: LlmClient(config: config, http: DioHttpAdapter()),
  );

  final stopwatch = Stopwatch()..start();
  final report = await TaggerEvaluator(knowledge: knowledge, tagger: tagger)
      .evaluate(
    gold.problems,
    onProgress: (done, total) {
      stdout.write('\r  进度 $done/$total');
    },
  );
  stopwatch.stop();
  stdout.writeln('\r  进度 ${gold.problems.length}/${gold.problems.length}'
      '（耗时 ${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s）');
  stdout.writeln();

  stdout.writeln(report.summary());

  // ── 逐题明细：错例比汇总数字更有用 ──
  stdout.writeln('=' * 74);
  stdout.writeln('逐题结果');
  stdout.writeln('=' * 74);
  for (final item in report.items) {
    final mark = item.top1Correct == true
        ? '✓'
        : (item.acceptable == true ? '~' : '✗');
    final rank = item.recallRank == null ? 'MISS' : '#${item.recallRank}';
    stdout.writeln('$mark ${item.gold.id.padRight(9)} 召回$rank');
    stdout.writeln('    期望 ${item.gold.primaryKpId}');
    if (item.predicted != null) {
      stdout.writeln('    预测 ${item.predicted}'
          '  conf=${item.confidence?.toStringAsFixed(2)}'
          '${item.needsReview ? "  [待人工确认]" : ""}');
    }
    if (item.failure != null) {
      stdout.writeln('    失败 ${item.failure!.split("\n").first}');
    }
  }

  // ── 目标判定 ──
  final acc = report.top1Accuracy;
  stdout.writeln();
  if (acc == null) {
    stdout.writeln('⚠️ 没有可判定的样本（全部调用失败？）');
  } else if (acc >= 0.80) {
    stdout.writeln('✅ Top-1 准确率 ${(acc * 100).toStringAsFixed(1)}% ≥ 80%，达标');
  } else {
    stdout.writeln('❌ Top-1 准确率 ${(acc * 100).toStringAsFixed(1)}% < 80%，未达标');
    stdout.writeln('   下一步按错例归因：');
    stdout.writeln('   - 期望答案没进候选（召回 MISS）→ 补别名或让 LLM 参与召回');
    stdout.writeln('   - 进了候选但选错 → 候选集太宽/本体仍有近义叶子，或 prompt 需改');
  }

  if (args.out != null) {
    final outFile = File('${root.path}/app/build/${args.out}');
    outFile.parent.createSync(recursive: true);
    outFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'provider': config.providerId,
        'model': config.model,
        'goldSet': args.set,
        'totalLeaves': knowledge.leaves.length,
        'top1Accuracy': acc,
        'acceptableRate': report.acceptableRate,
        'reviewRate': report.reviewRate,
        'failureRate': report.failureRate,
        'recallRate': report.recallRate,
        'items': [
          for (final i in report.items)
            {
              'id': i.gold.id,
              'expected': i.gold.primaryKpId,
              'predicted': i.predicted,
              'confidence': i.confidence,
              'recallRank': i.recallRank,
              'needsReview': i.needsReview,
              'failure': i.failure,
            }
        ],
      }),
    );
    stdout.writeln('\n逐题结果已写入 ${outFile.path}');
  }
}

/// 只显示掩码 —— 完整 Key 绝不落到终端历史或日志里。
String _mask(String key) {
  final k = key.trim();
  if (k.length <= 10) return '••••';
  return '${k.substring(0, 3)}••••••••${k.substring(k.length - 4)}';
}

class _Args {
  final String key;
  final String provider;
  final String? model;
  final String set;
  final int? limit;
  final String? out;

  _Args(List<String> argv)
      : key = _val(argv, '--key') ??
            (Platform.environment['DSH_LLM_API_KEY'] ?? '').trim(),
        provider = _val(argv, '--provider') ?? 'deepseek',
        model = _val(argv, '--model'),
        set = _val(argv, '--set') ?? 'gold_set',
        limit = int.tryParse(_val(argv, '--limit') ?? ''),
        out = _val(argv, '--out');

  /// 取值。支持 `--k=v` 与 `--k v` 两种写法。
  ///
  /// ⚠️ 两种写法的边界不同，不能共用一个循环上界：
  /// `--k=v` 可以出现在**最后一个**参数，而 `--k v` 需要后面还有一个元素。
  /// 早期版本统一写成 `i < argv.length - 1`，导致 `--limit=3` 放在末尾时
  /// **静默失效**（跑了全部 15 题才发现）。
  static String? _val(List<String> argv, String k) {
    for (var i = 0; i < argv.length; i++) {
      if (argv[i].startsWith('$k=')) return argv[i].substring(k.length + 1);
      if (argv[i] == k && i + 1 < argv.length) return argv[i + 1];
    }
    return null;
  }
}

Directory? _findRepoRoot() {
  for (final base in ['.', '..', '../..']) {
    if (Directory('$base/data/knowledge_points').existsSync()) {
      return Directory(base).absolute;
    }
  }
  return null;
}
