/// 数据库连接与 FTS5 全文检索配置。
///
/// ## 关于 FTS5
/// Drift 不原生支持 FTS5 虚拟表，所以这里手写 DDL 与触发器。
/// 采用 **external-content** 模式（`content='problems_index'`）：
/// 正文只存一份（在 `problems_index`），FTS 表只存倒排索引，
/// 避免文本翻倍。代价是必须自己维护同步触发器。
///
/// ## 三张表 + 三个触发器
/// ```
/// problems_fts            FTS5 虚拟表（索引 search_tokens 与 source）
///   ├─ problems_ai        插入 problems_index 后同步
///   ├─ problems_ad        删除 problems_index 前先删 FTS 行
///   └─ problems_au        更新 problems_index 后重建 FTS 行
/// ```
///
/// ⚠️ 索引的是 `search_tokens` **不是** `stem_text`。原因见下方 FTS DDL 的说明：
/// `stem_text` 是可读原文（中文无空格），直接交给 `unicode61`
/// 会把整句当成一个 token。
///
/// external-content 表删除时必须用 `'delete'` 命令通知 FTS 索引，
/// 否则会残留"幽灵"词条，检索出已删除的题。
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tables.dart';

part 'database.g.dart';

/// FTS5 虚拟表名。
const String kFtsTable = 'problems_fts';

/// 应用数据目录下的相对路径（相对 `getApplicationSupportDirectory()`）。
const String kLibraryDirName = 'library';
const String kIndexDirName = '.index';
const String kIndexFileName = 'index.sqlite';

/// 应用数据库。
@DriftDatabase(tables: [
  ProblemsIndex,
  ProblemKnowledge,
  UserProblemState,
  ReviewLogs,
  Papers,
  MetaEntries,
  TagCacheEntries,
  LlmUsageEntries,
  ChatSessions,
  ChatMessages,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// 用指定文件打开数据库（测试与生产都用它）。
  AppDatabase.openFile(File file) : super(NativeDatabase.createInBackground(file));

  /// 内存数据库，用于测试。
  AppDatabase.memory() : super(NativeDatabase.memory());

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createFtsObjects();
          await _seedMeta();
        },
        onUpgrade: (m, from, to) async {
          // 逐版本升级，不要写 `if (from < 2)` 就跳到底 ——
          // 将来加 v5 时容易漏掉中间步骤。
          if (from < 2) await _migrateToV2();
          if (from < 3) await m.createTable(tagCacheEntries);
          if (from < 3) await m.createTable(llmUsageEntries);
          if (from < 4) await _migrateToV4(m);
          // v5：对话助手的两张表。纯新增，不动任何既有表 ——
          // 所以对老库来说是零风险的一步（不需要拷数据）。
          if (from < 5) {
            await m.createTable(chatSessions);
            await m.createTable(chatMessages);
          }
          // v6：对话消息加一列"查过什么"（工具调用的溯源）。
          //
          // 用 `addColumn` 而不是重建表：新列可空、没有默认值需求，
          // SQLite 的 `ALTER TABLE ... ADD COLUMN` 就能完成，
          // 不必走 v2 那种"建新表→拷数据→换名"的重活。
          // 老库里的行在这一列上是 NULL，`decodeToolTrace` 按
          // "没有记录"处理 —— 界面上不会显示出异常的空块。
          if (from < 6) await m.addColumn(chatMessages, chatMessages.toolTrace);
        },
        beforeOpen: (details) async {
          // 打开外键约束的**执行**开关。注意：当前 schema 里**没有任何
          // 外键声明**（见下方说明），所以这一行目前是未雨绸缪 ——
          // 将来真加了外键，它才会起作用。
          //
          // ⚠️ 不要因为"反正是空的"就删掉它：一旦有人给表加上 references()，
          // 少了这一行约束会静默失效（SQLite 默认不执行外键）。
          await customStatement('PRAGMA foreign_keys = ON');
          // WAL 提升并发读写表现（索引构建与 UI 查询会并发）。
          await customStatement('PRAGMA journal_mode = WAL');
          // FTS5 在旧版 SQLite 上可能不可用，这里做一次能力探测。
          await _ensureFtsAvailable();
        },
      );

  /// v1 → v2：给 `user_problem_state` 补上 `problem_id` 主键。
  ///
  /// ## 为什么要手工重建表
  ///
  /// SQLite **不支持** `ALTER TABLE ... ADD PRIMARY KEY`。唯一办法是
  /// 建新表 → 拷数据 → 删旧表 → 改名。
  ///
  /// ## 为什么不能直接删表重建
  ///
  /// `user_problem_state` 存的是**用户数据**（错题次数、FSRS 状态、笔记），
  /// 与可重建的索引表性质完全不同 —— 删了就是真丢了复习进度。
  /// 所以必须拷贝。拷贝时顺手去重：v1 没有主键约束，理论上可能存在
  /// 同一题的重复行，取**复习次数最多**的那条（信息最全）。
  Future<void> _migrateToV2() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS user_problem_state_v2 (
        problem_id     TEXT    NOT NULL PRIMARY KEY,
        wrong_count    INTEGER NOT NULL DEFAULT 1,
        first_seen     INTEGER NOT NULL,
        last_wrong     INTEGER,
        fsrs_state     TEXT,
        mastery        REAL    NOT NULL DEFAULT 0.0,
        error_causes   TEXT    NOT NULL DEFAULT '[]',
        note           TEXT,
        starred        INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // 按 wrong_count 降序取每条 problem_id 的第一条，即信息最全的那条
    await customStatement('''
      INSERT OR REPLACE INTO user_problem_state_v2
        (problem_id, wrong_count, first_seen, last_wrong,
         fsrs_state, mastery, error_causes, note, starred)
      SELECT problem_id, wrong_count, first_seen, last_wrong,
             fsrs_state, mastery, error_causes, note, starred
      FROM user_problem_state
      ORDER BY wrong_count DESC
    ''');

    await customStatement('DROP TABLE user_problem_state');
    await customStatement(
      'ALTER TABLE user_problem_state_v2 RENAME TO user_problem_state',
    );
  }

  // ───────────────────────────────────────────────────────────────────────
  // FTS5 相关
  // ───────────────────────────────────────────────────────────────────────

  /// v3 → v4：给 `problems_index` 加 `error_causes` 列（画像的错因分布要用）。
  ///
  /// ## 为什么这次可以简单加一列
  ///
  /// `problems_index` 是**派生数据** —— 整个删掉都能从 Markdown 重建，
  /// 所以迁移不需要像 v2 那样小心翼翼地拷用户数据（那次动的是
  /// `user_problem_state`，删了就是真丢复习进度）。
  ///
  /// ## 旧行会一直是空的
  ///
  /// 加完列之后**旧行的内容为空**，只有之后被重新索引过的题才有值
  /// （增量重建按 mtime 跳过未改动的文件，所以老题不会被自动重扫）。
  ///
  /// 这一点**必须让画像如实说出来**，不能把"只统计了迁移之后新录的题"
  /// 当成完整的错因分布显示 —— 错因分布是聚合结果，看起来有数据
  /// 比空着更危险。所以画像里带了一个"有 N 道题缺错因数据，建议重建索引"
  /// 的提示（见 `MasteryReport.missingCauseData`）。
  Future<void> _migrateToV4(Migrator m) async {
    await m.addColumn(problemsIndex, problemsIndex.errorCauses);
  }
  /// 创建 FTS5 虚拟表与同步触发器。
  ///
  /// 幂等：全部使用 `IF NOT EXISTS`。
  ///
  /// ## 为什么索引 `search_tokens` 而不是 `stem_text`
  /// `stem_text` 是**原始可读文本**（中文无空格）。FTS5 的 `unicode61`
  /// 分词器按空白切词，中文句子会被当成一个巨型 token，检索失效。
  /// 因此索引列用 `search_tokens` —— 入库前已做 CJK 逐字分词。
  /// 详见 `CjkTokenizer` 与 `ProblemsIndex.searchTokens` 的注释。
  Future<void> _createFtsObjects() async {
    await customStatement('''
      CREATE VIRTUAL TABLE IF NOT EXISTS $kFtsTable USING fts5(
        search_tokens,
        source,
        content='problems_index',
        content_rowid='rowid',
        tokenize='unicode61 remove_diacritics 2'
      )
    ''');

    // 插入后同步
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS problems_ai AFTER INSERT ON problems_index BEGIN
        INSERT INTO $kFtsTable(rowid, search_tokens, source)
        VALUES (new.rowid, new.search_tokens, new.source);
      END
    ''');

    // 删除前先通知 FTS（external-content 必须用 'delete' 命令）
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS problems_ad AFTER DELETE ON problems_index BEGIN
        INSERT INTO $kFtsTable($kFtsTable, rowid, search_tokens, source)
        VALUES ('delete', old.rowid, old.search_tokens, old.source);
      END
    ''');

    // 更新后重建该行
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS problems_au AFTER UPDATE ON problems_index BEGIN
        INSERT INTO $kFtsTable($kFtsTable, rowid, search_tokens, source)
        VALUES ('delete', old.rowid, old.search_tokens, old.source);
        INSERT INTO $kFtsTable(rowid, search_tokens, source)
        VALUES (new.rowid, new.search_tokens, new.source);
      END
    ''');
  }

  /// 探测 FTS5 是否可用。不可用则抛出可读的错误。
  Future<void> _ensureFtsAvailable() async {
    try {
      final rows = await customSelect(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
        variables: [Variable.withString(kFtsTable)],
      ).get();
      if (rows.isEmpty) {
        // 表不存在（例如从旧库升级）。尝试补建。
        await _createFtsObjects();
      }
    } on SqliteException catch (e) {
      throw StateError(
        'FTS5 全文检索不可用：$e\n'
        '请确认使用随包分发的 sqlite3（sqlite3_flutter_libs）而非系统库。',
      );
    }
  }

  /// 全量重建 FTS 索引。
  ///
  /// 何时需要：手工改过触发器、怀疑索引与主表不一致、或 schema 迁移后。
  /// 用 FTS5 的 `rebuild` 命令，避免逐行重插。
  Future<void> rebuildFtsIndex() async {
    await customStatement("INSERT INTO $kFtsTable($kFtsTable) VALUES ('rebuild')");
  }

  /// 完整性自检：FTS 行数应与 problems_index 行数一致。
  Future<({int indexCount, int ftsCount})> ftsStats() async {
    final idx = await customSelect(
      'SELECT COUNT(*) AS c FROM problems_index',
    ).getSingle();
    final fts = await customSelect(
      'SELECT COUNT(*) AS c FROM $kFtsTable',
    ).getSingle();
    return (
      indexCount: idx.read<int>('c'),
      ftsCount: fts.read<int>('c'),
    );
  }

  // ───────────────────────────────────────────────────────────────────────
  // 元数据
  // ───────────────────────────────────────────────────────────────────────

  Future<void> _seedMeta() async {
    await into(metaEntries).insertOnConflictUpdate(
      MetaEntriesCompanion.insert(
        key: 'schema_created_at',
        value: DateTime.now().toIso8601String(),
      ),
    );
  }

  Future<String?> readMeta(String key) async {
    final row = await (select(metaEntries)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> writeMeta(String key, String value) async {
    await into(metaEntries).insertOnConflictUpdate(
      MetaEntriesCompanion.insert(key: key, value: value),
    );
  }

  // ───────────────────────────────────────────────────────────────────────
  // 维护
  // ───────────────────────────────────────────────────────────────────────

  /// 清空**派生**数据（保留用户状态）。
  ///
  /// 用途：从 Markdown 全量重建索引前先清场。
  ///
  /// 删索引行会触发 FTS 的 `AFTER DELETE` 触发器，逐行通知 FTS ——
  /// 这是刻意的：用 `DELETE FROM problems_fts` 之类的批量命令绕开触发器，
  /// 会让 external-content 表与主表失去同步（见 `rebuildFtsIndex` 的说明）。
  ///
  /// ## 为什么先删关联行
  ///
  /// 现在没有外键，顺序其实不强制。但保留这个顺序是因为它**将来**才对：
  /// 一旦给 `problem_knowledge` 加上外键，先删主索引行就会被约束挡下来。
  /// 与其埋一个"加外键那天才发现"的坑，不如现在就把顺序写对。
  Future<void> clearDerivedData() async {
    await transaction(() async {
      await delete(problemKnowledge).go();
      await customStatement('DELETE FROM problems_index');
    });
  }

  /// 数据统计。
  Future<DbStats> stats() async {
    Future<int> countOf(TableInfo<Table, dynamic> table) async {
      final row = await customSelect(
        'SELECT COUNT(*) AS c FROM ${table.actualTableName}',
      ).getSingle();
      return row.read<int>('c');
    }

    final fts = await ftsStats();
    return DbStats(
      problems: fts.indexCount,
      ftsRows: fts.ftsCount,
      knowledgeLinks: await countOf(problemKnowledge),
      userStates: await countOf(userProblemState),
      reviewLogs: await countOf(reviewLogs),
      papers: await countOf(papers),
    );
  }
}

/// 数据库统计快照。
class DbStats {
  final int problems;
  final int ftsRows;
  final int knowledgeLinks;
  final int userStates;
  final int reviewLogs;
  final int papers;

  const DbStats({
    required this.problems,
    required this.ftsRows,
    required this.knowledgeLinks,
    required this.userStates,
    required this.reviewLogs,
    required this.papers,
  });

  /// FTS 与主表是否一致。不一致说明触发器出过问题，应重建索引。
  bool get ftsConsistent => problems == ftsRows;

  @override
  String toString() => 'DbStats(题目: $problems, FTS 行: $ftsRows, '
      '知识点关联: $knowledgeLinks, 用户状态: $userStates, '
      '复习记录: $reviewLogs, 试卷: $papers)';
}

// ─────────────────────────────────────────────────────────────────────────────
// 路径解析
// ─────────────────────────────────────────────────────────────────────────────

/// 应用数据目录布局。
///
/// ```
/// <app support>/kaoyan_math_agent/
/// └── library/
///     ├── problems/          题目 Markdown（事实源）
///     ├── images/            题目图片
///     ├── resources/         教材 PDF 等原始资料
///     └── .index/index.sqlite  索引 + 用户状态
/// ```
///
/// ⚠️ **绝不要硬编码绝对路径。** Windows / macOS / iOS 的应用数据目录
/// 差异极大（iOS 还有沙箱与备份策略差异），必须走 `path_provider`。
class LibraryPaths {
  final Directory root;
  final Directory problems;
  final Directory images;
  final Directory resources;
  final Directory indexDir;
  final File indexFile;

  const LibraryPaths({
    required this.root,
    required this.problems,
    required this.images,
    required this.resources,
    required this.indexDir,
    required this.indexFile,
  });

  /// 解析并创建目录结构。
  ///
  /// [supportDirectory] 是给测试留的缝：`getApplicationSupportDirectory()`
  /// 走 `path_provider`，而它在 Windows 上是**纯 Dart 实现**
  /// （`path_provider_windows`，直接调 Win32 API，不走方法通道），
  /// 所以既不能在单测里 mock 通道，也不该让单测去写真机目录。
  ///
  /// 注入点放在这里而不是别处，是因为**首次运行最可能崩的一步**
  /// 正是"目录还没建就去开 sqlite 文件"——这一步必须有测试覆盖。
  static Future<LibraryPaths> resolve({
    Future<Directory> Function()? supportDirectory,
  }) async {
    final base = await (supportDirectory ?? getApplicationSupportDirectory)();
    return createAt(Directory(p.join(base.path, kLibraryDirName)));
  }

  /// 在指定目录下建立结构（测试用）。
  static Future<LibraryPaths> createAt(Directory libraryRoot) async {
    final problems = Directory(p.join(libraryRoot.path, 'problems'));
    final images = Directory(p.join(libraryRoot.path, 'images'));
    final resources = Directory(p.join(libraryRoot.path, 'resources'));
    final indexDir = Directory(p.join(libraryRoot.path, kIndexDirName));

    for (final d in [libraryRoot, problems, images, resources, indexDir]) {
      if (!d.existsSync()) await d.create(recursive: true);
    }

    return LibraryPaths(
      root: libraryRoot,
      problems: problems,
      images: images,
      resources: resources,
      indexDir: indexDir,
      indexFile: File(p.join(indexDir.path, kIndexFileName)),
    );
  }
}

/// 打开默认位置的数据库。
///
/// [supportDirectory] 透传给 [LibraryPaths.resolve]（见那里的说明）。
Future<AppDatabase> openDefaultDatabase({
  Future<Directory> Function()? supportDirectory,
}) async {
  final paths = await LibraryPaths.resolve(supportDirectory: supportDirectory);
  return AppDatabase.openFile(paths.indexFile);
}

/// 打开内存数据库（测试用）。
AppDatabase openMemoryDatabase() => AppDatabase.memory();
