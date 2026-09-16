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
/// - `prescription` —— 该错因对应的处方动作
///
/// 反例那一项是关键：它把"归类"从主观感觉变成可对照的判断。
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

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
    this.likelyKpPatterns = const [],
  });

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
