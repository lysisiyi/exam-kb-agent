/// 组卷的数据层：把题库与模板接到引擎上，并保存组卷结果。
///
/// ## 这一层存在的理由
///
/// `PaperComposer` 是纯函数，只认 `Candidate` 列表。本文件负责三件它不该管的事：
/// 1. **从索引与用户状态拼出候选池**（含"薄弱考点"要用的掌握度）
/// 2. **载入模板**（assets 里的 `exam_templates.json`）
/// 3. **持久化组卷结果**（`papers` 表）
///
/// ## 一个刻意的选择：掌握度按**考点**聚合，不按题
///
/// "这道题值不值得出"应该看**这道题所属考点**掌握得怎么样，而不是这道题
/// 自己的掌握度 —— 一道题只复习过一两次，它的掌握度噪声很大；
/// 而同一个考点下的所有题共同反映"这个考点我到底会不会"。
///
/// 所以候选的 `kpMastery` 是该考点下所有题的掌握度平均。没有复习记录的
/// 考点则缺席（引擎按 0.5 处理，即"未知"）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../data/db/database.dart';
import '../../domain/paper/paper_models.dart';
import '../../domain/paper/paper_template.dart';
import 'paper_composer.dart';

/// 模板文件的 asset 路径。
const String kExamTemplatesAsset = 'assets/data/exam_templates.json';

/// 组卷数据层。
class PaperRepository {
  final AppDatabase db;

  /// 模板 JSON 的文本。可注入以便测试不依赖 asset bundle。
  final String? templatesJson;

  PaperRepository({required this.db, this.templatesJson});

  // ───────────────────────────────────────────────────────────────────────
  // 模板
  // ───────────────────────────────────────────────────────────────────────

  String? _cachedJson;

  Future<String> _json() async {
    final injected = templatesJson;
    if (injected != null) return injected;
    return _cachedJson ??= await rootBundle.loadString(kExamTemplatesAsset);
  }

  /// 载入某科目的全部模板。
  Future<Map<String, PaperTemplate>> templates({
    required String subject,
  }) async {
    try {
      return PaperTemplateLoader.parse(await _json(), subject: subject);
    } catch (_) {
      // 资产缺失时给空表，让 UI 显示"模板载入失败"而不是崩
      return {};
    }
  }

  /// 载入展示标签。
  Future<PaperLabels> labels() async {
    try {
      return PaperTemplateLoader.parseLabels(await _json());
    } catch (_) {
      return const PaperLabels();
    }
  }

  /// 从文件载入模板（供不需要 asset bundle 的场景，如测试与命令行工具）。
  static Future<Map<String, PaperTemplate>> templatesFromFile(
    File file, {
    required String subject,
  }) =>
      PaperTemplateLoader.loadFromFile(file, subject: subject);

  // ───────────────────────────────────────────────────────────────────────
  // 候选池
  // ───────────────────────────────────────────────────────────────────────

  /// 拼出候选池。
  ///
  /// [onlyWrong] 为 true 时只保留用户做错过的题（「错题专练」用）。
  Future<List<Candidate>> candidates({
    required String subject,
    bool onlyWrong = false,
  }) async {
    final rows = await db
        .select(db.problemsIndex)
        .get()
      ..removeWhere((r) => r.subject != subject);

    final states = await db.select(db.userProblemState).get();
    final stateById = {for (final s in states) s.problemId: s};

    // ⚠️ 主考点 id **必须**从 `problem_knowledge` 取，不能从索引的
    // `primary_kp_name` 取。
    //
    // 实测踩过：`primary_kp_name` 是索引重建时从知识点本体里冗余写入的，
    // 本体没载入（或某个 id 在本体里查不到）时它就是 null。而"薄弱考点"
    // 恰恰是组卷的核心信号 —— 用 null 作聚合键，所有题都会落到同一个
    // 桶里，掌握度聚合直接失效，而且**不会报任何错**。
    final links = await db
        .select(db.problemKnowledge)
        .get()
      ..removeWhere((l) => l.role != 'primary');
    final primaryKpById = {for (final l in links) l.problemId: l.kpId};

    // 按考点聚合掌握度 —— 见类文档
    final masterySum = <String, double>{};
    final masteryN = <String, int>{};
    for (final s in states) {
      final kp = primaryKpById[s.problemId];
      if (kp == null) continue;
      masterySum[kp] = (masterySum[kp] ?? 0) + s.mastery;
      masteryN[kp] = (masteryN[kp] ?? 0) + 1;
    }

    final out = <Candidate>[];
    for (final r in rows) {
      final s = stateById[r.id];
      final wrong = s?.wrongCount ?? 0;
      if (onlyWrong && wrong <= 0) continue;

      // 聚合键用主考点 id；展示名优先用索引里冗余的那个（它更友好）
      final kpId = primaryKpById[r.id];
      final n = kpId == null ? 0 : (masteryN[kpId] ?? 0);
      out.add(Candidate(
        problemId: r.id,
        stemText: r.stemText,
        qtype: r.qtype,
        difficulty: r.difficulty,
        subject: r.subject,
        primaryKpId: kpId,
        primaryKpName: r.primaryKpName ?? kpId,
        primaryKpWeight: r.primaryKpWeight,
        wrongCount: wrong,
        kpMastery: n == 0 ? null : masterySum[kpId]! / n,
      ));
    }
    return out;
  }

  // ───────────────────────────────────────────────────────────────────────
  // 持久化
  // ───────────────────────────────────────────────────────────────────────

  /// 已保存的卷子，最新的在前。
  Future<List<PaperRow>> history({int limit = 50}) async {
    return (db.select(db.papers)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit))
        .get();
  }

  /// 保存一份组卷结果。
  Future<String> save(PaperResult result, {String? title, DateTime? now}) async {
    final ts = now ?? DateTime.now();
    // ⚠️ 用**微秒**而不是毫秒。
    //
    // `papers.id` 是主键，而这里用的是一个普通 `insert`（不是 upsert）。
    // 毫秒精度下，同一毫秒内的两次保存会算出同一个 id，
    // 第二次直接撞主键抛 `SqliteException: UNIQUE constraint failed` ——
    // 用户看到的是一条看不懂的红色报错，而那次保存其实**成功了**。
    // 微秒级撞车在实践中不会发生。
    final id = 'paper-${ts.microsecondsSinceEpoch}';

    await db.into(db.papers).insert(
          PapersCompanion.insert(
            id: id,
            title: title ?? _defaultTitle(result, ts),
            subject: result.subject,
            // config 存"这份卷子是按什么参数组的"，便于复现与解释
            config: jsonEncode({
              'templateId': result.template.id,
              'templateName': result.template.name,
              'questionCount': result.template.questionCount,
              'warnings': result.warnings,
              'emptySeats': result.emptySeats.length,
              'hasEstimatedScores': result.hasEstimatedScores,
            }),
            items: jsonEncode([
              for (final it in result.items)
                {
                  'problemId': it.problemId,
                  'no': it.seat.no,
                  'section': it.seat.sectionName,
                  'score': it.seat.score,
                  'difficulty': it.actualDifficulty,
                },
            ]),
            totalScore: Value(result.totalScore),
            createdAt: Value(ts),
          ),
        );
    return id;
  }

  /// 删除一份卷子。
  Future<void> delete(String paperId) async {
    await (db.delete(db.papers)..where((t) => t.id.equals(paperId))).go();
  }

  static String _defaultTitle(PaperResult r, DateTime ts) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${r.template.name} · ${ts.month}月${ts.day}日 '
        '${two(ts.hour)}:${two(ts.minute)}';
  }
}
