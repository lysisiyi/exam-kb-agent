/// 组卷模板的载入与展开。
///
/// ## 一个刻意的设计：难度按**题号**给，不按全局比例给
///
/// `data/exam_templates.json` 里每个 section 带一个 `difficulty` 数组，
/// 长度等于该大题的题量，**按题号顺序**给出每题的难度目标：
///
/// ```json
/// { "qtype": "solve", "count": 6, "difficulty": [2, 2, 2, 3, 3, 3] }
/// ```
///
/// 换一种做法——"整卷 30% 基础、50% 综合、20% 拓展"——能凑出比例相同的卷子，
/// 但难度分布是乱的：第 1 题可能抽到拓展题，最后一题可能是基础题。
/// 而真题的手感恰恰在于**从易到难递进**，所以按位置匹配是必要的。
///
/// 代价是"某个题位必须有恰好那个难度的题可抽"，题量不足时只能放宽 ——
/// 放宽的事实会记进 `PaperResult.warnings`，不静默处理。
library;

import 'dart:convert';
import 'dart:io';

import 'paper_models.dart';

/// 载入模板。
class PaperTemplateLoader {
  /// 从 JSON 文本解析。`subject` 为 `math1` / `math2` / `math3`。
  ///
  /// 返回该科目下的全部模板，键是模板 kind（`real_exam` / `quick_mock` /
  /// `wrong_only`）。
  static Map<String, PaperTemplate> parse(
    String jsonText, {
    required String subject,
  }) {
    final root = jsonDecode(jsonText);
    if (root is! Map) return {};

    final templates = root['templates'];
    if (templates is! Map) return {};

    final subj = templates[subject];
    if (subj is! Map) return {};

    final out = <String, PaperTemplate>{};
    for (final entry in subj.entries) {
      final kind = entry.key.toString();
      final raw = entry.value;
      if (raw is! Map) continue;
      final t = _oneTemplate(raw.cast<String, dynamic>());
      if (t != null) out[kind] = t;
    }
    return out;
  }

  /// 从文件读取。
  static Future<Map<String, PaperTemplate>> loadFromFile(
    File file, {
    required String subject,
  }) async {
    if (!file.existsSync()) return {};
    return parse(await file.readAsString(), subject: subject);
  }

  static PaperTemplate? _oneTemplate(Map<String, dynamic> raw) {
    final id = raw['id']?.toString() ?? '';
    if (id.isEmpty) return null;

    final sections = raw['sections'];
    if (sections is! List) return null;

    final seats = <PaperSeat>[];
    var no = 1;

    for (final s in sections) {
      if (s is! Map) continue;
      final sec = s.cast<String, dynamic>();
      final qtype = sec['qtype']?.toString() ?? '';
      final name = sec['name']?.toString() ?? qtype;
      final count = (sec['count'] as num?)?.toInt() ?? 0;
      final scorePer = (sec['score_per_item'] as num?)?.toInt() ?? 0;
      // `start_no` 在数据里有，但直接用解析顺序更稳：
      // 万一数据里题号有洞，按顺序展开不会留下空洞
      final diffs = (sec['difficulty'] as List? ?? const [])
          .map((e) => (e as num?)?.toInt() ?? 2)
          .toList();

      for (var i = 0; i < count; i++) {
        seats.add(PaperSeat(
          no: no++,
          sectionName: name,
          qtype: qtype,
          score: scorePer,
          // 难度数组比题量短时按最后一档补齐，长时忽略多余项
          targetDifficulty: diffs.isEmpty
              ? 2
              : diffs[i < diffs.length ? i : diffs.length - 1],
        ));
      }
    }

    if (seats.isEmpty) return null;

    return PaperTemplate(
      id: id,
      name: raw['name']?.toString() ?? id,
      description: raw['description']?.toString() ?? '',
      totalScore: (raw['total_score'] as num?)?.toInt(),
      durationMinutes: (raw['duration_minutes'] as num?)?.toInt(),
      seats: seats,
    );
  }
}
