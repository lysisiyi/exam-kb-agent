/// 测试用的公共环境：临时题库目录 + 内存 sqlite。
///
/// ## 为什么把库放在 test/ 里而不是 lib/
///
/// `AppDatabase` 只有文件版与内存版两个构造，没有"测试版"。
/// 这里不引入第三个构造，而是**组合**已有的零件 —— `LibraryPaths.createAt`
/// 建一个真实的目录结构，`openMemoryDatabase()` 建一个真实的 sqlite。
/// 于是测试跑的是与生产**同一套代码路径**，只是落盘位置换成了临时目录。
///
/// ## 为什么 `SeedProblem` 不直接用 `ProblemService.save`
///
/// 有些测试需要"索引里有这道题，但状态表里没有它"这种组合
/// （`ReviewRepository.ensureCards` 正是为这种情况写的）。
/// 走 `ProblemService.save` 每次都会连带写状态行，做不到这种组合。
/// 所以这里直接写文件 + 重建索引，把"题目存在"和"状态存在"分成两步。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:kaoyan_math_agent/data/db/database.dart';
import 'package:kaoyan_math_agent/data/index/index_builder.dart';
import 'package:kaoyan_math_agent/data/markdown/problem_markdown.dart';
import 'package:kaoyan_math_agent/data/markdown/problem_store.dart';
import 'package:kaoyan_math_agent/domain/fingerprint.dart';
import 'package:kaoyan_math_agent/domain/fsrs/fsrs_scheduler.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';

/// 一个临时题库目录 + 内存数据库。
class TempLibrary {
  final Directory root;
  final LibraryPaths paths;
  final AppDatabase db;
  final ProblemStore store;

  TempLibrary._(this.root, this.paths, this.db, this.store);

  static Future<TempLibrary> create() async {
    final dir = await Directory.systemTemp.createTemp('dsh-test-');
    final paths = await LibraryPaths.createAt(dir);
    final db = openMemoryDatabase();
    return TempLibrary._(
      dir,
      paths,
      db,
      ProblemStore(problemsDir: paths.problems, imagesDir: paths.images),
    );
  }

  /// 已载入的知识点本体（没载入过就是 null）。
  ///
  /// `KnowledgeRepository` 没有"同步取已缓存本体"的接口，
  /// 这里不强求：`IndexBuilder` 的 `knowledge` 本来就可选，
  /// 传 null 时只是不校验知识点 id、不冗余考频权重，
  /// 而测试用的临时题目本来也不在真实本体里。
  KnowledgeBase? get knowledge => null;

  /// 重建索引（从 `problems/` 里的 Markdown 文件）。
  Future<IndexReport> reindex() => IndexBuilder(
        db: db,
        store: store,
        knowledge: knowledge,
      ).rebuild();

  Future<void> dispose() async {
    await db.close();
    if (root.existsSync()) {
      try {
        await root.delete(recursive: true);
      } catch (_) {
        // Windows 上偶发文件占用，测试清理失败不该让用例失败
      }
    }
  }
}

/// 要种进去的一道题。
class SeedProblem {
  final String id;
  final String stem;
  final String? answer;
  final String? solution;
  final String? note;
  final String? primaryKpId;
  final String? primaryKpName;
  final int difficulty;
  final String? source;
  final DateTime? createdAt;

  /// 初始错误次数。null 表示**不建状态行**（用于测 `ensureCards` 的对账）。
  final int? wrongCount;

  /// 初始 FSRS 状态。null 表示新卡。
  final FsrsCard? card;

  const SeedProblem({
    required this.id,
    required this.stem,
    this.answer,
    this.solution,
    this.note,
    this.primaryKpId,
    this.primaryKpName,
    this.difficulty = 2,
    this.source,
    this.createdAt,
    this.wrongCount = 1,
    this.card,
  });
}

/// 把 [seeds] 写进题库：Markdown 文件 + 索引行 + （可选的）用户状态行。
///
/// 返回重建索引的报告 —— 题目解析失败会体现在 `report.failed` 里，
/// 测试可以直接断言它，而不是靠"后面某个断言莫名其妙失败"来发现。
///
/// ⚠️ 在 `testWidgets` 里调用**必须**包在 `tester.runAsync` 里：
/// 假异步时钟不会推进真实文件 IO，直接 await 会永久挂住。
/// 见 `review_flow_test.dart` 里 `seedInAsync` 的说明。
Future<IndexReport> seedProblems(
  TempLibrary env,
  List<SeedProblem> seeds,
) async {
  for (final s in seeds) {
    final p = Problem(
      id: s.id,
      fingerprint: ProblemFingerprint.compute(s.stem),
      subject: 'math1',
      qtype: QuestionType.solve,
      difficulty: s.difficulty,
      source: s.source,
      sourceType: s.source == null ? SourceType.selfMade : SourceType.textbook,
      knowledge: [
        if (s.primaryKpId != null)
          KnowledgeRef(id: s.primaryKpId!, role: 'primary'),
      ],
      stem: s.stem,
      answer: s.answer,
      solution: s.solution,
      note: s.note,
      createdAt: s.createdAt ?? DateTime(2024, 1, 1),
    );
    await env.store.save(p);
  }

  final report = await env.reindex();

  for (final s in seeds) {
    if (s.wrongCount == null && s.card == null) continue;
    await env.db.into(env.db.userProblemState).insert(
          UserProblemStateCompanion.insert(
            problemId: s.id,
            wrongCount: Value(s.wrongCount ?? 1),
            firstSeen: Value(s.createdAt ?? DateTime(2024, 1, 1)),
            fsrsState: Value(s.card == null ? null : _encodeCard(s.card!)),
            mastery: const Value(0),
          ),
        );
  }

  return report;
}

String _encodeCard(FsrsCard card) => jsonEncode(card.toJson());
