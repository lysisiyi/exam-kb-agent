/// 稳健的结构化输出解析。
///
/// ## 为什么需要"三重保险"
///
/// 我们要求 LLM 输出 JSON，但实测中不同服务商的表现差异很大：
///
/// | 现象 | 常见于 |
/// |---|---|
/// | 直接输出合法 JSON | 大多数情况 |
/// | 用 ` ```json ` 包裹 | Claude、部分国产模型 |
/// | 前后带解释文字 | 弱模型、未开 JSON mode 时 |
/// | 单引号、尾随逗号 | 小模型 |
/// | 中文全角标点 | 中文模型偶发 |
/// | **顶层是数组而不是对象** | 智谱 `glm-4v-flash`（实测） |
///
/// 而标注流程是**批量**的（可能一次跑几百道题），
/// 单次解析失败不应该让整批任务失败。所以这里做层层降级。
///
/// ## 顶层是数组：静默丢数据的坑
///
/// 让模型"把这一页的题都转写成 JSON"，它可能给
/// `{"problems": [...]}`，也可能**直接给 `[{...}, {...}]`**。
/// 后者如果只按对象解析，降级路径会取到"第一个平衡的 `{...}`" ——
/// 结果是**一页只进来第一道题，其余静默消失**，还报一句
/// "模型没有用 problems 包一层"。所以数组必须被显式识别，
/// 而不是靠"取第一个对象"蒙过去。
///
/// ## 设计原则
/// **宁可返回"部分结果 + 警告"，也不要直接抛异常。**
/// 调用方拿到 [JsonExtraction] 后可以决定：用结果、还是重试、还是进人工队列。
library;

import 'dart:convert';

/// 一次 JSON 提取的结果。
///
/// ## `ok` 只管对象
///
/// [value]（对象）与 [listValue]（数组）最多一个非空。
/// [ok] 仍然只表示"拿到了对象" —— 这是为了不改动已有的调用方语义
/// （标注器要的就是对象）。需要接受数组的调用方显式传
/// `acceptArray: true`，然后看 [hasList]。
class JsonExtraction {
  /// 解析出的对象。null 表示没拿到对象。
  final Map<String, dynamic>? value;

  /// 顶层是 JSON 数组时，元素放在这里（此时 [value] 为 null）。
  ///
  /// ⚠️ 真实踩过的坑：智谱 `glm-4v-flash` 面对"一页多题"的图片时
  /// **不写 `{"problems": [...]}` 包层，直接给一个数组**。
  /// 早先只认对象，于是解析降级成"取第一个平衡的 `{...}`"，
  /// 一页 3 道题只进来 1 道，还报"模型没用 problems 包一层"（误诊）。
  final List<dynamic>? listValue;

  /// 使用的策略标识，用于统计各服务商的输出质量。
  final String strategy;

  /// 过程中产生的问题（不致命）。
  final List<String> warnings;

  /// 是否拿到了 JSON **对象**。
  bool get ok => value != null;

  /// 是否拿到的是 JSON **数组**。
  bool get hasList => listValue != null;

  /// 对象与数组都没拿到。
  bool get isEmpty => value == null && listValue == null;

  const JsonExtraction._({
    required this.value,
    required this.strategy,
    this.listValue,
    this.warnings = const [],
  });

  factory JsonExtraction.success(
    Map<String, dynamic> v,
    String strategy, {
    List<String> warnings = const [],
  }) =>
      JsonExtraction._(value: v, strategy: strategy, warnings: warnings);

  /// 顶层是数组时的成功结果（[value] 为 null，[ok] 为 false）。
  factory JsonExtraction.successList(
    List<dynamic> v,
    String strategy, {
    List<String> warnings = const [],
  }) =>
      JsonExtraction._(
        value: null,
        listValue: v,
        strategy: strategy,
        warnings: warnings,
      );

  factory JsonExtraction.failure(String strategy, List<String> warnings) =>
      JsonExtraction._(value: null, strategy: strategy, warnings: warnings);

  @override
  String toString() =>
      'JsonExtraction(${ok ? "ok" : (hasList ? "list" : "fail")}, '
      'strategy=$strategy'
      '${warnings.isEmpty ? "" : ", warnings=${warnings.length}"})';
}

/// 从 LLM 的原始文本中提取 JSON 对象。
abstract final class RobustJson {
  const RobustJson._();

  /// 依次尝试多种策略，返回第一个成功的。
  ///
  /// [acceptArray]：顶层就是 JSON 数组时算不算成功。
  /// - 默认 `false`：数组**不算**成功，返回
  ///   [JsonExtraction.failure]，警告里说明"是数组不是对象"。
  ///   标注器就用这个默认值 —— 它要的是对象，而且**绝不能**
  ///   悄悄拿数组的第一个元素当结果。
  /// - 传 `true`：数组装进 [JsonExtraction.listValue]。
  ///   批量导入要这个：实测模型经常直接给题目数组。
  static JsonExtraction extract(String raw, {bool acceptArray = false}) {
    final warnings = <String>[];

    if (raw.trim().isEmpty) {
      return JsonExtraction.failure('empty', ['模型返回空内容']);
    }

    // 策略 1：直接解析（最理想，多数情况命中）
    final direct = _tryParseAny(raw);
    if (direct != null) return _fromAny(direct, 'direct', warnings, acceptArray);

    // 策略 2：剥掉 ```json ... ``` 围栏
    final fenced = _stripCodeFence(raw);
    if (fenced != null && fenced != raw) {
      final v = _tryParseAny(fenced);
      if (v != null) {
        return _fromAny(v, 'code-fence', warnings, acceptArray);
      }
      warnings.add('剥离代码围栏后仍不是合法 JSON');
    }

    // 策略 3：取第一个平衡的 {...} / [...] 块
    final block = _firstBalancedAny(raw);
    if (block != null) {
      final isArray = block.startsWith('[');
      final v = _tryParseAny(block);
      if (v != null) {
        return _fromAny(
          v,
          isArray ? 'balanced-array' : 'balanced-braces',
          warnings,
          acceptArray,
        );
      }
      // 策略 4：修常见瑕疵后再试
      final repaired = _repairCommonIssues(block);
      final vr = _tryParseAny(repaired);
      if (vr != null) {
        warnings.add('修复了 JSON 中的常见格式瑕疵（尾随逗号/单引号等）');
        return _fromAny(vr, 'repaired', warnings, acceptArray);
      }
      // 数组被截断（`[{...},{...` 这种）：把里面已经完整的对象救回来。
      // 没闭合的那个对象只能丢 —— 半截题干比没有题干更糟。
      if (acceptArray && isArray) {
        final objs = _balancedObjects(block);
        if (objs.isNotEmpty) {
          warnings.add('模型输出的数组被截断，'
              '已救回其中 ${objs.length} 个完整条目（后面可能还有遗漏）');
          return JsonExtraction.successList(objs, 'array-salvage',
              warnings: warnings);
        }
      }
      warnings.add('提取到花括号块但无法解析为 JSON');
    } else {
      warnings.add('未找到平衡的 {...} 块');
    }

    // 策略 5：全角标点归一后再试一次
    final normalized = _normalizeFullWidth(raw);
    if (normalized != raw) {
      final fenced2 = _stripCodeFence(normalized) ?? normalized;
      final block2 = _firstBalancedAny(fenced2);
      if (block2 != null) {
        final v = _tryParseAny(_repairCommonIssues(block2));
        if (v != null) {
          warnings.add('归一化全角标点后解析成功');
          return _fromAny(v, 'fullwidth-normalized', warnings, acceptArray);
        }
      }
    }

    return JsonExtraction.failure('all-failed', [
      ...warnings,
      '原始内容前 200 字符：${_preview(raw)}',
    ]);
  }

  /// 把"解析出来的东西"（对象或数组）变成结果。
  static JsonExtraction _fromAny(
    Object v,
    String strategy,
    List<String> warnings,
    bool acceptArray,
  ) {
    final w = List<String>.of(warnings);
    if (v is Map) {
      return JsonExtraction.success(v.cast<String, dynamic>(), strategy,
          warnings: w);
    }
    final list = (v as List).cast<dynamic>();
    if (!acceptArray) {
      return JsonExtraction.failure('array-not-object', [
        ...w,
        '模型返回的是 JSON 数组而不是对象（${list.length} 个元素）',
      ]);
    }
    return JsonExtraction.successList(list, strategy, warnings: w);
  }

  /// 从结果里取字符串字段（容忍类型意外的值）。
  static String? stringField(Map<String, dynamic> j, String key) {
    final v = j[key];
    if (v == null) return null;
    if (v is String) return v.trim().isEmpty ? null : v.trim();
    if (v is num || v is bool) return v.toString();
    if (v is List) return v.isEmpty ? null : v.first.toString();
    return null;
  }

  /// 取数值字段（容忍 "0.92" 这类字符串）。
  static double? doubleField(Map<String, dynamic> j, String key) {
    final v = j[key];
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim());
    return null;
  }

  /// 取整数字段。
  static int? intField(Map<String, dynamic> j, String key) {
    final v = j[key];
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  /// 取布尔字段（容忍 "true"/"是"）。
  static bool? boolField(Map<String, dynamic> j, String key) {
    final v = j[key];
    if (v == null) return null;
    if (v is bool) return v;
    if (v is String) {
      final s = v.trim().toLowerCase();
      if (s == 'true' || s == 'yes' || s == '是') return true;
      if (s == 'false' || s == 'no' || s == '否') return false;
    }
    return null;
  }

  /// 取字符串列表（容忍单个字符串或逗号分隔）。
  static List<String> stringListField(Map<String, dynamic> j, String key) {
    final v = j[key];
    if (v == null) return const [];
    if (v is List) {
      return v
          .map((e) {
            if (e is String) return e.trim();
            if (e is Map) {
              // 容忍 [{"id": "x"}] 这种结构
              final id = e['id'] ?? e['kp_id'] ?? e['name'];
              return id?.toString().trim() ?? '';
            }
            return e?.toString().trim() ?? '';
          })
          .where((e) => e.isNotEmpty)
          .toList();
    }
    if (v is String) {
      final s = v.trim();
      if (s.isEmpty) return const [];
      // 容忍 "a, b, c" 或 "a、b、c"
      return s
          .split(RegExp(r'[,、;；]'))
          .map((e) => e.trim().replaceAll(RegExp(r'''^['"]|['"]$'''), ''))
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return const [];
  }

  /// 取对象列表。
  static List<Map<String, dynamic>> objectListField(
    Map<String, dynamic> j,
    String key,
  ) {
    final v = j[key];
    if (v is! List) return const [];
    return v
        .whereType<Map<Object?, Object?>>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  // ───────────────────────────────────────────────────────────────────────
  // 内部工具
  // ───────────────────────────────────────────────────────────────────────

  static Map<String, dynamic>? _tryParse(String s) {
    final v = _tryParseAny(s);
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  /// 解析成对象**或**数组。失败的返回 null。
  static Object? _tryParseAny(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    try {
      final decoded = jsonDecode(t);
      if (decoded is Map) return decoded.cast<String, dynamic>();
      if (decoded is List) return decoded;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 剥离 ` ```json ... ``` ` 或 ` ``` ... ``` `。
  static String? _stripCodeFence(String s) {
    final m = RegExp(r'```(?:json|JSON)?\s*\n?([\s\S]*?)```').firstMatch(s);
    if (m != null) return m.group(1)?.trim();
    // 只有开围栏没有闭合（被截断）
    final open = RegExp(r'```(?:json|JSON)?\s*\n?([\s\S]*)$').firstMatch(s);
    if (open != null) return open.group(1)?.trim();
    return null;
  }

  /// 找出第一个**花括号或方括号平衡**的块，`{...}` 与 `[...]` 谁先出现取谁。
  ///
  /// 用计数而非正则 —— 正则处理不了嵌套对象与字符串里的括号。
  /// 同时要正确跳过字符串字面量里的括号。
  ///
  /// 返回的片段**可能是不平衡的**（多半是被截断）：这时返回从起点到末尾的
  /// 剩余内容，让调用方去尝试修复或救回其中的完整条目。
  static String? _firstBalancedAny(String s) {
    final brace = s.indexOf('{');
    final bracket = s.indexOf('[');
    int start;
    if (brace < 0 && bracket < 0) return null;
    if (brace < 0) {
      start = bracket;
    } else if (bracket < 0) {
      start = brace;
    } else {
      start = brace < bracket ? brace : bracket;
    }
    return _balancedFrom(s, start);
  }

  /// 从 [start]（必须是 `{` 或 `[`）开始扫描到匹配的闭合符。
  ///
  /// 不平衡时返回 `s.substring(start)`。
  static String? _balancedFrom(String s, int start) {
    if (start < 0 || start >= s.length) return null;
    final open = s[start];
    if (open != '{' && open != '[') return null;
    final close = open == '{' ? '}' : ']';

    var depth = 0;
    var inString = false;
    var escaped = false;

    for (var i = start; i < s.length; i++) {
      final c = s[i];

      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (c == r'\') {
          escaped = true;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }

      if (c == '"') {
        inString = true;
      } else if (c == open) {
        depth++;
      } else if (c == close) {
        depth--;
        if (depth == 0) return s.substring(start, i + 1);
      }
    }
    // 不平衡（多半是被截断）
    return depth > 0 ? s.substring(start) : null;
  }

  /// 从一个（可能被截断的）数组片段里救出**所有完整**的对象。
  ///
  /// 只收真正闭合、且能解析成对象的片段；半截对象直接丢。
  static List<Map<String, dynamic>> _balancedObjects(String s) {
    final out = <Map<String, dynamic>>[];
    var from = 0;
    while (from < s.length) {
      final start = s.indexOf('{', from);
      if (start < 0) break;
      final blk = _balancedFrom(s, start);
      if (blk == null) break;
      // 不平衡的片段不以 `}` 收尾，不能当成一个完整对象
      if (!blk.endsWith('}')) break;
      final v = _tryParse(blk);
      if (v != null) out.add(v);
      from = start + blk.length;
    }
    return out;
  }

  /// 修复常见 JSON 瑕疵。
  ///
  /// 只处理**安全的**修复 —— 不做任何可能改变语义的改动。
  ///
  /// ⚠️ 踩过的坑：Dart 的 `String.replaceAll` **不支持 `$1` 反向引用**
  /// （那是 JavaScript/PCRE 的语法）。写 `replaceAll(re, r'$1')` 会把字面量
  /// `$1` 插进结果里，把 JSON 弄得更坏。必须用 [String.replaceAllMapped]。
  static String _repairCommonIssues(String s) {
    var out = s.trim();

    // 尾随逗号：`{"a": 1,}` / `[1, 2,]`
    out = out.replaceAllMapped(
      RegExp(r',\s*([}\]])'),
      (m) => m.group(1) ?? '',
    );

    // 中文逗号造成的多余逗号
    out = out.replaceAllMapped(
      RegExp('\uFF0C\\s*([}\\]])'),
      (m) => m.group(1) ?? '',
    );

    // 单引号键/值 → 双引号（仅当该文本没有双引号时，避免误伤）
    if (!out.contains('"')) {
      out = out.replaceAll("'", '"');
    }

    // 无引号的键：`{id: "x"}` → `{"id": "x"}`
    out = out.replaceAllMapped(
      RegExp(r'([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*:)'),
      (m) => '${m.group(1)}"${m.group(2)}"${m.group(3)}',
    );

    // Python/JS 风格的字面量
    out = out.replaceAll(RegExp(r'\bNone\b'), 'null');
    out = out.replaceAll(RegExp(r'\bTrue\b'), 'true');
    out = out.replaceAll(RegExp(r'\bFalse\b'), 'false');

    return out;
  }

  /// 全角/中文标点 → 半角（中文模型偶发）。
  ///
  /// ⚠️ 用 `\u` 转义而不是直接写字符 —— 弯引号（U+201C/201D/2018/2019）
  /// 与直引号在编辑器里**看起来几乎一样**，直接写极易造成重复键
  /// （常量 map 不允许重复键，会在编译期报 Constant evaluation error）。
  static String _normalizeFullWidth(String s) {
    const map = <String, String>{
      '\uFF0C': ',', // ，
      '\uFF1A': ':', // ：
      '\uFF1B': ';', // ；
      '\u201C': '"', // 左双弯引号 “
      '\u201D': '"', // 右双弯引号 ”
      '\u2018': "'", // 左单弯引号 ‘
      '\u2019': "'", // 右单弯引号 ’
      '\uFF5B': '{', // ｛
      '\uFF5D': '}', // ｝
      '\uFF3B': '[', // ［
      '\uFF3D': ']', // ］
      '\uFF08': '(', // （
      '\uFF09': ')', // ）
    };
    var out = s;
    map.forEach((k, v) => out = out.replaceAll(k, v));
    return out;
  }

  static String _preview(String s) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length <= 200 ? t : '${t.substring(0, 200)}…';
  }
}
