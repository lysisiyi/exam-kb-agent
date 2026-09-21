/// 批量导入的数据模型。
///
/// ## 这一层为什么单独抽出来
///
/// 批量导入的**全部复杂逻辑**（选文件、解析、查重、估算、进度、取消）
/// 都不需要网络，也不需要界面。把它们放在纯 Dart 类型上，
/// 就能用假 HTTP 适配器把整条管道离线测一遍 —— 不花 token、结果可复现。
/// 界面只负责把 `IngestItem` 画出来。
///
/// 与 `services/tagger/` 的分工：这一层只管**内容**
/// （题干 / 答案 / 解析 / 题型 / 难度），**不做知识点标注** ——
/// 知识点有专门的召回 + 候选集 + 置信度门禁，见 `KnowledgeTagger`。
/// 把两件事混在一次调用里会让提炼 prompt 塞进 141 个叶子节点，
/// 既贵又更容易出错。
library;

import 'package:path/path.dart' as p;

import '../../data/markdown/problem_markdown.dart';
import '../../domain/fingerprint.dart';
import '../../domain/problem_draft.dart';
import '../llm/llm_client.dart';

/// 来源文件的种类。
enum IngestSourceKind {
  image,
  pdf;

  String get label => this == IngestSourceKind.pdf ? 'PDF' : '图片';
}

/// 支持的图片扩展名 → MIME。
///
/// ⚠️ MIME 必须给对：三家协议的多模态字段都要求 `media_type`，
/// 给错了服务商会直接 400，而错误信息通常不会说"你的 MIME 错了"。
const Map<String, String> kImageMimeByExtension = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.bmp': 'image/bmp',
  '.gif': 'image/gif',
  '.tif': 'image/tiff',
  '.tiff': 'image/tiff',
};

/// 单个来源的大小上限（字节）。
///
/// 为什么是 8 MiB：Gemini 的 `inline_data` 请求体总计上限约 20 MB
/// （base64 后膨胀约 4/3，即原始约 15 MB），而多家服务商对单张图片
/// 另有 5–10 MB 的限制。取 8 MiB 是这些约束里最保守的一个，
/// 且按"每页扫描件 1–3 MB"算，正常资料不会碰到。
const int kMaxImageBytes = 8 * 1024 * 1024;

/// 单个 PDF 的大小上限（字节）。
///
/// **V1 不拆分 PDF**：本地拆分需要 pdfium（+10–15 MB 包体），
/// 所以整个 PDF 作为**一个**附件发出去。这带来两个后果，都必须让用户知道：
/// 1. 文件太大就发不出去 → 这里设上限并提前拦下（而不是让服务商报 413）
/// 2. 页数太多时模型的输出会被输出 token 上限截断 → 见 [kPdfPageWarningThreshold]
const int kMaxPdfBytes = 15 * 1024 * 1024;

/// 超过这个页数就提醒用户"整份发过去可能被截断"。
///
/// V1 读不出真实页数（不解析 PDF），所以用字节数反推一个粗略页数：
/// 扫描件约 200–400 KB/页。宁可提醒得多一点，也不要让用户以为
/// 一份 60 页的真题集已经全导进去了。
const int kPdfPageWarningThreshold = 20;

/// 从路径推 MIME。认不出来返回 null。
String? mimeForPath(String path) {
  final ext = p.extension(path).toLowerCase();
  if (ext == '.pdf') return 'application/pdf';
  return kImageMimeByExtension[ext];
}

/// 一个待解析的来源文件。
class IngestSource {
  final String path;

  /// 文件名（展示用）。
  final String name;

  final int sizeBytes;

  final IngestSourceKind kind;

  const IngestSource({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.kind,
  });

  /// 从路径构造。扩展名不认识时返回 null（调用方应当跳过并告知用户）。
  static IngestSource? fromPath(String path, {int? sizeBytes}) {
    final mime = mimeForPath(path);
    if (mime == null) return null;
    return IngestSource(
      path: path,
      name: p.basename(path),
      sizeBytes: sizeBytes ?? 0,
      kind: mime == 'application/pdf'
          ? IngestSourceKind.pdf
          : IngestSourceKind.image,
    );
  }

  bool get isPdf => kind == IngestSourceKind.pdf;

  String get sizeText => formatBytes(sizeBytes);

  /// 估算页数。图片恒为 1；PDF 用体积粗估（见 [kPdfPageWarningThreshold]）。
  int get estimatedPages {
    if (!isPdf) return 1;
    final n = (sizeBytes / (300 * 1024)).ceil();
    return n < 1 ? 1 : n;
  }

  /// 序列化（草稿落盘用，见 T49）。
  Map<String, dynamic> toJson() => {
        'path': path,
        'name': name,
        'size': sizeBytes,
        'kind': kind.name,
      };

  factory IngestSource.fromJson(Map<String, dynamic> j) => IngestSource(
        path: j['path']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        sizeBytes: (j['size'] as num?)?.toInt() ?? 0,
        // 认不出的 kind 退回 image：宁可按图片试一次，
        // 也不要在恢复时把一个来源整条丢掉
        kind: j['kind'] == IngestSourceKind.pdf.name
            ? IngestSourceKind.pdf
            : IngestSourceKind.image,
      );

  @override
  String toString() => 'IngestSource($name, ${kind.label}, $sizeText)';
}

/// 人类可读的字节数。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// 从一份来源里解析出来的**一道题**（还没进题库）。
///
/// 字段刻意与 `ProblemDraft` 对齐，便于 [toDraft] 直接转换。
class ExtractedProblem {
  /// 题干（Markdown + LaTeX）。空题干的问题会在解析阶段就被丢掉。
  final String stem;

  final String? answer;
  final String? solution;

  final QuestionType qtype;

  /// 1 基础 · 2 综合 · 3 拓展。越界会被夹住。
  final int difficulty;

  /// 选择题选项（不含 A. 前缀）。
  final List<String> options;

  /// 出处，如「2023 年数学一」。
  final String? source;

  final SourceType sourceType;
  final int? sourceYear;

  /// 模型自报的置信度 0–1。null 表示模型没给。
  final double? confidence;

  /// 去重指纹（由题干算出）。
  final String fingerprint;

  /// 题库里已经存在的、同题干的题目 id。
  ///
  /// 由导入流程填（见 `IngestSession`）—— 提炼阶段不查库。
  /// 非空表示"这题大概已经录过了"，界面默认不勾选它。
  final List<String> duplicateIds;

  /// 来自哪个文件（展示与追溯用）。
  final String sourceName;

  /// ## 指纹为什么在构造函数里算，而不是做成默认参数
  ///
  /// 它是纯派生值（只依赖 [stem]）。若给它一个 `''` 的默认值，
  /// 任何忘了传的构造点都会得到空指纹 —— 而空指纹的表现是
  /// **「查重静默失效」**：不报错，只是同一道题被重复导入成两条。
  /// 这正是本项目已经踩过一次的那类坑（见 `problem_markdown.dart` 里
  /// 那份与 domain 分叉的指纹实现）。
  ///
  /// 所以这里不给默认值：不传就现算。[fingerprint] 只在
  /// [copyWith] 原样搬运时才会被显式传入。
  ExtractedProblem({
    required this.stem,
    this.answer,
    this.solution,
    this.qtype = QuestionType.solve,
    this.difficulty = 2,
    this.options = const [],
    this.source,
    this.sourceType = SourceType.unknown,
    this.sourceYear,
    this.confidence,
    String? fingerprint,
    this.duplicateIds = const [],
    this.sourceName = '',
  }) : fingerprint = fingerprint ?? ProblemFingerprint.compute(stem);

  bool get isDuplicate => duplicateIds.isNotEmpty;

  /// 题干太长时列表里用的短标题。
  String get shortStem {
    final t = stem.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length <= 48 ? t : '${t.substring(0, 48)}…';
  }

  ExtractedProblem copyWith({
    String? stem,
    String? answer,
    String? solution,
    QuestionType? qtype,
    int? difficulty,
    List<String>? options,
    String? source,
    SourceType? sourceType,
    int? sourceYear,
    double? confidence,
    String? fingerprint,
    List<String>? duplicateIds,
    String? sourceName,
  }) =>
      ExtractedProblem(
        stem: stem ?? this.stem,
        answer: answer ?? this.answer,
        solution: solution ?? this.solution,
        qtype: qtype ?? this.qtype,
        difficulty: difficulty ?? this.difficulty,
        options: options ?? this.options,
        source: source ?? this.source,
        sourceType: sourceType ?? this.sourceType,
        sourceYear: sourceYear ?? this.sourceYear,
        confidence: confidence ?? this.confidence,
        // 改了题干却没显式给指纹时**必须重算** —— 否则改完题干的题会带着
        // 旧指纹，查重就永远匹配不上了
        fingerprint: fingerprint ??
            (stem != null && stem != this.stem
                ? ProblemFingerprint.compute(stem)
                : this.fingerprint),
        duplicateIds: duplicateIds ?? this.duplicateIds,
        sourceName: sourceName ?? this.sourceName,
      );

  /// 转成录入页用的草稿。知识点留空 —— 由打标流程填。
  ProblemDraft toDraft({required String subject}) => ProblemDraft(
        subject: subject,
        qtype: qtype,
        difficulty: difficulty,
        stem: stem,
        answer: answer,
        solution: solution,
        options: options,
        source: source,
        sourceType: sourceType,
        sourceYear: sourceYear,
        aiTagged: false,
        aiConfidence: confidence,
        // 导入的题一律先标记"需要人工确认"：
        // 它是模型看图片读出来的，用户在核对界面看过才算确认。
        needsReview: true,
      );

  /// 序列化（草稿落盘用，见 T49）。
  ///
  /// **不写 `fingerprint`**：它是 `stem` 的纯派生值，读回来时现算更安全 ——
  /// 存下来的指纹一旦与当前算法不一致（换版本、改归一化规则），
  /// 查重就会拿一把旧尺子量新题。现算则永远与生产代码同一实现。
  Map<String, dynamic> toJson() => {
        'stem': stem,
        if (answer != null) 'answer': answer,
        if (solution != null) 'solution': solution,
        'qtype': qtype.id,
        'difficulty': difficulty,
        if (options.isNotEmpty) 'options': options,
        if (source != null) 'source': source,
        'source_type': sourceType.id,
        if (sourceYear != null) 'source_year': sourceYear,
        if (confidence != null) 'confidence': confidence,
        if (duplicateIds.isNotEmpty) 'duplicate_ids': duplicateIds,
        if (sourceName.isNotEmpty) 'source_name': sourceName,
      };

  factory ExtractedProblem.fromJson(Map<String, dynamic> j) => ExtractedProblem(
        stem: j['stem']?.toString() ?? '',
        answer: j['answer']?.toString(),
        solution: j['solution']?.toString(),
        qtype: QuestionType.fromId(j['qtype']?.toString()),
        difficulty: (j['difficulty'] as num?)?.toInt() ?? 2,
        options: [
          for (final o in (j['options'] as List? ?? const [])) o.toString(),
        ],
        source: j['source']?.toString(),
        sourceType: SourceType.fromId(j['source_type']?.toString()),
        sourceYear: (j['source_year'] as num?)?.toInt(),
        confidence: (j['confidence'] as num?)?.toDouble(),
        duplicateIds: [
          for (final d in (j['duplicate_ids'] as List? ?? const [])) d.toString(),
        ],
        sourceName: j['source_name']?.toString() ?? '',
      );

  /// 同题干判定用。与 `ProblemFingerprint` 同一实现，避免两套规则。
  static String fingerprintOf(String stem) => ProblemFingerprint.compute(stem);

  @override
  String toString() => 'ExtractedProblem(${qtype.id}, "$shortStem")';
}

/// 一个来源的处理状态。
enum IngestStatus {
  /// 还没开始。
  pending,

  /// 正在调用模型。
  running,

  /// 解析成功（可能解析出 0 道题 —— 那也是一种结果，不是失败）。
  done,

  /// 调用或解析失败。
  failed,

  /// 用户取消后剩下的，或超出限制被跳过的。
  skipped;

  String get label => switch (this) {
        IngestStatus.pending => '待处理',
        IngestStatus.running => '解析中',
        IngestStatus.done => '已完成',
        IngestStatus.failed => '失败',
        IngestStatus.skipped => '已跳过',
      };
}

/// 一个来源的处理结果。
class IngestItem {
  final IngestSource source;
  final IngestStatus status;
  final List<ExtractedProblem> problems;

  /// 失败原因（[status] 为 failed 时非空）。
  final String? error;

  /// 本次消耗。
  final LlmUsage usage;

  const IngestItem({
    required this.source,
    this.status = IngestStatus.pending,
    this.problems = const [],
    this.error,
    this.usage = const LlmUsage(),
  });

  bool get isDone => status == IngestStatus.done;
  bool get isEmptyResult => status == IngestStatus.done && problems.isEmpty;

  /// 这个来源**跑完了**（无论结果好坏）。
  ///
  /// 定义收敛在这里，是因为「跑完」有两个使用者：进度条，以及
  /// 草稿中继续跑时判定"哪些不用再花钱"。两处若各写各的，
  /// 迟早会出现"进度说 100%、续跑却还在重做"这种自相矛盾。
  bool get isFinished =>
      status == IngestStatus.done ||
      status == IngestStatus.failed ||
      status == IngestStatus.skipped;

  IngestItem copyWith({
    IngestStatus? status,
    List<ExtractedProblem>? problems,
    String? error,
    LlmUsage? usage,
  }) =>
      IngestItem(
        source: source,
        status: status ?? this.status,
        problems: problems ?? this.problems,
        // error 是"设为 null"有意义的值，所以不能用 ?? 兜 —— 重试成功时要清掉
        error: error,
        usage: usage ?? this.usage,
      );

  /// 序列化（草稿落盘用，见 T49）。
  Map<String, dynamic> toJson() => {
        'source': source.toJson(),
        'status': status.name,
        if (problems.isNotEmpty)
          'problems': [for (final p in problems) p.toJson()],
        if (error != null) 'error': error,
        if (usage.totalTokens > 0 || usage.fromCache) 'usage': usage.toJson(),
      };

  factory IngestItem.fromJson(Map<String, dynamic> j) => IngestItem(
        source: IngestSource.fromJson(
            (j['source'] as Map?)?.cast<String, dynamic>() ?? const {}),
        // 认不出的状态退回 pending：退回 pending 只会让这个来源重跑一次
        // （多花一次钱但结果正确），退回 done 会拿一个空结果糊弄用户
        status: IngestStatus.values.firstWhere(
          (s) => s.name == j['status']?.toString(),
          orElse: () => IngestStatus.pending,
        ),
        problems: [
          for (final p in (j['problems'] as List? ?? const []))
            ExtractedProblem.fromJson((p as Map).cast<String, dynamic>()),
        ],
        error: j['error']?.toString(),
        usage: j['usage'] is Map
            ? LlmUsage.fromJson((j['usage'] as Map).cast<String, dynamic>())
            : const LlmUsage(),
      );

  @override
  String toString() => 'IngestItem(${source.name}, ${status.label}, '
      '${problems.length} 题)';
}

/// 进度快照（界面画进度条用）。
class IngestProgress {
  final int total;
  final int finished;
  final int failed;
  final int problemCount;

  /// 当前正在处理的来源名。
  final String? current;

  const IngestProgress({
    this.total = 0,
    this.finished = 0,
    this.failed = 0,
    this.problemCount = 0,
    this.current,
  });

  /// 从当前结果列表算一份进度。
  ///
  /// 恢复草稿时要立刻画出进度条，而那时并没有"正在跑"的过程可言 ——
  /// 所以这个口径必须与 [IngestSession] 跑动时的口径**完全一致**，
  /// 否则恢复后与跑到一半的进度条会显示成两个数。
  factory IngestProgress.of(List<IngestItem> items, {String? current}) =>
      IngestProgress(
        total: items.length,
        finished: items.where((i) => i.isFinished).length,
        failed: items.where((i) => i.status == IngestStatus.failed).length,
        problemCount: items.fold(0, (n, i) => n + i.problems.length),
        current: current,
      );

  double get fraction => total == 0 ? 0 : finished / total;

  bool get isComplete => total > 0 && finished >= total;

  String get text {
    final c = current == null ? '' : '（$current）';
    return '$finished / $total$c · 已解析 $problemCount 题'
        '${failed > 0 ? ' · 失败 $failed' : ''}';
  }
}

/// 导入前的预估。
///
/// ⚠️ 这里全部是**估算**，用于让用户下单前心里有数。UI 必须标注「估算」。
/// 假设写在 [kTokensPerImagePage] 等处，改了要一起改。
class IngestEstimate {
  final int images;
  final int pdfs;

  /// 估算页数合计（图片按 1 页算）。
  final int pages;

  final int totalBytes;

  /// 估算输入 / 输出 token。
  final int estInputTokens;
  final int estOutputTokens;

  /// 估算费用（元）。模型不在价目表里时为 null。
  final double? estCostYuan;

  /// 必须告诉用户的事（大文件、PDF 会整份发出、可能被截断……）。
  final List<String> notes;

  const IngestEstimate({
    this.images = 0,
    this.pdfs = 0,
    this.pages = 0,
    this.totalBytes = 0,
    this.estInputTokens = 0,
    this.estOutputTokens = 0,
    this.estCostYuan,
    this.notes = const [],
  });

  int get sourceCount => images + pdfs;

  /// 费用文案（估算）。
  String get costText {
    final c = estCostYuan;
    if (c == null) return '未知（该模型不在价目表里）';
    if (c < 0.01) return '< ¥0.01';
    return '约 ¥${c.toStringAsFixed(2)}';
  }

  String get tokenText => '约 ${estInputTokens + estOutputTokens} tokens';

  String get summary =>
      '$sourceCount 个来源（$images 张图片 / $pdfs 个 PDF）· '
      '约 $pages 页 · ${formatBytes(totalBytes)} · $tokenText · $costText';
}

/// 估算一张扫描页占多少输入 token。
///
/// ## 这个数是怎么来的
///
/// 各家对图片的计费方式不同（OpenAI 按 512×512 分块，Anthropic 按
/// `宽×高/750`，Gemini 按固定 258 token/图）。取 1200 是这些口径下
/// **一张 A4 扫描页**的常见量级。它只用于"要不要花这笔钱"的判断，
/// 真实用量以服务商返回的 `usage` 为准（我们会记进用量台账）。
const int kTokensPerImagePage = 1200;

/// 估算一页能解析出几道题。
const double kProblemsPerPage = 1.5;

/// 估算一道题的结构化输出要多少 token（题干 + 答案 + 解析 + JSON 外壳）。
const int kTokensPerExtractedProblem = 500;

/// 按来源清单估算。
///
/// [model] 用于查价目表；[textPromptTokens] 是提示词本身的固定开销。
/// [maxOutputTokens] 是**该服务商允许的单次输出上限**（见
/// `ProviderSpec.maxOutputTokens`）—— 传入后，上限偏低会额外给一条提示：
/// 一页题多、解析长时输出会被截断，而截断表现为"解析失败"，
/// 用户不知道是模型限制导致的。
IngestEstimate estimateIngest(
  List<IngestSource> sources, {
  required String model,
  int textPromptTokens = 900,
  int? maxOutputTokens,
}) {
  var images = 0;
  var pdfs = 0;
  var pages = 0;
  var bytes = 0;
  final notes = <String>[];

  var oversize = 0;
  var bigPdfs = 0;

  for (final s in sources) {
    if (s.isPdf) {
      pdfs++;
      if (s.estimatedPages > kPdfPageWarningThreshold) bigPdfs++;
    } else {
      images++;
    }
    pages += s.estimatedPages;
    bytes += s.sizeBytes;

    final limit = s.isPdf ? kMaxPdfBytes : kMaxImageBytes;
    if (s.sizeBytes > limit) {
      oversize++;
      notes.add('${s.name} 超过单文件上限（${formatBytes(limit)}），'
          '将无法发送，请先压缩或拆分成图片。');
    }
  }

  if (pdfs > 0) {
    notes.add('PDF 会**整份**作为一次请求发出（V1 不做本地拆分，'
        '以免为它引入 10 MB 级的 PDF 渲染库）。'
        '页数很多的扫描件可能被模型的输出长度截断，建议一次不超过 '
        '$kPdfPageWarningThreshold 页。');
  }
  if (bigPdfs > 0) {
    notes.add('有 $bigPdfs 个 PDF 体积较大（估计超过 '
        '$kPdfPageWarningThreshold 页），解析结果可能不完整 —— '
        '导入后请核对题数是否与原文相符。');
  }
  if (oversize > 0) {
    notes.add('有 $oversize 个文件超限，不会发送，也不会计费。');
  }

  // token 口径：真话比好看的数字重要。
  //
  // 实测（2026-09-18）同一张 200 dpi 的数学书页：
  // 智谱 `glm-4v-flash` 报 **5919** 输入 token，而这里的常数按
  // `kTokensPerImagePage`（1200）算 —— 差 5 倍。Gemini 更低（按图固定 258）。
  // 既然差价能到几十倍，就不能让用户以为那个数字是准的。
  if (images > 0) {
    notes.add('token 是按每页 $kTokensPerImagePage 的通用口径估的：'
        '实测同一张 200 dpi 数学页，智谱报约 5900 输入 token、'
        'Gemini 按图固定约 258 —— 各家差异很大。'
        '这个数只用来判断量级，真实用量以服务商返回的统计为准（会记进台账）。');
  }

  // 输出上限偏低的模型：一页题多时会被截断，而且**看起来像"解析失败"**
  if (maxOutputTokens != null && maxOutputTokens < 2048) {
    notes.add('这个模型单次最多输出 $maxOutputTokens token'
        '（服务商硬限制），一页题多或解析较长时会被截断 —— '
        '建议一次只导一页、并核对题数；或换一个输出上限更大的模型。');
  }

  final input = textPromptTokens * sources.length + pages * kTokensPerImagePage;
  final output =
      (pages * kProblemsPerPage * kTokensPerExtractedProblem).round();

  return IngestEstimate(
    images: images,
    pdfs: pdfs,
    pages: pages,
    totalBytes: bytes,
    estInputTokens: input,
    estOutputTokens: output,
    estCostYuan: LlmPricing.estimate(
      model: model,
      inputTokens: input,
      outputTokens: output,
    ),
    notes: notes,
  );
}
