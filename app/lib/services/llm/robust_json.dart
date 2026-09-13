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
///
/// 而标注流程是**批量**的（可能一次跑几百道题），
/// 单次解析失败不应该让整批任务失败。所以这里做层层降级。
///
/// ## 设计原则
/// **宁可返回"部分结果 + 警告"，也不要直接抛异常。**
/// 调用方拿到 [JsonExtraction] 后可以决定：用结果、还是重试、还是进人工队列。
library;

import 'dart:convert';

/// 一次 JSON 提取的结果。
class JsonExtraction {
  /// 解析出的对象。null 表示彻底失败。
  final Map<String, dynamic>? value;

  /// 使用的策略标识，用于统计各服务商的输出质量。
  final String strategy;

  /// 过程中产生的问题（不致命）。
  final List<String> warnings;

  /// 是否成功。
  bool get ok => value != null;

  const JsonExtraction._({
    required this.value,
    required this.strategy,
    this.warnings = const [],
  });

  factory JsonExtraction.success(
    Map<String, dynamic> v,
    String strategy, {
    List<String> warnings = const [],
  }) =>
      JsonExtraction._(value: v, strategy: strategy, warnings: warnings);

  factory JsonExtraction.failure(String strategy, List<String> warnings) =>
      JsonExtraction._(value: null, strategy: strategy, warnings: warnings);

  @override
  String toString() =>
      'JsonExtraction(${ok ? "ok" : "fail"}, strategy=$strategy'
      '${warnings.isEmpty ? "" : ", warnings=${warnings.length}"})';
}

/// 从 LLM 的原始文本中提取 JSON 对象。
abstract final class RobustJson {
  const RobustJson._();

  /// 依次尝试多种策略，返回第一个成功的。
  static JsonExtraction extract(String raw) {
    final warnings = <String>[];

    if (raw.trim().isEmpty) {
      return JsonExtraction.failure('empty', ['模型返回空内容']);
    }

    // 策略 1：直接解析（最理想，多数情况命中）
    final direct = _tryParse(raw);
    if (direct != null) {
      return JsonExtraction.success(direct, 'direct');
    }

    // 策略 2：剥掉 ```json ... ``` 围栏
    final fenced = _stripCodeFence(raw);
    if (fenced != null && fenced != raw) {
      final v = _tryParse(fenced);
      if (v != null) {
        return JsonExtraction.success(v, 'code-fence');
      }
      warnings.add('剥离代码围栏后仍不是合法 JSON');
    }

    // 策略 3：取第一个平衡的 {...} 块
    final braced = _firstBalancedObject(raw);
    if (braced != null) {
      final v = _tryParse(braced);
      if (v != null) {
        return JsonExtraction.success(v, 'balanced-braces',
            warnings: warnings);
      }
      // 策略 4：修常见瑕疵后再试
      final repaired = _repairCommonIssues(braced);
      final vr = _tryParse(repaired);
      if (vr != null) {
        warnings.add('修复了 JSON 中的常见格式瑕疵（尾随逗号/单引号等）');
        return JsonExtraction.success(vr, 'repaired',
            warnings: warnings);
      }
      warnings.add('提取到花括号块但无法解析为 JSON');
    } else {
      warnings.add('未找到平衡的 {...} 块');
    }

    // 策略 5：全角标点归一后再试一次
    final normalized = _normalizeFullWidth(raw);
    if (normalized != raw) {
      final fenced2 = _stripCodeFence(normalized) ?? normalized;
      final braced2 = _firstBalancedObject(fenced2);
      if (braced2 != null) {
        final v = _tryParse(_repairCommonIssues(braced2));
        if (v != null) {
          warnings.add('归一化全角标点后解析成功');
          return JsonExtraction.success(v, 'fullwidth-normalized',
              warnings: warnings);
        }
      }
    }

    return JsonExtraction.failure('all-failed', [
      ...warnings,
      '原始内容前 200 字符：${_preview(raw)}',
    ]);
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
    final t = s.trim();
    if (t.isEmpty) return null;
    try {
      final decoded = jsonDecode(t);
      if (decoded is Map) return decoded.cast<String, dynamic>();
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

  /// 找出第一个**花括号平衡**的 `{...}` 片段。
  ///
  /// 用计数而非正则 —— 正则处理不了嵌套对象与字符串里的花括号。
  /// 同时要正确跳过字符串字面量里的 `{` `}`。
  static String? _firstBalancedObject(String s) {
    final start = s.indexOf('{');
    if (start < 0) return null;

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

      switch (c) {
        case '"':
          inString = true;
        case '{':
          depth++;
        case '}':
          depth--;
          if (depth == 0) {
            return s.substring(start, i + 1);
          }
      }
    }
    // 不平衡（多半是被截断）
    return depth > 0 ? s.substring(start) : null;
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
