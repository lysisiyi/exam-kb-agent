/// M4 录入闭环的域层与服务层测试。
///
/// ## 测试策略
/// - 草稿校验、指纹、id 生成：纯函数，直接断言
/// - 保存链路：用**临时目录** + **内存数据库**，跑真实文件 IO 与真实 sqlite
/// - 错因词表：解析真实 `data/error_causes.json`（不经 assets，
///   因为 `rootBundle` 在纯 Dart 测试里拿不到；这里测解析逻辑）
///
/// 不 mock 文件系统 —— 原子写、路径安全、查重这些恰好是**容易错在 IO 上**
/// 的逻辑，用假文件系统测等于没测。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/data/db/database.dart';
import 'package:kaoyan_math_agent/data/error_causes.dart';
import 'package:kaoyan_math_agent/data/index/index_builder.dart';
import 'package:kaoyan_math_agent/data/markdown/problem_markdown.dart';
import 'package:kaoyan_math_agent/data/markdown/problem_store.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/domain/problem_draft.dart';
import 'package:kaoyan_math_agent/services/library/problem_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 测试夹具
// ─────────────────────────────────────────────────────────────────────────────

/// 最小知识点本体：够用来验证"主考点必须存在于本体"。
KnowledgeBase _kb() => KnowledgeBase(
      subject: 'math1',
      subjectName: '考研数学（一）',
      version: 'test',
      nodes: const [
        KnowledgePoint(id: 'math1', name: '数学一', level: 1, isLeaf: false),
        KnowledgePoint(
            id: 'math1.calc', name: '高等数学', level: 2,
            parentId: 'math1', isLeaf: false),
        KnowledgePoint(
            id: 'math1.calc.limit', name: '极限与连续', level: 3,
            parentId: 'math1.calc', isLeaf: false),
        KnowledgePoint(
          id: 'math1.calc.limit.lhopital',
          name: '洛必达法则',
          level: 4,
          parentId: 'math1.calc.limit',
          isLeaf: true,
          examWeight: 0.8,
          definition: '求未定式极限的法则。',
          // ⚠️ 用双引号 raw string：raw string 里不能转义单引号，
          // `r'...f\'...'` 中的 `\'` 会被当成"反斜杠 + 字符串结束"。
          formulas: [r"\lim\frac{f}{g}=\lim\frac{f'}{g'}"],
        ),
        KnowledgePoint(
          id: 'math1.calc.limit.taylor',
          name: '泰勒公式求极限',
          level: 4,
          parentId: 'math1.calc.limit',
          isLeaf: true,
          examWeight: 0.9,
          definition: '用泰勒展开求极限。',
          formulas: [r'e^x=1+x+\frac{x^2}{2}'],
        ),
      ],
    );

/// 一个临时题库目录。
class _TempLibrary {
  final Directory root;
  late final LibraryPaths paths;

  _TempLibrary._(this.root, this.paths);

  static Future<_TempLibrary> create() async {
    final dir = await Directory.systemTemp.createTemp('dsh-m4-test-');
    final paths = await LibraryPaths.createAt(dir);
    return _TempLibrary._(dir, paths);
  }

  ProblemStore get store =>
      ProblemStore(problemsDir: paths.problems, imagesDir: paths.images);

  Future<void> dispose() async {
    if (root.existsSync()) {
      try {
        await root.delete(recursive: true);
      } catch (_) {
        // Windows 上偶发文件占用，测试清理失败不该让用例失败
      }
    }
  }
}

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  group('ProblemDraft 校验', () {
    test('空题干是阻断性问题', () {
      final d = ProblemDraft(stem: '   ');
      final issues = d.validate();
      expect(d.hasBlocking(), isTrue);
      expect(issues.any((i) => i.field == 'stem' && i.message.contains('不能为空')),
          isTrue);
    });

    test('选择题选项不足 2 个是阻断性问题', () {
      final d = ProblemDraft(
        stem: r'求 $\lim_{x\to0}\frac{\sin x}{x}$',
        qtype: QuestionType.choice,
        options: ['1'],
      );
      expect(d.hasBlocking(), isTrue);
      expect(d.validate().any((i) => i.field == 'options'), isTrue);
    });

    test('没选主考点只是警告，不阻断保存', () {
      // 这一条是 60 秒录入目标的关键：不能让用户被迫在现场翻 198 个知识点
      final d = ProblemDraft(stem: '求极限');
      expect(d.hasBlocking(), isFalse);
      expect(
        d.validate().any((i) =>
            i.field == 'primaryKpId' && i.level == DraftIssueLevel.warning),
        isTrue,
      );
    });

    test('主考点不在本体里是阻断性问题', () {
      final d = ProblemDraft(stem: '求极限', primaryKpId: 'math1.not.exist');
      expect(d.hasBlocking(knowledge: _kb()), isTrue);
    });

    test('本体未载入时跳过后端校验（不该误报）', () {
      final d = ProblemDraft(stem: '求极限', primaryKpId: 'math1.not.exist');
      expect(d.hasBlocking(), isFalse);
    });

    test('题干里 \$ 不成对给出警告', () {
      final d = ProblemDraft(stem: r'求 $\lim_{x\to0} \frac{\sin x}{x} 的值');
      expect(d.hasBlocking(), isFalse);
      expect(d.validate().any((i) => i.message.contains('未闭合')), isTrue);
    });

    test(r'转义后的 \$ 不计入配对检查', () {
      final d = ProblemDraft(stem: r'单价是 \$5，求 $\int_0^1 x\,dx$');
      expect(d.validate().any((i) => i.message.contains('未闭合')), isFalse);
    });

    test('未勾选错因只是警告', () {
      final d = ProblemDraft(stem: '求极限');
      expect(
        d.validate().any((i) =>
            i.field == 'errorCauses' && i.level == DraftIssueLevel.warning),
        isTrue,
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('ProblemDraft → Problem', () {
    test('指纹由题干决定，与答案/解析无关', () {
      final a = ProblemDraft(stem: '求极限 \$x\$', answer: '1');
      final b = ProblemDraft(stem: '求极限 \$x\$', answer: '2', solution: '换元');
      expect(a.build().fingerprint, b.build().fingerprint);
    });

    test('id 由指纹派生 —— 同一道题重复录入落到同一个 id', () {
      final stem = r'求 $\lim_{x\to0}\frac{\sin x}{x}$';
      final fixed = DateTime(2026, 3, 15);
      final a = ProblemDraft(stem: stem).build(now: fixed);
      final b = ProblemDraft(stem: stem).build(now: fixed);
      expect(a.id, b.id);
      expect(a.id, startsWith('self-20260315-'));
    });

    test('已指定 id 时不被覆盖（编辑已有题目）', () {
      final d = ProblemDraft(id: '2023-shu1-T18', stem: '求极限');
      expect(d.build().id, '2023-shu1-T18');
    });

    test('主考点排在 knowledge 列表首位且 role=primary', () {
      final d = ProblemDraft(
        stem: '求极限',
        primaryKpId: 'math1.calc.limit.lhopital',
        secondaryKpIds: ['math1.calc.limit.taylor'],
      );
      final p = d.build(knowledge: _kb());
      expect(p.knowledge.first.id, 'math1.calc.limit.lhopital');
      expect(p.knowledge.first.isPrimary, isTrue);
      expect(p.knowledge.where((k) => k.isPrimary).length, 1);
    });

    test('不存在的次考点被静默剔除（不污染文件）', () {
      final d = ProblemDraft(
        stem: '求极限',
        primaryKpId: 'math1.calc.limit.lhopital',
        secondaryKpIds: ['math1.calc.limit.taylor', 'math1.bogus'],
      );
      final p = d.build(knowledge: _kb());
      expect(p.knowledge.map((k) => k.id),
          ['math1.calc.limit.lhopital', 'math1.calc.limit.taylor']);
    });

    test('没有主考点 → needsReview 为真', () {
      expect(ProblemDraft(stem: '求极限').build().needsReview, isTrue);
    });

    test('有主考点且未主动标记 → needsReview 为假', () {
      final d = ProblemDraft(
        stem: '求极限',
        primaryKpId: 'math1.calc.limit.lhopital',
      );
      expect(d.build(knowledge: _kb()).needsReview, isFalse);
    });

    test('AI 置信度低时 UI 可显式标记 needsReview', () {
      final d = ProblemDraft(
        stem: '求极限',
        primaryKpId: 'math1.calc.limit.lhopital',
        aiTagged: true,
        aiConfidence: 0.52,
        needsReview: true,
      );
      final p = d.build(knowledge: _kb());
      expect(p.needsReview, isTrue);
      expect(p.aiConfidence, 0.55 - 0.03);
    });

    test('空白答案/解析归一化成 null（避免写出空章节）', () {
      final d = ProblemDraft(stem: '求极限', answer: '   ', solution: '\n');
      final p = d.build();
      expect(p.answer, isNull);
      expect(p.solution, isNull);
    });

    test('选择题的空选项被丢弃', () {
      final d = ProblemDraft(
        stem: '下列正确的是',
        qtype: QuestionType.choice,
        options: ['A. 1', '  ', 'B. 2'],
      );
      expect(d.build().options, ['A. 1', 'B. 2']);
    });

    test('copy() 是深拷贝（改副本不影响原件）', () {
      final d = ProblemDraft(stem: '原', options: ['a'], errorCauses: ['concept']);
      final c = d.copy()
        ..stem = '改'
        ..options.add('b')
        ..errorCauses.add('calc');
      // 副本变了
      expect(c.stem, '改');
      expect(c.options, ['a', 'b']);
      expect(c.errorCauses, ['concept', 'calc']);
      // 原件没变（列表也是各自独立的）
      expect(d.stem, '原');
      expect(d.options, ['a']);
      expect(d.errorCauses, ['concept']);
    });

    test('fromProblem 能往返（编辑已有题目）', () {
      final d = ProblemDraft(
        stem: '求极限',
        primaryKpId: 'math1.calc.limit.lhopital',
        secondaryKpIds: ['math1.calc.limit.taylor'],
        errorCauses: ['method'],
        answer: '1',
        difficulty: 3,
        sourceType: SourceType.realExam,
        source: '2023 年数学（一）真题',
      );
      final p = d.build(knowledge: _kb());
      final back = ProblemDraft.fromProblem(p);
      expect(back.stem, d.stem);
      expect(back.primaryKpId, d.primaryKpId);
      expect(back.secondaryKpIds, d.secondaryKpIds);
      expect(back.errorCauses, d.errorCauses);
      expect(back.sourceType, SourceType.realExam);
      expect(back.difficulty, 3);
      expect(back.id, p.id);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('保存链路（真实文件 IO + 真实 sqlite）', () {
    late _TempLibrary lib;
    late AppDatabase db;

    setUp(() async {
      lib = await _TempLibrary.create();
      db = openMemoryDatabase();
    });

    tearDown(() async {
      await db.close();
      await lib.dispose();
    });

    ProblemService service({KnowledgeBase? kb}) =>
        ProblemService(db: db, store: lib.store, knowledge: kb ?? _kb());

    test('保存后文件存在，且能被宽容解析回等价内容', () async {
      final draft = ProblemDraft(
        stem: r'求 $\displaystyle\lim_{x\to0}\frac{\sin x}{x}$。',
        primaryKpId: 'math1.calc.limit.lhopital',
        errorCauses: ['method'],
        answer: r'$1$',
        sourceType: SourceType.textbook,
        source: '教材习题',
      );

      final out = await service().save(draft);
      expect(out.ok, isTrue, reason: out.error);
      expect(out.file!.existsSync(), isTrue);
      expect(out.problem!.id, startsWith('self-'));

      final back = await lib.store.read(out.problem!.id);
      expect(back.isOk, isTrue, reason: back.error);
      expect(back.problem!.stem.trim(), draft.stem.trim());
      expect(back.problem!.answer, r'$1$');
      expect(back.problem!.errorCauses, ['method']);
      expect(back.problem!.knowledge.first.id, 'math1.calc.limit.lhopital');
      expect(back.problem!.knowledge.first.isPrimary, isTrue);
      expect(back.problem!.fingerprint, out.problem!.fingerprint);
    });

    test('保存后索引立即可查（题目能被搜到）', () async {
      final out = await service().save(ProblemDraft(
        stem: r'求 $\lim_{x\to0}\frac{\sin x}{x}$',
        primaryKpId: 'math1.calc.limit.lhopital',
      ));
      expect(out.ok, isTrue, reason: out.error);

      final count = await service().count();
      expect(count, 1);

      final rows = await db.select(db.problemsIndex).get();
      expect(rows.single.id, out.problem!.id);
      // 索引里要有冗余的主考点名与权重，列表页才不用回查本体
      expect(rows.single.primaryKpName, '洛必达法则');
      expect(rows.single.primaryKpWeight, 0.8);
    });

    test('重复录入同一道题会被拦下，且默认不覆盖', () async {
      final stem = r'求 $\lim_{x\to0}\frac{\sin x}{x}$';
      final first = await service().save(ProblemDraft(
        stem: stem,
        primaryKpId: 'math1.calc.limit.lhopital',
      ));
      expect(first.ok, isTrue, reason: first.error);

      // 用户在错题本上又碰到这道题，重新录一遍
      final second = await service().save(ProblemDraft(
        stem: stem,
        primaryKpId: 'math1.calc.limit.taylor',
      ));

      expect(second.ok, isFalse);
      expect(second.duplicates.single.id, first.problem!.id);
      expect(second.error, contains('已经录过'));
      // 没覆盖：原文的主考点仍然是洛必达
      final back = await lib.store.read(first.problem!.id);
      expect(back.problem!.knowledge.first.id, 'math1.calc.limit.lhopital');
      // 磁盘上仍然只有一个文件
      expect(lib.paths.problems.listSync().whereType<File>(), hasLength(1));
    });

    test('确认覆盖时沿用已有 id —— 不能让复习进度丢失', () async {
      final stem = r'求 $\lim_{x\to0}\frac{\sin x}{x}$';
      final first = await service().save(ProblemDraft(
        stem: stem,
        primaryKpId: 'math1.calc.limit.lhopital',
      ));
      final firstId = first.problem!.id;

      // 造一条用户状态（错题 2 次）
      await db.into(db.userProblemState).insert(
            UserProblemStateCompanion.insert(
              problemId: firstId,
              wrongCount: const Value(2),
            ),
          );

      final second = await service().save(
        ProblemDraft(stem: stem, primaryKpId: 'math1.calc.limit.taylor'),
        overwriteExisting: true,
      );

      expect(second.ok, isTrue, reason: second.error);
      expect(second.overwrote, isTrue);
      // 关键：id 不变，所以用户状态仍然挂得上
      expect(second.problem!.id, firstId);
      final back = await lib.store.read(firstId);
      expect(back.problem!.knowledge.first.id, 'math1.calc.limit.taylor');
      final state = await db.select(db.userProblemState).get();
      expect(state.single.problemId, firstId);
      expect(state.single.wrongCount, 2);
      expect(lib.paths.problems.listSync().whereType<File>(), hasLength(1));
    });

    test('重新保存**不会**动用户状态（双层存储纪律）', () async {
      // 这是本项目最容易犯的静默错误：编辑题干后把复习进度清零。
      final stem = r'求 $\lim_{x\to0}\frac{\sin x}{x}$';
      final out = await service().save(ProblemDraft(
        stem: stem,
        primaryKpId: 'math1.calc.limit.lhopital',
      ));
      final id = out.problem!.id;

      // 造一条用户状态
      await db.into(db.userProblemState).insert(
            UserProblemStateCompanion.insert(
              problemId: id,
              wrongCount: const Value(3),
              mastery: const Value(0.35),
            ),
          );

      // 编辑并重新保存（题干照旧，只改解析）
      final edited = ProblemDraft.fromProblem(
        (await lib.store.read(id)).problem!,
      )..solution = '用洛必达。';
      final again = await service().save(edited);
      expect(again.ok, isTrue, reason: again.error);

      final state = await db.select(db.userProblemState).get();
      expect(state.single.problemId, id);
      expect(state.single.wrongCount, 3, reason: '错题次数不能被保存动作重置');
      expect(state.single.mastery, 0.35);
    });

    test('阻断性校验失败时不落盘', () async {
      final out = await service().save(ProblemDraft(stem: '   '));
      expect(out.ok, isFalse);
      expect(out.error, contains('题干'));
      expect(await service().count(), 0);
      expect(lib.paths.problems.listSync(), isEmpty);
    });

    test('原子写不留 .tmp 残file', () async {
      await service().save(ProblemDraft(
        stem: '求极限',
        primaryKpId: 'math1.calc.limit.lhopital',
      ));
      final leftovers = lib.paths.problems
          .listSync()
          .where((e) => e.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty, reason: '原子写的临时文件应已被 rename 消耗掉');
    });

    test('recent() 能列出刚录入的题目', () async {
      await service().save(ProblemDraft(
        stem: r'求 $\lim_{x\to0}\frac{\sin x}{x}$',
        primaryKpId: 'math1.calc.limit.lhopital',
      ));
      final recent = await service().recent();
      expect(recent.single.id, startsWith('self-'));
      expect(recent.single.stemPreview, contains('sin'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('错因受控词表', () {
    test('真实词表解析出 6 类且 id 唯一', () async {
      final f = File('../data/error_causes.json');
      if (!f.existsSync()) {
        markTestSkipped('data/error_causes.json 不存在');
        return;
      }
      final doc = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final cat = ErrorCauseCatalog.fromJson(doc);

      expect(cat.causes.length, 6);
      expect(cat.causes.map((c) => c.id).toSet().length, 6);
      // 每类都必须有定义和反例 —— 反例是"归类可对照"的关键
      for (final c in cat.causes) {
        expect(c.name, isNotEmpty, reason: '${c.id} 缺 name');
        expect(c.definition.length, greaterThan(20),
            reason: '${c.id} 的 definition 太短，起不到边界定义作用');
        expect(c.counterExamples, isNotEmpty,
            reason: '${c.id} 缺 counter_examples —— 没有反例，用户无法判断边界');
      }
    });

    test('ordered 按 ui_order 排序，且未列入的类别不会被丢掉', () {
      final cat = ErrorCauseCatalog.fromJson({
        'ui_order': ['c', 'a'],
        'error_causes': [
          {'id': 'a', 'name': 'A'},
          {'id': 'b', 'name': 'B'},
          {'id': 'c', 'name': 'C'},
        ],
      });
      expect(cat.ordered.map((c) => c.id).toList(), ['c', 'a', 'b']);
    });

    test('ui_order 为空时保持原顺序', () {
      final cat = ErrorCauseCatalog.fromJson({
        'error_causes': [
          {'id': 'a', 'name': 'A'},
          {'id': 'b', 'name': 'B'},
        ],
      });
      expect(cat.ordered.map((c) => c.id).toList(), ['a', 'b']);
    });

    test('处方里 not_action 被解析出来', () {
      final cat = ErrorCauseCatalog.fromJson({
        'error_causes': [
          {
            'id': 'concept',
            'name': '概念不清',
            'prescription': {
              'action': '回去重讲定义',
              'not_action': '不要靠刷综合题硬补',
              'resource_type': ['知识卡片'],
            },
          }
        ],
      });
      final p = cat.causes.single.prescription!;
      expect(p.action, '回去重讲定义');
      expect(p.notAction, '不要靠刷综合题硬补');
      expect(p.resourceTypes, ['知识卡片']);
    });

    test('缺字段不抛异常', () {
      final cat = ErrorCauseCatalog.fromJson({'error_causes': [<String, dynamic>{}]});
      // id 为空会被过滤掉
      expect(cat.causes, isEmpty);
    });

    test('多选开关默认开，显式 false 时关', () {
      expect(ErrorCauseCatalog.fromJson({}).multiSelect, isTrue);
      expect(
        ErrorCauseCatalog.fromJson({'multi_select': false}).multiSelect,
        isFalse,
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('索引构建不会被录入流程破坏', () {
    test('新增题目后 rebuild 会把它加进来', () async {
      final lib = await _TempLibrary.create();
      final db = openMemoryDatabase();
      try {
        final store = lib.store;
        await store.save(Problem(
          id: 'p1',
          fingerprint: 'fp1',
          stem: '第一题',
          qtype: QuestionType.solve,
        ));

        final builder = IndexBuilder(db: db, store: store, knowledge: _kb());
        var report = await builder.rebuild();
        expect(report.added, 1);

        await store.save(Problem(
          id: 'p2',
          fingerprint: 'fp2',
          stem: '第二题',
          qtype: QuestionType.solve,
        ));
        report = await builder.rebuild();
        expect(report.added, 1);
        expect(await db.select(db.problemsIndex).get(), hasLength(2));
      } finally {
        await db.close();
        await lib.dispose();
      }
    });
  });
}
