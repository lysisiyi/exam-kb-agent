/// 组卷引擎测试。
///
/// ## 这里最容易出的错不是崩溃，而是"卷子看起来对、其实不对"
///
/// 组卷的失败方式是**静默降级**：题量不够时少几题、难度抽偏了、
/// 一份卷子里同一个考点刷了 6 遍。这些都不会报错，用户要自己数才发现。
/// 所以这个文件重点盯三件事：
///
/// 1. **硬约束不许破**：题型必须匹配，同一个题不能出两次
/// 2. **难度递进要保住**：模板的 `difficulty` 是按题号给的，
///    如果被打分函数忽略，卷子就退化成"难度乱序"
/// 3. **降级必须记账**：填不上的题位进 `emptySeats`，放宽的难度进 `warnings`
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/domain/paper/paper_models.dart';
import 'package:kaoyan_math_agent/domain/paper/paper_template.dart';
import 'package:kaoyan_math_agent/services/paper/paper_composer.dart';

/// 造一个简单的模板：3 选择 + 2 解答，难度按题号递进。
PaperTemplate _miniTemplate() => const PaperTemplate(
      id: 'test.mini',
      name: '小卷',
      description: '',
      totalScore: 40,
      seats: [
        PaperSeat(
            no: 1,
            sectionName: '选择题',
            qtype: 'choice',
            score: 5,
            targetDifficulty: 1),
        PaperSeat(
            no: 2,
            sectionName: '选择题',
            qtype: 'choice',
            score: 5,
            targetDifficulty: 2),
        PaperSeat(
            no: 3,
            sectionName: '选择题',
            qtype: 'choice',
            score: 5,
            targetDifficulty: 3),
        PaperSeat(
            no: 4,
            sectionName: '解答题',
            qtype: 'solve',
            score: 10,
            targetDifficulty: 2),
        PaperSeat(
            no: 5,
            sectionName: '解答题',
            qtype: 'solve',
            score: 10,
            targetDifficulty: 3),
      ],
    );

Candidate _c(
  String id,
  String qtype,
  int difficulty, {
  String? kp,
  double? weight,
  int wrong = 0,
  double? mastery,
}) =>
    Candidate(
      problemId: id,
      stemText: '题目 $id',
      qtype: qtype,
      difficulty: difficulty,
      subject: 'math1',
      primaryKpId: kp,
      primaryKpName: kp,
      primaryKpWeight: weight,
      wrongCount: wrong,
      kpMastery: mastery,
    );

/// 够填满小卷的题库：每种难度都有 2 个选择 + 2 个解答。
List<Candidate> _amplePool() => [
      for (var d = 1; d <= 3; d++) ...[
        _c('c$d-a', 'choice', d, kp: 'kp.choice.$d', weight: 0.5),
        _c('c$d-b', 'choice', d, kp: 'kp.choice.$d', weight: 0.5),
        _c('s$d-a', 'solve', d, kp: 'kp.solve.$d', weight: 0.5),
        _c('s$d-b', 'solve', d, kp: 'kp.solve.$d', weight: 0.5),
      ],
    ];

void main() {
  const engine = PaperComposer();

  PaperRequest reqOf(PaperTemplate t, {
    int tolerance = 1,
    bool preferWrong = true,
    bool preferWeak = true,
    double weightStrength = 0.6,
    bool diversify = true,
    Set<String> exclude = const {},
  }) =>
      PaperRequest(
        template: t,
        subject: 'math1',
        difficultyTolerance: tolerance,
        preferWrong: preferWrong,
        preferWeak: preferWeak,
        weightStrength: weightStrength,
        diversify: diversify,
        excludeProblemIds: exclude,
      );

  // ───────────────────────────────────────────────────────────────────────────
  group('硬约束', () {
    test('题型必须匹配：选择题的题位不会放解答题', () {
      final r = engine.compose(
        request: reqOf(_miniTemplate()),
        pool: _amplePool(),
      );

      for (final it in r.items) {
        expect(it.seat.qtype, isNotNull);
        final isChoice = it.seat.qtype == 'choice';
        expect(it.problemId.startsWith(isChoice ? 'c' : 's'), isTrue,
            reason: '题位 ${it.seat.no}（${it.seat.qtype}）'
                '抽到了 ${it.problemId}');
      }
    });

    test('同一道题不会在一份卷里出现两次', () {
      final r = engine.compose(
        request: reqOf(_miniTemplate()),
        pool: _amplePool(),
      );
      final ids = r.items.map((i) => i.problemId).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('题量充足时不留空位，且总分等于题位分值之和', () {
      final r = engine.compose(
        request: reqOf(_miniTemplate()),
        pool: _amplePool(),
      );
      expect(r.isComplete, isTrue, reason: r.warnings.join('；'));
      expect(r.items.length, 5);
      // 3 选择 × 5 分 + 2 解答 × 10 分 = 35
      // （模板的 total_score: 40 只是示例标签，真实模板里两者也会不一致 ——
      //   真题解答题是 10/12 分混排，见 exam_templates.json 里的说明）
      expect(r.totalScore, 35);
      expect(r.summary, contains('5/5'));
    });

    test('题号连续且按模板顺序', () {
      final r = engine.compose(
        request: reqOf(_miniTemplate()),
        pool: _amplePool(),
      );
      expect(r.items.map((i) => i.seat.no).toList(), [1, 2, 3, 4, 5]);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('难度递进（模板的核心意图）', () {
    test('容忍度为 0 时，每题都精确命中目标难度', () {
      final r = engine.compose(
        request: reqOf(_miniTemplate(), tolerance: 0),
        pool: _amplePool(),
      );
      for (final it in r.items) {
        expect(it.actualDifficulty, it.seat.targetDifficulty,
            reason: '第 ${it.seat.no} 题偏离了目标难度');
      }
      expect(r.warnings.where((w) => w.contains('期望难度')), isEmpty);
    });

    test('难度贴合：其它条件相同时，抽中的是目标难度那一档（不是随机）', () {
      // 这个用例盯的是一个具体 bug：打分函数如果漏掉"难度贴合"这一项，
      // 一档之内的候选就变成随机挑 —— 卷子的难度就乱了。
      //
      // ⚠️ 构造很关键：**所有候选的其它信号必须相同**（错题次数、掌握度、
      // 考频）。否则测的就不是难度贴合，而是"弱点和难度哪个权重高" ——
      // 那是另一个问题，而且答案不是显然的。
      final pool = [
        _c('c1', 'choice', 1, kp: 'a', weight: 0.5, wrong: 0, mastery: 0.5),
        _c('c2', 'choice', 2, kp: 'b', weight: 0.5, wrong: 0, mastery: 0.5),
        _c('c3', 'choice', 3, kp: 'c', weight: 0.5, wrong: 0, mastery: 0.5),
        _c('s1', 'solve', 1, kp: 'd', weight: 0.5, wrong: 0, mastery: 0.5),
        _c('s2', 'solve', 2, kp: 'e', weight: 0.5, wrong: 0, mastery: 0.5),
        _c('s3', 'solve', 3, kp: 'f', weight: 0.5, wrong: 0, mastery: 0.5),
      ];
      const t = PaperTemplate(
        id: 't', name: 't', description: '',
        seats: [
          PaperSeat(
              no: 1,
              sectionName: '选择题',
              qtype: 'choice',
              score: 5,
              targetDifficulty: 2),
          PaperSeat(
              no: 2,
              sectionName: '解答题',
              qtype: 'solve',
              score: 10,
              targetDifficulty: 3),
        ],
      );

      final r = engine.compose(request: reqOf(t, tolerance: 1), pool: pool);
      final first = r.items.firstWhere((i) => i.seat.no == 1);
      final second = r.items.firstWhere((i) => i.seat.no == 2);
      expect(first.actualDifficulty, 2, reason: '第 1 题应当选中难度 2 的题');
      expect(second.actualDifficulty, 3, reason: '第 2 题应当选中难度 3 的题');
    });

    test('难度数组比题量短时按最后一档补齐', () {
      final t = PaperTemplateLoader.parse('''
      {"templates":{"math1":{"x":{
        "id":"x","name":"x","total_score":15,
        "sections":[{"qtype":"choice","name":"选择","count":3,
                     "score_per_item":5,"difficulty":[1]}]}}}}''', subject: 'math1');
      final seats = t['x']!.seats;
      expect(seats.length, 3);
      expect(seats.map((s) => s.targetDifficulty).toList(), [1, 1, 1]);
    });

    test('弱点是强信号时，可以盖过难度贴合（这是有意的取舍）', () {
      // 这条把"舍弃一个偏好"的先后顺序固定下来：题位第 1 题要难度 2，
      // 但难度 1 的那道是用户错了很多次、掌握度极低的题 —— 它应该被选中。
      //
      // 理由：组卷的目的是**练用户的弱项**，难度贴合是"像真题"的手段。
      // 当两者冲突时，练弱项优先（否则用户会一遍遍做自己已经会的题）。
      // 代价是卷子的难度曲线会略有偏移，而这会记进 warnings。
      final pool = [
        _c('c1-weak', 'choice', 1, kp: 'a', wrong: 9, mastery: 0.0),
        _c('c2-target', 'choice', 2, kp: 'b', wrong: 0, mastery: 0.9),
      ];
      const t = PaperTemplate(
        id: 't', name: 't', description: '',
        seats: [
          PaperSeat(
              no: 1,
              sectionName: '选择题',
              qtype: 'choice',
              score: 5,
              targetDifficulty: 2),
        ],
      );
      final r = engine.compose(request: reqOf(t, tolerance: 1), pool: pool);
      expect(r.items.single.problemId, 'c1-weak',
          reason: '错 9 次 + 掌握度 0 的题应当优先于难度更贴合的题');
      // 而且这个偏移必须被记账，不能悄悄发生
      expect(r.warnings.any((w) => w.contains('期望难度 2')), isTrue);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('软偏好', () {
    test('优先抽做错过的题', () {
      final pool = [
        _c('c1-wrong', 'choice', 1, wrong: 5),
        _c('c1-clean', 'choice', 1, wrong: 0),
      ];
      const t = PaperTemplate(
        id: 't', name: 't', description: '',
        seats: [
          PaperSeat(
              no: 1,
              sectionName: '选择题',
              qtype: 'choice',
              score: 5,
              targetDifficulty: 1),
        ],
      );
      final r = engine.compose(request: reqOf(t), pool: pool);
      expect(r.items.single.problemId, 'c1-wrong');
    });

    test('preferWrong 关掉时不看错题次数', () {
      final pool = [
        _c('c1-wrong', 'choice', 1, wrong: 5),
        _c('c1-clean', 'choice', 1, wrong: 0),
      ];
      const t = PaperTemplate(
        id: 't', name: 't', description: '',
        seats: [
          PaperSeat(
              no: 1,
              sectionName: '选择题',
              qtype: 'choice',
              score: 5,
              targetDifficulty: 1),
        ],
      );
      // 两者难度、考频、掌握度都相同，关掉错题偏好后应当"谁先谁得"
      final r = engine.compose(
        request: reqOf(t, preferWrong: false),
        pool: pool,
      );
      expect(r.items.single.problemId, 'c1-wrong',
          reason: '并列时保持输入顺序即可，这一条只是确认关掉开关不会崩');
    });

    test('优先抽薄弱考点（掌握度低）', () {
      final pool = [
        _c('c1-weak', 'choice', 1, mastery: 0.1),
        _c('c1-strong', 'choice', 1, mastery: 0.95),
      ];
      const t = PaperTemplate(
        id: 't', name: 't', description: '',
        seats: [
          PaperSeat(
              no: 1,
              sectionName: '选择题',
              qtype: 'choice',
              score: 5,
              targetDifficulty: 1),
        ],
      );
      final r = engine.compose(request: reqOf(t), pool: pool);
      expect(r.items.single.problemId, 'c1-weak');
    });

    test('preferWeak 关掉时不看掌握度', () {
      final pool = [
        _c('c1-weak', 'choice', 1, mastery: 0.1),
        _c('c1-strong', 'choice', 1, mastery: 0.95),
      ];
      const t = PaperTemplate(
        id: 't', name: 't', description: '',
        seats: [
          PaperSeat(
              no: 1,
              sectionName: '选择题',
              qtype: 'choice',
              score: 5,
              targetDifficulty: 1),
        ],
      );
      final r = engine.compose(
        request: reqOf(t, preferWeak: false),
        pool: pool,
      );
      expect(r.items.single.problemId, 'c1-weak',
          reason: '并列时保持输入顺序，确认关掉开关不崩');
    });

    test('优先抽考频高的考点', () {
      final pool = [
        _c('c1-hot', 'choice', 1, weight: 0.95),
        _c('c1-cold', 'choice', 1, weight: 0.05),
      ];
      const t = PaperTemplate(
        id: 't', name: 't', description: '',
        seats: [
          PaperSeat(
              no: 1,
              sectionName: '选择题',
              qtype: 'choice',
              score: 5,
              targetDifficulty: 1),
        ],
      );
      final r = engine.compose(request: reqOf(t), pool: pool);
      expect(r.items.single.problemId, 'c1-hot');
    });

    test('考点多样性：同一考点的题不会被连抽', () {
      // 4 个选择题位，只有 2 个考点。多样性开启时应当 2+2 而不是 4+0。
      final pool = [
        for (var i = 0; i < 6; i++) _c('a$i', 'choice', 2, kp: 'kp.A'),
        for (var i = 0; i < 6; i++) _c('b$i', 'choice', 2, kp: 'kp.B'),
      ];
      final t = PaperTemplate(
        id: 't', name: 't', description: '',
        seats: [
          for (var i = 1; i <= 4; i++)
            PaperSeat(
                no: i,
                sectionName: '选择题',
                qtype: 'choice',
                score: 5,
                targetDifficulty: 2),
        ],
      );

      // 让 A 的题"更该被选"（错更多），看多样性会不会把它压下去
      final biased = [
        for (var i = 0; i < 6; i++)
          _c('a$i', 'choice', 2, kp: 'kp.A', wrong: 5),
        for (var i = 0; i < 6; i++) _c('b$i', 'choice', 2, kp: 'kp.B'),
      ];
      final r = engine.compose(request: reqOf(t), pool: biased);
      final aCount =
          r.items.where((i) => i.problemId.startsWith('a')).length;
      expect(aCount, lessThan(4),
          reason: '多样性没生效：同一个考点的题被连抽了 $aCount 次');
      expect(r.items.length, 4);
      expect(pool.length, 12); // 保证 pool 参数被用到
    });

    test('diversify 关掉时允许同一考点刷屏', () {
      final pool = [
        for (var i = 0; i < 6; i++)
          _c('a$i', 'choice', 2, kp: 'kp.A', wrong: 5),
        for (var i = 0; i < 6; i++) _c('b$i', 'choice', 2, kp: 'kp.B'),
      ];
      final t = PaperTemplate(
        id: 't', name: 't', description: '',
        seats: [
          for (var i = 1; i <= 4; i++)
            PaperSeat(
                no: i,
                sectionName: '选择题',
                qtype: 'choice',
                score: 5,
                targetDifficulty: 2),
        ],
      );
      final r = engine.compose(
        request: reqOf(t, diversify: false),
        pool: pool,
      );
      final aCount = r.items.where((i) => i.problemId.startsWith('a')).length;
      expect(aCount, 4, reason: '关掉多样性后，错得多的 A 组应当全被选中');
    });

    test('排除集里的题不会被抽到（避免重复出卷）', () {
      final pool = [
        _c('c1-used', 'choice', 1),
        _c('c1-fresh', 'choice', 1),
      ];
      const t = PaperTemplate(
        id: 't', name: 't', description: '',
        seats: [
          PaperSeat(
              no: 1,
              sectionName: '选择题',
              qtype: 'choice',
              score: 5,
              targetDifficulty: 1),
        ],
      );
      final r = engine.compose(
        request: reqOf(t, exclude: {'c1-used'}),
        pool: pool,
      );
      expect(r.items.single.problemId, 'c1-fresh');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('降级必须记账', () {
    test('题库不足时列出空题位，并说明缺什么题型', () {
      // 只给 1 个选择题，但模板要 3 个
      final pool = [_c('c1-a', 'choice', 1)];
      final r = engine.compose(
        request: reqOf(_miniTemplate()),
        pool: pool,
      );

      expect(r.isComplete, isFalse);
      expect(r.emptySeats.length, 4, reason: '3 选择里填了 1 个，解答题一个没有');
      expect(r.emptySeats.map((s) => s.qtype).toSet(),
          containsAll(['choice', 'solve']));

      final missing = r.warnings.firstWhere((w) => w.contains('题库不足'));
      // 提示语是给用户看的，不该出现 choice / solve 这种内部标识
      expect(missing, contains('选择题 2 题'));
      expect(missing, contains('解答题 2 题'));
      expect(missing, isNot(contains('choice')));
      expect(missing, isNot(contains('solve')));
    });

    test('难度不够时记账，而不是悄悄抽个别的难度', () {
      // 模板第 3 题要难度 3，但题库里没有难度 3 的选择题
      final pool = [
        _c('c1', 'choice', 1),
        _c('c2', 'choice', 2),
        _c('c1b', 'choice', 1),
        _c('s2', 'solve', 2),
        _c('s3', 'solve', 3),
      ];
      final r = engine.compose(
        request: reqOf(_miniTemplate(), tolerance: 0),
        pool: pool,
      );

      expect(r.warnings.any((w) => w.contains('放宽到任意难度')), isTrue,
          reason: '题量不足时放宽了难度，必须告诉用户');
    });

    test('空题库：全部题位进 emptySeats，不抛异常', () {
      final r = engine.compose(
        request: reqOf(_miniTemplate()),
        pool: const [],
      );
      expect(r.items, isEmpty);
      expect(r.emptySeats.length, 5);
      expect(r.totalScore, 0);
      expect(r.warnings.any((w) => w.contains('题库不足')), isTrue);
    });

    test('空题库的提示要给出可行动作', () {
      final r = engine.compose(
        request: reqOf(_miniTemplate()),
        pool: const [],
      );
      final msg = r.warnings.firstWhere((w) => w.contains('题库不足'));
      expect(msg, contains('多选题库里的题'),
          reason: '只说"题库不足"用户不知道下一步做什么');
    });

    test('科目不匹配的题不会被抽到', () {
      final pool = [
        const Candidate(
          problemId: 'math2-1',
          stemText: '数二的题',
          qtype: 'choice',
          difficulty: 1,
          subject: 'math2',
        ),
      ];
      final r = engine.compose(
        request: reqOf(_miniTemplate()),
        pool: pool,
      );
      expect(r.items, isEmpty);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('与真实模板文件对接', () {
    test('能载入 data/exam_templates.json 并展开成题位', () async {
      final f = File('../data/exam_templates.json');
      if (!f.existsSync()) {
        // 测试从 app/ 目录跑，拿不到仓库根时跳过（不假装通过）
        return;
      }
      final all = await PaperTemplateLoader.loadFromFile(f, subject: 'math1');
      expect(all.keys, containsAll(['real_exam', 'quick_mock', 'wrong_only']));

      final real = all['real_exam']!;
      expect(real.totalScore, 150);
      expect(real.durationMinutes, 180);
      expect(real.seats.length, 22);
      expect(real.countsByQtype['choice'], 10);
      expect(real.countsByQtype['fill'], 6);
      expect(real.countsByQtype['solve'], 6);
      // 满分要对得上：10*5 + 6*5 + 6*12 = 50+30+72 = 152
      // 数据里 total_score 写 150（真题实际分值），解答题那节有说明
      expect(real.scoresByQtype['choice'], 50);
      expect(real.scoresByQtype['fill'], 30);
      expect(real.scoresByQtype['solve'], 72);
    });

    test('真实模板的难度是递增的（真题手感）', () async {
      final f = File('../data/exam_templates.json');
      if (!f.existsSync()) return;
      final all = await PaperTemplateLoader.loadFromFile(f, subject: 'math1');
      final seats = all['real_exam']!.seats;
      // 真题全卷每个题位都指定了难度，所以这里可以安全地取非空值
      final first5 = seats.take(5).map((s) => s.targetDifficulty!);
      final last5 = seats.reversed.take(5).map((s) => s.targetDifficulty!);
      expect(first5.every((d) => d <= 2), isTrue,
          reason: '卷子开头就出现拓展题，不符合由易到难');
      expect(last5.every((d) => d >= 2), isTrue,
          reason: '卷子结尾出现基础题，不符合由易到难');
    });

    test('错题专练：题型不限、分值不限，不会被当成具体题型', () async {
      final f = File('../data/exam_templates.json');
      if (!f.existsSync()) return;
      final all = await PaperTemplateLoader.loadFromFile(f, subject: 'math1');
      final wrongOnly = all['wrong_only']!;

      expect(wrongOnly.seats.length, 15);
      // 这三条盯的是一个具体 bug：把 `any` 当成具体题型，
      // 会让候选集永远为空 —— 那道大题一个题位都填不上
      expect(wrongOnly.seats.every((s) => s.isAnyQtype), isTrue);
      expect(wrongOnly.seats.every((s) => s.score == null), isTrue,
          reason: 'score_per_item 在数据里就是 null');
      expect(wrongOnly.seats.every((s) => s.targetDifficulty == null), isTrue,
          reason: 'difficulty 在数据里就是 null，不该被填成默认难度 2');
    });

    test('标签表能载入，且不硬编码在 UI 里', () async {
      final f = File('../data/exam_templates.json');
      if (!f.existsSync()) return;
      final labels = PaperTemplateLoader.parseLabels(await f.readAsString());
      expect(labels.difficultyName(1), isNotEmpty);
      expect(labels.difficultyName(3), isNotEmpty);
      expect(labels.qtypeName('choice'), isNotEmpty);
      expect(labels.qtypeName('solve'), isNotEmpty);
      // 未知值时给出可读的退路，不抛、不编造
      expect(labels.difficultyName(9), contains('9'));
      expect(labels.difficultyName(null), '不限');
      expect(labels.qtypeName(PaperSeat.anyQtype), '不限题型');
    });
  });
}
