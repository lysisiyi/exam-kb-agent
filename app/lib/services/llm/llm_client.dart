/// LLM 客户端：多服务商调用、重试退避、错误分类、用量计量。
///
/// ## 关键设计：HTTP 层可注入
/// 构造函数接受一个 [HttpAdapter]。生产用 Dio 实现，测试用可控的假实现。
/// 这样**重试逻辑、错误分类、响应解析、用量计算全都可以离线测试** ——
/// 不需要网络、不花 token、结果可复现。
///
/// ## 错误分类为什么重要
/// "调用失败"对用户毫无帮助。必须区分：
/// - API Key 无效 → 让用户去检查 Key
/// - 余额不足 → 让用户去充值
/// - 频率限制 → 自动退避重试（用户什么都不用做）
/// - 模型不存在 → 让用户换模型
/// - 网络不通 → 提示可能需要代理
///
/// 分类错误会导致用户在一个"看起来坏了"的界面前干等或乱改配置。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'llm_stream.dart';
import 'provider_registry.dart';

// ─────────────────────────────────────────────────────────────────────────────
// HTTP 抽象
// ─────────────────────────────────────────────────────────────────────────────

/// 一次 HTTP 请求。
class HttpRequest {
  final String url;
  final String method;
  final Map<String, String> headers;
  final String? body;
  final Duration timeout;

  const HttpRequest({
    required this.url,
    this.method = 'POST',
    this.headers = const {},
    this.body,
    this.timeout = const Duration(seconds: 120),
  });
}

/// 一次 HTTP 响应。
class HttpResponse {
  final int statusCode;
  final String body;

  const HttpResponse({required this.statusCode, required this.body});

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// 尝试解析成 JSON。
  Object? get json {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }
}

/// 流式响应的一块。
///
/// 刻意**不带 SSE 语义** —— 适配器只负责"把响应体按到达顺序吐出来"，
/// 切分事件、认 `data:` 前缀、处理半行缓冲都是纯逻辑，
/// 放在 [LlmClient] 里（见 `llm_stream.dart` 的 `SseParser`）。
/// ⇒ 那些边界条件能在纯 Dart 测试里被完整覆盖，不必起网络、不花 token。
class HttpStreamChunk {
  /// HTTP 状态码。**只在第一块里有意义**（状态行在首字节就已确定）。
  final int statusCode;

  /// 本次新到的原始文本。
  ///
  /// ⚠️ 它**不保证是完整的一行**，也不保证是完整的字符 ——
  /// 切块边界可能落在 `\n` 中间，甚至落在某个中文字符的三个字节中间。
  /// 消费方必须自己缓冲（[LlmClient] 用的是 `SseParser` + 流式 UTF-8 解码）。
  final String text;

  const HttpStreamChunk({required this.statusCode, required this.text});

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

/// HTTP 适配器。生产用 Dio，测试用假实现。
abstract class HttpAdapter {
  Future<HttpResponse> send(HttpRequest request);

  /// 流式发送，返回响应体文本块流。
  ///
  /// ## 为什么这里有默认实现（以及为什么子类必须 `extends`）
  ///
  /// 绝大多数调用**根本不需要流式** —— 批量导入、标注、组题都是
  /// "发完等一个 JSON"。把 [sendStream] 做成抽象方法，等于逼着
  /// 每一个实现者（测试里有 5 个假适配器）写一个自己用不到的桩。
  ///
  /// ⚠️ 但 Dart 的 `implements` **不继承默认实现**，只有 `extends` 才继承。
  /// 所以需要流式的实现者要 `extends HttpAdapter`；
  /// 写成 `implements HttpAdapter` 的话，编译器会要求你实现
  /// [sendStream]，而这不是"多写一行"的问题 —— 是接口约定容易被误解的地方。
  ///
  /// ⚠️ 返回**已失败的流**而不是同步 `throw`：Dart 的 `await for` 与
  /// `Stream.listen` 都按异步错误处理，写成同步抛出会让异常从
  /// "收集流的表达式"里冒出来，而不是从循环体里 ——
  /// `try` 的覆盖范围会变得难以预期。
  Stream<HttpStreamChunk> sendStream(HttpRequest request) => Stream.error(
        UnsupportedError('这个适配器不支持流式响应'),
      );
}

/// 网络层异常（连接失败、超时等），与 HTTP 状态码错误区分。
class HttpTransportException implements Exception {
  final String message;
  final Object? cause;
  const HttpTransportException(this.message, [this.cause]);
  @override
  String toString() => 'HttpTransportException: $message';
}

// ─────────────────────────────────────────────────────────────────────────────
// 错误分类
// ─────────────────────────────────────────────────────────────────────────────

/// 调用失败的原因类别。
enum LlmErrorKind {
  /// API Key 无效或未授权。
  invalidKey,

  /// 余额/配额不足。
  insufficientBalance,

  /// 触发频率限制（可重试）。
  rateLimited,

  /// 模型不存在或不可用。
  modelNotFound,

  /// 请求体不合法（通常是我们的 bug）。
  badRequest,

  /// 服务端错误（5xx，可重试）。
  serverError,

  /// 网络不可达（可能需要代理）。
  network,

  /// 超时。
  timeout,

  /// 返回内容无法解析。
  badResponse,

  /// 未知。
  unknown;

  /// 是否值得重试。
  bool get isRetryable => switch (this) {
        LlmErrorKind.rateLimited ||
        LlmErrorKind.serverError ||
        LlmErrorKind.network ||
        LlmErrorKind.timeout =>
          true,
        _ => false,
      };

  /// 给用户看的处理建议。
  String get advice => switch (this) {
        LlmErrorKind.invalidKey => 'API Key 无效或已过期，请到服务商后台重新生成后填写',
        LlmErrorKind.insufficientBalance => '账户余额或免费额度不足，请到服务商后台充值',
        LlmErrorKind.rateLimited => '请求过于频繁，系统会自动退避重试；若持续失败可换模型',
        LlmErrorKind.modelNotFound => '该模型不可用，请在设置里换一个模型',
        LlmErrorKind.badRequest => '请求格式有误（可能是软件缺陷，请反馈）',
        LlmErrorKind.serverError => '服务商暂时故障，稍后重试',
        LlmErrorKind.network => '无法连接该服务。国内使用 OpenAI / Claude / Gemini 通常需要代理',
        LlmErrorKind.timeout => '请求超时，可能是网络慢或题目过长',
        // ⚠️ 不要说"已记入待人工确认" —— 这条路径上**什么都没记**。
        // 标注失败时 `KnowledgeTagger` 返回的是 failure，既没写 Markdown，
        // 也没往 `needs_review` 或任何队列里放东西。
        // 承诺一个不存在的队列，用户就会一直等一个永远不会出现的复核入口。
        LlmErrorKind.badResponse => '模型返回的内容无法解析，请再点一次重试；若反复失败可换模型',
        LlmErrorKind.unknown => '未知错误',
      };
}

/// LLM 调用异常，带分类与是否为配置问题。
class LlmException implements Exception {
  final LlmErrorKind kind;
  final String message;
  final int? statusCode;
  final String? rawBody;

  const LlmException(
    this.kind,
    this.message, {
    this.statusCode,
    this.rawBody,
  });

  /// 是否为"用户需要改配置"的问题（而非临时故障）。
  ///
  /// UI 可据此决定是弹"去设置"按钮，还是显示"重试"。
  bool get needsUserAction =>
      kind == LlmErrorKind.invalidKey ||
      kind == LlmErrorKind.insufficientBalance ||
      kind == LlmErrorKind.modelNotFound ||
      kind == LlmErrorKind.network;

  @override
  String toString() => 'LlmException(${kind.name}, status=$statusCode): '
      '$message\n建议：${kind.advice}';
}

// ─────────────────────────────────────────────────────────────────────────────
// 用量与计费
// ─────────────────────────────────────────────────────────────────────────────

/// 一次调用的 token 用量与费用估算。
class LlmUsage {
  final int inputTokens;
  final int outputTokens;
  final String model;

  /// 费用估算（人民币元）。null 表示该模型不在价目表里。
  final double? costYuan;

  /// 是否命中本地缓存（未真正调用 API，费用为 0）。
  final bool fromCache;

  const LlmUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.model = '',
    this.costYuan,
    this.fromCache = false,
  });

  static const LlmUsage cached = LlmUsage(fromCache: true);

  int get totalTokens => inputTokens + outputTokens;

  LlmUsage operator +(LlmUsage other) => LlmUsage(
        inputTokens: inputTokens + other.inputTokens,
        outputTokens: outputTokens + other.outputTokens,
        model: other.model.isNotEmpty ? other.model : model,
        costYuan: (costYuan ?? 0) + (other.costYuan ?? 0),
        fromCache: false,
      );

  /// 序列化。唯一的消费者是批量导入草稿（T49）——
  /// 中继续跑时要能把"这批已经花了多少"一起带回来，
  /// 否则用户会觉得钱花得不明不白。
  Map<String, dynamic> toJson() => {
        'input': inputTokens,
        'output': outputTokens,
        if (model.isNotEmpty) 'model': model,
        if (costYuan != null) 'cost': costYuan,
        if (fromCache) 'cached': true,
      };

  /// 反序列化。字段缺失一律退化为 0，不抛异常 ——
  /// 草稿是"未完成的工作"，读坏它不该拦住用户。
  factory LlmUsage.fromJson(Map<String, dynamic> j) => LlmUsage(
        inputTokens: (j['input'] as num?)?.toInt() ?? 0,
        outputTokens: (j['output'] as num?)?.toInt() ?? 0,
        model: j['model']?.toString() ?? '',
        costYuan: (j['cost'] as num?)?.toDouble(),
        fromCache: j['cached'] == true,
      );
}

/// 粗略的价目表（元 / 百万 token），用于给用户**估算**花费。
///
/// ⚠️ 价格会变，且各服务商常有折扣/阶梯。这里只是量级参考，
/// UI 上必须标注"估算"。**不要**用它做任何计费决策。
abstract final class LlmPricing {
  const LlmPricing._();

  /// 模型名（小写包含匹配）→ (输入价, 输出价)，单位：元/百万 token。
  ///
  /// ## 维护约定
  ///
  /// - **只放查得到的价**。查不到就让 [estimate] 返回 null、界面显示"未知" ——
  ///   编一个数字出来比"未知"更糟：用户会照着一个假价格决定要不要花这笔钱。
  /// - 每条注明**来源**；价格变了先改这里，再改下面的核对日期。
  /// - ⚠️ 匹配是**子串**匹配、取第一个命中的条目，所以**长名字要排在前面**：
  ///   `glm-4.6v-flashx` 必须排在 `glm-4.6v-flash` 与 `glm-4.6v` 之前，
  ///   否则前者会被当成后者估价（会少算钱，方向虽然"讨好"但是错的）。
  /// - 美元价按 1 USD ≈ 7.25 元折算，并在条目上写出原价。
  ///
  /// 核对日期：2026-09-18
  static const Map<String, (double, double)> _table = {
    // ── 视觉模型（批量导入用得到的那些）─────────────────────────────────
    // 阿里云百炼 · 华北 2（北京）：官方价目表就直接写"元/每百万 tokens"
    // https://help.aliyun.com/zh/model-studio/qwen-vl-max
    'qwen-vl-max': (1.6, 4.0),
    // https://help.aliyun.com/zh/model-studio/qwen-vl-plus
    'qwen-vl-plus': (0.8, 2.0),
    // 智谱开放平台：视觉模型同样按 元/百万 tokens，长上下文分档，这里取最低档
    // https://bigmodel.cn/pricing
    'glm-4.6v-flashx': (0.15, 1.5),
    'glm-4.6v-flash': (0.0, 0.0), // 官方标注免费
    'glm-4.6v': (1.0, 3.0),
    'glm-4.5v': (2.0, 6.0),
    'glm-4v-plus': (4.0, 2.0),
    'glm-4v-flash': (0.0, 0.0), // 官方标注免费（首个免费视觉模型）
    'glm-4v': (50.0, 25.0),
    // Google：$0.10 / $0.40 每百万 token（× 7.25）
    // https://aipricinghub.com/models/google-gemini-gemini-2-0-flash-001
    'gemini-2.0-flash': (0.7, 2.9),
    // 本地推理（Ollama）没有 API 费用 —— 记 0，用量台账才不会显示"未知"
    'llava': (0.0, 0.0),
    'qwen2.5vl': (0.0, 0.0),
    'minicpm-v': (0.0, 0.0),
    'bakllava': (0.0, 0.0),
    'moondream': (0.0, 0.0),

    // ── 文本模型 ────────────────────────────────────────────────────────
    'deepseek-chat': (1.0, 2.0),
    'deepseek-reasoner': (4.0, 16.0),
    'qwen-turbo': (0.3, 0.6),
    'qwen-plus': (0.8, 2.0),
    'qwen-max': (2.4, 9.6),
    'glm-4-flash': (0.0, 0.0), // 有免费额度
    'glm-4-air': (0.5, 0.5),
    'glm-4-plus': (2.5, 2.5),
    'gpt-4o-mini': (1.1, 4.3),
    'gpt-4o': (18.0, 72.0),
    'claude-3-5-haiku': (5.8, 29.0),
    'claude-3-5-sonnet': (22.0, 108.0),
    'gemini-1.5-flash': (0.5, 1.5),
    'gemini-1.5-pro': (9.0, 36.0),
    // Moonshot：2025-04-07 那轮调价把 8k 系列从 12/12 降到 2/10
    // （旧价正是本表原来写的那一条 —— 已按官方文档更正）
    // https://github.com/hkai-ai/LLM_OFFICIAL_DOCUMENTATION/blob/main/moonshot/pricing.md
    'moonshot-v1-128k': (10.0, 30.0),
    'moonshot-v1-32k': (5.0, 20.0),
    'moonshot-v1-8k': (2.0, 10.0),
    // `kimi-latest` 会按上下文自动选 8k/32k/128k 计费，这里取**最低档**；
    // 长上下文实际会到 5/20 或 10/30，所以估算偏乐观
    'kimi-latest': (2.0, 10.0),
  };

  /// 估算费用。未知模型返回 null。
  static double? estimate({
    required String model,
    required int inputTokens,
    required int outputTokens,
  }) {
    final key = model.toLowerCase();
    for (final entry in _table.entries) {
      if (key.contains(entry.key)) {
        final (inPrice, outPrice) = entry.value;
        return (inputTokens / 1e6) * inPrice +
            (outputTokens / 1e6) * outPrice;
      }
    }
    return null;
  }

  /// 是否有该模型的价格信息。
  static bool has(String model) {
    final key = model.toLowerCase();
    return _table.keys.any(key.contains);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 请求 / 响应
// ─────────────────────────────────────────────────────────────────────────────

/// 附件的种类。决定在请求体里怎么编码。
enum ChatAttachmentKind {
  image,

  /// 直接把 PDF 发给模型（Anthropic / Gemini 支持）。
  ///
  /// 为什么不做本地 PDF 转图片：那要引入 pdfium（+10–15 MB 包体），
  /// 而云端本来就能读 PDF —— 既然批量导入走的已经是云端视觉模型，
  /// 就没有必要为同一件事再往包里塞一个渲染引擎。
  pdf,
}

/// 一次请求要带上的附件。
///
/// ## 为什么是「字节 + MIME」而不是文件路径
///
/// [LlmClient] 是 services 层，不该依赖 `dart:io`：
/// - 测试要能直接 `const ChatAttachment(...)` 构造，不必落盘
/// - 将来若把解析放到 isolate / 后端，这一层不用改
///
/// 读取文件是调用方（`ingest` 管道）的事。
class ChatAttachment {
  final ChatAttachmentKind kind;

  /// MIME 类型，如 `image/png`、`image/jpeg`、`application/pdf`。
  final String mimeType;

  final Uint8List bytes;

  /// 展示名（只用于日志与错误信息，不进请求体）。
  final String name;

  const ChatAttachment({
    required this.kind,
    required this.mimeType,
    required this.bytes,
    this.name = '',
  });

  /// base64 编码后的内容（三家协议都要求 base64）。
  ///
  /// 不用 data-URI 前缀 —— 那是 OpenAI 特有的写法，由各自的编码函数补。
  String get base64Data => base64Encode(bytes);

  int get byteLength => bytes.length;

  String get displayName => name.isEmpty ? mimeType : name;
}

/// 对话中的说话方。
///
/// 刻意**不含 system** —— 系统提示在 [ChatRequest.system] 里单独给。
/// 原因是 Anthropic 的 Messages API **不接受** `messages` 里出现
/// system 角色（必须放顶层 `system` 字段），塞进去会直接 400。
/// 与其在三家编码里各写一遍"遇到 system 怎么办"，
/// 不如在类型上就不允许：那样这种错误根本编译不出来。
enum ChatRole {
  user,
  assistant,

  /// 工具执行结果。**只有 OpenAI 兼容协议有这种角色。**
  ///
  /// Anthropic 把工具结果塞进 `user` 消息的 `tool_result` 内容块，
  /// Gemini 塞进 `functionResponse` 部分 —— 三家都没有"工具"这个角色。
  /// 所以它一旦出现在非 OpenAI 协议的请求里，就是编码层漏了判断，
  /// 见 [ChatRole.geminiName] 与 [LlmClient._buildRequest]。
  tool;

  /// Gemini 的助手角色叫 `model`，OpenAI / Anthropic 叫 `assistant`。
  ///
  /// 这是三家协议里唯一一处角色命名差异，所以单独给个出口，
  /// 而不是让编码函数各写各的字符串字面量。
  ///
  /// ⚠️ [ChatRole.tool] 会**抛异常**而不是退化成某个字符串。
  /// 退化成 `user` 的话，工具返回的 JSON 会被当成"用户说的一句话"
  /// 送给模型 —— 模型很可能照着这段 JSON 编出解释，而没有任何报错。
  /// 宁可在这里炸，也不要让一次静默的语义错位流到用户面前。
  String get geminiName => switch (this) {
        ChatRole.assistant => 'model',
        ChatRole.user => 'user',
        ChatRole.tool => throw UnsupportedError(
            'Gemini 协议里工具结果不是独立角色（是 functionResponse 内容块）；'
            '出现这个异常说明编码层漏了拦截。',
          ),
      };

  /// 从存储里的字符串还原。
  ///
  /// ## 认不出来时退化为 [assistant]，而不是抛异常
  ///
  /// 数据库里出现陌生角色名只有两种可能：将来又加了新角色，
  /// 或者这份数据是别处写坏的。两种情况下**都不能扔异常** ——
  /// 那会让整个会话打不开，用户直接看不到自己的聊天记录。
  ///
  /// 退化方向选 assistant 而不是 user 是刻意的：万一认错了，
  /// "把模型的话当模型的话"比"把模型的话伪装成用户说的"危害小得多 ——
  /// 后者会让用户以为自己写过一句从没写过的话。
  ///
  /// ⚠️ [ChatRole.tool] 现在**算正常值**（P2 加的工具结果角色）。
  /// 不过它只活在一次工具往返的**内存消息链**里，不会写进
  /// `chat_messages`（那一列只有 user / assistant，见 `ChatStore`）——
  /// 所以这条分支实际只在读到别处写坏的数据时才会走到。
  static ChatRole parseStored(String raw) {
    for (final r in ChatRole.values) {
      if (r.name == raw) return r;
    }
    return ChatRole.assistant;
  }
}

/// 对话里的一条消息。
///
/// ## 为什么普通消息与工具消息共用一个类
///
/// 工具调用的一轮往返是一条**链**：`assistant`（带 tool_calls）
/// → `tool`（带 tool_call_id 的结果）→ `assistant`（最终回答）。
/// 这条链必须按顺序原样回灌给模型，否则它不知道自己刚才要过什么。
/// 若把工具消息另立一个类、另开一个列表，就必然要处理
/// "两者谁先谁后"这个本不该存在的问题。放一个列表里，
/// 顺序就是列表顺序。
///
/// 三个新增字段都只在特定角色上有意义，为空时**编码结果与从前逐字节一致**。
class ChatMessage {
  final ChatRole role;
  final String content;

  /// 助手这一轮**请求调用**的工具。仅 [ChatRole.assistant] 可能非空。
  final List<ToolCall> toolCalls;

  /// 这条消息是哪个工具调用的结果。仅 [ChatRole.tool] 非空。
  ///
  /// 服务商靠它把结果与请求配对 —— 一轮里可以并行调多个工具，
  /// 少了它，多个结果就分不清谁是谁的。
  final String? toolCallId;

  const ChatMessage({
    required this.role,
    required this.content,
    this.toolCalls = const [],
    this.toolCallId,
  });

  const ChatMessage.user(this.content)
      : role = ChatRole.user,
        toolCalls = const [],
        toolCallId = null;

  const ChatMessage.assistant(this.content, {this.toolCalls = const []})
      : role = ChatRole.assistant,
        toolCallId = null;

  /// 一条工具执行结果。
  const ChatMessage.tool({
    required this.toolCallId,
    required this.content,
  })  : role = ChatRole.tool,
        toolCalls = const [];

  /// 是不是一条"带工具调用的助手消息"。
  bool get hasToolCalls => toolCalls.isNotEmpty;

  @override
  String toString() => 'ChatMessage(${role.name}, ${content.length} 字'
      '${hasToolCalls ? ', 调用 ${toolCalls.length} 个工具' : ''})';
}

/// 一个可以被模型调用的工具（OpenAI 的 function calling 规格）。
///
/// [parameters] 必须是 JSON Schema。服务商**只在它认得这个 schema**时
/// 才会正常填参数：写错类型（比如 `type` 写成 `string` 而 properties
/// 里放了个数组）不会报错，只会让模型瞎填。
class ToolSpec {
  final String name;

  /// 给**模型**看的说明，不是给用户看的。
  ///
  /// 写清楚"什么时候该用它"比"它做什么"更重要 —— 四个查询工具的能力
  /// 有重叠（都能按知识点筛），模型选错工具不会失败，只会白花一次调用。
  final String description;

  final Map<String, dynamic> parameters;

  const ToolSpec({
    required this.name,
    required this.description,
    this.parameters = const {'type': 'object', 'properties': <String, dynamic>{}},
  });

  /// 编码成 OpenAI 的 tools 数组元素。
  Map<String, dynamic> toOpenAiJson() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': parameters,
        },
      };
}

/// 模型请求的一次工具调用。
class ToolCall {
  /// 服务商给的调用 id。回灌结果时必须原样带回。
  ///
  /// ⚠️ 流式下它**可能只在第一片里出现**，后续分片只有 index 与参数。
  /// 聚合逻辑见 [LlmClient._consumeFrame]。
  final String id;

  final String name;

  /// 参数的**原始** JSON 字符串。
  ///
  /// 保留原文是因为模型偶尔会吐出非法 JSON（多一个逗号、少一个引号）。
  /// 那时我们既不能执行它，也不该假装它是空的 ——
  /// 报错信息里带上原文，才能让人看出模型想干什么。
  final String arguments;

  /// 解析后的参数。解析失败时为 null。
  final Map<String, dynamic>? parsed;

  ToolCall({required this.id, required this.name, required this.arguments})
      : parsed = _tryParseArgs(arguments);

  /// 实际可用的参数。解析失败时返回空 map（调用方按"缺参数"处理，
  /// 而不是拿一个半截的参数去查询）。
  Map<String, dynamic> get args => parsed ?? const {};

  bool get isParsed => parsed != null;

  static Map<String, dynamic>? _tryParseArgs(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return const {};
    try {
      final j = jsonDecode(t);
      if (j is Map) return j.cast<String, dynamic>();
      // 模型偶尔会包一层数组（`[{...}]`）—— 取第一个对象，比整条丢掉好
      if (j is List && j.isNotEmpty && j.first is Map) {
        return (j.first as Map).cast<String, dynamic>();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => 'ToolCall($name, id=$id, args=${arguments.length} 字节)';
}

/// 一次对话请求。
class ChatRequest {
  final String system;
  final String user;

  /// 本次请求**之前**的对话轮次，按时间顺序（早的在前）。
  ///
  /// ## 为什么叫 history 而不是 messages
  ///
  /// `messages` 很容易被读成"全部消息（含本次这条 user）"。而它其实是
  /// 夹在 [system] 之后、本次 [user] 之前的那一段，所以叫 history。
  ///
  /// ## 为空时零影响
  ///
  /// 留空时请求体与改动前**逐字节一致** —— 既有那十来个调用点
  /// （录入、批量导入、标注、组题）一行都不用改，也不会多花一分钱。
  ///
  /// ## 历史消息只发文本，不带附件
  ///
  /// 带附件的那条消息在它自己那一轮已经发过图了。若每轮都重发，
  /// 到第十轮就会同时带上十张图的 base64 —— 费用是**平方级**增长的。
  /// 代价是模型看不到"之前那张图"，但它看得到当时的文字，
  /// 对"接着聊"这个场景够用。
  final List<ChatMessage> history;

  /// 随请求一起发出去的图片 / PDF。
  ///
  /// 为空时请求体与"纯文本"完全一致（保持与既有服务商的兼容性）。
  /// 非空时由 [_buildOpenAi] / [_buildAnthropic] / [_buildGemini]
  /// 按各自协议编码 —— 三家的多模态格式**互不相同**。
  final List<ChatAttachment> attachments;

  /// 是否要求模型输出 JSON。
  ///
  /// 不同服务商的支持方式不同（见 [LlmClient._buildBody]），
  /// 不支持时靠 [RobustJson] 兜底解析。
  final bool jsonMode;

  /// 温度。标注任务用低温度（0.1）保证稳定。
  final double temperature;

  /// 完整的对话消息列表（**不含** system）。
  ///
  /// ## 为什么需要一个"显式消息列表"，而不是复用 [history] + [user]
  ///
  /// `history + user` 这种形状隐含一个假设：**最后一条一定是用户说的话**。
  /// 带工具的一轮往返打破了这个假设 —— 它的结尾是一条 `tool` 结果
  /// （`assistant(tool_calls)` → `tool(结果)` → 再问模型）。
  /// 那种序列用"history 加一条 user"表达不出来：
  /// 把工具结果塞进 `user`，模型会把 JSON 当成人话；
  /// 塞进 `history` 又会在末尾多出一条不该有的空 user。
  ///
  /// 所以给一条明确的出口：本字段非空时**忽略** [user] 与 [history]，
  /// [system] 依然单独给（Anthropic 要求它在顶层）。
  ///
  /// 为空时（既有那十来个调用点）行为与从前逐字节一致。
  final List<ChatMessage> messages;

  /// 最大输出 token。
  final int? maxTokens;

  /// 本轮允许模型调用的工具。
  ///
  /// ## 为空时零影响
  ///
  /// 与 [history] 同一策略：留空时请求体里**不会出现** `tools` 字段，
  /// 于是既有的十来个纯文本调用点完全不受影响，也不会因为多传一个
  /// 服务商不认的字段而 400。
  ///
  /// ## 只有 OpenAI 兼容协议能传
  ///
  /// Anthropic / Gemini 的工具格式与 OpenAI **完全不同**
  /// （`tools` 的 schema 形状、工具结果的承载方式都不一样）。
  /// 硬套 OpenAI 格式的结果是模型收不到工具却也不报错，
  /// 于是它开始凭空编参数。所以 [_buildRequest] 里直接拦下来报错，
  /// 而不是试着"通用化"。另两家留到 P4。
  final List<ToolSpec> tools;

  const ChatRequest({
    required this.system,
    required this.user,
    this.history = const [],
    this.attachments = const [],
    this.jsonMode = false,
    this.temperature = 0.1,
    this.maxTokens,
    this.tools = const [],
    this.messages = const [],
  });

  bool get hasAttachments => attachments.isNotEmpty;

  bool get hasTools => tools.isNotEmpty;

  /// 是否走"显式消息列表"这条路。
  bool get hasExplicitMessages => messages.isNotEmpty;
}

/// 一次对话响应。
class ChatResponse {
  final String text;
  final LlmUsage usage;

  /// 命中的服务商与模型，便于审计。
  final String providerId;

  /// 尝试了几次（含首次）。
  final int attempts;

  /// 服务商给的停止原因（OpenAI `finish_reason` / Anthropic `stop_reason` /
  /// Gemini `finishReason`）。取不到时为 null。
  final String? finishReason;

  /// 模型这一轮请求调用的工具。为空表示它直接给了最终回答。
  ///
  /// ⚠️ **非空时 [text] 通常为空** —— 这是 OpenAI 的正常行为：
  /// 决定调工具的那一轮不产出正文。所以调用方判断"这一轮结束了吗"
  /// 不能只看 [text]，要看 [toolCalls] 是否为空。
  final List<ToolCall> toolCalls;

  const ChatResponse({
    required this.text,
    required this.usage,
    this.providerId = '',
    this.attempts = 1,
    this.finishReason,
    this.toolCalls = const [],
  });

  /// 模型这是**想调工具**，而不是在回答。
  ///
  /// 它比调用方自己写 `toolCalls.isNotEmpty` 更值得存在，是因为
  /// "工具轮"与"最终回答轮"要走的代码路径完全不同（一个要执行后回灌，
  /// 一个要落盘收尾），而这两条路一旦走串，症状是
  /// "回答里混着没执行的工具名" —— 很难从现象反推。
  bool get wantsTools => toolCalls.isNotEmpty;

  /// 输出是否**因为达到上限被截断**。
  ///
  /// ## 为什么这个字段重要
  ///
  /// 截断不会报错：JSON 只是少了一截，`RobustJson` 会把**能解析的前几个
  /// 对象**救回来。批量导入于是"成功"了，只是少导了几道题，
  /// 而提示会是"模型没有用 problems 包一层"之类（误诊）。
  /// 这个字段此前全项目**没有读过**，所以截断完全不可见。
  ///
  /// ⚠️ 别把它当成"少导题"的唯一解释：实测（2026-09-18，智谱
  /// `glm-4v-flash`，660 线代 p4）一页 3 道题只进来 1 道，
  /// 但 `finish_reason` 是 `stop`、只用了 567/1024 token ——
  /// 真因是模型给的是**顶层数组**而解析器只认对象（见
  /// `RobustJson.extract` 的 `acceptArray`）。
  ///
  /// 三家协议的"截断"标记分别是 `length` / `max_tokens` / `MAX_TOKENS`。
  bool get truncated {
    final r = finishReason?.toLowerCase();
    if (r == null) return false;
    return r == 'length' || r == 'max_tokens' || r == 'maxtokens';
  }
}

/// 流式对话过程中的一次事件。
///
/// 用 `sealed` 而不是"一个带 nullable 字段的结果类"是因为：
/// 调用方必须**把两种情形分开处理** —— [ChatDelta] 是"已经到手的字"，
/// 可以立刻画到屏幕上；[ChatDone] 是"这一轮结束了"，要落库、要记账、
/// 可能还要接着跑下一轮工具调用。合成一个类的话，
/// 漏判其中一种（比如把 delta 也当成结束）不会有任何编译期提示。
sealed class ChatStreamEvent {
  const ChatStreamEvent();
}

/// 模型新吐出的一段文本。**可能只是半个词**，别拿它当完整句子。
class ChatDelta extends ChatStreamEvent {
  final String text;

  const ChatDelta(this.text);
}

/// 这一轮结束。带完整文本、用量与停止原因。
///
/// 里面的 [ChatResponse] 与 [LlmClient.chat] 返回的是同一个类型 ——
/// 于是"非流式"与"流式"两条路在**落库与记账**上可以共用同一段代码。
class ChatDone extends ChatStreamEvent {
  final ChatResponse response;

  const ChatDone(this.response);
}

// ─────────────────────────────────────────────────────────────────────────────
// 客户端
// ─────────────────────────────────────────────────────────────────────────────

/// 重试策略。
class RetryPolicy {
  /// 最大尝试次数（含首次）。
  final int maxAttempts;

  /// 首次退避时长。
  final Duration initialBackoff;

  /// 退避倍数。
  final double backoffMultiplier;

  /// 单次退避上限（避免等到天荒地老）。
  final Duration maxBackoff;

  const RetryPolicy({
    this.maxAttempts = 3,
    this.initialBackoff = const Duration(seconds: 2),
    this.backoffMultiplier = 2.0,
    this.maxBackoff = const Duration(seconds: 30),
  });

  /// 第 [attempt] 次失败后的等待时长（attempt 从 1 开始）。
  Duration backoffFor(int attempt) {
    final ms = initialBackoff.inMilliseconds *
        _pow(backoffMultiplier, attempt - 1);
    final capped = ms.clamp(0, maxBackoff.inMilliseconds.toDouble());
    return Duration(milliseconds: capped.round());
  }

  static double _pow(double base, int exp) {
    var r = 1.0;
    for (var i = 0; i < exp; i++) {
      r *= base;
    }
    return r;
  }
}

/// LLM 客户端。
class LlmClient {
  final LlmConfig config;
  final HttpAdapter http;
  final RetryPolicy retry;

  /// 退避等待函数。测试时注入立即返回的实现，避免测试真的等待。
  final Future<void> Function(Duration) sleep;

  /// 每次调用后的回调（用于写用量台账）。
  final void Function(LlmUsage)? onUsage;

  LlmClient({
    required this.config,
    required this.http,
    this.retry = const RetryPolicy(),
    Future<void> Function(Duration)? sleep,
    this.onUsage,
  }) : sleep = sleep ?? Future<void>.delayed;

  /// 发送一次请求（含重试）。
  Future<ChatResponse> chat(ChatRequest request) async {
    final (ok, problem) = config.validate();
    if (!ok) {
      throw LlmException(LlmErrorKind.invalidKey, problem ?? '配置不完整');
    }

    Object? lastError;
    var attempt = 0;

    while (attempt < retry.maxAttempts) {
      attempt++;
      try {
        final resp = await http.send(_buildRequest(request));
        // ⚠️ 先记账，再校验内容。
        //
        // 一次 200 但"没有文本内容/JSON 不可解析"的响应**同样是要付费的** ——
        // 服务商按 token 计费，不会因为我们解析失败就免单。
        // 早先 `onUsage` 只在 `_parseResponse` 成功返回后才调用，
        // 于是这条路径上的钱凭空消失，而 `tables.dart` 明确写着
        // "这张表的行数就是真实调用次数" —— 用户在用量面板看到的数字是错的，
        // 而且错得**偏低**（以为省钱，实际花了）。
        _reportUsage(resp);
        final parsed = _parseResponse(resp, attempt);
        return parsed;
      } on LlmException catch (e) {
        lastError = e;
        // 不可重试的错误立即抛出，不做无谓等待
        if (!e.kind.isRetryable) rethrow;
        if (attempt >= retry.maxAttempts) rethrow;
        await sleep(retry.backoffFor(attempt));
      } on HttpTransportException catch (e) {
        lastError = e;
        if (attempt >= retry.maxAttempts) {
          throw LlmException(
            _classifyTransport(e),
            e.message,
          );
        }
        await sleep(retry.backoffFor(attempt));
      }
    }

    throw LlmException(
      LlmErrorKind.unknown,
      '重试 ${retry.maxAttempts} 次后仍失败：$lastError',
    );
  }

  /// 当前服务商是否支持流式输出。
  ///
  /// 暂时只有 OpenAI 兼容协议。Anthropic 与 Gemini 的 SSE 格式完全不同
  /// （Anthropic 走 `content_block_delta` 事件流，Gemini 要 `alt=sse`
  /// 且把文本埋在 `candidates[].content.parts[]` 里），
  /// 是单独一期的事 —— 见 `docs/PROGRESS.md` 的对话助手分期。
  ///
  /// 调用方（对话页）应当先问这个，不支持时退回非流式的 [chat]，
  /// 而不是走到 [chatStream] 里撞一个异常。
  bool get supportsStreaming =>
      config.spec?.protocol == LlmProtocol.openAiCompatible;

  /// 这个服务商能不能用工具（function calling）。
  ///
  /// 与 [supportsStreaming] 是同一批（都只有 OpenAI 兼容协议）。
  /// 分开两个 getter 而不是合成一个，是因为它们**将来会不同**：
  /// P4 要给 Anthropic / Gemini 补的是"流式**与**工具"两件事，
  /// 而补的过程中很可能出现"流式好了、工具还没好"的中间状态 ——
  /// 那时界面该退回非流式对话，却仍不该把工具按钮点亮。
  bool get supportsTools =>
      config.spec?.protocol == LlmProtocol.openAiCompatible;

  /// 发送一次**流式**请求，逐段吐出模型新增的文本。
  ///
  /// ## 与 [chat] 的三点不同
  ///
  /// **一、重试的口径不同 —— 这是最关键的一条。**
  /// 一旦有字吐出来，就**绝不能重试**：用户已经看到"洛必"两个字，
  /// 重试会让它再从"洛必"开始，回复里出现接不上的重复片段，
  /// 而用户完全无法判断哪一遍算数。所以只在"一个字都还没吐"时重试 ——
  /// 那时失败发生在建连阶段，语义与 [chat] 一致。
  ///
  /// **二、用量可能拿不到。** OpenAI 兼容接口默认**不返回**流式的 usage，
  /// 要显式要 `stream_options.include_usage` 才有；而几家国产服务商
  /// 对这个字段支持不一，传了可能直接 400。所以只对**已知支持**的传
  /// （与 `jsonMode` 同一策略），其余拿不到就记 0。
  /// ⚠️ 于是用量台账里对话的 token 数可能**偏低**，但**行数仍然准确**
  /// （每一次真实调用各记一行，见 `tables.dart` 的说明）。
  /// 拿不到用量时界面上会如实写出来，不让用户以为"聊天是免费的"。
  ///
  /// **三、返回事件流而非一次性结果。** [ChatDone] 里带着与 [chat]
  /// 同构的 [ChatResponse]，所以调用方可以只认它、忽略中间过程。
  Stream<ChatStreamEvent> chatStream(ChatRequest request) async* {
    final spec = config.spec;
    if (spec == null) {
      throw const LlmException(LlmErrorKind.invalidKey, '未知的服务商');
    }
    if (!supportsStreaming) {
      throw LlmException(
        LlmErrorKind.badRequest,
        '${spec.label} 走的 ${spec.protocol.name} 协议还不支持流式输出。',
      );
    }

    Object? lastError;
    var attempt = 0;

    while (attempt < retry.maxAttempts) {
      attempt++;

      final parser = SseParser();
      final acc = _StreamAcc();
      final errorBody = StringBuffer();
      var statusCode = 0;
      Object? failure;

      try {
        final chunks = http.sendStream(_buildRequest(request, stream: true));
        await for (final chunk in chunks) {
          statusCode = chunk.statusCode;
          // 非 2xx：把 body 收全了再分类 —— 状态行之外，
          // 服务商真正想说的话（欠费 / Key 错 / 参数不合法）都写在 body 里。
          if (!chunk.isSuccess) {
            errorBody.write(chunk.text);
            continue;
          }
          for (final payload in parser.feed(chunk.text)) {
            final delta = _consumeFrame(payload, acc);
            if (delta != null) yield ChatDelta(delta);
          }
        }
        // 流正常结束。缓冲区里若还剩半行，服务商就是没发结尾换行 ——
        // 不补这一下，用户看到的是"最后一句莫名缺了一截"。
        for (final payload in parser.flush()) {
          final delta = _consumeFrame(payload, acc);
          if (delta != null) yield ChatDelta(delta);
        }
      } on LlmException catch (e) {
        failure = e;
      } on HttpTransportException catch (e) {
        failure = e;
      } catch (e) {
        failure = e;
      }

      // ① 非 2xx。分类后按可重试性决定。
      if (errorBody.isNotEmpty) {
        final e = _classifyHttpError(
          HttpResponse(statusCode: statusCode, body: errorBody.toString()),
        );
        lastError = e;
        if (!e.kind.isRetryable || attempt >= retry.maxAttempts) throw e;
        await sleep(retry.backoffFor(attempt));
        continue;
      }

      // ② 流中途断了。
      if (failure != null) {
        // ⚠️ 已经吐过字就绝不重试 —— 见方法头注释第一条。
        if (acc.gotText || attempt >= retry.maxAttempts) {
          throw failure is LlmException
              ? failure
              : LlmException(
                  failure is HttpTransportException
                      ? _classifyTransport(failure)
                      : LlmErrorKind.unknown,
                  '$failure',
                );
        }
        lastError = failure;
        await sleep(retry.backoffFor(attempt));
        continue;
      }

      // ③ 正常结束，但既没有文本、也没有工具调用。
      //
      // ⚠️ "没有文本"**不等于**出错：模型决定调工具的那一轮就是
      // 一点正文都不产出（见 [ChatResponse.toolCalls]）。早先这里只看
      // 文本，于是每一次工具调用都会被判成"流式响应里没有文本内容" ——
      // 工具功能会以"服务商坏了"的样子整个失效。
      final calls = acc.buildToolCalls();
      if (acc.text.isEmpty && calls.isEmpty) {
        throw LlmException(
          LlmErrorKind.badResponse,
          '流式响应里没有文本内容',
          rawBody: _truncate(acc.lastPayload),
        );
      }

      // 记账放在这里：与 [chat] 同理，内容不可用也一样计费 ——
      // 但"完全没有文本"那种我们刚抛了错，那一笔在服务商侧通常也不计费。
      if (onUsage != null) {
        try {
          onUsage!(acc.usage);
        } catch (_) {
          // 记账是旁路，绝不能影响对话本身的成败
        }
      }

      yield ChatDone(ChatResponse(
        text: acc.text.toString(),
        usage: acc.usage,
        providerId: config.providerId,
        attempts: attempt,
        finishReason: acc.finishReason.isEmpty ? null : acc.finishReason,
        toolCalls: calls,
      ));
      return;
    }

    throw LlmException(
      LlmErrorKind.unknown,
      '重试 ${retry.maxAttempts} 次后仍失败：$lastError',
    );
  }

  /// 吃一帧 SSE 载荷，把结果并进 [acc]，返回这帧**新增**的文本。
  ///
  /// 返回 null 表示这帧没有文本可吐 —— 心跳、只有 usage 的收尾帧、
  /// `[DONE]` 都属于此类。**它们不是错误**，只是没什么可说的。
  String? _consumeFrame(String payload, _StreamAcc acc) {
    if (payload == '[DONE]') {
      acc.sawDone = true;
      return null;
    }
    if (payload.isEmpty) return null;

    // 留住最后见过的原始载荷：整条流一个字都没解析出来时，
    // 它就是唯一能说明"服务商到底回了什么"的证据。没有它，
    // 报错只剩一句"没有文本内容"，排查等于从零开始。
    acc.lastPayload = payload;

    final decoded = _tryJsonMap(payload);
    if (decoded == null) return null;

    // 停止原因与用量可能出现在任意一帧（多数服务商放在最后一帧）。
    // ⚠️ 它们必须在 delta 分支**之外**判断：OpenAI 会先发一帧
    // `choices: []` 而只有 usage 的收尾帧，那种帧的 delta 是 null，
    // 挂在 delta 里就会把用量整个漏掉。
    final fr = _extractFinishReason(decoded, LlmProtocol.openAiCompatible);
    if (fr != null && fr.isNotEmpty) acc.finishReason = fr;
    final u = _extractUsage(decoded);
    if (u.totalTokens > 0) acc.usage = u;

    // 工具调用分片。要在取文本**之前**处理：两者互斥
    // （同一帧不会既有正文又有工具分片），但工具分片会横跨很多帧，
    // 少过一帧就少一段参数 JSON，而那种残缺是**静默**的 ——
    // 参数解析失败的报错长得很像"模型乱填参数"。
    _mergeToolDeltas(decoded, acc);

    final delta = _openAiDelta(decoded);
    if (delta == null || delta.isEmpty) return null;

    acc.gotText = true;
    acc.text.write(delta);
    return delta;
  }

  /// 把一帧里的 `delta.tool_calls` 并进累积器。
  ///
  /// ## 为什么必须按 `index` 聚合
  ///
  /// OpenAI 的流式工具调用是**分片**的：函数名出现在第一片，
  /// 参数 JSON 被切成很多片陆续到达，而**每一片都带同样的 index**。
  /// 一轮可以并行调多个工具，于是分片会交织出现 ——
  /// 不按 index 归位的话，两个工具的参数字符串会被拼到一起。
  ///
  /// ## 参数是**字符串拼接**，不是 JSON 合并
  ///
  /// 服务商把 `arguments` 当普通文本切片发，我们只能按顺序接起来
  /// 再一次性解析。中途任何一片都不能单独解析 ——
  /// 所以 [ToolCall] 是在**整条流结束后**才构造的。
  void _mergeToolDeltas(Map<dynamic, dynamic> j, _StreamAcc acc) {
    final choices = j['choices'];
    if (choices is! List || choices.isEmpty) return;
    final first = choices.first;
    if (first is! Map) return;
    final delta = first['delta'];
    if (delta is! Map) return;
    final calls = delta['tool_calls'];
    if (calls is! List) return;

    for (final raw in calls) {
      if (raw is! Map) continue;

      // 没有 index 时退化到"当前最后一个槽位"：个别自建代理不发 index
      // 而一轮只调一个工具，那种情况下这是唯一说得通的解释。
      final idx = raw['index'];
      final i = idx is int
          ? idx
          : (acc.toolCalls.isEmpty
              ? 0
              : acc.toolCalls.keys.reduce((a, b) => a > b ? a : b));
      final slot = acc.toolCalls.putIfAbsent(i, _ToolCallAcc.new);

      final id = raw['id'];
      if (id is String && id.isNotEmpty) slot.id = id;

      final fn = raw['function'];
      if (fn is Map) {
        final name = fn['name'];
        if (name is String && name.isNotEmpty) slot.name = name;
        final args = fn['arguments'];
        if (args is String) slot.arguments.write(args);
      }
    }
  }

  /// OpenAI 兼容协议的增量文本。
  ///
  /// 三种形态都要认：`delta.content` 是字符串（绝大多数）、
  /// 是数组（部分实现把内容拆成 `[{type:text,text:...}]`）、
  /// 以及旧版 completions 的顶层 `text`（个别自建代理还在用）。
  String? _openAiDelta(Map<dynamic, dynamic> j) {
    final choices = j['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final first = choices.first;
    if (first is! Map) return null;

    final delta = first['delta'];
    if (delta is Map) {
      final c = delta['content'];
      if (c is String) return c;
      if (c is List) {
        return c
            .whereType<Map<Object?, Object?>>()
            .map((p) => p['text']?.toString() ?? '')
            .join();
      }
    }
    return first['text']?.toString();
  }

  /// 解析一帧载荷为 Map。不是 JSON 就返回 null。
  ///
  /// 静默跳过是有意的：部分服务商会在流里插非 JSON 的保活内容。
  /// 若整条流都没有可解析的帧，[chatStream] 会用 [.., 原始载荷]
  /// 报错，所以这里"吞掉"不会让问题变得不可查。
  static Map<dynamic, dynamic>? _tryJsonMap(String payload) {
    try {
      final v = jsonDecode(payload);
      return v is Map ? v : null;
    } catch (_) {
      return null;
    }
  }

  // ───────────────────────────────────────────────────────────────────────
  // 请求构造
  // ───────────────────────────────────────────────────────────────────────

  HttpRequest _buildRequest(ChatRequest req, {bool stream = false}) {
    final spec = config.spec;
    if (spec == null) {
      throw const LlmException(LlmErrorKind.invalidKey, '未知的服务商');
    }

    // ⚠️ 工具调用的**唯一**拦截点。
    //
    // 拦在编码之前而不是让三家编码各自处理，理由是三家的工具格式
    // 差异太大：OpenAI 是 `tools` + `tool` 角色，Anthropic 是
    // `tools` + user 消息里的 `tool_result` 块，Gemini 是
    // `functionDeclarations` + `functionResponse`。任何"通用化"的尝试
    // 都会变成三个半成品。
    //
    // 更要紧的是**失败方式**：如果只是把 OpenAI 格式原样发给 Anthropic，
    // 它多半会忽略不认识的字段并照常回答 —— 于是模型收不到工具、
    // 却仍然被要求"根据工具结果回答"。它会开始编。这属于
    // "看起来在工作"的问题，比直接报错难查得多。
    if (req.hasTools && spec.protocol != LlmProtocol.openAiCompatible) {
      throw LlmException(
        LlmErrorKind.badRequest,
        '${spec.label} 走的 ${spec.protocol.name} 协议还不支持工具调用。'
        '要让它读你的题库，请先在「设置」里换成 OpenAI 兼容的服务商'
        '（DeepSeek / 通义 / 智谱 / OpenAI 等）。',
      );
    }

    // 历史里若夹着工具消息（上一轮工具往返的回灌），同理不能送错协议。
    // 这类消息比 `tools` 字段更危险：它是**已经在对话里**的内容，
    // 漏掉它会让模型看不到自己刚要过什么，从而重复调用或凭空作答。
    if (spec.protocol != LlmProtocol.openAiCompatible &&
        req.history.any((m) => m.role == ChatRole.tool || m.hasToolCalls)) {
      throw LlmException(
        LlmErrorKind.badRequest,
        '这段对话里包含工具调用记录，而 ${spec.label} 的协议还不支持回灌它们。'
        '请换成 OpenAI 兼容的服务商，或新开一段对话。',
      );
    }

    // `messages` 这条路上没有地方安放附件：图片/PDF 属于"当前这一轮"，
    // 而显式消息列表里可以有好几条。硬塞进去会改变既有语义，
    // 所以直接挡住（目前唯一的调用方是工具往返，它不需要附件）。
    if (req.hasExplicitMessages && req.hasAttachments) {
      throw const LlmException(
        LlmErrorKind.badRequest,
        '同一次请求不能既给显式消息列表、又带附件。',
      );
    }

    return switch (spec.protocol) {
      LlmProtocol.openAiCompatible => _buildOpenAi(req, spec, stream: stream),
      // Anthropic / Gemini 目前只有非流式。[LlmClient.chatStream] 在入口
      // 就按 `supportsStreaming` 挡掉了，所以走不到这里。
      LlmProtocol.anthropic => _buildAnthropic(req),
      LlmProtocol.gemini => _buildGemini(req),
    };
  }

  /// OpenAI 兼容（覆盖 DeepSeek / 通义 / 智谱 / Moonshot / OpenAI / Ollama / 自建）。
  HttpRequest _buildOpenAi(
    ChatRequest req,
    ProviderSpec spec, {
    bool stream = false,
  }) {
    final body = <String, dynamic>{
      'model': config.model,
      'messages': [
        {'role': 'system', 'content': req.system},
        // 显式消息列表优先（工具往返走的这条）。为空时走下面那条，
        // 产生的结果与引入工具之前逐字节相同。
        if (req.hasExplicitMessages)
          for (final m in req.messages) _openAiMessage(m)
        else ...[
          for (final m in req.history) _openAiMessage(m),
          {'role': 'user', 'content': _openAiUserContent(req)},
        ],
      ],
      'temperature': req.temperature,
      'stream': stream,
    };

    // 流式下默认**拿不到**用量，要显式开口子。但几家国产服务商
    // 不认识这个字段，传了可能直接 400 —— 所以只对已知支持的传，
    // 与下面 jsonMode 同一策略：宁可在少数服务商上少记用量，
    // 也不能让对话在它们上面直接不可用。
    const supportsStreamUsage = {'openai', 'deepseek'};
    if (stream && supportsStreamUsage.contains(spec.id)) {
      body['stream_options'] = {'include_usage': true};
    }
    if (req.maxTokens != null) {
      body['max_tokens'] = _clampMaxTokens(req.maxTokens!);
    }

    // JSON mode 的支持面很广但不统一：
    // - OpenAI / DeepSeek / 通义 / 智谱 支持 response_format
    // - Ollama 与部分自建代理不认这个字段，传了可能报 400
    //
    // 策略：只在"已知支持"的服务商上传，其余靠 prompt 约束 + RobustJson 兜底。
    const supportsJsonMode = {'openai', 'deepseek', 'qwen', 'zhipu', 'moonshot'};
    if (req.jsonMode && supportsJsonMode.contains(spec.id)) {
      body['response_format'] = {'type': 'json_object'};
    }

    // 工具。为空时**这个键根本不出现** —— 见 [ChatRequest.tools] 的说明。
    if (req.hasTools) {
      body['tools'] = [for (final t in req.tools) t.toOpenAiJson()];
      // 不传 `tool_choice`：默认 `auto` 就是我们要的语义
      // （模型自己决定查还是不查）。显式传 `auto` 反而在个别自建
      // 代理上会因为不认识这个字段而 400。
    }

    return HttpRequest(
      url: '${config.baseUrl}/chat/completions',
      headers: config.headers(),
      body: jsonEncode(body),
    );
  }

  /// 把一条历史消息编码成 OpenAI 的 message。
  ///
  /// 三种形态：普通对话（user / assistant 纯文本）、带工具调用的助手消息、
  /// 工具执行结果。**普通形态的输出与引入工具之前逐字节相同** ——
  /// 键的顺序也一样，所以既有的非工具调用点不会因为这次改动产生任何差异。
  static Map<String, dynamic> _openAiMessage(ChatMessage m) {
    if (m.role == ChatRole.tool) {
      return {
        'role': 'tool',
        // 空 id 也要给键：服务商靠它配对，缺键会直接 400，
        // 而空串至少能让报错定位到"这一轮少了 id"。
        'tool_call_id': m.toolCallId ?? '',
        'content': m.content,
      };
    }
    if (m.hasToolCalls) {
      return {
        'role': 'assistant',
        // 决定调工具的那一轮通常没有正文，但 `content` 键**必须在**
        // （OpenAI 对缺键与空串的处理不同：缺键会让它认为这是
        // 一条不完整的 assistant 消息）。给空串最稳。
        'content': m.content,
        'tool_calls': [
          for (final c in m.toolCalls)
            {
              'id': c.id,
              'type': 'function',
              'function': {'name': c.name, 'arguments': c.arguments},
            },
        ],
      };
    }
    return {'role': m.role.name, 'content': m.content};
  }

  /// OpenAI 兼容协议的 user content。
  ///
  /// 没有附件时保持**纯字符串** —— 部分第三方兼容端点对"内容数组"支持不全，
  /// 没必要为了统一写法让纯文本调用冒兼容风险。
  Object _openAiUserContent(ChatRequest req) {
    if (!req.hasAttachments) return req.user;

    final parts = <Map<String, dynamic>>[
      {'type': 'text', 'text': req.user},
    ];
    for (final a in req.attachments) {
      switch (a.kind) {
        case ChatAttachmentKind.image:
          parts.add({
            'type': 'image_url',
            'image_url': {'url': 'data:${a.mimeType};base64,${a.base64Data}'},
          });
        case ChatAttachmentKind.pdf:
          // ⚠️ 宁可**报错也不要静默丢掉附件**。
          //
          // OpenAI 的 `/chat/completions` 不接受 PDF（要走 Files + Responses
          // API）。若这里默默跳过，用户会收到一个只看了题干文字、完全没看
          // PDF 的"解析结果"，而且**为它付了钱** —— 那种错误比直接失败难查得多。
          // 调用方应当先用 `LlmConfig.pdfSupport` 判断，不要走到这里。
          throw LlmException(
            LlmErrorKind.badRequest,
            '${config.providerId} 的对话接口不支持直接发送 PDF，'
            '请改用支持 PDF 的服务商（Claude / Gemini），或先把 PDF 导出成图片。',
          );
      }
    }
    return parts;
  }

  /// 把输出上限收进**这个模型**允许的范围。
  ///
  /// ## 为什么必须有这一步
  ///
  /// 真机实测（2026-09-18）：智谱 `glm-4v-flash` 的 `max_tokens` 只接受
  /// `[1,1024]`，而批量导入为了"一页多题"写死了 8192 ——
  /// 于是**智谱上的批量导入一次都跑不通**，返回 400 code 1210，
  /// 用户只看到一句"请求不合法"。
  ///
  /// 上限的取法见 [LlmConfig.maxOutputTokens]（按模型，不按服务商 ——
  /// 同家的 `glm-4.6v-flash` 实测就收 8192）。
  ///
  /// 收窄而不是报错：输出空间小一点，总好过整个模型不可用。
  int _clampMaxTokens(int want) {
    final cap = config.maxOutputTokens;
    if (cap == null || want <= cap) return want;
    return cap;
  }

  /// Anthropic Messages API。
  HttpRequest _buildAnthropic(ChatRequest req) {    // Anthropic 把 system 放在顶层字段而非 messages 里
    final body = <String, dynamic>{
      'model': config.model,
      'system': req.system,
      'messages': [
        // 工具在这条协议上被 [_buildRequest] 挡住了，所以这里不会出现
        // tool 角色或 tool_calls —— 只需按普通消息展开。
        if (req.hasExplicitMessages)
          for (final m in req.messages)
            {'role': m.role.name, 'content': m.content}
        else ...[
          for (final m in req.history)
            {'role': m.role.name, 'content': m.content},
          {'role': 'user', 'content': _anthropicUserContent(req)},
        ],
      ],
      'temperature': req.temperature,
      'max_tokens': _clampMaxTokens(req.maxTokens ?? 4096),
    };
    return HttpRequest(
      url: '${config.baseUrl}/messages',
      headers: config.headers(),
      body: jsonEncode(body),
    );
  }

  Object _anthropicUserContent(ChatRequest req) {
    if (!req.hasAttachments) return req.user;

    final blocks = <Map<String, dynamic>>[];
    for (final a in req.attachments) {
      blocks.add({
        // Anthropic 用两个不同的 block 类型：图片是 `image`，
        // PDF 是 `document`（2024-11 起支持，走同一个 base64 source 结构）。
        'type': a.kind == ChatAttachmentKind.pdf ? 'document' : 'image',
        'source': {
          'type': 'base64',
          'media_type': a.mimeType,
          'data': a.base64Data,
        },
      });
    }
    blocks.add({'type': 'text', 'text': req.user});
    return blocks;
  }

  /// Google Gemini generateContent。
  HttpRequest _buildGemini(ChatRequest req) {
    final body = <String, dynamic>{
      'systemInstruction': {
        'parts': [
          {'text': req.system},
        ],
      },
      'contents': [
        // 显式消息列表优先（工具往返走的这条）。Gemini 上工具被拦掉了，
        // 所以这里不会有 tool 角色 —— 走到 `geminiName` 的 tool 分支
        // 说明拦截失效了，那正是它抛异常要提示的事。
        if (req.hasExplicitMessages)
          for (final m in req.messages)
            {
              'role': m.role.geminiName,
              'parts': [
                {'text': m.content},
              ],
            }
        else ...[
          // ⚠️ Gemini 的助手角色是 `model` 而不是 `assistant` ——
          // 写成 assistant 不会报参数错，而是被当成未知角色处理，
          // 表现为"模型完全不记得上一轮说过什么"。
          for (final m in req.history)
            {
              'role': m.role.geminiName,
              'parts': [
                {'text': m.content},
              ],
            },
          {
            'role': 'user',
            'parts': _geminiParts(req),
          },
        ],
      ],
      'generationConfig': {
        'temperature': req.temperature,
        if (req.maxTokens != null)
          'maxOutputTokens': _clampMaxTokens(req.maxTokens!),
        if (req.jsonMode) 'responseMimeType': 'application/json',
      },
    };

    // Gemini 的 Key 走 query 参数
    final sep = config.baseUrl.contains('?') ? '&' : '?';
    return HttpRequest(
      url: '${config.baseUrl}/models/${config.model}:generateContent'
          '${sep}key=${Uri.encodeQueryComponent(config.apiKey)}',
      headers: config.headers(),
      body: jsonEncode(body),
    );
  }

  /// Gemini 的 parts：图片与 PDF 都走 `inline_data`，只差 MIME。
  List<Map<String, dynamic>> _geminiParts(ChatRequest req) {
    return [
      for (final a in req.attachments)
        {
          'inline_data': {'mime_type': a.mimeType, 'data': a.base64Data},
        },
      {'text': req.user},
    ];
  }

  // ───────────────────────────────────────────────────────────────────────
  // 响应解析
  // ───────────────────────────────────────────────────────────────────────

  /// 只要响应是 2xx 就把这次调用的用量报上去。
  ///
  /// 与 [_parseResponse] 分开的原因见 [chat] 里的调用点：
  /// 记账不能等到内容校验通过 —— 内容不可用也一样计费。
  ///
  /// 非 2xx（鉴权失败、限流、参数错）通常不计费，因此直接跳过；
  /// 重试的每一次尝试各记一次，因为每一次都真的发出去了。
  ///
  /// 内部吞掉所有异常：记不上账绝不能影响请求本身的成败。
  void _reportUsage(HttpResponse resp) {
    if (onUsage == null || !resp.isSuccess) return;
    try {
      final decoded = resp.json;
      if (decoded is! Map) return;
      onUsage!(_extractUsage(decoded));
    } catch (_) {
      // 见上：记账是旁路，不是请求的一部分
    }
  }

  ChatResponse _parseResponse(HttpResponse resp, int attempt) {
    if (!resp.isSuccess) {
      throw _classifyHttpError(resp);
    }

    final decoded = resp.json;
    if (decoded is! Map) {
      throw LlmException(
        LlmErrorKind.badResponse,
        '无法解析响应 JSON',
        statusCode: resp.statusCode,
        rawBody: _truncate(resp.body),
      );
    }

    final spec = config.spec;
    final text = switch (spec?.protocol) {
      LlmProtocol.anthropic => _extractAnthropicText(decoded),
      LlmProtocol.gemini => _extractGeminiText(decoded),
      _ => _extractOpenAiText(decoded),
    };

    // 非流式也要认工具调用，否则 `chat()` 在"模型决定查题库的那一轮"
    // 会以"响应里没有文本内容"报错 —— 与流式下那个坑是同一个。
    final toolCalls = spec?.protocol == LlmProtocol.openAiCompatible
        ? _extractOpenAiToolCalls(decoded)
        : const <ToolCall>[];

    if ((text == null || text.trim().isEmpty) && toolCalls.isEmpty) {
      throw LlmException(
        LlmErrorKind.badResponse,
        '响应里没有文本内容',
        statusCode: resp.statusCode,
        rawBody: _truncate(resp.body),
      );
    }

    final usage = _extractUsage(decoded);

    return ChatResponse(
      text: text ?? '',
      usage: usage,
      providerId: config.providerId,
      attempts: attempt,
      finishReason: _extractFinishReason(decoded, spec?.protocol),
      toolCalls: toolCalls,
    );
  }

  /// 取出停止原因，只用来判断"是不是被截断了"（见 [ChatResponse.truncated]）。
  ///
  /// 三家字段名不同；取不到就返回 null —— 宁可漏报截断，也不要凭空报警。
  String? _extractFinishReason(
    Map<dynamic, dynamic> j,
    LlmProtocol? protocol,
  ) {
    switch (protocol) {
      case LlmProtocol.anthropic:
        return j['stop_reason']?.toString();
      case LlmProtocol.gemini:
        final candidates = j['candidates'];
        if (candidates is! List || candidates.isEmpty) return null;
        final first = candidates.first;
        if (first is! Map) return null;
        return first['finishReason']?.toString();
      default:
        final choices = j['choices'];
        if (choices is! List || choices.isEmpty) return null;
        final first = choices.first;
        if (first is! Map) return null;
        final r = first['finish_reason'];
        // 老版 completions 用 stop_reason
        return (r ?? first['stop_reason'])?.toString();
    }
  }

  String? _extractOpenAiText(Map<dynamic, dynamic> j) {
    final choices = j['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final first = choices.first;
    if (first is! Map) return null;
    final message = first['message'];
    if (message is Map) {
      final content = message['content'];
      if (content is String) return content;
      // 部分模型把内容拆成数组
      if (content is List) {
        return content
            .whereType<Map<Object?, Object?>>()
            .map((p) => p['text']?.toString() ?? '')
            .join();
      }
    }
    // 兼容 text 字段（旧版 completions）
    final text = first['text'];
    return text?.toString();
  }

  /// 非流式响应里的工具调用（`choices[0].message.tool_calls`）。
  ///
  /// 参数是**完整**的 JSON 字符串，不像流式那样需要拼接。
  List<ToolCall> _extractOpenAiToolCalls(Map<dynamic, dynamic> j) {
    final choices = j['choices'];
    if (choices is! List || choices.isEmpty) return const [];
    final first = choices.first;
    if (first is! Map) return const [];
    final message = first['message'];
    if (message is! Map) return const [];
    final calls = message['tool_calls'];
    if (calls is! List) return const [];

    final out = <ToolCall>[];
    for (final raw in calls) {
      if (raw is! Map) continue;
      final fn = raw['function'];
      if (fn is! Map) continue;
      // 名字是唯一必须有的东西：没有它连"哪个工具"都不知道，
      // 而参数错了至少还能报"缺哪个参数"。
      final name = fn['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      out.add(ToolCall(
        id: raw['id']?.toString() ?? '',
        name: name,
        arguments: fn['arguments']?.toString() ?? '',
      ));
    }
    return out;
  }

  String? _extractAnthropicText(Map<dynamic, dynamic> j) {
    final content = j['content'];
    if (content is! List) return null;
    return content
        .whereType<Map<Object?, Object?>>()
        .where((b) => b['type'] == 'text')
        .map((b) => b['text']?.toString() ?? '')
        .join();
  }

  String? _extractGeminiText(Map<dynamic, dynamic> j) {
    final candidates = j['candidates'];
    if (candidates is! List || candidates.isEmpty) return null;
    final first = candidates.first;
    if (first is! Map) return null;
    final content = first['content'];
    if (content is! Map) return null;
    final parts = content['parts'];
    if (parts is! List) return null;
    return parts
        .whereType<Map<Object?, Object?>>()
        .map((p) => p['text']?.toString() ?? '')
        .join();
  }

  LlmUsage _extractUsage(Map<dynamic, dynamic> j) {
    final u = j['usage'];
    if (u is! Map) {
      // Gemini 用 usageMetadata
      final m = j['usageMetadata'];
      if (m is Map) {
        final inTok = (m['promptTokenCount'] as num?)?.toInt() ?? 0;
        final outTok = (m['candidatesTokenCount'] as num?)?.toInt() ?? 0;
        return _usage(inTok, outTok);
      }
      return LlmUsage(model: config.model);
    }
    final inTok = (u['prompt_tokens'] as num?)?.toInt() ??
        (u['input_tokens'] as num?)?.toInt() ??
        0;
    final outTok = (u['completion_tokens'] as num?)?.toInt() ??
        (u['output_tokens'] as num?)?.toInt() ??
        0;
    return _usage(inTok, outTok);
  }

  LlmUsage _usage(int inTok, int outTok) => LlmUsage(
        inputTokens: inTok,
        outputTokens: outTok,
        model: config.model,
        costYuan: LlmPricing.estimate(
          model: config.model,
          inputTokens: inTok,
          outputTokens: outTok,
        ),
      );

  // ───────────────────────────────────────────────────────────────────────
  // 错误分类
  // ───────────────────────────────────────────────────────────────────────

  LlmException _classifyHttpError(HttpResponse resp) {
    final code = resp.statusCode;
    final body = resp.body.toLowerCase();

    // 服务商自己说的话（有就带上）
    final pm = _providerMessage(resp.body);
    final tail = pm == null ? '' : '：$pm';

    // 先看业务错误码（很多国产服务商用 200 之外的码 + 特定 message）
    if (body.contains('insufficient') ||
        body.contains('quota') ||
        body.contains('balance') ||
        body.contains('余额') ||
        body.contains('欠费')) {
      return LlmException(
        LlmErrorKind.insufficientBalance,
        '余额或配额不足$tail',
        statusCode: code,
        rawBody: _truncate(resp.body),
      );
    }

    if (body.contains('rate limit') ||
        body.contains('too many requests') ||
        body.contains('频率')) {
      return LlmException(
        LlmErrorKind.rateLimited,
        '触发频率限制$tail',
        statusCode: code,
        rawBody: _truncate(resp.body),
      );
    }

    return switch (code) {
      401 || 403 => LlmException(
          LlmErrorKind.invalidKey,
          'API Key 无效或无权访问$tail',
          statusCode: code,
          rawBody: _truncate(resp.body),
        ),
      402 => LlmException(
          LlmErrorKind.insufficientBalance,
          '需要付费$tail',
          statusCode: code,
          rawBody: _truncate(resp.body),
        ),
      404 => LlmException(
          LlmErrorKind.modelNotFound,
          '模型或接口不存在$tail',
          statusCode: code,
          rawBody: _truncate(resp.body),
        ),
      429 => LlmException(
          LlmErrorKind.rateLimited,
          '请求过于频繁$tail',
          statusCode: code,
          rawBody: _truncate(resp.body),
        ),
      >= 500 => LlmException(
          LlmErrorKind.serverError,
          '服务商返回 $code$tail',
          statusCode: code,
          rawBody: _truncate(resp.body),
        ),
      400 => LlmException(
          LlmErrorKind.badRequest,
          // ⚠️ 一定要带上服务商的原话。
          //
          // 早先这里只有"请求不合法"，于是"max_tokens 超出上限"这种**一眼
          // 能修**的问题，用户（和当时的我）只能靠手写一个原始请求去猜。
          // 服务商的 message 才是可操作的那部分。
          '请求不合法$tail',
          statusCode: code,
          rawBody: _truncate(resp.body),
        ),
      _ => LlmException(
          LlmErrorKind.unknown,
          'HTTP $code$tail',
          statusCode: code,
          rawBody: _truncate(resp.body),
        ),
    };
  }

  /// 从服务商的错误响应里挖出"人话"。
  ///
  /// 各家形状高度一致 —— OpenAI / 智谱 / Gemini / Anthropic 都是
  /// `{"error":{"message":"...","code":"..."}}`，少数是顶层 `message`。
  /// 取不到就返回 null：**不要把整段 body 塞进面向用户的消息**，
  /// 那可能是几百字的 HTML 网关页。
  static String? _providerMessage(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final e = j['error'];
        if (e is Map) {
          final m = e['message']?.toString().trim();
          if (m != null && m.isNotEmpty) return _short(m);
        }
        final m = j['message']?.toString().trim();
        if (m != null && m.isNotEmpty) return _short(m);
      }
    } catch (_) {
      // 不是 JSON（网关 HTML、纯文本）：不猜
    }
    return null;
  }

  static String _short(String s) => s.length <= 200 ? s : '${s.substring(0, 200)}…';

  static LlmErrorKind _classifyTransport(HttpTransportException e) {
    final m = e.message.toLowerCase();
    if (m.contains('timeout') || m.contains('超时')) return LlmErrorKind.timeout;
    return LlmErrorKind.network;
  }

  static String _truncate(String s) =>
      s.length <= 500 ? s : '${s.substring(0, 500)}…';
}

/// 流式解析过程中累积的状态。纯数据袋，没有行为 ——
/// 行为都写在 [LlmClient._consumeFrame] 里，因为那里才拿得到协议上下文。
class _StreamAcc {
  /// 已经吐出去的完整文本。
  final StringBuffer text = StringBuffer();

  /// 是否吐过至少一个字。
  ///
  /// 它决定"中途出错能不能重试"：吐过了就不能（见 [LlmClient.chatStream]
  /// 的方法头注释）。每次重试都会新建一个 [_StreamAcc]，
  /// 所以这个标志天然是按尝试次数隔离的。
  bool gotText = false;

  String finishReason = '';

  /// 拿到的最新用量。**可能一直是零** —— 见 [LlmClient.chatStream]
  /// 方法头注释第二条（部分服务商的流式响应根本不带 usage）。
  LlmUsage usage = const LlmUsage();

  /// 最后见过的原始载荷，仅用于出错时的诊断。
  String lastPayload = '';

  /// 是否见过终止标记。目前只用于将来区分"服务商正常收尾"与"连接被掐断"，
  /// 暂不参与判定 —— 留着是因为这个信息只有在这里能拿到，
  /// 事后无法从别处补。
  bool sawDone = false;

  /// 工具调用分片，按服务商给的 `index` 归位。
  ///
  /// ⚠️ 它**不参与"能不能重试"的判定**（对比 [gotText]）：工具分片
  /// 用户一个字都没看见，中途失败时整条重来是安全的。而每次重试都会
  /// 新建一个 [_StreamAcc]，所以残留分片不会串到下一次尝试里。
  final Map<int, _ToolCallAcc> toolCalls = {};

  /// 把分片拼成完整的工具调用列表。
  ///
  /// 只在**整条流结束后**调用一次 —— 参数 JSON 是被切成很多片送来的，
  /// 中途任何一片都不构成合法的 JSON。
  List<ToolCall> buildToolCalls() {
    if (toolCalls.isEmpty) return const [];
    final keys = toolCalls.keys.toList()..sort();
    final out = <ToolCall>[];
    for (final k in keys) {
      final s = toolCalls[k]!;
      // 名字为空 = 这一片什么都没要。这种槽位丢掉比送出去好：
      // 一个无名调用只会换来一句"未知函数"。
      if (s.name.isEmpty) continue;
      out.add(ToolCall(
        // 服务商没给 id 时补一个确定性的占位。补而不是丢，是因为
        // `tool_call_id` 是"请求 ← → 结果"的唯一配对依据：缺了它，
        // 我们回灌结果时无法告诉模型"这是你要的那个"。占位符在
        // 我们自己的请求体内是自洽的（assistant 与 tool 两条消息用同一个），
        // 宽松的服务商能正常处理，严格的服务商本来也不会漏发 id。
        id: s.id.isEmpty ? 'call_$k' : s.id,
        name: s.name,
        arguments: s.arguments.toString(),
      ));
    }
    return out;
  }
}

/// 单个工具调用的分片累积槽。
class _ToolCallAcc {
  /// 调用 id。流式下**只在第一片里出现一次**，后续分片没有它。
  String id = '';

  /// 函数名。同样只出现在第一片。
  String name = '';

  /// 参数 JSON 的**字符串分片**，按到达顺序拼接。
  ///
  /// 用 StringBuffer 而不是尝试逐片解析：`{"kp":` 这样的半截 JSON
  /// 永远解析不出来，逐片解析只会得到一串"模型乱填参数"的假报错。
  final StringBuffer arguments = StringBuffer();
}
