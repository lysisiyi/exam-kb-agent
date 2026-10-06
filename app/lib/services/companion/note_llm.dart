/// 课堂笔记的 GLM 视觉调用（V3_PLAN §4.1）。
///
/// 与批量导入同一套底座（`LlmClient.chat` + 附件 + RobustJson），
/// 但纪律不同：**只记录、不解题、不扩展**；画面没换/没有可记的内容
/// 就返回空列表——宁缺勿编。
library;

import 'dart:typed_data';

import '../llm/llm_client.dart';
import '../llm/robust_json.dart';

/// 视觉模型吐回来的一条原始笔记（尚未落盘）。
class RawNote {
  final String? time; // mm:ss（画面时间戳，读不到为 null）
  final String point;
  final String? formula;
  const RawNote({this.time, required this.point, this.formula});
}

const kCompanionSystemPrompt =
    '你是网课课堂记录员。看一张正在播放网课的画面截图，记录**这一画面里老师正在讲的知识点**。\n'
    '纪律：\n'
    '- 只记录画面/字幕里真实出现的内容（定义、公式、口诀、易错点）；不解题、不扩展、不用自己的知识补充。\n'
    '- 一条笔记一句话要点 point；画面里有公式就原样记进 formula（LaTeX 或原文）。\n'
    '- 画面里有播放器时间显示（如 32:14）就记进 time（mm:ss）；没有就不写 time。\n'
    '- 画面是片头/广告/复习页/无新内容时，输出 {"notes":[]}。\n'
    '- 严格输出 JSON：{"notes":[{"time":"mm:ss","point":"要点","formula":"公式"}]}，不要输出任何其他文字。';

/// 从视觉模型输出解析笔记。解析不出 → 空列表（调用方如实提示），不抛异常。
List<RawNote> parseCompanionNotes(String raw) {
  final ex = RobustJson.extract(raw, acceptArray: true);
  final list = ex.value?['notes'] is List
      ? ex.value!['notes'] as List
      : ex.listValue ?? const [];
  final out = <RawNote>[];
  for (final item in list) {
    if (item is! Map) continue;
    final point = (item['point'] ?? item['title'] ?? '')?.toString().trim() ?? '';
    if (point.isEmpty) continue;
    final time = item['time']?.toString().trim();
    final formula = item['formula']?.toString().trim();
    out.add(RawNote(
      time: (time == null || time.isEmpty || time == 'null') ? null : time,
      point: point,
      formula: (formula == null || formula.isEmpty || formula == 'null') ? null : formula,
    ));
  }
  return out;
}

/// 课堂笔记客户端：截图进、笔记出。
class CompanionNoteClient {
  final LlmClient client;

  /// 视觉模型 id。默认智谱免费视觉档（BYOK 纪律：付费需用户在设置里主动换）。
  final String model;

  CompanionNoteClient(this.client, {this.model = 'glm-4.6v-flash'});

  /// 返回 (笔记, 模型回复原文)。回复原文用于解析失败时的如实降级提示。
  Future<(List<RawNote>, String)> extractNotes(Uint8List jpegBytes) async {
    final resp = await client.chat(ChatRequest(
      system: kCompanionSystemPrompt,
      user: '请按纪律记录这张网课画面里的知识点。',
      attachments: [
        ChatAttachment(
          kind: ChatAttachmentKind.image,
          mimeType: 'image/jpeg',
          bytes: jpegBytes,
          name: 'lesson-frame.jpg',
        ),
      ],
      temperature: 0.2,
      jsonMode: true,
      maxTokens: 2048,
    ));
    return (parseCompanionNotes(resp.text), resp.text);
  }
}
