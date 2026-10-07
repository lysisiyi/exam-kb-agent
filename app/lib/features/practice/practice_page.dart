/// 练习页（V3 严格按参考图 `docs/design/ui/ui_practice.png` 重建）。
///
/// ## 版式（与参考图逐块对应）
///
/// ```
/// 练习
/// 练错的题自动归入对应知识点（图像题面），进入 FSRS 复习循环
/// ┌ 入口① 课时练习(推荐) ┐ ┌ 入口② 错题专练 ┐ ┌ 入口③ 真题全卷/限时模考 ┐
/// │ 第5讲 · 8题          │ │ 错因统计       │ │ 模板抽取                │
/// │ [▶ 开始练习]          │ │ [去组卷]       │ │ [去组卷]                │
/// └─────────────────────┘ └───────────────┘ └────────────────────────┘
/// ┌ ✋ AI 自创题 · 待复核(N) ────────────────────────────────────────────┐
/// ┌ ── 最近练习 ─────────────────────────────────────────────────────────┐
/// ```
///
/// 「去组卷」= 展开下方的组卷器（入口②③公用），组卷器是既有能力原样嵌入。
/// 课时练习（P3）与 AI 自创题生成（P3）未上线，按钮如实标注，不放假入口。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/page_header.dart';
import '../../data/db/database.dart';
import '../paper/paper_page.dart';
import '../problems/problems_page.dart' show ProblemView;

/// 待复核的 AI 题目（needsReview）题干清单——取题库列表现过滤。
final pendingAiProblemsProvider = FutureProvider<List<String>>((ref) async {
  final rows = await ref.watch(problemListProvider(ProblemView.recent).future);
  return [
    for (final r in rows)
      if (r.needsReview) r.stemText,
  ];
});

class PracticePage extends ConsumerStatefulWidget {
  const PracticePage({super.key});

  @override
  ConsumerState<PracticePage> createState() => _PracticePageState();
}

class _PracticePageState extends ConsumerState<PracticePage> {
  /// 入口②③是否展开了组卷器。
  bool _composerOpen = false;

  /// 组卷器预选的模板（错题专练=wrong_only，真题=real_exam）。
  String? _presetKind;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const PageHeader(
                title: '练习',
                subtitle:
                    '练错的题自动归入对应知识点（图像题面），进入 FSRS 复习循环 —— 练习是知识库的上游进水口',
              ),
              const SizedBox(height: 6),
              _EntriesRow(
                composerOpen: _composerOpen,
                onOpenComposer: (kind) => setState(() {
                  _presetKind = kind;
                  _composerOpen = true;
                }),
              ),
              const SizedBox(height: 14),
              _AiDraftReviewCard(),
              const SizedBox(height: 14),
              if (_composerOpen)
                PaperPage(presetKind: _presetKind, embedded: true)
              else
                _HistoryCard(),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 三入口卡（参考图第二行）
// ─────────────────────────────────────────────────────────────────────────────

class _EntriesRow extends StatelessWidget {
  final bool composerOpen;
  final void Function(String kind) onOpenComposer;
  const _EntriesRow({required this.composerOpen, required this.onOpenComposer});

  @override
  Widget build(BuildContext context) {
    // IntrinsicHeight 让三卡等高（卡内用 Spacer 需要有界高度；
    // SingleChildScrollView 里直接 CrossAxisAlignment.stretch 会拿无穷高）。
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _EntryLesson()),
          const SizedBox(width: 14),
          Expanded(
            child: _EntryCard(
              no: '入口 ② · 按需',
              title: '错题专练',
              desc: '从错题里按模板抽题重做，优先错得多的',
              chips: const ['原组卷 · 错题专练'],
              buttonLabel: '去组卷',
              onPressed: () => onOpenComposer('wrong_only'),
              active: composerOpen,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: _EntryCard(
              no: '入口 ③ · 按需',
              title: '真题全卷 / 限时模考',
              desc: '按真题模板整卷抽取，锁定题目、错因对症都保留',
              chips: const ['原组卷 · 真题模板'],
              buttonLabel: '去组卷',
              onPressed: () => onOpenComposer('real_exam'),
              active: composerOpen,
            ),
          ),
        ],
      ),
    );
  }
}

/// 入口①（推荐位）：课时练习。P3 未上线 —— 卡片如实标注，
/// 点按钮弹出说明而不是假装能用。
class _EntryLesson extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.rLg,
        border: Border.all(color: AppColors.primarySoft, width: 1.5),
        boxShadow: [
          BoxShadow(
              color: AppColors.primary.withValues(alpha: 0.10),
              blurRadius: 18,
              offset: const Offset(0, 6)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('入口 ① · 本节课',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: AppColors.ink3,
                  letterSpacing: 0.6)),
          const SizedBox(height: 8),
          Row(children: [
            const Text('课时练习',
                style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.primaryWeak,
                borderRadius: BorderRadius.circular(99),
              ),
              child: const Text('推荐',
                  style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primaryStrong)),
            ),
          ]),
          const SizedBox(height: 6),
          Text('看完一节网课生成：题库匹配 + AI 自创题',
              style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          const Wrap(spacing: 6, runSpacing: 4, children: [
            _MiniChip(text: '题库匹配 5 题'),
            _MiniChip(text: 'AI 自创 3 题'),
          ]),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('课时练习随 P3 练习生成上线 —— 先用入口②③组卷'))),
                icon: const Icon(Icons.play_arrow_rounded, size: 17),
                label: const Text('开始练习（8 题）',
                    style: TextStyle(fontSize: 12.5)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 入口②③的通用卡。
class _EntryCard extends StatelessWidget {
  final String no;
  final String title;
  final String desc;
  final List<String> chips;
  final String buttonLabel;
  final VoidCallback onPressed;
  final bool active;

  const _EntryCard({
    required this.no,
    required this.title,
    required this.desc,
    required this.chips,
    required this.buttonLabel,
    required this.onPressed,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.rLg,
        border: Border.all(color: AppColors.line),
        boxShadow: AppShadows.s1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(no,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: AppColors.ink3,
                  letterSpacing: 0.6)),
          const SizedBox(height: 8),
          Text(title,
              style:
                  const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(desc,
              style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [for (final c in chips) _MiniChip(text: c)]),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: onPressed,
                style: OutlinedButton.styleFrom(
                  side: BorderSide(
                      color: active ? AppColors.primary : AppColors.line),
                  foregroundColor:
                      active ? AppColors.primaryStrong : AppColors.ink2,
                ),
                child: Text(active ? '组卷器已展开 ↓' : buttonLabel,
                    style: const TextStyle(fontSize: 12.5)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  final String text;
  const _MiniChip({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(text,
          style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: AppColors.ink2)),
    );
  }
}

/// 历史行的右侧：课时练习解析 config 显示「对 X · 错 Y」，组卷显示满分。
List<Widget> _recordTail(PaperRow r) {
  try {
    final cfg = jsonDecode(r.config);
    if (cfg is Map && cfg['kind'] == 'lesson_practice') {
      final right = (cfg['right'] as num?)?.toInt() ?? 0;
      final wrong = (cfg['wrong'] as num?)?.toInt() ?? 0;
      final allRight = wrong == 0 && right > 0;
      return [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: allRight ? AppColors.successWeak : AppColors.warningWeak,
            borderRadius: BorderRadius.circular(99),
          ),
          child: Text('对 $right · 错 $wrong',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: allRight ? AppColors.success : AppColors.warningInk)),
        ),
        const SizedBox(width: 6),
        const Text('课时练习',
            style: TextStyle(fontSize: 10.5, color: AppColors.ink3)),
      ];
    }
  } catch (_) {/* 老记录/坏 config：退化为满分显示 */}
  return [
    Text(r.totalScore == null ? r.subject : '满分 ${r.totalScore}',
        style: const TextStyle(fontSize: 11.5, color: AppColors.ink2)),
  ];
}

// ─────────────────────────────────────────────────────────────────────────────
// AI 自创题 · 待复核（参考图琥珀卡）
// ─────────────────────────────────────────────────────────────────────────────

class _AiDraftReviewCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingAiProblemsProvider);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.rMd,
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.45)),
      ),
      child: pending.when(
        loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text('正在读取待复核题目…',
                style: TextStyle(fontSize: 12, color: AppColors.ink3))),
        error: (e, _) => Text('待复核读取失败：$e',
            style: const TextStyle(fontSize: 12, color: AppColors.danger)),
        data: (items) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Text('✋ AI 自创题 · 待复核',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w800)),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.warningWeak,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text('${items.length}',
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.warningInk)),
              ),
              const Spacer(),
              Text('来自课时练习的 AI 原创题，复核后才进入练习与复习',
                  style: TextStyle(
                      fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ]),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('当前没有待复核的自创题。P3 上线后，AI 依课时笔记出的原创题会先到这里等你把关。',
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              )
            else
              for (final item in items.take(3))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.warningWeak,
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: const Text('自创',
                          style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: AppColors.warningInk)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(item,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5))),
                  ]),
                ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 最近练习（组卷历史，P3 后会有课时练习记录混排）
// ─────────────────────────────────────────────────────────────────────────────

class _HistoryCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(paperHistoryProvider);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.rLg,
        border: Border.all(color: AppColors.line),
      ),
      child: historyAsync.when(
        loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text('正在读取练习历史…',
                style: TextStyle(fontSize: 12, color: AppColors.ink3))),
        error: (e, _) => Text('历史读取失败：$e',
            style: const TextStyle(fontSize: 12, color: AppColors.danger)),
        data: (records) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('── 最近练习 ──',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                    color: AppColors.ink3)),
            const SizedBox(height: 8),
            if (records.isEmpty)
              Text('还没有练习记录。上面的入口练一次，这里就会出现第一条。',
                  style: TextStyle(
                      fontSize: 12.5,
                      height: 1.6,
                      color: Theme.of(context).colorScheme.onSurfaceVariant))
            else
              for (final r in records.take(6))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(children: [
                    SizedBox(
                        width: 46,
                        child: Text(
                            '${r.createdAt.month}/${r.createdAt.day}',
                            style: const TextStyle(
                                fontSize: 11.5, color: AppColors.ink3))),
                    Expanded(
                        child: Text(r.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700))),
                    const SizedBox(width: 10),
                    // 课时练习记录带对错；组卷记录显示满分/科目
                    ..._recordTail(r),
                  ]),
                ),
          ],
        ),
      ),
    );
  }
}
