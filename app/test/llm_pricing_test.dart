/// 价目表覆盖：**App 自己推荐的视觉模型必须估得出价**。
///
/// ## 这一条是怎么来的
///
/// 准备批量导入真实资料时发现：`estimateIngest` 对 `qwen-vl-max` /
/// `glm-4v-flash` / `gemini-2.0-flash` 全都返回"未知（该模型不在价目表里）"
/// —— 恰恰在**最需要看价格**的地方（要不要花这笔钱导入几百页）看不到数字。
///
/// 所以补了视觉模型的价目，并在这里钉住：以后往
/// `LlmVision.suggestedVisionModels` 里加新模型时，忘了补价会被测试拦住。
///
/// ⚠️ 这里只断言"有价"，**不断言具体数字** —— 价格会变，把数字写死会在
/// 服务商调价时变成一条只会误导人的红灯。数字的准确性靠条目上的来源注释。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/services/ingest/ingest_models.dart';
import 'package:kaoyan_math_agent/services/llm/llm_client.dart';
import 'package:kaoyan_math_agent/services/llm/provider_registry.dart';

void main() {
  group('价目表', () {
    test('每个"建议的视觉模型"都估得出价', () {
      final missing = <String>[];
      for (final entry in LlmVision.suggestedVisionModels.entries) {
        if (LlmVision.providersWithoutVision.contains(entry.key)) continue;
        for (final model in entry.value) {
          if (!LlmPricing.has(model)) missing.add('${entry.key} / $model');
        }
      }
      expect(missing, isEmpty,
          reason: '这些推荐模型查不到价，导入估算会显示"未知"：$missing\n'
              '去官方价目表查最新价，补进 LlmPricing._table（并更新核对日期）');
    });

    test('免费模型估出来是 0，未知模型返回 null（而不是 0）', () {
      // 0 与 null 是两件事：0 = 确实免费，null = 不知道
      expect(LlmPricing.estimate(
              model: 'glm-4v-flash', inputTokens: 1000000, outputTokens: 0),
          0.0);
      expect(LlmPricing.estimate(
              model: 'llava', inputTokens: 1000000, outputTokens: 0),
          0.0);
      expect(LlmPricing.has('某个不存在的模型-9x'), isFalse);
      expect(
          LlmPricing.estimate(
              model: '某个不存在的模型-9x', inputTokens: 1, outputTokens: 1),
          isNull);
    });

    test('长名字优先：flashx 不会被当成 flash 估价', () {
      // glm-4.6v-flash 是免费的；若匹配顺序错了，flashx 也会估成 0（少算钱）
      final flashx = LlmPricing.estimate(
          model: 'glm-4.6v-flashx', inputTokens: 1000000, outputTokens: 0);
      expect(flashx, isNotNull);
      expect(flashx, greaterThan(0.0),
          reason: 'flashx 有输入价，估成 0 说明被 glm-4.6v-flash 抢先匹配了');
    });

    test('导入估算对推荐的视觉模型给得出数字', () {
      const sources = [
        IngestSource(
            path: r'C:\x\p001.jpg',
            name: 'p001.jpg',
            sizeBytes: 400 * 1024,
            kind: IngestSourceKind.image),
      ];
      for (final model in const ['qwen-vl-max', 'glm-4v-flash', 'gemini-2.0-flash']) {
        final est = estimateIngest(sources, model: model);
        expect(est.costText, isNot(contains('未知')),
            reason: '$model 的估算文案是「${est.costText}」');
      }
    });
  });
}
