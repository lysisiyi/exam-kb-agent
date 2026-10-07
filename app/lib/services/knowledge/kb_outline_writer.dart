/// 建库向导的 AI 骨架（K2）：输入课程名 → 目录骨架 JSON → 大纲节点。
///
/// 纪律（与 V3_KB_PLAN §2 一致）：**AI 只出目录和空位，不写内容**。
/// 生成结果先在向导里给用户过目（预览），确认才落盘成 md 树。
///
/// 解析是纯函数（[parseOutlineJson]），测试不碰网。
library;

import '../../data/knowledge_md/knowledge_md_store.dart' show KbOutlineNode;
import '../llm/llm_client.dart';
import '../llm/robust_json.dart';

const kKbOutlineSystemPrompt =
    '你是课程知识库的目录设计师。根据给定的课程名（与可选的补充说明），'
    '设计一份**三级骨架目录**：章 → 节 → 知识点。\n'
    '硬约束：\n'
    '- **只给目录名称**，不要写任何内容（定义/公式/例题一律不写）。\n'
    '- 知识点名称要具体到可当复习单元（如"等价无穷小代换"），不要写"相关练习"这类空话。\n'
    '- 章 8–14 个为宜；每章 2–5 节；每节 2–6 个知识点。\n'
    '- 严格输出 JSON：{"title":"课程名","outline":[{"name":"第一章 …",'
    '"children":[{"name":"第一节 …","children":[{"name":"知识点"}]}]}]}';

class KbOutlineResult {
  final String title;
  final List<KbOutlineNode> outline;
  const KbOutlineResult({required this.title, required this.outline});
}

/// 调用文本模型生成骨架。
Future<KbOutlineResult?> generateKbOutline(
  LlmClient client, {
  required String courseName,
  String? note,
}) async {
  final resp = await client.chat(ChatRequest(
    system: kKbOutlineSystemPrompt,
    user: '课程名：$courseName\n'
        '${note == null || note.trim().isEmpty ? '' : '补充说明：$note'}',
    temperature: 0.4,
    jsonMode: true,
    maxTokens: 3072,
  ));
  return parseOutlineJson(resp.text, fallbackTitle: courseName);
}

/// 解析骨架 JSON。解析不出返回 null；节点名去空、全空的 children 归一为空表。
KbOutlineResult? parseOutlineJson(String raw, {required String fallbackTitle}) {
  final ex = RobustJson.extract(raw, acceptArray: true);
  final root = ex.value;
  // 宽容：有的模型只给一个数组
  final rawOutline = root?['outline'] is List
      ? root!['outline'] as List
      : ex.listValue;
  if (rawOutline == null || rawOutline.isEmpty) return null;

  List<KbOutlineNode> walk(List<dynamic> list) {
    final out = <KbOutlineNode>[];
    for (final item in list) {
      if (item is! Map) continue;
      final name = item['name']?.toString().trim() ?? '';
      if (name.isEmpty) continue;
      final kids = item['children'] is List
          ? walk(item['children'] as List)
          : const <KbOutlineNode>[];
      out.add(KbOutlineNode(name: name, children: kids));
    }
    return out;
  }

  final outline = walk(rawOutline);
  if (outline.isEmpty) return null;
  final title = (root?['title']?.toString().trim() ?? '').isEmpty
      ? fallbackTitle
      : root!['title'].toString().trim();
  return KbOutlineResult(title: title, outline: outline);
}

/// 大纲 → 预览文本（向导里给用户过目；只展前 [maxLines] 行）。
String outlinePreview(List<KbOutlineNode> outline, {int maxLines = 40}) {
  final lines = <String>[];
  void walk(List<KbOutlineNode> nodes, int depth) {
    for (final n in nodes) {
      if (lines.length >= maxLines) return;
      lines.add('${'  ' * depth}· ${n.name}');
      walk(n.children, depth + 1);
    }
  }

  walk(outline, 0);
  var leaves = 0;
  void count(List<KbOutlineNode> nodes) {
    for (final n in nodes) {
      if (n.children.isEmpty) {
        leaves++;
      } else {
        count(n.children);
      }
    }
  }

  count(outline);
  final shown = lines.length < maxLines ? lines.length : maxLines;
  return '${lines.take(shown).join('\n')}'
      '${lines.length >= maxLines ? '\n…（预览截断，完整树确认后生成）' : ''}'
      '\n共 ${outline.length} 章 / $leaves 个知识点';
}
