/// 知识库 Markdown 事实源（K1，V3_KB_PLAN）：Obsidian 式本地文件夹。
///
/// ## 目录约定
///
/// ```
/// <库根>/knowledge/<科目目录>/
///   _subject.md                       # 科目根（frontmatter: id/subject/version）
///   01-高等数学/
///     01-1 函数与极限.md               # 章节节点（is_leaf=false）
///     01-1 函数与极限/
///       01-1.3 极限的定义与性质.md      # 叶子节点（is_leaf=true）
/// ```
///
/// 一个知识点 = 一个 .md 文件；文件夹 = 章节。文件名带序号前缀保证排序。
/// frontmatter 存结构字段（id/parent/aliases/…），正文是统一格式的小节
/// （`## 定义` / `## 公式` / `## 陷阱` / `## 考频（估算）`）——这就是
/// 「内容格式重构」：旧 JSON 里混杂的 ★、\quad、混排段落全部规整化。
///
/// id 是**稳定性锚点**：改文件名、拖文件夹都不改 frontmatter 里的 id，
/// 题目关联因此不断（D14 硬验收）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/knowledge/knowledge_point.dart';

/// 科目在 `knowledge/` 下的目录名（中文可读，Obsidian 风格）。
const subjectDirNames = {
  'math1': '考研数学一',
  'math2': '考研数学二',
  'math3': '考研数学三',
};

class KnowledgeMdStore {
  /// `<库根>/knowledge`。
  final Directory root;
  KnowledgeMdStore({required this.root});

  Directory subjectDir(String subject) =>
      Directory(p.join(root.path, subjectDirNames[subject] ?? subject));

  bool isImported(String subject) => subjectDir(subject).existsSync();

  // ── 导入：JSON 树 → 文件夹 + md（幂等：已导入则跳过） ────────────────────

  /// 把 [kb] 整树写成 Obsidian 式文件夹。返回写出的文件数。
  /// 重跑安全：先清空科目目录再全量写出（种子数据无用户手改的前提）。
  Future<int> importTree(KnowledgeBase kb) async {
    final dir = subjectDir(kb.subject);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);

    var count = 0;

    // 科目根
    final sb = StringBuffer('---\n')
      ..writeln('id: ${kb.subject}')
      ..writeln('subject: ${kb.subject}')
      ..writeln('subject_name: ${kb.subjectName}')
      ..writeln('version: ${kb.version}')
      ..writeln('level: 1')
      ..writeln('is_leaf: false')
      ..writeln('---\n')
      ..writeln('# ${kb.subjectName}');
    File(p.join(dir.path, '_subject.md')).writeAsStringSync(sb.toString());
    count++;

    // 非根节点：按 id 深度排文件夹
    final nodes = [...kb.nodes]..sort((a, b) => a.id.compareTo(b.id));
    final dirOf = <String, Directory>{kb.subject: dir};
    for (final n in nodes) {
      // 科目根由 _subject.md 承担，不再落一份带序号的重复文件
      if (n.id == kb.subject) {
        dirOf[n.id] = dir;
        continue;
      }
      final parentDir = dirOf[n.parentId] ?? dir;
      final folder = _nodeDir(parentDir, n);
      final nodeDir = n.isLeaf ? parentDir : folder;
      if (!n.isLeaf) nodeDir.createSync(recursive: true);
      dirOf[n.id] = nodeDir;
      File(p.join(nodeDir.path, '${_fileName(n)}.md'))
          .writeAsStringSync(_renderNode(n, kb));
      count++;
    }
    return count;
  }

  // ── 回读：md 文件夹 → KnowledgeBase（UI 零改动的关键） ────────────────────

  /// 从文件夹重建 [KnowledgeBase]。文件缺失/坏 frontmatter 的文件**跳过并
  /// 返回警告**（宽容解析纪律），绝不静默丢节点——见返回值第二项。
  (KnowledgeBase?, List<String>) loadTree(String subject) {
    final dir = subjectDir(subject);
    if (!dir.existsSync()) return (null, const []);
    final warnings = <String>[];
    final subjectFile = File(p.join(dir.path, '_subject.md'));
    if (!subjectFile.existsSync()) {
      return (null, ['缺 _subject.md，科目 $subject 无法加载']);
    }
    final sfm = _Frontmatter.parse(subjectFile.readAsStringSync());

    final nodes = <KnowledgePoint>[];
    for (final f in dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.md') && !f.path.endsWith('_subject.md'))) {
      final raw = f.readAsStringSync();
      final fm = _Frontmatter.parse(raw);
      final id = fm['id'];
      if (id == null || id.isEmpty) {
        warnings.add('跳过无 id 的文件：${p.relative(f.path, from: root.path)}');
        continue;
      }
      final parsed = _parseNode(id, fm, raw);
      if (parsed == null) {
        warnings.add('节点解析失败：$id');
        continue;
      }
      nodes.add(parsed);
    }
    if (nodes.isEmpty) return (null, warnings);

    // 科目根：_subject.md 承担（不入文件循环），这里补回根节点
    final subjectId = sfm['id'] ?? subject;
    if (!nodes.any((n) => n.id == subjectId)) {
      nodes.insert(
          0,
          KnowledgePoint(
            id: subjectId,
            name: sfm['subject_name'] ?? subject,
            level: 1,
            isLeaf: false,
          ));
    }
    final kb = KnowledgeBase(
      subject: sfm['subject'] ?? subject,
      subjectName: sfm['subject_name'] ?? subject,
      version: '${sfm['version'] ?? '1.0.0'}+md',
      nodes: nodes,
    );
    return (kb, warnings);
  }

  // ── 渲染与解析 ────────────────────────────────────────────────────────────

  /// 文件/文件夹名：`NN-名称`。序号 = 同父下的排序位次（id 序）。
  String _fileName(KnowledgePoint n) =>
      '${n.idDepth.toString().padLeft(2, '0')}-${n.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}';

  Directory _nodeDir(Directory parentDir, KnowledgePoint n) =>
      Directory(p.join(parentDir.path, _fileName(n)));

  String _renderNode(KnowledgePoint n, KnowledgeBase kb) {
    final b = StringBuffer('---\n');
    b..writeln('id: ${n.id}')..writeln('name: ${n.name}');
    if (n.parentId != null) b.writeln('parent_id: ${n.parentId}');
    b..writeln('level: ${n.idDepth}')..writeln('is_leaf: ${n.isLeaf}');
    if (n.examWeight != null) b.writeln('exam_weight: ${n.examWeight}');
    if (n.aliases.isNotEmpty) {
      b.writeln('aliases:');
      for (final a in n.aliases) {
        b.writeln('  - "${a.replaceAll('"', "'")}"');
      }
    }
    if (n.examYears.isNotEmpty) b.writeln('exam_years: ${n.examYears.join(',')}');
    if (n.typicalQtypes.isNotEmpty) {
      b.writeln('typical_qtypes: ${n.typicalQtypes.join(',')}');
    }
    b.writeln('status: ${n.definition != null ? 'filled' : 'skeleton'}');
    b.writeln('source: seed');
    b.writeln('---\n');
    b.writeln('# ${n.name}\n');

    if (n.definition != null && n.definition!.trim().isNotEmpty) {
      b..writeln('## 定义')..writeln(n.definition!.trim())..writeln();
    }
    if (n.formulas.isNotEmpty) {
      b.writeln('## 公式');
      for (final f in n.formulas) {
        // 每条公式独立成 display 块——旧数据里 \quad 串接的长公式按顶层拆开的
        // 约定保留在渲染层，这里不拆，原样一条一块。
        // r'$$'：裸 '$$' 会被 Dart 当插值（$ 后必须跟标识符）。
        b..writeln(r'$$')..writeln(f.trim())..writeln(r'$$');
        b.writeln();
      }
    }
    if (n.commonTraps.isNotEmpty) {
      b.writeln('## 陷阱');
      for (var i = 0; i < n.commonTraps.length; i++) {
        b.writeln('${i + 1}. ${n.commonTraps[i].replaceAll('★ ', '').trim()}');
      }
      b.writeln();
    }
    if (n.examYears.isNotEmpty || n.typicalQtypes.isNotEmpty) {
      b.writeln('## 考频（估算）');
      if (n.examYears.isNotEmpty) {
        b.writeln('- 年份：${n.examYears.join('、')}（共 ${n.examYears.length} 次，估算值）');
      }
      if (n.typicalQtypes.isNotEmpty) {
        b.writeln('- 题型：${n.typicalQtypes.join('、')}');
      }
      b.writeln();
    }
    return b.toString();
  }

  KnowledgePoint? _parseNode(String id, Map<String, String> fm, String raw) {
    final body = raw.startsWith('---')
        ? raw.substring(raw.indexOf('\n---', 3) + 4)
        : raw;
    String? section(String title) {
      // 行扫描而不是正则 \Z：Dart RegExp 不支持 \Z，而 (?=\n## ) 在
      // "小节是文件最后一节"时永不命中（后面没有别的 ## 了），必须扫行。
      final lines = body.split('\n');
      final head = '## $title';
      int? start;
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trim() == head) {
          start = i + 1;
          break;
        }
      }
      if (start == null) return null;
      final buf = <String>[];
      for (var i = start; i < lines.length; i++) {
        if (lines[i].startsWith('## ')) break;
        buf.add(lines[i]);
      }
      final t = buf.join('\n').trim();
      return t.isEmpty ? null : t;
    }

    List<String> listOf(String title) {
      final s = section(title);
      if (s == null) return const [];
      return s
          .split('\n')
          .map((l) => l.replaceFirst(RegExp(r'^\s*\d+\.\s*'), '').trim())
          .where((l) => l.isNotEmpty && l != '\$\$' && l.trim() != r'$$')
          .toList();
    }

    final definition = section('定义');
    final aliases = (fm['aliases'] ?? '')
        .split(RegExp(r'[,\n]'))
        .map((e) => e.trim().replaceAll('"', ''))
        .where((e) => e.isNotEmpty)
        .toList();
    final years = <int>[];
    for (final part in (fm['exam_years'] ?? '').split(',')) {
      final y = int.tryParse(part.trim());
      if (y != null) years.add(y);
    }
    final qtypes = (fm['typical_qtypes'] ?? '')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    return KnowledgePoint(
      id: id,
      name: fm['name'] ?? id,
      level: int.tryParse(fm['level'] ?? '') ?? 4,
      parentId: fm['parent_id'],
      isLeaf: fm['is_leaf'] == 'true',
      examWeight: double.tryParse(fm['exam_weight'] ?? ''),
      definition: definition,
      formulas: listOf('公式')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList(),
      aliases: aliases,
      commonTraps: listOf('陷阱'),
      examYears: years,
      typicalQtypes: qtypes,
    );
  }
}

/// 极简宽容 frontmatter（值可带引号；列表项 `key:\n  - "x"` 摊平为逗号串）。
class _Frontmatter {
  static Map<String, String> parse(String text) {
    final out = <String, String>{};
    if (!text.startsWith('---')) return out;
    final end = text.indexOf('\n---', 3);
    if (end < 0) return out;
    String? lastKey;
    for (final line in text.substring(3, end).split('\n')) {
      final item = RegExp(r'^\s+-\s+(.*)$').firstMatch(line);
      if (item != null && lastKey != null) {
        final v = item.group(1)?.trim().replaceAll('"', '') ?? '';
        final prev = out[lastKey];
        out[lastKey] = prev == null ? v : '$prev,$v';
        continue;
      }
      final i = line.indexOf(':');
      if (i <= 0) continue;
      var v = line.substring(i + 1).trim();
      if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
        v = v.substring(1, v.length - 1);
      }
      lastKey = line.substring(0, i).trim();
      out[lastKey] = v;
    }
    return out;
  }
}
