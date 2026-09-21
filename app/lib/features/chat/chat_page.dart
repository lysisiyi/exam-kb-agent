/// 对话助手页（F8）。
///
/// ## 这一页要回答的问题
///
/// 其余页面都是"用界面操作题库"。这一页是**用说话来操作**的第一步 ——
/// 目前它只能就数学问题对话，还动不了题库（工具调用是下一期）。
///
/// ## 四条刻意的设计
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
/// ### 4. 能力边界要在界面上也说一遍
///
/// 提示词里写了"你读不到用户的题库"，但**提示词不是保证** ——
/// 模型仍可能顺着用户的话编。所以页面顶部常态显示一行说明，
/// 让用户从一开始就知道这个助手目前能看到什么。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/breakpoints.dart';
import '../../core/math/math_renderer.dart';
import '../../core/providers.dart';
import '../../services/chat/chat_store.dart';
import '../../services/llm/llm_client.dart';
import 'chat_prompt.dart';

/// 对话助手的系统提示，单独放一个文件便于单独改文案。
const String _kSystemPrompt = kChatSystemPrompt;

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

    final client = ref.read(chatClientProvider);
    if (client == null) {
      setState(() => _error = '还没有配置 AI 服务商（或配置不完整）。'
          '请先到「设置」里填好 Key —— 对话需要文本模型。');
      return;
    }

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
            model: client.config.model,
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
          model: client.config.model,
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
      });
      _scrollToEnd();

      await _pump(store, client, sid, turnId, text, history);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '发送失败：$e';
        _streaming = false;
      });
    }

    if (!mounted) return;
    setState(() => _streaming = false);
    await _reloadSessions();
  }

  /// 真正跑一轮流式对话，并边跑边落盘。
  Future<void> _pump(
    ChatStore store,
    LlmClient client,
    String sessionId,
    int turnId,
    String userText,
    List<ChatMessage> history,
  ) async {
    final buffer = StringBuffer();
    var done = false;

    try {
      final stream = client.chatStream(ChatRequest(
        system: _kSystemPrompt,
        user: userText,
        history: history,
        // 比标注(0.1)灵活、比闲聊收敛：数学讲解既要稳、又不能死板
        temperature: 0.3,
      ));

      await for (final event in stream) {
        // 用户按了停止。`break` 会连带取消对底层流的订阅。
        if (_stopRequested) break;

        switch (event) {
          case ChatDelta(:final text):
            buffer.write(text);
            // 落盘交给 ChatStore 自己节流（见它的文件头）。
            // 这里**不 await**：每来一个字都等一次写盘会把流式拖成幻灯片。
            unawaited(store.updateTurn(turnId, content: buffer.toString()));
            if (!mounted) return;
            setState(() => _patchLast(content: buffer.toString()));
            _scrollToEnd();

          case ChatDone(:final response):
            done = true;
            buffer
              ..clear()
              ..write(response.text);
            await store.updateTurn(
              turnId,
              content: response.text,
              interrupted: false,
              usage: response.usage,
              force: true,
            );
            if (!mounted) return;
            setState(() => _patchLast(
                  content: response.text,
                  interrupted: false,
                  usage: response.usage,
                ));
            _scrollToEnd();
        }
      }

      if (!done) {
        // 用户中途停止，或流在结束事件之前就断了。
        // 两种情况盘上都该是"未完成" —— 已经收到的内容留着，
        // 因为那些字用户已经看见了。
        await store.updateTurn(
          turnId,
          content: buffer.toString(),
          interrupted: true,
          force: true,
        );
        if (!mounted) return;
        setState(() {
          _patchLast(content: buffer.toString(), interrupted: true);
          if (_stopRequested) {
            _error = '已停止接收。这一轮的费用已经产生（服务端不会退回），'
                '但内容留在了记录里 —— 接着问就行。';
          }
        });
      }
    } catch (e) {
      // 出错时同样把**已经收到的部分**留住并标记未完成。
      await store.updateTurn(
        turnId,
        content: buffer.toString(),
        interrupted: true,
        force: true,
      );
      if (!mounted) return;
      setState(() {
        _patchLast(content: buffer.toString(), interrupted: true);
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
  void _patchLast({String? content, bool? interrupted, LlmUsage? usage}) {
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

    final chat = Column(
      children: [
        _Header(
          session: _session,
          hasMessages: _messages.isNotEmpty,
          streaming: _streaming,
          onNew: _newChat,
          onShowSessions: wide
              ? null
              : () => _showSessionSheet(context),
        ),
        if (_error != null)
          _ErrorBar(text: _error!, onDismiss: () => setState(() => _error = null)),
        Expanded(
          child: _messages.isEmpty
              ? const _Welcome()
              : _MessageList(
                  messages: _messages,
                  controller: _scroll,
                  streaming: _streaming,
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
  final VoidCallback onNew;
  final VoidCallback? onShowSessions;

  const _Header({
    required this.session,
    required this.hasMessages,
    required this.streaming,
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
                  // 边界要在界面上也说一遍：提示词里写了，但提示词不是保证
                  '能看你贴过来的题；看不到你的题库、错题记录与图谱',
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

  const _MessageList({
    required this.messages,
    required this.controller,
    required this.streaming,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      itemCount: messages.length,
      itemBuilder: (ctx, i) => ChatBubble(
        entry: messages[i],
        // 正在流式的那一条（也就是最后一条助手消息）显示光标
        streaming: streaming &&
            i == messages.length - 1 &&
            messages[i].role == ChatRole.assistant,
      ),
    );
  }
}

/// 一条消息气泡。
///
/// 抽成公开类是为了能单独测 —— 它承载了"未完成"与"思考中"
/// 这两种**必须显示对**的状态。
class ChatBubble extends StatelessWidget {
  final ChatEntry entry;

  /// 这一条正在被流式写入。
  final bool streaming;

  const ChatBubble({super.key, required this.entry, this.streaming = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUser = entry.role == ChatRole.user;

    final body = _body(context, scheme);

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
// 空态与错误条
// ───────────────────────────────────────────────────────────────────────────

class _Welcome extends StatelessWidget {
  const _Welcome();

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
                '可以：\n'
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
