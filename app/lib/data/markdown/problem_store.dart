/// 题目 Markdown 的磁盘读写层。
///
/// ## 核心要求
///
/// 1. **原子写**：文件系统没有事务。直接覆盖原文件时若进程被杀，
///    会留下半截文件（题目丢失）。必须先写临时文件再 `rename` ——
///    同一分区内的 rename 是原子操作。
///
/// 2. **宽容读**：单个文件损坏不能中断批量导入。读取失败要返回错误
///    而不是抛异常穿透到调用方。
///
/// 3. **序列化与解析对称**：`serialize()` 产出的文本再经
///    `ProblemMarkdownParser.parse()` 必须得到等价的 [Problem]。
///    这一点由单元测试保证。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/knowledge/knowledge_point.dart';
import '../knowledge/knowledge_repository.dart' show Subject;
import 'problem_markdown.dart';

/// 一次文件读取的结果。
class ReadOutcome {
  final Problem? problem;
  final String? error;
  final DateTime? modifiedAt;

  const ReadOutcome.ok(this.problem, this.modifiedAt) : error = null;
  const ReadOutcome.failed(this.error)
      : problem = null,
        modifiedAt = null;

  bool get isOk => problem != null;
}

/// 题目仓库：负责 `library/problems/` 目录下的 Markdown 文件。
class ProblemStore {
  final Directory problemsDir;
  final Directory imagesDir;

  const ProblemStore({
    required this.problemsDir,
    required this.imagesDir,
  });

  // ───────────────────────────────────────────────────────────────────────
  // 写
  // ───────────────────────────────────────────────────────────────────────

  /// 原子写入。
  ///
  /// 流程：写 `<name>.tmp` → `flush` → `rename` 覆盖目标。
  /// `rename` 在同一文件系统内是原子的，因此要么看到旧文件、
  /// 要么看到完整的新文件，不会看到半截内容。
  static Future<void> atomicWriteString(File target, String content) async {
    final dir = target.parent;
    if (!dir.existsSync()) await dir.create(recursive: true);

    final tmp = File('${target.path}.tmp');
    // flush: true 确保数据真正落盘后再 rename。
    await tmp.writeAsString(content, flush: true);

    // Windows 上 rename 到已存在的路径会失败，需先删目标。
    // 这不是原子的，但窗口极小（仅删除瞬间），且此时 .tmp 已完整落盘，
    // 即使崩溃也能靠 .tmp 恢复。
    if (target.existsSync()) {
      await target.delete();
    }
    await tmp.rename(target.path);
  }

  /// 原子写入字节（图片等）。
  static Future<void> atomicWriteBytes(File target, List<int> bytes) async {
    final dir = target.parent;
    if (!dir.existsSync()) await dir.create(recursive: true);

    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    if (target.existsSync()) {
      await target.delete();
    }
    await tmp.rename(target.path);
  }

  /// 保存一道题。
  Future<File> save(Problem problem) async {
    final file = fileFor(problem.id);
    final text = ProblemMarkdownSerializer.serialize(problem);
    await atomicWriteString(file, text);
    return file;
  }

  /// 批量保存。
  ///
  /// 逐个原子写。中途失败会抛出，已写入的文件保持有效
  /// （调用方可通过重新索引使数据库与磁盘一致）。
  Future<int> saveAll(Iterable<Problem> problems) async {
    var n = 0;
    for (final problem in problems) {
      await save(problem);
      n++;
    }
    return n;
  }

  // ───────────────────────────────────────────────────────────────────────
  // 读
  // ───────────────────────────────────────────────────────────────────────

  /// 该题对应的文件路径。
  File fileFor(String problemId) =>
      File(p.join(problemsDir.path, '${_safeFileName(problemId)}.md'));

  /// 读取单题。**不抛异常** —— 失败返回 [ReadOutcome.failed]。
  Future<ReadOutcome> read(String problemId) => readFile(fileFor(problemId));

  /// 读取指定文件。
  Future<ReadOutcome> readFile(File file) async {
    try {
      if (!file.existsSync()) {
        return const ReadOutcome.failed('文件不存在');
      }
      // 用同步 stat：索引构建会对成百上千个文件调用本方法，
      // 逐个 await 异步 stat 是明显的性能浪费（avoid_slow_async_io）。
      final stat = file.statSync();
      final text = await file.readAsString(encoding: utf8);

      final fallbackId = p.basenameWithoutExtension(file.path);
      final result = const ProblemMarkdownParser()
          .parse(text, fallbackId: fallbackId);

      if (!result.isOk) {
        return ReadOutcome.failed(result.error ?? '解析失败');
      }
      return ReadOutcome.ok(result.problem, stat.modified);
    } on FileSystemException catch (e) {
      return ReadOutcome.failed('读取失败：${e.message}');
    } on FormatException catch (e) {
      // 非 UTF-8 内容
      return ReadOutcome.failed('编码错误（非 UTF-8？）：${e.message}');
    } catch (e) {
      return ReadOutcome.failed('未知错误：$e');
    }
  }

  /// 列出全部 Markdown 文件（不解析）。
  Future<List<File>> listFiles() async {
    if (!problemsDir.existsSync()) return const [];
    final out = <File>[];
    await for (final entity in problemsDir.list(followLinks: false)) {
      if (entity is File && entity.path.toLowerCase().endsWith('.md')) {
        out.add(entity);
      }
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  /// 删除一道题的文件。
  Future<void> delete(String problemId) async {
    final f = fileFor(problemId);
    if (f.existsSync()) await f.delete();
  }

  /// 保存图片，返回相对路径（用于写进 Markdown）。
  Future<String> saveImage(String problemId, int index, List<int> bytes,
      {String ext = 'png'}) async {
    final name = '${_safeFileName(problemId)}-$index.$ext';
    final file = File(p.join(imagesDir.path, name));
    await atomicWriteBytes(file, bytes);
    return 'images/$name';
  }

  /// 把 id 转成安全的文件名。
  ///
  /// Windows 文件名禁止 `\ / : * ? " < > |` 与控制字符。
  /// id 一般已经规范（如 `2023-shu1-T18`），但导入的数据可能带非法字符。
  static String _safeFileName(String id) {
    var s = id.trim();
    s = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
    s = s.replaceAll(RegExp(r'\s+'), '_');
    if (s.isEmpty) s = 'untitled';
    // Windows 保留名
    const reserved = {
      'CON', 'PRN', 'AUX', 'NUL',
      'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
      'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
    };
    if (reserved.contains(s.toUpperCase())) s = '${s}_';
    // 限制长度（Windows 全路径 260 限制的老问题）
    if (s.length > 120) s = s.substring(0, 120);
    return s;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 序列化
// ─────────────────────────────────────────────────────────────────────────────

/// 把 [Problem] 序列化成 Markdown 文本。
///
/// 与 [ProblemMarkdownParser] 对称：`parse(serialize(p)) ≈ p`。
class ProblemMarkdownSerializer {
  const ProblemMarkdownSerializer._();

  /// 序列化。若 [includeUserState] 非空，会把用户状态以 `my_` 前缀
  /// 追加进 frontmatter（仅用于导出，日常保存不写用户状态）。
  static String serialize(
    Problem problem, {
    Map<String, dynamic>? includeUserState,
  }) {
    final b = StringBuffer();

    b.writeln('---');
    b.writeln('id: ${_yamlScalar(problem.id)}');
    b.writeln('fingerprint: ${_yamlScalar(problem.fingerprint)}');
    b.writeln('subject: ${_yamlScalar(problem.subject)}');
    b.writeln('qtype: ${problem.qtype.id}');
    b.writeln('difficulty: ${problem.difficulty}');

    if (problem.source != null) {
      b.writeln('source: ${_yamlScalar(problem.source!)}');
    }
    b.writeln('source_type: ${problem.sourceType.id}');
    if (problem.sourceYear != null) {
      b.writeln('source_year: ${problem.sourceYear}');
    }

    if (problem.knowledge.isNotEmpty) {
      b.writeln('knowledge:');
      for (final k in problem.knowledge) {
        b.writeln('  - id: ${_yamlScalar(k.id)}');
        b.writeln('    role: ${k.role}');
        b.writeln('    relevance: ${k.relevance}');
      }
    }

    if (problem.errorCauses.isNotEmpty) {
      b.writeln('error_causes: [${problem.errorCauses.join(', ')}]');
    }
    if (problem.options.isNotEmpty) {
      b.writeln('options:');
      for (final o in problem.options) {
        b.writeln('  - ${_yamlScalar(o)}');
      }
    }
    if (problem.images.isNotEmpty) {
      b.writeln('images:');
      for (final i in problem.images) {
        b.writeln('  - ${_yamlScalar(i)}');
      }
    }
    if (problem.tags.isNotEmpty) {
      b.writeln('tags: [${problem.tags.join(', ')}]');
    }

    if (problem.aiTagged) b.writeln('ai_tagged: true');
    if (problem.aiConfidence != null) {
      b.writeln('ai_confidence: ${problem.aiConfidence}');
    }
    if (problem.needsReview) b.writeln('needs_review: true');

    b.writeln('created_at: ${_dateOnly(problem.createdAt ?? DateTime.now())}');

    // 导出时追加用户状态
    if (includeUserState != null) {
      b.writeln('# ↓ 以下为用户状态（导出时合并，日常保存不写入）');
      includeUserState.forEach((k, v) {
        b.writeln('my_$k: ${_yamlValue(v)}');
      });
    }

    b.writeln('---');
    b.writeln();

    b.writeln('## 题干');
    b.writeln();
    b.writeln(problem.stem.trim());
    b.writeln();

    if (problem.answer != null && problem.answer!.trim().isNotEmpty) {
      b.writeln('## 答案');
      b.writeln();
      b.writeln(problem.answer!.trim());
      b.writeln();
    }

    if (problem.solution != null && problem.solution!.trim().isNotEmpty) {
      b.writeln('## 解析');
      b.writeln();
      b.writeln(problem.solution!.trim());
      b.writeln();
    }

    if (problem.note != null && problem.note!.trim().isNotEmpty) {
      b.writeln('## 我的笔记');
      b.writeln();
      b.writeln(problem.note!.trim());
      b.writeln();
    }

    return b.toString();
  }

  static String _dateOnly(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// YAML 标量转义。
  ///
  /// 需要引号的情况：含 `:` `#` `{` `}` `[` `]` `,` `&` `*` `!` `|` `>` `%`
  /// `@` 反引号、首尾空白、或以特殊字符开头。
  /// **LaTeX 内容（如 `$x^2$`）不需要引号**，加了反而会破坏公式显示。
  static String _yamlScalar(String s) {
    if (s.isEmpty) return "''";
    final needsQuote = RegExp(r'''[:#{}\[\],&*!|>%@`"']''').hasMatch(s) ||
        s != s.trim() ||
        RegExp(r'^[-?]').hasMatch(s) ||
        s.contains('\n');
    if (!needsQuote) return s;
    // YAML 单引号字符串：内部的单引号写成两个
    return "'${s.replaceAll("'", "''")}'";
  }

  static String _yamlValue(dynamic v) {
    if (v == null) return 'null';
    if (v is num || v is bool) return '$v';
    if (v is List) return '[${v.map(_yamlValue).join(', ')}]';
    return _yamlScalar(v.toString());
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 便捷构造
// ─────────────────────────────────────────────────────────────────────────────

/// 从知识点本体构造 [ProblemStore] 需要的相对路径前缀检查。
///
/// （保留此函数是为了让校验逻辑集中在一处：知识点 id 必须存在于本体。）
extension KnowledgeValidation on KnowledgeBase {
  /// 校验题目引用的知识点是否都存在。返回不存在的 id 列表。
  List<String> findUnknownKnowledge(Problem problem) {
    final missing = <String>[];
    for (final ref in problem.knowledge) {
      if (!byId.containsKey(ref.id)) missing.add(ref.id);
    }
    return missing;
  }

  /// 从知识点 id 取主考点名称与权重（供索引表冗余存储）。
  ({String? name, double? weight}) primaryMeta(String? kpId) {
    if (kpId == null) return (name: null, weight: null);
    final kp = byId[kpId];
    if (kp == null) return (name: null, weight: null);
    return (name: kp.name, weight: kp.examWeight);
  }
}

/// 题目所属科目枚举的解析（供索引构建用）。
Subject? subjectOf(String subjectId) {
  for (final s in Subject.values) {
    if (s.id == subjectId) return s;
  }
  return null;
}

/// 供测试与本模块内部使用：知识点类型再导出，避免调用方多写一个 import。
typedef KpRef = KnowledgePoint;
