/// 全局依赖注入（Riverpod providers）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/database.dart';
import '../data/error_causes.dart';
import '../data/knowledge/knowledge_repository.dart';
import '../data/markdown/problem_store.dart';
import '../domain/knowledge/knowledge_point.dart';
import '../services/library/problem_service.dart';

/// 当前选中的科目。
///
/// V1 先固定数学一；数二/数三的知识点编好后可通过 UI 切换。
final currentSubjectProvider = StateProvider<Subject>((ref) => Subject.math1);

/// 知识点本体仓库。
final knowledgeRepositoryProvider = Provider<KnowledgeRepository>(
  (ref) => KnowledgeRepository.instance,
);

/// 当前科目的知识点本体。异步载入，带缓存。
final knowledgeBaseProvider = FutureProvider<KnowledgeBase>((ref) async {
  final subject = ref.watch(currentSubjectProvider);
  return ref.watch(knowledgeRepositoryProvider).load(subject);
});

/// 已成功载入的全部科目（数二/数三可能尚未编好）。
final availableSubjectsProvider =
    FutureProvider<Map<Subject, KnowledgeBase>>((ref) async {
  return ref
      .watch(knowledgeRepositoryProvider)
      .loadAvailable(Subject.values);
});

/// 高频考点 Top N（按考频权重降序）。用于首页与组卷加权说明。
final topKnowledgePointsProvider =
    FutureProvider.family<List<KnowledgePoint>, int>((ref, limit) async {
  final kb = await ref.watch(knowledgeBaseProvider.future);
  return kb.leavesByWeight(limit: limit);
});

/// 当前知识点路径面包屑。
final knowledgePathProvider =
    Provider.family<List<KnowledgePoint>, String>((ref, id) {
  final kb = ref.watch(knowledgeBaseProvider).valueOrNull;
  if (kb == null) return const [];
  return kb.pathTo(id);
});

// ─────────────────────────────────────────────────────────────────────────────
// 题库（library）—— 录入闭环用的那一套
// ─────────────────────────────────────────────────────────────────────────────

/// 题库目录。首次访问时创建 `problems/` `images/` `index/` 等子目录。
final libraryPathsProvider = FutureProvider<LibraryPaths>(
  (ref) => LibraryPaths.resolve(),
);

/// 索引数据库（SQLite）。
///
/// 只存**用户状态与派生索引** —— 题目内容的事实源永远是 Markdown 文件。
/// 因此这个库整个删掉也不会丢数据，只会丢复习进度，
/// 而复习进度另有 `user_problem_state` 表保存。
final databaseProvider = FutureProvider<AppDatabase>((ref) async {
  final db = await openDefaultDatabase();
  // 应用退出时关掉，避免 Windows 上留下文件句柄
  ref.onDispose(db.close);
  return db;
});

/// 题目 Markdown 读写仓库。
final problemStoreProvider = FutureProvider<ProblemStore>((ref) async {
  final paths = await ref.watch(libraryPathsProvider.future);
  return ProblemStore(
    problemsDir: paths.problems,
    imagesDir: paths.images,
  );
});

/// 录入闭环服务。本体未载入时传 null（查重/索引依然可用，只是不校验知识点 id）。
final problemServiceProvider = FutureProvider<ProblemService>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  final store = await ref.watch(problemStoreProvider.future);
  final kb = ref.watch(knowledgeBaseProvider).valueOrNull;
  return ProblemService(db: db, store: store, knowledge: kb);
});

/// 错因受控词表。
final errorCauseCatalogProvider = FutureProvider<ErrorCauseCatalog>(
  (ref) => ErrorCauseRepository.instance.load(),
);
