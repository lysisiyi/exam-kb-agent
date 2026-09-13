/// 知识点**别名**与召回层的单元测试（技术债 T15）。
///
/// ## 为什么单独一个文件
/// 别名机制的每一个环节都可能悄悄失效，而且失效方式都很隐蔽 ——
/// 数据没写进去、分片合并时被覆盖、闸门把正确答案挡在门外。
/// 这些都不会抛异常，只会让召回率慢慢掉回去。
///
/// 所以这里用**合成知识点本体**做确定性测试：
/// 不依赖 `data/` 目录，不受真实数据变动影响，跑得也快。
/// 真实数据上的端到端召回率由 `recall_eval_test.dart` 负责。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/data/markdown/problem_markdown.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/services/tagger/knowledge_recall.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 合成本体
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

Problem _p(String stem) => Problem(
      id: 'p1',
      fingerprint: 'fp1',
      stem: stem,
      qtype: QuestionType.solve,
    );

void main() {
  group('别名数据模型', () {
    test('fromJson/toJson 往返保留 aliases', () {
      final j = <String, dynamic>{
        'id': 't.a.ch.k',
        'name': '正态分布',
        'level': 4,
        'parent_id': 't.a.ch',
        'is_leaf': true,
        'aliases': ['正态分布', r'X\sim N(\mu,\sigma^2)'],
      };
      final kp = KnowledgePoint.fromJson(j);
      expect(kp.aliases, ['正态分布', r'X\sim N(\mu,\sigma^2)']);
      expect(kp.toJson()['aliases'], kp.aliases);
    });

    test('缺少 aliases 字段时为空列表，不抛异常', () {
      final kp = KnowledgePoint.fromJson(<String, dynamic>{
        'id': 't.a.ch.k',
        'name': 'x',
        'level': 4,
        'is_leaf': true,
      });
      expect(kp.aliases, isEmpty);
    });
  });

  group('别名匹配', () {
    test('题干只有符号时，靠符号别名把正确答案召回', () {
      // 这正是 T15 要解决的失败模式：题干里没有「正态分布」四个字。
      final kb = _kb([
        _leaf(
          id: 't.a.ch.normal',
          name: '正态分布及其标准化计算',
          aliases: ['正态分布', r'X\sim N(\mu,\sigma^2)', r'\Phi(x)'],
          formulas: const [r'f(x)=\frac{1}{\sigma\sqrt{2\pi}}e^{-\frac{(x-\mu)^2}{2\sigma^2}}'],
        ),
        _leaf(id: 't.a.ch.other', name: '无关知识点A'),
        _leaf(id: 't.a.ch.other2', name: '无关知识点B'),
      ]);

      final r = KnowledgeRecall(knowledge: kb)
          .recall(_p(r'设 $X\sim N(0,1)$，求 $P\{|X|<1\}$。'));

      expect(
        r.candidates.map((c) => c.point.id),
        contains('t.a.ch.normal'),
        reason: '符号别名 X\\sim N(\\mu,\\sigma^2) 应当把正态分布召回',
      );
    });

    test('文本别名命中，且计分低于知识点全名命中', () {
      final kb = _kb([
        _leaf(id: 't.a.ch.extremum', name: '单调性、极值与最值', aliases: ['极值']),
        // 名称整体就是「极值」，会走 nameWeight（4.0）
        _leaf(id: 't.a.ch.exact', name: '极值', examWeight: 0.5),
      ]);

      final r = KnowledgeRecall(knowledge: kb).recall(_p('求该函数的极值。'));
      final byId = {for (final c in r.candidates) c.point.id: c};

      expect(byId.keys, containsAll(['t.a.ch.extremum', 't.a.ch.exact']));
      expect(
        byId['t.a.ch.exact']!.score,
        greaterThan(byId['t.a.ch.extremum']!.score),
        reason: '全名命中的权重（nameWeight=4.0）必须高于别名命中（aliasWeight=3.0）',
      );
    });

    test('别名命中数封顶，防止一个知识点靠别名压过真有公式命中的知识点', () {
      final kb = _kb([
        _leaf(
          id: 't.a.ch.k',
          name: '甲',
          aliases: const ['甲一', '甲二', '甲三', '甲四'],
        ),
      ]);

      final r = KnowledgeRecall(knowledge: kb).recall(_p('甲一 甲二 甲三 甲四'));
      final c = r.candidates.single;

      // 命中 4 个别名，但只按 2 个计分（上限），再加考频加权
      final expected = RecallConfig.defaults.aliasWeight * 2 +
          c.point.examWeight! * RecallConfig.defaults.examWeightFactor;
      expect(c.score, closeTo(expected, 1e-9));
    });

    test('别名不区分大小写，且忽略标点', () {
      final kb = _kb([
        _leaf(id: 't.a.ch.k', name: 'X', aliases: const ['最大 值']),
      ]);
      final r = KnowledgeRecall(knowledge: kb).recall(_p('求最大值。'));
      expect(r.candidates.map((c) => c.point.id), contains('t.a.ch.k'));
    });
  });

  group('公式闸门：只共享单字母变量不算命中', () {
    // 留出集上实测到的噪声：题干「∫x ln x dx」的 token 是 {\int, x, \ln, d}，
    // 而符号别名 D(X) 的 token 是 {d, x} —— 覆盖率满分，却毫无信息量。
    // 这条闸门把这类重合全部挡掉。
    //
    // ⚠️ 断言的是"没有公式命中"，不是"不在候选里"。
    // 候选里出现它并不奇怪：章节保底会往里塞叶子（每章至少 minPerChapter 个）。
    // 真正要防的是它**靠公式匹配拿到高分**，从而挤掉别的正确答案。
    test('单字母重合不产生公式命中', () {
      final kb = _kb([
        _leaf(
          id: 't.a.ch.noise',
          name: '数字特征的综合应用',
          aliases: const [r'\mathrm{D}(X)'],
        ),
      ]);

      final r = KnowledgeRecall(knowledge: kb)
          .recall(_p(r'求不定积分 $\int x\ln x\,\mathrm{d}x$。'));

      final noise =
          r.candidates.where((c) => c.point.id == 't.a.ch.noise').toList();
      for (final c in noise) {
        expect(
          c.reasons.join(),
          isNot(contains('公式匹配')),
          reason: '共享 {d, x} 两个单字母不构成公式命中',
        );
      }
    });

    test('排版命令不算数学运算（\\mathrm 不能骗过闸门）', () {
      // \mathrm 是排版包装，拆掉之后 D(X) 只剩 {d, x}，必须被闸门拒绝。
      final kb = _kb([
        _leaf(
          id: 't.a.ch.noise',
          name: '甲',
          aliases: const [r'\mathrm{D}(X)'],
        ),
      ]);
      final r = KnowledgeRecall(knowledge: kb)
          .recall(_p(r'求 $\int x\ln x\,\mathrm{d}x$。'));
      for (final c in r.candidates) {
        expect(c.reasons.join(), isNot(contains('公式匹配')));
      }
    });

    test('含 LaTeX 命令的重合仍然命中', () {
      final kb = _kb([
        _leaf(
          id: 't.a.ch.hit',
          name: '某知识点',
          aliases: const [r'\int f(\sqrt{x})\,\mathrm{d}x'],
        ),
      ]);

      final r = KnowledgeRecall(knowledge: kb)
          .recall(_p(r'求 $\int\frac{\mathrm{d}x}{1+\sqrt{x}}$。'));
      expect(r.candidates.map((c) => c.point.id), contains('t.a.ch.hit'));
    });
  });

  group('召回结果的可解释性', () {
    test('命中原因里能看出是哪个别名生效', () {
      final kb = _kb([
        _leaf(id: 't.a.ch.k', name: '正态分布及其标准化计算', aliases: const ['正态分布']),
      ]);
      final r = KnowledgeRecall(knowledge: kb).recall(_p('设 X 服从正态分布。'));
      expect(r.candidates.single.reasons.join(), contains('别名命中「正态分布」'));
      expect(r.aliasHits, 1);
    });

    test('没有别名时不报错，且 aliasHits 为 0', () {
      final kb = _kb([_leaf(id: 't.a.ch.k', name: '洛必达法则')]);
      final r = KnowledgeRecall(knowledge: kb).recall(_p('用洛必达法则求极限。'));
      expect(r.candidates, isNotEmpty);
      expect(r.aliasHits, 0);
    });
  });
}
