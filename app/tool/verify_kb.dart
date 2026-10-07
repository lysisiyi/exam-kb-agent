// 知识库目录校验器：不依赖 Flutter，直接走 App 同款加载器。
//
// 用法（在 app/ 目录下）：
//   dart run tool/verify_kb.dart "C:\...\library\knowledge\wzx-gaoshu-base"
//
// 打印节点数 / 叶子数 / 章节数 / 警告；非零退出 = 有警告或读不出。
// 与「按课程大纲生成知识库」（tools/data/build_kb_from_outline.py）配套：
// 生成完先跑它，确认 App 一定能加载，再打开界面看。
library;

import 'dart:io';

import 'package:kaoyan_math_agent/data/knowledge_md/knowledge_md_store.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tool/verify_kb.dart <知识库目录>');
    exit(2);
  }
  final dir = Directory(args.first);
  if (!dir.existsSync()) {
    stderr.writeln('目录不存在：${dir.path}');
    exit(2);
  }
  final store = KnowledgeMdStore(root: dir.parent);
  final (kb, warnings) = store.loadTreeAt(dir);
  for (final w in warnings) {
    stdout.writeln('warning: $w');
  }
  if (kb == null) {
    stderr.writeln('读不出：不是合法知识库（缺 _subject.md 或全无有效节点）');
    exit(1);
  }
  final leaves = kb.leaves;
  final filled = leaves
      .where((l) => (l.definition ?? '').trim().isNotEmpty)
      .length;
  stdout.writeln('库：${kb.subjectName}（id=${kb.subject}）');
  stdout.writeln(
      '节点 ${kb.nodes.length} · 章节 ${kb.chapters.length} · 叶子 ${leaves.length} · 已填 $filled · 骨架 ${leaves.length - filled}');
  // 前置/父子完整性：每个非根节点都应找得到父
  var orphans = 0;
  for (final n in kb.nodes) {
    if (n.parentId != null && !kb.byId.containsKey(n.parentId)) orphans++;
  }
  stdout.writeln(orphans == 0 ? '父子关系：完整' : '父子关系：孤儿 $orphans 个');
  exit(warnings.isEmpty && orphans == 0 ? 0 : 1);
}
