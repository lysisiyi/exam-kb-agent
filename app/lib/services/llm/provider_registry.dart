/// LLM 服务商注册表。
///
/// ## 设计要点
///
/// 1. **80% 的工程量集中在一个客户端上。** OpenAI 兼容协议已成事实标准，
///    DeepSeek / 通义 / 智谱 / Moonshot / Ollama / 自建代理全都兼容，
///    因此它们共用同一套请求逻辑，只有 base_url 与默认模型不同。
///    只有 Anthropic 与 Gemini 需要单独的协议适配。
///
/// 2. **用户只需要粘贴一个 API Key。** base_url 与默认模型都有预置值，
///    UI 上选服务商就自动填好，降低配置门槛（考研学生大多不知道什么是 base_url）。
///
/// 3. **可测试。** 这个文件是纯数据，不依赖网络，可以完整单测。
library;

/// 请求协议类型。
enum LlmProtocol {
  /// OpenAI 兼容的 `/chat/completions`。绝大多数服务商走这个。
  openAiCompatible,

  /// Anthropic Messages API（`x-api-key` 头 + 不同的请求体结构）。
  anthropic,

  /// Google Gemini generateContent（API Key 走 query 参数）。
  gemini,
}

/// 认证方式。
enum LlmAuthStyle {
  /// `Authorization: Bearer <key>`
  bearer,

  /// `x-api-key: <key>`
  xApiKey,

  /// `?key=<key>` 查询参数
  queryParam,

  /// 无需认证（本地 Ollama）
  none,
}

/// 一个服务商的静态规格。
class ProviderSpec {
  /// 内部 id，用于存储与展示。
  final String id;

  /// 展示名（中文优先，用户看得懂）。
  final String label;

  final String baseUrl;
  final LlmProtocol protocol;
  final LlmAuthStyle auth;

  /// 预置模型名。UI 上作为默认值，用户可改。
  final String defaultModel;

  /// 该服务商常见的可选模型（UI 下拉用）。
  final List<String> suggestedModels;

  /// 推荐度：`recommended`（标注质量与性价比都不错）/
  /// `acceptable`（能用）/ `discouraged`（参数量小，标注准确率会明显下降）。
  ///
  /// ⚠️ 这个分级是有实际后果的：对 `discouraged` 的模型，
  /// 标注引擎会把置信度门槛从 0.7 提到 0.85，让更多结果进人工确认队列。
  /// 因为弱模型的"高置信度"往往是虚高的。
  final ModelTier tier;

  /// 是否需要 API Key。本地 Ollama 为 false。
  final bool requiresApiKey;

  /// 配置指引（告诉用户去哪拿 Key）。UI 上显示。
  final String? helpUrl;

  /// 一句话说明，帮用户选。
  final String note;

  const ProviderSpec({
    required this.id,
    required this.label,
    required this.baseUrl,
    required this.protocol,
    required this.auth,
    required this.defaultModel,
    this.suggestedModels = const [],
    this.tier = ModelTier.recommended,
    this.requiresApiKey = true,
    this.helpUrl,
    this.note = '',
  });

  bool get isOpenAiCompatible => protocol == LlmProtocol.openAiCompatible;
}

/// 模型质量分级。
enum ModelTier {
  /// 推荐：标注质量与成本平衡好。
  recommended,

  /// 可用：质量略降，但能接受。
  acceptable,

  /// 不推荐：参数量小，知识点标注准确率会明显下降。
  discouraged;

  /// 该分级对应的置信度门槛。
  ///
  /// 弱模型的"高置信度"往往虚高，所以门槛更高，让更多结果进人工确认。
  double get confidenceThreshold => switch (this) {
        ModelTier.recommended => 0.70,
        ModelTier.acceptable => 0.78,
        ModelTier.discouraged => 0.85,
      };

  String get label => switch (this) {
        ModelTier.recommended => '推荐',
        ModelTier.acceptable => '可用',
        ModelTier.discouraged => '不推荐',
      };
}

/// 全部服务商。
abstract final class LlmProviders {
  const LlmProviders._();

  /// 服务商列表。
  ///
  /// 排序即 UI 展示顺序 —— 国内可直连、性价比高的放前面，
  /// 因为目标用户（考研学生）大多在国内且预算敏感。
  static const List<ProviderSpec> all = [
    ProviderSpec(
      id: 'deepseek',
      label: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com/v1',
      protocol: LlmProtocol.openAiCompatible,
      auth: LlmAuthStyle.bearer,
      defaultModel: 'deepseek-chat',
      suggestedModels: ['deepseek-chat', 'deepseek-reasoner'],
      note: '国内直连，中文与数学推理表现好，价格低',
      helpUrl: 'https://platform.deepseek.com/api_keys',
    ),
    ProviderSpec(
      id: 'qwen',
      label: '通义千问',
      baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      protocol: LlmProtocol.openAiCompatible,
      auth: LlmAuthStyle.bearer,
      defaultModel: 'qwen-plus',
      suggestedModels: ['qwen-plus', 'qwen-max', 'qwen-turbo'],
      note: '国内直连，阿里云百炼平台',
      helpUrl: 'https://bailian.console.aliyun.com/',
    ),
    ProviderSpec(
      id: 'zhipu',
      label: '智谱 GLM',
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      protocol: LlmProtocol.openAiCompatible,
      auth: LlmAuthStyle.bearer,
      defaultModel: 'glm-4-flash',
      suggestedModels: ['glm-4-flash', 'glm-4-air', 'glm-4-plus'],
      note: '国内直连，glm-4-flash 有免费额度',
      helpUrl: 'https://open.bigmodel.cn/usercenter/apikeys',
    ),
    ProviderSpec(
      id: 'openai',
      label: 'OpenAI',
      baseUrl: 'https://api.openai.com/v1',
      protocol: LlmProtocol.openAiCompatible,
      auth: LlmAuthStyle.bearer,
      defaultModel: 'gpt-4o-mini',
      suggestedModels: ['gpt-4o-mini', 'gpt-4o', 'gpt-4.1-mini'],
      note: '需要海外网络环境',
      helpUrl: 'https://platform.openai.com/api-keys',
    ),
    ProviderSpec(
      id: 'anthropic',
      label: 'Claude',
      baseUrl: 'https://api.anthropic.com/v1',
      protocol: LlmProtocol.anthropic,
      auth: LlmAuthStyle.xApiKey,
      defaultModel: 'claude-3-5-haiku-20241022',
      suggestedModels: [
        'claude-3-5-haiku-20241022',
        'claude-3-5-sonnet-20241022',
      ],
      note: '需要海外网络环境；长文本理解强',
      helpUrl: 'https://console.anthropic.com/settings/keys',
    ),
    ProviderSpec(
      id: 'gemini',
      label: 'Google Gemini',
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      protocol: LlmProtocol.gemini,
      auth: LlmAuthStyle.queryParam,
      defaultModel: 'gemini-1.5-flash',
      suggestedModels: ['gemini-1.5-flash', 'gemini-1.5-pro', 'gemini-2.0-flash'],
      note: '需要海外网络环境；有免费额度',
      helpUrl: 'https://aistudio.google.com/app/apikey',
    ),
    ProviderSpec(
      id: 'moonshot',
      label: 'Moonshot Kimi',
      baseUrl: 'https://api.moonshot.cn/v1',
      protocol: LlmProtocol.openAiCompatible,
      auth: LlmAuthStyle.bearer,
      defaultModel: 'moonshot-v1-8k',
      suggestedModels: ['moonshot-v1-8k', 'moonshot-v1-32k'],
      note: '国内直连，长上下文',
      helpUrl: 'https://platform.moonshot.cn/console/api-keys',
    ),
    ProviderSpec(
      id: 'ollama',
      label: '本地 Ollama',
      baseUrl: 'http://localhost:11434/v1',
      protocol: LlmProtocol.openAiCompatible,
      auth: LlmAuthStyle.none,
      defaultModel: 'qwen2.5:7b',
      suggestedModels: ['qwen2.5:7b', 'qwen2.5:14b', 'llama3.1:8b'],
      tier: ModelTier.discouraged,
      requiresApiKey: false,
      note: '完全离线、零成本；但本地小模型标注准确率偏低，会更多进人工确认',
    ),
    ProviderSpec(
      id: 'custom',
      label: '自定义 / 代理',
      baseUrl: '',
      protocol: LlmProtocol.openAiCompatible,
      auth: LlmAuthStyle.bearer,
      defaultModel: '',
      note: '自建代理、OneAPI 网关、或任何 OpenAI 兼容端点',
    ),
  ];

  /// 按 id 查找。找不到返回 null。
  static ProviderSpec? byId(String id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 需要用户填 base_url 的服务商（即 `custom`）。
  static List<ProviderSpec> get requiringBaseUrl =>
      all.where((p) => p.baseUrl.isEmpty).toList();

  /// 需要用户填模型名的服务商。
  static List<ProviderSpec> get requiringModel =>
      all.where((p) => p.defaultModel.isEmpty).toList();

  /// 推荐给新用户的服务商（国内直连 + 性价比）。
  static ProviderSpec get defaultProvider => all.first;
}

/// 一次标注请求使用的模型配置。
class LlmConfig {
  final String providerId;
  final String apiKey;

  /// 覆盖默认 base_url（custom 服务商必填）。
  final String? baseUrlOverride;

  /// 覆盖默认模型名。
  final String? modelOverride;

  const LlmConfig({
    required this.providerId,
    required this.apiKey,
    this.baseUrlOverride,
    this.modelOverride,
  });

  ProviderSpec? get spec => LlmProviders.byId(providerId);

  String get baseUrl {
    final o = baseUrlOverride?.trim();
    if (o != null && o.isNotEmpty) return _stripTrailingSlash(o);
    return spec?.baseUrl ?? '';
  }

  String get model {
    final o = modelOverride?.trim();
    if (o != null && o.isNotEmpty) return o;
    return spec?.defaultModel ?? '';
  }

  ModelTier get tier => spec?.tier ?? ModelTier.recommended;

  /// 该模型能用于标注时的置信度门槛。
  double get confidenceThreshold => tier.confidenceThreshold;

  /// 配置是否完整到可以发请求。
  (bool ok, String? problem) validate() {
    final s = spec;
    if (s == null) return (false, '未知的服务商：$providerId');
    if (baseUrl.isEmpty) return (false, '缺少 API 地址（base_url）');
    if (!baseUrl.startsWith('http')) {
      return (false, 'API 地址必须以 http(s):// 开头');
    }
    if (s.requiresApiKey && apiKey.trim().isEmpty) {
      return (false, '缺少 API Key');
    }
    if (model.isEmpty) return (false, '缺少模型名称');
    return (true, null);
  }

  static String _stripTrailingSlash(String s) =>
      s.endsWith('/') ? s.substring(0, s.length - 1) : s;

  /// 构造请求头。
  Map<String, String> headers() {
    final h = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    final s = spec;
    if (s == null) return h;

    switch (s.auth) {
      case LlmAuthStyle.bearer:
        if (apiKey.isNotEmpty) h['Authorization'] = 'Bearer $apiKey';
        break;
      case LlmAuthStyle.xApiKey:
        if (apiKey.isNotEmpty) h['x-api-key'] = apiKey;
        // Anthropic 要求显式声明 API 版本
        h['anthropic-version'] = '2023-06-01';
        break;
      case LlmAuthStyle.queryParam:
      case LlmAuthStyle.none:
        break; // 走 query 参数或在 URL 里处理
    }
    return h;
  }
}
