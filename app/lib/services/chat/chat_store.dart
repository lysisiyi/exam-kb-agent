/// 对话记录的读写，以及"边流边存"。
///
/// ## 落盘策略：先插空行、再慢慢填
///
/// 流式回复是逐字产出的，而写盘不能跟着逐字走（一次回复可能有
/// 几百次增量）。这里的做法是：
///
/// 1. **开始时先插一行空内容、`interrupted = true`**；
/// 2. 流式过程中覆盖式更新这一行，**按时间节流**（见 [kChatFlushInterval]）；
/// 3. 正常收尾时把 `interrupted` 改回 false。
///
/// 第 1 步是关键：它让"进程被杀死 / 断电"这种来不及收尾的情况
/// 也会在盘上留下一条**明确的"未完成"记录**。反过来，
/// 若等回复写完才插入，用户在断线后就只能看到"我明明问过，
/// 记录里却没有" —— 而真相是那一刻的答复没能落盘。
///
/// ## 为什么调用方不用自己节流
///
/// [ChatStore.updateTurn] 自己按时间压。调用方每收到一个增量
/// 无脑调一次即可，只在**结束时**传 `force: true` 保证最后一份内容落盘。
library;

import 'dart:math';

import 'package:drift/drift.dart';

import '../../data/db/database.dart';
import '../llm/llm_client.dart';
import 'chat_tools.dart';

/// 流式回复落盘的最小间隔。
///
/// 太快（比如每来一个字都写）会让磁盘写成为瓶颈，而且 SQLite 的 WAL
/// 也会被无谓地撑大；太慢则断线时丢的内容多。400ms 是个折中：
/// 一次 20 秒的回复大约写 50 次，而用户完全感知不到。
const Duration kChatFlushInterval = Duration(milliseconds: 400);

/// 会话标题最多取多少个字。
const int kChatTitleMax = 24;

/// 落盘的一条对话消息。
class ChatEntry {
  final int id;
  final ChatRole role;
  final String content;

  /// 这条回复是否**没写完**（见文件头说明）。
  final bool interrupted;

  /// 这条消息的用量。用户消息恒为 0。
  final LlmUsage usage;

  /// 这条回复**查过什么**（工具调用的摘要）。
  ///
  /// 空列表有两种情况，界面上要区分开 —— 但不必分得很细：
  /// "这一轮没用工具"和"旧版本记录没有这一列"都是空，
  /// 两者在界面上都表现为"不显示溯源那一段"。
  final List<ToolTraceItem> toolTrace;

  final DateTime createdAt;

  const ChatEntry({
    required this.id,
    required this.role,
    required this.content,
    this.interrupted = false,
    this.usage = const LlmUsage(),
    this.toolTrace = const [],
    required this.createdAt,
  });

  bool get isUser => role == ChatRole.user;

  /// 有没有内容可显示。流刚开头的空行属于"占位"，
  /// 界面上要显示成"正在思考"而不是一个空气泡。
  bool get hasContent => content.trim().isNotEmpty;
}

/// 一次对话会话。
class ChatSession {
  final String id;
  final String title;
  final String model;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 会话里的消息，按时间顺序。只由 [ChatStore.load] 填。
  final List<ChatEntry> entries;

  const ChatSession({
    required this.id,
    required this.title,
    this.model = '',
    required this.createdAt,
    required this.updatedAt,
    this.entries = const [],
  });

  int get messageCount => entries.length;

  /// 界面上显示什么标题。空标题（还没发过消息）退化成占位文案，
  /// 而不是留一行空白让人以为出了故障。
  String get displayTitle => title.isEmpty ? '（新对话）' : title;
}

/// 对话记录的读写。
class ChatStore {
  final AppDatabase db;

  /// 取当前时间。注入是为了测试能控制节流的时间轴。
  final DateTime Function() _now;

  final Random _random;

  /// 上次真正写盘的时间，按消息 id 记。
  final Map<int, DateTime> _lastFlush = {};

  ChatStore(this.db, {DateTime Function()? now, Random? random})
      : _now = now ?? DateTime.now,
        _random = random ?? Random();

  // ───────────────────────────────────────────────────────────────────────
  // 会话
  // ───────────────────────────────────────────────────────────────────────

  /// 新建一个会话，返回它的 id。
  Future<String> createSession({String model = '', String title = ''}) async {
    final id = _newId();
    final t = _now();
    await db.into(db.chatSessions).insert(
          ChatSessionsCompanion.insert(
            id: id,
            title: Value(title),
            model: Value(model),
            createdAt: Value(t),
            updatedAt: Value(t),
          ),
        );
    return id;
  }

  /// 列出会话，最近更新的在前。
  ///
  /// **不含消息正文** —— 历史列表只要标题与时间，
  /// 把几十个会话的几百条消息一起读出来纯属白费。
  Future<List<ChatSession>> listSessions({int limit = 100}) async {
    try {
      final rows = await (db.select(db.chatSessions)
            ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
            ..limit(limit))
          .get();
      return rows.map(_sessionOf).toList();
    } catch (_) {
      // 读不出历史不该让整个页面打不开：调用方拿空列表照样能开始新对话
      return const [];
    }
  }

  /// 读一个会话及其全部消息。不存在返回 null。
  Future<ChatSession?> load(String id) async {
    try {
      final row = await (db.select(db.chatSessions)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (row == null) return null;

      final msgs = await (db.select(db.chatMessages)
            ..where((t) => t.sessionId.equals(id))
            // 按自增 id 排，不按时间：同一毫秒内插入的多条消息
            // 用时间排序结果不确定，会让一问一答偶尔对调。
            ..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get();

      return _sessionOf(row, entries: msgs.map(_entryOf).toList());
    } catch (_) {
      return null;
    }
  }

  /// 最近一个会话（用来"打开就接着上次聊"）。
  Future<ChatSession?> latest() async {
    final list = await listSessions(limit: 1);
    if (list.isEmpty) return null;
    return load(list.first.id);
  }

  /// 删掉一个会话及其全部消息。
  ///
  /// 手写级联（先删消息再删会话）：当前 schema 没有外键声明，
  /// 不能指望 ON DELETE CASCADE 帮忙。
  Future<void> deleteSession(String id) async {
    await _clearThrottle();
    try {
      await (db.delete(db.chatMessages)
            ..where((t) => t.sessionId.equals(id)))
          .go();
      await (db.delete(db.chatSessions)..where((t) => t.id.equals(id))).go();
    } catch (_) {
      // 删不掉不该让界面崩：调用方会按"盘上还在"重新列出
    }
  }

  // ───────────────────────────────────────────────────────────────────────
  // 消息
  // ───────────────────────────────────────────────────────────────────────

  /// 追加一条用户消息；若会话还没有标题，就用它生成。
  Future<int> appendUserMessage(String sessionId, String text) async {
    final t = _now();
    final id = await db.into(db.chatMessages).insert(
          ChatMessagesCompanion.insert(
            sessionId: sessionId,
            role: ChatRole.user.name,
            content: text,
            createdAt: Value(t),
          ),
        );
    await _touch(sessionId, titleFrom: text);
    return id;
  }

  /// 开始一条助手回复：先落一行空的、标记为**未完成**。
  ///
  /// 见文件头的说明 —— 这一步是"断电也有痕迹"的保证。
  Future<int> beginAssistantTurn(String sessionId) async {
    final id = await db.into(db.chatMessages).insert(
          ChatMessagesCompanion.insert(
            sessionId: sessionId,
            role: ChatRole.assistant.name,
            content: '',
            interrupted: const Value(true),
            createdAt: Value(_now()),
          ),
        );
    await _touch(sessionId);
    return id;
  }

  /// 覆盖式更新一条回复的正文。
  ///
  /// ⚠️ **流结束时必须传 `force: true`**。没有它，最后一次写入可能
  /// 因为落在节流窗口里被跳过 —— 表现是"回复的最后几十个字没存上"，
  /// 而且只在回复较快时出现。
  ///
  /// [toolTrace] 为 null 表示**不动这一列**（与 `usage` 同一策略）。
  /// 工具往返是逐次发生的，界面上每查一次就可能想更新一次，
  /// 所以它跟正文一样走节流；只有 `force: true` 的那一次一定落盘。
  Future<void> updateTurn(
    int id, {
    required String content,
    bool? interrupted,
    LlmUsage? usage,
    List<ToolTraceItem>? toolTrace,
    bool force = false,
  }) async {
    final t = _now();
    final last = _lastFlush[id];
    if (!force && last != null && t.difference(last) < kChatFlushInterval) {
      return;
    }
    _lastFlush[id] = t;

    try {
      await (db.update(db.chatMessages)..where((x) => x.id.equals(id)))
          .write(ChatMessagesCompanion(
        content: Value(content),
        // 参数列表里**不能**写 `if (...)`（那是集合字面量的语法），
        // 所以"不更新这一列"要用 Value.absent() 表达。
        interrupted:
            interrupted == null ? const Value.absent() : Value(interrupted),
        inputTokens: usage == null ? const Value.absent() : Value(usage.inputTokens),
        outputTokens:
            usage == null ? const Value.absent() : Value(usage.outputTokens),
        costYuan: usage == null ? const Value.absent() : Value(usage.costYuan),
        toolTrace: toolTrace == null
            ? const Value.absent()
            : Value(encodeToolTrace(toolTrace)),
      ));
    } catch (_) {
      // 存不下不该让进行中的对话崩掉。但要把节流记录回退 ——
      // 否则下次会因为"刚写过"继续跳过，一错到底。
      _lastFlush.remove(id);
    }
  }

  // ───────────────────────────────────────────────────────────────────────
  // 内部
  // ───────────────────────────────────────────────────────────────────────

  /// 更新会话的 `updatedAt`；[titleFrom] 非空且当前无标题时顺便起标题。
  Future<void> _touch(String sessionId, {String? titleFrom}) async {
    try {
      final row = await (db.select(db.chatSessions)
            ..where((t) => t.id.equals(sessionId)))
          .getSingleOrNull();
      if (row == null) return;

      final needTitle = row.title.isEmpty && titleFrom != null;
      await (db.update(db.chatSessions)..where((t) => t.id.equals(sessionId)))
          .write(ChatSessionsCompanion(
        updatedAt: Value(_now()),
        title: needTitle ? Value(titleOf(titleFrom)) : const Value.absent(),
      ));
    } catch (_) {
      // 同上：只是个时间戳/标题，失败了不影响消息本身
    }
  }

  Future<void> _clearThrottle() async => _lastFlush.clear();

  /// 用首条用户消息生成标题：压平换行、截断。
  ///
  /// 公开成静态方法便于单独测 —— 标题生成的边界（超长、全是空白、
  /// 带换行）比它看起来的样子更容易出错。
  static String titleOf(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return '';
    if (flat.length <= kChatTitleMax) return flat;
    return '${flat.substring(0, kChatTitleMax)}…';
  }

  /// 生成会话 id。
  ///
  /// 时间戳 + 随机后缀。加随机是因为测试里会注入固定的 `now`，
  /// 只靠时间戳会连续撞 id —— 而撞 id 的表现是"新会话覆盖了旧的"，
  /// 属于会静默丢数据的那一类。
  String _newId() {
    final t = _now().microsecondsSinceEpoch.toRadixString(36);
    final r = _random.nextInt(1 << 20).toRadixString(36).padLeft(4, '0');
    return '$t-$r';
  }

  static ChatSession _sessionOf(ChatSessionRow r,
          {List<ChatEntry> entries = const []}) =>
      ChatSession(
        id: r.id,
        title: r.title,
        model: r.model,
        createdAt: r.createdAt,
        updatedAt: r.updatedAt,
        entries: entries,
      );

  static ChatEntry _entryOf(ChatMessageRow r) => ChatEntry(
        id: r.id,
        role: ChatRole.parseStored(r.role),
        content: r.content,
        interrupted: r.interrupted,
        toolTrace: decodeToolTrace(r.toolTrace),
        createdAt: r.createdAt,
        usage: LlmUsage(
          inputTokens: r.inputTokens,
          outputTokens: r.outputTokens,
          model: '',
          costYuan: r.costYuan,
        ),
      );
}
