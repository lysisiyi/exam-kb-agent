/// 「id ≠ 文件名」场景的回归测试（P0-7）。
///
/// ## 为什么要有这个文件
///
/// 解析器允许 frontmatter 的 `id` 与文件名解耦，索引也如实记录了每个
/// 文件的真实路径（`problems_index.filePath`）。但直到 2026-10，
/// 复习队列、导出、删除、编辑落盘全都用 `fileFor(id)` **从 id 推导**
/// 路径 —— 在外部题库（Git 拉取、按章节分子目录）上这指向不存在的文件：
///
/// - 复习队列里卡片读不到题干（loadError）；
/// - 导出把每道题记成"读取失败"；
/// - **删除最危险**：DB 四张表行已删、真正的 `.md` 留在盘上，下次启动
///   索引重建把题目"复活"且复习进度全部归零。
///
/// 修法是 `lib/data/problem_file.dart`：一律以索引路径为准。
/// 本文件用一个真实文件名 ≠ id 的题库，把四条链路各钉一遍。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/data/problem_file.dart';
import 'package:kaoyan_math_agent/domain/problem_draft.dart';
import 'package:kaoyan_math_agent/services/library/library_exporter.dart';
import 'package:kaoyan_math_agent/services/library/problem_service.dart';

import 'support/test_env.dart';

/// 一个 id 与文件名**不同**的题目文件。
/// frontmatter 声明 `id: p-custom`，文件名是 `real-name-md`。
const _customIdMd = '''
---
id: p-custom
fingerprint: fp-custom-001
subject: math1
qtype: fill
difficulty: 2
created_at: 2026-01-01
---

## 题干

设函数 \$f(x)=x^2\$，求 \$f'(x)\$。
''';

void main() {
  late TempLibrary env;

  setUp(() async {
    env = await TempLibrary.create();
    // 直接以**文件名 ≠ id**的方式落一个文件，再建索引 ——
    // 索引行将是 id=p-custom，filePath=real-name.md
    File('${env.paths.problems.path}/real-name.md')
      ..createSync(recursive: true)
      ..writeAsStringSync(_customIdMd, flush: true);
    await env.reindex();
  });

  tearDown(() => env.dispose());

  test('索引记录的是真实路径，readIndexedProblem 能读到内容', () async {
    final row = await (env.db.select(env.db.problemsIndex)
          ..where((t) => t.id.equals('p-custom')))
        .getSingle();
    // 索引存的是相对**题库根**的路径（IndexBuilder._relativePath 的约定）
    expect(row.filePath, 'problems/real-name.md',
        reason: '前提：索引按真实文件名记录（根相对路径）');

    // 修复前：store.read('p-custom') → p-custom.md → 文件不存在
    final read = await readIndexedProblem(
      db: env.db,
      store: env.store,
      problemId: 'p-custom',
    );
    expect(read.isOk, isTrue, reason: '按索引路径必须能读到题');
    expect(read.problem!.id, 'p-custom');
    expect(read.problem!.stem, contains(r'$f(x)=x^2$'));
  });

  test('resolveProblemFiles 批量解析也走真实路径', () async {
    final files = await resolveProblemFiles(
      db: env.db,
      store: env.store,
      problemIds: ['p-custom', 'ghost-id'],
    );
    expect(files['p-custom']!.path, endsWith('real-name.md'));
    // 索引查不到的 id 退回推导路径（旧行为兜底）
    expect(files['ghost-id']!.path, endsWith('ghost-id.md'));
  });

  test('删除会删掉**真正的**文件，而不是留下一个复活的孤儿', () async {
    final service = ProblemService(
      db: env.db,
      store: env.store,
      knowledge: null,
    );

    final fileGone = await service.delete('p-custom');

    expect(fileGone, isTrue);
    expect(File('${env.paths.problems.path}/real-name.md').existsSync(),
        isFalse, reason: '真正的文件必须被删掉 —— '
            '留在外面，下次启动索引重建就把题"复活"且进度归零');

    // 重建索引后题目不会回来
    final report = await env.reindex();
    expect(report.scannedFiles, 0);
  });

  test('导出走索引路径，不把这道题记成"读取失败"', () async {
    final target = await Directory.systemTemp.createTemp('dsh-export-');
    addTearDown(() => target.delete(recursive: true));

    final exporter = LibraryExporter(
      db: env.db,
      store: env.store,
      imagesDir: env.paths.images,
    );
    final result = await exporter.exportTo(target);

    expect(result.failures, isEmpty,
        reason: 'id ≠ 文件名的题不该被导出器当成读不到');
    expect(
      File('${target.path}/problems/p-custom.md').existsSync(),
      isTrue,
    );
  });

  test('两个文件声明同一个 id → 索引必须报冲突，而不是静默覆盖', () async {
    // 第二个文件也声明 id: p-custom。曾有的行为：后者静默顶掉前者，
    // 每次重建翻一次烧饼，failures 为空 —— 完全不可见。
    File('${env.paths.problems.path}/another.md')
      ..createSync(recursive: true)
      ..writeAsStringSync(_customIdMd, flush: true);

    final report = await env.reindex();

    expect(report.idConflicts['p-custom'], 'problems/real-name.md',
        reason: '冲突要指向**另一个仍在盘上**的文件');
    // 索引里仍然只有一行（谁赢由扫描顺序决定，但不能再是无声的）
    expect(report.scannedFiles, 2);
  });

  test('子目录里的题会被递归收进索引，不再静默失联', () async {
    File('${env.paths.problems.path}/第一章/sub.md')
      ..createSync(recursive: true)
      ..writeAsStringSync(_customIdMd.replaceAll('p-custom', 'p-sub'), flush: true);

    final report = await env.reindex();

    expect(report.scannedFiles, 2, reason: '根目录 + 子目录各一份');
    final row = await (env.db.select(env.db.problemsIndex)
          ..where((t) => t.id.equals('p-sub')))
        .getSingle();
    expect(row.filePath, 'problems/第一章/sub.md');
  });

  test('编辑一道 id ≠ 文件名的题，写回**原文件**而不是分裂成两个', () async {
    final service = ProblemService(
      db: env.db,
      store: env.store,
      knowledge: null,
    );
    final read = await readIndexedProblem(
      db: env.db,
      store: env.store,
      problemId: 'p-custom',
    );
    final draft = ProblemDraft.fromProblem(read.problem!);
    draft.note = '编辑过的笔记';

    final outcome = await service.save(draft);

    expect(outcome.ok, isTrue, reason: outcome.error);
    expect(
      outcome.file!.path,
      endsWith('real-name.md'),
      reason: '编辑结果必须写回原文件 —— 写到 p-custom.md 会分裂成两道题',
    );
    expect(File('${env.paths.problems.path}/p-custom.md').existsSync(),
        isFalse);
    final report = await env.reindex();
    expect(report.scannedFiles, 1, reason: '仍然只有一道题');
  });
}
