/// 知识库 Markdown 事实源的往返测试（K1，D13/D14 验收）：
/// id 保留、内容小节 roundtrip、幂等导入、坏文件宽容降级。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/data/knowledge_md/knowledge_md_store.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';

KnowledgeBase _seed() {
  const leaf1 = KnowledgePoint(
    id: 'math1.calc.1.1.1',
    name: '极限的定义',
    level: 4,
    parentId: 'math1.calc.1.1',
    isLeaf: true,
    examWeight: 0.86,
    definition:
        '当 \$x \\to x_0\$ 时 \$f(x) \\to A\$，记作 \$\\lim f(x)=A\$。',
    formulas: [r'\lim_{x\to x_0}f(x)=A', r'\lim_{x\to x_0}f(x)g(x)=AB'],
    aliases: ['limit', '重极限'],
    commonTraps: ['★ 左右极限不相等时极限不存在', '★ 分段函数端点必须分别求'],
    examYears: [2021, 2024],
    typicalQtypes: ['choice', 'solve'],
  );
  const leaf2 = KnowledgePoint(
    id: 'math1.calc.1.1.2',
    name: '极限的性质',
    level: 4,
    parentId: 'math1.calc.1.1',
    isLeaf: true,
  );
  const section = KnowledgePoint(
    id: 'math1.calc.1.1',
    name: '函数与极限',
    level: 3,
    parentId: 'math1.calc',
    isLeaf: false,
  );
  const chapter = KnowledgePoint(
    id: 'math1.calc.1',
    name: '第一章 预备知识',
    level: 3,
    parentId: 'math1.calc',
    isLeaf: false,
  );
  const s = KnowledgePoint(
    id: 'math1.calc',
    name: '高等数学',
    level: 2,
    parentId: 'math1',
    isLeaf: false,
  );
  const root = KnowledgePoint(
    id: 'math1',
    name: '考研数学一',
    level: 1,
    isLeaf: false,
  );
  return KnowledgeBase(
      subject: 'math1',
      subjectName: '考研数学一',
      version: '1.0.0',
      nodes: [root, s, chapter, section, leaf1, leaf2]);
}

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kb-md-test');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('导入产生 Obsidian 式文件夹：一个知识点一个 md、章节是文件夹', () async {
    final store = KnowledgeMdStore(root: Directory('${tmp.path}/knowledge'));
    final count = await store.importTree(_seed());
    expect(count, 6, reason: '科目根(_subject.md) 1 + 非根节点 5');

    final subjectDir = Directory('${tmp.path}/knowledge/考研数学一');
    expect(subjectDir.existsSync(), isTrue);
    expect(File('${subjectDir.path}/_subject.md').existsSync(), isTrue);
    // 章节文件夹 + 叶子文件
    expect(
        File('${subjectDir.path}/02-高等数学/'
                '04-函数与极限/05-极限的定义.md')
            .existsSync(),
        isTrue,
        reason: '叶子 = 父章节文件夹下的一个 .md');
  });

  test('roundtrip：id/别名/公式/陷阱/考频全部保真（D14 硬验收口径）', () async {
    final store = KnowledgeMdStore(root: Directory('${tmp.path}/knowledge'));
    final seed = _seed();
    await store.importTree(seed);
    final (kb, warnings) = store.loadTree('math1');
    expect(warnings, isEmpty);
    expect(kb, isNotNull);
    for (final n in seed.nodes) {
      final back = kb!.byId[n.id];
      expect(back, isNotNull, reason: 'id ${n.id} 必须原样保留');
      expect(back!.name, n.name);
      expect(back.isLeaf, n.isLeaf);
      expect(back.parentId, n.parentId);
      expect(back.definition, n.definition);
      expect(back.formulas, n.formulas);
      expect(back.aliases, n.aliases);
      // ★ 前缀在导出时有意剥离（它只是旧数据的强调记号，不是内容）
      expect(back.commonTraps,
          n.commonTraps.map((t) => t.replaceAll('★ ', '').trim()).toList());
      expect(back.examYears, n.examYears);
      expect(back.typicalQtypes, n.typicalQtypes);
      expect(back.examWeight, n.examWeight);
    }
  });

  test('幂等：重复导入安全，回读结果一致', () async {
    final store = KnowledgeMdStore(root: Directory('${tmp.path}/knowledge'));
    await store.importTree(_seed());
    await store.importTree(_seed());
    final (kb, warnings) = store.loadTree('math1');
    expect(kb!.nodes.length, 6);
    expect(warnings, isEmpty);
  });

  test('坏文件宽容：无 id 的文件跳过并给出警告，不静默丢节点', () async {
    final store = KnowledgeMdStore(root: Directory('${tmp.path}/knowledge'));
    await store.importTree(_seed());
    final chapDir =
        Directory('${tmp.path}/knowledge/考研数学一/01-考研数学一/02-高等数学');
    chapDir.createSync(recursive: true);
    final bad = File('${chapDir.path}/垃圾文件.md');
    bad.writeAsStringSync('# 没有 frontmatter 的文件');
    final (kb, warnings) = store.loadTree('math1');
    expect(kb!.nodes.length, 6);
    expect(warnings, isNotEmpty);
    expect(warnings.first, contains('垃圾文件.md'));
  });

  test('未导入的科目：loadTree 返回 (null, [])，provider 侧据此回落 JSON', () {
    final store = KnowledgeMdStore(root: Directory('${tmp.path}/knowledge'));
    final (kb, warnings) = store.loadTree('math2');
    expect(kb, isNull);
    expect(warnings, isEmpty);
  });
}
