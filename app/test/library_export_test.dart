/// 数据导出测试。
///
/// ## 这一项的验收线是"能不能用"，不是"有没有产出文件"
///
/// `V1_PLAN` 的验收表写得很具体：**导出 Markdown 包，能在 Obsidian 中
/// 直接打开并正确渲染公式。** 所以断言不能停在"文件夹非空"，得盯住
/// 三件真正决定可用性的事：
///
/// 1. **公式语法是 Obsidian 认的**（`$...$` / `$$...$$`，不是别的写法）
/// 2. **图片引用在导出后仍然成立**（相对路径没被搬坏 → 不出现碎图）
/// 3. **frontmatter 是合法 YAML**（否则 Obsidian 会把整段当正文显示出来）
///
/// 另外还守一条产品承诺：导出是**只读快照** ——
/// 它不能反过来污染 `problems/` 下的事实源文件。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/data/db/database.dart';
import 'package:kaoyan_math_agent/services/library/library_exporter.dart';

import 'support/test_env.dart';

void main() {
  late TempLibrary env;
  late LibraryExporter exporter;

  setUp(() async {
    env = await TempLibrary.create();
    exporter = LibraryExporter(
      db: env.db,
      store: env.store,
      imagesDir: env.paths.images,
    );
  });

  tearDown(() => env.dispose());

  /// 导出到一个新建的临时目录。
  Future<Directory> exportToTemp() async {
    final out = await Directory.systemTemp.createTemp('dsh-export-');
    addTearDown(() async {
      try {
        await out.delete(recursive: true);
      } catch (_) {}
    });
    await exporter.exportTo(out);
    return out;
  }

  // ───────────────────────────────────────────────────────────────────────────
  group('导出结构与内容', () {
    test('每道题写一个 md，正文与事实源一致', () async {
      await seedProblems(env, [
        const SeedProblem(
          id: 'p-1',
          stem: r'求 $\lim_{x\to0}\frac{\sin x}{x}$',
          answer: r'$1$',
          solution: '用等价无穷小。',
        ),
        const SeedProblem(id: 'p-2', stem: '第二题', answer: 'A'),
      ]);

      final dir = await exportToTemp();
      expect(File('${dir.path}/problems/p-1.md').existsSync(), isTrue);
      expect(File('${dir.path}/problems/p-2.md').existsSync(), isTrue);

      final text = File('${dir.path}/problems/p-1.md').readAsStringSync();
      // 公式原样保留 —— 这是 Obsidian 能渲染的前提
      expect(text, contains(r'\lim_{x\to0}\frac{\sin x}{x}'));
      expect(text, contains('## 题干'));
      expect(text, contains('## 答案'));
      expect(text, contains('## 解析'));
    });

    test('总览与使用说明都生成了', () async {
      await seedProblems(env, [const SeedProblem(id: 'p-1', stem: '一题')]);
      final dir = await exportToTemp();

      expect(File('${dir.path}/题库索引.md').existsSync(), isTrue);
      expect(File('${dir.path}/如何打开.md').existsSync(), isTrue);

      final readme = File('${dir.path}/如何打开.md').readAsStringSync();
      expect(readme, contains('Obsidian'));
      // 说明里要写清"这是只读快照"，否则用户会以为能双向同步
      expect(readme, contains('只读快照'));
    });

    test('索引页按主考点分组，并带错题次数', () async {
      await seedProblems(env, [
        const SeedProblem(
          id: 'p-1',
          stem: '洛必达的题',
          primaryKpId: 'math1.calc.limit.lhopital',
          wrongCount: 3,
        ),
        const SeedProblem(
          id: 'p-2',
          stem: '泰勒的题',
          primaryKpId: 'math1.calc.limit.taylor',
          wrongCount: 1,
        ),
      ]);
      final dir = await exportToTemp();
      final index = File('${dir.path}/题库索引.md').readAsStringSync();

      // 没有载入真实本体时索引里没有主考点名，会归到"未归类的题"
      expect(index, contains('未归类的题'));
      expect(index, contains('错 3 次'));
      expect(index, contains('[[p-1|'));
    });

    test('返回结果给出数量，且没有失败项', () async {
      await seedProblems(env, [
        const SeedProblem(id: 'p-1', stem: '一'),
        const SeedProblem(id: 'p-2', stem: '二'),
      ]);
      final out = await Directory.systemTemp.createTemp('dsh-export-');
      addTearDown(() async {
        try {
          await out.delete(recursive: true);
        } catch (_) {}
      });

      final result = await exporter.exportTo(out);
      expect(result.problems, 2);
      expect(result.isClean, isTrue, reason: result.failures.toString());
      expect(result.summary, contains('2 道题'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('用户状态合并进 frontmatter', () {
    test('my_ 前缀字段写进导出副本', () async {
      await seedProblems(env, [
        const SeedProblem(id: 'p-1', stem: '一题', wrongCount: 5),
      ]);
      // 补上复习状态
      await (env.db.update(env.db.userProblemState)
            ..where((t) => t.problemId.equals('p-1')))
          .write(const UserProblemStateCompanion(
        mastery: Value(0.42),
        starred: Value(true),
      ));

      final dir = await exportToTemp();
      final text = File('${dir.path}/problems/p-1.md').readAsStringSync();

      expect(text, contains('my_wrong_count: 5'));
      expect(text, contains('my_mastery: 0.42'));
      expect(text, contains('my_starred: true'));
      expect(text, contains('my_first_seen:'));
    });

    test('导出**不**污染事实源文件（铁律：用户状态不进 Markdown）', () async {
      await seedProblems(env, [
        const SeedProblem(id: 'p-1', stem: '一题', wrongCount: 5),
      ]);
      final before = env.store.fileFor('p-1').readAsStringSync();
      expect(before, isNot(contains('my_wrong_count')),
          reason: '前提：库里的文件本来就不该有用户状态');

      await exportToTemp();

      final after = env.store.fileFor('p-1').readAsStringSync();
      expect(after, before, reason: '导出必须只读，不能改事实源');
    });

    test('没有状态行的题也能导出（不写 my_ 字段）', () async {
      await seedProblems(env, [
        const SeedProblem(id: 'p-1', stem: '一题', wrongCount: null),
      ]);
      final dir = await exportToTemp();
      final text = File('${dir.path}/problems/p-1.md').readAsStringSync();
      expect(text, contains('## 题干'));
      expect(text, isNot(contains('my_wrong_count')));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('图片', () {
    test('被引用的图片会复制过去，相对路径仍然成立', () async {
      await _seedWithImage(env);
      final dir = await exportToTemp();

      final copied = File('${dir.path}/images/p-1-1.png');
      expect(copied.existsSync(), isTrue, reason: '图片没搬过去 → Obsidian 里是碎图');

      final text = File('${dir.path}/problems/p-1.md').readAsStringSync();
      // 题目里写的是 images/xxx.png，导出后目录结构一致，所以引用仍然成立
      expect(text, contains('images/p-1-1.png'));
    });

    test('图片文件缺失时记账而不是静默丢图', () async {
      await _seedWithImage(env, createFile: false);
      final out = await Directory.systemTemp.createTemp('dsh-export-');
      addTearDown(() async {
        try {
          await out.delete(recursive: true);
        } catch (_) {}
      });

      final result = await exporter.exportTo(out);
      expect(result.isClean, isFalse, reason: '缺图必须能查出来');
      expect(result.failures.keys.any((k) => k.contains('p-1-1.png')), isTrue);
      // 题目本身仍然要导出成功
      expect(result.problems, 1);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('目录与文件名', () {
    test('导出到已存在的目录不删除其中的其它文件', () async {
      final out = await Directory.systemTemp.createTemp('dsh-export-');
      addTearDown(() async {
        try {
          await out.delete(recursive: true);
        } catch (_) {}
      });
      final mine = File('${out.path}/我的笔记.md');
      await mine.writeAsString('别删我');

      await seedProblems(env, [const SeedProblem(id: 'p-1', stem: '一')]);
      await exporter.exportTo(out);

      expect(mine.existsSync(), isTrue, reason: '用户可能导出到自己的笔记库里');
      expect(File('${out.path}/problems/p-1.md').existsSync(), isTrue);
    });

    test('非法字符的题目 id 会被安全化成合法文件名', () async {
      await seedProblems(env, [
        const SeedProblem(id: 'a/b:c*d?e', stem: '一题'),
      ]);
      final dir = await exportToTemp();

      final files = Directory('${dir.path}/problems')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .toList();
      expect(files.length, 1);
      expect(files.single, isNot(contains('/')));
      expect(files.single, isNot(contains(':')));
      expect(files.single, endsWith('.md'));
    });

    test('重复导出覆盖同名文件，不产生副本', () async {
      await seedProblems(env, [const SeedProblem(id: 'p-1', stem: '一')]);
      final out = await Directory.systemTemp.createTemp('dsh-export-');
      addTearDown(() async {
        try {
          await out.delete(recursive: true);
        } catch (_) {}
      });

      await exporter.exportTo(out);
      await exporter.exportTo(out);

      final files = Directory('${out.path}/problems')
          .listSync()
          .whereType<File>()
          .toList();
      expect(files.length, 1);
      // 原子写不该留下 .tmp
      expect(files.any((f) => f.path.endsWith('.tmp')), isFalse);
    });

    test('空题库也能导出（给出索引与说明，不报错）', () async {
      final out = await Directory.systemTemp.createTemp('dsh-export-');
      addTearDown(() async {
        try {
          await out.delete(recursive: true);
        } catch (_) {}
      });

      final result = await exporter.exportTo(out);
      expect(result.problems, 0);
      expect(result.isClean, isTrue);
      expect(File('${out.path}/题库索引.md').existsSync(), isTrue);
    });

    test('目标目录里**别人的**同名文件不会被覆盖', () async {
      // 目标目录很可能是用户自己的 Obsidian 库，而 `如何打开.md`
      // 这种名字谁都可能占用。凭文件名覆盖就等于删用户的笔记 ——
      // 必须靠"文件里有没有我们自己的标记"来判断。
      await seedProblems(env, [const SeedProblem(id: 'p-1', stem: '一')]);
      final out = await Directory.systemTemp.createTemp('dsh-export-');
      addTearDown(() async {
        try {
          await out.delete(recursive: true);
        } catch (_) {}
      });

      const mine = '# 我的笔记\n这是用户自己写的东西，导出不该动它。';
      final userFile = File('${out.path}/如何打开.md');
      await userFile.writeAsString(mine);

      final result = await exporter.exportTo(out);

      // 用户那个文件原封不动
      expect(await userFile.readAsString(), mine);
      // 我们的说明换了个名字写出去
      expect(result.renamedRootFiles, hasLength(1));
      expect(result.renamedRootFiles.single, contains('如何打开.md →'));
      expect(
        File('${out.path}/如何打开（导出自错题本）.md').existsSync(),
        isTrue,
      );
      // 摘要里要提一句，否则用户找不到文件了
      expect(result.summary, contains('改了名'));
    });

    test('目标目录里**我们自己上次导出的**同名文件照常覆盖', () async {
      // 反向用例：如果连自己的文件都不覆盖，重复导出就会堆一堆副本。
      await seedProblems(env, [const SeedProblem(id: 'p-1', stem: '一')]);
      final out = await Directory.systemTemp.createTemp('dsh-export-');
      addTearDown(() async {
        try {
          await out.delete(recursive: true);
        } catch (_) {}
      });

      await exporter.exportTo(out);
      final second = await exporter.exportTo(out);

      expect(second.renamedRootFiles, isEmpty);
      expect(File('${out.path}/如何打开.md').existsSync(), isTrue);
      expect(
        Directory(out.path)
            .listSync()
            .whereType<File>()
            .where((f) => f.path.contains('导出自错题本')),
        isEmpty,
      );
    });
  });
}

/// 种一道带图片的题。
Future<void> _seedWithImage(TempLibrary env, {bool createFile = true}) async {
  if (createFile) {
    final img = File('${env.paths.images.path}/p-1-1.png');
    if (!img.existsSync()) await img.writeAsBytes([0x89, 0x50, 0x4E, 0x47]);
  }
  await seedProblems(env, [
    const SeedProblem(
      id: 'p-1',
      stem: '带图的题',
      images: ['images/p-1-1.png'],
    ),
  ]);
}
