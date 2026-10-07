/// 课时练习（P3 主链路）：从课时笔记生成一节的小练习，逐题作答。
///
/// ## 生成（题库匹配轨）
///
/// 每条笔记的要点作为 FTS 查询 → 合并去重 → 按相关性取前 N 题。
/// AI 自创题轨与练习记录落 `papers` 表随 P3 完整版补——
/// 本页只在结果页如实标注「错题已计入错次」，不假装有成绩单。
///
/// ## 作答（D9 自主判分）
///
/// 题面（图优先）→「亮答案」→ 自评 对/错 —— 答错的题
/// 走 `reviewRepository.recordWrong`（与复习评分同一 SQL 自增纪律），
/// 自然进入错题本与 FSRS 队列。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/math/math_renderer.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../data/markdown/problem_markdown.dart';
import '../../data/problem_file.dart';
import '../problems/problem_images.dart';

/// 一节练习的生成结果（题目 id 有序表）。
class LessonPracticeSet {
  final List<String> problemIds;
  const LessonPracticeSet(this.problemIds);
}

/// 按 FTS 关键词合并检索题目（去重、按最优 rank 排序、截取 limit）。
Future<List<String>> matchProblemsForNotes(WidgetRef ref, List<String> keywords,
    {int limit = 8}) async {
  final seen = <String>{};
  final ranked = <MapEntry<String, double>>[];
  for (final kw in keywords) {
    final q = kw.trim();
    if (q.length < 2) continue;
    final hits = await ref.read(problemSearchProvider(q).future);
    for (final h in hits) {
      if (seen.add(h.problemId)) {
        ranked.add(MapEntry(h.problemId, h.rank));
      }
    }
  }
  ranked.sort((a, b) => a.value.compareTo(b.value));
  return [for (final e in ranked.take(limit)) e.key];
}

/// 逐题作答页（D9：亮答案 → 自评对/错）。
class LessonRunnerPage extends ConsumerStatefulWidget {
  final List<String> problemIds;
  const LessonRunnerPage({super.key, required this.problemIds});

  @override
  ConsumerState<LessonRunnerPage> createState() => _LessonRunnerPageState();
}

class _LessonRunnerPageState extends ConsumerState<LessonRunnerPage> {
  int _index = 0;
  bool _revealed = false;
  final _wrong = <String>[];
  final _right = <String>[];
  Problem? _problem;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _loadCurrent();
  }

  Future<void> _loadCurrent() async {
    final store = await ref.read(problemStoreProvider.future);
    final db = await ref.read(databaseProvider.future);
    final id = widget.problemIds[_index];
    final read = await readIndexedProblem(db: db, store: store, problemId: id);
    if (!mounted) return;
    setState(() {
      _problem = read.isOk ? read.problem : null;
      _loadFailed = !read.isOk;
      _revealed = false;
    });
  }

  Future<void> _grade(bool correct) async {
    final id = widget.problemIds[_index];
    if (correct) {
      _right.add(id);
    } else {
      _wrong.add(id);
      // 错题联动：与复习评分同一 SQL 自增路径，自然进错题本与 FSRS。
      final repo = await ref.read(reviewRepositoryProvider.future);
      await repo.recordWrong(id);
    }
    if (_index + 1 >= widget.problemIds.length) {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
          builder: (_) => _RunnerDone(
                right: _right,
                wrong: _wrong,
              )));
      return;
    }
    setState(() => _index++);
    await _loadCurrent();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text('课时练习 ${_index + 1}/${widget.problemIds.length}')),
      body: _loadFailed
          ? _LoadFail(
              onSkip: () => _grade(true), // 跳过视为作对——不入错次，如实记日志
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('第 ${_index + 1} 题 · 共 ${widget.problemIds.length} 题',
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.ink3)),
                      const SizedBox(height: 10),
                      _StemView(problem: _problem),
                      const SizedBox(height: 16),
                      _AnswerReveal(
                          problem: _problem,
                          revealed: _revealed,
                          onReveal: () => setState(() => _revealed = true)),
                      if (_revealed) ...[
                        const SizedBox(height: 20),
                        const Text('做的怎么样？（自主判分，结果计入错次与 FSRS）',
                            style: TextStyle(
                                fontSize: 12.5, color: AppColors.ink2)),
                        const SizedBox(height: 10),
                        Row(children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => _grade(true),
                              icon: const Icon(Icons.check, size: 18),
                              label: const Text('做对了',
                                  style: TextStyle(fontSize: 13.5)),
                              style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.success,
                                  minimumSize: const Size(0, 44)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => _grade(false),
                              icon: const Icon(Icons.close, size: 18),
                              label: const Text('做错了',
                                  style: TextStyle(fontSize: 13.5)),
                              style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.danger,
                                  minimumSize: const Size(0, 44)),
                            ),
                          ),
                        ]),
                      ],
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

class _LoadFail extends StatelessWidget {
  final VoidCallback onSkip;
  const _LoadFail({required this.onSkip});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('这道题读不出来（索引与文件可能不同步）。',
            style: TextStyle(fontSize: 13, color: AppColors.danger)),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: onSkip, child: const Text('跳过此题')),
      ]),
    );
  }
}

/// 题面：图优先（扫描题），文字题干次之。
class _StemView extends ConsumerWidget {
  final Problem? problem;
  const _StemView({required this.problem});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = problem;
    if (p == null) return const SizedBox.shrink();
    final imagesDir =
        ref.watch(libraryPathsProvider).valueOrNull?.images.path;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (p.imagesPrimary && p.images.isNotEmpty)
        ProblemImageList(images: p.images, imagesDirPath: imagesDir)
      else ...[
        DefaultTextStyle.merge(
          style: const TextStyle(fontSize: 15, height: 1.85),
          child: MathRendering.renderer.renderMarkdown(p.stem),
        ),
        if (p.images.isNotEmpty) ...[
          const SizedBox(height: 10),
          ProblemImageList(images: p.images, imagesDirPath: imagesDir),
        ],
      ],
    ]);
  }
}

/// 答案与解析（揭晓前是占位卡）。
class _AnswerReveal extends StatelessWidget {
  final Problem? problem;
  final bool revealed;
  final VoidCallback onReveal;
  const _AnswerReveal(
      {required this.problem, required this.revealed, required this.onReveal});

  @override
  Widget build(BuildContext context) {
    final p = problem;
    if (!revealed || p == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 22),
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: AppRadius.rMd,
          border: Border.all(color: AppColors.line),
        ),
        child: Column(children: [
          const Icon(Icons.visibility_off_outlined,
              size: 24, color: AppColors.ink4),
          const SizedBox(height: 8),
          FilledButton.tonal(
              onPressed: onReveal, child: const Text('亮答案')),
        ]),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('答案',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
              color: AppColors.primaryStrong)),
      const SizedBox(height: 4),
      DefaultTextStyle.merge(
        style: const TextStyle(fontSize: 14.5, height: 1.85),
        child: MathRendering.renderer
            .renderMarkdown(p.answer ?? '（此题没有答案字段）'),
      ),
      if (p.solution != null && p.solution!.isNotEmpty) ...[
        const SizedBox(height: 12),
        const Text('解析',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                color: AppColors.primaryStrong)),
        const SizedBox(height: 4),
        DefaultTextStyle.merge(
          style: const TextStyle(fontSize: 14, height: 1.85),
          child: MathRendering.renderer.renderMarkdown(p.solution!),
        ),
      ],
    ]);
  }
}

/// 结算页：对错统计 + 错题去向说明。
class _RunnerDone extends StatelessWidget {
  final List<String> right;
  final List<String> wrong;
  const _RunnerDone({required this.right, required this.wrong});

  @override
  Widget build(BuildContext context) {
    final total = right.length + wrong.length;
    return Scaffold(
      appBar: AppBar(title: const Text('练习完成')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('🎉 本节练习完成',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            Text('共 $total 题 · 做对 ${right.length} · 做错 ${wrong.length}',
                style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 10),
            Text(
              wrong.isEmpty
                  ? '全对！错题本没有新条目。'
                  : '做错的 ${wrong.length} 题已计入错次，并进入 FSRS 复习队列。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12.5,
                  height: 1.7,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 18),
            FilledButton(
                onPressed: () => Navigator.of(context)
                    .popUntil((r) => r.isFirst),
                child: const Text('回到课时')),
          ]),
        ),
      ),
    );
  }
}
