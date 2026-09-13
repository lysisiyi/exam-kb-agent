/// 录入闭环的服务层：草稿 → 落盘 → 刷新索引。
///
/// ## 为什么要有这一层
///
/// "保存一道题"看起来只是写个文件，实际要**依次**完成四件事，
/// 少任何一件都会留下不一致状态：
///
/// 1. **查重**：题干指纹是否已经存在（同一道题重复录入是最常见的用户行为）
/// 2. **原子写**：Markdown 落盘（`ProblemStore` 保证原子性）
/// 3. **刷新索引**：让刚写的题目立即可被搜索到
/// 4. **不碰用户状态**：错题次数/FSRS 调度**不能**被保存动作重置
///
/// 第 4 条是这套双层存储的核心纪律（见 `docs/DATA_FORMAT.md`）：
/// Markdown 是内容的唯一事实源，SQLite 是用户状态的唯一事实源。
/// **重新保存一道已存在的题，绝不能把它的复习进度清零。**
library;

import 'dart:io';

import 'package:drift/drift.dart';

import '../../data/db/database.dart';
import '../../data/index/index_builder.dart';
import '../../data/markdown/problem_markdown.dart';
import '../../data/markdown/problem_store.dart';
import '../../domain/knowledge/knowledge_point.dart';
import '../../domain/problem_draft.dart';

/// 一次保存的结果。
class SaveOutcome {
  /// 是否落盘成功。
  final bool ok;

  /// 落盘后的题目（含最终 id 与指纹）。
  final Problem? problem;

  /// 写出的文件。
  final File? file;

  /// 是否是**覆盖**已有题目（同一 id 或同一指纹）。
  final bool overwrote;

  /// 与已有题目指纹相同的那些题（用于提示"这题可能已经录过"）。
  final List<ExistingProblem> duplicates;

  /// 索引刷新报告。
  final IndexReport? indexReport;

  /// 失败原因。
  final String? error;

  const SaveOutcome({
    required this.ok,
    this.problem,
    this.file,
    this.overwrote = false,
    this.duplicates = const [],
    this.indexReport,
    this.error,
  });

  static SaveOutcome failure(String message) =>
      SaveOutcome(ok: false, error: message);

  @override
  String toString() => 'SaveOutcome(ok=$ok, id=${problem?.id}, '
      'overwrote=$overwrote, dup=${duplicates.length}, err=$error)';
}

/// 一道已存在的题目的摘要（用于查重提示）。
class ExistingProblem {
  final String id;
  final String? filePath;
  final String stemPreview;
  final DateTime? createdAt;

  const ExistingProblem({
    required this.id,
    this.filePath,
    this.stemPreview = '',
    this.createdAt,
  });
}

/// 录入闭环服务。
class ProblemService {
  final AppDatabase db;
  final ProblemStore store;
  final KnowledgeBase? knowledge;

  const ProblemService({
    required this.db,
    required this.store,
    this.knowledge,
  });

  /// 按指纹查重。
  ///
  /// 用索引表而不是扫盘：索引里已经有 `fingerprint` 列。
  /// 索引可能落后于磁盘（比如手工往 `problems/` 里拷了文件），
  /// 那种情况下查不到重复，属于可接受的漏报 —— 错报更烦人。
  Future<List<ExistingProblem>> findByFingerprint(String fingerprint) async {
    if (fingerprint.isEmpty) return const [];
    final rows = await (db.select(db.problemsIndex)
          ..where((t) => t.fingerprint.equals(fingerprint)))
        .get();
    return rows
        .map((r) => ExistingProblem(
              id: r.id,
              filePath: r.filePath,
              stemPreview: _preview(r.stemText),
              createdAt: r.createdAt,
            ))
        .toList();
  }

  /// 保存草稿。
  ///
  /// ## 重复录入的语义（这是产品决策，不只是技术细节）
  ///
  /// 用户在错题本上**再碰到同一道题**是高频事件 —— 但它不是"新题"，
  /// 而是"又错了一次"。所以：
  ///
  /// | 情况 | 行为 |
  /// |---|---|
  /// | 新建草稿，指纹撞上已有题目 | **不落盘**，返回 `duplicates` 让界面问用户 |
  /// | 用户确认"就是同一道题" | 界面带 `overwriteExisting: true` 重试 → 沿用**已有 id** 覆盖内容 |
  /// | 编辑已有题目（草稿带 id） | 直接覆盖，不打扰 |
  ///
  /// 关键点：覆盖时**沿用已有题目的 id**。若生成新 id，同一道题会有两个文件，
  /// 而 `user_problem_state` 里的错题次数/FSRS 进度是挂在 id 上的 ——
  /// 等于用户的复习进度凭空消失。
  ///
  /// [overwriteExisting] 为 false 时，新建草稿若指纹重复则不落盘。
  Future<SaveOutcome> save(
    ProblemDraft draft, {
    bool overwriteExisting = false,
  }) async {
    final issues = draft.validate(knowledge: knowledge);
    final blocking = issues.where((i) => i.level == DraftIssueLevel.blocking);
    if (blocking.isNotEmpty) {
      return SaveOutcome.failure(
        '还有 ${blocking.length} 项必须修正：'
        '${blocking.map((i) => i.message).join('；')}',
      );
    }

    // "新建"意味着草稿还没定稿过。编辑已有题目时草稿一定带 id。
    final wasNew = draft.id == null || draft.id!.isEmpty;
    final fingerprint = draft.fingerprint();
    final duplicates = await findByFingerprint(fingerprint);

    if (wasNew && duplicates.isNotEmpty && !overwriteExisting) {
      return SaveOutcome(
        ok: false,
        duplicates: duplicates,
        error: '这道题已经录过了（${duplicates.first.id}）',
      );
    }

    // 覆盖时沿用已有 id
    final targetId = wasNew
        ? (duplicates.isNotEmpty ? duplicates.first.id : null)
        : draft.id;

    final problem = draft.build(knowledge: knowledge, idOverride: targetId);
    final file = store.fileFor(problem.id);
    final alreadyThisId = file.existsSync();

    try {
      await store.save(problem);
    } on FileSystemException catch (e) {
      return SaveOutcome.failure('写入失败：${e.message}');
    } catch (e) {
      return SaveOutcome.failure('写入失败：$e');
    }

    // 刷新索引。只重建增量部分：rebuild() 按 mtime 跳过未改动的文件，
    // 所以这一步的开销与"改了几道题"成正比，而不是与题库大小成正比。
    IndexReport? report;
    String? indexError;
    try {
      report = await IndexBuilder(
        db: db,
        store: store,
        knowledge: knowledge,
      ).rebuild();
    } catch (e) {
      // 索引失败**不能**让保存算失败 —— Markdown 已经落盘了，
      // 那是事实源。索引随时可以重建（`rebuildFromScratch`）。
      indexError = '题目已保存，但索引刷新失败：$e';
    }

    return SaveOutcome(
      ok: true,
      problem: problem,
      file: file,
      overwrote: alreadyThisId || duplicates.isNotEmpty,
      // 编辑时若指纹又撞上了**别的**题目，作为提示返回（不阻断）
      duplicates: duplicates.where((d) => d.id != problem.id).toList(),
      indexReport: report,
      error: indexError,
    );
  }

  /// 删除一道题：**用户状态 → 索引行 → Markdown 文件**，按这个顺序。
  ///
  /// ## 为什么必须是这个顺序
  ///
  /// `beforeOpen` 里打开了 `PRAGMA foreign_keys = ON`，而
  /// `problem_knowledge.problem_id` 是外键。所以：
  ///
  /// - 状态行、复习历史与关联行**必须先删**，否则删索引行会被外键挡下来
  /// - Markdown 文件**必须最后删** —— 它是内容的事实源。中途失败时
  ///   宁可留下"有文件没索引"的孤儿（重建索引即可恢复），
  ///   也不要出现"有索引没文件"（列表点进去读不到内容）。
  ///
  /// 顺带删掉复习状态与复习历史：题目都没了，进度留着没有意义，
  /// 而且会让"待复习"里出现读不到内容的幽灵卡片。
  ///
  /// 返回文件是否也删掉了（索引删除失败会抛异常，不吞）。
  Future<bool> delete(String problemId) async {
    final file = store.fileFor(problemId);

    await db.transaction(() async {
      await (db.delete(db.userProblemState)
            ..where((t) => t.problemId.equals(problemId)))
          .go();
      await (db.delete(db.reviewLogs)
            ..where((t) => t.problemId.equals(problemId)))
          .go();
      await (db.delete(db.problemKnowledge)
            ..where((t) => t.problemId.equals(problemId)))
          .go();
      await (db.delete(db.problemsIndex)..where((t) => t.id.equals(problemId)))
          .go();
    });

    try {
      if (file.existsSync()) await file.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 列出最近录入的题目（按创建时间倒序）。
  Future<List<ExistingProblem>> recent({int limit = 20}) async {
    final rows = await (db.select(db.problemsIndex)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit))
        .get();
    return rows
        .map((r) => ExistingProblem(
              id: r.id,
              filePath: r.filePath,
              stemPreview: _preview(r.stemText),
              createdAt: r.createdAt,
            ))
        .toList();
  }

  /// 题库总量。
  Future<int> count() async {
    final rows = await db.select(db.problemsIndex).get();
    return rows.length;
  }

  static String _preview(String s) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length <= 60 ? t : '${t.substring(0, 60)}…';
  }
}
