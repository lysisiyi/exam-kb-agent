/// 对话助手的**工具循环**：模型要工具 → 本地执行 → 回灌 → 再问。
///
/// ## 为什么单独一层，而不是写在页面里
///
/// 这个循环有三件事只有它能做对，而它们**都不该和界面状态混在一起**：
///
/// 1. **消息序列的完整性**。OpenAI 要求 `assistant` 声明的每一个
///    `tool_call` 都必须有对应的 `tool` 结果消息，否则下一次请求直接 400。
///    "用户按了停止，那一半工具还执行吗"这类问题在这里回答一次就够了。
/// 2. **轮数上限**。模型可能反复查同一件事。没有上限就是无限循环，
///    而每一次循环都在花钱。
/// 3. **用量累加**。一轮回答可能包含 3 次付费调用，用户看到的却是一条回复。
///    累加口径错了，界面上的"这次花了多少"就是错的。
///
/// 页面只负责把事件画出来。这样上面三件事可以脱离 widget 测试。
///
/// ## 停止的语义（与 P1 一致）
///
/// [run] 的 `shouldStop` 为真时**只是不再往下走**：当前这一轮已经产生的
/// 费用不会退回，服务端那一次生成还在跑。所以文案上不写"已取消"。
library;

import '../llm/llm_client.dart';
import 'chat_tools.dart';

/// 工具循环过程中发出的事件。
sealed class AgentEvent {
  const AgentEvent();
}

/// 正文增量。可能来自任意一轮 —— 中间轮次也可能有正文
/// （模型常常先写一句"我看一下你的错题本"再去调工具）。
class AgentTextDelta extends AgentEvent {
  final String text;
  const AgentTextDelta(this.text);
}

/// 模型要调用某个工具。界面据此显示"正在查错题本…"。
class AgentToolBegin extends AgentEvent {
  final String name;
  final String argsPreview;
  final int round;

  const AgentToolBegin({
    required this.name,
    this.argsPreview = '',
    this.round = 1,
  });

  String get label => toolLabel(name);
}

/// 一个工具执行完了。
class AgentToolEnd extends AgentEvent {
  final ToolTraceItem item;
  const AgentToolEnd(this.item);
}

/// 整轮结束（正常收尾、用户停止、达到轮数上限、或**摆出了一张确认卡片**）。
class AgentDone extends AgentEvent {
  /// 全部轮次正文拼起来的最终回答。
  final String text;

  /// **所有轮次累计**的用量。一轮回答可能含多次付费调用。
  final LlmUsage usage;

  final List<ToolTraceItem> trace;

  /// 实际调用了几次模型（含最终那一次）。
  final int rounds;

  /// 用户按了停止，或流在收尾前断了。
  final bool stopped;

  /// 这一轮以"摆出确认卡片"结束 —— 改动**还没发生**，等用户点。
  ///
  /// 它和 [stopped] 是两回事：这里模型完全没有出错，只是按设计停下来了。
  /// 界面上要提醒用户"还等你点一下"，否则他会以为那件事已经做完了。
  final bool awaitingConfirmation;

  /// 需要**原样告诉用户**的一句话。null 表示没什么要额外说的。
  ///
  /// 达到轮数上限这类情况必须说：用户看到的是一个"没头没尾的答案"，
  /// 不说的话他会以为模型就这水平。
  final String? note;

  const AgentDone({
    required this.text,
    this.usage = const LlmUsage(),
    this.trace = const [],
    this.rounds = 1,
    this.stopped = false,
    this.awaitingConfirmation = false,
    this.note,
  });
}

/// 跑工具循环。
class ChatAgent {
  final LlmClient client;
  final ChatToolRegistry tools;
  final String system;

  /// 温度。比标注(0.1)灵活、比闲聊收敛：数学讲解既要稳、又不能死板。
  final double temperature;

  /// 最多调用几次模型（含最终收尾那一次）。
  ///
  /// 它是**总闸**，不是"最多查几次"：模型可能"查一次→再查一次→再查一次"
  /// 一直不停，每一次都在花钱。给一个硬上界，超了就停下来说清楚。
  final int maxRounds;

  const ChatAgent({
    required this.client,
    required this.tools,
    required this.system,
    this.temperature = 0.3,
    this.maxRounds = 6,
  });

  /// 跑完一整轮用户提问。
  ///
  /// [history] 是**这次提问之前**的对话（不含本条）。本轮内部的工具往返
  /// 由这里自己维护，不会写回 [history] —— 工具往返的正文很大，
  /// 下一轮对话用不着它们（模型看得到自己写的结论），
  /// 而重放一次要多花一次的钱。
  Stream<AgentEvent> run({
    required List<ChatMessage> history,
    required String userText,
    bool Function()? shouldStop,
  }) async* {
    // 本轮的工作副本。工具往返会往里加消息，但只在本轮有效。
    final live = <ChatMessage>[...history, ChatMessage.user(userText)];
    final trace = <ToolTraceItem>[];
    final full = StringBuffer();
    LlmUsage? total;
    var rounds = 0;
    var stopped = false;
    var awaiting = false;
    String? note;

    bool stop() => shouldStop?.call() ?? false;

    while (true) {
      if (stop()) {
        stopped = true;
        break;
      }
      if (rounds >= maxRounds) {
        // 到顶了就如实说。不说的结果是用户拿到一个戛然而止的回答，
        // 而他会以为那是模型的能力问题。
        note = '我查得有点多了（已经问了 $rounds 次还没收尾），先停在这里。'
            '可以换个更具体的问法，比如指定某个考点或某类题。';
        break;
      }
      rounds++;

      // 多轮之间插一个空行。模型常常"先说一句 → 查 → 再说结论"，
      // 两段正文直接粘起来会读成一句话。
      if (full.isNotEmpty) {
        full.write('\n\n');
        yield const AgentTextDelta('\n\n');
      }

      ChatResponse? ended;
      final stream = client.chatStream(ChatRequest(
        system: system,
        // 显式 messages 这条路不读 user，但它是必填参数 —— 给空串。
        user: '',
        messages: live,
        temperature: temperature,
        tools: tools.specs,
      ));

      await for (final ev in stream) {
        if (stop()) {
          stopped = true;
          break;
        }
        switch (ev) {
          case ChatDelta(:final text):
            full.write(text);
            yield AgentTextDelta(text);
          case ChatDone(:final response):
            ended = response;
        }
      }

      // 流没走到收尾就中断了（用户按停，或连接被掐断）。
      if (ended == null) {
        stopped = true;
        break;
      }

      total = total == null ? ended.usage : _sum(total, ended.usage);

      if (!ended.wantsTools) break;

      // ⚠️ 必须把这些消息**加进 live**，哪怕下面马上要停下来：
      // assistant 里声明的每个 tool_call 都要有对应的 tool 结果消息，
      // 缺一条下一次请求就是非法的。
      live.add(ChatMessage.assistant(ended.text, toolCalls: ended.toolCalls));

      // 这一轮里有没有出现"待确认的改动"。有的话这一轮到此为止，
      // 见下面 break 处的说明。
      var proposed = false;

      for (final call in ended.toolCalls) {
        if (stop()) {
          stopped = true;
          break;
        }
        final preview = _argsPreview(call);
        yield AgentToolBegin(
          name: call.name,
          argsPreview: preview,
          round: rounds,
        );

        final outcome = await tools.invoke(call);
        final item = ToolTraceItem(
          name: call.name,
          argsPreview: preview,
          ok: outcome.ok,
          summary: outcome.summary,
          round: rounds,
          // 写工具返回的是"提议"，不是结果。它要原样带到界面上 ——
          // 用户看到的那张确认卡片就是从这里来的。
          proposal: outcome.proposal,
        );
        trace.add(item);
        yield AgentToolEnd(item);
        if (item.isProposal) proposed = true;

        // 无论成败都要回灌：失败也是一种结果（"这个查询跑不通"），
        // 让模型自己决定是换个方式再查，还是如实告诉用户"我查不到"。
        // 悄悄吞掉失败会让它以为查到了 0 条，然后说"你没有这方面的错题" ——
        // 那是一句**看起来很确定**的假话。
        // ⚠️ 失败要带上标记（Anthropic 的 is_error 会用它）：带着标记，
        // 模型把它当"一次失败的尝试"来解释；不带，它可能把报错文本
        // 当成查询结果继续编。
        live.add(
          ChatMessage.tool(
            toolCallId: call.id,
            content: outcome.content,
            toolError: !outcome.ok,
          ),
        );
      }

      if (stopped) break;

      // ⚠️ 摆出确认卡片之后**必须停下**，不能把结果回问给模型。
      //
      // 因为此刻改动**还没有发生**：用户可能点取消，也可能放着不管。
      // 再问一次模型，它只会拿到一句"等用户确认"，而它能说出口的
      // 只有两种话 —— "已经帮你改好了"（假话）或者重复一遍刚才的话
      // （白花一次钱）。停下来让用户去点，是这里唯一诚实的收尾。
      if (proposed) {
        awaiting = true;
        break;
      }
    }

    yield AgentDone(
      text: full.toString(),
      usage: total ?? const LlmUsage(),
      trace: trace,
      rounds: rounds,
      stopped: stopped,
      awaitingConfirmation: awaiting,
      note: note,
    );
  }

  /// 累加两次调用的用量。
  ///
  /// ## 与 `LlmUsage.operator +` 的区别：**费用未知不退化 0**
  ///
  /// 那个 `+` 把 `null + null` 算成 0 —— 对单次调用无所谓，
  /// 但一轮回答有 3 次调用、其中 2 次拿不到价目表时，累加会得到
  /// "这次花了 0 元"。用户照着一个假数字做决定，比看到"未知"更糟。
  /// 所以这里的口径是：**任何一次的费用未知，总额就是未知**。
  static LlmUsage _sum(LlmUsage a, LlmUsage b) => LlmUsage(
        inputTokens: a.inputTokens + b.inputTokens,
        outputTokens: a.outputTokens + b.outputTokens,
        model: b.model.isNotEmpty ? b.model : a.model,
        costYuan: (a.costYuan == null || b.costYuan == null)
            ? null
            : a.costYuan! + b.costYuan!,
      );

  /// 参数的紧凑预览，给界面看。
  ///
  /// 不用 `jsonEncode`：那会带上引号与花括号（`{"kp":"中值定理"}`），
  /// 窄一点的界面上放不下几个字。`kp=中值定理, limit=5` 更好读，
  /// 而且它**只用于显示** —— 真正发给工具的是原始参数。
  static String _argsPreview(ToolCall call) {
    if (!call.isParsed) {
      // 参数不是合法 JSON 时如实显示原文片段：那是排查的唯一线索。
      return '参数异常：${_clip(call.arguments, 40)}';
    }
    final args = call.args;
    if (args.isEmpty) return '';
    final parts = <String>[];
    for (final e in args.entries) {
      parts.add('${e.key}=${_clip(e.value?.toString() ?? 'null', 24)}');
    }
    return _clip(parts.join(', '), 60);
  }

  static String _clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}
