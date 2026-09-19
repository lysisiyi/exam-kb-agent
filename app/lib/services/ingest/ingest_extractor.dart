/// 把模型输出解析成 [ExtractedProblem] 列表。
///
/// ## 为什么这一层要写得这么宽容
///
/// 提炼任务的输出是模型对着**图片**生成的 JSON。实测过同类任务的三种翻车方式：
/// 1. 包在 ` ```json ` 代码块里（提示词明确禁了，但模型照样会包）
/// 2. 顶层是数组而不是对象（我们的提示词要求对象，见 [RobustJson] 只认对象）
/// 3. 字段名漂移：`stem` 写成 `question` / `题干`，`options` 写成 `choices`
///
/// 三种都不该让整页数据作废 —— [RobustJson] 处理第 1、2 种的兜底，
/// 这一层处理第 3 种。但**宽容有底线**：没有题干的条目一律丢弃并记账，
/// 因为一道没有题干的"题"进了题库就是一条查不到的垃圾数据。
library;

import '../../data/markdown/problem_markdown.dart';
import '../llm/robust_json.dart';
import 'ingest_models.dart';

/// 一次提炼的解析结果。
class ExtractionOutcome {
  final List<ExtractedProblem> problems;

  /// 解析过程中的问题（给用户看的）。
  final List<String> warnings;

  /// RobustJson 命中的策略（用于统计各服务商的输出质量）。
  final String strategy;

  const ExtractionOutcome({
    this.problems = const [],
    this.warnings = const [],
    this.strategy = '',
  });

  bool get isEmpty => problems.isEmpty;

  @override
  String toString() =>
      'ExtractionOutcome(${problems.length} 题, strategy=$strategy, '
      'warnings=${warnings.length})';
}

/// 提炼结果的解析器。
abstract final class IngestExtractor {
  const IngestExtractor._();

  /// 顶层可能承载题目数组的键，按优先级尝试。
  static const List<String> _listKeys = [
    'problems',
    'items',
    'questions',
    '题目',
    'data',
    'result',
  ];

  /// 解析模型输出。
  ///
  /// [sourceName] 会写进每道题的追溯字段。
  static ExtractionOutcome parse(
    String raw, {
    required String sourceName,
  }) {
    final warnings = <String>[];

    // `acceptArray: true` 是必须的：实测模型经常不写 `{"problems": [...]}`
    // 包层，直接给一个题目数组。早先不认数组，降级路径会取到数组里
    // **第一个**对象 —— 一页 3 道题只进来 1 道，其余静默消失。
    final extracted = RobustJson.extract(raw, acceptArray: true);
    if (extracted.isEmpty) {
      final detail = extracted.warnings.isEmpty
          ? ''
          : '：${extracted.warnings.take(2).join('；')}';
      return ExtractionOutcome(
        warnings: ['模型输出无法解析为 JSON$detail'],
        strategy: extracted.strategy,
      );
    }

    warnings.addAll(extracted.warnings);

    final root = extracted.value;
    final rawItems = root != null
        ? _findProblemList(root)
        : _arrayItems(extracted.listValue!, warnings);

    if (rawItems == null) {
      // 整个对象本身可能就"是一道题"（模型没用 problems 包一层）
      if (root != null && _hasStem(root)) {
        warnings.add('模型没有用 problems 包一层，已按单题处理');
        final one = _one(root, sourceName, warnings, index: 0);
        return ExtractionOutcome(
          problems: one == null ? const [] : [one],
          warnings: warnings,
          strategy: extracted.strategy,
        );
      }
      return ExtractionOutcome(
        warnings: [...warnings, '返回的 JSON 里没有找到题目数组'],
        strategy: extracted.strategy,
      );
    }

    if (rawItems.isEmpty) {
      // 不是错误：封面 / 目录 / 答案页本来就该返回空。
      return ExtractionOutcome(
        problems: const [],
        warnings: warnings,
        strategy: extracted.strategy,
      );
    }

    final out = <ExtractedProblem>[];
    for (var i = 0; i < rawItems.length; i++) {
      final p = _one(rawItems[i], sourceName, warnings, index: i);
      if (p != null) out.add(p);
    }

    if (out.isEmpty) {
      warnings.add('识别到 ${rawItems.length} 个条目，但都没有可用题干，'
          '已全部丢弃');
    }

    return ExtractionOutcome(
      problems: out,
      warnings: warnings,
      strategy: extracted.strategy,
    );
  }

  /// 在 [root] 里找题目数组。找不到返回 null。
  static List<Map<String, dynamic>>? _findProblemList(
    Map<String, dynamic> root,
  ) {
    for (final key in _listKeys) {
      final v = root[key];
      if (v is List) {
        return v
            .whereType<Map<Object?, Object?>>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
      }
    }
    return null;
  }

  /// 模型直接给数组时（`[{...}, {...}]`），数组本身就是题目列表。
  ///
  /// 数组里的非对象元素（数字、字符串）会被跳过并记账 ——
  /// 静默跳过和静默丢题一样有害。
  static List<Map<String, dynamic>> _arrayItems(
    List<dynamic> list,
    List<String> warnings,
  ) {
    final maps = list
        .whereType<Map<Object?, Object?>>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    final skipped = list.length - maps.length;
    if (skipped > 0) {
      warnings.add('模型输出的数组里有 $skipped 个元素不是题目对象，已跳过');
    }
    return maps;
  }

  static bool _hasStem(Map<String, dynamic> j) => _stemOf(j).isNotEmpty;

  /// 题干字段的候选名。
  static String _stemOf(Map<String, dynamic> j) {
    for (final k in ['stem', 'question', 'content', '题干', '题目', 'text']) {
      final v = j[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return '';
  }

  /// 解析单条。题干为空时返回 null 并记账。
  static ExtractedProblem? _one(
    Map<String, dynamic> j,
    String sourceName,
    List<String> warnings, {
    required int index,
  }) {
    final stem = _stemOf(j);
    if (stem.isEmpty) {
      warnings.add('第 ${index + 1} 条没有题干，已丢弃');
      return null;
    }

    final completeness =
        (RobustJson.stringField(j, 'completeness') ?? '').toLowerCase();
    final partial = completeness == 'partial';

    var answer = _clean(RobustJson.stringField(j, 'answer'));
    var solution = _clean(RobustJson.stringField(j, 'solution'));

    // ── 防编造：answer_from_source ──────────────────────────────────────
    //
    // 模型很擅长解题，给它一张只有题干的照片，它会"顺手"把答案算出来填上，
    // 而且看起来完全合理。用户拿到一份**编造答案**的错题本，
    // 比拿到一份没答案的错题本糟得多 —— 前者会让他以为是自己记错了。
    //
    // 所以提示词要求模型声明答案是不是从原文抄的，这里按声明办事：
    //   - 明确说"不是抄的" → 丢弃答案与解析（它不该出现在这里）
    //   - 没说 → 保留但记账，让用户在核对界面自己看一眼
    final fromSource = RobustJson.boolField(j, 'answer_from_source');
    if (fromSource == false) {
      if (answer != null || solution != null) {
        warnings.add('第 ${index + 1} 条：模型自述答案不是原文内容，'
            '已丢弃它生成的答案与解析');
      }
      answer = null;
      solution = null;
    } else if (fromSource == null && (answer != null || solution != null)) {
      warnings.add('第 ${index + 1} 条：模型没有说明答案是否来自原文，'
          '请在核对时确认');
    }

    var confidence = RobustJson.doubleField(j, 'confidence');
    if (partial) {
      // 题干读不全时，模型自报的高置信度没有意义 —— 压到 0.5 以下，
      // 让它在列表里一眼可见地排在"要核对"那一档
      confidence = confidence == null
          ? 0.4
          : (confidence > 0.5 ? 0.5 : confidence);
    }

    return ExtractedProblem(
      stem: stem,
      answer: answer,
      solution: solution,
      qtype: _qtypeOf(j),
      difficulty: _difficultyOf(j),
      options: _optionsOf(j),
      source: _clean(RobustJson.stringField(j, 'source')),
      sourceType: _sourceTypeOf(j),
      sourceYear: RobustJson.intField(j, 'source_year'),
      confidence: confidence,
      sourceName: sourceName,
      // 不传 fingerprint：由构造函数从 stem 现算，避免"忘了传就静默不查重"
    );
  }

  /// 题型。认中英文两种写法。
  static QuestionType _qtypeOf(Map<String, dynamic> j) {
    final raw = (RobustJson.stringField(j, 'qtype') ??
            RobustJson.stringField(j, 'type') ??
            '')
        .trim()
        .toLowerCase();
    return switch (raw) {
      'choice' || '选择题' || '选择' || '单选' || '多选' => QuestionType.choice,
      'fill' || 'fill_in' || '填空题' || '填空' => QuestionType.fill,
      'proof' || '证明题' || '证明' => QuestionType.proof,
      'solve' || '解答题' || '解答' || '计算题' => QuestionType.solve,
      // 认不出时按解答题处理（与 `QuestionType.fromId` 的默认一致），
      // 但不写警告 —— 题型判错用户一眼就能改，不值得为它打断核对流程
      _ => QuestionType.solve,
    };
  }

  /// 难度。接受 1/2/3 与中文档位。
  static int _difficultyOf(Map<String, dynamic> j) {
    final n = RobustJson.intField(j, 'difficulty');
    if (n != null) return n.clamp(1, 3);

    final raw = (RobustJson.stringField(j, 'difficulty') ?? '').trim();
    return switch (raw) {
      '基础' || '容易' || '简单' || 'easy' => 1,
      '拓展' || '难' || '困难' || 'hard' => 3,
      _ => 2,
    };
  }

  static SourceType _sourceTypeOf(Map<String, dynamic> j) {
    final raw = (RobustJson.stringField(j, 'source_type') ?? '').toLowerCase();
    final byId = SourceType.fromId(raw);
    if (byId != SourceType.unknown) return byId;
    final s = RobustJson.stringField(j, 'source') ?? '';
    if (s.contains('真题')) return SourceType.realExam;
    if (s.contains('模拟')) return SourceType.mock;
    if (s.contains('教材') || s.contains('讲义') || s.contains('辅导')) {
      return SourceType.textbook;
    }
    return SourceType.unknown;
  }

  /// 选项。剥掉 `A.` / `A、` / `（A）` 这类前缀（提示词要求不带，但模型常带）。
  static List<String> _optionsOf(Map<String, dynamic> j) {
    final raw = RobustJson.stringListField(j, 'options');
    final list = raw.isNotEmpty
        ? raw
        : RobustJson.stringListField(j, 'choices');
    return [
      for (final o in list)
        if (_stripOptionPrefix(o).isNotEmpty) _stripOptionPrefix(o),
    ];
  }

  static final RegExp _optionPrefix = RegExp(
    r'^\s*(?:[（(\[]?[A-Ha-h][）)\].、,：:]\s*|\[[A-Ha-h]\]\s*)',
  );

  static String _stripOptionPrefix(String s) =>
      s.replaceFirst(_optionPrefix, '').trim();

  static String? _clean(String? s) {
    final t = s?.trim();
    if (t == null || t.isEmpty) return null;
    // 模型常把"没有"写成这些字符串而不是 null
    const notAvailable = {'null', 'none', 'n/a', 'na', '无', '略', '（略）', '-'};
    if (notAvailable.contains(t.toLowerCase())) return null;
    return t;
  }
}
