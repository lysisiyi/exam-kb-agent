/// 「AI 为什么这么判」面板的测试。
///
/// ## 这个面板最容易出的错不是崩溃，是**说错话**
///
/// 它要在一屏里同时说清两种可信度完全不同的东西：
/// - 「题目文件里存了什么」（事实）
/// - 「召回层现在会怎么算」（可复算，但不是模型原话）
///
/// 所以这里的断言重点不在"有没有渲染出来"，而在：
/// 1. **未知不能渲染成 0** —— `aiConfidence` 缺失时不能显示 `0%`，
///    那会让用户以为"模型完全没把握"（项目里"空槽=未知"的一贯纪律）。
/// 2. **边界必须说出来** —— "模型的 reason 没落库"这句提示如果被删掉，
///    用户会把召回重算的结果当成模型当年的判断。
/// 3. **名次是可信的核心信号** —— 主考点排在候选第几位直接可断言。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/providers.dart';
import 'package:kaoyan_math_agent/data/markdown/problem_markdown.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/features/problems/tag_explanation_panel.dart';
import 'package:kaoyan_math_agent/services/tagger/knowledge_recall.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 构造素材
// ─────────────────────────────────────────────────────────────────────────────

KnowledgePoint _leaf({
  required String id,
  required String name,
  String? definition,
  List<String> formulas = const [],
  List<String> aliases = const [],
  double examWeight = 0.5,
}) =>
    KnowledgePoint(
      id: id,
      name: name,
      level: 4,
      parentId: id.split('.').take(3).join('.'),
      isLeaf: true,
      examWeight: examWeight,
      definition: definition ?? '关于$name的定义。',
      formulas: formulas,
      aliases: aliases,
    );

KnowledgeBase _kb(List<KnowledgePoint> leaves) {
  final nodes = <KnowledgePoint>[
    const KnowledgePoint(id: 't', name: '测试科目', level: 1, isLeaf: false),
    const KnowledgePoint(
        id: 't.a', name: '分段', level: 2, parentId: 't', isLeaf: false),
    const KnowledgePoint(
        id: 't.a.ch', name: '章节', level: 3, parentId: 't.a', isLeaf: false),
  ];
  for (final l in leaves) {
    if (!nodes.any((n) => n.id == l.parentId)) {
      nodes.add(KnowledgePoint(
        id: l.parentId!,
        name: '章节',
        level: 3,
        parentId: 't.a',
        isLeaf: false,
      ));
    }
  }
  return KnowledgeBase(
    subject: 't',
    subjectName: '测试科目',
    version: '1',
    nodes: [...nodes, ...leaves],
  );
}

KnowledgePoint get _kpA =>
    _leaf(id: 't.a.ch.alpha', name: '洛必达法则', examWeight: 0.9);
KnowledgePoint get _kpB => _leaf(id: 't.a.ch.beta', name: '泰勒公式');
KnowledgePoint get _kpC => _leaf(id: 't.a.ch.gamma', name: '夹逼准则');

Problem _problem({
  List<KnowledgeRef> knowledge = const [],
  bool aiTagged = false,
  double? aiConfidence,
  bool needsReview = false,
  String stem = r'求 $\lim_{x\to0}\frac{\sin x}{x}$',
}) =>
    Problem(
      id: 'p1',
      fingerprint: 'fp1',
      stem: stem,
      qtype: QuestionType.solve,
      knowledge: knowledge,
      aiTagged: aiTagged,
      aiConfidence: aiConfidence,
      needsReview: needsReview,
    );

RecallCandidate _cand(KnowledgePoint p, double score, List<String> reasons) =>
    RecallCandidate(point: p, score: score, reasons: reasons);

RecallResult _result(List<RecallCandidate> cs, {int totalLeaves = 20}) =>
    RecallResult(
      candidates: cs,
      totalLeaves: totalLeaves,
      formulaHits: 3,
      nameHits: 1,
      aliasHits: 2,
    );

Future<void> _pumpView(
  WidgetTester tester, {
  required Problem problem,
  required RecallResult recall,
  KnowledgeBase? knowledge,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: TagExplanationView(
          problem: problem,
          recall: recall,
          knowledge: knowledge,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// 召回还没算出来（或算不出来）时的渲染。
Future<void> _pumpViewWithNote(
  WidgetTester tester, {
  required Problem problem,
  required String note,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: TagExplanationView(problem: problem, recallNote: note),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

// ─────────────────────────────────────────────────────────────────────────────

void main() {
  group('已落库的标注事实', () {
    testWidgets('未 AI 标注：说"手工填写"，并明说没有模型判据', (tester) async {
      await _pumpView(
        tester,
        problem: _problem(aiTagged: false),
        recall: _result([_cand(_kpA, 5, const ['名称命中「洛必达法则」'])]),
      );

      expect(find.text('手工填写'), findsOneWidget);
      expect(find.textContaining('没有"模型判据"可看'), findsOneWidget);
      // 未标注时不该冒出"把握/复核"这两行
      expect(find.text('把握'), findsNothing);
      expect(find.text('复核'), findsNothing);
    });

    testWidgets('AI 标注：把握按百分数显示，并说清它是什么的把握', (tester) async {
      await _pumpView(
        tester,
        problem: _problem(
          aiTagged: true,
          aiConfidence: 0.93,
          knowledge: const [
            KnowledgeRef(id: 't.a.ch.alpha', role: 'primary'),
            KnowledgeRef(id: 't.a.ch.beta', relevance: 0.6),
          ],
        ),
        recall: _result([_cand(_kpA, 5, const ['名称命中「洛必达法则」'])]),
        knowledge: _kb([_kpA, _kpB, _kpC]),
      );

      expect(find.text('93%'), findsOneWidget);
      // ⚠️ 这句定性说明不能少：confidence 不是"答案对不对"的把握
      expect(find.textContaining('不是对答案对错的把握'), findsOneWidget);
      expect(find.text('未要求复核'), findsOneWidget);
    });

    testWidgets('置信度缺失显示"未记录"，绝不显示 0%', (tester) async {
      await _pumpView(
        tester,
        problem: _problem(aiTagged: true, aiConfidence: null),
        recall: _result([_cand(_kpA, 5, const ['名称命中「洛必达法则」'])]),
      );

      expect(find.text('未记录'), findsOneWidget);
      // 关键：未知不能被渲染成"完全没把握"
      expect(find.text('0%'), findsNothing);
      expect(find.textContaining('旧版本写入的题目可能没有这个字段'), findsOneWidget);
    });

    testWidgets('needsReview 为真时如实说明它意味着什么', (tester) async {
      await _pumpView(
        tester,
        problem: _problem(aiTagged: true, aiConfidence: 0.6, needsReview: true),
        recall: _result([_cand(_kpA, 5, const ['名称命中「洛必达法则」'])]),
      );

      expect(find.text('当时被判为需人工确认'), findsOneWidget);
      expect(find.textContaining('低于当时模型的门槛'), findsOneWidget);
    });

    testWidgets('主/次考点显示名字与相关度；知识库缺失时退回 id', (tester) async {
      final problem = _problem(
        aiTagged: true,
        aiConfidence: 0.9,
        knowledge: const [
          KnowledgeRef(id: 't.a.ch.alpha', role: 'primary'),
          KnowledgeRef(id: 't.a.ch.beta', relevance: 0.6),
        ],
      );
      final recall = _result([_cand(_kpA, 5, const ['名称命中「洛必达法则」'])]);

      await _pumpView(tester,
          problem: problem, recall: recall, knowledge: _kb([_kpA, _kpB, _kpC]));
      expect(find.textContaining('洛必达法则  t.a.ch.alpha'), findsOneWidget);
      expect(find.textContaining('泰勒公式（0.60）'), findsOneWidget);

      await _pumpView(tester, problem: problem, recall: recall);
      // 没有本体时不编造名字，也不隐藏 id（id 本身就是线索）
      expect(find.textContaining('t.a.ch.alpha  t.a.ch.alpha'), findsOneWidget);
    });

    testWidgets('没有考点时显示"未填"，不显示空白', (tester) async {
      await _pumpView(
        tester,
        problem: _problem(),
        recall: _result([_cand(_kpA, 5, const ['名称命中「洛必达法则」'])]),
      );

      expect(find.text('未填'), findsOneWidget);
      expect(find.text('无'), findsOneWidget); // 次考点
    });
  });

  group('召回重算', () {
    testWidgets('逐条列出候选的得分与命中原因', (tester) async {
      await _pumpView(
        tester,
        problem: _problem(aiTagged: true, aiConfidence: 0.9),
        recall: _result([
          _cand(_kpA, 12.4, const ['公式匹配 ×0.83', '名称命中「洛必达法则」']),
          _cand(_kpB, 4.1, const ['别名命中「展开」']),
        ]),
        knowledge: _kb([_kpA, _kpB, _kpC]),
      );

      expect(find.textContaining('得分 12.40'), findsOneWidget);
      expect(find.text('公式匹配 ×0.83 · 名称命中「洛必达法则」'), findsOneWidget);
      expect(find.text('别名命中「展开」'), findsOneWidget);
      expect(find.textContaining('t.a.ch.alpha · 得分'), findsOneWidget);
    });

    testWidgets('命中原因缺失时明说，不留空白', (tester) async {
      await _pumpView(
        tester,
        problem: _problem(aiTagged: true, aiConfidence: 0.9),
        recall: _result([_cand(_kpA, 5, const [])]),
      );

      expect(find.text('（没有记录命中原因）'), findsOneWidget);
    });

    testWidgets('主考点在候选里：报出名次与得分', (tester) async {
      await _pumpView(
        tester,
        problem: _problem(
          aiTagged: true,
          aiConfidence: 0.9,
          knowledge: const [KnowledgeRef(id: 't.a.ch.beta', role: 'primary')],
        ),
        recall: _result([
          _cand(_kpA, 9.0, const ['名称命中「洛必达法则」']),
          _cand(_kpB, 7.5, const ['名称命中「泰勒公式」']),
          _cand(_kpC, 2.0, const ['章节保底']),
        ]),
        knowledge: _kb([_kpA, _kpB, _kpC]),
      );

      expect(find.textContaining('排第 2 / 3 位'), findsOneWidget);
      // 用「位（得分 …）」而不是裸的「得分 …」：后者在候选行里也有一份，
      // 断言会同时命中两个控件，测不出名次行到底有没有出现
      expect(find.textContaining('位（得分 7.50）'), findsOneWidget);
      // 该候选行被标成本题主考点
      expect(find.text('本题主考点'), findsOneWidget);
    });

    testWidgets('主考点不在候选里：如实报告，并给出可能的原因', (tester) async {
      await _pumpView(
        tester,
        problem: _problem(
          aiTagged: true,
          aiConfidence: 0.9,
          knowledge: const [KnowledgeRef(id: 't.a.ch.zzz', role: 'primary')],
        ),
        recall: _result([_cand(_kpA, 9.0, const ['名称命中「洛必达法则」'])]),
        knowledge: _kb([_kpA, _kpB, _kpC]),
      );

      expect(find.text('不在当前候选里'), findsOneWidget);
      expect(find.textContaining('本体更新过、或考点被手工改过'), findsOneWidget);
      expect(find.text('本题主考点'), findsNothing);
    });

    testWidgets('召回为空：说明原因，而不是渲染一张空表', (tester) async {
      await _pumpView(
        tester,
        problem: _problem(aiTagged: true, aiConfidence: 0.9),
        recall: const RecallResult(candidates: [], totalLeaves: 0),
      );

      expect(find.textContaining('重算得到 0 个候选'), findsOneWidget);
      expect(find.text('候选'), findsNothing);
    });

    testWidgets('候选过多时只列前 6 个，并交代总数', (tester) async {
      final many = [
        for (var i = 0; i < 5; i++) _cand(_kpA, 10.0 - i, const ['公式匹配 ×0.5']),
        _cand(_kpB, 5.0, const ['公式匹配 ×0.4']),
        _cand(_kpC, 4.0, const ['章节保底']),
        _cand(_kpA, 3.0, const ['章节保底']),
      ];
      await _pumpView(
        tester,
        problem: _problem(aiTagged: true, aiConfidence: 0.9),
        recall: _result(many),
        knowledge: _kb([_kpA, _kpB, _kpC]),
      );

      expect(find.textContaining('只列出前 6 个，共 8 个候选'), findsOneWidget);
      for (var i = 1; i <= 6; i++) {
        expect(find.text('$i.'), findsOneWidget);
      }
      expect(find.text('7.'), findsNothing);
    });

    testWidgets('命中统计只列非零项，不刷"公式 0"这种噪声', (tester) async {
      await _pumpView(
        tester,
        problem: _problem(aiTagged: true, aiConfidence: 0.9),
        recall: RecallResult(
          candidates: [_cand(_kpA, 5, const ['名称命中「洛必达法则」'])],
          totalLeaves: 20,
          formulaHits: 0,
          nameHits: 1,
          aliasHits: 0,
          chapterFloorAdded: 2,
        ),
      );

      expect(find.text('名称 1 · 章节保底 2'), findsOneWidget);
      expect(find.textContaining('公式 0'), findsNothing);
      expect(find.textContaining('别名 0'), findsNothing);
      // 覆盖面要报出来（口径：候选数 / 全部叶子）
      expect(find.textContaining('1 / 20 个叶子'), findsOneWidget);
    });

    testWidgets('一条都没命中时直说，不留空行', (tester) async {
      await _pumpView(
        tester,
        problem: _problem(aiTagged: true, aiConfidence: 0.9),
        recall: RecallResult(
          candidates: [_cand(_kpA, 5, const ['名称命中「洛必达法则」'])],
          totalLeaves: 20,
        ),
      );

      expect(find.text('没有任何策略命中'), findsOneWidget);
    });

    testWidgets('召回算不出来时，已落库的事实照样显示', (tester) async {
      await _pumpViewWithNote(
        tester,
        problem: _problem(
          aiTagged: true,
          aiConfidence: 0.93,
          knowledge: const [KnowledgeRef(id: 't.a.ch.alpha', role: 'primary')],
        ),
        note: '知识库没能载入，无法重算召回：本体文件缺失',
      );

      expect(find.textContaining('无法重算召回'), findsOneWidget);
      // 主要信息不能因为次要区块失败而消失
      expect(find.text('AI 标注'), findsOneWidget);
      expect(find.text('93%'), findsOneWidget);
      expect(find.textContaining('t.a.ch.alpha'), findsOneWidget);
      // 也不该渲染出一张假的空表
      expect(find.text('候选'), findsNothing);
    });
  });

  group('边界必须说清楚', () {
    testWidgets('明说模型的判断依据没有落库，避免把重算当成模型原话', (tester) async {
      await _pumpView(
        tester,
        problem: _problem(aiTagged: true, aiConfidence: 0.9),
        recall: _result([_cand(_kpA, 5, const ['名称命中「洛必达法则」'])]),
      );

      expect(find.text('怎么读这块内容'), findsOneWidget);
      expect(
          find.textContaining('「一句话判断依据」没有写进题目文件'), findsOneWidget);
      expect(find.textContaining('重算用的是'), findsOneWidget);
    });

    testWidgets('说明里不残留 Markdown 星号字面量', (tester) async {
      await _pumpView(
        tester,
        problem: _problem(),
        recall: _result([_cand(_kpA, 5, const ['章节保底'])]),
      );

      // 这是纯 Text（不是 Markdown 渲染器），`**` 会原样显示出来
      expect(find.textContaining('**'), findsNothing);
    });
  });

  group('折叠外壳（懒加载）', () {
    /// 记录召回器被构造了几次 —— 用于验证"展开才去算"。
    ///
    /// 召回器构造要遍历全部叶子预计算 IDF，「看一眼题目」不该付这个成本。
    Future<int Function()> pumpShell(
      WidgetTester tester, {
      required Problem problem,
    }) async {
      var built = 0;
      final kb = _kb([_kpA, _kpB, _kpC]);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          knowledgeBaseProvider.overrideWith((ref) async => kb),
          knowledgeRecallProvider.overrideWith((ref) async {
            built++;
            return KnowledgeRecall(knowledge: kb);
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TagExplanationPanel(problem: problem),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return () => built;
    }

    testWidgets('默认收起：正文不渲染，召回器也不构造', (tester) async {
      final built = await pumpShell(tester, problem: _problem());

      expect(find.text('AI 为什么这么判'), findsOneWidget);
      expect(find.text('展开'), findsOneWidget);
      expect(find.text('标注结果（题目文件里存的）'), findsNothing);
      expect(built(), 0, reason: '未展开时不该为召回付预计算成本');
    });

    testWidgets('展开后拿出召回结果，可再收起', (tester) async {
      final built = await pumpShell(
        tester,
        problem: _problem(
          aiTagged: true,
          aiConfidence: 0.9,
          knowledge: const [KnowledgeRef(id: 't.a.ch.alpha', role: 'primary')],
          // 题干里要真的出现知识点名，真实召回才会命中 —— 否则这条断言
          // 测的是"召回没命中"，而不是"面板把命中原因显示出来了"
          stem: '用洛必达法则求下列极限',
        ),
      );

      await tester.tap(find.text('AI 为什么这么判'));
      await tester.pumpAndSettle();

      expect(find.text('标注结果（题目文件里存的）'), findsOneWidget);
      expect(find.text('召回重算（按当前知识库，实时）'), findsOneWidget);
      expect(find.text('收起'), findsOneWidget);
      expect(built(), 1);

      // 真实召回跑在构造出来的小本体上：主考点应当被名称命中
      expect(find.textContaining('名称命中「洛必达法则」'), findsWidgets);

      await tester.tap(find.text('AI 为什么这么判'));
      await tester.pumpAndSettle();
      expect(find.text('标注结果（题目文件里存的）'), findsNothing);
      expect(find.text('展开'), findsOneWidget);
    });

    testWidgets('知识库载不进来时给一句实话，而不是静默空面板', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          knowledgeBaseProvider
              .overrideWith((ref) async => throw StateError('本体文件缺失')),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TagExplanationPanel(problem: _problem(aiTagged: true)),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('AI 为什么这么判'));
      await tester.pumpAndSettle();

      expect(find.textContaining('无法重算召回'), findsOneWidget);
      // 但"已落库的事实"仍然要显示 —— 它不依赖知识库
      expect(find.textContaining('AI 标注'), findsOneWidget);
    });
  });
}
