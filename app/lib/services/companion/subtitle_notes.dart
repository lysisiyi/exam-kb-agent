/// 字幕分窗总结（P4）：把一个窗口的字幕交给文本模型 → 若干条课堂笔记。
///
/// 解析复用截图轨的 `parseCompanionNotes`（同一 JSON 契约），
/// prompt 纪律也一致：只记录、不解题、不扩展；空窗口输出空列表。
library;

import '../llm/llm_client.dart';
import 'bilibili_client.dart';
import 'note_llm.dart' show RawNote, parseCompanionNotes;

const kSubtitleSummarySystemPrompt =
    '你是网课课堂记录员。下面是一段网课字幕，每行形如 [时间] 内容。\n'
    '把它总结成若干条课堂笔记要点：\n'
    '- 只记录老师讲的知识点（定义、公式、方法、易错点），不解题、不扩展。\n'
    '- 每条给 time：用字幕里出现的时间（mm:ss 或 h:mm:ss），取该要点首次出现的行。\n'
    '- 有公式就记进 formula（LaTeX 或原文）。\n'
    '- 纯寒暄/举例/无知识点的段落不要记。\n'
    '严格输出 JSON：{"notes":[{"time":"mm:ss","point":"要点","formula":"公式"}]}；'
    '本窗口没有可记内容时输出 {"notes":[]}。';

/// 总结一个窗口。[client] 是文本模型客户端（BYOK）。
Future<List<RawNote>> summarizeSubtitleWindow(
    LlmClient client, List<SubtitleLine> window) async {
  final resp = await client.chat(ChatRequest(
    system: kSubtitleSummarySystemPrompt,
    user: windowToPromptText(window),
    temperature: 0.2,
    jsonMode: true,
    maxTokens: 2048,
  ));
  return parseCompanionNotes(resp.text);
}
