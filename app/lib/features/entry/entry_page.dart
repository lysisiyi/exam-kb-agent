/// 录入页 —— M4 的核心，也是用户唯一的高频动作。
///
/// ## 设计目标只有一个：掐表 ≤ 60 秒
///
/// 规划里写得很直白："M4 做不好，整个产品没意义"。所以这一页的每个决定
/// 都是围绕"少一次点击、少一次滚动"做的：
///
/// | 决定 | 原因 |
/// |---|---|
/// | 题干框自动聚焦、占满首屏 | 用户打开就是要贴题，不该先找输入框 |
/// | 公式键盘常驻在题干下方 | 移动端的"弹窗里选符号"在 PC 上多一次点击 |
/// | 保存不强制选考点 | 逼用户在现场翻 198 个知识点，60 秒必崩（存为待确认） |
/// | 错因放在保存**之前但可选** | 规划允许事后批量补 |
/// | 宽屏右侧实时预览 | 公式打错要立刻看见，否则错了要到错题本才发现 |
///
/// ## 与 AI 打标的关系
///
/// AI 打标是**加速器而不是必经步骤**：没配 Key 时按钮变成"配置后可用"，
/// 录入流程完全不受影响（离线可用是产品承诺，不是降级方案）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/breakpoints.dart';
import '../../core/math/math_renderer.dart';
import '../../core/providers.dart';
import '../../data/error_causes.dart';
import '../../data/markdown/problem_markdown.dart';
import '../../domain/knowledge/knowledge_point.dart';
import '../../domain/problem_draft.dart';
import 'widgets/entry_ai_button.dart';
import 'widgets/formula_keyboard.dart';
import 'widgets/kp_picker.dart';

class EntryPage extends ConsumerStatefulWidget {
  /// 编辑已有题目时传入的初始草稿。为 null 表示"录新题"。
  ///
  /// 编辑必须带着原 id（[ProblemDraft.id]）：否则指纹查重会把这次保存
  /// 当成"重复录入"拦下来，而不是当成"编辑同一道题"。
  final ProblemDraft? initial;

  const EntryPage({super.key, this.initial});

  @override
  ConsumerState<EntryPage> createState() => _EntryPageState();
}

class _EntryPageState extends ConsumerState<EntryPage> {
  final _stem = TextEditingController();
  final _answer = TextEditingController();
  final _solution = TextEditingController();
  final _note = TextEditingController();
  final _source = TextEditingController();
  final _optionCtrls = <TextEditingController>[TextEditingController(), TextEditingController()];
  final _stemFocus = FocusNode();

  QuestionType _qtype = QuestionType.solve;
  int _difficulty = 2;
  SourceType _sourceType = SourceType.textbook;
  int? _sourceYear;
  String? _primaryKpId;
  final List<String> _secondaryKpIds = [];
  final Set<String> _errorCauses = {};
  bool _aiTagged = false;
  double? _aiConfidence;
  bool _needsReview = false;
  bool _advancedOpen = false;
  bool _saving = false;

  /// 正在编辑的题目的原 id。
  ///
  /// 编辑时**必须**带着它：否则指纹查重会把这次保存当成"重复录入"拦下来，
  /// 而不是当成"编辑同一道题"。
  String? _editingId;

  @override
  void initState() {
    super.initState();
    final d = widget.initial;
    if (d != null) _loadDraft(d);
  }

  /// 把草稿填进表单（编辑已有题目）。
  void _loadDraft(ProblemDraft d) {
    _editingId = d.id;
    _stem.text = d.stem;
    _answer.text = d.answer ?? '';
    _solution.text = d.solution ?? '';
    _note.text = d.note ?? '';
    _source.text = d.source ?? '';
    _qtype = d.qtype;
    _difficulty = d.difficulty;
    _sourceType = d.sourceType;
    _sourceYear = d.sourceYear;
    _primaryKpId = d.primaryKpId;
    _secondaryKpIds
      ..clear()
      ..addAll(d.secondaryKpIds);
    _errorCauses
      ..clear()
      ..addAll(d.errorCauses);
    _aiTagged = d.aiTagged;
    _aiConfidence = d.aiConfidence;
    _needsReview = d.needsReview;
    // 选项数按题目来（至少 2，否则选择题校验过不了）
    if (d.options.length >= 2) {
      for (final c in _optionCtrls) {
        c.dispose();
      }
      _optionCtrls
        ..clear()
        ..addAll(d.options.map((o) => TextEditingController(text: o)));
    }
  }

  @override
  void dispose() {
    _stem.dispose();
    _answer.dispose();
    _solution.dispose();
    _note.dispose();
    _source.dispose();
    for (final c in _optionCtrls) {
      c.dispose();
    }
    _stemFocus.dispose();
    super.dispose();
  }

  ProblemDraft _draft() => ProblemDraft(
        id: _editingId,
        qtype: _qtype,
        difficulty: _difficulty,
        stem: _stem.text,
        options: _qtype == QuestionType.choice
            ? _optionCtrls.map((c) => c.text).toList()
            : const [],
        answer: _answer.text,
        solution: _solution.text,
        note: _note.text,
        source: _source.text,
        sourceType: _sourceType,
        sourceYear: _sourceYear,
        primaryKpId: _primaryKpId,
        secondaryKpIds: [..._secondaryKpIds],
        errorCauses: _errorCauses.toList(),
        aiTagged: _aiTagged,
        aiConfidence: _aiConfidence,
        needsReview: _needsReview,
      );

  void _resetForm() {
    _stem.clear();
    _answer.clear();
    _solution.clear();
    _note.clear();
    _source.clear();
    for (final c in _optionCtrls) {
      c.clear();
    }
    setState(() {
      _qtype = QuestionType.solve;
      _difficulty = 2;
      _sourceType = SourceType.textbook;
      _sourceYear = null;
      _primaryKpId = null;
      _secondaryKpIds.clear();
      _errorCauses.clear();
      _aiTagged = false;
      _aiConfidence = null;
      _needsReview = false;
      _saving = false;
      // 清掉"正在编辑"的标记，否则下一道新题会沿用上一题的 id
      _editingId = null;
    });
    _stemFocus.requestFocus();
  }

  Future<void> _save({bool overwrite = false}) async {
    final service = await ref.read(problemServiceProvider.future);
    if (!mounted) return;
    setState(() => _saving = true);

    final outcome = await service.save(_draft(), overwriteExisting: overwrite);
    if (!mounted) return;
    setState(() => _saving = false);

    if (!outcome.ok) {
      if (outcome.duplicates.isNotEmpty) {
        final again = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('这道题已经录过了'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('题库里已有题干相同的题目：'),
                const SizedBox(height: 8),
                for (final d in outcome.duplicates)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('· ${d.id}\n  ${d.stemPreview}',
                        style: const TextStyle(fontSize: 12.5)),
                  ),
                const SizedBox(height: 12),
                const Text(
                  '如果这是"又错了一次"，正确做法是在错题本里给它记一次错，'
                  '而不是新建一道题 —— 否则复习进度会分成两份。',
                  style: TextStyle(fontSize: 12, height: 1.5),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('返回修改'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('就是它，覆盖内容'),
              ),
            ],
          ),
        );
        if (again == true) {
          await _save(overwrite: true);
        }
      } else {
        _snack(outcome.error ?? '保存失败', error: true);
      }
      return;
    }

    _snack('已保存：${outcome.problem!.id}');

    // 给新题建一张复习卡（幂等：已有的不动）。
    // 放在这里而不是"打开复习页时才补"，是为了让保存后立刻统计得到。
    try {
      final repo = await ref.read(reviewRepositoryProvider.future);
      await repo.ensureCards();
    } catch (_) {
      // 建卡失败不该让"保存成功"变成失败提示 —— Markdown 已经落盘了
    }
    if (!mounted) return;

    // 编辑模式：保存完退回错题本，而不是清空表单继续录
    if (_editingId != null) {
      Navigator.of(context).maybePop();
      return;
    }
    _resetForm();
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

  @override
  Widget build(BuildContext context) {
    final kbAsync = ref.watch(knowledgeBaseProvider);
    final causesAsync = ref.watch(errorCauseCatalogProvider);
    final bp = BreakpointScope.of(context);
    final wide = bp == LayoutBreakpoint.expanded || bp == LayoutBreakpoint.large;

    return kbAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('知识点本体载入失败：$e')),
      data: (kb) => causesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('错因词表载入失败：$e')),
        data: (catalog) => _buildForm(context, kb, catalog, wide: wide),
      ),
    );
  }

  Widget _buildForm(
    BuildContext context,
    KnowledgeBase kb,
    ErrorCauseCatalog catalog, {
    required bool wide,
  }) {
    final draft = _draft();
    final issues = draft.validate(knowledge: kb);
    final blocking = issues.where((i) => i.level == DraftIssueLevel.blocking).toList();
    final warnings = issues.where((i) => i.level == DraftIssueLevel.warning).toList();

    final form = ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      children: [
        _SectionTitle(
          '题干',
          trailing: Text(
            '支持 LaTeX：行内 \$x^2\$　独立 \$\$...\$\$　Ctrl+M 包住选中文字',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _stem,
          focusNode: _stemFocus,
          autofocus: true,
          minLines: 4,
          maxLines: 12,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            hintText: r'例：求 $\displaystyle\lim_{x\to0}\frac{\sin x-x\cos x}{x^{3}}$。',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 8),
        FormulaKeyboard(controller: _stem),
        const SizedBox(height: 18),

        // 题型
        _SectionTitle('题型'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          children: [
            for (final t in QuestionType.values)
              ChoiceChip(
                label: Text(t.label),
                selected: _qtype == t,
                onSelected: (_) => setState(() {
                  _qtype = t;
                  if (t == QuestionType.choice && _optionCtrls.length < 2) {
                    while (_optionCtrls.length < 2) {
                      _optionCtrls.add(TextEditingController());
                    }
                  }
                }),
              ),
          ],
        ),
        if (_qtype == QuestionType.choice) ...[
          const SizedBox(height: 10),
          for (var i = 0; i < _optionCtrls.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 22,
                    child: Text('${String.fromCharCode(65 + i)}.',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _optionCtrls[i],
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '删除该选项',
                    icon: const Icon(Icons.remove_circle_outline, size: 18),
                    onPressed: _optionCtrls.length <= 2
                        ? null
                        : () => setState(() {
                              _optionCtrls.removeAt(i).dispose();
                            }),
                  ),
                ],
              ),
            ),
          TextButton.icon(
            onPressed: () =>
                setState(() => _optionCtrls.add(TextEditingController())),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('加一个选项'),
          ),
        ],
        const SizedBox(height: 18),

        // 答案与解析
        _SectionTitle('答案与解析'),
        const SizedBox(height: 6),
        TextField(
          controller: _answer,
          minLines: 1,
          maxLines: 4,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: '答案（可留空）',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _solution,
          minLines: 2,
          maxLines: 8,
          decoration: const InputDecoration(
            labelText: '解析（可留空）',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 18),

        // 考点
        _SectionTitle(
          '考点',
          trailing: _KpSummary(
            kb: kb,
            primaryId: _primaryKpId,
            secondaryIds: _secondaryKpIds,
          ),
        ),
        const SizedBox(height: 6),
        // 用 Wrap 而不是 Row：两个按钮的文字都不短
        // （「AI 标注（需配置 Key）」尤其长），
        // 窄屏下 Row 会直接溢出（实测 420px 宽溢出 9.8px）。
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            OutlinedButton.icon(
              onPressed: () async {
                final sel = await showKpPicker(
                  context,
                  kb: kb,
                  primaryId: _primaryKpId,
                  secondaryIds: _secondaryKpIds,
                );
                if (sel != null) {
                  setState(() {
                    _primaryKpId = sel.primaryId;
                    _secondaryKpIds
                      ..clear()
                      ..addAll(sel.secondaryIds);
                  });
                }
              },
              icon: const Icon(Icons.search, size: 16),
              label: Text(_primaryKpId == null ? '选主考点' : '改考点'),
            ),
            EntryAiButton(
              draft: _draft(),
              knowledge: kb,
              onResult: (r) => setState(() {
                _primaryKpId = r.primaryKpId;
                _secondaryKpIds
                  ..clear()
                  ..addAll(r.secondaryKpIds);
                _aiTagged = true;
                _aiConfidence = r.confidence;
                _needsReview = r.needsReview;
                if (r.difficulty != null) _difficulty = r.difficulty!;
                // 错因只在用户还没选时预填 —— 别覆盖用户自己的判断
                if (_errorCauses.isEmpty) {
                  _errorCauses.addAll(r.errorCauses);
                }
              }),
              onMessage: (m, {error = false}) => _snack(m, error: error),
            ),
          ],
        ),
        const SizedBox(height: 18),

        // 错因
        _SectionTitle(
          '错因',
          trailing: Text(
            catalog.multiSelect ? '可多选 · 允许事后补' : '单选 · 允许事后补',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final c in catalog.ordered)
              FilterChip(
                label: Text(c.short),
                selected: _errorCauses.contains(c.id),
                onSelected: (on) => setState(() {
                  if (on) {
                    if (!catalog.multiSelect) _errorCauses.clear();
                    _errorCauses.add(c.id);
                  } else {
                    _errorCauses.remove(c.id);
                  }
                }),
              ),
          ],
        ),
        if (_errorCauses.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final id in _errorCauses)
            if (catalog.byId(id) != null)
              _CauseDetail(cause: catalog.byId(id)!),
        ],
        const SizedBox(height: 18),

        // 高级选项（默认折叠，不干扰主流程）
        _AdvancedSection(
          open: _advancedOpen,
          onToggle: () => setState(() => _advancedOpen = !_advancedOpen),
          difficulty: _difficulty,
          onDifficulty: (v) => setState(() => _difficulty = v),
          sourceType: _sourceType,
          onSourceType: (v) => setState(() => _sourceType = v),
          sourceYear: _sourceYear,
          onSourceYear: (v) => setState(() => _sourceYear = v),
          sourceCtrl: _source,
          noteCtrl: _note,
          onChanged: () => setState(() {}),
        ),
      ],
    );

    final preview = _PreviewPanel(stem: _stem.text);

    return Stack(
      children: [
        wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 3, child: form),
                  const VerticalDivider(width: 1),
                  Expanded(flex: 2, child: preview),
                ],
              )
            : form,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _SaveBar(
            blocking: blocking,
            warnings: warnings,
            saving: _saving,
            canSave: blocking.isEmpty && !_saving,
            onSave: () => _save(),
            onReset: _resetForm,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 子组件
// ─────────────────────────────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const _SectionTitle(this.text, {this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          text,
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 10),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: trailing!)),
        ],
      ],
    );
  }
}

class _KpSummary extends StatelessWidget {
  final KnowledgeBase kb;
  final String? primaryId;
  final List<String> secondaryIds;

  const _KpSummary({
    required this.kb,
    required this.primaryId,
    required this.secondaryIds,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (primaryId == null) {
      return Text(
        '还没选 —— 可以先保存，之后在错题本里补',
        style: TextStyle(
          fontSize: 11,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    final name = kb.byId[primaryId]?.name ?? primaryId!;
    return Text(
      '主：$name'
      '${secondaryIds.isEmpty ? "" : "　次：${secondaryIds.length} 个"}',
      style: const TextStyle(fontSize: 11.5),
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _CauseDetail extends StatelessWidget {
  final ErrorCause cause;

  const _CauseDetail({required this.cause});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(cause.name,
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(cause.definition,
              style: const TextStyle(fontSize: 12, height: 1.6)),
          if (cause.counterExamples.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('不算这一类的情况',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurfaceVariant,
                )),
            const SizedBox(height: 3),
            for (final e in cause.counterExamples)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text('· $e',
                    style: const TextStyle(fontSize: 11.5, height: 1.55)),
              ),
          ],
          if (cause.prescription != null) ...[
            const SizedBox(height: 8),
            Text('处方',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurfaceVariant,
                )),
            const SizedBox(height: 3),
            if (cause.prescription!.action.isNotEmpty)
              Text('做：${cause.prescription!.action}',
                  style: const TextStyle(fontSize: 11.5, height: 1.55)),
            if (cause.prescription!.notAction.isNotEmpty)
              Text('别做：${cause.prescription!.notAction}',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.55,
                    color: theme.colorScheme.error,
                  )),
          ],
        ],
      ),
    );
  }
}

class _AdvancedSection extends StatelessWidget {
  final bool open;
  final VoidCallback onToggle;
  final int difficulty;
  final ValueChanged<int> onDifficulty;
  final SourceType sourceType;
  final ValueChanged<SourceType> onSourceType;
  final int? sourceYear;
  final ValueChanged<int?> onSourceYear;
  final TextEditingController sourceCtrl;
  final TextEditingController noteCtrl;
  final VoidCallback onChanged;

  const _AdvancedSection({
    required this.open,
    required this.onToggle,
    required this.difficulty,
    required this.onDifficulty,
    required this.sourceType,
    required this.onSourceType,
    required this.sourceYear,
    required this.onSourceYear,
    required this.sourceCtrl,
    required this.noteCtrl,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(open ? Icons.expand_less : Icons.expand_more, size: 18),
                const SizedBox(width: 4),
                const Text('更多（难度 / 来源 / 笔记）',
                    style: TextStyle(fontSize: 12.5)),
              ],
            ),
          ),
        ),
        if (open) ...[
          const SizedBox(height: 6),
          const Text('难度', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            children: [
              for (final d in [1, 2, 3])
                ChoiceChip(
                  label: Text(d == 1 ? '基础' : (d == 2 ? '综合' : '拓展')),
                  selected: difficulty == d,
                  onSelected: (_) => onDifficulty(d),
                ),
            ],
          ),
          const SizedBox(height: 10),
          const Text('来源类型', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            children: [
              for (final s in SourceType.values)
                ChoiceChip(
                  label: Text(s.label),
                  selected: sourceType == s,
                  onSelected: (_) => onSourceType(s),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              SizedBox(
                width: 120,
                child: TextFormField(
                  initialValue: sourceYear?.toString() ?? '',
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: '年份',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => onSourceYear(int.tryParse(v)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: sourceCtrl,
                  onChanged: (_) => onChanged(),
                  decoration: const InputDecoration(
                    labelText: '来源（如「2023 年数学（一）真题」）',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: noteCtrl,
            minLines: 1,
            maxLines: 4,
            onChanged: (_) => onChanged(),
            decoration: const InputDecoration(
              labelText: '我的笔记',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ],
    );
  }
}

class _PreviewPanel extends StatelessWidget {
  final String stem;

  const _PreviewPanel({required this.stem});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final renderer = MathRendering.renderer;
    final hasMath = stem.contains(r'$');

    return Container(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 100),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('预览',
                  style: TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Text('渲染器：${renderer.name}',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: theme.colorScheme.onSurfaceVariant,
                  )),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: SingleChildScrollView(
              child: stem.trim().isEmpty
                  ? Text('开始输入后这里会实时渲染',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: theme.colorScheme.onSurfaceVariant,
                      ))
                  : renderer.renderMarkdown(stem),
            ),
          ),
          if (!hasMath)
            Text(
              '提示：用 \$...\$ 包住公式才会被识别为数学内容',
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class _SaveBar extends StatelessWidget {
  final List<DraftIssue> blocking;
  final List<DraftIssue> warnings;
  final bool saving;
  final bool canSave;
  final VoidCallback onSave;
  final VoidCallback onReset;

  const _SaveBar({
    required this.blocking,
    required this.warnings,
    required this.saving,
    required this.canSave,
    required this.onSave,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final first = blocking.isNotEmpty
        ? blocking.first.message
        : (warnings.isNotEmpty ? warnings.first.message : '可以保存');

    return Material(
      elevation: 6,
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
        child: Row(
          children: [
            Icon(
              blocking.isNotEmpty
                  ? Icons.error_outline
                  : (warnings.isNotEmpty ? Icons.info_outline : Icons.check_circle_outline),
              size: 17,
              color: blocking.isNotEmpty
                  ? theme.colorScheme.error
                  : (warnings.isNotEmpty
                      ? theme.colorScheme.onSurfaceVariant
                      : const Color(0xFF0CA678)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                first,
                style: TextStyle(
                  fontSize: 12,
                  color: blocking.isNotEmpty
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(onPressed: onReset, child: const Text('清空')),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: canSave ? onSave : null,
              icon: saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined, size: 17),
              label: Text(saving ? '保存中…' : '保存并继续录下一题'),
            ),
          ],
        ),
      ),
    );
  }
}
