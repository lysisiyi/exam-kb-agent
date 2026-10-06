# -*- coding: utf-8 -*-
"""给 knowledge_leaf_detail.dart 打补丁：AI 草稿闭环（按钮+琥珀框+三操作）。"""
from pathlib import Path

p = Path("lib/features/knowledge/knowledge_leaf_detail.dart")
s = p.read_text(encoding="utf-8")

# 1) imports
old = "import '../../services/profile/mastery_service.dart';"
assert old in s, "import anchor"
s = s.replace(old, """import '../../data/knowledge_md/knowledge_md_store.dart';
import '../../services/llm/llm_client.dart';
import '../../services/profile/mastery_service.dart';
import 'dart:io';

import '../../data/problem_file.dart';""", 1)

# dart:io / problem_file 若已有则不重复——检查
if s.count("import 'dart:io';") > 1:
    s = s.replace("import 'dart:io';\n\nimport '../../data/problem_file.dart';\n", "", 1)

# 2) 标题行加状态 chip（已填/骨架）——插在 _WeightPill 之前
old2 = """              if (leaf.examWeight != null) _WeightPill(weight: leaf.examWeight!),
            ],
          ),"""
new2 = """              // md 状态（与树上的状态点、页头 chips 同一口径：有定义即已填）
              _MdStatusPill(
                  filled: (leaf.definition ?? '').trim().isNotEmpty),
              if (leaf.examWeight != null) ...[
                const SizedBox(width: 6),
                _WeightPill(weight: leaf.examWeight!),
              ],
            ],
          ),"""
assert old2 in s, "title row"
s = s.replace(old2, new2)

# 3) 相关题目之前插入 AI 草稿节
old3 = """          // ── 你的题目 ──────────────────────────────────────────────────"""
new3 = """          // ── AI 补全此节（参考图 ui_knowledge.png 的虚线草稿框） ─────────
          _AiDraftSection(leaf: leaf, crumbs: crumbs),

          // ── 你的题目 ──────────────────────────────────────────────────"""
assert old3 in s, "problems anchor"
s = s.replace(old3, new3, 1)

# 4) 文件尾部追加：状态 pill / 草稿节组件 + provider
s += r'''

/// md 状态小胶囊：已填（实心绿点）/ 骨架（空心点）。
class _MdStatusPill extends StatelessWidget {
  final bool filled;
  const _MdStatusPill({required this.filled});

  @override
  Widget build(BuildContext context) {
    final color = filled ? AppColors.success : AppColors.ink3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? color : null,
            border: filled ? null : Border.all(color: color, width: 1.4),
          ),
        ),
        const SizedBox(width: 5),
        Text(filled ? '已填' : '骨架',
            style: TextStyle(
                fontSize: KnowledgeSizes.secondary,
                fontWeight: FontWeight.w700,
                color: color)),
      ]),
    );
  }
}

/// AI 草稿提示词：只依据给定信息起草，不编造；输出纯 Markdown 正文。
const _kDraftSystemPrompt =
    '你在帮用户完善他的知识库草稿。只依据给定信息起草，不要引入不确定的细节，宁可简短。\n'
    '输出纯 Markdown 正文（不要代码块围栏、不要任何小节标题）、依次是：一段简短定义；'
    '若干条核心公式（每条独立成行，用双美元号包裹）；若干条易错点（用 - 开头）。';

/// 草稿读写通道（按 md 文件夹；找不到文件/未导入时如实返回 null）。
final knowledgeMdStoreProvider = FutureProvider<KnowledgeMdStore>((ref) async {
  final paths = await ref.watch(libraryPathsProvider.future);
  return KnowledgeMdStore(root: Directory('${paths.root.path}/knowledge'));
});

/// 该知识点 md 里现存的 AI 草稿正文（无草稿/无文件 = null）。
final kpAiDraftProvider =
    FutureProvider.family<String?, String>((ref, nodeId) async {
  final store = await ref.watch(knowledgeMdStoreProvider.future);
  final subject = ref.watch(currentSubjectProvider).id;
  final file = store.fileOf(subject, nodeId);
  if (file == null) return null;
  return store.draftOf(file);
});

/// 「AI 补全此节」按钮 + 草稿琥珀框（接纳/丢弃/重新生成）。
///
/// 纪律：草稿只写进 md 的 `## AI 草稿（待确认）` 小节，
/// **用户点"接纳"之前绝不并入正式内容**。
class _AiDraftSection extends ConsumerStatefulWidget {
  final KnowledgePoint leaf;
  final List<String> crumbs;
  const _AiDraftSection({required this.leaf, required this.crumbs});

  @override
  ConsumerState<_AiDraftSection> createState() => _AiDraftSectionState();
}

class _AiDraftSectionState extends ConsumerState<_AiDraftSection> {
  bool _busy = false;
  String? _status;

  Future<File?> _fileFor() async {
    final store = await ref.read(knowledgeMdStoreProvider.future);
    final subject = ref.read(currentSubjectProvider).id;
    return store.fileOf(subject, widget.leaf.id);
  }

  Future<void> _generate() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final client = ref.read(chatClientProvider);
      if (client == null) {
        setState(() => _status = '先到「设置」里配好 AI 服务商（文本模型即可）。');
        return;
      }
      final file = await _fileFor();
      if (file == null) {
        setState(() => _status = '找不到这个知识点的 md 文件——知识库需来自 knowledge/ 文件夹（K1 导入）。');
        return;
      }
      final leaf = widget.leaf;
      final resp = await client.chat(ChatRequest(
        system: _kDraftSystemPrompt,
        user: '知识点：${leaf.name}\n'
            '章节：${widget.crumbs.join(' › ')}\n'
            '已有定义：${(leaf.definition ?? '').trim().isEmpty ? '（无）' : leaf.definition}\n'
            '已有公式：${leaf.formulas.isEmpty ? '（无）' : leaf.formulas.join('；')}',
        temperature: 0.3,
        maxTokens: 1024,
      ));
      final store = await ref.read(knowledgeMdStoreProvider.future);
      store.writeAiDraft(file, resp.text.trim());
      ref.invalidate(kpAiDraftProvider(widget.leaf.id));
      setState(() => _status = '草稿已写入 md 的「AI 草稿（待确认）」小节。');
    } catch (e) {
      setState(() => _status = '生成失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept() async {
    final file = await _fileFor();
    if (file == null) return;
    final store = await ref.read(knowledgeMdStoreProvider.future);
    store.acceptAiDraft(file);
    ref.invalidate(kpAiDraftProvider(widget.leaf.id));
    // 定义小节变了 → 树内容与状态点一起刷新
    ref.invalidate(knowledgeBaseProvider);
    if (mounted) {
      setState(() => _status = '已接纳进「定义」小节。');
    }
  }

  Future<void> _discard() async {
    final file = await _fileFor();
    if (file == null) return;
    final store = await ref.read(knowledgeMdStoreProvider.future);
    store.discardAiDraft(file);
    ref.invalidate(kpAiDraftProvider(widget.leaf.id));
    if (mounted) {
      setState(() => _status = '草稿已丢弃。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(kpAiDraftProvider(widget.leaf.id));
    final hasDraft =
        draft.valueOrNull != null && (draft.valueOrNull ?? '').isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 13, bottom: 7),
          child: Row(children: [
            const _SectionTitle('AI 补全'),
            const Spacer(),
            TextButton.icon(
              onPressed: _busy ? null : _generate,
              icon: _busy
                  ? const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome, size: 15),
              label: Text(hasDraft ? '重新生成草稿' : 'AI 补全此节'),
              style: TextButton.styleFrom(
                  foregroundColor: AppColors.primaryStrong,
                  padding: const EdgeInsets.symmetric(horizontal: 8)),
            ),
          ]),
        ),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(_status!,
                style: const TextStyle(
                    fontSize: KnowledgeSizes.secondary,
                    color: AppColors.primaryStrong)),
          ),
        if (hasDraft)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
            decoration: BoxDecoration(
              color: AppColors.warningWeak,
              borderRadius: AppRadius.rMd,
              border: Border.all(color: AppColors.warning.withValues(alpha: 0.45)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('✨ AI 草稿（待确认） · 不会在接纳前并入正式内容',
                    style: TextStyle(
                        fontSize: KnowledgeSizes.secondary,
                        fontWeight: FontWeight.w700,
                        color: AppColors.warningInk)),
                const SizedBox(height: 6),
                MathRendering.renderer.renderMarkdown(
                  draft.valueOrNull!,
                  options: const MathRenderOptions(
                      fontSize: AppMathSizes.reading),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  FilledButton(
                    onPressed: _busy ? null : _accept,
                    style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6),
                        minimumSize: const Size(0, 32)),
                    child: const Text('✓ 接纳进「定义」',
                        style: TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _busy ? null : _discard,
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        minimumSize: const Size(0, 32)),
                    child:
                        const Text('丢弃', style: TextStyle(fontSize: 12)),
                  ),
                ]),
              ],
            ),
          ),
      ],
    );
  }
}
'''
p.write_text(s, encoding="utf-8")
print("patched knowledge_leaf_detail.dart")
