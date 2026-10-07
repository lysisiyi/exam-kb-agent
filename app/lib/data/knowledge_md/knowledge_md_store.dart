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

  // ── 单节点读写（K2 编辑器与 AI 草稿的地基） ──────────────────────────────

  /// 按 frontmatter id 找节点的 md 文件；找不到返回 null。
  ///
  /// 逐文件解析 frontmatter（768 节点 ≈ 一次点击几毫秒级 IO）——
  /// 只在"AI 补全/接纳草稿"这类低频写路径上调用，不进启动路径。
  File? fileOf(String subject, String nodeId) {
    final dir = subjectDir(subject);
    if (!dir.existsSync()) return null;
    for (final f in dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.md'))) {
      final fm = _Frontmatter.parse(f.readAsStringSync());
      if (fm['id'] == nodeId) return f;
    }
    return null;
  }

  /// 读出 `## AI 草稿（待确认）` 小节正文；没有草稿返回 null。
  String? draftOf(File file) =>
      file.existsSync() ? aiDraftBodyOf(file.readAsStringSync()) : null;

  /// 写入/替换 AI 草稿小节（保留文件其余内容）。返回写入后的全文。
  String writeAiDraft(File file, String markdown) {
    final text = file.readAsStringSync();
    final updated = upsertAiDraft(text, markdown);
    file.writeAsStringSync(updated);
    return updated;
  }

  /// 接纳草稿：草稿正文并进 [intoSection]（默认「定义」），移除草稿小节。
  String acceptAiDraft(File file, {String intoSection = '定义'}) {
    final text = file.readAsStringSync();
    final updated = acceptDraftInto(text, intoSection: intoSection);
    file.writeAsStringSync(updated);
    return updated;
  }

  /// 丢弃草稿：只移除草稿小节。
  String discardAiDraft(File file) {
    final text = file.readAsStringSync();
    final updated = removeAiDraft(text);
    file.writeAsStringSync(updated);
    return updated;
  }

  /// AI 草稿小节标题（与 md 渲染口径**唯一一处定义**）。
  static const aiDraftHeading = '## AI 草稿（待确认）';

  /// 纯函数：取草稿正文。
  static String? aiDraftBodyOf(String text) {
    final lines = text.split('\n');
    int? start;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim() == aiDraftHeading) {
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
    final body = buf.join('\n').trim();
    return body.isEmpty ? null : body;
  }

  /// 纯函数：写入/替换草稿小节（保留其余内容）。
  static String upsertAiDraft(String text, String markdown) {
    final body = markdown.trim();
    final lines = text.split('\n');
    int? head;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim() == aiDraftHeading) {
        head = i;
        break;
      }
    }
    if (head == null) {
      final b = StringBuffer(text);
      if (!text.endsWith('\n')) b.writeln();
      b..writeln()..writeln(aiDraftHeading)..writeln()..writeln(body)..writeln();
      return b.toString();
    }
    var end = lines.length;
    for (var i = head + 1; i < lines.length; i++) {
      if (lines[i].startsWith('## ')) {
        end = i;
        break;
      }
    }
    final out = <String>[
      ...lines.sublist(0, head + 1),
      '',
      body,
      '',
      ...lines.sublist(end),
    ];
    return out.join('\n');
  }

  /// 纯函数：移除草稿小节（含其标题到下一个 `## ` 之前）。
  static String removeAiDraft(String text) {
    final lines = text.split('\n');
    int? head;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim() == aiDraftHeading) {
        head = i;
        break;
      }
    }
    if (head == null) return text;
    var end = lines.length;
    for (var i = head + 1; i < lines.length; i++) {
      if (lines[i].startsWith('## ')) {
        end = i;
        break;
      }
    }
    // 连同标题上方多余的空气行一起收掉
    var start = head;
    while (start > 0 && lines[start - 1].trim().isEmpty) {
      start--;
    }
    return [...lines.sublist(0, start), ...lines.sublist(end)].join('\n');
  }

  /// 纯函数：草稿正文并进 [intoSection]（无该小节则创建），再移除草稿小节。
  static String acceptDraftInto(String text, {String intoSection = '定义'}) {
    final draft = aiDraftBodyOf(text);
    if (draft == null) return text;
    final withoutDraft = removeAiDraft(text);
    return _upsertSection(withoutDraft, intoSection, draft);
  }

  /// 纯函数：写入/替换 `## <title>` 小节正文。
  static String _upsertSection(String text, String title, String body) {
    final lines = text.split('\n');
    final headLine = '## $title';
    int? head;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim() == headLine) {
        head = i;
        break;
      }
    }
    if (head == null) {
      final b = StringBuffer(text);
      if (!text.endsWith('\n')) b.writeln();
      b..writeln()..writeln(headLine)..writeln()..writeln(body.trim())..writeln();
      return b.toString();
    }
    var end = lines.length;
    for (var i = head + 1; i < lines.length; i++) {
      if (lines[i].startsWith('## ')) {
        end = i;
        break;
      }
    }
    return [
      ...lines.sublist(0, head + 1),
      '',
      body.trim(),
      '',
      ...lines.sublist(end),
    ].join('\n');
  }

  // ── 节点编辑（K2 编辑器：增 / 改名 / 删） ────────────────────────────────

  /// 在 [parentId] 下新建一个叶子节点。返回写出的文件。
  ///
  /// id = `<parentId>.<n>`（n = 现有子节点最大编号 +1，不可解析时按数量+1）。
  /// 文件名序号取"同名前缀两位序号"家族里的下一个空位。
  File createChildNode(String subject, String parentId, String name) {
    final dir = subjectDir(subject);
    if (!dir.existsSync()) {
      throw StateError('科目目录不存在：${dir.path}（先做 K1 种子导入）');
    }
    // 找父节点所在目录：父是科目根 → 科目文件夹；否则父文件夹下
    final parentFile = fileOf(subject, parentId);
    final parentIsSubjectRoot = parentFile == null;
    final parentDir = parentIsSubjectRoot
        ? dir
        : Directory(parentFile.parent.path);

    // 现有子节点 id 编号
    var maxN = 0;
    var fileCount = 0;
    for (final f in dir.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.md')) continue;
      final fm = _Frontmatter.parse(f.readAsStringSync());
      if (fm['parent_id'] != parentId) continue;
      fileCount++;
      final id = fm['id'] ?? '';
      final n = int.tryParse(id.split('.').last);
      if (n != null && n > maxN) maxN = n;
    }
    final n = (maxN > 0 ? maxN : fileCount) + 1;
    final id = '$parentId.$n';

    // 文件名：父目录下序号前缀的下一个空位（与既有文件同家族排序）
    final safeName = name.replaceAll(RegExp(r'[\/:*?"<>|]'), '_');
    var seq = fileCount + 1;
    File file;
    do {
      final seqText = seq.toString().padLeft(2, '0');
      file = File('${parentDir.path}$_sep$seqText-$safeName.md');
      seq++;
    } while (file.existsSync());

    file.writeAsStringSync([
      '---',
      'id: $id',
      'name: $name',
      'parent_id: $parentId',
      'level: ${parentId.split('.').length + 1}',
      'is_leaf: true',
      'status: skeleton',
      'source: user',
      '---',
      '',
      '# $name',
      '',
    ].join('\n'));
    return file;
  }

  /// 改名：文件名与 frontmatter 的 name、以及标题行一起改。id 不动。
  void renameNode(File file, String newName) {
    final s = file.readAsStringSync();
    var out = s.replaceFirst(RegExp(r'^name:.*$', multiLine: true), 'name: $newName');
    final titleRe = RegExp(r'^# .*$', multiLine: true);
    if (titleRe.hasMatch(out)) {
      out = out.replaceFirst(titleRe, '# $newName');
    }
    // 文件名：保留序号前缀
    final base = p.basename(file.path);
    final m = RegExp(r'^(\d+)-').firstMatch(base);
    final prefix = m?.group(1) ?? '';
    final safeName = newName.replaceAll(RegExp(r'[\/:*?"<>|]'), '_');
    final newPath = p.join(file.parent.path,
        prefix.isEmpty ? '$safeName.md' : '$prefix-$safeName.md');
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(out);
    if (newPath != file.path && File(newPath).existsSync()) {
      File(newPath).deleteSync();
    }
    tmp.renameSync(newPath);
  }

  /// 删除节点。有子节点时 [recursive] 必须为 true（含子树），否则拒绝。
  int deleteNode(File file, {bool recursive = false}) {
    final fm = _Frontmatter.parse(file.readAsStringSync());
    final id = fm['id'] ?? '';
    var removed = 1;
    // 子树 = 所有 parent_id 以 `id.` 开头的文件
    final dir = file.parent;
    final root = _subjectRootOf(file);
    if (root != null) {
      final kids = <File>[];
      for (final f in root.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.md')) continue;
        final kfm = _Frontmatter.parse(f.readAsStringSync());
        final pid = kfm['parent_id'] ?? '';
        // ⚠️ 直系子节点 parent_id **等于** id；孙子串才带 `id.` 前缀。
        // 只判 `startsWith('$id.')` 会漏掉直系；只判 startsWith('$id')
        // 又会误伤 `math1.calc.1.10` 这种同前缀兄弟。
        if (pid == id || pid.startsWith('$id.')) kids.add(f);
      }
      if (kids.isNotEmpty && !recursive) {
        throw StateError('该节点还有 ${kids.length} 个子节点（调用方应先确认递归删除）');
      }
      for (final k in kids) {
        k.deleteSync();
        removed++;
      }
    }
    file.deleteSync();
    // 空目录顺手清掉（叶子所在目录若只剩空壳）
    if (dir.existsSync() &&
        !p.basename(dir.path).startsWith('_') &&
        dir.path != root?.path &&
        dir.listSync().isEmpty) {
      dir.deleteSync();
    }
    return removed;
  }

  /// 拖拽移动：把 [file] 挂到 [newParentId] 下（id 不变，改 parent_id + 移文件）。
  ///
  /// - 叶子 = 单文件移动；分支 = 连同其文件夹一起移动（文件夹里还有子树）。
  /// - 禁止移到自身/后代（环）与叶子节点下（叶子不承载子级）。
  /// - 显示顺序按 **id 排序**（不是文件名序号），移动后无需重排前缀。
  File moveNode(File file, String newParentId) {
    final text = file.readAsStringSync();
    final fm = _Frontmatter.parse(text);
    final id = fm['id'] ?? '';
    if (id.isEmpty) throw StateError('文件缺 id，拒绝移动');
    if (newParentId == id || newParentId.startsWith('$id.')) {
      throw StateError('不能移动到自身或自己的后代下');
    }
    final root = _subjectRootOf(file);
    if (root == null) throw StateError('找不到科目根（_subject.md）');
    // 科目 id 反查（目录名 → subject）
    final dirName = p.basename(root.path);
    final subject = subjectDirNames.entries
        .firstWhere((e) => e.value == dirName,
            orElse: () => const MapEntry('', ''))
        .key;

    final parentFile =
        subject.isEmpty ? null : fileOf(subject, newParentId);
    if (subject.isNotEmpty && parentFile == null && newParentId != subject) {
      throw StateError('目标父节点不存在：$newParentId');
    }
    // 新父目录：根 → 科目目录；分支 → 其文件夹
    final Directory newParentDir;
    if (parentFile == null) {
      newParentDir = root;
    } else {
      final pfm = _Frontmatter.parse(parentFile.readAsStringSync());
      if (pfm['is_leaf'] == 'true') {
        throw StateError('叶子节点不能作为父级（先把它改成骨架分支）');
      }
      newParentDir = parentFile.parent;
    }

    final newText = text.replaceFirst(
        RegExp(r'^parent_id:.*$', multiLine: true),
        'parent_id: $newParentId');

    if (fm['is_leaf'] == 'true') {
      // 叶子：写回 frontmatter 后移动到新目录
      file.writeAsStringSync(newText);
      final base = p.basename(file.path);
      var target = File(p.join(newParentDir.path, base));
      var seq = 1;
      while (target.existsSync()) {
        final safe = base.replaceFirst(RegExp(r'^\d+-'), '');
        target = File(p.join(newParentDir.path,
            '${(seq + 99).toString().padLeft(2, '0')}-$safe'));
        seq++;
      }
      file.renameSync(target.path);
      return target;
    }
    // 分支：文件夹连同子树整体移动，再改文件夹内自己那份 md
    final oldDir = file.parent;
    final newDir = Directory(p.join(newParentDir.path, p.basename(oldDir.path)));
    if (newDir.existsSync()) {
      throw StateError('目标下已有同名文件夹：${p.basename(oldDir.path)}');
    }
    // 先把 parent_id 写进旧位置的 md（随文件夹一起搬走）
    file.writeAsStringSync(newText);
    if (p.equals(oldDir.path, newParentDir.path)) return file;
    oldDir.renameSync(newDir.path);
    return File(p.join(newDir.path, p.basename(file.path)));
  }

  /// 上溯到科目根目录（找含 _subject.md 的那一级）。
  Directory? _subjectRootOf(File file) {
    var d = file.parent;
    for (var i = 0; i < 12; i++) {
      if (File(p.join(d.path, '_subject.md')).existsSync()) return d;
      final parent = d.parent;
      if (parent.path == d.path) return null;
      d = parent;
    }
    return null;
  }

  String get _sep => Platform.pathSeparator;

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

// ── 笔记回流（K2）：课时笔记归入知识点 ─────────────────────────────────────

/// 把一条课时笔记追加到节点的「## 来自 <课时> 的笔记」小节。
///
/// 小节按课时分组（同一课时的多条笔记合并在同一个小节下），
/// 每条笔记是一个 `- [mm:ss] 要点` 列表项。返回写入后的全文。
String appendLessonNote(
    File file, String lessonTitle, String? time, String point) {
  final text = file.existsSync() ? file.readAsStringSync() : '';
  final lines = text.split('\n');
  final sectionHead = '## 来自 $lessonTitle 的笔记';
  final entry = '- [${time ?? '—'}] $point';

  int? head;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim() == sectionHead) {
      head = i;
      break;
    }
  }
  if (head != null) {
    var end = lines.length;
    for (var i = head + 1; i < lines.length; i++) {
      if (lines[i].startsWith('## ')) {
        end = i;
        break;
      }
    }
    while (end > head + 1 && lines[end - 1].trim().isEmpty) {
      end--;
    }
    lines.insert(end, entry);
    return lines.join('\n');
  }

  final b = StringBuffer(text);
  if (!text.endsWith('\n')) b.writeln();
  b..writeln()..writeln(sectionHead)..writeln()..writeln(entry)..writeln();
  return b.toString();
}
