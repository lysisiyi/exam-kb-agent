/// 批量导入的编排：逐个来源调用视觉模型 → 解析 → 查重。
///
/// ## 为什么是"逐个"而不是并发
///
/// 一次导入可能上百个来源。并发发出去有三个问题：
/// 1. **撞限流**：多数服务商对每分钟请求数有硬限制，并发只会换来一串 429
///    和退避等待，总耗时未必更短
/// 2. **失败时无法解释**：`IngestItem` 的粒度是"这一个来源怎么了"，
///    并发下错误的归属会变得模糊
/// 3. **取消耗钱停不下来**：用户按下取消时，一批已经发出去的请求照样计费
///
/// 串行的代价是慢，但进度条是**诚实**的 —— 用户能看见第几个、还能按取消。
/// 真嫌慢可以在 V2 加一个"并发度"设置并如实说明限流风险。
///
/// ## 为什么默认只试一次
///
/// `LlmClient` 内部已经对网络类错误做了退避重试。而对"模型输出不是 JSON"
/// 这类失败，再试一次要**把整张图片重新发一遍** —— 那就是双倍的费用。
/// BYOK 模式下花钱的是用户，所以这里默认不自动重试，
/// 由用户在核对界面上对失败的那一条手动重试。
library;

import 'dart:async';

import '../llm/llm_client.dart';
import 'ingest_extractor.dart';
import 'ingest_models.dart';
import 'ingest_prompt.dart';

/// 读取一个来源的附件内容。
typedef AttachmentLoader = Future<ChatAttachment> Function(IngestSource source);

/// 查重：给定指纹，返回题库里已存在的题目 id。
typedef DuplicateProbe = Future<List<String>> Function(String fingerprint);

/// 一次导入的汇总。
class IngestReport {
  final int total;
  final int done;
  final int failed;
  final int skipped;
  final int problemCount;
  final int duplicateCount;

  /// 累计用量（用于展示"这批花了多少"）。
  final LlmUsage usage;

  final bool cancelled;

  /// 各来源的问题汇总（去重后的可读文本）。
  final List<String> notes;

  const IngestReport({
    this.total = 0,
    this.done = 0,
    this.failed = 0,
    this.skipped = 0,
    this.problemCount = 0,
    this.duplicateCount = 0,
    this.usage = const LlmUsage(),
    this.cancelled = false,
    this.notes = const [],
  });

  String get summary {
    final parts = <String>[
      '处理 $total 个来源',
      '成功 $done',
      if (failed > 0) '失败 $failed',
      if (skipped > 0) '跳过 $skipped',
      '解析出 $problemCount 题',
      if (duplicateCount > 0) '其中疑似重复 $duplicateCount',
      if (cancelled) '已取消',
    ];
    return parts.join(' · ');
  }
}

/// 一次批量导入会话。
class IngestSession {
  final LlmClient client;

  /// 附件加载器（可注入 → 管道离线可测）。
  final AttachmentLoader loadAttachment;

  /// 查重。为 null 时不做查重（题库不可用）。
  final DuplicateProbe? findDuplicates;

  /// 来源清单（构造时定下，运行中不变）。
  final List<IngestSource> sources;

  IngestSession({
    required this.client,
    required this.loadAttachment,
    this.findDuplicates,
    required List<IngestSource> sources,
  }) : sources = List.unmodifiable(sources);

  final List<IngestItem> _items = [];

  /// 当前结果。顺序与 [sources] 一致。
  List<IngestItem> get items => List.unmodifiable(_items);

  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  /// 请求取消。**不会**打断已经发出去的那一次调用 ——
  /// 当前来源跑完，剩下的标记为跳过（也就不会再花钱）。
  void cancel() => _cancelled = true;

  /// 跑完全部来源。
  ///
  /// [onProgress] 在**每个来源开始前与结束后**各调一次，
  /// 这样进度条在慢调用期间也能显示"正在处理哪一个"，而不是卡在 0%。
  Future<IngestReport> run({
    void Function(IngestProgress)? onProgress,
  }) async {
    _items
      ..clear()
      ..addAll(sources.map((s) => IngestItem(source: s)));

    var usage = const LlmUsage();
    final notes = <String>[];

    void notify([String? current]) {
      onProgress?.call(IngestProgress(
        total: _items.length,
        finished: _items.where(_isFinished).length,
        failed: _items.where((i) => i.status == IngestStatus.failed).length,
        problemCount: _items.fold(0, (n, i) => n + i.problems.length),
        current: current,
      ));
    }

    notify();

    for (var i = 0; i < _items.length; i++) {
      if (_cancelled) {
        _items[i] = _items[i].copyWith(status: IngestStatus.skipped);
        continue;
      }

      final source = _items[i].source;
      _items[i] = _items[i].copyWith(status: IngestStatus.running);
      notify(source.name);

      try {
        final result = await _processOne(source, i);
        _items[i] = result;
        usage = usage + result.usage;
      } on LlmException catch (e) {
        _items[i] = _items[i].copyWith(
          status: IngestStatus.failed,
          error: '${e.message}\n建议：${e.kind.advice}',
        );
      } catch (e) {
        _items[i] = _items[i].copyWith(
          status: IngestStatus.failed,
          error: '$e',
        );
      }

      notify();
    }

    // 取消时上面那些 `continue` 不会各自 notify，所以最后补一次 ——
    // 否则用户按了取消，界面会停在"处理到一半"的进度上不动。
    notify();

    // 汇总
    final done = _items.where((i) => i.status == IngestStatus.done).length;
    final failed = _items.where((i) => i.status == IngestStatus.failed).length;
    final skipped = _items.where((i) => i.status == IngestStatus.skipped).length;
    final problems = [for (final i in _items) ...i.problems];

    if (failed > 0) {
      notes.add('有 $failed 个来源失败。失败**不会**产生费用之外的副作用，'
          '可以在结果列表里逐条重试。');
    }
    final empty = _items.where((i) => i.isEmptyResult).length;
    if (empty > 0) {
      notes.add('$empty 个来源没有识别到试题（封面 / 目录 / 答案页属于正常情况）。');
    }

    return IngestReport(
      total: _items.length,
      done: done,
      failed: failed,
      skipped: skipped,
      problemCount: problems.length,
      duplicateCount: problems.where((p) => p.isDuplicate).length,
      usage: usage,
      cancelled: _cancelled,
      notes: notes,
    );
  }

  /// 处理一个来源。
  ///
  /// [index] 只用于提示词里的"第几份"，所以由调用方传入 ——
  /// 不要在这里按路径反查下标：同一个文件被选中两次时那个反查会取到错的位置。
  Future<IngestItem> _processOne(IngestSource source, int index) async {
    final attachment = await loadAttachment(source);

    final resp = await client.chat(ChatRequest(
      system: kIngestSystemPrompt,
      user: ingestUserPrompt(
        sourceName: source.name,
        index: index,
        total: sources.length,
      ),
      attachments: [attachment],
      // 提炼要的是"照着抄"，温度压到 0
      temperature: 0.0,
      jsonMode: true,
      // 一页可能有 2–3 道大题，每题含题干+答案+解析。
      // 给足输出空间，避免 JSON 被截断（截断会表现为"解析失败"，
      // 而真实原因是 max_tokens 太小 —— 那种误诊很费时间）
      //
      // ⚠️ 实际发出去的值会被 `LlmClient` 收进服务商的硬上限
      // （见 `ProviderSpec.maxOutputTokens`）：智谱视觉模型只收 1024。
      maxTokens: 8192,
    ));

    final outcome = IngestExtractor.parse(resp.text, sourceName: source.name);
    final warnings = [...outcome.warnings];

    // 输出被截断：一条**真实的静默丢题**通道。
    //
    // 截断本身不报错，`RobustJson` 会救回能解析的部分，于是表现为
    // "这一页只有 1 道题"外加一句解析层的提示。所以先把真实原因说清楚，
    // 再让解析层的提示跟在后面。
    //
    // ⚠️ 实测（2026-09-18，智谱 glm-4v-flash，660 线代 p4-p6）每页只进来
    // 1 道题，但 `finish_reason` 是 `stop`、输出只用了 567/1024 token ——
    // 那批数据丢失的真因是**顶层数组被当成单题**（见 `IngestExtractor`
    // 传的 `acceptArray`）。截断是另一条通道，同样要报，
    // 但不该拿它解释那批数据。
    if (resp.truncated) {
      warnings.insert(
        0,
        '模型输出被截断（达到输出上限），这一页可能还有题没导入。'
        '建议换输出上限更大的模型，或把一页拆成多张图分别导入。',
      );
    }

    var problems = outcome.problems;
    if (problems.isNotEmpty) {
      problems = await _annotateDuplicates(problems);
    }

    final item = IngestItem(
      source: source,
      status: IngestStatus.done,
      problems: problems,
      usage: resp.usage,
    );

    // 解析层的问题（丢弃了没有题干的条目、模型没声明答案来源……）
    // 归到这一条上，让用户在它旁边就能看到
    if (warnings.isNotEmpty) {
      return item.copyWith(error: warnings.join('\n'));
    }
    return item;
  }

  /// 给每道题标上"题库里已存在同题干的题目"。
  ///
  /// 查重失败**不能**让解析白做 —— 那只是少一层提示，
  /// 用户仍然可以在核对界面看到内容并自己判断。
  Future<List<ExtractedProblem>> _annotateDuplicates(
    List<ExtractedProblem> problems,
  ) async {
    final probe = findDuplicates;
    if (probe == null) return problems;

    final out = <ExtractedProblem>[];
    for (final p in problems) {
      if (p.fingerprint.isEmpty) {
        out.add(p);
        continue;
      }
      try {
        final dup = await probe(p.fingerprint);
        out.add(dup.isEmpty ? p : p.copyWith(duplicateIds: dup));
      } catch (_) {
        out.add(p);
      }
    }
    return out;
  }

  static bool _isFinished(IngestItem i) =>
      i.status == IngestStatus.done ||
      i.status == IngestStatus.failed ||
      i.status == IngestStatus.skipped;
}
