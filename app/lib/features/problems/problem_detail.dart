/// 题目详情弹层 + 统一的动作处理。
///
/// ## 为什么从 `problems_page.dart` 里搬出来
///
/// 知识库详情页的「你的题目」也要点开同一张详情抽屉（同一个 sheet、
/// 同一套编辑/记错/删除动作）。原来整个 sheet 是 `_` 私有类、动作处理
/// 写在 `_ProblemsPageState` 里 —— 知识库要用就只能再抄一遍，
/// 而"两处各写一遍"的下场就是动作语义迟早不一致
/// （一个能记错一个不能、删除确认文案一边改了另一边没改）。
///
/// 抽出来之后：**sheet 与动作处理只有这一份**，错题本与知识库都从这里走。
/// 页面各自的差异（刷新列表 / 刷新考点清单）通过 [openProblemDetail] 的
/// `onChanged` 回调交还给调用方。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/math/math_renderer.dart';
import '../../core/providers.dart';
import '../../data/markdown/problem_markdown.dart';
import '../../domain/problem_draft.dart';
import '../entry/entry_page.dart';
import 'problem_images.dart';
import 'tag_explanation_panel.dart';

/// 打开一道题的详情抽屉，并**统一处理**编辑/记错/删除三个动作。
///
/// [onChanged] 在题目被修改（编辑保存回来）或题库被改动（记错/删除）后
/// 调用一次 —— 调用方用它刷新自己的列表/清单；没传就没有刷新，
/// 所以调用方只要关心数据变化就应当传。
Future<void> openProblemDetail(
  BuildContext context,
  WidgetRef ref,
  Problem problem, {
  VoidCallback? onChanged,
}) async {
  final problemId = problem.id;
  // SnackBar 在多个 await 之后还要发 —— 提前拿 messenger，
  // 不在异步间隙之后再碰 context（use_build_context_synchronously）。
  final messenger = ScaffoldMessenger.of(context);
  final action = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (_) => ProblemDetailSheet(problem: problem),
  );

  switch (action) {
    case 'edit':
      if (!context.mounted) return;
      // 编辑：把题目反向填进编辑页（M4 的表单本来就能接收草稿）
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => EntryPage(initial: ProblemDraft.fromProblem(problem)),
        ),
      );
      onChanged?.call(); // 回来后刷新（题干可能已经改了）
    case 'wrong':
      try {
        final repo = await ref.read(reviewRepositoryProvider.future);
        await repo.recordWrong(problemId);
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('记错失败：$e')));
        return;
      }
      messenger.showSnackBar(const SnackBar(content: Text('已记一次错')));
      onChanged?.call();
    case 'delete':
      if (context.mounted) {
        await _confirmDelete(context, ref, problem, onChanged, messenger);
      }
  }
}

Future<void> _confirmDelete(
  BuildContext context,
  WidgetRef ref,
  Problem problem,
  VoidCallback? onChanged,
  ScaffoldMessengerState messenger,
) async {
  final problemId = problem.id;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除这道题？'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('将删除 Markdown 文件与索引行：\n$problemId',
              style: const TextStyle(fontSize: 12.5)),
          const SizedBox(height: 12),
          const Text(
            '复习进度（错题次数、FSRS 间隔与复习历史）也会一并清除，无法恢复。',
            style: TextStyle(fontSize: 12, height: 1.6),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
          ),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (ok != true) return;

  final bool removed;
  try {
    final service = await ref.read(problemServiceProvider.future);
    removed = await service.delete(problemId);
  } catch (e) {
    // 删除要动四张表再删文件，中途抛异常时早先没有任何提示 ——
    // 异常直接进 FlutterError，用户看到的是一个什么都没发生的界面。
    messenger.showSnackBar(SnackBar(content: Text('删除失败：$e')));
    return;
  }
  messenger.showSnackBar(SnackBar(
    content: Text(removed ? '已删除' : '删除失败（文件可能已不在）'),
  ));
  if (removed) onChanged?.call();
}

// ─────────────────────────────────────────────────────────────────────────────
// 详情 sheet（内容渲染，自 problems_page.dart 原样搬入）
// ─────────────────────────────────────────────────────────────────────────────

/// 一道题的完整详情。返回的动作字符串（'edit' / 'wrong' / 'delete'）
/// 由 [openProblemDetail] 处理 —— **不要**绕过它直接 pop 自定义动作，
/// 那会让动作语义出现第二份真相。
class ProblemDetailSheet extends ConsumerStatefulWidget {
  final Problem problem;

  const ProblemDetailSheet({super.key, required this.problem});

  @override
  ConsumerState<ProblemDetailSheet> createState() => _ProblemDetailSheetState();
}

class _ProblemDetailSheetState extends ConsumerState<ProblemDetailSheet> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final renderer = MathRendering.renderer;
    final problem = widget.problem;
    // 题库路径没就绪（罕见）时 imagesDirPath 传 null → 组件显示"缺失"占位。
    final paths = ref.watch(libraryPathsProvider).valueOrNull;
    final imagesDir = paths?.images.path;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (_, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(problem.id,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
              ),
              IconButton(
                tooltip: '关闭',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _kv(theme, '题型', problem.qtype.label),
          _kv(theme, '难度',
              problem.difficulty == 1 ? '基础' : (problem.difficulty == 2 ? '综合' : '拓展')),
          if (problem.primaryKnowledge != null)
            _kv(theme, '主考点', problem.primaryKnowledge!.id),
          if (problem.knowledge.length > 1)
            _kv(
              theme,
              '次考点',
              problem.knowledge
                  .where((k) => !k.isPrimary)
                  .map((k) => k.id)
                  .join('、'),
            ),
          if (problem.source != null) _kv(theme, '来源', problem.source!),
          _kv(theme, '指纹', problem.fingerprint),
          const Divider(height: 28),
          // 图为主（扫描题）：配图就是题目本体，OCR 文本收进折叠区；
          // 否则维持原样：文字为主，配图挂在下方（示意图语义）。
          if (problem.imagesPrimary && problem.images.isNotEmpty) ...[
            const _SectionLabel('题干（印刷原图）'),
            const SizedBox(height: 6),
            ProblemImageList(
              images: problem.images,
              imagesDirPath: imagesDir,
              maxHeight: 480,
            ),
            if (problem.stem.isNotEmpty) ...[
              OcrTextDisclosure(stem: problem.stem, options: problem.options),
            ],
          ] else ...[
            const _SectionLabel('题干'),
            renderer.renderMarkdown(problem.stem),
            if (problem.images.isNotEmpty) ...[
              const SizedBox(height: 10),
              ProblemImageList(images: problem.images, imagesDirPath: imagesDir),
            ],
            if (problem.options.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (var i = 0; i < problem.options.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                      '${String.fromCharCode(65 + i)}. ${problem.options[i]}'),
                ),
            ],
          ],
          if (problem.answer != null) ...[
            const Divider(height: 28),
            const _SectionLabel('答案'),
            renderer.renderMarkdown(problem.answer!),
          ],
          if (problem.solution != null) ...[
            const Divider(height: 28),
            const _SectionLabel('解析'),
            renderer.renderMarkdown(problem.solution!),
          ],
          if (problem.note != null) ...[
            const Divider(height: 28),
            const _SectionLabel('我的笔记'),
            renderer.renderMarkdown(problem.note!),
          ],
          // 「AI 为什么这么判」——折叠区，展开才去算召回。
          //
          // 位置放在内容之后、操作按钮之前：想复核标注的人会顺着读完题干
          // 与解析再往下看；不想看的人不需要滚动跳过它。
          const Divider(height: 28),
          TagExplanationPanel(problem: problem),
          const Divider(height: 28),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop('edit'),
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('编辑'),
              ),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop('wrong'),
                icon: const Icon(Icons.replay, size: 16),
                label: const Text('再记一次错'),
              ),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop('delete'),
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('删除'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _kv(ThemeData theme, String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 56,
              child: Text(k,
                  style: TextStyle(
                      fontSize: 11.5,
                      color: theme.colorScheme.onSurfaceVariant)),
            ),
            Expanded(child: Text(v, style: const TextStyle(fontSize: 11.5))),
          ],
        ),
      );
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
      );
}
