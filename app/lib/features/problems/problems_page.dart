/// 错题本列表页。
///
/// ## 为什么这一页是"最急"的
///
/// M4 之后，用户录进去的题**只写进了 Markdown 文件，界面上任何地方都看不到**。
/// 录入闭环缺了"回看"这一半 —— 而产品的前提是"录完第一题会想录第二题"，
/// 看不到自己录了什么，这个前提就不成立。
///
/// ## 三种浏览方式，对应三种真实需求
///
/// | 入口 | 用户想干什么 |
/// |---|---|
/// | 搜索 | "我记得录过一道含 `sinx` 的极限题" |
/// | 全部（默认按录入时间倒序） | "看看我最近录了什么" |
/// | 待复习 | "今天该复习哪些" |
///
/// 排序刻意做成显式的一组 chip 而不是隐藏的下拉菜单 ——
/// 用户需要知道"我现在看的是什么顺序"。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/breakpoints.dart';
import '../../core/math/math_renderer.dart';
import '../../core/providers.dart';
import '../../data/markdown/problem_markdown.dart';
import '../../domain/problem_draft.dart';
import '../../services/review/review_repository.dart';
import '../entry/entry_page.dart';

/// 列表的排序/筛选方式。
enum ProblemView {
  recent('最近录入'),
  mostWrong('错题最多'),
  due('待复习');

  const ProblemView(this.label);
  final String label;
}

class ProblemsPage extends ConsumerStatefulWidget {
  const ProblemsPage({super.key});

  @override
  ConsumerState<ProblemsPage> createState() => _ProblemsPageState();
}

class _ProblemsPageState extends ConsumerState<ProblemsPage> {
  final _query = TextEditingController();
  ProblemView _view = ProblemView.recent;
  String _search = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Toolbar(
          query: _query,
          view: _view,
          onView: (v) => setState(() => _view = v),
          onQuery: (q) => setState(() => _search = q.trim()),
        ),
        const Divider(height: 1),
        Expanded(
          child: _search.isEmpty
              ? _BrowseList(view: _view, onOpen: _openDetail)
              : _SearchList(query: _search, onOpen: _openDetail),
        ),
      ],
    );
  }

  Future<void> _openDetail(String problemId) async {
    final store = await ref.read(problemStoreProvider.future);
    final read = await store.read(problemId);
    if (!mounted) return;
    if (!read.isOk) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('读取失败：${read.error}')),
      );
      return;
    }

    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ProblemDetailSheet(problem: read.problem!),
    );
    if (!mounted || action == null) return;

    switch (action) {
      case 'edit':
        // 编辑：把题目反向填进录入页（M4 的表单本来就能接收草稿）
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => EntryPage(initial: ProblemDraft.fromProblem(read.problem!)),
          ),
        );
        if (mounted) setState(() {}); // 回来后刷新列表
      case 'wrong':
        final repo = await ref.read(reviewRepositoryProvider.future);
        await repo.recordWrong(problemId);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已记一次错')),
        );
        setState(() {});
      case 'delete':
        await _confirmDelete(problemId, read.problem!);
    }
  }

  Future<void> _confirmDelete(String problemId, Problem p) async {
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
              '复习进度（错题次数、FSRS 间隔与复习历史）也会一并清除，'
              '无法恢复。',
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
    if (ok != true || !mounted) return;

    final service = await ref.read(problemServiceProvider.future);
    final removed = await service.delete(problemId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(removed ? '已删除' : '删除失败（文件可能已不在）')),
    );
    setState(() {});
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 工具栏
// ─────────────────────────────────────────────────────────────────────────────

class _Toolbar extends StatelessWidget {
  final TextEditingController query;
  final ProblemView view;
  final ValueChanged<ProblemView> onView;
  final ValueChanged<String> onQuery;

  const _Toolbar({
    required this.query,
    required this.view,
    required this.onView,
    required this.onQuery,
  });

  @override
  Widget build(BuildContext context) {
    final narrow = BreakpointScope.of(context) == LayoutBreakpoint.compact;
    final search = TextField(
      controller: query,
      onChanged: onQuery,
      decoration: const InputDecoration(
        isDense: true,
        prefixIcon: Icon(Icons.search, size: 18),
        hintText: '搜题干、考点、来源（中文按字匹配）',
        border: OutlineInputBorder(),
      ),
    );
    final chips = Wrap(
      spacing: 6,
      children: [
        for (final v in ProblemView.values)
          ChoiceChip(
            label: Text(v.label),
            selected: view == v,
            onSelected: (_) => onView(v),
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [search, const SizedBox(height: 8), chips],
            )
          : Row(
              children: [
                Expanded(child: search),
                const SizedBox(width: 12),
                chips,
              ],
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 列表
// ─────────────────────────────────────────────────────────────────────────────

/// 不带搜索时的浏览列表。
class _BrowseList extends ConsumerWidget {
  final ProblemView view;
  final void Function(String problemId) onOpen;

  const _BrowseList({required this.view, required this.onOpen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(problemListProvider(view));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('载入失败：$e')),
      data: (rows) => rows.isEmpty
          ? const _EmptyState()
          : _List(rows: rows, onOpen: onOpen),
    );
  }
}

/// 搜索结果的列表。
class _SearchList extends ConsumerWidget {
  final String query;
  final void Function(String problemId) onOpen;

  const _SearchList({required this.query, required this.onOpen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(problemSearchProvider(query));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('检索失败：$e')),
      data: (hits) {
        if (hits.isEmpty) {
          return Center(
            child: Text('没有匹配「$query」的题目',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          itemCount: hits.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final h = hits[i];
            return _ProblemTile(
              problemId: h.problemId,
              stemText: h.stemText,
              primaryKpName: h.primaryKpName,
              difficulty: h.difficulty,
              source: h.source,
              onTap: () => onOpen(h.problemId),
            );
          },
        );
      },
    );
  }
}

class _List extends StatelessWidget {
  final List<ProblemListRow> rows;
  final void Function(String problemId) onOpen;

  const _List({required this.rows, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final r = rows[i];
        return _ProblemTile(
          problemId: r.problemId,
          stemText: r.stemText,
          primaryKpName: r.primaryKpName,
          difficulty: r.difficulty,
          source: r.source,
          needsReview: r.needsReview,
          wrongCount: r.wrongCount,
          mastery: r.mastery,
          due: dueOfState(r.state),
          onTap: () => onOpen(r.problemId),
        );
      },
    );
  }
}

class _ProblemTile extends StatelessWidget {
  final String problemId;
  final String stemText;
  final String? primaryKpName;
  final int difficulty;
  final String? source;
  final bool needsReview;
  final int wrongCount;
  final double mastery;
  final DateTime? due;
  final VoidCallback onTap;

  const _ProblemTile({
    required this.problemId,
    required this.stemText,
    required this.onTap,
    this.primaryKpName,
    this.difficulty = 2,
    this.source,
    this.needsReview = false,
    this.wrongCount = 0,
    this.mastery = 0,
    this.due,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 题干本来就是"保留 LaTeX 的可读文本"，直接交给渲染器即可
    final stem = MathRendering.renderer.renderMarkdown(
      stemText.length > 160 ? '${stemText.substring(0, 160)}…' : stemText,
      options: MathRenderOptions(fontSize: 13.5),
    );

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DefaultTextStyle.merge(
                    style: const TextStyle(height: 1.7),
                    child: stem,
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (primaryKpName != null)
                        _Pill(
                          text: primaryKpName!,
                          color: theme.colorScheme.primary,
                        )
                      else if (needsReview)
                        _Pill(text: '待补考点', color: theme.colorScheme.error),
                      if (wrongCount > 0)
                        _Pill(text: '错 $wrongCount 次', color: const Color(0xFFE03131)),
                      if (due != null)
                        _Pill(
                          text: describeDue(due),
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      if (mastery > 0)
                        _Pill(
                          text: '掌握 ${(mastery * 100).round()}%',
                          color: const Color(0xFF0CA678),
                        ),
                      _Pill(
                        text: difficulty == 1
                            ? '基础'
                            : (difficulty == 2 ? '综合' : '拓展'),
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      if (source != null && source!.isNotEmpty)
                        _Pill(
                          text: source!,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(problemId,
                style: TextStyle(
                    fontSize: 10,
                    color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;

  const _Pill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined,
                size: 44, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            const Text('错题本还是空的', style: TextStyle(fontSize: 15)),
            const SizedBox(height: 6),
            Text(
              '去「录入」页记下第一道题 —— 之后它会出现在这里，\n'
              '并按遗忘曲线进入「今日复习」。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.7,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 详情
// ─────────────────────────────────────────────────────────────────────────────

class _ProblemDetailSheet extends StatelessWidget {
  final Problem problem;

  const _ProblemDetailSheet({required this.problem});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final renderer = MathRendering.renderer;

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
          const _SectionLabel('题干'),
          renderer.renderMarkdown(problem.stem),
          if (problem.options.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (var i = 0; i < problem.options.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('${String.fromCharCode(65 + i)}. ${problem.options[i]}'),
              ),
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
