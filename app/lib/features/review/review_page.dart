/// 今日复习页 —— FSRS 的实际使用面。
///
/// ## 为什么"揭晓答案"是一个显式动作
///
/// 复习的价值来自**先自己回忆，再对答案**。如果题干和答案同时出现，
/// 用户会不自觉地把"看懂了"当成"会做了" —— 那是复习里最贵的错觉。
/// 所以这一页只有两步：看题 → 揭晓 → 打分。中间不能跳。
///
/// ## 为什么只有三档打分
///
/// FSRS 标准是四档（Again/Hard/Good/Easy）。但真实使用时用户分不清
/// Good 与 Easy，凭感觉给的 Easy 会把间隔拉得过长，反而让调度变差。
/// 三档（忘了 / 吃力 / 轻松）每一档都有明确的行为含义：
///
/// | 打分 | 用户的意思 | 算法里的动作 |
/// |---|---|---|
/// | 忘了 | 完全没思路 / 做错了 | `Rating.forgot`，重新学习 |
/// | 吃力 | 做出来了，但卡了很久 | `Rating.hard`，间隔缩水 |
/// | 轻松 | 顺畅做出来 | `Rating.easy`，间隔奖励 |
///
/// ## 键盘优先（PC 端）
///
/// 桌面端复习时手在键盘上，不该为了打分去摸鼠标：
/// `空格` 揭晓，`1` `2` `3` 对应三档打分。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/breakpoints.dart';
import '../../core/math/math_renderer.dart';
import '../../core/platform/capabilities.dart';
import '../../core/platform/platform_services.dart';
import '../../core/providers.dart';
import '../../core/theme/app_fonts.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/page_header.dart';
import '../../data/error_causes.dart';
import '../../data/markdown/problem_markdown.dart';
import '../../domain/fsrs/fsrs_scheduler.dart';
import '../../domain/knowledge/knowledge_point.dart';
import '../../services/llm/llm_client.dart';
import '../../services/review/handwrite_check.dart';
import '../../services/review/review_repository.dart';
import '../problems/problem_images.dart';
import 'error_prescription_panel.dart';

/// 本次会话的一条评分流水（会话报告用）。
///
/// 刻意只存**原始数据**（id / 评级 / 考点 id / 错因 JSON 串）：
/// 名称翻译要查本体与词表，而评分热路径上不该做这件事；
/// 报告视图本来就 watch 着它们，翻译放那里。
class SessionGradeEntry {
  final String problemId;

  /// 题干预览（报告里让人认出这道题；读取失败时为 null）。
  final String? stemPreview;
  final String? primaryKpId;

  /// `user_problem_state.errorCauses` 的原始 JSON 串，报告视图再解。
  final String causeIdsRaw;
  final Rating rating;

  const SessionGradeEntry({
    required this.problemId,
    required this.causeIdsRaw,
    required this.rating,
    this.stemPreview,
    this.primaryKpId,
  });
}

String _previewOf(String stem) {
  final t = stem.trim();
  if (t.isEmpty) return '（无题干）';
  return t.length > 60 ? '${t.substring(0, 60)}…' : t;
}

class ReviewPage extends ConsumerStatefulWidget {
  const ReviewPage({super.key});

  @override
  ConsumerState<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends ConsumerState<ReviewPage> {
  /// 本次会话的队列（快照）。抽完为止，不边抽边取 ——
  /// 否则评完一张卡它立刻又被拉回来（间隔算法可能仍判为到期），
  /// 用户会觉得"怎么老是这一题"。
  List<DueCard>? _queue;

  int _index = 0;
  bool _revealed = false;
  Object? _error;

  /// 累计已评分数（本次会话）。
  int _graded = 0;

  /// 是否正在写入一次评分。
  ///
  /// ## 为什么必须有这道闸
  ///
  /// 评分要等一次 sqlite 写入（还要写 review_logs）。在 await 期间
  /// [_revealed] 仍然是 true，于是"可以评分"这个前置条件对**同一张卡**
  /// 依然成立 —— 而 `CallbackShortcuts` 对长按产生的 `KeyRepeatEvent`
  /// 同样会触发回调。所以手指在 1/2/3 上多停一会儿就会对同一张卡并发评分：
  ///
  /// - 同一次复习写出多条 `review_logs`
  /// - `wrong_count` 被重复累加（用户看到"错了 5 次"但只错了一次）
  /// - 每次调用都会 `_index++`，把后面的卡**直接跳过** ——
  ///   那张卡的 FSRS 状态永远不会被写入，等于凭空消失
  ///
  /// 因为 `user_problem_state` 有主键，重复写不会崩、也不会多出卡片行，
  /// 所以手工点是测不出来的：症状只是调度慢慢变得不对。
  bool _grading = false;

  /// 本题开始计时，用于 `review_logs.elapsed_ms`。
  DateTime _shownAt = DateTime.now();

  /// 今日提醒文案。非 null 时在页面顶部显示一条可关闭的横幅。
  String? _reminder;

  /// 本次会话的评分流水（3.3 会话报告的数据源）。
  /// 只记 id / 评级 / 考点 id / 错因 id 原始串 —— 名称翻译交给报告视图
  /// （它本来就在 watch 本体与词表，不该在评分热路径上做）。
  final List<SessionGradeEntry> _sessionLog = [];

  @override
  void initState() {
    super.initState();
    _load();
    _checkReminder();
  }

  /// 每日提醒检查。
  ///
  /// 只判断、不打扰：到点且有到期卡片时给一条**可关闭的横幅**，
  /// 而不是弹窗。用户点掉即记为"今天提醒过了"，写进 `meta_entries`。
  Future<void> _checkReminder() async {
    try {
      final stats = await ref.read(reviewStatsProvider.future);
      if (stats.dueNow <= 0) return;
      final svc = await ref.read(reminderServiceProvider.future);
      await svc.load();
      final d = await svc.decide(dueCount: stats.dueNow);
      if (!mounted || !d.notify) return;
      setState(() => _reminder =
          '${d.at} 的复习提醒 · 还有 ${d.dueCount} 张卡等着（提醒只在应用运行时出现）');
      await svc.markNotified();
    } catch (_) {
      // 提醒失败绝不该影响复习页本身
    }
  }

  Future<void> _load() async {
    setState(() {
      _queue = null;
      _error = null;
    });
    try {
      final repo = await ref.read(reviewRepositoryProvider.future);
      await repo.ensureCards();
      final settings = await ref.watch(reviewSettingsProvider.future);
      final q = await repo.dueQueue(limit: settings.dailyLimit);
      if (!mounted) return;
      setState(() {
        _queue = q;
        _index = 0;
        _revealed = false;
        _shownAt = DateTime.now();
        _sessionLog.clear();
      });
      ref.invalidate(reviewStatsProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  DueCard? get _current {
    final q = _queue;
    if (q == null || _index >= q.length) return null;
    return q[_index];
  }

  void _reveal() {
    if (_revealed) return;
    setState(() => _revealed = true);
  }

  Future<void> _grade(Rating rating) async {
    final card = _current;
    if (card == null || !_revealed || _grading) return;
    _grading = true;
    try {
      final elapsed = DateTime.now().difference(_shownAt).inMilliseconds;
      final repo = await ref.read(reviewRepositoryProvider.future);
      final GradeResult result;
      try {
        result = await repo.grade(
          problemId: card.problemId,
          rating: rating,
          elapsedMs: elapsed,
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('评分写入失败：$e')),
        );
        return;
      }
      if (!mounted) return;

      _sessionLog.add(SessionGradeEntry(
        problemId: card.problemId,
        stemPreview: card.problem == null
            ? null
            : _previewOf(card.problem!.stem),
        primaryKpId: card.problem?.primaryKnowledge?.id,
        causeIdsRaw: card.state.errorCauses,
        rating: rating,
      ));

      final next = describeDue(result.nextDue);
      setState(() {
        _index++;
        _revealed = false;
        _graded++;
        _shownAt = DateTime.now();
      });
      ref.invalidate(reviewStatsProvider);

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 1400),
            content: Text(
              rating == Rating.forgot
                  ? '记下了 —— $next 再见'
                  : '${rating.label} · 下次 $next',
            ),
          ),
        );
    } finally {
      _grading = false;
    }
  }

  /// 跳过：不改 FSRS 状态，本题留在队列里下次还会出现。
  void _skip() {
    // 评分写入期间不允许跳过：否则 _index 会被推进两次，中间那张卡被吞掉
    if (_grading) return;
    setState(() {
      _index++;
      _revealed = false;
      _shownAt = DateTime.now();
    });
  }

  @override
  Widget build(BuildContext context) {
    final banner = _reminderBanner(context);
    final body = _buildBody(context);
    const header = PageHeader(
      title: '复习',
      subtitle: '图片题面 · 双栏解析 · 手写核对——三档打分后进入下一步间隔',
    );
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 14, 24, 0),
          child: header,
        ),
        if (banner != null) banner,
        Expanded(child: body),
      ],
    );
  }

  /// 今日提醒横幅。可关闭，关掉不再出现（当天）。
  Widget? _reminderBanner(BuildContext context) {
    final text = _reminder;
    if (text == null) return null;
    return Material(
      color: AppColors.warningWeak,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            const Icon(Icons.notifications_active_outlined,
                size: 17, color: AppColors.warningInk),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                    fontSize: 12, height: 1.5, color: AppColors.warningInk),
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _reminder = null),
              child: const Text('知道了', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_error != null) {
      return _ErrorView(error: _error!, onRetry: _load);
    }
    if (_queue == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_queue!.isEmpty) {
      return _AllDoneView(onRefresh: _load);
    }

    final card = _current;
    if (card == null) {
      return _SessionDoneView(graded: _graded, log: _sessionLog, onAgain: _load);
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): _reveal,
        const SingleActivator(LogicalKeyboardKey.digit1): () => _grade(Rating.forgot),
        const SingleActivator(LogicalKeyboardKey.digit2): () => _grade(Rating.hard),
        const SingleActivator(LogicalKeyboardKey.digit3): () => _grade(Rating.easy),
      },
      child: Focus(
        autofocus: true,
        child: _Session(
          card: card,
          grading: _grading,
          position: _index + 1,
          total: _queue!.length,
          revealed: _revealed,
          onReveal: _reveal,
          onGrade: _grade,
          onSkip: _skip,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 复习会话
// ─────────────────────────────────────────────────────────────────────────────

class _Session extends ConsumerWidget {
  final DueCard card;
  final int position;
  final int total;
  final bool revealed;

  /// 正在写入评分（M4）：写库期间三个评分按钮必须变灰 ——
  /// 闸门本来就拦得住连点，但拦不住"用户以为没点上"的第二次点击预期。
  final bool grading;
  final VoidCallback onReveal;
  final void Function(Rating) onGrade;
  final VoidCallback onSkip;

  const _Session({
    required this.card,
    required this.position,
    required this.total,
    required this.revealed,
    required this.grading,
    required this.onReveal,
    required this.onGrade,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bp = BreakpointScope.of(context);
    final compact = bp == LayoutBreakpoint.compact;

    // 主考点显示名字而不是裸 id —— 复习时不该让人去查 id 对应什么
    final kb = ref.watch(knowledgeBaseProvider).valueOrNull;
    final kpId = card.problem?.primaryKnowledge?.id;
    final kpName = kpId == null ? null : (kb?.byId[kpId]?.name ?? kpId);

    // 错因处方。词表**还没加载完时什么都不显示**，而不是显示"未知错因" ——
    // 把"正在加载"渲染成"数据有问题"是本项目已经修过三次的那类错误。
    final catalog = ref.watch(errorCauseCatalogProvider).valueOrNull;
    final causeIds =
        catalog?.idsOfJson(card.state.errorCauses) ?? const <String>[];
    final errorCauses = catalog?.resolve(causeIds) ?? const <ErrorCause>[];
    final unknownCauseIds =
        catalog == null ? const <String>[] : catalog.unknownIdsOf(causeIds);

    return Column(
      children: [
        _Progress(position: position, total: total, card: card),
        const Divider(height: 1),
        Expanded(
          child: Scrollbar(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                compact ? 16 : 28,
                18,
                compact ? 16 : 28,
                24,
              ),
              child: Center(
                child: ConstrainedBox(
                  // 限宽上限提到 1180：宽窗口下卡片内部做「左题右析」双栏，
                    // 窄窗口回到单列 760（见 _CardBody 的 LayoutBuilder）。
                    constraints: const BoxConstraints(maxWidth: 1180),
                  child: _CardBody(
                    card: card,
                    revealed: revealed,
                    kpName: kpName,
                    errorCauses: errorCauses,
                    unknownCauseIds: unknownCauseIds,
                  ),
                ),
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        _Actions(
          revealed: revealed,
          compact: compact,
          grading: grading,
          onReveal: onReveal,
          onGrade: onGrade,
          onSkip: onSkip,
        ),
      ],
    );
  }
}

/// 顶部进度：第几张 / 共几张 + 这道题的状态。
class _Progress extends StatelessWidget {
  final int position;
  final int total;
  final DueCard card;

  const _Progress({
    required this.position,
    required this.total,
    required this.card,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final overdue = card.overdueDays(DateTime.now());

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: total == 0 ? 0 : (position - 1) / total,
                minHeight: 5,
                backgroundColor: AppColors.surface2,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '$position / $total',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          if (card.isNew) ...[
            const SizedBox(width: 8),
            const _Chip(text: '新卡', color: AppColors.primary),
          ] else if (overdue > 0) ...[
            const SizedBox(width: 8),
            _Chip(text: '逾期 $overdue 天', color: AppColors.danger),
          ],
          if (card.state.wrongCount > 0) ...[
            const SizedBox(width: 6),
            _Chip(
              text: '错 ${card.state.wrongCount} 次',
              color: const Color(0xFFE03131),
            ),
          ],
          if (PlatformCapabilities.usesDesktopInteractions) ...[
            const SizedBox(width: 12),
            Text(
              '空格揭晓 · 1/2/3 打分',
              style: TextStyle(
                fontSize: 10.5,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 题面 + （揭晓后）答案与解析 + 错因处方。
class _CardBody extends ConsumerWidget {
  final DueCard card;
  final bool revealed;

  /// 主考点的展示名（本体未载入时退化为 id）。
  final String? kpName;

  /// 这道题标的错因，已解析（词表未载入时为空）。
  final List<ErrorCause> errorCauses;

  /// 题目里标了、但当前词表查不到的错因 id（如实列出，不吞掉）。
  final List<String> unknownCauseIds;

  const _CardBody({
    required this.card,
    required this.revealed,
    this.kpName,
    this.errorCauses = const [],
    this.unknownCauseIds = const [],
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final renderer = MathRendering.renderer;

    if (card.problem == null) {
      return _LoadFailedCard(card: card);
    }
    final p = card.problem!;

    // 关键词行（设想 #2）：题面下方只给"认出这道题"所需的最小信息 ——
    // 考点 + 错因 + 错次。完整处方在揭晓后的右栏里。
    final keywords = Wrap(
      spacing: 6,
      runSpacing: 5,
      children: [
        if (kpName case final name?) _Chip(text: name, color: AppColors.primary),
        for (final c in errorCauses) _Chip(text: c.name, color: AppColors.warningInk),
        for (final u in unknownCauseIds) _Chip(text: u, color: AppColors.ink3),
        if (card.state.wrongCount > 0)
          _Chip(text: '错 ${card.state.wrongCount} 次', color: AppColors.danger),
      ],
    );

    final stemSection = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              p.qtype.label,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: AppColors.primaryStrong,
              ),
            ),
            Text(
              p.id,
              style: TextStyle(
                fontSize: 10.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        // 图为主（扫描题）：复习时重做的就是图里的原题，配图直接当题面；
        // OCR 文本失真多，收进折叠区只作检索核对用。
        // 否则维持原样：文字题面为主，配图是示意图。
        if (p.imagesPrimary && p.images.isNotEmpty) ...[
          ProblemImageList(
            images: p.images,
            // 题库路径未就绪时传 null → 每张显示"缺失"占位，不吞也不炸。
            imagesDirPath:
                ref.watch(libraryPathsProvider).valueOrNull?.images.path,
            maxHeight: 420,
          ),
          if (p.stem.isNotEmpty) ...[
            OcrTextDisclosure(stem: p.stem, options: p.options),
          ],
        ] else ...[
          DefaultTextStyle.merge(
            style: const TextStyle(fontSize: 15, height: 1.85),
            child: renderer.renderMarkdown(p.stem),
          ),
          if (p.images.isNotEmpty) ...[
            const SizedBox(height: 12),
            ProblemImageList(
              images: p.images,
              imagesDirPath:
                  ref.watch(libraryPathsProvider).valueOrNull?.images.path,
            ),
          ],
          if (p.options.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (var i = 0; i < p.options.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: DefaultTextStyle.merge(
                  style: const TextStyle(fontSize: 14, height: 1.8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${String.fromCharCode(65 + i)}. ',
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      Expanded(
                        child: renderer.renderMarkdown(p.options[i]),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
        if (keywords.children.isNotEmpty) ...[
          const SizedBox(height: 14),
          keywords,
        ],
      ],
    );

    final analysisSection = !revealed
        ? const _HiddenAnswer()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (p.answer != null) ...[
                const _SectionLabel('答案'),
                DefaultTextStyle.merge(
                  style: const TextStyle(fontSize: 14.5, height: 1.85),
                  child: renderer.renderMarkdown(p.answer!),
                ),
                const SizedBox(height: 20),
              ],
              if (p.solution != null) ...[
                const _SectionLabel('解析'),
                DefaultTextStyle.merge(
                  style: const TextStyle(fontSize: 14, height: 1.9),
                  child: renderer.renderMarkdown(p.solution!),
                ),
              ],
              if (p.note != null && p.note!.isNotEmpty) ...[
                const SizedBox(height: 20),
                const _SectionLabel('我的笔记'),
                DefaultTextStyle.merge(
                  style: const TextStyle(fontSize: 13.5, height: 1.85),
                  child: renderer.renderMarkdown(p.note!),
                ),
              ],
              // 错因处方放在**最后**：先看完答案与解析，再谈"接下来该怎么补"。
              if (errorCauses.isNotEmpty || unknownCauseIds.isNotEmpty) ...[
                const SizedBox(height: 20),
                const _SectionLabel('错因处方'),
                ErrorPrescriptionPanel(
                  causes: errorCauses,
                  unknownIds: unknownCauseIds,
                ),
              ],
              // 手写核对（V2-3.2）：可选能力，设置里开了才出现 ——
              // 每次调用真实计费，不该让没打算用的用户看见入口。
              if (ref.watch(handwriteCheckEnabledProvider).valueOrNull ?? false)
                _HandwriteCheckPanel(problem: p),
            ],
          );

    // 左题右析（设想 #2）：≥1100px 双栏，题面常驻、解析揭晓后才出现在
    // 右栏 —— 评完一张题不用滚回去找题面。窄窗口退化为原来的单列。
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1100;
        if (!wide) {
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  stemSection,
                  const SizedBox(height: 22),
                  analysisSection,
                ],
              ),
            ),
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 5, child: stemSection),
            const SizedBox(width: 24),
            const VerticalDivider(width: 1, color: AppColors.line),
            const SizedBox(width: 24),
            Expanded(flex: 4, child: analysisSection),
          ],
        );
      },
    );
  }
}

/// 揭晓前的占位。刻意做得"有点碍事" —— 提醒用户先自己动笔。
class _HiddenAnswer extends StatelessWidget {
  const _HiddenAnswer();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 18),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppRadius.rMd,
        border: Border.all(color: AppColors.line),
      ),
      child: const Column(
        children: [
          Icon(Icons.visibility_off_outlined, size: 26, color: AppColors.ink4),
          SizedBox(height: 10),
          Text(
            '答案与解析已隐藏',
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 6),
          Text(
            '先在草稿纸上做一遍，再揭晓 —— 直接看答案会把'
            '「看懂了」误当成「会做了」。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, height: 1.7, color: AppColors.ink3),
          ),
        ],
      ),
    );
  }
}

/// Markdown 读不出来的卡片。仍然让用户能打分（否则这张卡会永远卡在队列里）。
class _LoadFailedCard extends StatelessWidget {
  final DueCard card;

  const _LoadFailedCard({required this.card});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF5F5),
        borderRadius: AppRadius.rMd,
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.error_outline, size: 20, color: AppColors.danger),
              SizedBox(width: 8),
              Text('这道题的 Markdown 读不出来',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            card.problemId,
            style: const TextStyle(
              fontFamily: AppFonts.mono,
              fontFamilyFallback: AppFonts.monoFallback,
              fontSize: 12,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '${card.loadError ?? "未知原因"}\n\n'
            '文件可能在题库目录外被改动或删除。保留这张卡是为了'
            '不丢复习进度 —— 你可以照常打分，或者去「错题本」里删掉这道题。',
            style: const TextStyle(fontSize: 12.5, height: 1.75),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 底部操作区
// ─────────────────────────────────────────────────────────────────────────────

class _Actions extends StatelessWidget {
  final bool revealed;
  final bool compact;

  /// 正在写库 —— 评分按钮变灰。写库期间 `_grade` 的闸门本来就拦得住，
  /// 但"按钮没反应"和"按钮变灰"是两种体验：前者让用户以为没点上。
  final bool grading;
  final VoidCallback onReveal;
  final void Function(Rating) onGrade;
  final VoidCallback onSkip;

  const _Actions({
    required this.revealed,
    required this.compact,
    required this.grading,
    required this.onReveal,
    required this.onGrade,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final content = revealed
        ? Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: [
              _GradeButton(
                label: '忘了',
                hint: '没思路',
                keyHint: '1',
                color: AppColors.danger,
                filled: true,
                disabled: grading,
                onTap: () => onGrade(Rating.forgot),
              ),
              _GradeButton(
                label: '吃力',
                hint: '做出来了但卡住',
                keyHint: '2',
                color: const Color(0xFFF08C00),
                disabled: grading,
                onTap: () => onGrade(Rating.hard),
              ),
              _GradeButton(
                label: '轻松',
                hint: '很顺',
                keyHint: '3',
                color: const Color(0xFF0CA678),
                disabled: grading,
                onTap: () => onGrade(Rating.easy),
              ),
            ],
          )
        : Wrap(
            spacing: 10,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: onReveal,
                icon: const Icon(Icons.visibility_outlined, size: 18),
                label: const Text('揭晓答案'),
              ),
              TextButton(
                onPressed: onSkip,
                child: const Text('跳过这题'),
              ),
            ],
          );

    return Container(
      padding: EdgeInsets.fromLTRB(16, compact ? 12 : 14, 16, compact ? 12 : 16),
      color: AppColors.surface,
      child: Column(
        children: [
          content,
          if (revealed) ...[
            const SizedBox(height: 8),
            Text(
              '打分决定下次什么时候再见到它 · 打分后自动跳到下一题',
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _GradeButton extends StatelessWidget {
  final String label;
  final String hint;
  final String keyHint;
  final Color color;
  final bool filled;

  /// 写库中禁用 —— 与键盘闸门（`_grading`）同一时刻，两条入口一致。
  final bool disabled;
  final VoidCallback onTap;

  const _GradeButton({
    required this.label,
    required this.hint,
    required this.keyHint,
    required this.color,
    required this.onTap,
    this.filled = false,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    final child = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: filled ? Colors.white : color,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: filled
                    ? Colors.white.withValues(alpha: 0.22)
                    : color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                keyHint,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: filled ? Colors.white : color,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          hint,
          style: TextStyle(
            fontSize: 10.5,
            color: filled
                ? Colors.white.withValues(alpha: 0.85)
                : AppColors.ink3,
          ),
        ),
      ],
    );

    final shape = RoundedRectangleBorder(
      borderRadius: AppRadius.rMd,
      side: BorderSide(color: color.withValues(alpha: filled ? 0 : 0.5)),
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 132),
      child: filled
          ? FilledButton(
              onPressed: disabled ? null : onTap,
              style: FilledButton.styleFrom(
                backgroundColor: color,
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                shape: shape,
              ),
              child: child,
            )
          : OutlinedButton(
              onPressed: disabled ? null : onTap,
              style: OutlinedButton.styleFrom(
                foregroundColor: color,
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                shape: shape,
              ),
              child: child,
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 空态与结算
// ─────────────────────────────────────────────────────────────────────────────

/// 队列为空：今天没有到期的卡。
class _AllDoneView extends ConsumerWidget {
  final VoidCallback onRefresh;

  const _AllDoneView({required this.onRefresh});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(reviewStatsProvider);
    final theme = Theme.of(context);

    return FutureBuilder<ReviewStats>(
      future: ref.read(reviewRepositoryProvider.future).then((r) => r.stats()),
      builder: (context, snap) {
        final s = snap.data ?? stats.valueOrNull;
        // 「一张卡都没有」和「今天做完了」是两件事，文案必须分开 ——
        // 对着一张空白卡片说"今天做完了"会让人以为复习功能坏了。
        final nothingYet = s?.isEmpty ?? false;
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    nothingYet
                        ? Icons.inbox_outlined
                        : Icons.check_circle_outline,
                    size: 48,
                    color: nothingYet
                        ? AppColors.ink4
                        : const Color(0xFF0CA678),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    nothingYet ? '错题本还是空的' : '今天的复习做完了',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _emptySubtitle(s, nothingYet),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.75,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (s != null && s.upcoming.isNotEmpty) ...[
                    const SizedBox(height: 26),
                    _Upcoming(upcoming: s.upcoming),
                  ],
                  const SizedBox(height: 26),
                  OutlinedButton.icon(
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh, size: 17),
                    label: const Text('重新检查'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 空态副标题。
  ///
  /// 「下次什么时候来」是这里最有价值的一句 —— 没有它，用户只知道
  /// "现在不用复习"，却不知道什么时候该回来。
  static String _emptySubtitle(ReviewStats? s, bool nothingYet) {
    if (s == null) return '正在读取复习进度…';
    if (nothingYet) {
      return '去「录入」页记下第一道错题，它就会进入复习队列。';
    }
    final parts = <String>[
      '共 ${s.totalCards} 张卡',
      '今天已复习 ${s.reviewedToday} 次',
      if (s.newCards > 0) '新卡 ${s.newCards} 张',
    ];
    final next = s.nextDue;
    parts.add(next == null ? '已无待安排的卡' : '下次 ${describeDue(next)}');
    return parts.join(' · ');
  }
}

/// 本次会话抽完（队列里还有，只是这一轮已评完）+ **会话报告**（3.3）。
///
/// 报告是**纯本地聚合**（评分流水在 `_sessionLog` 里现成），不读库、
/// 不调模型 —— 「AI 挂了产品不能挂」在报告这件事上的意思就是：
/// 它根本不需要 AI。可复制为 Markdown，贴进笔记或发给谁都行。
class _SessionDoneView extends ConsumerWidget {
  final int graded;
  final List<SessionGradeEntry> log;
  final VoidCallback onAgain;

  const _SessionDoneView({
    required this.graded,
    required this.log,
    required this.onAgain,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final kb = ref.watch(knowledgeBaseProvider).valueOrNull;
    final catalog = ref.watch(errorCauseCatalogProvider).valueOrNull;
    final forgot = log.where((e) => e.rating == Rating.forgot).length;
    final passed = log.length - forgot;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.emoji_events_outlined,
                  size: 46, color: AppColors.primary),
              const SizedBox(height: 14),
              Text('本轮复习完成 · $graded 张',
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                '还有没到期的卡。现在再抽一轮会看到同样几张 —— '
                '间隔是算法算出来的，不是越勤越好。',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.75,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (log.isNotEmpty) ...[
                const SizedBox(height: 22),
                Text(
                  '做出 $passed · 忘了 $forgot'
                  '${log.isEmpty ? "" : "（正确率 ${(passed * 100 / log.length).round()}%）"}',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700),
                ),
                ..._weakKpLines(kb),
                ..._causeLines(catalog),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(
                        text: sessionReportMarkdown(log, kb: kb, catalog: catalog)));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('报告已复制为 Markdown')),
                    );
                  },
                  icon: const Icon(Icons.copy_outlined, size: 16),
                  label: const Text('复制 Markdown 报告'),
                ),
              ],
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: onAgain,
                icon: const Icon(Icons.replay, size: 17),
                label: const Text('再来一轮'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 最弱考点行（忘了 ≥1 次的考点，按次数降序，最多 3 行）。
  List<Widget> _weakKpLines(KnowledgeBase? kb) {
    final counts = <String, int>{};
    for (final e in log) {
      if (e.rating != Rating.forgot) continue;
      final kp = e.primaryKpId;
      if (kp == null) continue;
      counts[kp] = (counts[kp] ?? 0) + 1;
    }
    if (counts.isEmpty) return const [];
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      const SizedBox(height: 14),
      const Text('这次忘了最多：',
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
      for (final e in sorted.take(3))
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            '· ${kb?.byId[e.key]?.name ?? e.key}（忘了 ${e.value} 次）',
            style: const TextStyle(fontSize: 12.5, height: 1.6),
          ),
        ),
    ];
  }

  /// 错因分布行（只统计这次会话里评过分的题）。
  List<Widget> _causeLines(ErrorCauseCatalog? catalog) {
    final counts = <String, int>{};
    for (final e in log) {
      for (final id in catalog?.idsOfJson(e.causeIdsRaw) ?? const <String>[]) {
        counts[id] = (counts[id] ?? 0) + 1;
      }
    }
    if (counts.isEmpty) return const [];
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      const SizedBox(height: 10),
      for (final e in sorted.take(3))
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            '· ${catalog?.nameOf(e.key) ?? e.key} × ${e.value}',
            style: const TextStyle(fontSize: 12.5, height: 1.6),
          ),
        ),
    ];
  }
}

/// 错因 JSON 串 → id 列表。坏数据当没标，报告不崩
/// （与 `ErrorCauseCatalog.idsOfJson` 同一容错策略；解耦出来是因为
/// 词表没载入时分布不该整个消失 —— 翻译可以缺，计数不能缺）。
List<String> _decodeCauseIds(String raw) {
  if (raw.trim().isEmpty) return const [];
  try {
    final v = jsonDecode(raw);
    if (v is List) {
      return v.map((e) => e?.toString() ?? '').where((e) => e.isNotEmpty).toList();
    }
  } catch (_) {
    // 索引里的 JSON 坏了不该让报告挂掉
  }
  return const [];
}

/// 会话报告的 Markdown 文本（纯函数，可测）。
String sessionReportMarkdown(
  List<SessionGradeEntry> log, {
  KnowledgeBase? kb,
  ErrorCauseCatalog? catalog,
  DateTime? now,
}) {
  if (log.isEmpty) return '本轮没有评分记录。';
  final forgot = log.where((e) => e.rating == Rating.forgot).length;
  final passed = log.length - forgot;
  final d = now ?? DateTime.now();
  final b = StringBuffer();
  final ymd = '${d.year}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  b.writeln('# 复习报告 · $ymd');
  b.writeln();
  b.writeln('- 共 ${log.length} 张：做出 $passed · 忘了 $forgot'
      '（正确率 ${(passed * 100 / log.length).round()}%）');
  b.writeln();
  b.writeln('## 明细');
  for (final e in log) {
    final kpName = e.primaryKpId == null
        ? ''
        : '${kb?.byId[e.primaryKpId]?.name ?? e.primaryKpId!} · ';
    b.writeln('- ${e.rating.label} · $kpName${e.stemPreview ?? e.problemId}');
  }
  final causeCounts = <String, int>{};
  for (final e in log) {
    for (final id in _decodeCauseIds(e.causeIdsRaw)) {
      causeCounts[id] = (causeCounts[id] ?? 0) + 1;
    }
  }
  if (causeCounts.isNotEmpty) {
    b.writeln();
    b.writeln('## 错因分布');
    final sorted = causeCounts.entries.toList()
      ..sort((a, z) => z.value.compareTo(a.value));
    for (final e in sorted) {
      b.writeln('- ${catalog?.nameOf(e.key) ?? e.key} × ${e.value}');
    }
  }
  final kpCounts = <String, int>{};
  for (final e in log) {
    if (e.rating != Rating.forgot) continue;
    final kp = e.primaryKpId;
    if (kp == null) continue;
    kpCounts[kp] = (kpCounts[kp] ?? 0) + 1;
  }
  if (kpCounts.isNotEmpty) {
    b.writeln();
    b.writeln('## 最需要回头看的考点（按忘了的次数）');
    final sorted = kpCounts.entries.toList()
      ..sort((a, z) => z.value.compareTo(a.value));
    for (final e in sorted.take(3)) {
      b.writeln('- ${kb?.byId[e.key]?.name ?? e.key} × ${e.value}');
    }
  }
  return b.toString();
}

/// 未来 7 天到期分布。
class _Upcoming extends StatelessWidget {
  final List<int> upcoming;

  const _Upcoming({required this.upcoming});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final max = upcoming.fold<int>(1, (a, b) => b > a ? b : a);
    const labels = ['今天', '明天', '2天', '3天', '4天', '5天', '6天'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '未来 7 天',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 96,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < upcoming.length; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text('${upcoming[i]}',
                            style: const TextStyle(
                                fontSize: 10.5, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 3),
                        Container(
                          height: 4 + 52 * (upcoming[i] / max),
                          decoration: BoxDecoration(
                            color: i == 0
                                ? AppColors.primary
                                : AppColors.primary.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(labels[i],
                            style: TextStyle(
                                fontSize: 9.5,
                                color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 44, color: AppColors.danger),
              const SizedBox(height: 16),
              const Text('复习队列载入失败',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              SelectableText(
                '$error',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 小组件
// ─────────────────────────────────────────────────────────────────────────────

class _Chip extends StatelessWidget {
  final String text;
  final Color color;

  const _Chip({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(
            fontSize: 10.5, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Container(width: 3, height: 13, color: AppColors.primary),
            const SizedBox(width: 7),
            Text(text,
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w700)),
          ],
        ),
      );
}


/// 手写答案拍照核对（V2-3.2）。
///
/// ## 交互契约
///
/// 拍照/选图 → 视觉模型对照标准解析 → **要点命中清单**（✓/✗ + 一句话
/// 依据）→ 用户自己打分。清单上没有分数，将来也不会有 —— 那条边界
/// 写在提示词与解析层（见 `handwrite_check.dart`）。
///
/// ## 失败路径
///
/// 无 Key / 无视觉能力 / 网络失败 / 解析失败 → 红字如实显示，
/// 手动三档打分**始终可用** —— 这是增强，不是依赖。
class _HandwriteCheckPanel extends ConsumerStatefulWidget {
  final Problem problem;

  const _HandwriteCheckPanel({required this.problem});

  @override
  ConsumerState<_HandwriteCheckPanel> createState() =>
      _HandwriteCheckPanelState();
}

class _HandwriteCheckPanelState extends ConsumerState<_HandwriteCheckPanel> {
  bool _running = false;
  HandwriteCheckResult? _result;
  String? _error;

  Future<void> _check() async {
    if (_running) return;
    final client = ref.read(ingestClientProvider);
    if (client == null) {
      setState(() => _error = '还没有配置 AI 服务商 —— 到「设置 → AI 服务商」填 Key。');
      return;
    }

    setState(() {
      _running = true;
      _error = null;
      _result = null;
    });
    try {
      final picked =
          await PlatformServices.instance.imageSource.pickMultipleImages();
      if (!mounted) return;
      if (picked.isEmpty) {
        setState(() => _running = false);
        return;
      }
      final f = picked.first;
      final bytes = f.bytes ?? await File(f.path).readAsBytes();
      final p = widget.problem;

      final r = await checkHandwrittenAnswer(
        client: client,
        attachment: ChatAttachment(
          kind: ChatAttachmentKind.image,
          mimeType: 'image/png',
          bytes: bytes,
          name: f.name,
        ),
        answer: p.answer,
        solution: p.solution,
      );
      if (!mounted) return;
      setState(() {
        _running = false;
        _result = r;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Row(
          children: [
            const _SectionLabel('手写核对'),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: _running ? null : _check,
              icon: _running
                  ? const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.draw_outlined, size: 15),
              label: Text(_running ? '核对中…' : '拍照核对',
                  style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SelectableText(
              '核对失败：$_error\n（不影响手动打分）',
              style: TextStyle(
                  fontSize: 11.5,
                  height: 1.6,
                  color: theme.colorScheme.error),
            ),
          ),
        if (_result != null) ...[
          const SizedBox(height: 8),
          for (final pt in _result!.points)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    pt.hit ? Icons.check_circle_outline : Icons.cancel_outlined,
                    size: 14,
                    color: pt.hit ? AppColors.success : AppColors.danger,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      pt.hit ? '${pt.name} —— ${pt.note}' : '${pt.name}：${pt.note}',
                      style: const TextStyle(fontSize: 12, height: 1.6),
                    ),
                  ),
                ],
              ),
            ),
          if (_result!.points.isEmpty)
            Text('模型没有给出可辨认的要点。', style: _secondaryText()),
        ],
      ],
    );
  }

  TextStyle _secondaryText() => TextStyle(
      fontSize: 11.5, color: Theme.of(context).colorScheme.onSurfaceVariant);
}
