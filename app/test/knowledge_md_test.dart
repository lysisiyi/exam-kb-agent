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

  group('AI 草稿（K2 编辑器闭环）', () {
    const base = '''
---
id: math1.calc.1.1.1
name: 极限的定义
is_leaf: true
---

# 极限的定义

## 定义

旧的定义内容。

## 陷阱

1. 左右极限不等时不存在。
''';

    test('upsertAiDraft：无草稿时追加、有草稿时整段替换（保留其余小节）', () {
      final once = KnowledgeMdStore.upsertAiDraft(base, '草稿第一版');
      expect(KnowledgeMdStore.aiDraftBodyOf(once), '草稿第一版');
      expect(once, contains('旧的定义内容。'), reason: '正式内容必须原样保留');

      final twice = KnowledgeMdStore.upsertAiDraft(once, '草稿第二版');
      expect(KnowledgeMdStore.aiDraftBodyOf(twice), '草稿第二版');
      expect(twice, isNot(contains('草稿第一版')));
      expect(twice, contains('## 陷阱'), reason: '草稿之后的小节不能被吞');
      expect(twice, contains('左右极限不等时不存在。'));
    });

    test('acceptDraftInto：草稿并进「定义」，草稿小节移除', () {
      final withDraft = KnowledgeMdStore.upsertAiDraft(base, '新的定义草稿文本');
      final accepted = KnowledgeMdStore.acceptDraftInto(withDraft);
      expect(KnowledgeMdStore.aiDraftBodyOf(accepted), isNull);
      expect(accepted, contains('新的定义草稿文本'));
      expect(accepted, isNot(contains('旧的定义内容。')), reason: '定义被草稿替换');
      expect(accepted, contains('## 陷阱'));
    });

    test('acceptDraftInto：目标小节不存在时新建', () {
      const noDef = '''
---
id: x
---

# x

## 陷阱

1. 只有陷阱。
''';
      final withDraft = KnowledgeMdStore.upsertAiDraft(noDef, '补出来的定义');
      final accepted = KnowledgeMdStore.acceptDraftInto(withDraft);
      expect(accepted, contains('## 定义'));
      expect(accepted, contains('补出来的定义'));
    });

    test('removeAiDraft：只删草稿，其余原样', () {
      final withDraft = KnowledgeMdStore.upsertAiDraft(base, '待丢弃');
      final removed = KnowledgeMdStore.removeAiDraft(withDraft);
      expect(KnowledgeMdStore.aiDraftBodyOf(removed), isNull);
      expect(removed, contains('旧的定义内容。'));
      expect(removed, contains('## 陷阱'));
      expect(removed, isNot(contains('待丢弃')));
      expect(KnowledgeMdStore.removeAiDraft(removed), removed, reason: '幂等');
    });

    test('fileOf：按 frontmatter id 找到文件；写草稿→读回→接纳走真实 IO', () async {
      final store = KnowledgeMdStore(root: Directory('${tmp.path}/knowledge'));
      await store.importTree(_seed());
      final f = store.fileOf('math1', 'math1.calc.1.1.1');
      expect(f, isNotNull);
      expect(f!.path, endsWith('.md'));
      expect(store.fileOf('math1', '不存在.id'), isNull);
      store.writeAiDraft(f, '真实文件草稿');
      expect(store.draftOf(f), '真实文件草稿');
      store.acceptAiDraft(f);
      expect(store.draftOf(f), isNull);
      expect(f.readAsStringSync(), contains('真实文件草稿'));
    });
  });

  group('节点编辑（K2 增/改/删）', () {
    test('createChildNode：id 递增、frontmatter 完整、可回读', () async {
      final store = KnowledgeMdStore(root: Directory('${tmp.path}/knowledge'));
      await store.importTree(_seed());
      final f = store.createChildNode(
          'math1', 'math1.calc.limit', '新的知识点');
      expect(f.existsSync(), isTrue);
      final (kb, _) = store.loadTree('math1');
      final created =
          kb!.nodes.where((n) => n.id.startsWith('math1.calc.limit.')).toList();
      // 种子 limit 下无子节点 → 新 id 为 .1
      expect(created.any((n) => n.name == '新的知识点'), isTrue);
      expect(created.firstWhere((n) => n.name == '新的知识点').id,
          'math1.calc.limit.1');
      expect(created.firstWhere((n) => n.name == '新的知识点').isLeaf, isTrue);
    });

    test('renameNode：name/标题/文件名一起改，id 不动', () async {
      final store = KnowledgeMdStore(root: Directory('${tmp.path}/knowledge'));
      await store.importTree(_seed());
      final f = store.fileOf('math1', 'math1.calc.1.1.1')!;
      final oldPath = f.path;
      store.renameNode(f, '极限的定义（修订）');
      final renamed = File(oldPath.replaceFirst('极限的定义.md', '极限的定义（修订）.md'));
      expect(renamed.existsSync(), isTrue);
      final text = renamed.readAsStringSync();
      expect(text, contains('name: 极限的定义（修订）'));
      expect(text, contains('# 极限的定义（修订）'));
      expect(text, contains('id: math1.calc.1.1.1'), reason: 'id 必须原样');
      final (kb, _) = store.loadTree('math1');
      expect(kb!.byId['math1.calc.1.1.1']!.name, '极限的定义（修订）');
    });

    test('deleteNode：有子节点时拒绝；递归删除清整棵子树', () async {
      final store = KnowledgeMdStore(root: Directory('${tmp.path}/knowledge'));
      await store.importTree(_seed());
      final parentFile = store.fileOf('math1', 'math1.calc.1.1')!;
      expect(() => store.deleteNode(parentFile), throwsStateError,
          reason: '有子节点且未递归 → 拒绝');

      final removed = store.deleteNode(parentFile, recursive: true);
      expect(removed, greaterThan(1), reason: '含子树');
      final (kb, _) = store.loadTree('math1');
      expect(kb!.byId.containsKey('math1.calc.1.1'), isFalse);
      expect(kb.byId.containsKey('math1.calc.1.1.1'), isFalse, reason: '子树也要走');
      expect(kb.byId.containsKey('math1.calc.1'), isTrue, reason: '不误伤旁支');
    });
  });
}
