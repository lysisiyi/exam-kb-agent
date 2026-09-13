/// 知识点本体模型。
///
/// 知识点树是**整个系统的尺子**：
/// - 错题靠它分类（AI 标注的输出是知识点 id，不是自由文本）
/// - 画像靠它聚合（按知识点统计掌握度）
/// - 组卷靠它加权（`examWeight` 决定抽题偏好）
///
/// 因此知识点 id 一旦发布就**不能随意改动** —— 会打断所有历史数据的关联。
library;

/// 一个知识点节点。
class KnowledgePoint {
  /// 全局唯一 id，如 `math1.calc.limit.eq_infinitesimal`。
  final String id;

  final String name;

  /// 层级：1 科目 · 2 学科分段 · 3 章节 · 4 知识点。
  final int level;

  /// 父节点 id。根节点为 null。
  final String? parentId;

  /// 是否叶子节点。**只有叶子才能被标注为题目考点。**
  final bool isLeaf;

  /// 考频权重 0–1。用于组卷软偏好与薄弱点排序。
  ///
  /// 章节级来自 `exam_frequency.json`（权威值）；
  /// 叶子级由 `tools/data/merge_knowledge.py` 派生。
  final double? examWeight;

  /// 定义 / 定理陈述。**这是给 LLM 判断用的核心字段。**
  final String? definition;

  /// 核心公式（LaTeX）。同时充当标注时的关键词召回索引。
  final List<String> formulas;

  /// **别名** —— 题干里可能出现、但和知识点名不同的说法。
  ///
  /// ## 为什么必须有这个字段
  ///
  /// 召回层是纯规则的，靠字面重合。知识点名往往是复合短语，
  /// 而题干常常只写其中一部分，或只写符号：
  ///
  /// ```
  /// 知识点名：正态分布及其标准化计算
  /// 题干：    设 X~N(0,1)，求 P{|X|<1}
  /// ```
  ///
  /// 两边没有任何共同子串 —— 规则层完全匹配不上，正确答案进不了候选集，
  /// LLM 再强也没用（实测 4 道召回失败题全是这个模式）。
  ///
  /// 别名就是把知识点名"翻译"成题干可能的样子：
  /// - **名称片段**（自动派生）：「正态分布」「极值」「二重积分」
  /// - **符号写法**（人工维护）：「X\sim N(\mu,\sigma^2)」「\iint_D」
  ///
  /// 数据由 `tools/data/gen_aliases.py` 生成，人工部分在
  /// `data/knowledge_points/alias_overrides.json`。
  final List<String> aliases;

  /// 常见陷阱。
  final List<String> commonTraps;

  /// 历年出现年份。
  final List<int> examYears;

  /// 常见题型：choice / fill / solve / proof。
  final List<String> typicalQtypes;

  /// 难度范围 [min, max]。
  final List<int> difficultyRange;

  const KnowledgePoint({
    required this.id,
    required this.name,
    required this.level,
    this.parentId,
    this.isLeaf = false,
    this.examWeight,
    this.definition,
    this.formulas = const [],
    this.aliases = const [],
    this.commonTraps = const [],
    this.examYears = const [],
    this.typicalQtypes = const [],
    this.difficultyRange = const [1, 3],
  });

  /// 所属章节 id（截取到第 3 段）。叶子为 4 段。
  String get chapterId {
    final parts = id.split('.');
    return parts.length >= 3 ? parts.take(3).join('.') : id;
  }

  /// 考频的年数。用于 UI 展示"近 15 年考了 N 次"。
  int get examCount => examYears.length;

  factory KnowledgePoint.fromJson(Map<String, dynamic> j) => KnowledgePoint(
        id: j['id']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        level: (j['level'] as num?)?.toInt() ?? 4,
        parentId: j['parent_id']?.toString(),
        isLeaf: j['is_leaf'] == true,
        examWeight: (j['exam_weight'] as num?)?.toDouble(),
        definition: j['definition']?.toString(),
        formulas: _strList(j['formulas']),
        aliases: _strList(j['aliases']),
        commonTraps: _strList(j['common_traps']),
        examYears: _intList(j['exam_years']),
        typicalQtypes: _strList(j['typical_qtypes']),
        difficultyRange: _intList(j['difficulty_range']).isEmpty
            ? const [1, 3]
            : _intList(j['difficulty_range']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'level': level,
        if (parentId != null) 'parent_id': parentId,
        'is_leaf': isLeaf,
        if (examWeight != null) 'exam_weight': examWeight,
        if (definition != null) 'definition': definition,
        if (formulas.isNotEmpty) 'formulas': formulas,
        if (aliases.isNotEmpty) 'aliases': aliases,
        if (commonTraps.isNotEmpty) 'common_traps': commonTraps,
        if (examYears.isNotEmpty) 'exam_years': examYears,
        if (typicalQtypes.isNotEmpty) 'typical_qtypes': typicalQtypes,
        'difficulty_range': difficultyRange,
      };

  static List<String> _strList(Object? v) {
    if (v is List) {
      return v.map((e) => e?.toString() ?? '').where((e) => e.isNotEmpty).toList();
    }
    return const [];
  }

  static List<int> _intList(Object? v) {
    if (v is List) {
      return v
          .map((e) => e is num ? e.toInt() : int.tryParse(e.toString()))
          .whereType<int>()
          .toList();
    }
    return const [];
  }

  @override
  String toString() => 'KnowledgePoint($id, $name, leaf=$isLeaf, w=$examWeight)';
}

/// 一个科目的完整知识点本体。
class KnowledgeBase {
  final String subject;
  final String subjectName;
  final String version;

  /// 全部节点，扁平存放。
  final List<KnowledgePoint> nodes;

  /// id → 节点。
  final Map<String, KnowledgePoint> byId;

  /// 父 id → 直接子节点（已按 level 与名称排序）。
  final Map<String?, List<KnowledgePoint>> childrenOf;

  KnowledgeBase({
    required this.subject,
    required this.subjectName,
    required this.version,
    required this.nodes,
  })  : byId = {for (final n in nodes) n.id: n},
        childrenOf = _groupByParent(nodes);

  static Map<String?, List<KnowledgePoint>> _groupByParent(
    List<KnowledgePoint> nodes,
  ) {
    final m = <String?, List<KnowledgePoint>>{};
    for (final n in nodes) {
      m.putIfAbsent(n.parentId, () => []).add(n);
    }
    for (final list in m.values) {
      list.sort((a, b) {
        // 章节顺序由 id 决定（保持与考试大纲一致的书写顺序）
        final c = a.id.compareTo(b.id);
        return c;
      });
    }
    return m;
  }

  /// 全部叶子节点（可被标注为考点的）。
  late final List<KnowledgePoint> leaves =
      nodes.where((n) => n.isLeaf).toList(growable: false);

  /// 全部章节节点。
  late final List<KnowledgePoint> chapters =
      nodes.where((n) => !n.isLeaf && n.level == 3).toList(growable: false);

  /// 根节点。
  KnowledgePoint? get root => byId[subject];

  /// 从根到该节点的路径（含自身）。
  List<KnowledgePoint> pathTo(String id) {
    final path = <KnowledgePoint>[];
    KnowledgePoint? cur = byId[id];
    var guard = 0;
    while (cur != null && guard++ < 16) {
      path.insert(0, cur);
      final pid = cur.parentId;
      if (pid == null) break;
      cur = byId[pid];
    }
    return path;
  }

  /// 该节点的全部后代叶子 id。用于"某章节下所有考点"的查询。
  List<String> leafIdsUnder(String nodeId) {
    final out = <String>[];
    void walk(String id) {
      final self = byId[id];
      if (self == null) return;
      if (self.isLeaf) {
        out.add(self.id);
        return;
      }
      for (final c in childrenOf[id] ?? const <KnowledgePoint>[]) {
        walk(c.id);
      }
    }

    walk(nodeId);
    return out;
  }

  /// 按考频权重排序的叶子（降序）。用于"高频考点"展示与组卷加权。
  List<KnowledgePoint> leavesByWeight({int? limit}) {
    final sorted = [...leaves]
      ..sort((a, b) => (b.examWeight ?? 0).compareTo(a.examWeight ?? 0));
    return limit == null ? sorted : sorted.take(limit).toList();
  }

  factory KnowledgeBase.fromJson(Map<String, dynamic> j) {
    final rawNodes = (j['nodes'] as List?) ?? const [];
    final nodes = rawNodes
        // jsonDecode 产出的元素是 Map<String, dynamic>，但静态类型是 dynamic。
        // 这里显式标注类型参数以满足 strict-raw-types。
        .whereType<Map<String, dynamic>>()
        .map(KnowledgePoint.fromJson)
        .where((n) => n.id.isNotEmpty)
        .toList();

    return KnowledgeBase(
      subject: j['subject']?.toString() ?? 'unknown',
      subjectName: j['subject_name']?.toString() ?? '',
      version: j['version']?.toString() ?? '0',
      nodes: nodes,
    );
  }
}
