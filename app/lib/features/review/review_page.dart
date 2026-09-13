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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/breakpoints.dart';
import '../../core/math/math_renderer.dart';
import '../../core/platform/capabilities.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/fsrs/fsrs_scheduler.dart';
import '../../services/review/review_repository.dart';

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

  /// 本题开始计时，用于 `review_logs.elapsed_ms`。
  DateTime _shownAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _queue = null;
      _error = null;
    });
    try {
      final repo = await ref.read(reviewRepositoryProvider.future);
      await repo.ensureCards();
      final q = await repo.dueQueue(limit: 30);
      if (!mounted) return;
      setState(() {
        _queue = q;
        _index = 0;
        _revealed = false;
        _shownAt = DateTime.now();
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
    if (card == null || !_revealed) return;

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
  }

  /// 跳过：不改 FSRS 状态，本题留在队列里下次还会出现。
  void _skip() {
    setState(() {
      _index++;
      _revealed = false;
      _shownAt = DateTime.now();
    });
  }

  @override
  Widget build(BuildContext context) {
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
      return _SessionDoneView(graded: _graded, onAgain: _load);
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
  final VoidCallback onReveal;
  final void Function(Rating) onGrade;
  final VoidCallback onSkip;

  const _Session({
    required this.card,
    required this.position,
    required this.total,
    required this.revealed,
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
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: _CardBody(card: card, revealed: revealed, kpName: kpName),
                ),
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        _Actions(
          revealed: revealed,
          compact: compact,
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

/// 题面 + （揭晓后）答案与解析。
class _CardBody extends StatelessWidget {
  final DueCard card;
  final bool revealed;

  /// 主考点的展示名（本体未载入时退化为 id）。
  final String? kpName;

  const _CardBody({
    required this.card,
    required this.revealed,
    this.kpName,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final renderer = MathRendering.renderer;

    if (card.problem == null) {
      return _LoadFailedCard(card: card);
    }
    final p = card.problem!;

    return Column(
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
            if (kpName case final name?)
              Text(
                name,
                style: TextStyle(
                  fontSize: 11.5,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            Text(
              p.id,
              style: TextStyle(
                fontSize: 10.5,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        DefaultTextStyle.merge(
          style: const TextStyle(fontSize: 15, height: 1.85),
          child: renderer.renderMarkdown(p.stem),
        ),
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
        const SizedBox(height: 22),
        if (!revealed)
          _HiddenAnswer()
        else ...[
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
        ],
      ],
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
                fontSize: 12, fontFamily: 'monospace', height: 1.6),
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
  final VoidCallback onReveal;
  final void Function(Rating) onGrade;
  final VoidCallback onSkip;

  const _Actions({
    required this.revealed,
    required this.compact,
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
                onTap: () => onGrade(Rating.forgot),
              ),
              _GradeButton(
                label: '吃力',
                hint: '做出来了但卡住',
                keyHint: '2',
                color: const Color(0xFFF08C00),
                onTap: () => onGrade(Rating.hard),
              ),
              _GradeButton(
                label: '轻松',
                hint: '很顺',
                keyHint: '3',
                color: const Color(0xFF0CA678),
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
  final VoidCallback onTap;

  const _GradeButton({
    required this.label,
    required this.hint,
    required this.keyHint,
    required this.color,
    required this.onTap,
    this.filled = false,
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
              onPressed: onTap,
              style: FilledButton.styleFrom(
                backgroundColor: color,
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                shape: shape,
              ),
              child: child,
            )
          : OutlinedButton(
              onPressed: onTap,
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
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check_circle_outline,
                      size: 48, color: Color(0xFF0CA678)),
                  const SizedBox(height: 14),
                  const Text('今天的复习做完了',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text(
                    s == null
                        ? '错题本里还没有卡片。去「录入」页记下第一道错题，'
                            '它就会进入复习队列。'
                        : '共 ${s.totalCards} 张卡 · 今天已复习 ${s.reviewedToday} 次 · '
                            '新卡 ${s.newCards} 张',
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
}

/// 本次会话抽完（队列里还有，只是这一轮已评完）。
class _SessionDoneView extends StatelessWidget {
  final int graded;
  final VoidCallback onAgain;

  const _SessionDoneView({required this.graded, required this.onAgain});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.75,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: onAgain,
              icon: const Icon(Icons.replay, size: 17),
              label: const Text('再来一轮'),
            ),
          ],
        ),
      ),
    );
  }
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
