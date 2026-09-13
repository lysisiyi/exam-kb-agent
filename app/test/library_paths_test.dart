/// 题库目录解析与**真实文件库**的首次打开测试。
///
/// ## 这个文件补的是哪块空白
///
/// 其余测试都用 `LibraryPaths.createAt(临时目录)`，也就是说
/// **`LibraryPaths.resolve()` 从来没被执行过** —— 而它才是 App 真正走的入口：
///
/// ```
/// 录入页点保存
///   → problemServiceProvider
///   → databaseProvider → openDefaultDatabase()
///   → LibraryPaths.resolve() → getApplicationSupportDirectory()
///       → AppDatabase.openFile(index.sqlite)
/// ```
///
/// 这条链只在**第一次保存**时才走，而首次运行最容易崩的地方恰恰是它：
/// "目录还没建就去开 sqlite 文件"。
///
/// 这里通过 `resolve(supportDirectory:)` 注入一个临时目录，
/// 让真实入口路径跑起来 —— 不打桩平台通道，也不写用户真机目录。
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/data/db/database.dart';
import 'package:kaoyan_math_agent/data/markdown/problem_markdown.dart';
import 'package:kaoyan_math_agent/data/markdown/problem_store.dart';
import 'package:kaoyan_math_agent/domain/problem_draft.dart';
import 'package:kaoyan_math_agent/services/library/problem_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory fakeSupport;

  /// 注入给 `resolve()` 的"应用数据目录"。
  Future<Directory> support() async => fakeSupport;

  setUp(() async {
    fakeSupport = await Directory.systemTemp.createTemp('dsh-support-');
  });

  tearDown(() async {
    if (fakeSupport.existsSync()) {
      try {
        await fakeSupport.delete(recursive: true);
      } catch (_) {
        // Windows 上偶发文件占用，清理失败不该让用例失败
      }
    }
  });

  group('LibraryPaths.resolve', () {
    test('在应用数据目录下建立完整结构', () async {
      final paths = await LibraryPaths.resolve(supportDirectory: support);

      // 落在 app support 目录下的子目录里（不污染用户数据根）
      expect(paths.root.path, startsWith(fakeSupport.path));
      expect(p.basename(paths.root.path), kLibraryDirName);

      for (final d in [
        paths.root,
        paths.problems,
        paths.images,
        paths.resources,
        paths.indexDir,
      ]) {
        expect(d.existsSync(), isTrue, reason: '目录未创建：${d.path}');
      }

      expect(p.basename(paths.indexFile.path), kIndexFileName);
      expect(paths.indexFile.parent.path, paths.indexDir.path);
    });

    test('重复调用幂等（第二次不会因目录已存在而报错）', () async {
      final a = await LibraryPaths.resolve(supportDirectory: support);
      final b = await LibraryPaths.resolve(supportDirectory: support);
      expect(a.root.path, b.root.path);
      expect(b.problems.existsSync(), isTrue);
    });
  });

  group('openDefaultDatabase 首次打开', () {
    test('目录尚未存在时也能建库 —— 首次运行最可能崩的一步', () async {
      // 刻意不先调 resolve()：模拟"用户在全新环境点了保存"
      final db = await openDefaultDatabase(supportDirectory: support);
      try {
        // 能真的执行 SQL 才算打开了
        expect(await db.select(db.problemsIndex).get(), isEmpty);

        // 库文件确实落盘了
        final paths = await LibraryPaths.resolve(supportDirectory: support);
        expect(paths.indexFile.existsSync(), isTrue);
      } finally {
        await db.close();
      }
    });

    test('schema 与 FTS5 触发器在**文件库**上同样生效', () async {
      // 内存库与文件库在 DDL/触发器上可能有差异（external-content 尤其），
      // 所以这条单独验一遍。
      final db = await openDefaultDatabase(supportDirectory: support);
      try {
        await db.into(db.problemsIndex).insert(ProblemsIndexCompanion.insert(
              id: 'p1',
              fingerprint: 'fp1',
              subject: 'math1',
              qtype: 'solve',
              filePath: 'problems/p1.md',
              stemText: r'求 $\lim_{x\to0}\frac{\sin x}{x}$',
              searchTokens: const Value('求 x 0 sin x x'),
            ));

        final hit = await (db.selectOnly(db.problemsIndex)
              ..addColumns([db.problemsIndex.id])
              ..where(db.problemsIndex.searchTokens.like('%sin%')))
            .get();
        expect(hit, isNotEmpty);

        // external-content 的 FTS 表也要能查到
        final fts = await db
            .customSelect(
              "SELECT rowid FROM $kFtsTable WHERE $kFtsTable MATCH 'sin'",
              readsFrom: {db.problemsIndex},
            )
            .get();
        expect(fts, isNotEmpty, reason: 'FTS5 触发器没把新行同步进倒排索引');

        // 删除后 FTS 行也应被清掉
        await (db.delete(db.problemsIndex)..where((t) => t.id.equals('p1')))
            .go();
        final after = await db
            .customSelect(
              "SELECT rowid FROM $kFtsTable WHERE $kFtsTable MATCH 'sin'",
              readsFrom: {db.problemsIndex},
            )
            .get();
        expect(after, isEmpty);
      } finally {
        await db.close();
      }
    });
  });

  group('真实目录上的完整保存链路', () {
    test('resolve → openDefaultDatabase → save 一步不少地走通', () async {
      // 这就是 App 里点「保存」时真正发生的事
      final paths = await LibraryPaths.resolve(supportDirectory: support);
      final db = await openDefaultDatabase(supportDirectory: support);
      try {
        final service = ProblemService(
          db: db,
          store: ProblemStore(
            problemsDir: paths.problems,
            imagesDir: paths.images,
          ),
          // 刻意不传 knowledge：模拟首次运行时本体还没载入完，
          // 验证"没有本体也能存下来"这条降级路径
        );

        final out = await service.save(ProblemDraft(
          stem: r'求 $\displaystyle\lim_{x\to0}\frac{\sin x}{x}$。',
          qtype: QuestionType.solve,
        ));

        expect(out.ok, isTrue, reason: out.error);
        expect(out.problem!.id, startsWith('self-'));

        // Markdown 落在真实的 problems/ 目录
        final files = paths.problems.listSync().whereType<File>().toList();
        expect(files, hasLength(1));
        expect(files.single.path, endsWith('.md'));

        // 内容能被解析回等价题目
        final back = await service.store.read(out.problem!.id);
        expect(back.isOk, isTrue, reason: back.error);
        expect(back.problem!.fingerprint, out.problem!.fingerprint);

        // 索引里查得到
        expect(await service.count(), 1);
      } finally {
        await db.close();
      }
    });

    test('再点一次保存 → 被查重拦下（不会写出第二个文件）', () async {
      final paths = await LibraryPaths.resolve(supportDirectory: support);
      final db = await openDefaultDatabase(supportDirectory: support);
      try {
        final store = ProblemStore(
          problemsDir: paths.problems,
          imagesDir: paths.images,
        );
        final service = ProblemService(db: db, store: store);
        const stem = r'求 $\lim_{x\to0}\frac{\sin x}{x}$';

        final first = await service.save(ProblemDraft(stem: stem));
        expect(first.ok, isTrue, reason: first.error);

        final second = await service.save(ProblemDraft(stem: stem));
        expect(second.ok, isFalse);
        expect(second.duplicates.single.id, first.problem!.id);
        expect(paths.problems.listSync().whereType<File>(), hasLength(1));
      } finally {
        await db.close();
      }
    });
  });
}
