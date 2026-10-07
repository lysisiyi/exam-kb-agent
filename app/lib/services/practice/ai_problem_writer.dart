/// AI 自创题轨（P3）：按课时笔记出原创题 → 直接入库为「待复核」。
///
/// ## 合规与纪律
///
/// prompt 硬约束「**原创**，不得逐字改编任何教材/真题原文」；生成物一律
/// 走 `ExtractedProblem.toDraft`（`needsReview: true`）——它们会出现在
/// 练习页的「AI 自创题 · 待复核」卡里，人工核对后才算正式题。
///
/// 解析复用批量导入的 `IngestExtractor`：同一套 JSON 契约与容错
/// （顶层数组/字段别名/LaTeX 修复），不写第二套解析器。
library;

import '../ingest/ingest_extractor.dart';
import '../ingest/ingest_models.dart';
import '../llm/llm_client.dart';

/// 出题结果：解析出的题目 + 原始输出（失败时用于如实提示）。
class AiProblemDraftResult {
  final List<ExtractedProblem> problems;
  final List<String> warnings;

  const AiProblemDraftResult({required this.problems, required this.warnings});
}

const kAiProblemSystemPrompt =
    '你是考研数学命题老师。根据给定的课堂笔记要点，原创若干道小练习题。\n'
    '硬约束：\n'
    '- **必须原创**：不得逐字改编任何教材、真题或题库原文；数字与情境自行设定。\n'
    '- 每题的答案与解析必须自洽可验证；算不准的题不要出。\n'
    '- 题型以选择题（choice，4 个选项）与填空题（fill）为主。\n'
    '- 难度 1 基础 / 2 综合 / 3 拓展。\n'
    '严格输出 JSON：{"problems":[{"stem":"题干（可用 LaTeX）",'
    '"qtype":"choice|fill","difficulty":1,"options":["..."],'
    '"answer":"答案","solution":"解析","knowledge_primary":"关联考点名"}]}';

class AiProblemWriter {
  final LlmClient client;
  AiProblemWriter(this.client);

  /// 依据笔记要点与目标考点名出题。[count] 为期望题数（模型可能少于它）。
  Future<AiProblemDraftResult> generate({
    required List<String> notes,
    required String kpName,
    int count = 3,
  }) async {
    final resp = await client.chat(ChatRequest(
      system: kAiProblemSystemPrompt,
      user: '关联考点：$kpName\n'
          '本节课笔记要点：\n${notes.map((n) => '- $n').join('\n')}\n\n'
          '请出 $count 道题。',
      temperature: 0.7, // 出题需要一点变化；诚实性靠"答案自洽"约束
      jsonMode: true,
      maxTokens: 3072,
    ));
    final outcome =
        IngestExtractor.parse(resp.text, sourceName: 'AI 自创题');
    final warnings = [...outcome.warnings];
    if (resp.truncated) {
      warnings.insert(0, '模型输出被截断，这轮题可能少一些。');
    }
    return AiProblemDraftResult(
        problems: outcome.problems, warnings: warnings);
  }
}
