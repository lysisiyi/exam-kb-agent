/// P3 写操作：**提议**与**执行**是两个分开的东西。
///
/// ## 这个文件要守住的那条线
///
/// P3 之后助手能改题库了，所以"安全"不再靠"它只能读"来保证，而是靠：
///
/// > 工具只产出提案（一步都不写库），真正的写只在
/// > [ChatWriteExecutor.apply] 里，而它只被界面上的「确认」按钮调用。
///
/// 于是这里有两组必须成立的断言：
///
/// 1. **跑完所有写工具，题库一个字节都没变**（见「写工具不落库」那组）。
///    这条如果哪天坏了，整套确认流程就只是一句口号。
/// 2. **执行器在动手之前重新校验**（见「执行前重新校验」那组）。
///    提案可能在盘上躺了几天，这期间题目会被删、模板会被改。
///
/// ## 为什么绝大多数用例走"工具提议 → 执行器执行"这条路
///
/// 因为这两半之间唯一的耦合就是 `ChatWriteProposal.payload` 的键名。
/// 分别造数据去测，能测出两半各自"看起来对"，而**接不上**——
/// 而接不上正是最容易发生、也最难在真机上定位的一类错。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/data/error_causes.dart';
import 'package:kaoyan_math_agent/data/index/index_builder.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/services/chat/chat_tools.dart';
import 'package:kaoyan_math_agent/services/chat/chat_writes.dart';
import 'package:kaoyan_math_agent/services/library/problem_service.dart';
import 'package:kaoyan_math_agent/services/paper/paper_repository.dart';

import 'support/test_env.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 脚手架
// ─────────────────────────────────────────────────────────────────────────────

/// 一份最小的本体。与 `chat_tools_test.dart` 里那份同源。
KnowledgeBase _kb() => KnowledgeBase.fromJson({
      'subject': 'math1',
      'subject_name': '数学一',
      'version': 'test',
      'nodes': [
        {'id': '3', 'name': '一元函数微分学', 'level': 1, 'is_leaf': false},
        {
          'id': '3.2.1',
          'name': '罗尔定理',
          'level': 3,
          'parent_id': '3',
          'is_leaf': true,
          'exam_weight': 0.9,
          'aliases': ['Rolle'],
        },
        {
          'id': '3.2.2',
          'name': '拉格朗日中值定理',
          'level': 3,
          'parent_id': '3',
          'is_leaf': true,
          'exam_weight': 0.5,
        },
      ],
    });

/// 测试用的组卷模板。**注入文本**而不是读 asset：
/// 这一层要测的是"提议与执行对得上"，不是模板文件本身。
String _templates() => jsonEncode({
      'version': 'test',
      'templates': {
        'math1': {
          'quick_mock': {
            'id': 'math1.quick_mock',
            'name': '突击模考',
            'description': '测试用',
            'total_score': 24,
            'duration_minutes': 30,
            'sections': [
              {
                'qtype': 'solve',
                'name': '解答题',
                'start_no': 1,
                'count': 2,
                'score_per_item': 12,
                'difficulty': [2, 2],
              },
            ],
          },
          'wrong_only': {
            'id': 'math1.wrong_only',
            'name': '错题专练',
            'description': '测试用',
            'sections': [
              // 分值留空：走"估算分值"那条路
              {'qtype': 'any', 'name': '错题专练', 'start_no': 1, 'count': 2},
            ],
          },
        },
      },
    });

/// 两个错因，其中一个属于"重做本题没用"的那类。
ErrorCauseCatalog _causes() => const ErrorCauseCatalog(
      version: 'test',
      causes: [
        ErrorCause(
          id: 'concept',
          name: '概念不清',
          short: '概念',
          definition: '概念的定义没搞清。',
        ),
        ErrorCause(
          id: 'calc',
          name: '计算粗心',
          short: '计算',
          definition: '思路对但算错。',
        ),
      ],
    );

/// 把工具、执行器、依赖一次装好。
class _W {
  final TempLibrary env;
  final KnowledgeBase kb;
  final ErrorCauseCatalog causes;
  final PaperRepository papers;

  late final ProblemService service;
  late final ChatWriteExecutor executor;

  late final CreateProblemTool create;
  late final UpdateProblemTool update;
  late final DeleteProblemTool delete;
  late final ComposePaperTool compose;

  _W(this.env, this.kb, this.causes)
      : papers = PaperRepository(
          db: env.db,
          templatesJson: _templates(),
          causes: causes,
        ) {
    service = ProblemService(db: env.db, store: env.store, knowledge: kb);
    executor = ChatWriteExecutor(
      loadService: () async => service,
      loadKnowledge: () async => kb,
      loadPaper: () async => papers,
      loadCauses: () async => causes,
    );
    create = CreateProblemTool(
      loadService: () async => service,
      loadKnowledge: () async => kb,
      loadCauses: () async => causes,
    );
    update = UpdateProblemTool(
      loadService: () async => service,
      loadKnowledge: () async => kb,
      loadCauses: () async => causes,
    );
    delete = DeleteProblemTool(
      loadService: () async => service,
      loadKnowledge: () async => kb,
    );
    compose = ComposePaperTool(
      loadService: () async => service,
      loadPaper: () async => papers,
    );
  }

  /// 题库目录里有几个 Markdown 文件。
  ///
  /// 用"数文件"而不是"数索引行"来证明没写库：`ProblemService.save`
  /// 先落文件再刷索引，只盯着索引会漏掉"文件写了、索引还没刷"的中间态。
  int get fileCount => env.store.problemsDir
      .listSync()
      .where((e) => e.path.endsWith('.md'))
      .length;

  /// 每张关键表的行数。
  Future<Map<String, int>> rowCounts() async {
    final db = env.db;
    Future<int> n(String sql) async =>
        (await db.customSelect(sql).getSingle()).read<int>('c');
    return {
      'problems_index': await n('SELECT COUNT(*) AS c FROM problems_index'),
      'user_problem_state':
          await n('SELECT COUNT(*) AS c FROM user_problem_state'),
      'review_logs': await n('SELECT COUNT(*) AS c FROM review_logs'),
      'papers': await n('SELECT COUNT(*) AS c FROM papers'),
    };
  }
}

void main() {
  late TempLibrary env;

  setUp(() async {
    env = await TempLibrary.create();
  });

  tearDown(() async => env.dispose());

  Future<_W> rig({bool seed = true}) async {
    final w = _W(env, _kb(), _causes());
    if (seed) {
      await seedProblems(env, const [
        SeedProblem(
          id: 'p-rolle',
          stem: '证明存在 ξ 使 f\'(ξ)=0',
          answer: '由罗尔定理可得',
          solution: '先验证三个条件。',
          note: '我又忘了验证端点相等',
          primaryKpId: '3.2.1',
          primaryKpName: '罗尔定理',
          wrongCount: 4,
          errorCauses: ['concept'],
        ),
        SeedProblem(
          id: 'p-lagrange',
          stem: '用拉格朗日中值定理证明不等式',
          primaryKpId: '3.2.2',
          primaryKpName: '拉格朗日中值定理',
          wrongCount: 2,
        ),
      ]);
      // 与生产一致：索引要带着本体建一次，`primary_kp_name` 才有值。
      await IndexBuilder(db: env.db, store: env.store, knowledge: w.kb)
          .rebuild(force: true);
    }
    return w;
  }

  // ───────────────────────────────────────────────────────────────────────────
  group('写工具不落库（P3 的安全底线）', () {
    test('四个写工具全跑一遍，题库与文件一个字节都没变', () async {
      final w = await rig();
      final before = await w.rowCounts();
      final files = w.fileCount;

      final outs = <ToolOutcome>[
        await w.create.run({
          'stem': '新录入的一道题：求极限 lim x→0 sin x / x',
          'answer': '1',
          'knowledge_point': '罗尔定理',
          'error_causes': ['概念不清'],
        }),
        await w.update.run({'id': 'p-rolle', 'answer': '改过的答案'}),
        await w.delete.run({'id': 'p-lagrange'}),
        await w.compose.run({'template': 'quick_mock'}),
      ];

      expect(outs.every((o) => o.isProposal), isTrue,
          reason: '四个工具都应当返回提案而不是直接改数据');
      expect(await w.rowCounts(), before, reason: '表的行数不该变');
      expect(w.fileCount, files, reason: '题库目录不该多出或少掉文件');
    });

    test('提案的正文里明说"什么都还没发生"，并禁止重复调用', () async {
      final w = await rig();
      final out = await w.create.run({'stem': '一道新题'});
      final j = jsonDecode(out.content) as Map<String, dynamic>;

      expect(j['status'], 'pending_user_confirmation');
      expect(j['instruction'], contains('不要'));
      expect(j['instruction'], contains('已经'));
      expect(j['instruction'], contains('重复调用'));
    });

    test('删题的提案带不可逆标记，并说清会一起删掉什么', () async {
      final w = await rig();
      final out = await w.delete.run({'id': 'p-rolle'});

      expect(out.proposal!.destructive, isTrue);
      expect(out.proposal!.warning, contains('不能撤销'));
      expect(out.proposal!.warning, contains('复习进度'));
      final labels = [for (final f in out.proposal!.fields) f.label];
      expect(labels, contains('题干'));
      expect(labels, contains('错过次数'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('提议阶段的校验：不合格的题不摆到用户面前', () {
    test('题干为空 → 直接失败，不产出提案', () async {
      final w = await rig();
      final out = await w.create.run({'stem': '   '});

      expect(out.ok, isFalse);
      expect(out.proposal, isNull);
      expect(out.summary, contains('题干'));
    });

    test('选择题选项不足 2 个 → 失败', () async {
      final w = await rig();
      final out = await w.create.run({
        'stem': '下面哪个是对的？',
        'qtype': 'choice',
        'options': ['A'],
      });

      expect(out.ok, isFalse);
      expect(out.proposal, isNull);
    });

    test('考点名字写错 → 不拦，但卡片上明说会被标为待复核', () async {
      final w = await rig();
      final out = await w.create.run({
        'stem': '一道题',
        'knowledge_point': '压根不存在的定理',
      });

      expect(out.ok, isTrue);
      expect(out.proposal!.payload['kp_id'], isNull);
      expect(out.proposal!.warning, contains('待复核'));
      expect(out.proposal!.warning, contains('压根不存在的定理'));
    });

    test('改题不给任何字段 → 失败，并提示"这次什么也不会发生"', () async {
      final w = await rig();
      final out = await w.update.run({'id': 'p-rolle'});

      expect(out.ok, isFalse);
      expect(out.proposal, isNull);
      expect(out.content, contains('什么也不会发生'));
    });

    test('改题给的考点不存在 → 失败（宁可不改，也不把题挂到错的章节）', () async {
      final w = await rig();
      final out = await w.update.run({'id': 'p-rolle', 'knowledge_point': '不存在的定理'});

      expect(out.ok, isFalse);
      expect(out.proposal, isNull);
    });

    test('组卷模板名写错 → 失败，并把可用的模板列出来', () async {
      final w = await rig();
      final out = await w.compose.run({'template': 'real_full'});
      final j = jsonDecode(out.content) as Map<String, dynamic>;

      expect(out.ok, isFalse);
      expect((j['available'] as List).length, 2);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('执行器：录入', () {
    test('确认之后才真的落盘：文件、索引行、考点名都到位', () async {
      final w = await rig();
      final before = await w.rowCounts();
      final files = w.fileCount;

      final out = await w.create.run({
        'stem': '设 f 在 [0,2] 连续、(0,2) 可导，f(0)=f(2)，证明存在 ξ 使 f\'(ξ)=0',
        'qtype': 'proof',
        'difficulty': 1,
        'answer': '由罗尔定理直接可得',
        'knowledge_point': '罗尔定理',
        'error_causes': ['概念不清'],
        'source': '2024 数学一',
        'source_type': 'real_exam',
        'source_year': 2024,
      });
      final res = await w.executor.apply(out.proposal!);

      expect(res.ok, isTrue, reason: res.message);
      expect(w.fileCount, files + 1);
      final after = await w.rowCounts();
      expect(after['problems_index'], before['problems_index']! + 1);

      final row = await env.db.customSelect(
        "SELECT id, primary_kp_name, difficulty FROM problems_index "
        "WHERE stem_text LIKE '%[0,2]%'",
      ).getSingle();
      expect(row.read<String>('id'), startsWith('self-'));
      expect(row.read<String?>('primary_kp_name'), '罗尔定理',
          reason: '本体已在手上，冗余的考点名必须写上 —— '
              '否则按考点筛错题会漏掉这道题');
      expect(row.read<int>('difficulty'), 1);
    });

    test('错因给中文名也能认出来（模型不会记得受控 id）', () async {
      final w = await rig();
      final out = await w.create.run({
        'stem': '一道题',
        'error_causes': ['计算粗心'],
      });

      expect(out.proposal!.payload['error_causes'], ['calc']);
    });

    test('指纹撞上已有题目：卡片明说会覆盖，且执行后**沿用原 id**', () async {
      final w = await rig();
      final before = await w.rowCounts();
      final files = w.fileCount;

      final out = await w.create.run({
        'stem': '证明存在 ξ 使 f\'(ξ)=0',
        'answer': '换一个答案',
      });

      expect(out.proposal!.warning, contains('已有一道题干相同的题'));
      expect(out.proposal!.warning, contains('p-rolle'));
      expect(out.proposal!.payload['target_id'], 'p-rolle');

      final res = await w.executor.apply(out.proposal!);
      expect(res.ok, isTrue, reason: res.message);
      expect(w.fileCount, files, reason: '覆盖不该多出一个文件');

      final after = await w.rowCounts();
      expect(after['problems_index'], before['problems_index']!,
          reason: '同一道题覆盖，索引里不该多一行');

      // ⚠️ 最关键的一条：复习进度必须活着。
      final state = await env.db.customSelect(
        "SELECT wrong_count FROM user_problem_state WHERE problem_id='p-rolle'",
      ).getSingle();
      expect(state.read<int>('wrong_count'), 4,
          reason: '覆盖内容不能把错题次数清零 —— 那是用户的复习进度');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('执行器：修改', () {
    test('只改传上来的字段，别的一律不动', () async {
      final w = await rig();
      final out = await w.update.run({'id': 'p-rolle', 'answer': '新的答案'});
      final res = await w.executor.apply(out.proposal!);

      expect(res.ok, isTrue, reason: res.message);
      final read = await env.store.read('p-rolle');
      expect(read.problem!.answer, '新的答案');
      expect(read.problem!.solution, '先验证三个条件。', reason: '没传的字段不能被清空');
      expect(read.problem!.note, '我又忘了验证端点相等');
      expect(read.problem!.stem, '证明存在 ξ 使 f\'(ξ)=0');
    });

    test('传空串表示清空某一项', () async {
      final w = await rig();
      final out = await w.update.run({'id': 'p-rolle', 'note': ''});
      final res = await w.executor.apply(out.proposal!);

      expect(res.ok, isTrue, reason: res.message);
      final read = await env.store.read('p-rolle');
      expect(read.problem!.note, isNull);
      expect(read.problem!.answer, '由罗尔定理可得', reason: '别的字段不受影响');
    });

    test('改内容**不动**复习进度', () async {
      final w = await rig();
      final out = await w.update.run({'id': 'p-rolle', 'stem': '换个题干'});
      await w.executor.apply(out.proposal!);

      final state = await env.db.customSelect(
        "SELECT wrong_count FROM user_problem_state WHERE problem_id='p-rolle'",
      ).getSingle();
      expect(state.read<int>('wrong_count'), 4);
    });

    test('卡片的字段带"旧值"，用户能看出要改哪一处', () async {
      final w = await rig();
      final out = await w.update.run({'id': 'p-rolle', 'answer': '新的答案'});

      final answerField = out.proposal!.fields
          .firstWhere((f) => f.label == '答案');
      expect(answerField.before, '由罗尔定理可得');
      expect(answerField.value, '新的答案');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('执行器：删除', () {
    test('文件与索引行一起消失', () async {
      final w = await rig();
      final out = await w.delete.run({'id': 'p-lagrange'});
      final res = await w.executor.apply(out.proposal!);

      expect(res.ok, isTrue, reason: res.message);
      expect(env.store.fileFor('p-lagrange').existsSync(), isFalse);
      final left = await env.db.customSelect(
        "SELECT COUNT(*) AS c FROM problems_index WHERE id='p-lagrange'",
      ).getSingle();
      expect(left.read<int>('c'), 0);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('执行器：组卷', () {
    test('确认之后才写进 papers 表；提议阶段不写', () async {
      final w = await rig();
      final before = await w.rowCounts();

      final out = await w.compose.run({'template': 'quick_mock'});
      expect(await w.rowCounts(), before, reason: '提议阶段不该有卷子落库');

      final res = await w.executor.apply(out.proposal!);
      expect(res.ok, isTrue, reason: res.message);
      final after = await w.rowCounts();
      expect(after['papers'], before['papers']! + 1);

      final row = await env.db.customSelect(
        'SELECT title, total_score, items FROM papers',
      ).getSingle();
      expect(row.read<String>('title'), isNotEmpty);
      expect(row.read<int?>('total_score'), 24);
      expect(jsonDecode(row.read<String>('items')), hasLength(2));
    });

    test('分值留空的模板（错题专练）也能组出来，并标注是估算分', () async {
      final w = await rig();
      final out = await w.compose.run({'template': 'wrong_only'});
      final res = await w.executor.apply(out.proposal!);

      expect(res.ok, isTrue, reason: res.message);
      expect(out.proposal!.fields.map((f) => f.value).join(),
          contains('估算分值'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('执行前重新校验（提案可能在盘上躺了几天）', () {
    test('改一道已经被删掉的题 → 失败，且不新建文件', () async {
      final w = await rig();
      final out = await w.update.run({'id': 'p-rolle', 'answer': 'x'});
      final proposal = out.proposal!;

      // 提案摆出来之后，用户从别的页面把这道题删了。
      await w.service.delete('p-rolle');
      final files = w.fileCount;

      final res = await w.executor.apply(proposal);
      expect(res.ok, isFalse);
      expect(res.message, contains('已经不在了'));
      expect(w.fileCount, files, reason: '不能因为原题没了就写出一份新的');
    });

    test('删一道已经被删掉的题 → 失败，而不是假装删过', () async {
      final w = await rig();
      final out = await w.delete.run({'id': 'p-lagrange'});
      await w.service.delete('p-lagrange');

      final res = await w.executor.apply(out.proposal!);
      expect(res.ok, isFalse);
      expect(res.message, contains('没有删任何东西'));
    });

    test('认不出的 kind → 拒绝执行', () async {
      final w = await rig();
      final res = await w.executor.apply(const ChatWriteProposal(
        id: 'x',
        kind: 'drop_database',
        title: '？',
        summary: '？',
      ));

      expect(res.ok, isFalse);
      expect(res.message, contains('没有改动任何数据'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('提案与调用记录的序列化', () {
    test('提案 JSON 往返后一字不差', () async {
      final w = await rig();
      final out = await w.create.run({
        'stem': '一道题',
        'answer': '答案',
        'knowledge_point': '罗尔定理',
        'error_causes': ['概念不清'],
      });
      final p = out.proposal!;

      final back = ChatWriteProposal.fromJson(
        jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>,
      )!;

      expect(back.id, p.id);
      expect(back.kind, p.kind);
      expect(back.title, p.title);
      expect(back.summary, p.summary);
      expect(back.destructive, p.destructive);
      expect(back.warning, p.warning);
      expect(back.payload, p.payload);
      expect(back.fields.length, p.fields.length);
      expect(back.fields.last.label, p.fields.last.label);
      expect(back.fields.last.value, p.fields.last.value);
      expect(back.fields.last.before, p.fields.last.before);
    });

    test('认不出的 kind / 缺 id → 返回 null，而不是拼一张空卡片', () {
      expect(
        ChatWriteProposal.fromJson({'id': 'a', 'kind': 'rm_rf'}),
        isNull,
      );
      expect(ChatWriteProposal.fromJson({'kind': kWriteDeleteProblem}), isNull);
    });

    test('调用记录带着提案与决定一起往返', () async {
      final w = await rig();
      final out = await w.delete.run({'id': 'p-rolle'});
      final item = ToolTraceItem(
        name: 'delete_problem',
        ok: true,
        summary: out.summary,
        proposal: out.proposal,
      );
      final settled = item.decided(ToolTraceItem.decisionCancelled, '已取消');

      final raw = encodeToolTrace([settled]);
      final back = decodeToolTrace(raw).single;

      expect(back.isProposal, isTrue);
      expect(back.isPending, isFalse);
      expect(back.decision, ToolTraceItem.decisionCancelled);
      expect(back.result, '已取消');
      expect(back.proposal!.id, out.proposal!.id);
      expect(back.proposal!.destructive, isTrue);
      expect(back.proposal!.payload['id'], 'p-rolle');
    });

    test('P2 写的旧记录（没有 proposal 键）照样解得出来', () {
      // 这一列在 P2 就已经在盘上了，不能因为 P3 加了字段就读不动。
      const legacy = '[{"name":"query_wrong_problems","ok":true,'
          '"summary":"查到 3 道错题","round":1}]';
      final back = decodeToolTrace(legacy).single;

      expect(back.name, 'query_wrong_problems');
      expect(back.summary, '查到 3 道错题');
      expect(back.proposal, isNull);
      expect(back.isPending, isFalse);
    });

    test('坏掉的提案被丢掉，那一条退化成普通记录（而不是一张能点的空卡片）', () {
      const broken = '[{"name":"delete_problem","ok":true,'
          '"proposal":{"id":"x","kind":"rm_rf"}}]';
      final back = decodeToolTrace(broken).single;

      expect(back.name, 'delete_problem');
      expect(back.proposal, isNull);
      expect(back.isPending, isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('卡片文案', () {
    test('长文本截断时带上总字数 —— 用户要知道后面还有', () {
      final long = '甲' * 300;
      final s = writePreview(long, 100);
      expect(s, contains('共 300 字'));
      expect(s, contains('省略'));
    });

    test('空值显示成"（空）"而不是留白', () {
      expect(writePreview('   ', 10), '（空）');
    });

    test('错因词表拿不到时显示 id，而不是空串', () {
      expect(writeCauseLabel(null, ['calc', 'concept']), 'calc、concept');
    });

    test('错因词表在手上时显示中文名', () {
      expect(writeCauseLabel(_causes(), ['calc']), '计算粗心');
      expect(writeCauseLabel(_causes(), []), '（未选）');
    });
  });
}
