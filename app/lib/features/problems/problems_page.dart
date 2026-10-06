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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/breakpoints.dart';
import '../../core/math/math_renderer.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/page_header.dart';
import '../../core/widgets/state_views.dart';
import '../../data/markdown/problem_markdown.dart';
import '../../data/problem_file.dart';
import '../../services/review/review_repository.dart';
import 'problem_detail.dart';

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

  /// 搜索去抖计时器。
  ///
  /// ## 为什么必须有
  ///
  /// 没有它时**每敲一个字符**都会发起一次 FTS 查询并切一次 provider：
  /// 5000 题的库上输入明显发涩，而且 `problemSearchProvider` 是按查询串
  /// 分家的 family —— 敲 20 个字符就攒下 20 份结果（每份最多 100 条），
  /// 它们再也不会被用到第二次。
  ///
  /// 250 ms 是个常见的取值：比最快的打字间隔长一点，比"感觉卡了"短得多。
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onQueryChanged(String raw) {
    final q = raw.trim();
    _debounce?.cancel();

    // 清空要**立刻**生效：用户按 Ctrl+A 删掉整串时，
    // 还要等 250 ms 才看到列表回来，会以为界面卡住了
    if (q.isEmpty) {
      if (_search.isNotEmpty) setState(() => _search = '');
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _search = q);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // V3 重设计：题库不再是顶级页，这里是从知识库进来的"全部题目"视图
        const PageHeader(
          title: '题目',
          subtitle: '练错的题都在这里——答错会自动计入错次并进入 FSRS 复习循环',
        ),
        _Toolbar(
          query: _query,
          view: _view,
          onView: (v) => setState(() => _view = v),
          onQuery: _onQueryChanged,
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
    final problem = await _loadDetail(problemId);
    if (!mounted || problem == null) return;

    // sheet 与编辑/记错/删除动作都走共享实现（problem_detail.dart）——
    // 知识库的「你的题目」点开的是同一张抽屉、同一套动作，两边不会漂移。
    // 本页的差异只有"改完刷新自己的列表"，经 onChanged 交还。
    await openProblemDetail(context, ref, problem, onChanged: _refresh);
  }

  /// 详情缓存（LRU，[kDetailCacheSize] 条）。
  ///
  /// 点开一道题要读盘 + 解析 Markdown。单次 1–5 ms（T40 记的就是这条），
  /// 但用户在新录完一批题之后会**反复来回翻同一批**核对，
  /// 每次都重新读盘既慢又没必要。
  ///
  /// 上限取 20：详情面板一次只显示一道题，20 条足够覆盖"来回翻"，
  /// 又不会在用户手工改了文件之后长期显示旧内容 ——
  /// [_refresh] 会清掉整个缓存。
  static const int kDetailCacheSize = 20;
  final Map<String, Problem> _detailCache = {};
  final List<String> _detailOrder = [];

  Problem? _cachedDetail(String id) {
    final hit = _detailCache[id];
    if (hit == null) return null;
    // 命中挪到队尾，保持 LRU 语义（与 MathRenderCache 同一个道理）
    if (_detailOrder.isNotEmpty && _detailOrder.last != id) {
      _detailOrder.remove(id);
      _detailOrder.add(id);
    }
    return hit;
  }

  void _cacheDetail(String id, Problem p) {
    _detailCache[id] = p;
    _detailOrder.remove(id);
    _detailOrder.add(id);
    while (_detailOrder.length > kDetailCacheSize) {
      _detailCache.remove(_detailOrder.removeAt(0));
    }
  }

  /// 取一道题的完整内容（带缓存）。失败时提示并返回 null。
  Future<Problem?> _loadDetail(String problemId) async {
    final cached = _cachedDetail(problemId);
    if (cached != null) return cached;

    final store = await ref.read(problemStoreProvider.future);
    final db = await ref.read(databaseProvider.future);
    // 按索引真实路径读：外部题库允许 id ≠ 文件名，按 id 推导会读错文件
    final read = await readIndexedProblem(
      db: db,
      store: store,
      problemId: problemId,
    );
    if (!mounted) return null;
    if (!read.isOk) {
      _snack('读取失败：${read.error}', error: true);
      return null;
    }
    _cacheDetail(problemId, read.problem!);
    return read.problem!;
  }

  /// 让列表与侧边栏角标重新取数。
  ///
  /// ⚠️ 只调 `setState` 是**不够**的。列表内容来自 `problemListProvider`
  /// （FutureProvider），Riverpod 会缓存它的结果 —— 重建 widget 只会拿到
  /// 同一份旧快照。后果是删掉一道题之后它仍留在列表里，
  /// 用户会以为删除失败了，于是再删一次。
  void _refresh() {
    // 详情缓存也要清：题目内容可能刚被编辑过，
    // 留着旧快照会让用户看到改动前的版本
    _detailCache.clear();
    _detailOrder.clear();

    ref.invalidate(problemListProvider);
    ref.invalidate(reviewStatsProvider);
    if (mounted) setState(() {});
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
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
      error: (e, _) => AppErrorView(
        title: '错题本载入失败',
        error: e,
        // 题库读不出来几乎都是瞬时问题（库被占用、一次 IO 抖动），
        // 重试一下基本就好 —— 早先这里只有一行字，用户唯一的出路是重启应用
        onRetry: () => ref.invalidate(problemListProvider),
      ),
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
      error: (e, _) => AppErrorView(
        title: '检索失败',
        error: e,
        hint: '全文检索依赖本机索引。若刚手工改动过 problems/ 目录，'
            '可以到「设置」里重建索引。',
        onRetry: () => ref.invalidate(problemSearchProvider),
      ),
      data: (hits) {
        if (hits.isEmpty) {
          // 空态要回答"那我该做什么"，而不只是"没找到"
          return AppEmptyView(
            icon: Icons.search_off,
            title: '没有匹配「$query」的题目',
            hint: '试试更短的关键词，或者只留一个考点名。\n'
                '中文是按字匹配的，不需要空格。',
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
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: rows.length,
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
      // 列表是扫读场景，走「紧凑」档 —— 与批量导入核对页同一个值。
      // 此前这里是 13.5、核对页是 13，同一类内容两个大小。
      options: const MathRenderOptions(fontSize: AppMathSizes.compact),
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.rMd,
        border: Border.all(color: AppColors.line),
        boxShadow: AppShadows.s1,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
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
                  // 行内标签刻意**只有**：考点（或待补）、待复核、错次。
                  // 难度/来源/掌握度/下次复习都在详情抽屉里 —— 行是扫读
                  // 场景，五个标签挤一行时哪个都看不出重点（用户反馈
                  // "标签怪怪的"，减法才是解法）。掌握度与到期去复习页看，
                  // 那里有更完整的上下文。
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
                      if (needsReview && primaryKpName != null)
                        const _Pill(text: '待复核', color: AppColors.warningInk),
                      if (wrongCount > 0)
                        _Pill(text: '错 $wrongCount 次', color: AppColors.danger),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        // 手账风：全圆角胶囊（原来是 5 的直角小方片）
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => const AppEmptyView(
        icon: Icons.inbox_outlined,
        title: '错题本还是空的',
        hint: '去「录入」页记下第一道题 —— 之后它会出现在这里，\n'
            '并按遗忘曲线进入「今日复习」。',
      );
}

