/// 索引构建器：把 `library/problems/*.md` 扫进 SQLite。
///
/// ## 为什么需要"重建索引"
/// Markdown 文件是**事实源**，SQLite 里的索引是**派生数据**。
/// 这带来一个很有用的性质：索引可以随时丢弃重建，不会丢任何内容。
///
/// 用户可能：手工编辑 `.md`、用 Git 拉取别人的题库、从别处拷入文件。
/// 这些操作都不经过 App，所以必须以文件系统为准重新扫描。
///
/// ## 增量策略
/// 按 `problems_index.file_modified_at` 与磁盘 mtime 比较：
/// - mtime 相同 → 跳过（不重新解析，省时间）
/// - mtime 变化或文件是新的 → 重新解析并 upsert
/// - 索引里有但磁盘上已不存在 → 删除索引行（**但保留用户状态**）
///
/// ## 关于用户状态
/// ⚠️ 文件被删除时，`user_problem_state` 与 `review_logs` **不删**。
/// 用户的复习历史是无价数据，不该因为文件移动而消失。
/// 索引行删除后状态成为孤儿，UI 可提示"有 3 条复习记录找不到对应题目"。
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../../domain/knowledge/knowledge_point.dart';
import '../db/database.dart';
import '../markdown/problem_markdown.dart';
import '../markdown/problem_store.dart';

/// 一次重建的结果。
class IndexReport {
  /// 本次扫描到的文件总数。
  final int scannedFiles;

  /// 新解析并入索引的题目数。
  final int added;

  /// 因 mtime 变化而更新的题目数。
  final int updated;

  /// 因 mtime 未变而跳过的题目数。
  final int skipped;

  /// 解析失败的文件数。
  final int failed;

  /// 索引里存在但磁盘上已消失、被清理的条数。
  final int removed;

  /// 失败详情（文件路径 → 原因）。
  final Map<String, String> failures;

  /// 解析成功但需要人工复核的题目数（needsReview）。
  final int needsReview;

  const IndexReport({
    required this.scannedFiles,
    required this.added,
    required this.updated,
    required this.skipped,
    required this.failed,
    required this.removed,
    required this.failures,
    required this.needsReview,
  });

  bool get isClean => failed == 0;

  /// 人类可读摘要。
  String get summary {
    final parts = <String>[
      '扫描 $scannedFiles 个文件',
      if (added > 0) '新增 $added',
      if (updated > 0) '更新 $updated',
      if (skipped > 0) '跳过 $skipped',
      if (removed > 0) '清理 $removed',
      if (failed > 0) '失败 $failed',
      if (needsReview > 0) '待复核 $needsReview',
    ];
    return parts.join(' · ');
  }

  @override
  String toString() => 'IndexReport($summary)';
}

/// 索引构建器。
class IndexBuilder {
  final AppDatabase db;
  final ProblemStore store;

  /// 知识点本体。用于校验题目引用的知识点是否存在，并冗余主考点名称/权重。
  final KnowledgeBase? knowledge;

  const IndexBuilder({
    required this.db,
    required this.store,
    this.knowledge,
  });

  /// 重建索引。
  ///
  /// [force] 为 true 时忽略 mtime，全部重新解析（用于怀疑索引损坏时）。
  Future<IndexReport> rebuild({bool force = false}) async {
    final files = await store.listFiles();

    var added = 0;
    var updated = 0;
    var skipped = 0;
    var failed = 0;
    var needsReview = 0;
    final failures = <String, String>{};

    // 现有索引：文件路径 → (id, mtime)
    final existing = <String, ({String id, DateTime? mtime})>{};
    final rows = await db.select(db.problemsIndex).get();
    for (final r in rows) {
      existing[r.filePath] = (id: r.id, mtime: r.fileModifiedAt);
    }

    final seenPaths = <String>{};

    for (final file in files) {
      // 用相对路径作为稳定键（绝对路径会因机器/用户不同而变化）
      final relPath = _relativePath(file.path);
      seenPaths.add(relPath);

      final mtime = file.statSync().modified;
      final prev = existing[relPath];

      if (!force &&
          prev != null &&
          prev.mtime != null &&
          _sameInstant(prev.mtime!, mtime)) {
        skipped++;
        continue;
      }

      final outcome = await store.readFile(file);
      if (!outcome.isOk) {
        failed++;
        failures[relPath] = outcome.error ?? '未知原因';
        continue;
      }

      final problem = outcome.problem!;
      if (problem.needsReview) needsReview++;

      try {
        await _upsert(problem, relPath, mtime);
        if (prev == null) {
          added++;
        } else {
          updated++;
        }
      } catch (e) {
        failed++;
        failures[relPath] = '写索引失败：$e';
      }
    }

    // 清理磁盘上已不存在的索引行
    var removed = 0;
    final stalePaths = existing.keys.where((p) => !seenPaths.contains(p));
    for (final stalePath in stalePaths.toList()) {
      await _removeByPath(stalePath);
      removed++;
    }

    await db.writeMeta('last_index_at', DateTime.now().toIso8601String());
    await db.writeMeta('last_index_summary', summaryOf(
      added: added, updated: updated, skipped: skipped,
      failed: failed, removed: removed,
    ));

    return IndexReport(
      scannedFiles: files.length,
      added: added,
      updated: updated,
      skipped: skipped,
      failed: failed,
      removed: removed,
      failures: failures,
      needsReview: needsReview,
    );
  }

  /// 清空派生数据后全量重建。
  Future<IndexReport> rebuildFromScratch() async {
    await db.clearDerivedData();
    return rebuild(force: true);
  }

  // ───────────────────────────────────────────────────────────────────────
  // 写入
  // ───────────────────────────────────────────────────────────────────────

  Future<void> _upsert(Problem problem, String relPath, DateTime mtime) async {
    await db.transaction(() async {
      // 先按业务 id 清理旧行（可能路径变了：同一题改了文件名）
      await _removeById(problem.id);
      // 也按路径清理（可能 id 变了：同一文件改了 id）
      await _removeByPath(relPath);

      final primary = problem.primaryKnowledge;
      final meta = knowledge?.primaryMeta(primary?.id);

      await db.into(db.problemsIndex).insert(
            ProblemsIndexCompanion.insert(
              id: problem.id,
              fingerprint: problem.fingerprint,
              subject: problem.subject,
              qtype: problem.qtype.id,
              difficulty: Value(problem.difficulty),
              source: Value(problem.source),
              sourceType: Value(problem.sourceType.id),
              sourceYear: Value(problem.sourceYear),
              filePath: relPath,
              // 只存**题干**，且保留 LaTeX 源码。
              //
              // 早先这里存的是"题干+答案+解析"再 stripMarkdown 的结果，
              // 而 stripMarkdown 会把 `\sin`、`\frac` 整个删掉 ——
              // 列表页拿到的摘要会是「求 x 0 x x」这种残句。
              // FTS5 索引的是 `search_tokens` 而不是本列（见 database.dart 的 DDL），
              // 所以本列不必为检索牺牲可读性。
              stemText: SearchableText.preview(problem.stem, maxLength: 200),
              searchTokens: Value(SearchableText.fromProblem(problem)),
              primaryKpWeight: Value(meta?.weight),
              primaryKpName: Value(meta?.name),
              parseWarnings: Value(
                problem.warnings.isEmpty
                    ? null
                    : jsonEncode(problem.warnings),
              ),
              needsReview: Value(problem.needsReview),
              aiTagged: Value(problem.aiTagged),
              aiConfidence: Value(problem.aiConfidence),
              createdAt: Value(problem.createdAt),
              fileModifiedAt: Value(mtime),
            ),
          );

      for (final ref in problem.knowledge) {
        await db.into(db.problemKnowledge).insert(
              ProblemKnowledgeCompanion.insert(
                problemId: problem.id,
                kpId: ref.id,
                role: Value(ref.role),
                relevance: Value(ref.relevance),
              ),
            );
      }
    });
  }

  /// 删除索引行。**不动用户状态。**
  Future<void> _removeById(String id) async {
    await (db.delete(db.problemKnowledge)
          ..where((t) => t.problemId.equals(id)))
        .go();
    await (db.delete(db.problemsIndex)..where((t) => t.id.equals(id))).go();
  }

  Future<void> _removeByPath(String relPath) async {
    final row = await (db.select(db.problemsIndex)
          ..where((t) => t.filePath.equals(relPath)))
        .getSingleOrNull();
    if (row != null) await _removeById(row.id);
  }

  // ───────────────────────────────────────────────────────────────────────
  // 工具
  // ───────────────────────────────────────────────────────────────────────

  /// 转成相对 `library/` 根的路径，用作跨机器的稳定键。
  String _relativePath(String absolutePath) {
    final root = store.problemsDir.parent.path;
    if (absolutePath.startsWith(root)) {
      var rel = absolutePath.substring(root.length);
      rel = rel.replaceAll('\\', '/');
      if (rel.startsWith('/')) rel = rel.substring(1);
      return rel;
    }
    // 不在预期根下（测试场景）就用文件名
    return p.basename(absolutePath);
  }

  static bool _sameInstant(DateTime a, DateTime b) =>
      a.toUtc().difference(b.toUtc()).inSeconds.abs() < 1;

  /// 剥离 Markdown 标记。转发到 [SearchableText.stripMarkdown] ——
  /// 保留这个方法是为了让索引构建与文本抽取的入口集中在一处，便于调用方使用。
  static String stripMarkdown(String input) =>
      SearchableText.stripMarkdown(input);

  static String summaryOf({
    required int added,
    required int updated,
    required int skipped,
    required int failed,
    required int removed,
  }) =>
      'added=$added updated=$updated skipped=$skipped '
      'failed=$failed removed=$removed';
}

/// 从题目抽取可检索文本。
///
/// ## ⚠️ 中文分词：为什么要做「CJK 逐字加空格」
///
/// FTS5 内置的 `unicode61` 分词器按**空白与标点**切词，这对中文是灾难：
/// 中文句子没有空格，于是 `设函数在闭区间连续` 会变成**一个 token**，
/// 检索"罗尔定理"完全命中不了（实测确认过）。
///
/// 尝试过的替代方案：
/// - `tokenize='trigram'`：可用，但要求**至少 3 个字符**才能匹配，
///   "罗尔""定理"这类两字查询返回 0 条 —— 对中文检索不合格。
/// - 引入 jieba 等外部分词：需要额外原生依赖，V1 不值得。
///
/// 最终方案：**入库前把 CJK 字符之间插入空格**，让 `unicode61` 把每个汉字
/// 当成独立 token，检索时对查询串做同样变换并用**短语查询**保证顺序。
/// 例如：
/// ```
/// 索引：设 f(x) 在闭区间  →  设  f(x)  在 闭 区 间
/// 查询：罗尔定理          →  "罗 尔 定 理"   （短语，保证顺序）
/// ```
/// 实测：1–6 字的中文查询全部命中，`f(x)` 这类 ASCII 内容也正常工作。
///
/// 代价：FTS 表里存的是加空格版本，`snippet()`/`highlight()` 取出的文本
/// 也带空格。本项目暂不用这两个函数（展示走 Markdown 文件），可以接受。
class CjkTokenizer {
  const CjkTokenizer._();

  /// 是否为 CJK 字符（含中日韩标点）。
  static bool _isCjk(int rune) =>
      (rune >= 0x4E00 && rune <= 0x9FFF) || // CJK 统一表意文字
      (rune >= 0x3400 && rune <= 0x4DBF) || // 扩展 A
      (rune >= 0xF900 && rune <= 0xFAFF) || // 兼容表意文字
      (rune >= 0x3000 && rune <= 0x303F) || // CJK 标点（、。「」等）
      (rune >= 0xFF00 && rune <= 0xFFEF);   // 全角字符

  /// 在 CJK 字符两侧插入空格。
  ///
  /// 规则：只要**当前字符或前一个字符**是 CJK，就在中间加一个空格。
  /// 这样非 CJK 的连续段（英文单词、公式、数字）会保持为单个 token。
  static String space(String input) {
    final b = StringBuffer();
    var prevWasCjk = false;
    var first = true;

    for (final rune in input.runes) {
      final cjk = _isCjk(rune);
      if (!first && (cjk || prevWasCjk)) b.write(' ');
      b.writeCharCode(rune);
      prevWasCjk = cjk;
      first = false;
    }
    // 折叠可能产生的连续空格
    return b.toString().replaceAll(RegExp(r' {2,}'), ' ');
  }
}

/// 从题目抽取可检索文本（已做过 CJK 分词处理）。
///
/// 详见 [CjkTokenizer] 的说明 —— 索引与查询**必须用同一套分词规则**，
/// 否则命中不了。
class SearchableText {
  const SearchableText._();

  /// 抽取并分词。
  static String fromProblem(Problem problem) {
    final b = StringBuffer();
    b.writeln(problem.stem);
    if (problem.answer != null) b.writeln(problem.answer);
    if (problem.solution != null) b.writeln(problem.solution);
    if (problem.note != null) b.writeln(problem.note);
    for (final k in problem.knowledge) {
      b.writeln(k.id);
    }
    return CjkTokenizer.space(stripMarkdown(b.toString()));
  }

  /// 剥离 Markdown 标记与 LaTeX 命令。
  ///
  /// ⚠️ 这个函数**只适合做检索分词**，不要拿它生成列表摘要：
  /// 它会把 `\sin`、`\frac`、`\int` 这些命令整个删掉，
  /// 于是一道 `求 $\lim_{x\to0}\frac{\sin x}{x}$` 会退化成「求 x 0 x x」——
  /// 用户完全看不出这是哪道题。摘要请用 [preview]。
  static String stripMarkdown(String input) {
    var s = _stripMarkdownCommon(input);

    // LaTeX 命令（\frac、\int 等）整体去掉，但保留其参数文本
    s = s.replaceAll(RegExp(r'\\[a-zA-Z]+\*?'), ' ');
    // 剩余的 LaTeX 控制符
    s = s.replaceAll(RegExp(r'\\[^a-zA-Z]'), ' ');
    // 花括号、方括号
    s = s.replaceAll(RegExp(r'[{}]'), ' ');
    // 公式定界符也去掉：检索时 `$` 没有意义
    s = s.replaceAll(RegExp(r'\$\$?'), ' ');

    return _collapse(s);
  }

  /// 生成**给人看**的摘要：剥 Markdown，但**保留 LaTeX 源码**。
  ///
  /// 列表页拿到它之后可以直接交给 `MathRenderer.renderMarkdown()`
  /// 渲染出真正的公式，而不是一串被啃掉算符的残句。
  static String preview(String input, {int maxLength = 120}) {
    final s = _collapse(_stripMarkdownCommon(input));
    if (s.length <= maxLength) return s;
    return '${s.substring(0, maxLength)}…';
  }

  /// Markdown 层面的清洗（与 LaTeX 无关），两个入口共用。
  static String _stripMarkdownCommon(String input) {
    var s = input;

    // 代码块与行内代码
    s = s.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
    s = s.replaceAll(RegExp(r'`[^`]*`'), ' ');
    // 图片：保留 alt 文本
    s = s.replaceAllMapped(
      RegExp(r'!\[([^\]]*)\]\([^)]*\)'),
      (m) => ' ${m.group(1) ?? ''} ',
    );
    // 链接：保留文字
    s = s.replaceAllMapped(
      RegExp(r'\[([^\]]*)\]\([^)]*\)'),
      (m) => ' ${m.group(1) ?? ''} ',
    );
    // 标题、列表、引用、强调标记
    s = s.replaceAll(RegExp(r'^\s{0,3}#{1,6}\s+', multiLine: true), ' ');
    s = s.replaceAll(RegExp(r'^\s{0,3}[-*+]\s+', multiLine: true), ' ');
    s = s.replaceAll(RegExp(r'^\s{0,3}>\s?', multiLine: true), ' ');
    s = s.replaceAll(RegExp(r'[*_~]'), ' ');
    // HTML 标签
    s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
    // 控制字符
    s = s.replaceAll(RegExp(r'[\x00-\x1F]'), ' ');

    return s;
  }

  static String _collapse(String s) =>
      s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

// ─────────────────────────────────────────────────────────────────────────────
// 检索
// ─────────────────────────────────────────────────────────────────────────────

/// 一条检索结果。
class SearchHit {
  final String problemId;
  final String stemText;
  final String? source;
  final String? primaryKpName;
  final int difficulty;

  /// FTS5 的 bm25 分数，越小越相关（SQLite 的约定）。
  final double rank;

  const SearchHit({
    required this.problemId,
    required this.stemText,
    this.source,
    this.primaryKpName,
    required this.difficulty,
    required this.rank,
  });
}

/// 基于 FTS5 的全文检索。
class ProblemSearch {
  final AppDatabase db;

  const ProblemSearch(this.db);

  /// 全文检索。
  ///
  /// [query] 会按 FTS5 语法处理。调用 [buildFtsQuery] 可由普通用户输入
  /// 生成安全的查询串（避免用户输入的 `-` `"` 等被当成语法）。
  Future<List<SearchHit>> search(String query, {int limit = 50}) async {
    final fts = buildFtsQuery(query);
    if (fts.isEmpty) return const [];

    final rows = await db.customSelect(
      '''
      SELECT pi.id              AS id,
             pi.stem_text       AS stem_text,
             pi.source          AS source,
             pi.primary_kp_name AS kp_name,
             pi.difficulty      AS difficulty,
             bm25($kFtsTable)   AS rank
      FROM $kFtsTable f
      JOIN problems_index pi ON pi.rowid = f.rowid
      WHERE $kFtsTable MATCH ?
      ORDER BY rank
      LIMIT ?
      ''',
      variables: [
        Variable.withString(fts),
        Variable.withInt(limit),
      ],
      readsFrom: {db.problemsIndex},
    ).get();

    return rows
        .map((r) => SearchHit(
              problemId: r.read<String>('id'),
              stemText: r.read<String>('stem_text'),
              source: r.read<String?>('source'),
              primaryKpName: r.read<String?>('kp_name'),
              difficulty: r.read<int>('difficulty'),
              rank: r.read<double>('rank'),
            ))
        .toList();
  }

  /// 把用户输入转成安全的 FTS5 查询串。
  ///
  /// ## 顺序很关键
  /// **先按用户输入的空格切词，再对每个词做 CJK 分词。**
  ///
  /// 如果反过来（先分词再按空格切），中文会被拆成单字，
  /// `罗尔定理` 会变成 `"罗" AND "尔" AND "定" AND "理"` ——
  /// 虽然能命中，但丢失了短语语义（允许字序错乱、允许跨词匹配）。
  ///
  /// 正确结果：`罗尔定理` → `"罗 尔 定 理"`（一个短语，保证顺序与相邻）。
  ///
  /// 加引号同时也让 `-` `*` `"` `(` 等 FTS 语法字符变得无害。
  ///
  /// 例：
  /// - `罗尔定理`   → `"罗 尔 定 理"`
  /// - `中值 定理`  → `"中 值" AND "定 理"`
  /// - `f(x)`      → `"f(x)"`
  static String buildFtsQuery(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';

    // 1. 先按空白切成"词组"（用户输入的空白即词组边界）
    final phrases = trimmed
        .split(RegExp(r'\s+'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    if (phrases.isEmpty) return '';

    // 2. 每个词组内部做 CJK 逐字分词，使其成为 FTS 的短语
    final quoted = phrases.map((phrase) {
      final tokenized = CjkTokenizer.space(phrase);
      // 双引号在 FTS5 短语里需要写两遍转义
      final escaped = tokenized.replaceAll('"', '""');
      return '"$escaped"';
    });

    return quoted.join(' AND ');
  }
}
