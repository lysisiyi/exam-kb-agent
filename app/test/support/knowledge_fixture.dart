/// 知识点本体的测试夹具。
///
/// ## 为什么要有两套形状
///
/// 三科本体的**树深并不一样**：数一/数二是 4 层，数三多一层「节」是 5 层；
/// 而它们历史上连 `level` 字段的写法都不一致（数一把章节标成 2、数三整体少 1）。
/// 用一份"理想数据"做夹具，恰恰会把真实数据里的形状问题掩盖掉 ——
/// 这正是「章节 0」那个 bug 能穿过 621 个测试的原因。
///
/// 所以这里刻意造两种形状，并且**故意把 level 写错**，用来钉住
/// "结构判断不看 level"这件事。
library;

import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';

KnowledgePoint _kp(
  String id,
  String name, {
  String? parent,
  bool leaf = false,
  int? level,
  double? weight,
}) =>
    KnowledgePoint(
      id: id,
      name: name,
      // 默认按 id 段数给 level；调用方可以显式传一个"错的"来测判据
      level: level ?? id.split('.').length,
      parentId: parent,
      isLeaf: leaf,
      examWeight: weight,
      definition: leaf ? '这是 $name 的定义。' : null,
      formulas: leaf ? const [r'x \to 0'] : const [],
      commonTraps: leaf ? const ['★ 常见陷阱'] : const [],
      examYears: leaf ? const [2020, 2022] : const [],
      typicalQtypes: leaf ? const ['choice', 'solve'] : const [],
      // 别名：详情卡里要显示（召回层靠它把题干说法映射到知识点）
      aliases: leaf ? [name, '$name 别名'] : const [],
    );

/// 数一形状：科目 → 分段 → 章节 → 叶子（4 层）。
///
/// ⚠️ `math1.calc.limit` 的 `level` 故意写成 **2**（历史数据就是这样）——
/// 章节判据必须仍然认得它。
KnowledgeBase math1LikeKb() => KnowledgeBase(
      subject: 'math1',
      subjectName: '考研数学（一）',
      version: 'test',
      nodes: [
        _kp('math1', '考研数学（一）', level: 1),
        _kp('math1.calc', '高等数学', parent: 'math1', level: 2),
        _kp('math1.linalg', '线性代数', parent: 'math1', level: 2),
        // 章节：level 写错成 2
        _kp('math1.calc.limit', '极限与连续', parent: 'math1.calc', level: 2, weight: 0.92),
        _kp('math1.calc.diff', '一元函数微分学', parent: 'math1.calc', level: 3, weight: 0.88),
        _kp('math1.linalg.eigen', '特征值与二次型', parent: 'math1.linalg', level: 3, weight: 0.71),
        _kp('math1.calc.limit.taylor', '泰勒公式求极限',
            parent: 'math1.calc.limit', leaf: true, weight: 0.91),
        _kp('math1.calc.limit.lhopital', '洛必达法则',
            parent: 'math1.calc.limit', leaf: true, weight: 0.86),
        _kp('math1.calc.limit.eq_infinitesimal', '等价无穷小替换',
            parent: 'math1.calc.limit', leaf: true, weight: 1.0),
        _kp('math1.calc.diff.mvt', '中值定理',
            parent: 'math1.calc.diff', leaf: true, weight: 0.75),
        _kp('math1.linalg.eigen.similarity', '相似对角化',
            parent: 'math1.linalg.eigen', leaf: true, weight: 0.71),
      ],
    );

/// 数三形状：科目 → 分段 → 章节 → **节** → 叶子（5 层）。
KnowledgeBase math3LikeKb() => KnowledgeBase(
      subject: 'math3',
      subjectName: '考研数学（三）',
      version: 'test',
      nodes: [
        _kp('math3', '考研数学（三）', level: 1),
        _kp('math3.calc', '高等数学', parent: 'math3', level: 2),
        _kp('math3.calc.limit', '极限与连续', parent: 'math3.calc', level: 3, weight: 0.9),
        _kp('math3.calc.limit.seq', '数列极限', parent: 'math3.calc.limit', level: 4, weight: 0.8),
        _kp('math3.calc.limit.funclimit', '函数极限',
            parent: 'math3.calc.limit', level: 4, weight: 0.7),
        _kp('math3.calc.limit.seq.existence', '数列极限的存在性',
            parent: 'math3.calc.limit.seq', leaf: true, weight: 0.8),
        _kp('math3.calc.limit.funclimit.infinitesimal', '无穷小比较',
            parent: 'math3.calc.limit.funclimit', leaf: true, weight: 0.7),
      ],
    );

/// 数据缺陷形状：**没有科目根**，三个分段是游离的。
///
/// 真机上的 math3 曾经就是这样（根节点是一个没有子节点的空壳）。
/// 视图必须照样画得出来，而不是给一片空白。
KnowledgeBase orphanKb() => KnowledgeBase(
      subject: 'math2',
      subjectName: '考研数学（二）',
      version: 'test',
      nodes: [
        _kp('math2', '考研数学（二）', level: 1), // 空壳根，谁也没挂上来
        _kp('math2.calc', '高等数学', level: 1), // 游离
        _kp('math2.linalg', '线性代数', level: 1), // 游离
        _kp('math2.calc.limit', '极限与连续', parent: 'math2.calc', level: 3),
        _kp('math2.calc.limit.taylor', '泰勒展开',
            parent: 'math2.calc.limit', leaf: true),
      ],
    );
