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
      // ⚠️ 题型可能是 `any`（错题专练那道大题不限题型）。
      // 早先这里直接取字符串并当作具体题型用，于是"任何题型"变成了
      // 字面量 `any` —— 候选集永远是空的，那道大题一个题位都填不上。
      final qtype = sec['qtype']?.toString() ?? '';
      final name = sec['name']?.toString() ?? qtype;
      final count = (sec['count'] as num?)?.toInt() ?? 0;
      // ⚠️ 分值可能是 null（见 wrong_only），难度同理。
      final scorePer = (sec['score_per_item'] as num?)?.toInt();
      final diffs = (sec['difficulty'] as List? ?? const [])
          .map((e) => (e as num?)?.toInt())
          .toList();
      // 逐个题位的分值。与 `difficulty` 同一套写法（按题号顺序），
      // 为的是能表达"同一道大题里各题分值不同"—— 2023 年后的真题解答题
      // 正是这样（一道 10 分 + 五道 12 分 = 70 分）。
      //
      // 只给 `score_per_item` 是不够的：全按 12 分算会得到 72 分，
      // 于是整卷变成 152 分，而模板上写着"150 分"——
      // 用户会看到预览里的总分与模板名不符，且没有任何解释。
      final scorePattern = (sec['score_pattern'] as List? ?? const [])
          .map((e) => (e as num?)?.toInt())
          .toList();

      for (var i = 0; i < count; i++) {
        // 难度数组比题量短时按最后一档补齐，长时忽略多余项；
        // 整段为空表示不限难度
        final diff = diffs.isEmpty
            ? null
            : diffs[i < diffs.length ? i : diffs.length - 1];

        // 分值同理：给了 score_pattern 就按题号取，否则全用 score_per_item
        final score = scorePattern.isEmpty
            ? scorePer
            : scorePattern[i < scorePattern.length ? i : scorePattern.length - 1];

        seats.add(PaperSeat(
          no: no++,
          sectionName: name,
          qtype: qtype.isEmpty ? PaperSeat.anyQtype : qtype,
          score: score,
          targetDifficulty: diff,
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

  /// 从同一份模板文件里取展示用的标签表。
  ///
  /// 文件里本来就有 `difficulty_labels` / `qtype_labels` —— 直接用它们，
  /// 而不是在 UI 里再硬编码一份"1 → 基础"。两份映射迟早会不一致。
  static PaperLabels parseLabels(String jsonText) {
    final root = jsonDecode(jsonText);
    if (root is! Map) return const PaperLabels();
    Map<String, String> read(String key) {
      final raw = root[key];
      if (raw is! Map) return const {};
      return {
        for (final e in raw.entries) e.key.toString(): e.value.toString(),
      };
    }

    return PaperLabels(
      difficulty: read('difficulty_labels'),
      qtype: read('qtype_labels'),
    );
  }
}

/// 模板文件里的展示标签。
class PaperLabels {
  /// 难度 id → 中文，如 `{'1': '基础'}`。
  final Map<String, String> difficulty;

  /// 题型 id → 中文，如 `{'choice': '选择题'}`。
  final Map<String, String> qtype;

  const PaperLabels({this.difficulty = const {}, this.qtype = const {}});

  /// 难度的展示名。取不到时退回一个中性说法，不编造。
  String difficultyName(int? d) {
    if (d == null) return '不限';
    return difficulty['$d'] ?? '难度 $d';
  }

  /// 题型的展示名。
  String qtypeName(String id) {
    if (id == PaperSeat.anyQtype) return '不限题型';
    return qtype[id] ?? id;
  }
}
