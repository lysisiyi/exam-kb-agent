/// 五个只读工具：查询正确性、参数夹紧、以及"绝不动数据"。
///
/// ## 这里要守的几条
///
/// - **参数由模型生成，一律当不可信输入**：类型不对、数值越界、
///   多给没定义的键，都不能让一次查询炸掉，也不能真的按越界值去查。
/// - **`masteryPercent: null` 与 `0` 是两回事**。压成一个数会让
///   模型把"没复习过"说成"完全不会"，用户于是去补一个本来没开始的地方。
/// - **查到 0 条是成功，不是失败**。当成失败会诱导模型反复重试同一个查询。
/// - **只读**。这一期的每个工具都必须在调用前后不改动任何一张表。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/data/index/index_builder.dart';
import 'package:kaoyan_math_agent/domain/fsrs/fsrs_scheduler.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/services/chat/chat_tools.dart';
import 'package:kaoyan_math_agent/services/llm/llm_client.dart';
import 'package:kaoyan_math_agent/services/profile/mastery_service.dart';
import 'package:kaoyan_math_agent/services/review/review_repository.dart';

import 'support/test_env.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 脚手架
// ─────────────────────────────────────────────────────────────────────────────

/// 一份最小的知识点本体。
///
/// 不读真实 assets：那份 JSON 有 270 个叶子，而这一层要测的是
/// "按名称/别名找到它、把 id 翻成名字"，不是本体的内容对不对。
/// 用真实文件反而会让测试依赖 `sync_assets.py` 跑过。
KnowledgeBase _kb() => KnowledgeBase.fromJson({
      'subject': 'math1',
      'subject_name': '数学一',
      'version': 'test',
      'nodes': [
        {
          'id': '3',
          'name': '一元函数微分学',
          'level': 1,
          'is_leaf': false,
        },
        {
          'id': '3.2',
          'name': '微分中值定理',
          'level': 2,
          'parent_id': '3',
          'is_leaf': false,
        },
        {
          'id': '3.2.1',
          'name': '罗尔定理',
          'level': 3,
          'parent_id': '3.2',
          'is_leaf': true,
          'exam_weight': 0.9,
          'definition': '若 f 在[a,b]连续、(a,b)可导且 f(a)=f(b)，则存在 ξ 使 f\'(ξ)=0。',
          'aliases': ['Rolle'],
          'common_traps': ['忘了验证端点相等'],
          'exam_years': [2019, 2021],
        },
        {
          'id': '3.2.2',
          'name': '拉格朗日中值定理',
          'level': 3,
          'parent_id': '3.2',
          'is_leaf': true,
          'exam_weight': 0.5,
        },
      ],
    });

/// 一次性把工具都装好。
class _Rig {
  final TempLibrary env;
  final KnowledgeBase kb;

  late final WrongProblemsTool wrong;
  late final GetProblemTool problem;
  late final KnowledgePointsTool knowledge;
  late final ProfileTool profile;
  late final DueReviewTool due;

  _Rig(this.env, this.kb) {
    final scheduler = FsrsScheduler(enableFuzzing: false);
    wrong = WrongProblemsTool(env.db);
    problem = GetProblemTool(
      db: env.db,
      loadStore: () async => env.store,
      loadKnowledge: () async => kb,
    );
    knowledge = KnowledgePointsTool(() async => kb);
    profile = ProfileTool(
      loadService: () async => MasteryService(db: env.db, scheduler: scheduler),
      loadKnowledge: () async => kb,
    );
    due = DueReviewTool(
      loadRepo: () async => ReviewRepository(
        db: env.db,
        store: env.store,
        scheduler: scheduler,
      ),
      loadKnowledge: () async => kb,
    );
  }

  ChatToolRegistry get registry => ChatToolRegistry([
        wrong,
        problem,
        knowledge,
        profile,
        due,
      ]);

  /// 跑一次并把结果当 JSON 看。
  Future<Map<String, dynamic>> run(ChatTool tool, Map<String, dynamic> args) async {
    final out = await tool.run(args);
    return jsonDecode(out.content) as Map<String, dynamic>;
  }

  /// 每张表的行数。用来证明"调用工具没有动数据"。
  Future<Map<String, int>> rowCounts() async {
    final db = env.db;
    Future<int> n(String sql) async =>
        (await db.customSelect(sql).getSingle()).read<int>('c');
    return {
      'problems_index': await n('SELECT COUNT(*) AS c FROM problems_index'),
      'user_problem_state':
          await n('SELECT COUNT(*) AS c FROM user_problem_state'),
      'review_logs': await n('SELECT COUNT(*) AS c FROM review_logs'),
      'problem_knowledge': await n('SELECT COUNT(*) AS c FROM problem_knowledge'),
    };
  }
}

void main() {
  late TempLibrary env;

  setUp(() async {
    env = await TempLibrary.create();
  });

  tearDown(() async => env.dispose());

  /// 种一批错题：错次数、有无复习状态各不相同。
  Future<_Rig> rig({bool seed = true}) async {
    final r = _Rig(env, _kb());
    if (seed) {
      await seedProblems(env, [
        const SeedProblem(
          id: 'p-rolle',
          stem: '设 f 在 [0,1] 连续，(0,1) 可导，f(0)=f(1)=0，证明存在 ξ 使 f\'(ξ)=0',
          answer: '由罗尔定理直接可得',
          solution: '第一步验证三个条件，第二步用罗尔定理。',
          note: '我又忘了验证端点相等',
          primaryKpId: '3.2.1',
          primaryKpName: '罗尔定理',
          wrongCount: 4,
          errorCauses: ['concept'],
        ),
        const SeedProblem(
          id: 'p-lagrange',
          stem: '用拉格朗日中值定理证明不等式',
          primaryKpId: '3.2.2',
          primaryKpName: '拉格朗日中值定理',
          wrongCount: 2,
        ),
        const SeedProblem(
          id: 'p-limit',
          stem: '求极限 lim x→0 (sin x - x)/x^3',
          primaryKpName: '泰勒公式',
          wrongCount: 1,
        ),
        const SeedProblem(
          id: 'p-new',
          stem: '设 A 为三阶矩阵，求其特征值',
          primaryKpName: '矩阵特征值',
          // 故意不建状态行：这是"索引里有、状态表里没有"的组合
          wrongCount: null,
        ),
      ]);

      // 生产环境里索引是**带着本体**建的（启动时本体已载入），
      // `problems_index.primary_kp_name` 才会被冗余写上。而 seedProblems
      // 走的是"无本体"那条路（`TempLibrary.knowledge` 恒为 null），
      // 那一列会全是 null —— 按 kp 筛错题就一条都查不到。
      // 这里补一次带本体的重建，让测试环境与生产一致。
      //
      // ⚠️ 必须 `force: true`：不带 force 时 rebuild 会按"文件 mtime 没变"
      // 整批跳过（刚才那轮已经写过索引了），这一列就补不上。
      await IndexBuilder(db: env.db, store: env.store, knowledge: r.kb)
          .rebuild(force: true);
    }
    return r;
  }

  // ───────────────────────────────────────────────────────────────────────────
  group('query_wrong_problems', () {
    test('按错误次数从多到少，且带上掌握度字段', () async {
      final r = await rig();
      final j = await r.run(r.wrong, {});

      expect(j['matched'], 3, reason: 'p-new 没有状态行，错 0 次，默认 min_wrong=1 时不该出现');
      final ids = [for (final p in j['problems'] as List) (p as Map)['id']];
      expect(ids.first, 'p-rolle');
    });

    test('min_wrong 过滤出顽固错题', () async {
      final r = await rig();
      final j = await r.run(r.wrong, {'min_wrong': 3});

      expect(j['matched'], 1);
      expect((j['problems'] as List).single['id'], 'p-rolle');
    });

    test('kp 参数按主考点名做包含匹配', () async {
      final r = await rig();
      final j = await r.run(r.wrong, {'kp': '中值定理'});

      final ids = [for (final p in j['problems'] as List) (p as Map)['id']];
      expect(ids, containsAll(['p-lagrange']));
      expect(ids, isNot(contains('p-limit')));
    });

    test('keyword 走全文检索（中文分词那条路）', () async {
      final r = await rig();
      final j = await r.run(r.wrong, {'keyword': '极限'});

      expect((j['problems'] as List).single['id'], 'p-limit');
    });

    test('关键词查不到时明说"没有"，并提示换个说法', () async {
      final r = await rig();
      final out = await r.wrong.run({'keyword': '不存在的词'});

      expect(out.ok, isTrue, reason: '查到 0 条是成功，不是失败');
      expect(out.content, contains('没有题干含'));
      expect(out.content, contains('换个说法'));
    });

    test('limit 被夹紧：传 999 不会真的返回 999 条', () async {
      final r = await rig();
      final out = await r.wrong.run({'limit': 999});
      final j = jsonDecode(out.content) as Map<String, dynamic>;
      // 断言的是"参数被夹住了"这件事本身，而不是恰好有几条数据
      expect(j['returned'], lessThanOrEqualTo(kMaxToolRows));
      expect((out.content.length), lessThan(20000),
          reason: '灌一整个题库进上下文是这一层最该防的事');
    });

    test('参数类型不对也能活：字符串数字、负数、乱给键', () async {
      final r = await rig();
      final j = await r.run(r.wrong, {
        'limit': '2',
        'min_wrong': -5,
        'kp': null,
        '没定义过的键': '随便',
      });
      expect((j['problems'] as List).length, lessThanOrEqualTo(2));
    });

    test('没复习过的题给 null 掌握度，不能给 0', () async {
      final r = await rig();
      final j = await r.run(r.wrong, {'kp': '拉格朗日'});
      final p = (j['problems'] as List).single as Map;

      expect(p['masteryPercent'], isNull,
          reason: '0 是"完全不会"，null 是"还没有数据"，混起来会误导用户');
      expect(p['reviewed'], isFalse);
      expect(j['note'], contains('还没复习过'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('get_problem', () {
    test('取到完整内容，并把考点 id 翻成名字', () async {
      final r = await rig();
      final j = await r.run(r.problem, {'id': 'p-rolle'});

      expect(j['stem'], isNot(contains('罗尔定理')),
          reason: '题干里本来就没有这四个字');
      expect(j['stem'], contains('证明存在'));
      expect(j['answer'], contains('罗尔定理'));
      expect(j['solution'], contains('第一步'));
      expect(j['userNote'], contains('端点相等'));
      expect(j['knowledge'], ['罗尔定理'],
          reason: 'Markdown 里只存 id，不回本体查就只有一个 3.2.1');
      expect(j['qtype'], '解答', reason: '给 label 而不是枚举名 solve');
      expect((j['userState'] as Map)['wrongCount'], 4);
    });

    test('id 不存在：报错并说清下一步（不能返回一道空题）', () async {
      final r = await rig();
      final out = await r.problem.run({'id': 'p-不存在'});

      expect(out.ok, isFalse);
      expect(out.content, contains('读不到题目'));
      expect(out.content, contains('query_wrong_problems'),
          reason: '要告诉模型 id 从哪来，否则它会继续编');
    });

    test('缺 id 参数 → 明确失败，而不是当成"取默认题"', () async {
      final r = await rig();
      final out = await r.problem.run({});
      expect(out.ok, isFalse);
      expect(out.content, contains('缺少 id'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('query_knowledge_points', () {
    test('按名称命中，并给出章节路径与考频', () async {
      final r = await rig();
      final j = await r.run(r.knowledge, {'query': '罗尔'});

      expect(j['matched'], 1);
      final kp = (j['knowledgePoints'] as List).single as Map;
      expect(kp['id'], '3.2.1');
      expect(kp['path'], '一元函数微分学 > 微分中值定理 > 罗尔定理');
      expect(kp['examWeight'], 0.9);
      expect(kp['commonTraps'], contains('忘了验证端点相等'));
    });

    test('别名也算命中（用户不会只按正名问）', () async {
      final r = await rig();
      final j = await r.run(r.knowledge, {'query': 'Rolle'});
      expect((j['knowledgePoints'] as List).single['id'], '3.2.1');
    });

    test('不给 query 时按考频降序（用来回答"哪些是重点"）', () async {
      final r = await rig();
      final out = await r.knowledge.run({});
      final items = (jsonDecode(out.content) as Map)['knowledgePoints'] as List;

      expect(items.length, 2, reason: '默认只给叶子');
      expect((items.first as Map)['id'], '3.2.1',
          reason: '0.9 权重的排 0.5 前面');
      expect(out.content, contains('examWeight 越大越常考'));
    });

    test('only_leaves=false 时也能返回章节节点', () async {
      final r = await rig();
      final j = await r.run(r.knowledge, {'only_leaves': false, 'query': '微分'});
      final ids = [for (final k in j['knowledgePoints'] as List) (k as Map)['id']];
      expect(ids, contains('3.2'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('query_profile', () {
    test('一条复习记录都没有时：明说没有数据，而不是说"你很薄弱"', () async {
      final r = await rig();
      final j = await r.run(r.profile, {});
      final out = await r.profile.run({});

      expect(j['totalProblems'], 4);
      expect(j['hasReviewData'], isFalse);
      expect(j['overallMasteryPercent'], isNull);
      expect(out.content, contains('不要'),
          reason: '要明确挡住"没有数据 → 你很薄弱"这一步推理');
    });

    test('有复习数据后：薄弱考点按考点上卷，并带上复习题数', () async {
      final r = await rig(seed: false);
      await seedProblems(env, [
        SeedProblem(
          id: 'q1',
          stem: '罗尔定理的题',
          primaryKpId: '3.2.1',
          primaryKpName: '罗尔定理',
          wrongCount: 5,
          card: FsrsCard(
            due: DateTime(2024, 1, 1),
            stability: 3,
            difficulty: 6,
            reps: 3,
            state: CardState.review,
            lastReview: DateTime(2023, 12, 20),
          ),
        ),
      ]);

      final j = await r.run(r.profile, {'top_kp': 5});

      expect(j['totalProblems'], 1);
      expect(j['reviewedProblems'], 1);
      expect(j['hasReviewData'], isTrue);
      final weak = (j['weakestKnowledgePoints'] as List).single as Map;
      expect(weak['kpId'], '3.2.1');
      expect(weak['name'], '罗尔定理');
      expect(weak['wrongCount'], 5);
      // 复习题数必须一起报：只给平均掌握度，用户会以为是 10 道题的结论
      expect(weak.containsKey('reviewedCount'), isTrue);
      expect(weak.containsKey('problemCount'), isTrue);
      expect(weak['masteryPercent'], isNotNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('query_due_reviews', () {
    test('空库：说清是"一张卡都没有"，而不是"今天做完了"', () async {
      final r = await rig(seed: false);
      final out = await r.due.run({});
      final j = jsonDecode(out.content) as Map<String, dynamic>;

      expect(j['totalCards'], 0);
      expect(out.content, contains('一张卡都没有'));
      expect(out.content, isNot(contains('做完了')));
    });

    test('到期清单给出逾期天数与题目摘要', () async {
      final r = await rig(seed: false);
      await seedProblems(env, [
        SeedProblem(
          id: 'd1',
          stem: '一道早就该复习的题',
          primaryKpId: '3.2.1',
          wrongCount: 2,
          card: FsrsCard(
            due: DateTime(2020, 1, 1),
            stability: 2,
            difficulty: 5,
            reps: 2,
            state: CardState.review,
            lastReview: DateTime(2019, 12, 1),
          ),
        ),
      ]);

      final j = await r.run(r.due, {'limit': 5});
      final item = (j['dueList'] as List).single as Map;

      expect(item['id'], 'd1');
      expect(item['isNew'], isFalse);
      expect(item['overdueDays'], greaterThan(1000));
      expect(item['stem'], contains('早就该复习'));
      expect(item['kp'], '罗尔定理');
      expect(j['dueNow'], 1);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('只读纪律', () {
    test('把五个工具全跑一遍，任何一张表的行数都不变', () async {
      final r = await rig();
      final before = await r.rowCounts();

      await r.wrong.run({'limit': 5});
      await r.problem.run({'id': 'p-rolle'});
      await r.knowledge.run({'query': '罗尔'});
      await r.profile.run({});
      await r.due.run({'limit': 5});

      expect(await r.rowCounts(), before,
          reason: 'P2 的工具必须是纯读的；写操作要等 P3 的确认流程');
    });

    test('待复习工具不动"补建卡片"那一步（那是写库）', () async {
      // 索引里有题、状态表里没有 —— dueQueueProvider 会在这里补建卡片。
      // 工具走的是 repo.dueQueue，不能顺手把卡片建出来。
      final r = await rig();
      final before = await r.rowCounts();

      await r.due.run({});

      expect((await r.rowCounts())['user_problem_state'],
          before['user_problem_state'],
          reason: 'ensureCards 是写操作，工具里不能调（会悄悄改用户数据）');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('注册表', () {
    test('五个工具的规格都能编成 OpenAI 的 tools 数组', () async {
      final r = await rig();
      final specs = r.registry.specs;

      expect(specs.length, 5);
      for (final s in specs) {
        final j = s.toOpenAiJson();
        expect((j['function'] as Map)['name'], s.name);
        expect((j['function'] as Map)['description'], isNotEmpty,
            reason: '没写说明，模型只能瞎猜该用哪个工具');
      }
    });

    test('未知工具名：如实说不知道，并列出可用的', () async {
      final r = await rig();
      final out = await r.registry
          .invoke(ToolCall(id: 'x', name: 'delete_everything', arguments: '{}'));

      expect(out.ok, isFalse);
      expect(out.content, contains('没有名为'));
      expect(out.content, contains('query_wrong_problems'));
    });

    test('参数不是合法 JSON：报错并带上原文（那才是排查线索）', () async {
      final r = await rig();
      final out = await r.registry
          .invoke(ToolCall(id: 'x', name: 'query_profile', arguments: '{"top'));

      expect(out.ok, isFalse);
      // 原文是塞在 JSON 字符串里的，引号被转义了 —— 要解出来才看得见 `{"top`。
      final j = jsonDecode(out.content) as Map<String, dynamic>;
      expect(j['error'], contains('JSON'));
      expect(j['raw'], contains('{"top'));
    });

    test('工具内部抛异常被转成结果回灌，而不是让整轮对话崩掉', () async {
      final registry = ChatToolRegistry([_ThrowingTool()]);
      final out = await registry.invoke(
        ToolCall(id: 'x', name: 'boom', arguments: '{}'),
      );

      expect(out.ok, isFalse);
      expect(out.content, contains('查询执行失败'));
      expect(out.summary, contains('执行失败'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('调用记录的序列化', () {
    test('往返一致', () {
      const items = [
        ToolTraceItem(
          name: 'query_profile',
          argsPreview: 'top_kp=5',
          ok: false,
          summary: '查询执行失败',
          round: 2,
        ),
        ToolTraceItem(name: 'get_problem', round: 2),
      ];
      final back = decodeToolTrace(encodeToolTrace(items));

      expect(back.length, 2);
      expect(back.first.name, 'query_profile');
      expect(back.first.ok, isFalse);
      expect(back.first.summary, '查询执行失败');
      expect(back.first.round, 2);
      expect(back.first.label, '查学习画像', reason: '界面上要中文短名');
    });

    test('坏数据退化成空列表，不抛异常（一条历史备注不值得让会话打不开）', () {
      expect(decodeToolTrace(null), isEmpty);
      expect(decodeToolTrace(''), isEmpty);
      expect(decodeToolTrace('不是 JSON'), isEmpty);
      expect(decodeToolTrace('{"不是":"数组"}'), isEmpty);
    });
  });
}

/// 用来验证"工具抛异常"这条路的假工具。
class _ThrowingTool extends ChatTool {
  @override
  ToolSpec get spec => const ToolSpec(name: 'boom', description: '必炸');

  @override
  Future<ToolOutcome> run(Map<String, dynamic> args) async =>
      throw StateError('数据库锁住了');
}
