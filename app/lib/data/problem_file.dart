/// 题目 id → 磁盘文件的解析。
///
/// ## 为什么不能只靠 id 推导
///
/// 解析器允许 frontmatter 里的 `id` 与文件名解耦（`fallbackId` 只是缺省），
/// 索引头注释也明确支持"Git 拉取别人的题库、从别处拷文件"。一旦 id ≠ 文件名，
/// `fileFor(id)` 指向的是**不存在的文件**：复习读不到题干、导出记失败、
/// 删除更危险 —— DB 行删掉了而真正的 `.md` 留在盘上，下次启动索引重建
/// 会把题目"复活"且复习进度全部归零。
///
/// 所以凡是**已入库**的题，一律以 `problems_index.filePath`（索引增量扫描
/// 时的真实相对路径）为准；索引查不到（新建未索引、状态行残留等）才退回
/// 推导路径，保持旧行为兜底。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'db/database.dart';
import 'markdown/problem_store.dart';

/// 把题目 id 解析成磁盘文件。见文件头说明。
///
/// ⚠️ `problems_index.filePath` 相对的是**题库根目录**（`library/`），
/// 如 `problems/子目录/x.md` —— `IndexBuilder._relativePath` 刻意把它
/// 做成跨机器的稳定键，不是相对 `problems/` 的。
Future<File> resolveProblemFile({
  required AppDatabase db,
  required ProblemStore store,
  required String problemId,
}) async {
  final row = await (db.select(db.problemsIndex)
        ..where((t) => t.id.equals(problemId)))
      .getSingleOrNull();
  final path = row?.filePath;
  if (path != null && path.isNotEmpty) {
    return File(p.join(store.problemsDir.parent.path, path));
  }
  return store.fileFor(problemId);
}

/// 读取一道已入库的题（按索引路径）。语义与 `ProblemStore.read` 一致：
/// 不抛异常，失败返回 [ReadOutcome.failed]。
Future<ReadOutcome> readIndexedProblem({
  required AppDatabase db,
  required ProblemStore store,
  required String problemId,
}) async {
  final file =
      await resolveProblemFile(db: db, store: store, problemId: problemId);
  return store.readFile(file);
}

/// 批量解析题目 id → 文件（**一次**索引查询）。
/// 索引查不到的 id 退回按 id 推导的路径。
Future<Map<String, File>> resolveProblemFiles({
  required AppDatabase db,
  required ProblemStore store,
  required Iterable<String> problemIds,
}) async {
  final ids = problemIds.toSet();
  final rows = ids.isEmpty
      ? const <ProblemIndexRow>[]
      : await (db.select(db.problemsIndex)..where((t) => t.id.isIn(ids)))
          .get();

  final out = <String, File>{
    for (final id in ids) id: store.fileFor(id), // 兜底；下面被索引路径覆盖
  };
  for (final r in rows) {
    final path = r.filePath;
    if (path.isNotEmpty) {
      out[r.id] = File(p.join(store.problemsDir.parent.path, path));
    }
  }
  return out;
}
