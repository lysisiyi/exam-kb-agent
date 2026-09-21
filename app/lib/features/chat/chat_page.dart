/// 对话助手页（F8）。
///
/// ## 这一页要回答的问题
///
/// 其余页面都是"用界面操作题库"。这一页是**用说话来操作** ——
/// P1 只做到"能聊"（流式 + 多轮 + 落盘），P2 给它接上了**只读工具**：
/// 能查错题本、读某道题的原文、查知识点、查画像、查待复习。
/// **还不能改任何数据**（那是 P3，带确认流程）。
///
/// ## 五条刻意的设计
///
/// ### 1. 流式回复在**开始时就落盘**，而不是写完才存
///
/// 见 `ChatStore` 的文件头说明。一句话：这样进程被杀也留下一条
/// 明确标记为"未完成"的记录，而不是"问过、但记录里什么都没有"。
///
/// ### 2. "停止"要说清它停的是什么
///
/// 用户按停止，客户端只是不再接收 —— **服务端那一次生成还在跑，
/// 钱照花**。所以按钮的说明写的是"停止接收"而不是"取消"，
/// 并明说费用不会退回。说是"取消"会让人以为能止损。
///
/// ### 3. 被中断的回复要显式标注
///
/// 半句话如果正常显示，用户会以为"模型怎么变笨了" ——
/// 而真相是我们把一次中断伪装成了完整回答。
///
/// ### 4. 能力边界在界面上也说一遍
///
/// 提示词里写了"你能查什么、不能改什么"，但**提示词不是保证** ——
/// 模型仍可能顺着用户的话编。所以页面顶部常态显示一行说明，
/// 而且这行字**跟着实际配置变**：服务商不支持工具时说"看不到你的题库"，
/// 支持时说"能读、只读"。
///
/// ### 5. 查过什么要摆出来
///
/// 见 [_TraceStrip]。没有它，"你在中值定理上错得最多"这句话
/// 是真查出来的还是编的，用户一点办法都没有。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/breakpoints.dart';
import '../../core/math/math_renderer.dart';
import '../../core/providers.dart';
import '../../services/chat/chat_agent.dart';
import '../../services/chat/chat_store.dart';
import '../../services/chat/chat_tools.dart';
import '../../services/llm/llm_client.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  /// 当前会话的元信息（标题等）。null 表示"还没开始的新对话"。
  ChatSession? _session;

  /// 界面上的消息。与库里的行一一对应（除了流式中那条 ——
  /// 它也有 id，因为它一开始就落盘了）。
  List<ChatEntry> _messages = const [];

  List<ChatSession> _sessions = const [];
  bool _loadingSessions = true;

  /// 正在接收流式回复。
  bool _streaming = false;

  /// 用户按了停止。收下一个事件时生效。
  bool _stopRequested = false;

  /// 本轮已经用过的工具（正在流式的那条回复的溯源）。
  ///
  /// 与 [ChatEntry.toolTrace] 是同一份数据的两个阶段：这里是最新的，
  /// 落盘后由 [ChatEntry] 持有。之所以还要单独存一份，是因为
  /// [_patchLast] 只改最后一条消息的字段、不做合并 ——
  /// 没有它就没法把"刚查完的工具"接到正在流式的那条上。
  List<ToolTraceItem> _liveTrace = const [];

  /// 正在执行的工具（中文短名）。null 表示此刻没有工具在跑。
  ///
  /// 它驱动"正在查错题本…"这行提示。没有它的话，工具执行的那几秒里
  /// 界面只有一个空的气泡，用户会以为卡住了。
  String? _runningTool;

  String? _error;

  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ───────────────────────────────────────────────────────────────────────
  // 启动
  // ───────────────────────────────────────────────────────────────────────

  Future<void> _bootstrap() async {
    try {
      final store = await ref.read(chatStoreProvider.future);
      final sessions = await store.listSessions();
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _loadingSessions = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingSessions = false;
        _error = '对话记录读不出来：$e';
      });
    }
  }

  Future<void> _reloadSessions() async {
    try {
      final store = await ref.read(chatStoreProvider.future);
      final list = await store.listSessions();
      if (!mounted) return;
      setState(() => _sessions = list);
    } catch (_) {
      // 列表刷新失败不该干扰正在进行的对话
    }
  }

  // ───────────────────────────────────────────────────────────────────────
  // 会话操作
  // ───────────────────────────────────────────────────────────────────────

  /// 新开一段对话。
  ///
  /// **不立刻建会话** —— 那样会在库里留下一串没说过话的空会话。
  /// 真正的建表发生在第一条消息发出去的时候。
  void _newChat() {
    if (_streaming) return;
    setState(() {
      _session = null;
      _messages = const [];
      _error = null;
      _input.clear();
      // 溯源与"正在查"都属于**当前这段对话**的状态，
      // 不清的话新开的对话会顶着上一段的工具记录。
      _liveTrace = const [];
      _runningTool = null;
    });
    _focus.requestFocus();
  }

  Future<void> _openSession(String id) async {
    if (_streaming) return;
    try {
      final store = await ref.read(chatStoreProvider.future);
      final s = await store.load(id);
      if (!mounted || s == null) return;
      setState(() {
        _session = s;
        _messages = s.entries;
        _error = null;
        // 历史消息各自带着自己的溯源，全局那份要清空。
        _liveTrace = const [];
        _runningTool = null;
      });
      _scrollToEnd(animate: false);
    } catch (e) {
      if (mounted) setState(() => _error = '打不开这个会话：$e');
    }
  }

  Future<void> _deleteSession(String id) async {
    try {
      final store = await ref.read(chatStoreProvider.future);
      await store.deleteSession(id);
    } catch (_) {
      // 删不掉就按"盘上还在"重新列一遍
    }
    if (!mounted) return;
    if (_session?.id == id) {
      setState(() {
        _session = null;
        _messages = const [];
      });
    }
    await _reloadSessions();
  }

  // ───────────────────────────────────────────────────────────────────────
  // 发消息
  // ───────────────────────────────────────────────────────────────────────

  /// 把界面上的消息转成要发给模型的历史。
  ///
  /// ⚠️ 跳过没有内容的条目（流式刚开始时那个空气泡就是其中之一）——
  /// 发一条 `{role: assistant, content: ""}` 过去，有些服务商会直接 400。
  static List<ChatMessage> _historyOf(List<ChatEntry> messages) => [
        for (final m in messages)
          if (m.hasContent)
            ChatMessage(role: m.role, content: m.content),
      ];

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _streaming) return;

    // 工具集合与系统提示词都由这个 provider 一并给出 ——
    // 两者必须一致（提示词说"你有工具"而请求里没传，模型会假装查过），
    // 所以在这里一起取，而不是页面各取一半。
    //
    // ⚠️ 分两步赋值是必要的：`agent` 后面会被 `setState` 的闭包捕获，
    // 而"先声明后赋值"的局部变量在 Dart 里**不会**因为一次 null 检查
    // 就提升类型（闭包捕获会取消提升）。落成一个新的 final 才行。
    final ChatAgent? loaded;
    try {
      loaded = await ref.read(chatAgentProvider.future);
    } catch (e) {
      if (mounted) setState(() => _error = '助手初始化失败：$e');
      return;
    }
    if (loaded == null) {
      setState(() => _error = '还没有配置 AI 服务商（或配置不完整）。'
          '请先到「设置」里填好 Key —— 对话需要文本模型。');
      return;
    }
    final agent = loaded;

    final ChatStore store;
    try {
      store = await ref.read(chatStoreProvider.future);
    } catch (e) {
      if (mounted) setState(() => _error = '对话记录打不开：$e');
      return;
    }
    if (!mounted) return;

    // 历史必须在**加入本次用户消息之前**取 —— 否则这条会既在
    // history 里、又作为 user 参数发一次，模型会看到两遍同一句话。
    final history = _historyOf(_messages);

    try {
      final existingId = _session?.id;
      // 建会话时**顺便把标题给上**。否则顶部会一直显示"新对话"，
      // 而用户看到自己说过的话在上面，会以为这段没被记下来。
      final sid = existingId ??
          await store.createSession(
            model: agent.client.config.model,
            title: ChatStore.titleOf(text),
          );

      final now = DateTime.now();
      final userId = await store.appendUserMessage(sid, text);
      final turnId = await store.beginAssistantTurn(sid);

      if (!mounted) return;
      setState(() {
        _session ??= ChatSession(
          id: sid,
          title: ChatStore.titleOf(text),
          model: agent.client.config.model,
          createdAt: now,
          updatedAt: now,
        );
        _messages = [
          ..._messages,
          ChatEntry(
            id: userId,
            role: ChatRole.user,
            content: text,
            createdAt: now,
          ),
          ChatEntry(
            id: turnId,
            role: ChatRole.assistant,
            content: '',
            interrupted: true,
            createdAt: now,
          ),
        ];
        _input.clear();
        _error = null;
        _streaming = true;
        _stopRequested = false;
        // 新一轮从零开始 —— 上一轮的溯源不能跟过来。
        _liveTrace = const [];
        _runningTool = null;
      });
      _scrollToEnd();

      await _pump(store, agent, sid, turnId, text, history);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '发送失败：$e';
        _streaming = false;
      });
    }

    if (!mounted) return;
    setState(() {
      _streaming = false;
      _runningTool = null;
    });
    await _reloadSessions();
  }

  /// 真正跑一轮对话（可能含多次工具往返），并边跑边落盘。
  Future<void> _pump(
    ChatStore store,
    ChatAgent agent,
    String sessionId,
    int turnId,
    String userText,
    List<ChatMessage> history,
  ) async {
    final buffer = StringBuffer();
    var done = false;

    try {
      final stream = agent.run(
        history: history,
        userText: userText,
        shouldStop: () => _stopRequested,
      );

      await for (final event in stream) {
        // 用户按了停止。`break` 会连带取消对底层流的订阅。
        //
        // ⚠️ 但 **[AgentDone] 必须放行**：它带着整轮的最终状态
        // （累计用量、工具溯源、是否被中断）。在它之前 break，
        // 盘上就只剩一条"被中断"的记录、用量也记成 0 ——
        // 而那一轮其实**已经完整跑完了**（钱也花了）。
        // 用户按下停止的那一刻刚好撞上收尾，是很常见的。
        if (_stopRequested && event is! AgentDone) break;

        switch (event) {
          case AgentTextDelta(:final text):
            buffer.write(text);
            // 落盘交给 ChatStore 自己节流（见它的文件头）。
            // 这里**不 await**：每来一个字都等一次写盘会把流式拖成幻灯片。
            unawaited(store.updateTurn(turnId, content: buffer.toString()));
            if (!mounted) return;
            setState(() => _patchLast(content: buffer.toString()));
            _scrollToEnd();

          case AgentToolBegin(:final label):
            if (!mounted) return;
            setState(() => _runningTool = label);
            _scrollToEnd();

          case AgentToolEnd(:final item):
            _liveTrace = [..._liveTrace, item];
            // 工具记录也走节流：一次回答可能查好几次，
            // 每次都强制落盘等于把节流绕过去了。
            unawaited(store.updateTurn(
              turnId,
              content: buffer.toString(),
              toolTrace: _liveTrace,
            ));
            if (!mounted) return;
            setState(() {
              _runningTool = null;
              _patchLast(content: buffer.toString(), toolTrace: _liveTrace);
            });
            _scrollToEnd();

          case AgentDone(
              :final text,
              :final usage,
              :final trace,
              :final stopped,
              :final note
            ):
            done = true;
            buffer
              ..clear()
              ..write(text);
            _liveTrace = trace;
            // ⚠️ 这一次必须 force：整轮的最终状态（正文、用量、溯源、
            // 是否被中断）都在这里定型，漏掉它就会留下"最后一段没存上"。
            await store.updateTurn(
              turnId,
              content: text,
              interrupted: stopped,
              usage: usage,
              toolTrace: trace,
              force: true,
            );
            if (!mounted) return;
            setState(() {
              _runningTool = null;
              _patchLast(
                content: text,
                interrupted: stopped,
                usage: usage,
                toolTrace: trace,
              );
              // 达到轮数上限这类话必须原样转给用户，不能吞掉：
              // 他看到的是一个戛然而止的回答，不说就会以为是模型不行。
              _error = note ??
                  (stopped
                      ? '已停止接收。这一轮的费用已经产生（服务端不会退回），'
                          '但内容留在了记录里 —— 接着问就行。'
                      : null);
            });
            _scrollToEnd();
        }
      }

      if (!done) {
        // 走到这里只有一种情况：底层连接被掐断，收尾事件永远没来
        // （用户按停的那条路会在 AgentDone 里带着 stopped 收尾）。
        await store.updateTurn(
          turnId,
          content: buffer.toString(),
          interrupted: true,
          toolTrace: _liveTrace,
          force: true,
        );
        if (!mounted) return;
        setState(() {
          _runningTool = null;
          _patchLast(
            content: buffer.toString(),
            interrupted: true,
            toolTrace: _liveTrace,
          );
          _error = _stopRequested
              ? '已停止接收。这一轮的费用已经产生（服务端不会退回），'
                  '但内容留在了记录里 —— 接着问就行。'
              : '这一轮没能正常收尾（连接断了）。已经收到的内容留在了记录里。';
        });
      }
    } catch (e) {
      // 出错时同样把**已经收到的部分**留住并标记未完成。
      await store.updateTurn(
        turnId,
        content: buffer.toString(),
        interrupted: true,
        toolTrace: _liveTrace,
        force: true,
      );
      if (!mounted) return;
      setState(() {
        _runningTool = null;
        _patchLast(
          content: buffer.toString(),
          interrupted: true,
          toolTrace: _liveTrace,
        );
        _error = _describeChatError(e);
      });
    } finally {
      _stopRequested = false;
    }
  }

  /// 用户按停止。
  ///
  /// 只是让循环在下一个事件处退出。**不打断服务端那一次生成** ——
  /// 所以文案上别说"已取消"。
  void _stop() {
    if (!_streaming) return;
    setState(() => _stopRequested = true);
  }

  /// 把错误翻成"用户能怎么办"。
  ///
  /// 直接显示 `LlmException.toString()` 会把分类、状态码、
  /// 甚至 rawBody 一起倒出来 —— 那些是给排查用的，不是给用户的。
  static String _describeChatError(Object e) {
    if (e is LlmException) {
      final advice = e.needsUserAction
          ? '（可以去「设置」检查一下）'
          : '';
      return '这一轮没跑完：${e.message}$advice';
    }
    return '这一轮没跑完：$e';
  }

  // ───────────────────────────────────────────────────────────────────────
  // 局部状态更新
  // ───────────────────────────────────────────────────────────────────────

  /// 只改最后一条（流式中的那条回复）。
  void _patchLast({
    String? content,
    bool? interrupted,
    LlmUsage? usage,
    List<ToolTraceItem>? toolTrace,
  }) {
    if (_messages.isEmpty) return;
    final last = _messages.last;
    if (last.role != ChatRole.assistant) return;
    _messages = [
      ..._messages.take(_messages.length - 1),
      ChatEntry(
        id: last.id,
        role: last.role,
        content: content ?? last.content,
        interrupted: interrupted ?? last.interrupted,
        usage: usage ?? last.usage,
        toolTrace: toolTrace ?? last.toolTrace,
        createdAt: last.createdAt,
      ),
    ];
  }

  void _scrollToEnd({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (animate && !_streaming) {
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      } else {
        // 流式时用跳转：每 100ms 排一次动画会互相打架
        _scroll.jumpTo(target);
      }
    });
  }

  // ───────────────────────────────────────────────────────────────────────
  // 构建
  // ───────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final compact = BreakpointScope.of(context) == LayoutBreakpoint.compact;
    final wide = !compact;

    final cfg = ref.watch(llmConfigProvider);
    final agent = ref.watch(chatAgentProvider).valueOrNull;
    final toolsOn = agent != null && agent.tools.isNotEmpty;

    /// 顶部那行能力说明。
    ///
    /// ## 为什么要分三种而不是两种
    ///
    /// "配置好了但工具没就绪"（首次进入、provider 还在 await）如果和
    /// "没配服务商"说成同一句，用户会去设置里瞎改一个本来没问题的 Key。
    /// 而"服务商不支持工具"又完全是另一回事 —— 那种情况**换服务商能解决**，
    /// 得说出来。
    final capability = cfg == null
        ? '还没配置 AI 服务商：到「设置」里填好 Key 就能开始'
        : agent == null
            ? '正在准备助手…'
            : !toolsOn
                ? '${cfg.spec?.label ?? '当前服务商'} 不支持工具调用 —— '
                    '它看不到你的题库，只能回答你贴过来的题（换成 DeepSeek 等可解决）'
                : '能读你的错题本、知识点与画像；只读，不会改动任何数据';

    final chat = Column(
      children: [
        _Header(
          session: _session,
          hasMessages: _messages.isNotEmpty,
          streaming: _streaming,
          capability: capability,
          onNew: _newChat,
          onShowSessions: wide
              ? null
              : () => _showSessionSheet(context),
        ),
        if (_error != null)
          _ErrorBar(text: _error!, onDismiss: () => setState(() => _error = null)),
        Expanded(
          child: _messages.isEmpty
              ? _Welcome(withTools: toolsOn)
              : _MessageList(
                  messages: _messages,
                  controller: _scroll,
                  streaming: _streaming,
                  runningTool: _runningTool,
                ),
        ),
        _Composer(
          controller: _input,
          focus: _focus,
          streaming: _streaming,
          onSubmit: _send,
          onStop: _stop,
        ),
      ],
    );

    if (!wide) return chat;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 248,
          child: _SessionList(
            sessions: _sessions,
            currentId: _session?.id,
            loading: _loadingSessions,
            onPick: _openSession,
            onDelete: _deleteSession,
            onNew: _newChat,
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(child: chat),
      ],
    );
  }

  Future<void> _showSessionSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.6,
          child: _SessionList(
            sessions: _sessions,
            currentId: _session?.id,
            loading: _loadingSessions,
            onPick: (id) {
              Navigator.of(ctx).pop();
              unawaited(_openSession(id));
            },
            onDelete: (id) {
              Navigator.of(ctx).pop();
              unawaited(_deleteSession(id));
            },
            onNew: () {
              Navigator.of(ctx).pop();
              _newChat();
            },
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────────
// 顶部
// ───────────────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final ChatSession? session;
  final bool hasMessages;
  final bool streaming;

  /// 这一行说明"助手现在能看到什么"。由页面按服务商与工具就绪状态算出来。
  final String capability;

  final VoidCallback onNew;
  final VoidCallback? onShowSessions;

  const _Header({
    required this.session,
    required this.hasMessages,
    required this.streaming,
    required this.capability,
    required this.onNew,
    this.onShowSessions,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      child: Row(
        children: [
          if (onShowSessions != null) ...[
            IconButton(
              tooltip: '历史对话',
              onPressed: onShowSessions,
              icon: const Icon(Icons.history),
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  hasMessages ? (session?.displayTitle ?? '新对话') : '对话助手',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  // 能力说明必须在界面上也说一遍：提示词里写了，但
                  // **提示词不是保证** —— 模型仍可能顺着用户的话编。
                  // 让用户从一开始就知道这个助手能看到什么。
                  capability,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: streaming ? null : onNew,
            icon: const Icon(Icons.add_comment_outlined, size: 17),
            label: const Text('新对话'),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────────
// 会话列表
// ───────────────────────────────────────────────────────────────────────────

class _SessionList extends StatelessWidget {
  final List<ChatSession> sessions;
  final String? currentId;
  final bool loading;
  final void Function(String id) onPick;
  final void Function(String id) onDelete;
  final VoidCallback onNew;

  const _SessionList({
    required this.sessions,
    required this.currentId,
    required this.loading,
    required this.onPick,
    required this.onDelete,
    required this.onNew,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Row(
            children: [
              Text(
                '历史对话',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: '新对话',
                onPressed: onNew,
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        if (sessions.isEmpty)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '还没有历史对话。\n发第一条消息就会出现在这里。',
                style: TextStyle(fontSize: 12, height: 1.7, color: scheme.onSurfaceVariant),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 12),
              itemCount: sessions.length,
              itemBuilder: (ctx, i) {
                final s = sessions[i];
                final selected = s.id == currentId;
                return ListTile(
                  dense: true,
                  selected: selected,
                  selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.5),
                  title: Text(
                    s.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    _relativeTime(s.updatedAt),
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                  trailing: IconButton(
                    tooltip: '删除这段对话',
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => onDelete(s.id),
                  ),
                  onTap: () => onPick(s.id),
                );
              },
            ),
          ),
      ],
    );
  }

  /// 相对时间。比绝对时间戳更符合"我刚聊过"的直觉。
  static String _relativeTime(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')}';
  }
}

// ───────────────────────────────────────────────────────────────────────────
// 消息
// ───────────────────────────────────────────────────────────────────────────

class _MessageList extends StatelessWidget {
  final List<ChatEntry> messages;
  final ScrollController controller;
  final bool streaming;

  /// 正在执行的工具（中文短名）。只显示在**最后一条**助手气泡上。
  final String? runningTool;

  const _MessageList({
    required this.messages,
    required this.controller,
    required this.streaming,
    this.runningTool,
  });

  @override
  Widget build(BuildContext context) {
    final lastAssistant =
        messages.isNotEmpty && messages.last.role == ChatRole.assistant;
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      itemCount: messages.length,
      itemBuilder: (ctx, i) {
        final isLast = i == messages.length - 1;
        return ChatBubble(
          entry: messages[i],
          // 正在流式的那一条（也就是最后一条助手消息）显示光标
          streaming: streaming && isLast && messages[i].role == ChatRole.assistant,
          // "正在查…"只挂在最后一条上：工具是**这一轮**在跑的，
          // 把它显示在历史气泡上会让人以为那条回复还在动。
          runningTool: (isLast && lastAssistant) ? runningTool : null,
        );
      },
    );
  }
}

/// 一条消息气泡。
///
/// 抽成公开类是为了能单独测 —— 它承载了"未完成"、"思考中"
/// 与"查过什么"这三种**必须显示对**的状态。
class ChatBubble extends StatelessWidget {
  final ChatEntry entry;

  /// 这一条正在被流式写入。
  final bool streaming;

  /// 此刻正在执行的工具（中文短名）。非空时在气泡顶部显示"正在查…"。
  final String? runningTool;

  const ChatBubble({
    super.key,
    required this.entry,
    this.streaming = false,
    this.runningTool,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUser = entry.role == ChatRole.user;

    final body = _body(context, scheme);
    final showTrace = !isUser &&
        (entry.toolTrace.isNotEmpty || (streaming && runningTool != null));

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 720),
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
        decoration: BoxDecoration(
          color: isUser
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: entry.interrupted && !streaming
              ? Border.all(color: scheme.error.withValues(alpha: 0.5))
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 溯源放在正文**上面**：它是"这句话从哪来"的前情，
            // 放在下面会让长回答的读者永远看不到。
            if (showTrace)
              _TraceStrip(
                trace: entry.toolTrace,
                running: streaming ? runningTool : null,
                scheme: scheme,
              ),
            body,
            if (entry.interrupted && !streaming) ..._interruptedNote(scheme),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, ColorScheme scheme) {
    // 空内容 + 正在流式 = 刚发出、模型还没吐字
    if (!entry.hasContent) {
      return Text(
        streaming ? '正在思考…' : '（这条回复没有内容）',
        style: TextStyle(
          fontSize: 13.5,
          fontStyle: FontStyle.italic,
          color: scheme.onSurfaceVariant,
        ),
      );
    }

    // 用户消息不渲染 Markdown —— 用户打字就是字面意思，
    // 把 `**` 解释成粗体会让他看不懂自己发的是什么。
    if (entry.role == ChatRole.user) {
      return SelectableText(
        entry.content,
        style: const TextStyle(fontSize: 14, height: 1.6),
      );
    }

    return MathRendering.renderer.renderMarkdown(entry.content);
  }

  /// "这条没写完"的标注。
  ///
  /// 不标注的话，半句话看起来就是一句奇怪的话 ——
  /// 用户会怀疑模型，而真相是这条回复被中断了。
  List<Widget> _interruptedNote(ColorScheme scheme) => [
        const SizedBox(height: 8),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 13, color: scheme.error),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                '这条回复被中断了，内容不完整',
                style: TextStyle(fontSize: 11.5, color: scheme.error),
              ),
            ),
          ],
        ),
      ];
}

// ───────────────────────────────────────────────────────────────────────────
// 溯源条
// ───────────────────────────────────────────────────────────────────────────

/// 一条回复"查过什么"。
///
/// ## 为什么必须有这个
///
/// 接上工具之后，助手说的每句与用户数据有关的话都**有可能**是查出来的、
/// 也有可能是编的 —— 而两者在文字上长得一模一样，用户无从分辨。
/// 把"查了什么、查到几条"摆出来，他才有判断的依据。
///
/// 这与项目其余部分是同一条纪律：画像里同时显示掌握度**与**复习题数、
/// 「AI 为什么这么判」面板把召回词摆出来 —— 让结论可核对，而不是
/// 要求用户相信。
class _TraceStrip extends StatelessWidget {
  final List<ToolTraceItem> trace;

  /// 正在执行的工具名。非空时多显示一行"正在查…"。
  final String? running;

  final ColorScheme scheme;

  const _TraceStrip({
    required this.trace,
    required this.running,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      // 与正文之间留一点空，但别太多 —— 它是附注，不是正文的一部分。
      padding: const EdgeInsets.only(bottom: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final t in trace)
            _row(
              t.summary.isEmpty ? t.label : '${t.label} · ${t.summary}',
              ok: t.ok,
            ),
          // 正在查的那一行**排在最后**：它是时间上最新的，
          // 而上面那些是已经有结果的。
          if (running != null) _row('正在查$running…', ok: true, pending: true),
        ],
      ),
    );
  }

  Widget _row(String text, {required bool ok, bool pending = false}) {
    // 失败的那一条用错误色：查询失败与"查到 0 条"是两回事，
    // 后者是我们真的问过了，前者是我们没问到。
    final color = ok ? scheme.onSurfaceVariant : scheme.error;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ok ? Icons.search : Icons.error_outline, size: 12.5, color: color),
          const SizedBox(width: 5),
          // 必须 Flexible：工具摘要可能很长（比如把用户的考点名带进去），
          // 而外层气泡宽度有限，不换行就会溢出成一条黄色警示带。
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: color,
                fontStyle: pending ? FontStyle.italic : FontStyle.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────────
// 空态与错误条
// ───────────────────────────────────────────────────────────────────────────

class _Welcome extends StatelessWidget {
  /// 当前是否真的能查数据。空态文案必须跟着变 ——
  /// 明明能查还写着"它现在读不到你的题库"，用户永远不会去试。
  final bool withTools;

  const _Welcome({required this.withTools});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.forum_outlined, size: 34, color: scheme.onSurfaceVariant),
              const SizedBox(height: 14),
              const Text(
                '有什么想问的？',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              Text(
                withTools
                    ? '可以直接问你的数据：\n'
                        '· "我哪块最弱？" —— 它会查画像\n'
                        '· "我今天该复习什么？" —— 它会查复习计划\n'
                        '· "我在中值定理上有哪些错题？" —— 它会查错题本\n'
                        '· "讲讲我那道 2023-shu1-T18" —— 它会读原文\n\n'
                        '也可以贴一道题过来让它讲思路，或问概念辨析。\n\n'
                        // ⚠️ 这里是纯 Text，不能出现 Markdown 记号 ——
                        // 星号会原样显示出来（A3 那次踩过同一个坑）。
                        '它是只读的，不会改动你的题库；每次回答都会标出'
                        '它查了什么。'
                    : '可以：\n'
                        '· 贴一道题过来，让它讲思路；\n'
                        '· 问概念辨析（比如"洛必达和泰勒什么时候用哪个"）；\n'
                        '· 让它帮你归类型（"这类题的通用套路是什么"）。\n\n'
                        '它现在读不到你的题库 —— 想看自己的薄弱点，去「画像」页。',
                style: TextStyle(fontSize: 13, height: 1.85, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorBar extends StatelessWidget {
  final String text;
  final VoidCallback onDismiss;

  const _ErrorBar({required this.text, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 9, 8, 9),
      color: scheme.errorContainer,
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              text,
              style: TextStyle(fontSize: 12.5, height: 1.5, color: scheme.onErrorContainer),
            ),
          ),
          IconButton(
            tooltip: '知道了',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            onPressed: onDismiss,
            icon: Icon(Icons.close, color: scheme.onErrorContainer),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────────
// 输入区
// ───────────────────────────────────────────────────────────────────────────

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focus;
  final bool streaming;
  final Future<void> Function() onSubmit;
  final VoidCallback onStop;

  const _Composer({
    required this.controller,
    required this.focus,
    required this.streaming,
    required this.onSubmit,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Focus(
              // Enter 发送、Shift+Enter 换行。放在 Focus 上而不是
              // TextField 的 onSubmitted：后者在多行输入框里
              // 拿不到"按下的同时有没有按 Shift"。
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                if (event.logicalKey != LogicalKeyboardKey.enter) {
                  return KeyEventResult.ignored;
                }
                if (HardwareKeyboard.instance.isShiftPressed) {
                  return KeyEventResult.ignored;
                }
                unawaited(onSubmit());
                return KeyEventResult.handled;
              },
              child: TextField(
                controller: controller,
                focusNode: focus,
                enabled: !streaming,
                minLines: 1,
                maxLines: 6,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: streaming ? '正在回复…' : '问一道题，或问一个概念',
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          if (streaming)
            // ⚠️ "停止接收"而不是"取消"：服务端那一次生成还在跑，
            // 费用已经产生且不会退回。说"取消"会让人以为能止损。
            Tooltip(
              message: '停止接收。这一轮的费用已经产生，服务端不会退回。',
              child: IconButton.filledTonal(
                onPressed: onStop,
                icon: const Icon(Icons.stop),
              ),
            )
          else
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (ctx, value, _) => IconButton.filled(
                tooltip: '发送（Enter）',
                onPressed: value.text.trim().isEmpty
                    ? null
                    : () => unawaited(onSubmit()),
                icon: const Icon(Icons.arrow_upward),
              ),
            ),
        ],
      ),
    );
  }
}
