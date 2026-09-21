/// A1：「错因从**分类**走到**开方**」的不变量。
///
/// ## 这个文件守的是什么
///
/// `data/error_causes.json` 里每一类错因早就写好了 `action` / `not_action` /
/// `resource_type`，但在这之前它们**从未上过界面**，也不参与任何决策 ——
/// 错因只被用于画像页的"错因分布"统计。这个文件盯住下面几件事：
///
/// 1. **数据本身**：6 类的 `remedy` 分组是产品判断，改了必须是有人想过才改的；
/// 2. **处方的三段文本真的显示出来**（这是"开方"最直接的证据）；
/// 3. **`remedy` 真的影响决策**（复习队列次序、错题专练选材）；
/// 4. **缺省等于既有行为** —— 一次数据没同步不该静默改变排序。
///
/// 第 4 条是这批改动里最容易出事的地方：`causes` 缺省为空词表，
/// 那时排序、打分都必须与引入该维度**之前**逐字节一致。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/data/error_causes.dart';
import 'package:kaoyan_math_agent/domain/fsrs/fsrs_scheduler.dart';
import 'package:kaoyan_math_agent/domain/paper/paper_models.dart';
import 'package:kaoyan_math_agent/features/review/error_prescription_panel.dart';
import 'package:kaoyan_math_agent/services/paper/paper_composer.dart';
import 'package:kaoyan_math_agent/services/review/review_repository.dart';

import 'support/test_env.dart';

/// 从仓库根的 `data/`（**事实源**）载入词表。
///
/// 刻意不走 `assets/data`：那份是消费副本、在 `.gitignore` 里，
/// 而这里要守的是源数据本身。
ErrorCauseCatalog loadCatalog() {
  final f = File('../data/error_causes.json');
  if (!f.existsSync()) {
    fail('找不到 ${f.absolute.path}');
  }
  return ErrorCauseCatalog.fromJson(
    (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>(),
  );
}

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  group('词表数据：remedy 是数据，不是代码里的常量', () {
    final catalog = loadCatalog();

    test('6 类错因全都有 remedy，且分成 requiz / drill 两组', () {
      expect(catalog.causes.length, 6, reason: '错因词表是受控的 6 类');

      for (final c in catalog.causes) {
        expect(
          c.remedy,
          anyOf(ErrorRemedy.requiz, ErrorRemedy.drill),
          reason: '${c.id} 的 remedy 只能是这两者之一',
        );
      }

      expect(
        catalog.causes
            .where((c) => c.remedy == ErrorRemedy.requiz)
            .map((c) => c.id)
            .toSet(),
        {'concept', 'idea', 'method'},
        reason: '这三类的处方是"重做本题/同类变式"能解决的',
      );
      expect(
        catalog.causes.where((c) => c.needsDrill).map((c) => c.id).toSet(),
        {'calc', 'reading', 'time'},
        reason: '这三类要靠专项训练（限时计算 / 审题流程 / 限时套卷），'
            '重做本题帮不上忙 —— 分组变了，复习队列的排序语义就变了',
      );
    });

    test('每类错因的处方三段都有内容（界面上不该出现空的"该做/别做"）', () {
      for (final c in catalog.causes) {
        final p = c.prescription;
        expect(p, isNotNull, reason: '${c.id} 缺 prescription');
        expect(p!.action.trim(), isNotEmpty, reason: '${c.id} 缺 action');
        expect(p.notAction.trim(), isNotEmpty, reason: '${c.id} 缺 not_action');
        expect(p.resourceTypes, isNotEmpty, reason: '${c.id} 缺 resource_type');
      }
    });

    test('每类的 not_action 都是实质性的否定建议（不是重复 action 的话）', () {
      for (final c in catalog.causes) {
        final text = c.prescription!.notAction;
        expect(text.startsWith('不要'), isTrue,
            reason: '${c.id} 的 not_action 应当明确指出**不该**做什么，'
                '而不是把 action 换句话再说一遍');
        expect(text.length, greaterThan(20),
            reason: '${c.id} 的 not_action 太短，起不到"别这么练"的提醒作用');
      }
    });

    test('drill 三类的 not_action 必须点明"别靠刷题/新题"——这是它们被降权的依据', () {
      // 这条守的是 remedy 分组的**文案依据**：如果哪天有人把这三段改写没了
      // 那层意思，分组本身就该被重新审视。
      for (final c in catalog.causes.where((x) => x.needsDrill)) {
        final text = c.prescription!.notAction;
        expect(
          text.contains('刷') || text.contains('再做') || text.contains('新题'),
          isTrue,
          reason: '${c.id} 的 not_action 应说明"重做本题帮不上忙"，'
              '这正是它被排在复习队列后面、并在错题专练里降权的唯一依据',
        );
      }
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('缺省 = 既有行为', () {
    test('remedy 字段缺失 / 非法时一律解析成 requiz', () {
      // 旧版数据文件没有这个字段。缺省值必须等于"没引入这个维度之前"的行为，
      // 否则一次数据没同步就会静默改变复习队列的排序。
      expect(ErrorRemedy.parse(null), ErrorRemedy.requiz);
      expect(ErrorRemedy.parse(''), ErrorRemedy.requiz);
      expect(ErrorRemedy.parse('   '), ErrorRemedy.requiz);
      expect(ErrorRemedy.parse('whatever'), ErrorRemedy.requiz);

      expect(ErrorRemedy.parse('drill'), ErrorRemedy.drill);
      expect(ErrorRemedy.parse('DRILL'), ErrorRemedy.drill);
      expect(ErrorRemedy.parse(' drill '), ErrorRemedy.drill);
    });

    test('空词表：resolveJson 给空、idsOfJson 仍能取出原始 id', () {
      // 这两者必须能分开：前者是"没有可用的错因信息"，
      // 后者是"数据里有 id，只是当前词表认不出"。
      const empty = ErrorCauseCatalog.empty;
      expect(empty.resolveJson('["concept"]'), isEmpty);
      expect(empty.idsOfJson('["concept"]'), ['concept']);
      expect(empty.unknownIdsOf(['concept']), ['concept']);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('从存储格式解析错因', () {
    final catalog = loadCatalog();

    test('坏数据一律当空，不抛异常', () {
      // 错因是辅助信息 —— 一份坏数据不该让复习页打不开。
      for (final bad in ['not json', '{"a":1}', '"concept"', '[', '42']) {
        expect(catalog.idsOfJson(bad), isEmpty, reason: '输入: $bad');
        expect(catalog.resolveJson(bad), isEmpty, reason: '输入: $bad');
      }
      expect(catalog.idsOfJson(null), isEmpty);
      expect(catalog.idsOfJson(''), isEmpty);
      expect(catalog.idsOfJson('   '), isEmpty);
    });

    test('resolve 按词表展示顺序返回，而不是输入顺序', () {
      // ui_order 是 ["calc","idea","concept","method","reading","time"]
      final got =
          catalog.resolve(['time', 'concept', 'calc']).map((c) => c.id).toList();
      expect(got, ['calc', 'concept', 'time'],
          reason: '顺序必须跟着词表走，否则两处界面会显示成两种顺序');
    });

    test('unknownIdsOf 挑出词表里没有的 id，且不误伤正常的', () {
      final ids = catalog.idsOfJson('["concept","made_up","calc"]');
      expect(catalog.unknownIdsOf(ids), ['made_up']);
      expect(catalog.resolve(ids).map((c) => c.id), ['calc', 'concept']);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('处方面板（这是"开方"唯一的出口）', () {
    final catalog = loadCatalog();

    Future<void> pumpPanel(WidgetTester tester, List<String> ids) async {
      final all = catalog.idsOfJson(jsonEncode(ids));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ErrorPrescriptionPanel(
              causes: catalog.resolve(all),
              unknownIds: catalog.unknownIdsOf(all),
            ),
          ),
        ),
      ));
    }

    testWidgets('drill 类必须明说"再做一遍帮助有限"，并给出该做的专项', (tester) async {
      await pumpPanel(tester, ['calc']);

      expect(find.text('计算失误'), findsOneWidget);
      expect(find.text('需专项训练'), findsOneWidget);
      expect(find.textContaining('帮助有限'), findsOneWidget,
          reason: '不告诉用户的话，他会把这一遍白做还以为"练了就是这个效果"');
      expect(find.textContaining('限时纯计算专项'), findsOneWidget,
          reason: 'action 要显示出来 —— 只说"这样没用"而不说"该做什么"等于没开方');
      expect(find.text('别做'), findsOneWidget);
      expect(find.text('该做'), findsOneWidget);
      expect(find.text('材料'), findsOneWidget);
    });

    testWidgets('requiz 类不该出现"帮助有限"的警告（不制造无谓的紧张）', (tester) async {
      await pumpPanel(tester, ['concept']);

      expect(find.text('概念不清'), findsOneWidget);
      expect(find.text('重做有效'), findsOneWidget);
      expect(find.textContaining('帮助有限'), findsNothing);
      expect(find.textContaining('回到教材'), findsOneWidget);
    });

    testWidgets('一个 drill 混在多个错因里也要被点出来', (tester) async {
      await pumpPanel(tester, ['concept', 'reading']);
      expect(find.textContaining('帮助有限'), findsOneWidget,
          reason: '只要有一个 drill 类，这一遍就该被提示');
      expect(find.text('概念不清'), findsOneWidget);
      expect(find.text('审题错误'), findsOneWidget);
    });

    testWidgets('没标错因时整块高度为 0（不占位、不留空框）', (tester) async {
      await pumpPanel(tester, []);
      expect(tester.getSize(find.byType(ErrorPrescriptionPanel)).height, 0);
    });

    testWidgets('词表里没有的 id 要如实列出来，不能静默吞掉', (tester) async {
      await pumpPanel(tester, ['concept', 'made_up']);
      expect(find.textContaining('made_up'), findsOneWidget);
      expect(find.textContaining('不存在的错因'), findsOneWidget);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('复习队列次序', () {
    late TempLibrary env;
    final now = DateTime(2024, 6, 11, 12);

    setUp(() async => env = await TempLibrary.create());
    tearDown(() => env.dispose());

    /// 造一张"已到期、逾期不足一天"的卡。
    SeedProblem dueCard(String id, {required List<String> causes, Duration ago = const Duration(hours: 3)}) =>
        SeedProblem(
          id: id,
          stem: '$id 的题干',
          errorCauses: causes,
          card: FsrsCard(
            due: now.subtract(ago),
            stability: 5,
            difficulty: 5,
            reps: 3,
            state: CardState.review,
          ),
        );

    Future<List<String>> queueOf({bool withCatalog = true}) async {
      final repo = withCatalog
          ? ReviewRepository(db: env.db, store: env.store, causes: loadCatalog())
          : ReviewRepository(db: env.db, store: env.store);
      final queue = await repo.dueQueue(limit: 10, now: now);
      return queue.map((c) => c.problemId).toList();
    }

    test('同一逾期档内，requiz 排在 drill 前面', () async {
      await seedProblems(env, [
        dueCard('p-first', causes: const ['calc']), // drill，但 id 字母序在前
        dueCard('p-second', causes: const ['concept']), // requiz
      ]);

      expect(await queueOf(), ['p-second', 'p-first']);
    });

    test('次序跟着错因走，而不是跟着题目 id 走（把错因对调）', () async {
      // 与上一条是**同一对 id**，只把错因互换。
      // 如果实现是"按 id 排序"，这条必然失败 —— 所以这对测试互相为对照。
      await seedProblems(env, [
        dueCard('p-first', causes: const ['concept']),
        dueCard('p-second', causes: const ['calc']),
      ]);

      expect(await queueOf(), ['p-first', 'p-second']);
    });

    test('错因不会让"刚到期"的题插队到"逾期 10 天"前面', () async {
      await seedProblems(env, [
        dueCard('p-stale', causes: const ['calc'], ago: const Duration(days: 10)),
        dueCard('p-fresh', causes: const ['concept']),
      ]);

      expect(await queueOf(), ['p-stale', 'p-fresh'],
          reason: '逾期多久是遗忘风险（FSRS 语义），不该被错因覆盖 —— '
              '错因只决定同一档内谁先做');
    });

    test('不给词表时排序退回"只按逾期"，与引入该维度之前一致', () async {
      await seedProblems(env, [
        dueCard('p-first', causes: const ['calc']),
        dueCard('p-second', causes: const ['concept']),
      ]);

      // 同逾期天数 → 落到"按 id 稳定"这一级
      expect(await queueOf(withCatalog: false), ['p-first', 'p-second']);
    });

    test('没标错因的题不因此被排到最后', () async {
      // 空列表是"没标错因"，不是"错在别处" —— 惩罚它会让用户
      // 因为"懒得标注"而收到一份越来越差的复习队列。
      await seedProblems(env, [
        dueCard('p-labeled', causes: const ['calc']), // drill
        dueCard('p-unlabeled', causes: const []), // 没标
      ]);

      // p-unlabeled 的档位是 0（同 requiz），所以排在 drill 之前；
      // 关键是它**没有因为缺数据而落后于 requiz 档**。
      expect(await queueOf(), ['p-unlabeled', 'p-labeled']);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('组卷：错题专练里的错因对症', () {
    const template = PaperTemplate(
      id: 'wrong_only',
      name: '错题专练',
      description: '只看做错过的题',
      seats: [PaperSeat(no: 1, sectionName: '错题专练', qtype: 'any')],
    );

    Candidate cand(String id, List<String> causes) => Candidate(
          problemId: id,
          stemText: '$id 的题干',
          qtype: 'solve',
          difficulty: 2,
          subject: 'math1',
          // 用不同考点，避免"考点多样性"那一项干扰
          primaryKpId: 'kp-$id',
          wrongCount: 1,
          errorCauseIds: causes,
        );

    test('错题专练里优先选"重做本题真的有用"的题', () {
      const drill = {'calc', 'reading', 'time'};
      final r = const PaperComposer().compose(
        request: const PaperRequest(
          template: template,
          subject: 'math1',
          drillCauseIds: drill,
        ),
        pool: [
          cand('p-drill', const ['calc']),
          cand('p-requiz', const ['concept']),
        ],
      );

      expect(r.items.single.problemId, 'p-requiz');
    });

    test('把错因对调，选中的题也跟着换（证明是错因在起作用）', () {
      const drill = {'calc', 'reading', 'time'};
      final r = const PaperComposer().compose(
        request: const PaperRequest(
          template: template,
          subject: 'math1',
          drillCauseIds: drill,
        ),
        pool: [
          cand('p-drill', const ['concept']),
          cand('p-requiz', const ['calc']),
        ],
      );

      expect(r.items.single.problemId, 'p-drill');
    });

    test('降权而不是排除：题库里只剩 drill 类的题时仍能凑满卷子', () {
      const drill = {'calc', 'reading', 'time'};
      final r = const PaperComposer().compose(
        request: const PaperRequest(
          template: template,
          subject: 'math1',
          drillCauseIds: drill,
        ),
        pool: [cand('p-a', const ['calc']), cand('p-b', const ['time'])],
      );

      expect(r.items, hasLength(1), reason: '排除会让小题库直接凑不满');
      expect(r.emptySeats, isEmpty);
    });

    test('只有「错题专练」类请求才启用错因（真题全卷考的是覆盖面）', () {
      const base = PaperRequest(template: template, subject: 'math1');
      expect(base.usesErrorCause, isFalse,
          reason: '没传 drillCauseIds 时不启用，行为与引入该维度之前一致');

      const withCauses = PaperRequest(
        template: template,
        subject: 'math1',
        drillCauseIds: {'calc'},
      );
      expect(withCauses.usesErrorCause, isTrue);

      const noPreferWrong = PaperRequest(
        template: template,
        subject: 'math1',
        drillCauseIds: {'calc'},
        preferWrong: false,
      );
      expect(noPreferWrong.usesErrorCause, isFalse,
          reason: '不优先错题时，错因也不该影响选材 —— '
              '否则真题全卷会偏离真题结构，而结构正是它存在的意义');
    });
  });
}
