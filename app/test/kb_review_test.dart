/// AI 梳理本章的范围解析与输入构建（纯函数）测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/services/knowledge/kb_review_writer.dart';

import 'support/knowledge_fixture.dart';

void main() {
  final kb = math1LikeKb();

  test('selected=null → 顶层即各章；空库为 null', () {
    final scope = reviewScopeOf(kb, null)!;
    expect(scope.title, '考研数学（一）');
    // 顶层 = 科目的直接子节点（高数/线代两个分段）
    expect(scope.nodes.map((n) => n.name), containsAll(['高等数学', '线性代数']));

    final empty = KnowledgeBase(
        subject: 'x', subjectName: '空', version: 't', nodes: const [
      KnowledgePoint(id: 'x', name: '空', level: 1),
    ]);
    expect(reviewScopeOf(empty, null), isNull);
  });

  test('选中叶子 → 上溯到章节级分支（梳理"它所属的那一章"）', () {
    final leaf = kb.byId['math1.calc.limit.taylor']!;
    final scope = reviewScopeOf(kb, leaf)!;
    expect(scope.title, '极限与连续', reason: '叶子应上溯聚焦到所属章节');
    expect(scope.nodes.length, 3, reason: '该章下三个叶子');
  });

  test('选中章节本身 → 梳理其子节点；选中分段（depth2）保持自身', () {
    final chapter = kb.byId['math1.calc.limit']!;
    final scope = reviewScopeOf(kb, chapter)!;
    expect(scope.title, '极限与连续');

    final section = kb.byId['math1.calc']!;
    final s2 = reviewScopeOf(kb, section)!;
    expect(s2.nodes.length, greaterThan(1));
  });

  test('buildReviewInput：定义摘要截断、骨架标注、封顶', () {
    final scope = reviewScopeOf(kb, kb.byId['math1.calc.limit.taylor'])!;
    final input = buildReviewInput(scope, defCap: 6);
    expect(input, contains('章节：极限与连续'));
    expect(input, contains('定义摘要：'));

    // 无定义 → 骨架标注
    const skeleton = KbReviewScope(title: 't', focalId: 't-root', nodes: [
      KnowledgePoint(id: 'a', name: '只有名字', level: 4, isLeaf: true),
    ]);
    expect(buildReviewInput(skeleton), contains('（尚无定义——骨架）'));

    // 封顶
    final many = KbReviewScope(
      title: 't',
      focalId: 't-root',
      nodes: [
        for (var i = 0; i < 50; i++)
          KnowledgePoint(id: 'n$i', name: '节点$i', level: 4, isLeaf: true),
      ],
    );
    final capped = buildReviewInput(many, maxNodes: 10);
    expect('清单过长'.length, isPositive);
    expect(capped, contains('仅列前 10 个'));
    expect(capped, isNot(contains('节点10')));
  });

  group('结构化建议解析（K3 v2）', () {
    test('标准 JSON：summary/aliases/missing/notes 全解析；缺 parent 归一为 null', () {
      const raw = '''
{"summary":"整体不错","aliases":[{"node":"顺序表","alias":"顺序存储"}],
 "missing":[{"parent":"线性表","name":"双向链表"},{"name":"循环队列"}],
 "notes":"第三章节点偏碎"}''';
      final r = parseReviewSuggestions(raw)!;
      expect(r.summary, '整体不错');
      expect(r.aliases, [('顺序表', '顺序存储')]);
      expect(r.missing, [('线性表', '双向链表'), (null, '循环队列')]);
      expect(r.notes, '第三章节点偏碎');
    });

    test('宽容：markdown 包裹可解析；垃圾输出返回 null（调用方回退原文）', () {
      final wrapped = parseReviewSuggestions(
          '```json\n{"summary":"x","aliases":[{"node":"a","alias":"b"}]}\n```');
      expect(wrapped, isNotNull);
      expect(parseReviewSuggestions('模型说了一堆人话'), isNull);
      // 全空对象也算"没建议" → null（不显示空白面板）
      expect(parseReviewSuggestions('{"summary":"","aliases":[]}'), isNull);
    });

    test('空名条目丢弃', () {
      final r = parseReviewSuggestions('''
{"aliases":[{"node":"","alias":"x"},{"node":"a","alias":"  "},{"node":"b","alias":"c"}],
 "missing":[{"name":"  "},{"name":"有效"}]}''')!;
      expect(r.aliases, [('b', 'c')]);
      expect(r.missing, [(null, '有效')]);
    });
  });
}
