/// 批量导入页（M7）。
///
/// ## 这一页存在的理由
///
/// PC 版相对手机版的**唯一真正优势**：用户的全部学习资料都在这台机器上 ——
/// 真题 PDF、教材扫描件、以前拍的错题照片。手输一道题要 60 秒，
/// 一册真题集有几百道。不能让用户一道一道录。
///
/// ## 三步，而且每一步都让用户看得见
///
/// ```
/// 1. 选来源     文件夹 / 多张图片 / 多个 PDF
///               → 立刻给出：多少个文件、大约几页、大概花多少钱
///               → 立刻判断：当前模型**能不能读图片**（不能就拦在这里）
/// 2. 解析       逐个来源调用视觉模型，进度可中断
///               → 失败的那一条单独重试，不影响其它
/// 3. 核对       逐题勾选 / 编辑 / 看到"这题好像录过了"
///               → 批量入库 → 可选批量打标
/// ```
///
/// ## 一条贯穿全页的纪律：不静默
///
/// - 不会因为"模型不认识这个格式"就少发一个文件而不说
/// - 不会因为"这题好像重复"就悄悄跳过
/// - 不会因为"模型自己编了答案"就把答案留下（见 `ingest_extractor.dart`）
/// - 费用、进度、失败原因全部显示出来
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/breakpoints.dart';
import '../../core/math/math_renderer.dart';
import '../../core/platform/platform_services.dart';
import '../../core/providers.dart';
import '../../data/index/index_builder.dart';
import '../../data/markdown/problem_markdown.dart';
import '../../services/ingest/ingest_models.dart';
import '../../services/ingest/ingest_session.dart';
import '../../services/ingest/ingest_source_io.dart';
import '../../services/llm/dio_http_adapter.dart';
import '../../services/llm/llm_settings.dart';
import '../../services/llm/provider_registry.dart';
import '../../services/tagger/knowledge_tagger.dart';
import '../../services/tagger/tag_cache_store.dart';

class IngestPage extends ConsumerStatefulWidget {
  const IngestPage({super.key});

  @override
  ConsumerState<IngestPage> createState() => _IngestPageState();
}

class _IngestPageState extends ConsumerState<IngestPage> {
  List<IngestSource> _sources = const [];
  IngestSession? _session;
  IngestProgress? _progress;
  IngestReport? _report;

  bool _parsing = false;
  bool _saving = false;
  bool _tagging = false;
  String? _status;
  String? _error;

  /// 取消勾选的题。键：`<来源路径>#<题序号>`。
  ///
  /// 存"取消"而不是"选中"：默认**全选**（用户导入就是为了入库），
  /// 而重复题在结果出来时被自动取消勾选。
  final Set<String> _unchecked = {};

  /// 用户改过的题（覆盖提炼结果）。
  final Map<String, ExtractedProblem> _edited = {};

  /// 已经入库的题，留作"批量打标"的输入。
  final List<Problem> _saved = [];

  static String _key(String sourcePath, int index) => '$sourcePath#$index';

  // ───────────────────────────────────────────────────────────────────────
  // 第一步：选来源
  // ───────────────────────────────────────────────────────────────────────

  Future<void> _pick(Future<List<PickedFile>> Function() pick) async {
    try {
      final files = await pick();
      if (files.isEmpty || !mounted) return;
      final list = await sourcesFromPaths(files.map((f) => f.path));
      if (!mounted) return;
      setState(() {
        _sources = list;
        _resetResults();
        _error = list.isEmpty ? '选中的文件里没有可导入的图片或 PDF' : null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '选择文件失败：$e');
    }
  }

  void _resetResults() {
    _session = null;
    _progress = null;
    _report = null;
    _status = null;
    _unchecked.clear();
    _edited.clear();
    _saved.clear();
  }

  IngestEstimate _estimate(LlmConfig? cfg) => estimateIngest(
        _sources,
        model: cfg?.model ?? '',
        // 带上服务商的输出上限：偏低时要如实提示"一页题多会被截断"
        maxOutputTokens: cfg?.maxOutputTokens,
      );

  bool get _hasPdf => _sources.any((s) => s.isPdf);

  // ───────────────────────────────────────────────────────────────────────
  // 第二步：解析
  // ───────────────────────────────────────────────────────────────────────

  Future<void> _startParsing() async {
    final client = ref.read(ingestClientProvider);
    final cfg = ref.read(llmConfigProvider);

    if (client == null) {
      setState(() => _error = '还没有配置 AI 服务商（或配置不完整）。'
          '批量导入需要视觉模型，请先到「设置」里配置。');
      return;
    }
    final block = cfg?.visionBlockReason(needPdf: _hasPdf);
    if (block != null) {
      setState(() => _error = block);
      return;
    }

    final IngestSession session;
    try {
      final service = await ref.read(problemServiceProvider.future);
      if (!mounted) return;

      session = IngestSession(
        client: client,
        loadAttachment: loadAttachmentFromDisk,
        // 查重直接复用录入页那套（同一个指纹实现），
        // 于是"批量导入的题"和"手输的题"用的是同一把尺子
        findDuplicates: (fp) async {
          final hits = await service.findByFingerprint(fp);
          return hits.map((h) => h.id).toList();
        },
        sources: _sources,
      );
    } catch (e) {
      // 取服务 / 建会话失败也要**说出来**。早先这一段没有 try，
      // 异常会直接变成"未处理的异步错误"：按钮点下去什么都不发生，
      // 用户只会以为软件卡了 —— 与录入页那个"永远转圈"的问题同一类。
      if (mounted) setState(() => _error = '准备导入失败：$e');
      return;
    }

    setState(() {
      _session = session;
      _parsing = true;
      _error = null;
      _status = null;
      _unchecked.clear();
      _edited.clear();
      _saved.clear();
    });

    try {
      final report = await session.run(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _report = report;
        // 疑似重复的题默认**不勾选** —— 但留在列表里让用户自己判断，
        // 而不是替他删掉。他可能就是想把重复的题合并进来。
        for (final item in session.items) {
          for (var i = 0; i < item.problems.length; i++) {
            if (item.problems[i].isDuplicate) {
              _unchecked.add(_key(item.source.path, i));
            }
          }
        }
      });
    } finally {
      if (mounted) setState(() => _parsing = false);
    }
  }

  // ───────────────────────────────────────────────────────────────────────
  // 第三步：入库 + 打标
  // ───────────────────────────────────────────────────────────────────────

  /// 勾选中的题。
  List<(IngestItem, int, ExtractedProblem)> get _selectedProblems {
    final session = _session;
    if (session == null) return const [];
    final out = <(IngestItem, int, ExtractedProblem)>[];
    for (final item in session.items) {
      for (var i = 0; i < item.problems.length; i++) {
        final key = _key(item.source.path, i);
        if (_unchecked.contains(key)) continue;
        out.add((item, i, _edited[key] ?? item.problems[i]));
      }
    }
    return out;
  }

  Future<void> _saveSelected() async {
    final picked = _selectedProblems;
    if (picked.isEmpty) {
      setState(() => _error = '没有勾选任何题目');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
      _status = null;
    });

    var ok = 0;
    var dup = 0;
    var failed = 0;
    final problems = <Problem>[];

    try {
      final service = await ref.read(problemServiceProvider.future);
      final subject = ref.read(currentSubjectProvider).id;

      for (final (_, _, p) in picked) {
        try {
          final outcome = await service.save(p.toDraft(subject: subject));
          if (outcome.ok && outcome.problem != null) {
            ok++;
            problems.add(outcome.problem!);
          } else if (outcome.duplicates.isNotEmpty) {
            dup++;
          } else {
            failed++;
          }
        } catch (_) {
          failed++;
        }
      }

      if (!mounted) return;
      setState(() {
        _saved
          ..clear()
          ..addAll(problems);
        _status = '已入库 $ok 题'
            '${dup > 0 ? ' · $dup 题因重复被跳过' : ''}'
            '${failed > 0 ? ' · $failed 题写入失败' : ''}';
      });

      // 列表与角标要跟着变，否则用户回到错题本看不到刚导进去的题
      ref.invalidate(problemListProvider);
      ref.invalidate(reviewStatsProvider);
    } catch (e) {
      if (mounted) setState(() => _error = '入库失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 对已入库的题批量打标。
  ///
  /// 与录入页的「AI 标注」走**同一套**引擎（同一个缓存、同一份用量台账），
  /// 所以这里打过的题，在录入页再遇到会命中缓存不花钱。
  Future<void> _tagSaved() async {
    if (_saved.isEmpty) return;
    setState(() {
      _tagging = true;
      _error = null;
      _status = null;
    });

    // 声明在 try 之外，才能保证 `finally` 里一定关得掉
    DioHttpAdapter? adapter;
    try {
      final settings = await ref.read(llmSettingsProvider.future);
      final kb = await ref.read(knowledgeBaseProvider.future);
      final db = await ref.read(databaseProvider.future);
      final store = await ref.read(problemStoreProvider.future);

      final ledger = UsageLedger(db);
      // 自己拿适配器实例，好在结束时关掉连接池。
      // 交给 `buildTagger` 内部新建的话就没人引用它了，
      // `DioHttpAdapter.close()` 会永远没有调用者（见该方法的说明）。
      adapter = DioHttpAdapter();
      final tagger = await buildTagger(
        knowledge: kb,
        settings: settings,
        http: adapter,
        cache: SqliteTagCache(db: db, model: settings.toConfig().model),
        onUsage: (u) => ledger.record(provider: settings.providerId, usage: u),
      );
      if (tagger == null) {
        adapter.close();
        setState(() => _error = 'AI 配置不完整，无法打标。请先到「设置」里配置。');
        return;
      }

      final threshold = settings.toConfig().confidenceThreshold;
      var tagged = 0;
      var needReview = 0;
      final updated = <Problem>[];

      for (var i = 0; i < _saved.length; i++) {
        final p = _saved[i];
        if (mounted) {
          setState(() => _status =
              '打标中 ${i + 1} / ${_saved.length}（${p.id}）');
        }
        final outcome = await tagger.tag(p);
        final r = outcome.result;
        if (r == null) {
          updated.add(p);
          continue;
        }
        final applied = applyTagResult(
          p,
          r,
          confidenceThreshold: threshold,
        );
        await store.save(applied);
        updated.add(applied);
        tagged++;
        if (applied.needsReview) needReview++;
      }

      // 索引只重建**一次**：`rebuild()` 按 mtime 跳过没变的文件，
      // 所以放在循环里逐题调用等于白扫 N 遍题库
      await IndexBuilder(db: db, store: store, knowledge: kb).rebuild();

      if (!mounted) return;
      setState(() {
        _saved
          ..clear()
          ..addAll(updated);
        _status = '已打标 $tagged 题'
            '${needReview > 0 ? ' · 其中 $needReview 题置信度偏低，建议人工确认' : ''}';
      });
      ref.invalidate(problemListProvider);
      ref.invalidate(reviewStatsProvider);
    } catch (e) {
      if (mounted) setState(() => _error = '打标失败：$e');
    } finally {
      // 无论成功失败都要关掉连接池
      adapter?.close();
      if (mounted) setState(() => _tagging = false);
    }
  }

  // ───────────────────────────────────────────────────────────────────────
  // 界面
  // ───────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(llmConfigProvider);
    final settingsAsync = ref.watch(llmSettingsProvider);
    final compact = BreakpointScope.of(context) == LayoutBreakpoint.compact;

    return Column(
      children: [
        _Toolbar(
          compact: compact,
          busy: _parsing || _saving || _tagging,
          hasSources: _sources.isNotEmpty,
          onPickFolder: () => _pick(PlatformServices.instance.imageSource.pickDirectory),
          onPickImages: () => _pick(PlatformServices.instance.imageSource.pickMultipleImages),
          onPickPdfs: () => _pick(PlatformServices.instance.imageSource.pickPdfs),
          onClear: () => setState(() {
            _sources = const [];
            _resetResults();
          }),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
            children: [
              _SettingsGate(settings: settingsAsync, cfg: cfg, hasPdf: _hasPdf),
              if (_error != null) ...[
                const SizedBox(height: 12),
                _Banner(text: _error!, tone: _BannerTone.error),
              ],
              if (_sources.isNotEmpty) ...[
                const SizedBox(height: 12),
                _EstimateCard(
                  estimate: _estimate(cfg),
                  sources: _sources,
                ),
                const SizedBox(height: 12),
                _ParseControls(
                  parsing: _parsing,
                  progress: _progress,
                  report: _report,
                  blocked: cfg == null ||
                      cfg.visionBlockReason(needPdf: _hasPdf) != null,
                  onStart: _startParsing,
                  onCancel: () => _session?.cancel(),
                ),
              ],
              if (_session != null) ...[
                const SizedBox(height: 16),
                _ResultsHeader(
                  selected: _selectedProblems.length,
                  total: _session!.items
                      .fold<int>(0, (n, i) => n + i.problems.length),
                  saving: _saving,
                  status: _status,
                  savedCount: _saved.length,
                  tagging: _tagging,
                  onSave: _saveSelected,
                  onTag: _tagSaved,
                  onSelectAll: () => setState(_unchecked.clear),
                  onSelectNone: () => setState(() {
                    for (final item in _session!.items) {
                      for (var i = 0; i < item.problems.length; i++) {
                        _unchecked.add(_key(item.source.path, i));
                      }
                    }
                  }),
                ),
                const SizedBox(height: 8),
                for (final item in _session!.items)
                  _SourceSection(
                    item: item,
                    unchecked: _unchecked,
                    edited: _edited,
                    onToggle: (index, checked) => setState(() {
                      final k = _key(item.source.path, index);
                      if (checked) {
                        _unchecked.remove(k);
                      } else {
                        _unchecked.add(k);
                      }
                    }),
                    onEdit: (index) => _openEditor(item, index),
                  ),
              ],
              if (_sources.isEmpty && _session == null)
                const Padding(
                  padding: EdgeInsets.only(top: 60),
                  child: _EmptyHint(),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openEditor(IngestItem item, int index) async {
    final key = _key(item.source.path, index);
    final current = _edited[key] ?? item.problems[index];
    final result = await showDialog<ExtractedProblem>(
      context: context,
      builder: (_) => _ProblemEditor(problem: current),
    );
    if (result == null || !mounted) return;
    setState(() => _edited[key] = result);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 顶部工具条
// ─────────────────────────────────────────────────────────────────────────────

class _Toolbar extends StatelessWidget {
  final bool compact;
  final bool busy;
  final bool hasSources;
  final VoidCallback onPickFolder;
  final VoidCallback onPickImages;
  final VoidCallback onPickPdfs;
  final VoidCallback onClear;

  const _Toolbar({
    required this.compact,
    required this.busy,
    required this.hasSources,
    required this.onPickFolder,
    required this.onPickImages,
    required this.onPickPdfs,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final buttons = <Widget>[
      FilledButton.icon(
        onPressed: busy ? null : onPickFolder,
        icon: const Icon(Icons.folder_open, size: 18),
        label: const Text('选择文件夹'),
      ),
      OutlinedButton.icon(
        onPressed: busy ? null : onPickImages,
        icon: const Icon(Icons.image_outlined, size: 18),
        label: const Text('选图片'),
      ),
      OutlinedButton.icon(
        onPressed: busy ? null : onPickPdfs,
        icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
        label: const Text('选 PDF'),
      ),
      if (hasSources)
        TextButton(onPressed: busy ? null : onClear, child: const Text('清空')),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: buttons,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AI 配置闸门
// ─────────────────────────────────────────────────────────────────────────────

class _SettingsGate extends StatelessWidget {
  final AsyncValue<LlmSettings> settings;
  final LlmConfig? cfg;
  final bool hasPdf;

  const _SettingsGate({
    required this.settings,
    required this.cfg,
    required this.hasPdf,
  });

  @override
  Widget build(BuildContext context) {
    if (settings.isLoading) {
      return const _Banner(text: '正在读取 AI 配置…', tone: _BannerTone.info);
    }
    if (cfg == null) {
      return const _Banner(
        text: '批量导入需要 AI 视觉模型：由它把扫描件读成文字，App 再整理进题库。'
            '请先到「设置」里选一个服务商并填 API Key。'
            '\n（DeepSeek 是纯文本模型，不能读图片；Claude / Gemini / '
            '通义 VL / 智谱 4V / Kimi 视觉版可以。）',
        tone: _BannerTone.warning,
      );
    }

    final block = cfg!.visionBlockReason(needPdf: hasPdf);
    if (block != null) {
      return _Banner(text: block, tone: _BannerTone.error);
    }
    final warn = cfg!.visionWarning(needPdf: hasPdf);
    if (warn != null) {
      return _Banner(text: warn, tone: _BannerTone.warning);
    }
    return _Banner(
      text: '当前使用 ${cfg!.spec?.label ?? cfg!.providerId} · ${cfg!.model}'
          '，可以读取${hasPdf ? '图片与 PDF' : '图片'}。',
      tone: _BannerTone.info,
    );
  }
}

enum _BannerTone { info, warning, error }

class _Banner extends StatelessWidget {
  final String text;
  final _BannerTone tone;

  const _Banner({required this.text, required this.tone});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg, icon) = switch (tone) {
      _BannerTone.info => (
          scheme.surfaceContainerHighest,
          scheme.onSurfaceVariant,
          Icons.info_outline,
        ),
      _BannerTone.warning => (
          const Color(0xFFFFF6E5),
          const Color(0xFF8A5A00),
          Icons.warning_amber_outlined,
        ),
      _BannerTone.error => (
          scheme.errorContainer,
          scheme.onErrorContainer,
          Icons.error_outline,
        ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: fg),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12.5, height: 1.6, color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 预估
// ─────────────────────────────────────────────────────────────────────────────

class _EstimateCard extends StatelessWidget {
  final IngestEstimate estimate;
  final List<IngestSource> sources;

  const _EstimateCard({required this.estimate, required this.sources});

  /// 清单里最多列几个。
  ///
  /// 不列全：用户选了一个几百个文件的文件夹时，把清单全部铺出来
  /// 会把"开始解析"按钮挤到屏幕外 —— 而那才是他下一步要点的东西。
  static const int _maxListed = 20;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final listed = sources.take(_maxListed).toList();
    final hidden = sources.length - listed.length;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.calculate_outlined, size: 17),
                const SizedBox(width: 8),
                Text('导入前预估', style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '（估算值，实际以服务商返回为准）',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(estimate.summary, style: theme.textTheme.bodyMedium),
            if (estimate.notes.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (final n in estimate.notes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('· ', style: TextStyle(fontSize: 12.5)),
                      Expanded(
                        child: Text(
                          n,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.6,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 8),
            Text('来源清单', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            for (final s in listed)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  children: [
                    Icon(
                      s.isPdf
                          ? Icons.picture_as_pdf_outlined
                          : Icons.image_outlined,
                      size: 13,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    Text(
                      s.sizeText,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            if (hidden > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '…… 还有 $hidden 个',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 解析控制
// ─────────────────────────────────────────────────────────────────────────────

class _ParseControls extends StatelessWidget {
  final bool parsing;
  final IngestProgress? progress;
  final IngestReport? report;
  final bool blocked;
  final VoidCallback onStart;
  final VoidCallback onCancel;

  const _ParseControls({
    required this.parsing,
    required this.progress,
    required this.report,
    required this.blocked,
    required this.onStart,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (parsing)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const Icon(Icons.play_circle_outline, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    parsing
                        ? (progress?.text ?? '正在解析…')
                        : (report?.summary ?? '准备就绪'),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                if (parsing)
                  TextButton(onPressed: onCancel, child: const Text('取消'))
                else
                  FilledButton(
                    onPressed: blocked ? null : onStart,
                    child: const Text('开始解析'),
                  ),
              ],
            ),
            if (parsing) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(value: progress?.fraction ?? 0),
            ],
            if (report != null && report!.notes.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (final n in report!.notes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '· $n',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.6,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 结果
// ─────────────────────────────────────────────────────────────────────────────

class _ResultsHeader extends StatelessWidget {
  final int selected;
  final int total;
  final bool saving;
  final bool tagging;
  final String? status;
  final int savedCount;
  final VoidCallback onSave;
  final VoidCallback onTag;
  final VoidCallback onSelectAll;
  final VoidCallback onSelectNone;

  const _ResultsHeader({
    required this.selected,
    required this.total,
    required this.saving,
    required this.tagging,
    required this.status,
    required this.savedCount,
    required this.onSave,
    required this.onTag,
    required this.onSelectAll,
    required this.onSelectNone,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = saving || tagging;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('已选 $selected / $total 题',
                    style: theme.textTheme.titleSmall),
                TextButton(
                    onPressed: busy ? null : onSelectAll,
                    child: const Text('全选')),
                TextButton(
                    onPressed: busy ? null : onSelectNone,
                    child: const Text('全不选')),
                FilledButton.icon(
                  onPressed: busy || selected == 0 ? null : onSave,
                  icon: saving
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_alt, size: 18),
                  label: Text(saving ? '入库中…' : '批量入库'),
                ),
                OutlinedButton.icon(
                  onPressed: busy || savedCount == 0 ? null : onTag,
                  icon: tagging
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome_outlined, size: 18),
                  label: Text(
                    savedCount == 0 ? '批量打标' : '批量打标（$savedCount 题）',
                  ),
                ),
              ],
            ),
            if (status != null) ...[
              const SizedBox(height: 8),
              Text(status!, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 4),
            Text(
              '打标用的是与录入页同一套引擎（同一份缓存与用量台账），'
              '重复标注不会重复花钱。',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceSection extends StatelessWidget {
  final IngestItem item;
  final Set<String> unchecked;
  final Map<String, ExtractedProblem> edited;
  final void Function(int index, bool checked) onToggle;
  final void Function(int index) onEdit;

  const _SourceSection({
    required this.item,
    required this.unchecked,
    required this.edited,
    required this.onToggle,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final duplicated =
        item.problems.where((p) => p.isDuplicate).length;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        initiallyExpanded: item.problems.isNotEmpty,
        title: Text(item.source.name, style: theme.textTheme.titleSmall),
        subtitle: Text(
          '${item.source.kind.label} · ${item.source.sizeText} · '
          '${item.status.label}'
          '${item.problems.isEmpty ? '' : ' · ${item.problems.length} 题'}'
          '${duplicated > 0 ? ' · 疑似重复 $duplicated' : ''}',
          style: theme.textTheme.bodySmall,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          if (item.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                item.error!,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: item.status == IngestStatus.failed
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (item.isEmptyResult)
            Text(
              '这一份里没有识别到试题。封面 / 目录 / 答案页属于正常情况。',
              style: theme.textTheme.bodySmall,
            ),
          for (var i = 0; i < item.problems.length; i++)
            _ProblemCard(
              problem: edited[_IngestPageState._key(item.source.path, i)] ??
                  item.problems[i],
              checked:
                  !unchecked.contains(_IngestPageState._key(item.source.path, i)),
              onToggle: (v) => onToggle(i, v),
              onEdit: () => onEdit(i),
            ),
        ],
      ),
    );
  }
}

class _ProblemCard extends StatelessWidget {
  final ExtractedProblem problem;
  final bool checked;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;

  const _ProblemCard({
    required this.problem,
    required this.checked,
    required this.onToggle,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final renderer = MathRendering.renderer;
    final stem = problem.stem.length > 200
        ? '${problem.stem.substring(0, 200)}…'
        : problem.stem;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Card 本身就是 Material，所以 CheckboxListTile 放在里面不会触发
          // "ink splash 不可见"那个断言
          CheckboxListTile(
            value: checked,
            onChanged: (v) => onToggle(v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            title: Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _Chip(text: problem.qtype.label),
                _Chip(text: '难度 ${problem.difficulty}'),
                if (problem.source != null) _Chip(text: problem.source!),
                if (problem.confidence != null)
                  _Chip(text: '把握 ${(problem.confidence! * 100).round()}%'),
                if (problem.isDuplicate)
                  _Chip(
                    text: '题库里已有：${problem.duplicateIds.join('、')}',
                    tone: _ChipTone.warn,
                  ),
              ],
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: renderer.renderMarkdown(
                stem,
                options: const MathRenderOptions(fontSize: 13),
              ),
            ),
          ),
          if (problem.options.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < problem.options.length; i++)
                    renderer.renderMarkdown(
                      '${String.fromCharCode(65 + i)}. ${problem.options[i]}',
                      options: const MathRenderOptions(fontSize: 12.5),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    problem.answer == null && problem.solution == null
                        ? '原文没有答案与解析（App 不会替你解）'
                        : '含答案${problem.solution != null ? '与解析' : ''}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                TextButton.icon(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('编辑'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _ChipTone { normal, warn }

class _Chip extends StatelessWidget {
  final String text;
  final _ChipTone tone;

  const _Chip({required this.text, this.tone = _ChipTone.normal});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warn = tone == _ChipTone.warn;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: warn
            ? const Color(0xFFFFF0D6)
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: warn
              ? const Color(0xFF8A5A00)
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 编辑对话框
// ─────────────────────────────────────────────────────────────────────────────

/// 逐题修正。
///
/// 只开放**最可能被 OCR 读错**的字段：题干、选项、答案、解析、题型、难度。
/// 出处、知识点那些留给录入页 —— 核对阶段的目标是"看着原图把文字改对"，
/// 不是把整张表单重填一遍。
class _ProblemEditor extends StatefulWidget {
  final ExtractedProblem problem;

  const _ProblemEditor({required this.problem});

  @override
  State<_ProblemEditor> createState() => _ProblemEditorState();
}

class _ProblemEditorState extends State<_ProblemEditor> {
  late final TextEditingController _stem;
  late final TextEditingController _options;
  late final TextEditingController _answer;
  late final TextEditingController _solution;
  late QuestionType _qtype;
  late int _difficulty;

  @override
  void initState() {
    super.initState();
    _stem = TextEditingController(text: widget.problem.stem);
    _options = TextEditingController(text: widget.problem.options.join('\n'));
    _answer = TextEditingController(text: widget.problem.answer ?? '');
    _solution = TextEditingController(text: widget.problem.solution ?? '');
    _qtype = widget.problem.qtype;
    _difficulty = widget.problem.difficulty;
  }

  @override
  void dispose() {
    _stem.dispose();
    _options.dispose();
    _answer.dispose();
    _solution.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('修正这道题'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('题干（Markdown + LaTeX，行内公式用 \$...\$）',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              TextField(
                controller: _stem,
                minLines: 3,
                maxLines: 10,
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Text('题型', style: TextStyle(fontSize: 12)),
                  const SizedBox(width: 10),
                  for (final t in QuestionType.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(t.label),
                        selected: _qtype == t,
                        onSelected: (_) => setState(() => _qtype = t),
                      ),
                    ),
                  const SizedBox(width: 12),
                  const Text('难度', style: TextStyle(fontSize: 12)),
                  const SizedBox(width: 10),
                  for (var d = 1; d <= 3; d++)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text('$d'),
                        selected: _difficulty == d,
                        onSelected: (_) => setState(() => _difficulty = d),
                      ),
                    ),
                ],
              ),
              if (_qtype == QuestionType.choice) ...[
                const SizedBox(height: 14),
                const Text('选项（一行一个，不要写 A. 前缀）',
                    style: TextStyle(fontSize: 12)),
                const SizedBox(height: 6),
                TextField(
                  controller: _options,
                  minLines: 2,
                  maxLines: 8,
                  decoration:
                      const InputDecoration(border: OutlineInputBorder()),
                ),
              ],
              const SizedBox(height: 14),
              const Text('答案（原文没有就留空 —— 不要自己解）',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              TextField(
                controller: _answer,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
              const SizedBox(height: 14),
              const Text('解析（原文没有就留空）', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              TextField(
                controller: _solution,
                minLines: 2,
                maxLines: 8,
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final stem = _stem.text.trim();
            if (stem.isEmpty) return;
            Navigator.of(context).pop(widget.problem.copyWith(
              stem: stem,
              qtype: _qtype,
              difficulty: _difficulty,
              options: _qtype == QuestionType.choice
                  ? _options.text
                      .split('\n')
                      .map((s) => s.trim())
                      .where((s) => s.isNotEmpty)
                      .toList()
                  : const [],
              answer: _answer.text.trim(),
              solution: _solution.text.trim(),
            ));
          },
          child: const Text('保存修改'),
        ),
      ],
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Icon(Icons.folder_open_outlined,
            size: 42, color: theme.colorScheme.outline),
        const SizedBox(height: 14),
        Text('选一个文件夹，或者挑几张图片 / 几个 PDF',
            style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Text(
          '目录会递归扫描（最多 6 层）。\n'
          '扫描件、手机拍的照片、真题 PDF 都可以。\n'
          '解析由云端视觉模型完成 —— 请先确认上面的配置提示是绿色/蓝色的。',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
