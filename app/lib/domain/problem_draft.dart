/// 录入草稿：界面上正在编辑的那道题。
///
/// ## 为什么需要一个单独的"草稿"类型
///
/// [Problem] 是**不可变的、已定稿的**内容模型 —— 它要序列化成 Markdown、
/// 参与索引、被 FSRS 引用。让表单直接改 [Problem] 会带来两个问题：
///
/// 1. **半成品状态没有位置**：用户输入到一半时，`stem` 可能为空、
///    `fingerprint` 还没算、主考点还没选。这些中间态不该出现在 [Problem] 里。
/// 2. **校验时机说不清**：不可变模型没法表达"这个字段是错的"，
///    只能把错误塞进 `warnings`，最终污染存盘文件。
///
/// 所以草稿是**可变的、可以不合法的**；[build] 是唯一的"转正"入口，
/// 它会重新计算 [ProblemFingerprint]，并把校验结论写进 `needsReview`。
///
/// ## 60 秒录入目标与校验强度的取舍
///
/// 规划里的硬指标是"掐表 ≤ 60 秒"。因此校验**只卡真正致命的**：
/// - 阻断：题干为空、选择题选项不足 2 个、主考点 id 不在本体里
/// - 非阻断：没选主考点、没选错因、题干里的 `$` 不成对
///
/// 没选主考点**不阻断**保存，而是把题目标成 `needsReview` ——
/// 否则用户会被迫在录入现场翻 198 个知识点，这一条就足以让 60 秒变成 5 分钟。
library;

import '../data/markdown/problem_markdown.dart';
import 'fingerprint.dart';
import 'knowledge/knowledge_point.dart';

/// 校验问题的严重程度。
enum DraftIssueLevel {
  /// 阻断保存。
  blocking,

  /// 可以保存，但要在界面上提示，并且会写进 `needs_review`。
  warning,
}

/// 一条校验问题。
class DraftIssue {
  final DraftIssueLevel level;

  /// 出问题的字段（用于把界面焦点定位过去）。
  final String field;

  final String message;

  const DraftIssue({
    required this.level,
    required this.field,
    required this.message,
  });

  @override
  String toString() => '[${level.name}] $field: $message';
}

/// 保存结果里"这道题已经存在"的判断依据。
enum DuplicateKind {
  /// 没有重复。
  none,

  /// 题干指纹与已有题目相同 —— 大概率是同一道题。
  sameFingerprint,
}

/// 一道题的编辑草稿。
class ProblemDraft {
  /// 题目 id。为空表示"还没定稿"，[build] 时会按指纹生成。
  ///
  /// 为什么允许为空：让**重复录入同一道题自动落回同一个文件**，
  /// 而不是每次都生成新 id 造出两份。
  String? id;

  String subject;

  QuestionType qtype;

  /// 1 基础 · 2 综合 · 3 拓展
  int difficulty;

  /// 题干（Markdown + LaTeX）。
  String stem;

  /// 选择题选项（仅 [QuestionType.choice] 用）。
  List<String> options;

  String? answer;
  String? solution;

  /// 用户笔记（会写进 Markdown 的 `## 我的笔记`）。
  String? note;

  String? source;
  SourceType sourceType;
  int? sourceYear;

  /// 主考点 id。null 表示尚未标注。
  String? primaryKpId;

  /// 次考点 id。
  List<String> secondaryKpIds;

  /// 错因，取值见 `data/error_causes.json`。
  List<String> errorCauses;

  List<String> tags;

  /// 是否由 AI 标注过。
  bool aiTagged;

  /// AI 对主考点的置信度。
  double? aiConfidence;

  /// 是否要求人工复核。
  ///
  /// 由 AI 流程（置信度低于门禁）或用户手动勾选设置；
  /// [build] 还会 **OR** 上"没有主考点"这一条 —— 没分类的题必然要补。
  bool needsReview;

  ProblemDraft({
    this.id,
    this.subject = 'math1',
    this.qtype = QuestionType.solve,
    this.difficulty = 2,
    this.stem = '',
    List<String>? options,
    this.answer,
    this.solution,
    this.note,
    this.source,
    this.sourceType = SourceType.textbook,
    this.sourceYear,
    this.primaryKpId,
    List<String>? secondaryKpIds,
    List<String>? errorCauses,
    List<String>? tags,
    this.aiTagged = false,
    this.aiConfidence,
    this.needsReview = false,
  })  : options = options ?? [],
        secondaryKpIds = secondaryKpIds ?? [],
        errorCauses = errorCauses ?? [],
        tags = tags ?? [];

  /// 从已有题目反向填充草稿（用于"编辑已录入的题"）。
  factory ProblemDraft.fromProblem(Problem p) {
    String? primary;
    final secondary = <String>[];
    for (final k in p.knowledge) {
      if (k.isPrimary) {
        primary = k.id;
      } else {
        secondary.add(k.id);
      }
    }
    return ProblemDraft(
      id: p.id,
      subject: p.subject,
      qtype: p.qtype,
      difficulty: p.difficulty,
      stem: p.stem,
      options: [...p.options],
      answer: p.answer,
      solution: p.solution,
      note: p.note,
      source: p.source,
      sourceType: p.sourceType,
      sourceYear: p.sourceYear,
      primaryKpId: primary,
      secondaryKpIds: secondary,
      errorCauses: [...p.errorCauses],
      tags: [...p.tags],
      aiTagged: p.aiTagged,
      aiConfidence: p.aiConfidence,
      needsReview: p.needsReview,
    );
  }

  /// 题干是否为空（只算真正的空白）。
  bool get isEmpty => stem.trim().isEmpty;

  /// 校验。
  ///
  /// [knowledge] 为 null 时跳过"知识点 id 是否存在于本体"的检查
  /// （本体还没载入完时不该误报）。
  List<DraftIssue> validate({KnowledgeBase? knowledge}) {
    final issues = <DraftIssue>[];

    if (isEmpty) {
      issues.add(const DraftIssue(
        level: DraftIssueLevel.blocking,
        field: 'stem',
        message: '题干不能为空',
      ));
    }

    if (qtype == QuestionType.choice) {
      final real = options.where((o) => o.trim().isNotEmpty).length;
      if (real < 2) {
        issues.add(const DraftIssue(
          level: DraftIssueLevel.blocking,
          field: 'options',
          message: '选择题至少要有 2 个选项',
        ));
      }
    }

    // `$` 不成对：LaTeX 定界符缺失是最常见的录入笔误，
    // 而且后果很隐蔽 —— 后面的所有内容都会被当成公式。
    final dollars = RegExp(r'(?<!\\)\$').allMatches(stem).length;
    if (dollars.isOdd) {
      issues.add(DraftIssue(
        level: DraftIssueLevel.warning,
        field: 'stem',
        message: '题干里的 `\$` 有 $dollars 个（奇数），可能有未闭合的公式',
      ));
    }

    if (primaryKpId == null || primaryKpId!.isEmpty) {
      issues.add(const DraftIssue(
        level: DraftIssueLevel.warning,
        field: 'primaryKpId',
        message: '还没有选主考点 —— 可以保存，之后在错题本里补',
      ));
    } else if (knowledge != null && !knowledge.byId.containsKey(primaryKpId)) {
      issues.add(DraftIssue(
        level: DraftIssueLevel.blocking,
        field: 'primaryKpId',
        message: '主考点「$primaryKpId」不在知识点本体里',
      ));
    }

    if (knowledge != null) {
      for (final s in secondaryKpIds) {
        if (!knowledge.byId.containsKey(s)) {
          issues.add(DraftIssue(
            level: DraftIssueLevel.warning,
            field: 'secondaryKpIds',
            message: '次考点「$s」不在知识点本体里，已忽略',
          ));
        }
      }
    }

    if (errorCauses.isEmpty) {
      issues.add(const DraftIssue(
        level: DraftIssueLevel.warning,
        field: 'errorCauses',
        message: '没有勾选错因（规划里允许事后批量补）',
      ));
    }

    return issues;
  }

  /// 是否存在阻断性问题。
  bool hasBlocking({KnowledgeBase? knowledge}) =>
      validate(knowledge: knowledge)
          .any((i) => i.level == DraftIssueLevel.blocking);

  /// 计算题干指纹。
  String fingerprint() => ProblemFingerprint.compute(stem);

  /// 转正成 [Problem]。
  ///
  /// [now] 与 [idOverride] 只为服务层与测试可注入：
  /// - [now] 固定时间戳，让 id 可预测
  /// - [idOverride] 覆盖时沿用已有题目的 id（**不能**生成新 id，
  ///   否则同一道题会出现两个文件）
  Problem build({
    KnowledgeBase? knowledge,
    DateTime? now,
    String? idOverride,
  }) {
    final fp = fingerprint();
    final secondary = knowledge == null
        ? [...secondaryKpIds]
        : secondaryKpIds.where((s) => knowledge.byId.containsKey(s)).toList();

    final knowledgeRefs = <KnowledgeRef>[
      if (primaryKpId != null && primaryKpId!.isNotEmpty)
        KnowledgeRef(id: primaryKpId!, role: 'primary', relevance: 1.0),
      for (final s in secondary)
        KnowledgeRef(id: s, role: 'secondary', relevance: 1.0),
    ];

    return Problem(
      id: idOverride ??
          ((id == null || id!.isEmpty) ? generateId(fp, now: now) : id!),
      fingerprint: fp,
      subject: subject,
      qtype: qtype,
      difficulty: difficulty,
      source: _nullIfBlank(source),
      sourceType: sourceType,
      sourceYear: sourceYear,
      knowledge: knowledgeRefs,
      errorCauses: [...errorCauses],
      options: options.where((o) => o.trim().isNotEmpty).toList(),
      tags: [...tags],
      stem: stem.trim(),
      answer: _nullIfBlank(answer),
      solution: _nullIfBlank(solution),
      note: _nullIfBlank(note),
      createdAt: now ?? DateTime.now(),
      aiTagged: aiTagged,
      aiConfidence: aiConfidence,
      // ⚠️ 「没选主考点」必须 OR 进来：那是"分类产品的地基还没打"，
      // 和 AI 置信度低是两回事，不能因为用户手动选了一个就漏掉另一种。
      needsReview:
          needsReview || primaryKpId == null || primaryKpId!.isEmpty,
    );
  }

  /// 由指纹生成人类可读的 id。
  ///
  /// 形式：`self-20260315-a1b2c3d4`
  /// - `self-` 前缀表明是自己录入的（区别于 `2023-shu1-T18` 这类外部题库 id）
  /// - 日期便于在文件管理器里按时间翻
  /// - 指纹前 8 位保证同一道题**重复录入会落到同一个 id**
  static String generateId(String fingerprint, {DateTime? now}) {
    final d = now ?? DateTime.now();
    final date = '${d.year.toString().padLeft(4, '0')}'
        '${d.month.toString().padLeft(2, '0')}'
        '${d.day.toString().padLeft(2, '0')}';
    final short = fingerprint.length >= 8 ? fingerprint.substring(0, 8) : fingerprint;
    return 'self-$date-$short';
  }

  static String? _nullIfBlank(String? s) {
    if (s == null) return null;
    final t = s.trim();
    return t.isEmpty ? null : t;
  }

  /// 深拷贝（用于撤销/重置表单）。
  ProblemDraft copy() => ProblemDraft(
        id: id,
        subject: subject,
        qtype: qtype,
        difficulty: difficulty,
        stem: stem,
        options: [...options],
        answer: answer,
        solution: solution,
        note: note,
        source: source,
        sourceType: sourceType,
        sourceYear: sourceYear,
        primaryKpId: primaryKpId,
        secondaryKpIds: [...secondaryKpIds],
        errorCauses: [...errorCauses],
        tags: [...tags],
        aiTagged: aiTagged,
        aiConfidence: aiConfidence,
        needsReview: needsReview,
      );

  @override
  String toString() => 'ProblemDraft(qtype=${qtype.id}, '
      'stem=${stem.length}字, primary=$primaryKpId, '
      'causes=${errorCauses.length})';
}
