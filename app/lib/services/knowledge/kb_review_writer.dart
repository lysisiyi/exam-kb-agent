/// AI 梳理本章（K3 v1）：读一章的节点清单 → 出一份**整理报告**。
///
/// 纪律（V3_KB_PLAN §4）：AI 只**建议**，不动盘。报告列出「疑似重复 /
/// 过于零碎 / 建议补充 / 顺序与归类」四类观察，用户在编辑器里自己落实
/// （增删改、上移下移、拖拽）——v1 不做自动 diff 应用。
///
/// 范围解析与输入构建是纯函数（测试全覆盖）；模型调用走 BYOK 文本客户端。
library;

import '../../domain/knowledge/knowledge_point.dart';
import '../llm/llm_client.dart';
import '../llm/robust_json.dart';

/// 一次梳理的范围：一个"章节级"分支及其直接子节点。
class KbReviewScope {
  final String title;
  final List<KnowledgePoint> nodes;

  /// 本章的焦点节点 id（"建议补充但没指明父节点"时挂到它下面）。
  final String focalId;

  const KbReviewScope(
      {required this.title, required this.nodes, required this.focalId});
}

/// 解析梳理范围。
///
/// - [selected] 为 null → 落回知识库顶层（科目的直接子节点，即各章）。
/// - [selected] 是叶子 → 上溯到最近的**章节级分支**（id 段数 ≤ 3），
///   梳理"它所属的那一章"而不是孤立的一个知识点。
/// - 找不到合适的分支（空库/游离数据）→ null，调用方如实提示。
KbReviewScope? reviewScopeOf(KnowledgeBase kb, KnowledgePoint? selected) {
  KnowledgePoint? focal = selected;
  if (focal == null) {
    // 顶层：科目的直接子节点
    final roots = kb.childrenOf[kb.subject] ??
        kb.traversalRoots.fold<List<KnowledgePoint>>(
            [], (acc, r) => acc..addAll(kb.childrenOf[r.id] ?? const []));
    if (roots.isEmpty) return null;
    return KbReviewScope(
        title: kb.subjectName, nodes: List.of(roots), focalId: kb.subject);
  }
  // 上溯到分支
  while (focal != null && focal.isLeaf) {
    focal = focal.parentId == null ? null : kb.byId[focal.parentId];
  }
  // 再上溯到章节级（id 段数 ≤ 3：科目.分段.章节）
  while (focal != null && focal.idDepth > 3) {
    focal = focal.parentId == null ? null : kb.byId[focal.parentId];
  }
  if (focal == null) return null;
  final kids = kb.childrenOf[focal.id] ?? const <KnowledgePoint>[];
  if (kids.isEmpty) {
    return KbReviewScope(title: focal.name, nodes: [focal], focalId: focal.id);
  }
  return KbReviewScope(
      title: focal.name, nodes: List.of(kids), focalId: focal.id);
}

/// 给模型的本章清单：名称 + 状态 + 定义摘要（截断），节点数封顶。
String buildReviewInput(KbReviewScope scope, {int maxNodes = 40, int defCap = 60}) {
  final buf = StringBuffer('章节：${scope.title}\n节点清单（${scope.nodes.length} 个）：\n');
  for (final n in scope.nodes.take(maxNodes)) {
    final def = (n.definition ?? '').trim();
    final defPart = def.isEmpty
        ? '（尚无定义——骨架）'
        : '定义摘要：${def.length <= defCap ? def : '${def.substring(0, defCap)}…'}';
    buf.writeln('- ${n.name}｜${n.isLeaf ? '知识点' : '分支'}｜$defPart');
  }
  if (scope.nodes.length > maxNodes) {
    buf.writeln('（清单过长，仅列前 $maxNodes 个）');
  }
  return buf.toString();
}

const kKbReviewSystemPrompt =
    '你是知识库整理助手。看一份章节的节点清单，指出可整理之处。\n'
    '只**建议**，不重写内容；不确定的事不要编。输出纯 Markdown（不要代码围栏），'
    '固定四节，每节没有发现就写"未发现"：\n'
    '### 疑似重复\n（名称/含义高度重叠、建议合并的节点对）\n'
    '### 过于零碎\n（碎到不像复习单元、建议并入父节点的）\n'
    '### 建议补充\n（明显缺失的常见知识点，结合该章主题判断）\n'
    '### 顺序与归类\n（层级/次序问题，说明建议怎么调）\n'
    '最后一行给一句总评。';

/// 可机械应用的梳理建议（K3 v2）。
class ReviewSuggestions {
  final String summary;

  /// 建议加的别名：[(节点名, 别名)]。
  final List<(String, String)> aliases;

  /// 建议补充的子节点：[(父节点名(可空=本章根), 新节点名)]。
  final List<(String?, String)> missing;

  /// 其余观察（重复/零碎/顺序）——纯文本，落实靠编辑器。
  final String notes;

  const ReviewSuggestions({
    required this.summary,
    this.aliases = const [],
    this.missing = const [],
    this.notes = '',
  });

  bool get isEmpty => aliases.isEmpty && missing.isEmpty && notes.isEmpty;
}

/// 解析结构化建议；解析不出返回 null（调用方回退显示原文）。
ReviewSuggestions? parseReviewSuggestions(String raw) {
  final ex = RobustJson.extract(raw);
  final j = ex.value;
  if (j == null) return null;
  final aliases = <(String, String)>[];
  if (j['aliases'] is List) {
    for (final a in j['aliases'] as List) {
      if (a is! Map) continue;
      final node = a['node']?.toString().trim() ?? '';
      final alias = a['alias']?.toString().trim() ?? '';
      if (node.isNotEmpty && alias.isNotEmpty) aliases.add((node, alias));
    }
  }
  final missing = <(String?, String)>[];
  if (j['missing'] is List) {
    for (final m in j['missing'] as List) {
      if (m is! Map) continue;
      final name = m['name']?.toString().trim() ?? '';
      if (name.isEmpty) continue;
      final parent = m['parent']?.toString().trim() ?? '';
      missing.add((parent.isEmpty ? null : parent, name));
    }
  }
  final summary = j['summary']?.toString().trim() ?? '';
  final notes = j['notes']?.toString().trim() ?? '';
  final out = ReviewSuggestions(
      summary: summary, aliases: aliases, missing: missing, notes: notes);
  if (out.isEmpty) return null;
  return out;
}

/// 生成梳理报告（Markdown 文本）。失败由调用方 catch 后如实展示。
Future<String> reviewChapter(LlmClient client, KbReviewScope scope) async {
  final resp = await client.chat(ChatRequest(
    system: kKbReviewSystemPrompt,
    user: buildReviewInput(scope),
    temperature: 0.3,
    maxTokens: 2048,
  ));
  return resp.text.trim();
}
