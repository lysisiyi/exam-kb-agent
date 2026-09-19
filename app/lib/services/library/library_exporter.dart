/// 数据导出：把题库导出成「Obsidian 能直接打开」的文件夹。
///
/// ## 为什么这一项是差异化的核心
///
/// 竞品把数据锁在服务器里，用户换一个 App 就等于从零开始。
/// 本项目的立场是**数据是用户的**，所以导出不是一个"附加功能"，
/// 而是那个承诺的兑现方式 —— 它必须真的能用，不能只是"能导出个 json"。
///
/// 因此判据是：**导出后双击用 Obsidian 打开，公式和图片都正常显示。**
///
/// ## 三个设计约束
///
/// 1. **正文与内部完全一致**。导出走的是同一个
///    `ProblemMarkdownSerializer`，与 `problems/` 里的文件同源。
///    这意味着"导出"不可能因为格式漂移而失真 —— 它本来就是同一套格式。
///
/// 2. **用户状态以 `my_` 前缀合并进 frontmatter**，且**只在这里写**。
///    铁律是"绝不把用户状态写进 Markdown"，那条铁律针对的是
///    `problems/` 下的**事实源**文件（否则每复习一次就要重写文件、
///    而且索引不再可重建）。导出的副本是**只读快照**，写进去没有这个问题，
///    反而是必要的 —— 否则用户在 Obsidian 里看不到自己错了多少次。
///
/// 3. **图片路径要跟着走**。题目里的 `images/xxx.png` 相对路径在导出后
///    必须仍然成立，否则 Obsidian 里就是一堆碎图。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../data/db/database.dart';
import '../../data/markdown/problem_store.dart';
import '../review/review_repository.dart';

/// 导出结果。
class ExportResult {
  /// 写出的题目数量。
  final int problems;

  /// 复制的图片数量。
  final int images;

  /// 失败条目：`题目 id → 原因`。空表示全部成功。
  final Map<String, String> failures;

  /// 导出到哪个目录。
  final String targetDir;

  /// 因为目标目录里已有**同名但不像我们生成的**文件，而改了名字的根文件。
  ///
  /// 形如 `['如何打开.md → 如何打开（导出自错题本）.md']`。
  /// 空表示没发生改名。UI 应当把它显示出来 ——
  /// 用户下次去目标目录找 `如何打开.md` 时，得知道它去哪了。
  final List<String> renamedRootFiles;

  const ExportResult({
    required this.problems,
    required this.images,
    required this.targetDir,
    this.failures = const {},
    this.renamedRootFiles = const [],
  });

  bool get isClean => failures.isEmpty;

  String get summary {
    final parts = <String>[
      '导出 $problems 道题',
      if (images > 0) '图片 $images 张',
      if (failures.isNotEmpty) '失败 ${failures.length} 条',
      if (renamedRootFiles.isNotEmpty) '${renamedRootFiles.length} 个文件改了名',
    ];
    return parts.join(' · ');
  }
}

/// 我们生成的 Markdown 里的标记。
///
/// 用途只有一个：**导出时判断目标目录里的同名文件是不是我们自己写的**。
/// 目标目录很可能是用户的 Obsidian 库，`如何打开.md` 这种名字谁都可能占用 ——
/// 凭文件名覆盖就等于删用户的笔记。
const String kExportMarker = '<!-- kaoyan-math-agent-export -->';

/// 题库导出器。
class LibraryExporter {
  final AppDatabase db;
  final ProblemStore store;

  /// 库里 `images/` 的实际目录（复制图片用）。
  final Directory imagesDir;

  const LibraryExporter({
    required this.db,
    required this.store,
    required this.imagesDir,
  });

  /// 导出到 [target]。
  ///
  /// [target] 会被创建（已存在则复用，**不删除**里面的东西 ——
  /// 用户可能导出到自己的笔记库里，删掉他的文件是不可接受的）。
  /// 同名文件会被覆盖：那是我们自己上一次导出的产物。
  Future<ExportResult> exportTo(Directory target) async {
    if (!target.existsSync()) await target.create(recursive: true);

    final problemsDir = Directory(p.join(target.path, 'problems'));
    final targetImages = Directory(p.join(target.path, 'images'));
    if (!problemsDir.existsSync()) await problemsDir.create(recursive: true);

    final rows = await db.select(db.problemsIndex).get();
    final states = await db.select(db.userProblemState).get();
    final stateById = {for (final s in states) s.problemId: s};

    final failures = <String, String>{};
    var written = 0;
    var imagesCopied = 0;
    final copiedImages = <String>{};

    for (final row in rows) {
      try {
        final read = await store.read(row.id);
        if (!read.isOk) {
          failures[row.id] = read.error ?? '读取失败';
          continue;
        }
        final problem = read.problem!;

        final md = ProblemMarkdownSerializer.serialize(
          problem,
          includeUserState: _userStateOf(stateById[row.id]),
        );
        await _writeAtomic(
          File(p.join(problemsDir.path, '${_safeFileName(row.id)}.md')),
          md,
        );
        written++;

        for (final rel in problem.images) {
          final name = p.basename(rel);
          if (name.isEmpty || !copiedImages.add(name)) continue;
          final src = File(p.join(imagesDir.path, name));
          if (!src.existsSync()) {
            // 图片缺失不影响这道题的导出，但要记下来 ——
            // 静默丢图是"导出了但打不开"的典型成因
            failures['${row.id}#$name'] = '图片文件不存在';
            continue;
          }
          if (!targetImages.existsSync()) {
            await targetImages.create(recursive: true);
          }
          await src.copy(p.join(targetImages.path, name));
          imagesCopied++;
        }
      } catch (e) {
        failures[row.id] = '$e';
      }
    }

    // 这两个文件写在**目标根目录**，而目标根目录很可能是用户自己的
    // Obsidian 库（类注释里承诺过"不删用户的东西"）。
    // 所以：同名文件若不像我们生成的，就**不覆盖**，改成带后缀的名字并记下来。
    final skippedRoot = <String>[];
    for (final entry in {
      '题库索引.md': _indexMarkdown(rows, stateById),
      '如何打开.md': _readmeMarkdown(written, imagesCopied),
    }.entries) {
      final target0 = File(p.join(target.path, entry.key));
      if (target0.existsSync() && !_looksLikeOurs(target0)) {
        final alt = File(
          p.join(target.path, '${p.basenameWithoutExtension(entry.key)}'
              '（导出自错题本）.md'),
        );
        await _writeAtomic(alt, entry.value);
        skippedRoot.add('${entry.key} → ${p.basename(alt.path)}');
        continue;
      }
      await _writeAtomic(target0, entry.value);
    }

    return ExportResult(
      problems: written,
      images: imagesCopied,
      targetDir: target.path,
      failures: failures,
      renamedRootFiles: skippedRoot,
    );
  }

  /// 这个文件像不像我们导出生成的。
  ///
  /// 判据是**我们自己在文件开头写的标记**，而不是文件名 ——
  /// 同名文件完全可能是用户自己的笔记（"如何打开.md"这个名字太容易被占用了）。
  /// 读不出来时保守地当作"不是我们的"，宁可多写一个新文件，也不覆盖用户内容。
  static bool _looksLikeOurs(File f) {
    try {
      final head = f.readAsStringSync();
      return head.contains(kExportMarker);
    } catch (_) {
      return false;
    }
  }

  /// 用户状态 → frontmatter 里的 `my_*` 字段。
  ///
  /// 只放"用户在 Obsidian 里也想看到"的东西。刻意**不**导出
  /// `fsrs_state` 原文 —— 那是一坨 JSON，写进 Markdown 只会让文件难读，
  /// 而它真正的用途是复习调度，不需要人看。
  Map<String, dynamic>? _userStateOf(UserProblemStateRow? s) {
    if (s == null) return null;
    final due = dueOfState(s);
    return {
      'wrong_count': s.wrongCount,
      'mastery': double.parse(s.mastery.toStringAsFixed(3)),
      // `firstSeen` 在表定义里是非空列（带 currentDateAndTime 默认值），
      // 所以这里不需要判空
      'first_seen': _dateOnly(s.firstSeen),
      if (s.lastWrong != null) 'last_wrong': _dateOnly(s.lastWrong!),
      if (due != null) 'next_review': _dateOnly(due),
      if (s.starred) 'starred': true,
      // 错因是受控词表的 id，导出时保持 id 而不翻译成中文：
      // 翻译会引入一份需要跟着 data/error_causes.json 同步的映射，
      // 而不翻译至少是稳定、可 grep 的。
      'error_causes': _errorCausesOf(s.errorCauses),
    };
  }

  static List<String> _errorCausesOf(String raw) {
    final t = raw.trim();
    if (t.isEmpty || t == '[]') return const [];
    // 形如 ["concept","method"]；手写解析而不是引一个 JSON 依赖 ——
    // 这里的输入是我们自己写的，格式固定
    return t
        .replaceAll(RegExp(r'^\[|\]$'), '')
        .split(',')
        .map((e) => e.replaceAll('"', '').trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// 索引页：按主考点分组列题目，方便在 Obsidian 里跳转。
  String _indexMarkdown(
    List<ProblemIndexRow> rows,
    Map<String, UserProblemStateRow> stateById,
  ) {
    final byKp = <String, List<ProblemIndexRow>>{};
    for (final r in rows) {
      final name = r.primaryKpName;
      final kp = (name == null || name.isEmpty) ? '未归类的题' : name;
      byKp.putIfAbsent(kp, () => []).add(r);
    }
    final kpNames = byKp.keys.toList()
      ..sort((a, b) => byKp[b]!.length.compareTo(byKp[a]!.length));

    final b = StringBuffer()
      ..writeln(kExportMarker)
      ..writeln('# 错题本索引')
      ..writeln()
      ..writeln('共 ${rows.length} 道题，按主考点分组。')
      ..writeln()
      ..writeln('> 这是导出快照，在此处的修改**不会**同步回 App。')
      ..writeln();

    for (final kp in kpNames) {
      final list = byKp[kp]!;
      b.writeln('## $kp（${list.length}）');
      b.writeln();
      for (final r in list) {
        final s = stateById[r.id];
        final wrong = s == null ? 0 : s.wrongCount;
        final diff = r.difficulty == 1
            ? '基础'
            : (r.difficulty == 2 ? '综合' : '拓展');
        final title = _oneLine(r.stemText);
        b.writeln('- [[${_safeFileName(r.id)}|$title]]'
            ' · $diff · 错 $wrong 次');
      }
      b.writeln();
    }
    return b.toString();
  }

  String _readmeMarkdown(int problems, int images) => '''
$kExportMarker
# 如何在 Obsidian 里打开这个题库

这是「考试知识库 Agent」的导出快照：**$problems 道题、$images 张图片**。

## 打开步骤

1. Obsidian → 「打开文件夹作为仓库」→ 选**当前这个文件夹**
2. 打开后从 `题库索引.md` 进去，或直接用文件列表浏览 `problems/`

## 为什么公式能正常显示

题目正文里的公式是标准 `\$...\$` / `\$\$...\$\$` 写法，Obsidian 自带渲染。
**不需要装任何插件。**

> 上面那行里的反斜杠是 Markdown 转义；文件里实际就是普通的美元符号。

## 目录结构

```
problems/     每道题一个 .md（与 App 内部格式完全一致）
images/       题目引用的图片
题库索引.md    按主考点分组的跳转入口
```

## frontmatter 里的 `my_` 字段是什么

那是**你自己在 App 里的状态**，导出时合并进来的：

| 字段 | 含义 |
|---|---|
| `my_wrong_count` | 累计做错次数 |
| `my_mastery` | 掌握度 0–1 |
| `my_next_review` | 下次复习日期 |
| `my_starred` | 是否标记为顽固错题 |
| `my_error_causes` | 错因（受控词表 id） |

⚠️ **这个文件夹是只读快照。** 在这里的修改不会同步回 App，
App 也不会读它。它是给你"把数据带走"用的 —— 想拿它当主库，
App 内部的 `problems/` 目录才是事实源。
''';

  /// 原子写：先写 `.tmp` 再改名，避免导出中途失败留下半个文件。
  static Future<void> _writeAtomic(File file, String content) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    if (file.existsSync()) await file.delete();
    await tmp.rename(file.path);
  }

  /// 与 `ProblemStore._safeFileName` 保持一致的规则。
  static String _safeFileName(String id) {
    final cleaned = id.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
    final safe = cleaned.isEmpty ? 'unnamed' : cleaned;
    // Windows 保留名会让写入直接失败
    const reserved = {
      'CON', 'PRN', 'AUX', 'NUL',
      'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
      'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
    };
    return reserved.contains(safe.toUpperCase()) ? '_$safe' : safe;
  }

  static String _dateOnly(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// 把题干压成一行，供索引页做链接文字。
  ///
  /// ## 为什么必须剥掉 `$`
  ///
  /// Obsidian 的 wiki 链接语法是 `[[目标|显示文字]]`，而 `$...$` 在
  /// **链接文字里也会被当成数学定界符**。实测踩过：
  ///
  /// ```
  /// - [[p-2|求 $\lim_{x\to0}\frac{\sin x}{x}$。]] · 综合 · 错 0 次
  /// ```
  ///
  /// 渲染出来是「求 $\lim {x\to0}\frac{\sin x}{x}$。」—— 反斜杠被当转义
  /// 吃掉、`$` 配对错乱，链接文字直接坏掉。索引页本来就是给用户点的地方，
  /// 第一眼看到的就是这个，所以不能留。
  ///
  /// 顺手也处理 `|` `[` `]`：它们会破坏链接语法本身。
  static String _oneLine(String stem) {
    final t = stem
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(r'$', '') // 数学定界符会吃掉链接文字
        .replaceAll('|', '/')
        .replaceAll('[', '(')
        .replaceAll(']', ')')
        .trim();
    // Obsidian 在文件列表里显示不了太长的标题，48 字够认出题目
    return t.length <= 48 ? t : '${t.substring(0, 48)}…';
  }
}
