/// 会话报告（3.3）的 Markdown 纯函数测试。
///
/// 报告是"复习完这轮之后用户看到的第一样东西"，它撒谎的代价是
/// 用户按错误的印象安排复习。这里钉三件事：
/// 1. **正确率是计数算的**（做出/忘了各多少），不是从平均评分反推的；
/// 2. **名称翻译有就翻译、没有就如实给 id**（本体/词表未载入时不编造）；
/// 3. 空会话不是空指针，是一句实话。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/domain/fsrs/fsrs_scheduler.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/features/review/review_page.dart';

KnowledgeBase _kb() {
  const nodes = <KnowledgePoint>[
    KnowledgePoint(id: 'math1', name: '数学一', level: 1),
    KnowledgePoint(
      id: 'math1.calc.limit',
      name: '极限',
      level: 3,
      parentId: 'math1.calc',
      isLeaf: true,
    ),
    KnowledgePoint(
      id: 'math1.calc.deriv',
      name: '导数',
      level: 3,
      parentId: 'math1.calc',
      isLeaf: true,
    ),
  ];
  return KnowledgeBase(subject: 'math1', subjectName: '考研数学一', version: 't', nodes: nodes);
}

SessionGradeEntry _e(
  Rating r,
  String id, {
  String? kp,
  String causes = '[]',
}) =>
    SessionGradeEntry(
      problemId: id,
      stemPreview: '题面$id',
      primaryKpId: kp,
      causeIdsRaw: causes,
      rating: r,
    );

void main() {
  test('空会话是一句实话，不是异常', () {
    expect(sessionReportMarkdown(const []), '本轮没有评分记录。');
  });

  test('正确率按计数算，明细按评级列出', () {
    final md = sessionReportMarkdown([
      _e(Rating.forgot, 'p1', kp: 'math1.calc.limit'),
      _e(Rating.forgot, 'p2', kp: 'math1.calc.limit'),
      _e(Rating.easy, 'p3', kp: 'math1.calc.deriv'),
    ], kb: _kb(), now: DateTime(2026, 6, 1, 9));

    expect(md, contains('# 复习报告 · 2026-06-01'));
    expect(md, contains('做出 1 · 忘了 2（正确率 33%）'));
    expect(md, contains('- 忘了 · 极限 · 题面p1'));
    expect(md, contains('- 轻松 · 导数 · 题面p3'));
    // 最弱考点：忘了 2 次的极限排第一
    expect(md, contains('## 最需要回头看的考点'));
    expect(md, contains('- 极限 × 2'));
  });

  test('错因分布：词表在则译名，不在则如实给 id', () {
    final log = [
      _e(Rating.forgot, 'p1', causes: '["concept","calc"]'),
      _e(Rating.forgot, 'p2', causes: '["concept"]'),
    ];

    // 词表未载入（catalog: null）→ 用原始 id，不编造名字
    final raw = sessionReportMarkdown(log);
    expect(raw, contains('- concept × 2'));
    expect(raw, contains('- calc × 1'));

    // 坏 JSON → 当作没标错因，报告不崩
    final bad = sessionReportMarkdown([
      _e(Rating.forgot, 'p1', causes: '{oops'),
    ]);
    expect(bad, isNot(contains('错因分布')));
  });
}
