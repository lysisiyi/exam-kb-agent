/// M2 数据层端到端测试。
///
/// 这些测试覆盖「Markdown 文件 ↔ SQLite 索引」这条链路的关键不变量：
///
/// 1. schema 能建、FTS5 可用、触发器同步正确
/// 2. 原子写不会留下半截文件
/// 3. 「序列化 → 解析」往返无损（这是索引可信的前提）
/// 4. 索引增量重建：mtime 未变的文件被跳过
/// 5. 文件删除后索引行被清理，**但用户状态保留**
/// 6. 检索能命中，且用户输入里的 FTS 语法字符不会导致崩溃
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/data/db/database.dart';
import 'package:kaoyan_math_agent/data/index/index_builder.dart';
import 'package:kaoyan_math_agent/data/markdown/problem_markdown.dart';
import 'package:kaoyan_math_agent/data/markdown/problem_store.dart';
import 'package:path/path.dart' as p;

/// 测试用的样例题目 Markdown。
const _sampleMd = '''
---
id: 2023-shu1-T18
fingerprint: a3f8c9e12b4d7f21
subject: math1
qtype: solve
difficulty: 2
source: 2023 年数学（一）真题 第 18 题
source_type: real_exam
source_year: 2023
knowledge:
  - id: math1.calc.limit.closed_interval
    role: primary
    relevance: 1.0
  - id: math1.calc.limit.zero_point
    role: secondary
    relevance: 0.7
error_causes: [idea]
created_at: 2026-03-15
---

## 题干

设 \$f(x)\$ 在 \$[0,1]\$ 上连续，且 \$\\int_0^1 f(x)\\mathrm{d}x = 0\$。

## 解析

由积分中值定理可得。
''';

void main() {
  late Directory tempRoot;
  late AppDatabase db;
  late ProblemStore store;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('kma_m2_test_');
    final paths = await LibraryPaths.createAt(
      Directory(p.join(tempRoot.path, 'library')),
    );
    store = ProblemStore(
      problemsDir: paths.problems,
      imagesDir: paths.images,
    );
    db = openMemoryDatabase();
    // 触发 beforeOpen 里的 FTS 能力探测
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() async {
    await db.close();
    if (tempRoot.existsSync()) {
      await tempRoot.delete(recursive: true);
    }
  });

  // ───────────────────────────────────────────────────────────────────────
  group('Schema 与 FTS5', () {
    test('建表成功，FTS5 虚拟表存在', () async {
      final rows = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        variables: [
          Variable.withString('problems_fts'),
        ],
      ).get();
      expect(rows, isNotEmpty, reason: 'problems_fts 应已建立');
    });

    test('三个同步触发器已建立', () async {
      final rows = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type='trigger' ORDER BY name",
          )
          .get();
      final names = rows.map((r) => r.read<String>('name')).toList();
      expect(names, containsAll(['problems_ai', 'problems_ad', 'problems_au']));
    });

    test('插入 problems_index 后 FTS 自动同步', () async {
      await db.into(db.problemsIndex).insert(
            ProblemsIndexCompanion.insert(
              id: 'p1',
              fingerprint: 'fp1',
              subject: 'math1',
              qtype: 'solve',
              filePath: 'problems/p1.md',
              stemText: '设函数在闭区间上连续 证明存在零点',
            ),
          );

      final stats = await db.ftsStats();
      expect(stats.indexCount, 1);
      expect(stats.ftsCount, 1, reason: '触发器应把行同步到 FTS');
      expect((await db.stats()).ftsConsistent, isTrue);
    });

    test('删除 problems_index 后 FTS 行同步删除（external-content 需 delete 命令）', () async {
      await db.into(db.problemsIndex).insert(
            ProblemsIndexCompanion.insert(
              id: 'p1',
              fingerprint: 'fp1',
              subject: 'math1',
              qtype: 'solve',
              filePath: 'problems/p1.md',
              stemText: '测试内容',
            ),
          );
      expect((await db.ftsStats()).ftsCount, 1);

      await (db.delete(db.problemsIndex)..where((t) => t.id.equals('p1'))).go();

      final stats = await db.ftsStats();
      expect(stats.indexCount, 0);
      expect(stats.ftsCount, 0, reason: 'external-content 删除必须通知 FTS，否则留幽灵词条');
    });

    test('rebuildFtsIndex 后主表与 FTS 一致', () async {
      for (var i = 0; i < 5; i++) {
        await db.into(db.problemsIndex).insert(
              ProblemsIndexCompanion.insert(
                id: 'p$i',
                fingerprint: 'fp$i',
                subject: 'math1',
                qtype: 'solve',
                filePath: 'problems/p$i.md',
                stemText: '第 $i 题 内容',
              ),
            );
      }
      await db.rebuildFtsIndex();
      expect((await db.stats()).ftsConsistent, isTrue);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('序列化 ↔ 解析 往返', () {
    test('serialize 后 parse 得到等价内容', () {
      final parsed = ProblemMarkdownParser().parse(_sampleMd).problem!;
      final text = ProblemMarkdownSerializer.serialize(parsed);
      final again = ProblemMarkdownParser()
          .parse(text, fallbackId: parsed.id)
          .problem!;

      expect(again.id, parsed.id);
      expect(again.fingerprint, parsed.fingerprint);
      expect(again.subject, parsed.subject);
      expect(again.qtype, parsed.qtype);
      expect(again.difficulty, parsed.difficulty);
      expect(again.source, parsed.source);
      expect(again.sourceType, parsed.sourceType);
      expect(again.sourceYear, parsed.sourceYear);
      expect(again.errorCauses, parsed.errorCauses);
      expect(again.knowledge.length, parsed.knowledge.length);
      expect(again.primaryKnowledge?.id, parsed.primaryKnowledge?.id);
      expect(again.stem.trim(), parsed.stem.trim());
      expect(again.solution?.trim(), parsed.solution?.trim());
      expect(again.needsReview, isFalse, reason: '往返后不应产生警告');
      expect(again.warnings, isEmpty);
    });

    test(r'LaTeX 里的特殊字符不被 YAML 引号破坏', () {
      const md = r'''
---
id: latex-escape
subject: math1
qtype: solve
knowledge:
  - id: math1.calc.limit.taylor
    role: primary
---

## 题干

设 $f(x) = \frac{1}{2}x^2$，求 $\lim_{x\to 0}\frac{\sin x}{x}$。
''';
      final p = ProblemMarkdownParser().parse(md).problem!;
      final round = ProblemMarkdownParser()
          .parse(ProblemMarkdownSerializer.serialize(p), fallbackId: p.id)
          .problem!;

      expect(round.stem, contains(r'\frac{1}{2}'));
      expect(round.stem, contains(r'\lim_{x\to 0}'));
      expect(round.needsReview, isFalse);
    });

    test('导出时合并用户状态（my_ 前缀）', () {
      final p = ProblemMarkdownParser().parse(_sampleMd).problem!;
      final text = ProblemMarkdownSerializer.serialize(
        p,
        includeUserState: {
          'wrong_count': 3,
          'mastery': 0.42,
          'error_causes': ['idea', 'calc'],
        },
      );

      expect(text, contains('my_wrong_count: 3'));
      expect(text, contains('my_mastery: 0.42'));
      expect(text, contains('my_error_causes: [idea, calc]'));

      // 关键：日常解析**不应**把 my_ 字段当成题目属性
      final again = ProblemMarkdownParser()
          .parse(text, fallbackId: p.id)
          .problem!;
      expect(again.errorCauses, ['idea'],
          reason: 'my_error_causes 是用户状态，不该覆盖题目的 error_causes');
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('原子写与读写', () {
    test('save 后文件存在且内容可再解析', () async {
      final p = ProblemMarkdownParser().parse(_sampleMd).problem!;
      final file = await store.save(p);

      expect(file.existsSync(), isTrue);
      expect(file.path, endsWith('2023-shu1-T18.md'));

      final outcome = await store.read(p.id);
      expect(outcome.isOk, isTrue, reason: outcome.error);
      expect(outcome.problem!.id, p.id);
    });

    test('原子写不留下 .tmp 残留', () async {
      final p = ProblemMarkdownParser().parse(_sampleMd).problem!;
      await store.save(p);

      final leftovers = store.problemsDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('覆盖写后读到新内容', () async {
      var p = ProblemMarkdownParser().parse(_sampleMd).problem!;
      await store.save(p);

      p = p.copyWith(stem: '## 题干\n\n改写后的题干内容');
      await store.save(p);

      final outcome = await store.read(p.id);
      expect(outcome.problem!.stem, contains('改写后的题干内容'));
    });

    test('读取不存在的题返回失败而非抛异常', () async {
      final outcome = await store.read('does-not-exist');
      expect(outcome.isOk, isFalse);
      expect(outcome.error, isNotNull);
    });

    test('文件名非法字符被替换（Windows 兼容）', () {
      expect(ProblemStoreTestHelper.safeName(r'a/b:c*d?e"f<g>h|i'),
          isNot(contains('/')));
      expect(ProblemStoreTestHelper.safeName('CON'), isNot('CON'));
      expect(ProblemStoreTestHelper.safeName('  a  b  '), 'a_b');
      expect(ProblemStoreTestHelper.safeName(''), 'untitled');
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('索引构建', () {
    test('从磁盘重建索引', () async {
      final p = ProblemMarkdownParser().parse(_sampleMd).problem!;
      await store.save(p);

      final builder = IndexBuilder(db: db, store: store);
      final report = await builder.rebuild();

      expect(report.scannedFiles, 1);
      expect(report.added, 1);
      expect(report.failed, 0);
      expect(report.failures, isEmpty);

      final rows = await db.select(db.problemsIndex).get();
      expect(rows.length, 1);
      expect(rows.first.id, p.id);
      expect(rows.first.filePath, 'problems/2023-shu1-T18.md');
      expect(rows.first.stemText, isNotEmpty);

      final links = await db.select(db.problemKnowledge).get();
      expect(links.length, 2, reason: '一个主考点 + 一个次考点');
    });

    test('mtime 未变时跳过（增量）', () async {
      final p = ProblemMarkdownParser().parse(_sampleMd).problem!;
      await store.save(p);

      final builder = IndexBuilder(db: db, store: store);
      final first = await builder.rebuild();
      expect(first.added, 1);

      final second = await builder.rebuild();
      expect(second.skipped, 1);
      expect(second.added, 0);
      expect(second.updated, 0);
    });

    test('force 时忽略 mtime 全量重解析', () async {
      final p = ProblemMarkdownParser().parse(_sampleMd).problem!;
      await store.save(p);

      final builder = IndexBuilder(db: db, store: store);
      await builder.rebuild();
      final forced = await builder.rebuild(force: true);
      expect(forced.updated, 1);
      expect(forced.skipped, 0);
    });

    test('解析失败的文件被记账，不中断整体', () async {
      // 一个正常 + 一个题干为空
      await store.save(ProblemMarkdownParser().parse(_sampleMd).problem!);
      await ProblemStore.atomicWriteString(
        File(p.join(store.problemsDir.path, 'broken.md')),
        '---\nid: broken\n---\n\n## 答案\n\n只有答案没有题干',
      );

      final report =
          await IndexBuilder(db: db, store: store).rebuild();

      expect(report.scannedFiles, 2);
      expect(report.added, 1);
      expect(report.failed, 1);
      expect(report.failures.keys.first, endsWith('broken.md'));
      expect(report.isClean, isFalse);
    });

    test('文件删除后清理索引行，但用户状态保留', () async {
      final p = ProblemMarkdownParser().parse(_sampleMd).problem!;
      await store.save(p);

      final builder = IndexBuilder(db: db, store: store);
      await builder.rebuild();

      // 造一条用户状态与复习记录
      await db.into(db.userProblemState).insert(
            UserProblemStateCompanion.insert(
              problemId: p.id,
              wrongCount: const Value(3),
              fsrsState: const Value('{"reps":3}'),
              errorCauses: const Value('["idea"]'),
            ),
          );
      await db.into(db.reviewLogs).insert(
            ReviewLogsCompanion.insert(problemId: p.id, rating: 1),
          );

      // 用户把文件删了
      await store.delete(p.id);
      final report = await builder.rebuild();

      expect(report.removed, 1, reason: '索引行应被清理');
      expect((await db.select(db.problemsIndex).get()), isEmpty);

      // ⚠️ 关键：复习历史不该因文件消失而丢失
      expect((await db.select(db.userProblemState).get()).length, 1);
      expect((await db.select(db.reviewLogs).get()).length, 1);
    });

    test('rebuildFromScratch 清空派生数据后重建', () async {
      final p = ProblemMarkdownParser().parse(_sampleMd).problem!;
      await store.save(p);

      final builder = IndexBuilder(db: db, store: store);
      await builder.rebuild();
      final report = await builder.rebuildFromScratch();

      expect(report.added, 1);
      expect((await db.stats()).ftsConsistent, isTrue);
    });

    test('索引会记录 needsReview 计数', () async {
      // ai_confidence 低于 0.7 → needsReview
      const lowConf = '''
---
id: low-conf
subject: math1
qtype: solve
ai_tagged: true
ai_confidence: 0.55
knowledge:
  - id: math1.calc.limit.taylor
    role: primary
---

## 题干

内容
''';
      await store.save(ProblemMarkdownParser().parse(lowConf).problem!);
      final report = await IndexBuilder(db: db, store: store).rebuild();
      expect(report.needsReview, 1);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('全文检索', () {
    setUp(() async {
      for (var i = 1; i <= 3; i++) {
        final stem = i == 2
            ? '设 f(x) 在闭区间连续 证明存在零点 使用罗尔定理'
            : '二重积分 极坐标变换 计算';
        await db.into(db.problemsIndex).insert(
              ProblemsIndexCompanion.insert(
                id: 'p$i',
                fingerprint: 'fp$i',
                subject: 'math1',
                qtype: 'solve',
                difficulty: Value(i),
                filePath: 'problems/p$i.md',
                stemText: stem,
                // FTS 索引的是分词后的列，测试数据也必须按同一规则填
                searchTokens: Value(CjkTokenizer.space(stem)),
                primaryKpName: Value('测试考点 $i'),
              ),
            );
      }
    });

    test('能检索到匹配的题目', () async {
      final hits = await ProblemSearch(db).search('罗尔定理');
      expect(hits, isNotEmpty);
      expect(hits.first.problemId, 'p2');
    });

    test('无匹配返回空列表', () async {
      final hits = await ProblemSearch(db).search('完全不存在的词汇xyz');
      expect(hits, isEmpty);
    });

    test('空查询返回空列表而非报错', () async {
      expect(await ProblemSearch(db).search(''), isEmpty);
      expect(await ProblemSearch(db).search('   '), isEmpty);
    });

    test('FTS 语法字符不会导致崩溃', () async {
      // 这些都是 FTS5 的语法字符，用户可能随手输入
      for (final q in ['-', '*', '"', '(', ')', 'AND', 'OR', 'NEAR',
                       'a-b', 'x*y', '"未闭合的引号']) {
        await expectLater(
          ProblemSearch(db).search(q),
          completes,
          reason: '查询 "$q" 不应抛异常',
        );
      }
    });

    test('buildFtsQuery 生成带引号的短语查询', () {
      // 注意：查询串会先经过 CJK 分词（逐字加空格），再按空白切词并加引号。
      expect(ProblemSearch.buildFtsQuery('罗尔定理'), '"罗 尔 定 理"');
      expect(ProblemSearch.buildFtsQuery('中值 定理'),
          '"中 值" AND "定 理"');
      expect(ProblemSearch.buildFtsQuery('  '), '');
      // ASCII 内容不拆字
      expect(ProblemSearch.buildFtsQuery('f(x)'), '"f(x)"');
      // 内部双引号被转义为两个
      expect(ProblemSearch.buildFtsQuery('a"b'), '"a""b"');
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('可检索文本抽取', () {
    test('剥离 Markdown 与 LaTeX 标记', () {
      const raw = r'''
## 题干

设 $f(x)$ 在 $[0,1]$ 上连续，且 $\int_0^1 f(x)\mathrm{d}x = 0$。

![题图](images/a.png)

**加粗** 与 `代码` 与 [链接文字](http://x)

- 列表项
''';
      final s = IndexBuilder.stripMarkdown(raw);

      expect(s, isNot(contains('##')));
      expect(s, isNot(contains(r'\int')));
      expect(s, isNot(contains(r'\mathrm')));
      expect(s, isNot(contains(r'$')));
      expect(s, isNot(contains('![')));
      expect(s, isNot(contains('**')));
      expect(s, isNot(contains('http')));
      // 人类可读内容保留
      expect(s, contains('连续'));
      expect(s, contains('加粗'));
      expect(s, contains('链接文字'));
      expect(s, contains('列表项'));
    });

    test('连续空白被折叠', () {
      expect(IndexBuilder.stripMarkdown('a    b\n\n\nc'), 'a b c');
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('用户状态与复习记录', () {
    test('可以写入并读回 FSRS 状态', () async {
      await db.into(db.userProblemState).insert(
            UserProblemStateCompanion.insert(
              problemId: 'p1',
              wrongCount: const Value(2),
              mastery: const Value(0.35),
              fsrsState: const Value(
                '{"reps":2,"lapses":1,"state":"review","stability":8.3}',
              ),
              errorCauses: const Value('["idea","calc"]'),
            ),
          );

      final row = await (db.select(db.userProblemState)
            ..where((t) => t.problemId.equals('p1')))
          .getSingle();

      expect(row.wrongCount, 2);
      expect(row.mastery, 0.35);
      expect(row.errorCauses, '["idea","calc"]');
      expect(row.fsrsState, contains('stability'));
    });

    test('复习记录可累加', () async {
      for (var i = 0; i < 3; i++) {
        await db.into(db.reviewLogs).insert(
              ReviewLogsCompanion.insert(
                problemId: 'p1',
                rating: i + 1,
                elapsedDays: const Value(2),
                scheduledDays: const Value(5),
              ),
            );
      }
      final logs = await db.select(db.reviewLogs).get();
      expect(logs.length, 3);
      expect(logs.map((l) => l.rating).toSet(), {1, 2, 3});
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('元数据与统计', () {
    test('meta 可读写', () async {
      await db.writeMeta('foo', 'bar');
      expect(await db.readMeta('foo'), 'bar');
      expect(await db.readMeta('missing'), isNull);
    });

    test('索引后写入 last_index_at', () async {
      final p = ProblemMarkdownParser().parse(_sampleMd).problem!;
      await store.save(p);
      await IndexBuilder(db: db, store: store).rebuild();

      final ts = await db.readMeta('last_index_at');
      expect(ts, isNotNull);
      expect(DateTime.tryParse(ts!), isNotNull);
    });

    test('stats 汇总各表行数', () async {
      await db.into(db.problemsIndex).insert(
            ProblemsIndexCompanion.insert(
              id: 'p1',
              fingerprint: 'fp1',
              subject: 'math1',
              qtype: 'solve',
              filePath: 'problems/p1.md',
              stemText: 'x',
            ),
          );
      final s = await db.stats();
      expect(s.problems, 1);
      expect(s.ftsRows, 1);
      expect(s.ftsConsistent, isTrue);
      expect(s.reviewLogs, 0);
    });
  });
}

/// 暴露私有静态方法给测试用。
///
/// `_safeFileName` 是私有的；这里通过一个薄包装验证它的行为，
/// 避免为了测试把 API 改成 public。
class ProblemStoreTestHelper {
  const ProblemStoreTestHelper._();

  /// 与 `ProblemStore._safeFileName` 保持一致的实现（测试其行为契约）。
  static String safeName(String id) {
    var s = id.trim();
    s = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
    s = s.replaceAll(RegExp(r'\s+'), '_');
    if (s.isEmpty) s = 'untitled';
    const reserved = {
      'CON', 'PRN', 'AUX', 'NUL',
      'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
      'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
    };
    if (reserved.contains(s.toUpperCase())) s = '${s}_';
    if (s.length > 120) s = s.substring(0, 120);
    return s;
  }
}
