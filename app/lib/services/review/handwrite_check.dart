/// 手写答案拍照核对（V2-3.2，可选能力，默认关）。
///
/// ## 契约（与批量导入「防模型编造」同一纪律）
///
/// AI 只做**参照**：返回手写解答的**要点命中清单**（命中/未命中的步骤），
/// **不给总分**、不替代打分 —— FSRS 的输入必须是人类判断。
/// 提示词里写死这条边界，解析层也只认 `points` 数组。
///
/// ## 可用性
///
/// 每次调用真实计费，进用量台账；任何失败（无 Key、无视觉能力、网络、
/// 解析失败）如实抛给 UI，由 UI 退回手动打分 —— 「AI 挂了产品不能挂」。
library;


import '../llm/llm_client.dart';
import '../llm/robust_json.dart';

/// 一条要点核对的结论。
class HandwritePoint {
  final String name;

  /// 手写解答里是否命中了这个要点。
  final bool hit;

  /// 一句话说明（命中：在哪里体现；未命中：缺了什么）。
  final String note;

  const HandwritePoint({
    required this.name,
    required this.hit,
    required this.note,
  });

  factory HandwritePoint.fromJson(Map<String, dynamic> j) => HandwritePoint(
        name: (j['name'] ?? '').toString(),
        hit: j['hit'] == true,
        note: (j['note'] ?? '').toString(),
      );
}

class HandwriteCheckResult {
  final List<HandwritePoint> points;

  final LlmUsage usage;

  const HandwriteCheckResult({required this.points, required this.usage});
}

/// 构造核对请求的提示词。
///
/// 系统提示写死三条：只对照不给分、逐条要点输出 JSON、答案以题库为准。
String handwriteCheckSystemPrompt() =>
    '你是数学解题过程核对助手。用户给出题目答案/解析（标准参照）与一张手写解答照片。'
    '你的任务：把手写解答与标准解析对照，列出关键步骤要点的命中情况。'
    '规则：1) 只做对照分析，**绝不打分、不评对错等级** —— 评分由使用者本人完成；'
    '2) 逐条要点输出：name（要点名）、hit（true/false）、note（一句话依据）；'
    '3) 手写内容看不清时如实写 hit=false、note=「无法辨认」，不要猜；'
    '4) 只输出 JSON：{"points":[{"name":"...","hit":true,"note":"..."}]}。';

/// 用户消息：标准答案/解析 + （图片由附件承载）。
String handwriteCheckUserPrompt({String? answer, String? solution}) {
  final b = StringBuffer('请对照以下标准参照，核对我的手写解答：\n');
  if (answer != null && answer.trim().isNotEmpty) {
    b.writeln('\n【标准答案】\n${answer.trim()}');
  }
  if (solution != null && solution.trim().isNotEmpty) {
    b.writeln('\n【标准解析】\n${solution.trim()}');
  }
  if (answer == null && solution == null) {
    b.writeln('\n（题库没有存标准答案与解析 —— 只列出你能在手写里辨认出的'
        '解题步骤要点，hit 一律按"可见/不可见"判断。）');
  }
  return b.toString();
}

/// 调视觉模型核对手写解答。
///
/// [attachment] 由调用方从所选图片构造（录入/复习两处的图片来源不同，
/// 这里只认构造好的附件）。解析走 [RobustJson] —— 模型输出不规范的
/// 兜底与批量导入同一条路。
Future<HandwriteCheckResult> checkHandwrittenAnswer({
  required LlmClient client,
  required ChatAttachment attachment,
  String? answer,
  String? solution,
  int maxTokens = 2048,
}) async {
  final resp = await client.chat(ChatRequest(
    system: handwriteCheckSystemPrompt(),
    user: handwriteCheckUserPrompt(answer: answer, solution: solution),
    attachments: [attachment],
    temperature: 0.0,
    jsonMode: true,
    maxTokens: maxTokens,
  ));

  final extracted = RobustJson.extract(resp.text, acceptArray: true);
  // 顶层是对象时用 value，顶层是数组时用 listValue（value 为 null）
  final Object? root = extracted.value ?? extracted.listValue;
  // 两种形状都认：{"points":[...]} 或顶层就是 [...]（模型经常不包壳，
  // 与批量导入同一条宽容度）。其余形状按"没按契约"处理。
  final list = <dynamic>[];
  if (root is Map) {
    final pts = root['points'];
    if (pts is List) list.addAll(pts);
  } else if (root is List) {
    list.addAll(root);
  }

  final points = <HandwritePoint>[
    for (final item in list)
      if (item is Map)
        HandwritePoint.fromJson(item.cast<String, dynamic>()),
  ];

  // 全军覆没（有输出但解析不出 points）→ 如实报，而不是显示"0 个要点"
  // 让用户以为手写解答一无所是。
  if (resp.text.trim().isNotEmpty && points.isEmpty) {
    throw const LlmException(
      LlmErrorKind.badResponse,
      '模型返回的核对结果无法解析（缺少 points 字段）',
    );
  }

  return HandwriteCheckResult(points: points, usage: resp.usage);
}
