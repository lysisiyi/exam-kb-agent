/// 题目 Markdown 的模型与宽容解析器。
///
/// 格式规范见 `docs/DATA_FORMAT.md`。核心设计：
/// - **题目内容**（题干/答案/解析）存 Markdown 文件
/// - **用户状态**（错误次数/FSRS/掌握度）存 SQLite，**绝不写进文件**
///
/// ## 宽容原则（最重要）
/// frontmatter 解析失败**绝不能导致题目丢失**。降级链：
/// 1. 标准 YAML 解析
/// 2. YAML 失败 → 逐行正则提取能识别的字段，标记 `needsReview`
/// 3. 完全没有 frontmatter → 整个文件当纯文本题干，id 用文件名
/// 4. 文件读取失败 → 跳过并记账，不中断批量导入
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';

/// 知识点关联。
class KnowledgeRef {
  /// 知识点 id，必须在知识点本体中存在。
  final String id;

  /// `primary`（主考点，有且仅有一个）或 `secondary`。
  final String role;

  /// 相关度 0–1。
  final double relevance;

  const KnowledgeRef({
    required this.id,
    this.role = 'secondary',
    this.relevance = 1.0,
  });

  bool get isPrimary => role == 'primary';

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'relevance': relevance,
      };

  factory KnowledgeRef.fromJson(Map<String, dynamic> j) => KnowledgeRef(
        id: j['id']?.toString() ?? '',
        role: j['role']?.toString() ?? 'secondary',
        relevance: (j['relevance'] as num?)?.toDouble() ?? 1.0,
      );
}

/// 题型。
enum QuestionType {
  choice('choice', '选择'),
  fill('fill', '填空'),
  solve('solve', '解答'),
  proof('proof', '证明');

  const QuestionType(this.id, this.label);
  final String id;
  final String label;

  static QuestionType fromId(String? v) => QuestionType.values.firstWhere(
        (t) => t.id == v,
        orElse: () => QuestionType.solve,
      );
}

/// 来源类型。
enum SourceType {
  realExam('real_exam', '真题'),
  mock('mock', '模拟题'),
  textbook('textbook', '教材/教辅'),
  selfMade('self_made', '自建'),
  unknown('unknown', '未知');

  const SourceType(this.id, this.label);
  final String id;
  final String label;

  static SourceType fromId(String? v) => SourceType.values.firstWhere(
        (t) => t.id == v,
        orElse: () => SourceType.unknown,
      );
}

/// 一道题目的完整内容（不含用户状态）。
class Problem {
  /// 全局唯一 id，人类可读优先，如 `2023-shu1-T18`。
  final String id;

  /// 去重指纹（16 位十六进制）。基于规范化题干计算。
  final String fingerprint;

  /// `math1` / `math2` / `math3`
  final String subject;

  final QuestionType qtype;

  /// 1 基础 · 2 综合 · 3 拓展
  final int difficulty;

  final String? source;
  final SourceType sourceType;
  final int? sourceYear;

  /// 知识点关联。约束：有且仅有一个 primary。
  final List<KnowledgeRef> knowledge;

  /// 预判易错点，取值见 `data/error_causes.json`。
  final List<String> errorCauses;

  /// 选择题选项。
  final List<String> options;

  /// 图片相对路径。
  final List<String> images;

  final List<String> tags;

  /// 题干（Markdown + LaTeX）。
  final String stem;

  /// 答案。
  final String? answer;

  /// 解析。
  final String? solution;

  /// 用户笔记（导出时从 SQLite 合并进来）。
  final String? note;

  final DateTime? createdAt;

  /// AI 是否已标注。
  final bool aiTagged;

  /// primary 知识点的置信度 0–1。
  final double? aiConfidence;

  /// 是否需要人工确认（解析降级、置信度低、知识点 id 不存在等）。
  final bool needsReview;

  /// 解析过程中产生的警告，用于 UI 提示与日志。
  final List<String> warnings;

  const Problem({
    required this.id,
    required this.fingerprint,
    this.subject = 'math1',
    this.qtype = QuestionType.solve,
    this.difficulty = 2,
    this.source,
    this.sourceType = SourceType.unknown,
    this.sourceYear,
    this.knowledge = const [],
    this.errorCauses = const [],
    this.options = const [],
    this.images = const [],
    this.tags = const [],
    required this.stem,
    this.answer,
    this.solution,
    this.note,
    this.createdAt,
    this.aiTagged = false,
    this.aiConfidence,
    this.needsReview = false,
    this.warnings = const [],
  });

  /// 主考点（可能为空——未标注的题目）。
  KnowledgeRef? get primaryKnowledge {
    for (final k in knowledge) {
      if (k.isPrimary) return k;
    }
    return null;
  }

  /// 全部知识点 id。
  List<String> get knowledgeIds => knowledge.map((k) => k.id).toList();

  Problem copyWith({
    String? id,
    String? fingerprint,
    String? subject,
    QuestionType? qtype,
    int? difficulty,
    String? source,
    SourceType? sourceType,
    int? sourceYear,
    List<KnowledgeRef>? knowledge,
    List<String>? errorCauses,
    List<String>? options,
    List<String>? images,
    List<String>? tags,
    String? stem,
    String? answer,
    String? solution,
    String? note,
    DateTime? createdAt,
    bool? aiTagged,
    double? aiConfidence,
    bool? needsReview,
    List<String>? warnings,
  }) =>
      Problem(
        id: id ?? this.id,
        fingerprint: fingerprint ?? this.fingerprint,
        subject: subject ?? this.subject,
        qtype: qtype ?? this.qtype,
        difficulty: difficulty ?? this.difficulty,
        source: source ?? this.source,
        sourceType: sourceType ?? this.sourceType,
        sourceYear: sourceYear ?? this.sourceYear,
        knowledge: knowledge ?? this.knowledge,
        errorCauses: errorCauses ?? this.errorCauses,
        options: options ?? this.options,
        images: images ?? this.images,
        tags: tags ?? this.tags,
        stem: stem ?? this.stem,
        answer: answer ?? this.answer,
        solution: solution ?? this.solution,
        note: note ?? this.note,
        createdAt: createdAt ?? this.createdAt,
        aiTagged: aiTagged ?? this.aiTagged,
        aiConfidence: aiConfidence ?? this.aiConfidence,
        needsReview: needsReview ?? this.needsReview,
        warnings: warnings ?? this.warnings,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'fingerprint': fingerprint,
        'subject': subject,
        'qtype': qtype.id,
        'difficulty': difficulty,
        'source': source,
        'sourceType': sourceType.id,
        'sourceYear': sourceYear,
        'knowledge': knowledge.map((k) => k.toJson()).toList(),
        'errorCauses': errorCauses,
        'options': options,
        'images': images,
        'tags': tags,
        'stem': stem,
        'answer': answer,
        'solution': solution,
        'note': note,
        'createdAt': createdAt?.toIso8601String(),
        'aiTagged': aiTagged,
        'aiConfidence': aiConfidence,
        'needsReview': needsReview,
      };
}

/// 正文分区。
class ProblemSections {
  final String stem;
  final String? answer;
  final String? solution;
  final String? note;

  const ProblemSections({
    required this.stem,
    this.answer,
    this.solution,
    this.note,
  });
}

/// 解析结果。
class ParseResult {
  final Problem? problem;

  /// 解析失败原因。非空表示这道题应被记入导入报告。
  final String? error;

  const ParseResult.ok(this.problem) : error = null;
  const ParseResult.failed(this.error) : problem = null;

  bool get isOk => problem != null;
}

// ─────────────────────────────────────────────────────────────────────────────
// 解析器
// ─────────────────────────────────────────────────────────────────────────────

class ProblemMarkdownParser {
  const ProblemMarkdownParser();

  /// 公式分隔符归一化：`\(..\)` → `$..$`，`\[..\]` → `$$..$$`。
  static final RegExp _reInlineParen = RegExp(r'\\\((.*?)\\\)', dotAll: true);
  static final RegExp _reDisplayBracket = RegExp(r'\\\[(.*?)\\\]', dotAll: true);
  static final RegExp _reEquationEnv =
      RegExp(r'\\begin\{equation\*?\}(.*?)\\end\{equation\*?\}', dotAll: true);

  /// 不可见字符。
  static final RegExp _reInvisible =
      RegExp(r'[\u200B-\u200F\u202A-\u202E\u2060-\u2064\uFEFF\u00AD]');

  /// 正文分区标题 → 标准分区名。
  static const Map<String, List<String>> sectionAliases = {
    'stem': ['题干', '题目', '问题', 'stem', 'Stem'],
    'answer': ['答案', 'answer', 'Answer'],
    'solution': ['解析', '解答', '解题过程', 'solution', 'Solution'],
    'note': ['我的笔记', '笔记', 'note', 'Note'],
  };

  /// 从一个 Markdown 文件的完整文本解析出题目。
  ///
  /// [fallbackId] 通常是文件名（不含扩展名），在 frontmatter 缺失时作为 id。
  ParseResult parse(String content, {String? fallbackId}) {
    final warnings = <String>[];

    // 1. 基础清理
    final text = content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(_reInvisible, '');

    // 2. 提取 frontmatter
    Map<String, dynamic> meta = {};
    String body = text;
    final fm = _extractFrontmatter(text);
    if (fm == null) {
      warnings.add('缺少 YAML frontmatter，已按纯文本题目处理');
    } else {
      body = fm.body;
      try {
        final parsed = loadYaml(fm.yaml);
        if (parsed is Map) {
          meta = _normalizeYamlMap(parsed.cast<dynamic, dynamic>());
        } else {
          warnings.add('frontmatter 不是映射结构，已忽略');
        }
      } catch (e) {
        warnings.add('frontmatter YAML 解析失败，已降级为逐行提取：$e');
        meta = _salvageFrontmatter(fm.yaml);
      }
    }

    // 3. 解析正文分区
    final sections = _splitSections(body);

    // 4. 组装
    final stem = _normalizeMath(sections.stem).trim();
    if (stem.isEmpty) {
      return const ParseResult.failed('题干为空');
    }

    final id = (meta['id']?.toString().trim().isNotEmpty ?? false)
        ? meta['id'].toString().trim()
        : (fallbackId ?? _idFromHash(stem));

    final fingerprint = meta['fingerprint']?.toString().trim().isNotEmpty == true
        ? meta['fingerprint'].toString().trim()
        : _computeFingerprint(stem);

    final knowledge = _parseKnowledge(meta['knowledge'], warnings);

    // 知识点约束：有且仅有一个 primary
    final primaryCount = knowledge.where((k) => k.isPrimary).length;
    var needsReview = warnings.isNotEmpty;
    if (knowledge.isNotEmpty && primaryCount == 0) {
      warnings.add('缺少 primary 知识点');
      needsReview = true;
    } else if (primaryCount > 1) {
      warnings.add('存在 $primaryCount 个 primary 知识点，应为 1 个');
      needsReview = true;
    }

    // 置信度低也进人工确认队列
    final conf = _toDouble(meta['ai_confidence']);
    if (conf != null && conf < 0.7) {
      needsReview = true;
    }

    final problem = Problem(
      id: id,
      fingerprint: fingerprint,
      subject: meta['subject']?.toString() ?? 'math1',
      qtype: QuestionType.fromId(meta['qtype']?.toString()),
      difficulty: _toInt(meta['difficulty'])?.clamp(1, 3) ?? 2,
      source: meta['source']?.toString(),
      sourceType: SourceType.fromId(meta['source_type']?.toString()),
      sourceYear: _toInt(meta['source_year']),
      knowledge: knowledge,
      errorCauses: _toStringList(meta['error_causes']),
      options: _toStringList(meta['options']),
      images: _toStringList(meta['images']),
      tags: _toStringList(meta['tags']),
      stem: stem,
      answer: _emptyToNull(_normalizeMath(sections.answer ?? '')),
      solution: _emptyToNull(_normalizeMath(sections.solution ?? '')),
      note: _emptyToNull(sections.note),
      createdAt: _toDate(meta['created_at']),
      aiTagged: meta['ai_tagged'] == true,
      aiConfidence: conf,
      needsReview: needsReview,
      warnings: warnings,
    );

    return ParseResult.ok(problem);
  }

  // ── frontmatter ───────────────────────────────────────────────────────────

  /// 提取 `---\n...\n---` 之间的 YAML 与剩余正文。
  static ({String yaml, String body})? _extractFrontmatter(String text) {
    // file 必须以 --- 开头（允许前面有 BOM / 空行）
    final m = RegExp(r'^\s*---[ \t]*\n(.*?)\n---[ \t]*(?:\n|$)', dotAll: true)
        .firstMatch(text);
    if (m == null) return null;
    return (yaml: m.group(1) ?? '', body: text.substring(m.end));
  }

  /// YAML 坏掉时的抢救：逐行正则提取 `key: value`。
  ///
  /// 只认识标量字段；`knowledge` 这类嵌套结构会丢失（记入 warnings）。
  static Map<String, dynamic> _salvageFrontmatter(String yamlText) {
    final out = <String, dynamic>{};
    for (final rawLine in yamlText.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith('-')) continue; // 列表项，跳过
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      final key = line.substring(0, idx).trim();
      var value = line.substring(idx + 1).trim();
      if (value.isEmpty) continue;
      // 去引号
      if ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))) {
        value = value.substring(1, value.length - 1);
      }
      // 去行内注释
      final hash = value.indexOf(' #');
      if (hash > 0) value = value.substring(0, hash).trim();
      out[key] = value;
    }
    return out;
  }

  /// 把 `YamlMap` 递归转成普通 `Map<String, dynamic>`。
  ///
  /// 入参类型用 `Map<dynamic, dynamic>`：YAML 库产出的是 `YamlMap`，
  /// 它实际是 `Map<dynamic, dynamic>` 的子类型，但**不是**
  /// `Map<String, dynamic>` 的子类型，因此不能直接声明成后者。
  static Map<String, dynamic> _normalizeYamlMap(Map<dynamic, dynamic> yamlMap) {
    final out = <String, dynamic>{};
    yamlMap.forEach((k, v) {
      out[k.toString()] = _normalizeYamlValue(v);
    });
    return out;
  }

  static dynamic _normalizeYamlValue(dynamic v) {
    if (v is YamlMap) {
      return _normalizeYamlMap(v);
    }
    if (v is Map) {
      return _normalizeYamlMap(v.cast<dynamic, dynamic>());
    }
    if (v is YamlList || v is List) {
      return (v as List).map(_normalizeYamlValue).toList();
    }
    return v;
  }

  static List<KnowledgeRef> _parseKnowledge(dynamic raw, List<String> warnings) {
    if (raw == null) return const [];
    if (raw is! List) {
      warnings.add('knowledge 字段不是列表');
      return const [];
    }
    final out = <KnowledgeRef>[];
    for (final item in raw) {
      if (item is Map) {
        final m = item.map((k, v) => MapEntry(k.toString(), v));
        final id = m['id']?.toString().trim() ?? '';
        if (id.isEmpty) {
          warnings.add('knowledge 条目缺少 id');
          continue;
        }
        out.add(KnowledgeRef(
          id: id,
          role: m['role']?.toString().trim() ?? 'secondary',
          relevance: _toDouble(m['relevance']) ?? 1.0,
        ));
      } else if (item is String && item.trim().isNotEmpty) {
        // 简写形式：knowledge: [kp.id.1, kp.id.2]
        out.add(KnowledgeRef(id: item.trim(), role: 'secondary'));
      }
    }
    return out;
  }

  // ── 正文分区 ──────────────────────────────────────────────────────────────

  /// 按二级标题切分正文。未识别的部分**全部归入题干**（宁可多，不可漏）。
  static ProblemSections _splitSections(String body) {
    final lines = body.split('\n');
    final buckets = <String, List<String>>{'stem': []};
    var current = 'stem';

    for (final line in lines) {
      final heading = _matchSectionHeading(line);
      if (heading != null) {
        current = heading;
        buckets.putIfAbsent(current, () => []);
        continue;
      }
      buckets.putIfAbsent(current, () => []).add(line);
    }

    // 逐行去行尾空白后再拼接。
    // 只对整体 trim 不够：内部行的行尾空格会残留（Word / 网页粘贴很常见），
    // 进而污染指纹与单元测试的文本比较。
    String join(String key) => (buckets[key] ?? const [])
        .map((line) => line.replaceAll(RegExp(r'[ \t]+$'), ''))
        .join('\n')
        .trim();

    return ProblemSections(
      stem: join('stem'),
      answer: _emptyToNull(join('answer')),
      solution: _emptyToNull(join('solution')),
      note: _emptyToNull(join('note')),
    );
  }

  /// 匹配 `## 题干` / `### 解析` 这类标题，返回标准分区名。
  static String? _matchSectionHeading(String line) {
    final m = RegExp(r'^\s{0,3}#{1,6}\s+(.+?)\s*$').firstMatch(line);
    if (m == null) return null;
    var title = m.group(1)!.trim();
    // 去掉尾部标点与加粗标记
    title = title.replaceAll(RegExp(r'[*_`]'), '').replaceAll(RegExp(r'[:：]\s*$'), '').trim();

    for (final entry in sectionAliases.entries) {
      for (final alias in entry.value) {
        if (title == alias) return entry.key;
      }
    }
    return null; // 未识别标题 → 当成正文的一部分
  }

  // ── 公式归一化 ────────────────────────────────────────────────────────────

  static String _normalizeMath(String s) {
    var out = s;
    out = out.replaceAllMapped(_reDisplayBracket, (m) => '\$\$${m.group(1)}\$\$');
    out = out.replaceAllMapped(_reInlineParen, (m) => '\$${m.group(1)}\$');
    out = out.replaceAllMapped(
      _reEquationEnv,
      (m) => '\$\$${m.group(1)}\$\$',
    );
    return out;
  }

  // ── 类型转换工具 ──────────────────────────────────────────────────────────

  static int? _toInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString().trim());
  }

  static double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().trim());
  }

  static List<String> _toStringList(dynamic v) {
    if (v == null) return const [];
    if (v is List) {
      return v
          .map((e) => e?.toString().trim() ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
    }
    // 逗号分隔的字符串也接受
    final s = v.toString().trim();
    if (s.isEmpty) return const [];
    if (s.startsWith('[') && s.endsWith(']')) {
      return s
          .substring(1, s.length - 1)
          .split(',')
          // 去掉首尾可能存在的单/双引号。
          // 注意：正则里**不能**写 \' —— 在 r'...' 原始字符串中反斜杠是字面量，
          // 它既不能转义单引号，反而会让 ' 提前结束字符串（编译期语法错误）。
          // 把 ' 放在字符类开头即可，无需转义。
          .map((e) => e.trim().replaceAll(RegExp(r'''^['"]|['"]$'''), ''))
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return [s];
  }

  static DateTime? _toDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString().trim());
  }

  static String? _emptyToNull(String? s) {
    if (s == null) return null;
    final t = s.trim();
    return t.isEmpty ? null : t;
  }

  static String _idFromHash(String stem) {
    final h = sha256.convert(utf8.encode(stem)).toString();
    return 'self-${h.substring(0, 10)}';
  }

  /// 指纹计算。与 `domain/fingerprint.dart` 保持一致的算法。
  static String _computeFingerprint(String stem) {
    final h = sha256.convert(utf8.encode(_canonicalForFingerprint(stem)));
    return h.toString().substring(0, 16);
  }

  static String _canonicalForFingerprint(String input) {
    var s = input;
    s = s.replaceAll(RegExp(r'\$\$?'), '');
    s = s.replaceAll(RegExp(r'\\(left|right|big|Big|bigg|Bigg)\b'), '');
    s = s.replaceAll(RegExp(r'\\[dt]frac'), r'\frac');
    // ⚠️ 同 fingerprint.dart：不能用 \b?（词边界断言不可加量词，会抛
    //    FormatException: Nothing to repeat）。改用负向先行断言。
    s = s.replaceAll(
      RegExp(r'\\(?:displaystyle|textstyle|scriptstyle|limits|nolimits'
          r'|quad|qquad|enspace|thinspace)(?![a-zA-Z])'
          r'|\\[,;!:]'),
      '',
    );
    s = s.replaceAll(RegExp(r'\\math(rm|it)\{d\}'), 'd');
    s = s.replaceAll(RegExp(r'\\text\{d\}'), 'd');
    s = s.replaceAll(RegExp(r'\s+'), '');
    // 去掉全部标点。用 r'''...''' 三引号原始字符串以便安全包含 ' 和 "。
    s = s.replaceAll(RegExp(r'''[,.!?;:()\[\]{}<>~\-—_/\\|"'`]'''), '');
    return s.toLowerCase();
  }
}
