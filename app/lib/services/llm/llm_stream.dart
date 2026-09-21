/// SSE（Server-Sent Events）文本解析。
///
/// ## 为什么单独一个文件
///
/// 这是**纯字符串逻辑**：不含网络、不认识 OpenAI 也不认识 Anthropic，
/// 更不知道"消息"是什么。它只做一件事 —— 把陆续到达的文本块
/// 切成一条条 `data:` 载荷。
///
/// 正因为它是纯的，那些最容易出错的地方（半行留在缓冲里、CRLF、
/// 心跳注释、一个中文字符被切成两半）才能在一个纯 Dart 测试里穷举，
/// 而不必发一次真请求、不必花 token。
///
/// ## 它故意只做"按行"而不是"按事件"
///
/// 完整的 SSE 规范里，一个事件可以由**多行 `data:`** 组成，用 `\n` 连接。
/// 但那在 LLM 服务商里几乎不存在 —— OpenAI / DeepSeek / 通义 / 智谱 /
/// Moonshot / Anthropic / Gemini 的流式接口都是
/// **一行 data = 一个 JSON 事件**。
///
/// 所以这里按行返回载荷，不做多行合并。这是**有意为之的简化**，
/// 而不是漏了：真要做多行合并，就得等空行才能确定事件结束，
/// 于是每一条消息都会**延迟一个事件**才吐出来 —— 打字机效果会肉眼可见地卡。
/// 若将来真遇到多行 data 的服务商，在这里加合并即可，调用方不用改。
library;

/// 增量式 SSE 解析器。
///
/// 用法：收到一段文本就 [feed] 一次，拿回其中**已经完整**的 data 载荷。
/// 没凑成整行的部分留在内部缓冲里，等下一段。
///
/// ```dart
/// final parser = SseParser();
/// parser.feed('data: {"a"');   // → []          半行，留着
/// parser.feed(':1}\n\n');      // → ['{"a":1}']  这次凑齐了
/// ```
class SseParser {
  /// 还没凑成整行的尾部。
  String _pending = '';

  /// 喂一段新到的文本，返回其中已经完整的 `data:` 载荷。
  ///
  /// 顺序与到达顺序一致。载荷两边空白都已去掉。
  List<String> feed(String chunk) {
    if (chunk.isEmpty) return const [];

    _pending += chunk;
    final out = <String>[];

    while (true) {
      final idx = _pending.indexOf('\n');
      if (idx < 0) break;

      final line = _pending.substring(0, idx);
      _pending = _pending.substring(idx + 1);

      final payload = _payloadOf(line);
      if (payload != null) out.add(payload);
    }

    return out;
  }

  /// 冲刷缓冲区。
  ///
  /// 流正常结束时缓冲区**应该是空的**（最后一个事件后面会有空行）。
  /// 若不为空，说明服务商没发结尾的换行 —— 这时如果那半行看着是
  /// 完整载荷，就把它交出来，否则丢掉。
  ///
  /// ## 为什么值得单独写这一条
  ///
  /// 丢了这最后一行，用户看到的就是**回复的最后一句莫名缺了**，
  /// 而且只在某些服务商上出现 —— 那种问题极难归因。
  List<String> flush() {
    final tail = _pending;
    _pending = '';
    if (tail.isEmpty) return const [];
    final payload = _payloadOf(tail);
    return payload == null ? const [] : [payload];
  }

  /// 一行 → data 载荷。返回 null 表示这行不是数据行。
  static String? _payloadOf(String line) {
    // SSE 允许 CRLF 行尾。`trimRight` 顺带把孤立的 `\r` 处理掉。
    final t = line.trimRight();
    if (t.isEmpty) return null; // 事件分隔用的空行
    // 以 `:` 开头是注释。部分服务商用它在长时间思考时保活连接 ——
    // 把它当数据会解析出一堆噪声并中断流。
    if (t.startsWith(':')) return null;
    if (!t.startsWith('data:')) return null; // event: / id: / retry: 一律忽略
    // `data:` 之后按规范可以有**一个**空格，也可能直接接内容
    return t.substring(5).trimLeft();
  }
}
