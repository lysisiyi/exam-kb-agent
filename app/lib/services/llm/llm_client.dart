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

/// HTTP 适配器。生产用 Dio，测试用假实现。
abstract class HttpAdapter {
  Future<HttpResponse> send(HttpRequest request);
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
        LlmErrorKind.badResponse => '模型返回的内容无法解析，已记入待人工确认',
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
}

/// 粗略的价目表（元 / 百万 token），用于给用户**估算**花费。
///
/// ⚠️ 价格会变，且各服务商常有折扣/阶梯。这里只是量级参考，
/// UI 上必须标注"估算"。**不要**用它做任何计费决策。
abstract final class LlmPricing {
  const LlmPricing._();

  /// 模型名（小写包含匹配）→ (输入价, 输出价)，单位：元/百万 token。
  static const Map<String, (double, double)> _table = {
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
    'moonshot-v1-8k': (12.0, 12.0),
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

/// 一次对话请求。
class ChatRequest {
  final String system;
  final String user;

  /// 是否要求模型输出 JSON。
  ///
  /// 不同服务商的支持方式不同（见 [LlmClient._buildBody]），
  /// 不支持时靠 [RobustJson] 兜底解析。
  final bool jsonMode;

  /// 温度。标注任务用低温度（0.1）保证稳定。
  final double temperature;

  /// 最大输出 token。
  final int? maxTokens;

  const ChatRequest({
    required this.system,
    required this.user,
    this.jsonMode = false,
    this.temperature = 0.1,
    this.maxTokens,
  });
}

/// 一次对话响应。
class ChatResponse {
  final String text;
  final LlmUsage usage;

  /// 命中的服务商与模型，便于审计。
  final String providerId;

  /// 尝试了几次（含首次）。
  final int attempts;

  const ChatResponse({
    required this.text,
    required this.usage,
    this.providerId = '',
    this.attempts = 1,
  });
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
        final parsed = _parseResponse(resp, attempt);
        if (onUsage != null) onUsage!(parsed.usage);
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

  // ───────────────────────────────────────────────────────────────────────
  // 请求构造
  // ───────────────────────────────────────────────────────────────────────

  HttpRequest _buildRequest(ChatRequest req) {
    final spec = config.spec;
    if (spec == null) {
      throw const LlmException(LlmErrorKind.invalidKey, '未知的服务商');
    }

    return switch (spec.protocol) {
      LlmProtocol.openAiCompatible => _buildOpenAi(req, spec),
      LlmProtocol.anthropic => _buildAnthropic(req),
      LlmProtocol.gemini => _buildGemini(req),
    };
  }

  /// OpenAI 兼容（覆盖 DeepSeek / 通义 / 智谱 / Moonshot / OpenAI / Ollama / 自建）。
  HttpRequest _buildOpenAi(ChatRequest req, ProviderSpec spec) {
    final body = <String, dynamic>{
      'model': config.model,
      'messages': [
        {'role': 'system', 'content': req.system},
        {'role': 'user', 'content': req.user},
      ],
      'temperature': req.temperature,
      'stream': false,
    };
    if (req.maxTokens != null) body['max_tokens'] = req.maxTokens;

    // JSON mode 的支持面很广但不统一：
    // - OpenAI / DeepSeek / 通义 / 智谱 支持 response_format
    // - Ollama 与部分自建代理不认这个字段，传了可能报 400
    //
    // 策略：只在"已知支持"的服务商上传，其余靠 prompt 约束 + RobustJson 兜底。
    const supportsJsonMode = {'openai', 'deepseek', 'qwen', 'zhipu', 'moonshot'};
    if (req.jsonMode && supportsJsonMode.contains(spec.id)) {
      body['response_format'] = {'type': 'json_object'};
    }

    return HttpRequest(
      url: '${config.baseUrl}/chat/completions',
      headers: config.headers(),
      body: jsonEncode(body),
    );
  }

  /// Anthropic Messages API。
  HttpRequest _buildAnthropic(ChatRequest req) {
    // Anthropic 把 system 放在顶层字段而非 messages 里
    final body = <String, dynamic>{
      'model': config.model,
      'system': req.system,
      'messages': [
        {'role': 'user', 'content': req.user},
      ],
      'temperature': req.temperature,
      'max_tokens': req.maxTokens ?? 4096,
    };
    return HttpRequest(
      url: '${config.baseUrl}/messages',
      headers: config.headers(),
      body: jsonEncode(body),
    );
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
        {
          'role': 'user',
          'parts': [
            {'text': req.user},
          ],
        },
      ],
      'generationConfig': {
        'temperature': req.temperature,
        if (req.maxTokens != null) 'maxOutputTokens': req.maxTokens,
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

  // ───────────────────────────────────────────────────────────────────────
  // 响应解析
  // ───────────────────────────────────────────────────────────────────────

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

    if (text == null || text.trim().isEmpty) {
      throw LlmException(
        LlmErrorKind.badResponse,
        '响应里没有文本内容',
        statusCode: resp.statusCode,
        rawBody: _truncate(resp.body),
      );
    }

    final usage = _extractUsage(decoded);

    return ChatResponse(
      text: text,
      usage: usage,
      providerId: config.providerId,
      attempts: attempt,
    );
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

    // 先看业务错误码（很多国产服务商用 200 之外的码 + 特定 message）
    if (body.contains('insufficient') ||
        body.contains('quota') ||
        body.contains('balance') ||
        body.contains('余额') ||
        body.contains('欠费')) {
      return LlmException(
        LlmErrorKind.insufficientBalance,
        '余额或配额不足',
        statusCode: code,
        rawBody: _truncate(resp.body),
      );
    }

    if (body.contains('rate limit') ||
        body.contains('too many requests') ||
        body.contains('频率')) {
      return LlmException(
        LlmErrorKind.rateLimited,
        '触发频率限制',
        statusCode: code,
        rawBody: _truncate(resp.body),
      );
    }

    return switch (code) {
      401 || 403 => LlmException(
          LlmErrorKind.invalidKey,
          'API Key 无效或无权访问',
          statusCode: code,
          rawBody: _truncate(resp.body),
        ),
      402 => LlmException(
          LlmErrorKind.insufficientBalance,
          '需要付费',
          statusCode: code,
          rawBody: _truncate(resp.body),
        ),
      404 => LlmException(
          LlmErrorKind.modelNotFound,
          '模型或接口不存在',
          statusCode: code,
          rawBody: _truncate(resp.body),
        ),
      429 => LlmException(
          LlmErrorKind.rateLimited,
          '请求过于频繁',
          statusCode: code,
          rawBody: _truncate(resp.body),
        ),
      >= 500 => LlmException(
          LlmErrorKind.serverError,
          '服务商返回 $code',
          statusCode: code,
          rawBody: _truncate(resp.body),
        ),
      400 => LlmException(
          LlmErrorKind.badRequest,
          '请求不合法',
          statusCode: code,
          rawBody: _truncate(resp.body),
        ),
      _ => LlmException(
          LlmErrorKind.unknown,
          'HTTP $code',
          statusCode: code,
          rawBody: _truncate(resp.body),
        ),
    };
  }

  static LlmErrorKind _classifyTransport(HttpTransportException e) {
    final m = e.message.toLowerCase();
    if (m.contains('timeout') || m.contains('超时')) return LlmErrorKind.timeout;
    return LlmErrorKind.network;
  }

  static String _truncate(String s) =>
      s.length <= 500 ? s : '${s.substring(0, 500)}…';
}
