/// 错因受控词表的加载。
///
/// ## 为什么错因必须是**受控**的
///
/// 如果让用户自由填写错因，很快就会得到「粗心」「算错了」「不会」「没思路」
/// 这类无法聚合的标签 —— 而错因分析的**全部价值来自聚合**：
/// "我这一个月 12 道题都栽在『方法选择错误』上"才是可行动的信息，
/// "我有 12 条不同的自述"不是。
///
/// 所以词表固定 6 类（`data/error_causes.json`），每类都带：
/// - `definition` —— 边界定义
/// - `typical_signs` —— 典型表现，帮用户判断"我这算不算这一类"
/// - `counter_examples` —— **反例**，明确"这种情况该归到别的类"
/// - `prescription` —— 该错因对应的处方动作（含 `not_action`：**不该**做什么）
/// - `remedy` —— 补救方式：**再做一遍这道题到底有没有用**
///
/// 反例那一项是关键：它把"归类"从主观感觉变成可对照的判断。
///
/// ## `remedy` 为什么单独成为一个维度
///
/// 6 类错因里，`concept` / `idea` / `method` 有一个共同点：
/// **重做本题（或同类变式）就能改善**。而 `calc` / `reading` / `time`
/// 的共同点是**重做本题帮助有限**：
///
/// - `calc` 要的是限时纯计算专项 —— 重复做综合题只会掩盖随机性错误；
/// - `reading` 要的是圈画与复述的动作训练 —— 刷题量本身不改善它；
/// - `time` 要的是限时套卷 —— 不计时的无限刷题只会让慢的习惯固化。
///
/// 这三类的 `not_action` 里都明确写着"不要靠刷题解决"。
/// 所以复习队列把它们与前三类**同样对待**是错的：复习页的场景恰恰就是
/// "重做本题" —— 对 `drill` 类题目，界面必须如实告诉用户
/// "这道题再做一遍帮助有限，你该去做 X"，而不是让他白做一遍。
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// 补救方式：**再做一遍这道题**到底有没有用。
///
/// 这是 `data/error_causes.json` 里 `remedy` 字段的枚举化。
/// 它不描述"错在哪"，而描述"**该怎么补**" —— 前者用于聚合统计，
/// 后者用于决定这张卡在复习队列里的位置、以及界面上该给什么建议。
enum ErrorRemedy {
  /// 重做本题（或同类变式）能改善 —— 错在知识掌握与思路上。
  requiz('重做有效'),

  /// 重做本题帮助有限，需要单独的专项训练 —— 错在基本功、流程或节奏上。
  drill('需专项训练');

  const ErrorRemedy(this.label);

  /// 界面上的短标签。
  final String label;

  /// 从数据文件的字符串解析。
  ///
  /// **缺省为 [requiz]**，理由：字段缺失只可能意味着数据文件还是旧版，
  /// 而旧版的行为就是"重做本题" —— 让缺省值等于既有行为，
  /// 才不会因为一次数据没同步就让复习队列的排序突然改变。
  static ErrorRemedy parse(Object? v) =>
      v?.toString().trim().toLowerCase() == 'drill'
          ? ErrorRemedy.drill
          : ErrorRemedy.requiz;
}

/// 一个错因类别。
class ErrorCause {
  /// 受控 id，如 `concept`。**存进 Markdown 的是它，不是中文名**。
  final String id;

  final String name;

  /// 短名，用于空间紧张的标签。
  final String short;

  /// 边界定义。
  final String definition;

  /// 典型表现。
  final List<String> typicalSigns;

  /// 反例：「这种情况不算本类，该归到 X」。
  final List<String> counterExamples;

  /// 处方。
  final ErrorPrescription? prescription;

  /// 补救方式：重做本题有没有用。见 [ErrorRemedy]。
  final ErrorRemedy remedy;

  /// 容易与哪些知识点同时出现（用于给用户"你可能是这个原因"的提示）。
  final List<String> likelyKpPatterns;

  const ErrorCause({
    required this.id,
    required this.name,
    required this.short,
    required this.definition,
    this.typicalSigns = const [],
    this.counterExamples = const [],
    this.prescription,
    this.remedy = ErrorRemedy.requiz,
    this.likelyKpPatterns = const [],
  });

  /// 重做本题是否**帮不上忙**（需要专项训练）。
  bool get needsDrill => remedy == ErrorRemedy.drill;

  factory ErrorCause.fromJson(Map<String, dynamic> j) => ErrorCause(
        id: j['id']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        short: j['short']?.toString() ?? j['name']?.toString() ?? '',
        definition: j['definition']?.toString() ?? '',
        typicalSigns: _strList(j['typical_signs']),
        counterExamples: _strList(j['counter_examples']),
        prescription: j['prescription'] is Map
            ? ErrorPrescription.fromJson(
                (j['prescription'] as Map).cast<String, dynamic>())
            : null,
        remedy: ErrorRemedy.parse(j['remedy']),
        likelyKpPatterns: _strList(j['likely_kp_patterns']),
      );

  static List<String> _strList(Object? v) => v is List
      ? v.map((e) => e?.toString() ?? '').where((e) => e.isNotEmpty).toList()
      : const [];
}

/// 错因对应的处方。
class ErrorPrescription {
  /// 该做什么。
  final String action;

  /// **不该**做什么。
  ///
  /// 这一项比 [action] 更有价值：错因的顽固之处往往在于
  /// "用错误的方式努力"（例如概念不清却靠刷综合题去补）。
  final String notAction;

  /// 推荐的材料类型。
  final List<String> resourceTypes;

  const ErrorPrescription({
    this.action = '',
    this.notAction = '',
    this.resourceTypes = const [],
  });

  factory ErrorPrescription.fromJson(Map<String, dynamic> j) =>
      ErrorPrescription(
        action: j['action']?.toString() ?? '',
        notAction: j['not_action']?.toString() ?? '',
        resourceTypes: ErrorCause._strList(j['resource_type']),
      );
}

/// 错因词表。
class ErrorCauseCatalog {
  final String version;
  final List<ErrorCause> causes;

  /// 是否允许一道题勾多个错因。
  ///
  /// 由数据文件决定而不是代码里写死 —— 这是产品策略，会随数据调整。
  final bool multiSelect;

  /// UI 展示顺序（受控 id 列表）。数据文件里排好序，避免各处排序不一致。
  final List<String> uiOrder;

  const ErrorCauseCatalog({
    this.version = '0',
    this.causes = const [],
    this.multiSelect = true,
    this.uiOrder = const [],
  });

  /// 按 [uiOrder] 排好序的类别列表。
  ///
  /// 数据文件里 `ui_order` 是权威顺序；没列进去的追加在后面，
  /// 保证**新增错因不会因为忘了改 ui_order 就从界面上消失**。
  List<ErrorCause> get ordered {
    if (uiOrder.isEmpty) return causes;
    final rank = {for (var i = 0; i < uiOrder.length; i++) uiOrder[i]: i};
    final out = [...causes];
    out.sort((a, b) {
      final ra = rank[a.id] ?? uiOrder.length;
      final rb = rank[b.id] ?? uiOrder.length;
      return ra != rb ? ra.compareTo(rb) : a.id.compareTo(b.id);
    });
    return out;
  }

  /// id → 中文名。认不出来时**返回 id 本身**，不返回空串。
  ///
  /// 认不出来通常意味着"题目里存了一个已经不在词表里的错因 id"
  /// （词表改过、或者 AI 标了一个不存在的）。这时把 id 显示出来，
  /// 用户和开发者至少能看到是哪一个；显示空串等于把线索抹掉。
  String nameOf(String id) {
    for (final c in causes) {
      if (c.id == id) return c.name;
    }
    return id;
  }

  ErrorCause? byId(String id) {
    for (final c in causes) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 按 id 批量取错因，**按词表的展示顺序**返回（与录入页看到的顺序一致）。
  List<ErrorCause> resolve(Iterable<String> ids) {
    final want = ids.toSet();
    if (want.isEmpty) return const [];
    return ordered.where((c) => want.contains(c.id)).toList();
  }

  /// 从存储格式里取出**原始** id 列表（不做词表校验）。
  ///
  /// 需要它是因为调用方常要区分两件事：
  /// "这个词表里没有"（[unknownIdsOf] 非空 → 该如实提示）
  /// 与"压根没解析出东西"。只给 [resolveJson] 就分不出来了。
  ///
  /// 解析失败一律当作**空列表**，不抛异常 —— 错因是辅助信息，
  /// 一份坏数据不该让复习页打不开（与 [ErrorCauseRepository.load] 同一取舍）。
  List<String> idsOfJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded.map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  /// 解析一份 `error_causes` JSON 数组字符串并解析成错因。
  ///
  /// 这是 `user_problem_state.error_causes` 与 `problems_index.error_causes`
  /// 两列的存储格式（如 `["concept","calc"]`）。
  List<ErrorCause> resolveJson(String? raw) => resolve(idsOfJson(raw));

  /// 在 [ids] 里、但**不在词表中**的 id。
  ///
  /// 用途：题目里存的错因 id 可能来自更早版本的词表（词表改过，
  /// 或者 AI 标了一个不存在的 id）。静默丢掉它们会让人误以为
  /// "这题没标错因"，所以调用方应当把结果如实显示出来 ——
  /// 这条与 [nameOf] 认不出时返回 id 本身是同一个理由。
  List<String> unknownIdsOf(Iterable<String> ids) =>
      ids.where((id) => byId(id) == null).toList();

  static const ErrorCauseCatalog empty = ErrorCauseCatalog();

  factory ErrorCauseCatalog.fromJson(Map<String, dynamic> j) =>
      ErrorCauseCatalog(
        version: j['version']?.toString() ?? '0',
        causes: (j['error_causes'] as List? ?? [])
            .whereType<Map<Object?, Object?>>()
            .map((m) => ErrorCause.fromJson(m.cast<String, dynamic>()))
            .where((c) => c.id.isNotEmpty)
            .toList(),
        multiSelect: j['multi_select'] != false,
        uiOrder: ErrorCause._strList(j['ui_order']),
      );
}

/// 错因词表仓库。
///
/// 与 [KnowledgeRepository] 一样是单例缓存：词表只有几 KB，
/// 但会被列表、详情页、录入页反复读取。
class ErrorCauseRepository {
  ErrorCauseRepository._();

  static final ErrorCauseRepository instance = ErrorCauseRepository._();

  static const String assetPath = 'assets/data/error_causes.json';

  ErrorCauseCatalog? _cached;

  ErrorCauseCatalog? get cached => _cached;

  /// 载入词表。失败时返回 [ErrorCauseCatalog.empty] 而不是抛异常 ——
  /// 错因选择是**可选的**辅助信息，它的缺失不该让录入页打不开。
  Future<ErrorCauseCatalog> load({bool force = false}) async {
    if (!force && _cached != null) return _cached!;
    try {
      final raw = await rootBundle.loadString(assetPath);
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return ErrorCauseCatalog.empty;
      final catalog =
          ErrorCauseCatalog.fromJson(decoded.cast<String, dynamic>());
      _cached = catalog;
      return catalog;
    } catch (_) {
      return ErrorCauseCatalog.empty;
    }
  }

  /// 仅供测试。
  void reset() => _cached = null;
}
