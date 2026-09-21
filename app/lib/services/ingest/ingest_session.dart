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
import 'ingest_draft.dart';
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
  /// 调模型用的客户端。
  ///
  /// **可以为 null**：恢复一份草稿只需要"把结果摆回界面上"，
  /// 不需要发请求。用户完全可能在改完设置（甚至清空 Key）之后
  /// 才回来接着看上次的结果 —— 那时硬要一个 client 就变成"看不到结果"，
  /// 而这恰恰是最不该发生的。
  final LlmClient? client;

  /// 附件加载器（可注入 → 管道离线可测）。
  final AttachmentLoader loadAttachment;

  /// 查重。为 null 时不做查重（题库不可用）。
  final DuplicateProbe? findDuplicates;

  /// 来源清单（构造时定下，运行中不变）。
  final List<IngestSource> sources;

  /// [initialItems] 是**上一轮的既有结果**（从中断处续跑，见 T49）。
  ///
  /// 它按**来源路径**认领到 [sources] 上，所以条数不必与 [sources] 相等：
  /// 对不上时缺的来源会被补成 `pending`（也就是还会去跑），
  /// 而不是被悄悄漏掉。
  IngestSession({
    required this.client,
    required this.loadAttachment,
    this.findDuplicates,
    required List<IngestSource> sources,
    List<IngestItem> initialItems = const [],
  })  : sources = List.unmodifiable(sources),
        _items = List.of(initialItems) {
    _alignItems();
  }

  final List<IngestItem> _items;

  /// 当前结果。顺序与 [sources] 一致。
  List<IngestItem> get items => List.unmodifiable(_items);

  late LlmUsage _usage;
  LlmUsage get usage => _usage;

  /// 把 [_items] 与 [sources] 对齐，并从既有结果推出累计用量。幂等。
  ///
  /// ## 为什么不能"直接用传进来的那份结果"
  ///
  /// 上一版这里是 `if (_items.isEmpty) { 按 sources 造 }` —— 也就是
  /// **只用来源条数判定**。后果是：调用方给了 1 条结果、却给了 3 个来源时，
  /// 循环只走那 1 条，另外 2 个来源既不发请求也不报错，
  /// 界面上表现为"解析完了，就是题少了" —— 一个不会自己暴露的静默丢数据。
  ///
  /// 改成按路径认领之后，**任何没被结果覆盖的来源都会被补成 `pending`**，
  /// 于是最坏情况只是多花一次钱，而不是少导几道题。
  void _alignItems() {
    final byPath = <String, IngestItem>{
      for (final i in _items) i.source.path: i,
    };
    _items
      ..clear()
      ..addAll(sources.map((s) => byPath[s.path] ?? IngestItem(source: s)));

    // 累计用量从既有结果里**推**出来，而不是另外存一个数：
    // 续跑之后那个"这批花了多少"必须把上半场算进去，
    // 而两处各存一份迟早会对不上。
    _usage = _items.fold(const LlmUsage(), (a, i) => a + i.usage);
  }

  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  /// 请求取消。**不会**打断已经发出去的那一次调用 ——
  /// 当前来源跑完，剩下的标记为跳过（也就不会再花钱）。
  void cancel() => _cancelled = true;

  /// 当前进度的快照，可直接落盘（见 [IngestDraftStore]）。
  ///
  /// `running` 一律归一成 `pending`：正在跑的那个来源**没有拿到结果**，
  /// 崩溃后它就是"没完成"。见 [IngestDraft] 顶部的说明。
  IngestDraft snapshot({String model = '', DateTime? now}) => IngestDraft(
        items: [
          for (final i in _items)
            i.status == IngestStatus.running
                ? i.copyWith(status: IngestStatus.pending)
                : i,
        ],
        usage: _usage,
        model: model,
        savedAt: now,
      );

  /// 跑完全部来源。
  ///
  /// ## 已有结果的来源**不再重跑**
  ///
  /// 这是 T49 的全部意义：续跑时 `done` 的来源直接沿用，
  /// 既不重新发请求，也不重新计费。[IngestReport.done] 仍然把它算进去，
  /// 所以进度条与"已完成 N 个"不会看起来像少了一截。
  ///
  /// [onProgress] 在**每个来源开始前与结束后**各调一次，
  /// 这样进度条在慢调用期间也能显示"正在处理哪一个"，而不是卡在 0%。
  Future<IngestReport> run({
    void Function(IngestProgress)? onProgress,
  }) async {
    // 与来源清单对齐；既有结果按路径认领，认不到的补成 pending。
    // 幂等：正常情况下这一句什么都不改。
    _alignItems();

    // 落盘的 `running` 在恢复时已归一成 pending，但同一个会话被中断后
    // 直接再 run() 也可能留下 running —— 一并归一，避免它被当成"跑完了"
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].status == IngestStatus.running) {
        _items[i] = _items[i].copyWith(status: IngestStatus.pending);
      }
    }

    final notes = <String>[];

    void notify([String? current]) =>
        onProgress?.call(IngestProgress.of(_items, current: current));

    notify();

    if (client == null) {
      // 没客户端就一个请求都不发（也就一分钱不花），并**说出来**
      return IngestReport(
        total: _items.length,
        done: _items.where((i) => i.isDone).length,
        skipped: _items.where((i) => !i.isFinished).length,
        problemCount: _items.fold(0, (n, i) => n + i.problems.length),
        usage: _usage,
        notes: const ['当前没有可用的 AI 服务商配置，未发出任何请求。'],
      );
    }

    for (var i = 0; i < _items.length; i++) {
      // 已经拿到结果的来源：直接沿用，不重新花钱
      if (_items[i].isDone) continue;

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
        _usage = _usage + result.usage;
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
      usage: _usage,
      cancelled: _cancelled,
      notes: notes,
    );
  }

  /// 处理一个来源。
  ///
  /// [index] 只用于提示词里的"第几份"，所以由调用方传入 ——
  /// 不要在这里按路径反查下标：同一个文件被选中两次时那个反查会取到错的位置。
  Future<IngestItem> _processOne(IngestSource source, int index) async {
    final c = client;
    // run() 已经挡过一次。这里再挡一次是因为"没客户端却去调模型"
    // 会以 Null check 的形式炸在深层调用里，那条错误信息对用户毫无意义。
    if (c == null) throw StateError('没有可用的 AI 服务商配置，无法解析。');

    final attachment = await loadAttachment(source);

    final resp = await c.chat(ChatRequest(
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
}
