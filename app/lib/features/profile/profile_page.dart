/// 掌握度画像页（F7）。
///
/// ## 这一页要回答的问题
///
/// 错题本告诉你"我错过哪些题"，复习页告诉你"今天该复习什么"，
/// 但都不回答**"我最该补哪里"**。
///
/// ## 三条刻意的设计
///
/// ### 1. 排序理由必须是可核对的
///
/// 薄弱点排序用的是 `MasteryService` 里那个启发式公式
/// （掌握度低是主因，错得多加分）。用户看到榜单时应该能自己判断
/// "它为什么排第一" —— 所以每一行都把**掌握度**与**错次数**
/// 这两个组成项摆出来，而不是只给一个名次。
/// 排序不合心意时，他能看出是哪个数导致的。
///
/// ### 2. "掌握 X%" 是**此刻**的值，不是打分那一刻的快照
///
/// 见 `MasteryService` 顶部关于 T37 的说明。这也是为什么这一页
/// 每次打开都重算 —— 缓存一份报告等于把那个问题换个地方重演。
///
/// ### 3. 有多少数据说多少话
///
/// `reviewedCount / problemCount` 一起显示：一个"掌握 30%"如果只由
/// 1 道题算出来，和一个由 12 道题算出来的，可信度完全不同。
/// 只给百分比就是在暗示一个它没有的精度。
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/breakpoints.dart';
import '../../core/providers.dart';
import '../../core/widgets/state_views.dart';
import '../../services/profile/mastery_service.dart';

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(masteryReportProvider);
    final compact = BreakpointScope.of(context) == LayoutBreakpoint.compact;

    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => AppErrorView(
        title: '画像算不出来',
        error: e,
        hint: '画像要读整个题库与全部复习状态。'
            '若刚手工改动过 problems/ 目录，可以到「设置」里重建索引。',
        onRetry: () => ref.invalidate(masteryReportProvider),
      ),
      data: (report) => report.isEmpty
          ? const AppEmptyView(
              icon: Icons.insights_outlined,
              title: '还没有题目，画像无从谈起',
              hint: '先去「录入」或「批量导入」把题录进来，\n'
                  '再复习几轮，这里就会显示你最该补的考点。',
            )
          : _Body(report: report, compact: compact),
    );
  }
}

class _Body extends ConsumerWidget {
  final MasteryReport report;
  final bool compact;

  const _Body({required this.report, required this.compact});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // 宽屏两列：左侧"该补什么"，右侧"数据长什么样"。窄屏一列。
    final wide = !compact;

    final left = <Widget>[
      _Overview(report: report),
      const SizedBox(height: 14),
      _Section(
        title: '最薄弱的考点',
        subtitle: report.hasReviewData
            ? '按"掌握度低 × 错得多"排序。每行都给出这两个数，方便你判断它排得对不对。'
            : '还没有复习记录 —— 复习几轮之后这里才有意义。',
        child: _WeakestList(items: report.weakest),
      ),
      const SizedBox(height: 14),
      _Section(
        title: '各章节掌握情况',
        subtitle: '把考点上的数据上卷到章节。没有复习记录的章节也在列，'
            '方便看出"哪一章还没碰"。',
        child: _ChapterList(items: report.chapters),
      ),
    ];

    final right = <Widget>[
      _Section(
        title: '最近 30 天复习曲线',
        subtitle: '每天复习了几题、其中多少做出来了。'
            '没复习的日子是断点 —— 那正好能看出停过多久。',
        child: _TrendChart(points: report.trend),
      ),
      const SizedBox(height: 14),
      _Section(
        title: '错因分布',
        subtitle: '按录入时勾选的易错点统计（或 AI 预判的）。',
        child: _CauseList(
          causes: report.causes,
          missing: report.missingCauseData,
          onRebuild: () => ref.invalidate(masteryReportProvider),
        ),
      ),
    ];

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(masteryReportProvider),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
        children: wide
            ? [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Column(children: left)),
                    const SizedBox(width: 14),
                    Expanded(child: Column(children: right)),
                  ],
                ),
                const SizedBox(height: 8),
                _Footnote(theme: theme),
              ]
            : [
                ...left,
                const SizedBox(height: 14),
                ...right,
                const SizedBox(height: 8),
                _Footnote(theme: theme),
              ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 总览
// ─────────────────────────────────────────────────────────────────────────────

class _Overview extends StatelessWidget {
  final MasteryReport report;

  const _Overview({required this.report});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('总览', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            Wrap(
              spacing: 22,
              runSpacing: 12,
              children: [
                _Stat(label: '题库', value: '${report.totalProblems} 题'),
                _Stat(
                  label: '有复习记录',
                  value: '${report.reviewedProblems} 题',
                ),
                _Stat(label: '从未复习', value: '${report.newProblems} 题'),
                _Stat(
                  label: '顽固错题',
                  value: '${report.stubbornProblems} 题',
                  hint: '错 ≥$kStubbornWrongThreshold 次',
                ),
                _Stat(
                  label: '平均掌握',
                  value: report.overallMastery == null
                      ? '—'
                      : '${(report.overallMastery! * 100).round()}%',
                  hint: report.reviewedProblems == 0
                      ? '还没有复习记录'
                      : '只统计有复习记录的题',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final String? hint;

  const _Stat({required this.label, required this.value, this.hint});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 11.5, color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        Text(value,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        if (hint != null)
          Text(hint!,
              style: TextStyle(
                  fontSize: 10.5, color: theme.colorScheme.outline)),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 通用区块
// ─────────────────────────────────────────────────────────────────────────────

class _Section extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;

  const _Section({required this.title, this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.6,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// 掌握度条。颜色按严重程度分档 —— 与 mockup 里"红 / 橙 / 绿"一致。
class _MasteryBar extends StatelessWidget {
  final double? mastery;

  const _MasteryBar(this.mastery);

  static const Color _danger = Color(0xFFE03131);
  static const Color _warn = Color(0xFFF08C00);
  static const Color _ok = Color(0xFF0CA678);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = mastery;
    if (m == null) {
      // 没有数据时**不画一条 0% 的条** —— 那看起来像"完全不会"，
      // 而真相是"还不知道"。用一条虚线底纹表达"空缺"。
      return Container(
        height: 6,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(3),
        ),
      );
    }
    final color = m < 0.35 ? _danger : (m < 0.6 ? _warn : _ok);
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: LinearProgressIndicator(
        value: m.clamp(0.0, 1.0),
        minHeight: 6,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        valueColor: AlwaysStoppedAnimation(color),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 薄弱考点
// ─────────────────────────────────────────────────────────────────────────────

class _WeakestList extends StatelessWidget {
  final List<KpMastery> items;

  const _WeakestList({required this.items});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (items.isEmpty) {
      return Text('这个科目下还没有标注过考点的题。',
          style: theme.textTheme.bodySmall);
    }

    return Column(
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 名次
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: i < 3
                        ? const Color(0xFFFFF0D6)
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: i < 3
                          ? const Color(0xFF8A5A00)
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        items[i].kpName,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      if (items[i].chapterName != null)
                        Text(
                          items[i].chapterName!,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      const SizedBox(height: 6),
                      _MasteryBar(items[i].mastery),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 84,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        items[i].masteryText,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        items[i].wrongCount > 0
                            ? '错 ${items[i].wrongCount} 次'
                            : '没错过',
                        style: TextStyle(
                          fontSize: 11,
                          color: items[i].wrongCount > 0
                              ? const Color(0xFFE03131)
                              : theme.colorScheme.outline,
                        ),
                      ),
                      // 样本量：平均是几道题平均出来的
                      Text(
                        '${items[i].reviewedCount}/${items[i].problemCount} 题有记录',
                        style: TextStyle(
                          fontSize: 10,
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 章节
// ─────────────────────────────────────────────────────────────────────────────

class _ChapterList extends StatelessWidget {
  final List<ChapterMastery> items;

  const _ChapterList({required this.items});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (items.isEmpty) {
      return Text('还没有可以聚合的章节。', style: theme.textTheme.bodySmall);
    }

    return Column(
      children: [
        for (final c in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(c.chapterName,
                          style: const TextStyle(fontSize: 12.5)),
                    ),
                    Text(
                      c.mastery == null
                          ? '未复习'
                          : '${(c.mastery! * 100).round()}%',
                      style: const TextStyle(
                          fontSize: 11.5, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                _MasteryBar(c.mastery),
                const SizedBox(height: 3),
                Text(
                  '${c.problemCount} 题 · 有记录 ${c.reviewedCount} 题'
                  '${c.wrongCount > 0 ? ' · 错 ${c.wrongCount} 次' : ''}',
                  style: TextStyle(
                      fontSize: 10.5, color: theme.colorScheme.outline),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 错因分布
// ─────────────────────────────────────────────────────────────────────────────

class _CauseList extends StatelessWidget {
  final List<CauseStat> causes;
  final int missing;
  final VoidCallback onRebuild;

  const _CauseList({
    required this.causes,
    required this.missing,
    required this.onRebuild,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = causes.fold<int>(0, (n, c) => n + c.problemCount);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ⚠️ 数据不完整必须说出来。
        // schema v4 才加的错因列，旧题一直是空的 ——
        // 一份"只统计了迁移之后新录的题"的分布看起来有数据，实际是错的。
        // 空着比错了强，所以这里明确提示去重建索引。
        if (missing > 0)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF6E5),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline,
                    size: 15, color: Color(0xFF8A5A00)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '有 $missing 道题没有错因数据（本次统计只覆盖了其余部分）。'
                    '这是升级到新版后旧索引的正常状态 —— '
                    '到「设置」里重建一次索引就会补全。',
                    style: const TextStyle(
                        fontSize: 11.5, height: 1.6, color: Color(0xFF8A5A00)),
                  ),
                ),
                TextButton(
                  onPressed: onRebuild,
                  child: const Text('刷新', style: TextStyle(fontSize: 11.5)),
                ),
              ],
            ),
          ),
        if (causes.isEmpty)
          Text('还没有带错因的题。录入时勾一下错因，这里就能看出你的高频失分原因。',
              style: theme.textTheme.bodySmall)
        else
          for (final c in causes)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(c.causeName,
                            style: const TextStyle(fontSize: 12.5)),
                      ),
                      Text('${c.problemCount} 题',
                          style: const TextStyle(
                              fontSize: 11.5, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: total == 0 ? 0 : c.problemCount / total,
                      minHeight: 6,
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                      valueColor: const AlwaysStoppedAnimation(
                          Color(0xFF7048E8)),
                    ),
                  ),
                  if (c.wrongCount > 0) ...[
                    const SizedBox(height: 3),
                    Text('累计错 ${c.wrongCount} 次',
                        style: TextStyle(
                            fontSize: 10.5,
                            color: theme.colorScheme.outline)),
                  ],
                ],
              ),
            ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 复习曲线
// ─────────────────────────────────────────────────────────────────────────────

/// 最近 30 天的复习量。
///
/// 用 `fl_chart`（项目本来就为画像引了这个依赖）。这里刻意只画**一条线** ——
/// 复习次数。想同时画"过关率"需要第二根 Y 轴，而两条量纲不同的线画在一起
/// 只会让人读错；过关率更适合在下面的文字摘要里给。
class _TrendChart extends StatelessWidget {
  final List<TrendPoint> points;

  const _TrendChart({required this.points});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxReviews =
        points.fold<int>(0, (n, p) => p.reviews > n ? p.reviews : n);
    final active = points.where((p) => p.reviews > 0).toList();

    if (active.isEmpty) {
      return Text(
        '最近 $kTrendDays 天没有复习记录。',
        style: theme.textTheme.bodySmall,
      );
    }

    final totalReviews = points.fold<int>(0, (n, p) => n + p.reviews);
    final totalPassed = points.fold<int>(0, (n, p) => n + p.passed);
    final rate = totalReviews == 0 ? 0.0 : totalPassed / totalReviews;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 140,
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: (points.length - 1).toDouble(),
              minY: 0,
              // 上留一点余量，不然最高的点会贴住边框
              maxY: (maxReviews == 0 ? 1 : maxReviews * 1.2).toDouble(),
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: (maxReviews <= 4 ? 1 : maxReviews / 4)
                    .clamp(1, double.infinity)
                    .toDouble(),
                getDrawingHorizontalLine: (_) => FlLine(
                  color: theme.colorScheme.outlineVariant,
                  strokeWidth: 0.6,
                ),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 26,
                    interval: (maxReviews <= 4 ? 1 : maxReviews / 4)
                        .clamp(1, double.infinity)
                        .toDouble(),
                    getTitlesWidget: (v, meta) => Text(
                      v.toInt().toString(),
                      style: TextStyle(
                          fontSize: 9.5, color: theme.colorScheme.outline),
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 20,
                    // 只在第 1 天、最后一天、中间给三个刻度 ——
                    // 30 个刻度挤在一起谁也读不出来
                    interval: ((points.length - 1) / 2).toDouble(),
                    getTitlesWidget: (v, meta) {
                      final i = v.round();
                      if (i < 0 || i >= points.length) {
                        return const SizedBox.shrink();
                      }
                      final d = points[i].day;
                      return Text(
                        '${d.month}/${d.day}',
                        style: TextStyle(
                            fontSize: 9.5, color: theme.colorScheme.outline),
                      );
                    },
                  ),
                ),
              ),
              lineTouchData: const LineTouchData(enabled: false),
              lineBarsData: [
                LineChartBarData(
                  spots: [
                    for (var i = 0; i < points.length; i++)
                      FlSpot(i.toDouble(), points[i].reviews.toDouble()),
                  ],
                  isCurved: false,
                  color: theme.colorScheme.primary,
                  barWidth: 2,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(
                    show: true,
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '这 $kTrendDays 天共复习 $totalReviews 次，'
          '做出来 $totalPassed 次（${(rate * 100).round()}%）。',
          style: TextStyle(
            fontSize: 11.5,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

/// 页脚说明。**必须写**：这一页的排序是启发式，不是真理。
class _Footnote extends StatelessWidget {
  final ThemeData theme;

  const _Footnote({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Text(
      '"最薄弱"用的是启发式排序（掌握度低是主因，错得多加分，'
      '错次取对数以免长尾压倒一切）。它不代表唯一正确的顺序 —— '
      '每行都给出了掌握度与错次数，你可以按自己的判断去补。\n'
      '掌握度是**此刻**按遗忘曲线重算的，不是复习那一刻的记录 —— '
      '所以放久了它会自己降下来，那正是"该复习了"的意思。',
      style: TextStyle(
        fontSize: 11,
        height: 1.7,
        color: theme.colorScheme.outline,
      ),
    );
  }
}
