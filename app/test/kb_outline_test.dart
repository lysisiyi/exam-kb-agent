/// 建库向导的骨架解析与预览（纯函数）测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/data/knowledge_md/knowledge_md_store.dart' show KbOutlineNode;
import 'package:kaoyan_math_agent/services/knowledge/kb_outline_writer.dart';

void main() {
  test('parseOutlineJson：标准嵌套；顶层数组也认；垃圾输出为 null', () {
    const ok = '''
{"title":"数据结构 408","outline":[
 {"name":"第一章 绪论","children":[{"name":"第一节 基本概念","children":[
   {"name":"什么是数据结构"},{"name":"算法与复杂度"}]}]}]}''';
    final r = parseOutlineJson(ok, fallbackTitle: 'x')!;
    expect(r.title, '数据结构 408');
    expect(r.outline.length, 1);
    expect(r.outline.first.children.first.children.length, 2);

    final arr = parseOutlineJson(
        '[{"name":"第一章 绪论","children":[]}]', fallbackTitle: '兜底');
    expect(arr, isNotNull);
    expect(arr!.title, '兜底');

    expect(parseOutlineJson('模型说了一堆人话', fallbackTitle: 'x'), isNull);
    expect(parseOutlineJson('{"title":"x","outline":[]}', fallbackTitle: 'x'),
        isNull);
  });

  test('空名节点被丢弃；children 缺失归一为空表（=叶子）', () {
    const raw = '''
{"outline":[{"name":"  "},{"name":"第一章","children":[{"name":"知识点"}]}]}''';
    final r = parseOutlineJson(raw, fallbackTitle: 'x')!;
    expect(r.outline.length, 1, reason: '空名节点丢弃');
    expect(r.outline.first.children.first.children, isEmpty);
  });

  test('outlinePreview：缩进树 + 章/知识点计数', () {
    final preview = outlinePreview(const [
      KbOutlineNode(name: '第一章 A', children: [
        KbOutlineNode(name: '第一节 a', children: [KbOutlineNode(name: '点1')]),
      ]),
      KbOutlineNode(name: '第二章 B', children: [KbOutlineNode(name: '点2')]),
    ]);
    expect(preview, contains('· 第一章 A'));
    expect(preview, contains('    · 点1'));
    expect(preview, contains('共 2 章 / 2 个知识点'));
  });
}
