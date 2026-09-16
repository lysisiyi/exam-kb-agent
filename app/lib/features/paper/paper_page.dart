/// 组卷页：选模板 → 组卷 → 预览 → 导出。
///
/// ## 这一页的核心问题是"信任"
///
/// 组卷是**算法替用户做决定**：哪 22 道题、什么难度、多少分。
/// 用户看不到算法，只能看到结果。所以这一页必须做到三件事：
///
/// 1. **结果可核对**：每道题的题号、分值、难度、考点都摆出来，
///    用户能一眼看出"这卷子像不像真题"。
/// 2. **偏离要留痕**：题量不够、难度不符、分值是估算 ——
///    全部显示在预览上方，而不是让用户自己数出来。
/// 3. **不擅自保存**：组卷只是草稿，用户点了"保存"才落库。
///    否则试几次参数就会在历史里堆一堆没用的卷子。
///
/// ## 为什么组卷是同步的（不放进后台 isolate）
///
/// 个人题库是几百到几千条，贪心组卷是毫秒级（`PaperComposer` 只做一次
/// 线性扫描 + 排序）。放进 isolate 的通信开销比计算本身还大。
/// 真正重的是 **PDF 导出里的公式光栅化**（每个公式一次 `toImage`），
/// 那一步有进度提示。
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/breakpoints.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/paper/paper_models.dart';
import '../../domain/paper/paper_template.dart';
import '../../services/paper/paper_composer.dart';
import '../../services/paper/paper_pdf_exporter.dart';
import '../../services/paper/paper_repository.dart' show PaperTemplatesResult;

/// 模板 kind → 用户看得懂的说明。
///
/// 数据文件里有 `name` / `description`，这里只负责给一个"适合什么时候用"。
const Map<String, String> _kWhenToUse = {
  'real_exam': '完整模拟一次考试，掐表 180 分钟',
  'quick_mock': '碎片时间检验，约 90 分钟',
  'wrong_only': '只练你做错过的题，按薄弱度排',
};

class PaperPage extends ConsumerStatefulWidget {
  const PaperPage({super.key});

  @override
  ConsumerState<PaperPage> createState() => _PaperPageState();
}

class _PaperPageState extends ConsumerState<PaperPage> {
  String _subject = 'math1';
  String? _kind;
  PaperResult? _result;
  List<Candidate> _pool = const [];

  bool _busy = false;
  String? _error;
  String? _status;

  /// 组卷参数
  int _tolerance = 1;
  bool _preferWrong = true;
  bool _preferWeak = true;
  bool _diversify = true;

  Future<void> _compose() async {
    final kind = _kind;
    if (kind == null) return;
    // 重入闸门：组卷要读整个题库并算分，期间按钮虽然会变灰，
    // 但变灰靠的是下一帧的重建 —— 同一帧里连点两次仍会进两次。
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final repo = await ref.read(paperRepositoryProvider.future);
      final loaded = await repo.templates(subject: _subject);
      final template = loaded[kind];
      if (template == null) {
        // 带上真实原因：数据坏了与"没这个模板"要给用户不同的话
        throw StateError(
          loaded.error ?? '这个科目没有「$kind」模板',
        );
      }

      final pool = await repo.candidates(
        subject: _subject,
        // 错题专练只从做错过的题里抽
        onlyWrong: kind == 'wrong_only',
      );

      final result = const PaperComposer().compose(
        request: PaperRequest(
          template: template,
          subject: _subject,
          difficultyTolerance: _tolerance,
          preferWrong: _preferWrong,
          preferWeak: _preferWeak,
          diversify: _diversify,
        ),
        pool: pool,
      );

      if (!mounted) return;
      setState(() {
        _pool = pool;
        _result = result;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final result = _result;
    if (result == null) return;
    // 见 _compose：没有这道闸，连点两次会用同一个卷子 id 保存，
    // 第二次撞 `papers.id` 主键，弹出看不懂的 SQL 报错
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final repo = await ref.read(paperRepositoryProvider.future);
      await repo.save(result);
      ref.invalidate(paperHistoryProvider);
      if (mounted) setState(() => _status = '已保存到历史');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export(PaperLayout layout) async {
    final result = _result;
    if (result == null) return;
    // 见 _compose。导出最慢（逐条光栅化公式），并发两次会白烧两倍 CPU
    if (_busy) return;

    final dir = await fs.getDirectoryPath(confirmButtonText: '导出到这里');
    if (dir == null || !mounted) return;

    setState(() {
      _busy = true;
      _status = '正在导出（公式要逐条光栅化，稍等）…';
      _error = null;
    });
    try {
      final store = await ref.read(problemStoreProvider.future);
      final exporter = PaperPdfExporter(
        loadProblem: (id) async => (await store.read(id)).problem,
      );

      final stamp = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final name = '${result.template.name}-${layout.label}'
          '-${stamp.year}${two(stamp.month)}${two(stamp.day)}.pdf';
      final target = File('$dir${Platform.pathSeparator}$name');

      final out = await exporter.export(
        paper: result,
        layout: layout,
        target: target,
      );

      if (!mounted) return;
      setState(() => _status = '${out.summary}\n${out.path}');
      if (out.caveats.isNotEmpty) {
        // 提醒要显眼 —— 尤其是"中文可能显示异常"这条，
        // 不说的话用户会以为 App 坏了
        await _showCaveats(out.caveats);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showCaveats(List<String> caveats) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导出完成，但有两点要注意'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final c in caveats)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(c, style: const TextStyle(fontSize: 12.5, height: 1.7)),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bp = BreakpointScope.of(context);
    final compact = bp == LayoutBreakpoint.compact;
    final templates = ref.watch(paperTemplatesProvider(_subject));

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(compact ? 16 : 24, 18, compact ? 16 : 24, 24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('智能组卷',
                        style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text(
                      '按真题结构从你的错题本里抽题。抽出来的题会如实标出'
                      '难度、考点与偏离模板的地方。',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.7,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),
                    _Settings(
                      subject: _subject,
                      onSubject: (s) => setState(() {
                        _subject = s;
                        _kind = null;
                        _result = null;
                      }),
                      templates: templates,
                      kind: _kind,
                      onKind: (k) => setState(() {
                        _kind = k;
                        _result = null;
                      }),
                      tolerance: _tolerance,
                      onTolerance: (v) => setState(() => _tolerance = v),
                      preferWrong: _preferWrong,
                      onPreferWrong: (v) => setState(() => _preferWrong = v),
                      preferWeak: _preferWeak,
                      onPreferWeak: (v) => setState(() => _preferWeak = v),
                      diversify: _diversify,
                      onDiversify: (v) => setState(() => _diversify = v),
                      poolSize: _pool.length,
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: (_busy || _kind == null) ? null : _compose,
                          icon: _busy
                              ? const SizedBox(
                                  width: 15,
                                  height: 15,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.auto_awesome, size: 17),
                          label: Text(_result == null ? '组卷' : '重新组卷'),
                        ),
                        if (_result != null) ...[
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _save,
                            icon: const Icon(Icons.save_outlined, size: 17),
                            label: const Text('保存到历史'),
                          ),
                          for (final layout in PaperLayout.values)
                            OutlinedButton.icon(
                              onPressed: _busy ? null : () => _export(layout),
                              icon: const Icon(Icons.picture_as_pdf_outlined,
                                  size: 17),
                              label: Text('导出${layout.label}'),
                            ),
                        ],
                      ],
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      SelectableText(
                        _error!,
                        style: TextStyle(
                            fontSize: 12.5,
                            color: Theme.of(context).colorScheme.error),
                      ),
                    ],
                    if (_status != null) ...[
                      const SizedBox(height: 14),
                      _StatusBox(text: _status!),
                    ],
                    if (_result != null) ...[
                      const SizedBox(height: 20),
                      _Preview(
                        result: _result!,
                        labels: ref.watch(paperLabelsProvider).valueOrNull ??
                            const PaperLabels(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 参数区
// ─────────────────────────────────────────────────────────────────────────────

class _Settings extends StatelessWidget {
  final String subject;
  final ValueChanged<String> onSubject;
  final AsyncValue<PaperTemplatesResult> templates;
  final String? kind;
  final ValueChanged<String> onKind;
  final int tolerance;
  final ValueChanged<int> onTolerance;
  final bool preferWrong;
  final ValueChanged<bool> onPreferWrong;
  final bool preferWeak;
  final ValueChanged<bool> onPreferWeak;
  final bool diversify;
  final ValueChanged<bool> onDiversify;
  final int poolSize;

  const _Settings({
    required this.subject,
    required this.onSubject,
    required this.templates,
    required this.kind,
    required this.onKind,
    required this.tolerance,
    required this.onTolerance,
    required this.preferWrong,
    required this.onPreferWrong,
    required this.preferWeak,
    required this.onPreferWeak,
    required this.diversify,
    required this.onDiversify,
    required this.poolSize,
  });

  static const _subjects = {
    'math1': '数学一',
    'math2': '数学二',
    'math3': '数学三',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.line),
        borderRadius: AppRadius.rMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _FieldLabel('科目'),
          Wrap(
            spacing: 8,
            children: [
              for (final e in _subjects.entries)
                ChoiceChip(
                  label: Text(e.value),
                  selected: subject == e.key,
                  onSelected: (_) => onSubject(e.key),
                ),
            ],
          ),
          const SizedBox(height: 16),
          const _FieldLabel('模板'),
          templates.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
            error: (e, _) => Text('模板载入失败：$e',
                style: TextStyle(
                    fontSize: 12.5, color: theme.colorScheme.error)),
            data: (r) => r.isEmpty
                ? Text(
                    // 数据出问题与"这个科目没模板"是两件完全不同的事，
                    // 不能都说成"还没有可用模板"（见 PaperTemplatesResult）
                    r.error ?? '这个科目还没有可用模板',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: r.isOk ? null : theme.colorScheme.error,
                    ),
                  )
                : Column(
                    children: [
                      for (final e in r.templates.entries)
                        _TemplateTile(
                          template: e.value,
                          selected: kind == e.key,
                          onTap: () => onKind(e.key),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 16),
          const _FieldLabel('抽题偏好'),
          // ⚠️ `SwitchListTile` 必须包一层透明 `Material`。
          //
          // 它和 `ExpansionTile` 同源：都是 ListTile 家族，会把背景与涟漪画到
          // **最近的 Material 祖先**上，而外层那个带白底的 `Container`
          // 会把它盖住。Flutter 为此直接抛断言：
          //   "ListTile background color or ink splashes may be invisible"
          //
          // 这个坑在 `knowledge_page.dart` 里已经踩过一次（那次是 ExpansionTile）。
          // 规矩：**ListTile 家族放进带背景的容器里，一律先包 Material**。
          Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: preferWeak,
                  onChanged: onPreferWeak,
                  title: const Text('优先薄弱考点', style: TextStyle(fontSize: 13)),
                  subtitle: const Text('掌握度低的考点优先出题',
                      style: TextStyle(fontSize: 11.5)),
                ),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: preferWrong,
                  onChanged: onPreferWrong,
                  title: const Text('优先做错过的题', style: TextStyle(fontSize: 13)),
                  subtitle: const Text('错得越多越靠前',
                      style: TextStyle(fontSize: 11.5)),
                ),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: diversify,
                  onChanged: onDiversify,
                  title: const Text('分散考点', style: TextStyle(fontSize: 13)),
                  subtitle: const Text('同一个考点不在一份卷里反复出现',
                      style: TextStyle(fontSize: 11.5)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const _FieldLabel('难度匹配'),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('严格')),
              ButtonSegment(value: 1, label: Text('相邻一档')),
              ButtonSegment(value: 2, label: Text('不限')),
            ],
            selected: {tolerance},
            onSelectionChanged: (s) => onTolerance(s.first),
            showSelectedIcon: false,
          ),
          const SizedBox(height: 10),
          Text(
            poolSize == 0
                ? '（点「组卷」后这里会显示候选题数）'
                : '候选题 $poolSize 道',
            style: TextStyle(
                fontSize: 11.5, color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _TemplateTile extends StatelessWidget {
  final PaperTemplate template;
  final bool selected;
  final VoidCallback onTap;

  const _TemplateTile({
    required this.template,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final when = _kWhenToUse[template.id.split('.').last];
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected ? AppColors.primaryWeak : Colors.transparent,
        borderRadius: AppRadius.rSm,
        child: InkWell(
          borderRadius: AppRadius.rSm,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: selected ? AppColors.primary : AppColors.ink4,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(template.name,
                          style: const TextStyle(
                              fontSize: 13.5, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 3),
                      Text(
                        [
                          '${template.questionCount} 题',
                          if (template.totalScore != null)
                            '${template.totalScore} 分',
                          if (template.durationMinutes != null)
                            '${template.durationMinutes} 分钟',
                        ].join(' · '),
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      if (when != null) ...[
                        const SizedBox(height: 2),
                        Text(when,
                            style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 预览
// ─────────────────────────────────────────────────────────────────────────────

class _Preview extends StatelessWidget {
  final PaperResult result;
  final PaperLabels labels;

  const _Preview({required this.result, required this.labels});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('试卷预览',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: 10),
            Text(result.summary,
                style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
        if (result.hasEstimatedScores) ...[
          const SizedBox(height: 6),
          Text(
            '注：这个模板不固定每题分值，总分是估算值。',
            style: TextStyle(
                fontSize: 11.5, color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        // 偏离模板的地方必须显眼 —— 用户是照着"真题结构"来选的
        if (result.warnings.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: const BoxDecoration(
              color: AppColors.warningWeak,
              borderRadius: AppRadius.rSm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('这份卷子与模板的差异',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.warningInk)),
                const SizedBox(height: 6),
                for (final w in result.warnings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text('· $w',
                        style: const TextStyle(
                            fontSize: 11.5,
                            height: 1.6,
                            color: AppColors.warningInk)),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        for (final entry in result.bySection.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 6),
            child: Text(
              '${entry.key}（${entry.value.length} 题）',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ),
          for (final it in entry.value)
            _ItemTile(item: it, labels: labels),
        ],
      ],
    );
  }
}

class _ItemTile extends StatelessWidget {
  final PaperItem item;
  final PaperLabels labels;

  const _ItemTile({required this.item, required this.labels});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stem = item.stemText.replaceAll(RegExp(r'\s+'), ' ').trim();
    final clipped = stem.length <= 70 ? stem : '${stem.substring(0, 70)}…';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 26,
            child: Text('${item.seat.no}.',
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w700)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(clipped, style: const TextStyle(fontSize: 12.5, height: 1.6)),
                const SizedBox(height: 3),
                Wrap(
                  spacing: 6,
                  runSpacing: 3,
                  children: [
                    _Pill(
                      text: labels.difficultyName(item.actualDifficulty),
                      color: AppColors.primary,
                    ),
                    if (item.primaryKpName != null)
                      _Pill(
                          text: item.primaryKpName!,
                          color: theme.colorScheme.onSurfaceVariant),
                    if (item.wrongCount > 0)
                      _Pill(
                          text: '错 ${item.wrongCount} 次',
                          color: const Color(0xFFE03131)),
                    _Pill(
                        text: item.seat.score == null
                            ? '分值待定'
                            : '${item.seat.score} 分',
                        color: theme.colorScheme.onSurfaceVariant),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 小组件
// ─────────────────────────────────────────────────────────────────────────────

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
      );
}

class _StatusBox extends StatelessWidget {
  final String text;
  const _StatusBox({required this.text});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: const BoxDecoration(
          color: AppColors.successWeak,
          borderRadius: AppRadius.rSm,
        ),
        child: SelectableText(
          text,
          style: const TextStyle(fontSize: 12, height: 1.7),
        ),
      );
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  const _Pill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w600, color: color)),
      );
}
