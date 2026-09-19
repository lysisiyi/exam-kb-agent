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

/// 某个能力"有没有"。
///
/// 三态而不是布尔，是因为**"我们不知道"和"没有"必须分开**：
/// - [no]：确定不支持 → 直接拦住，别让用户白花 100 次调用的钱
/// - [unknown]：无法确认（自建代理、我们不认识的模型名）→ 允许继续但要提示
/// - [yes]：确定支持
///
/// 把 [unknown] 当成 [no] 会把自建网关的用户挡在门外；
/// 把 [unknown] 当成 [yes] 会让选了纯文本模型的用户白花钱。
enum VisionSupport {
  yes,
  no,
  unknown;

  String get label => switch (this) {
        VisionSupport.yes => '支持',
        VisionSupport.no => '不支持',
        VisionSupport.unknown => '无法确认',
      };
}

/// 视觉能力判定表。
///
/// ## 为什么按"模型名片段"匹配而不是维护一张完整模型清单
///
/// 服务商上新模型的速度远快于我们发版的速度。用**片段匹配**（小写包含）
/// 的代价是可能漏判，收益是不会因为一个没听过的新模型就判定"不支持" ——
/// 漏判的后果是提示"无法确认"，误判的后果是让用户白花钱。
/// 两害相权，宁可漏判。
abstract final class LlmVision {
  const LlmVision._();

  /// 各服务商下**已知**支持图片输入的模型名片段。
  ///
  /// ⚠️ 不在这里出现的模型一律是 [VisionSupport.unknown]，不是 [no]。
  static const Map<String, List<String>> modelPatterns = {
    'openai': ['gpt-4o', 'gpt-4.1', 'gpt-4-turbo', 'gpt-4-vision'],
    'anthropic': ['claude-3', 'claude-4', 'claude-sonnet', 'claude-opus'],
    'gemini': ['gemini-1.5', 'gemini-2', 'gemini-pro-vision'],
    'qwen': ['-vl'],
    'zhipu': ['glm-4v'],
    'moonshot': ['vision', 'kimi-latest'],
    'ollama': ['llava', 'vision', 'minicpm-v', 'bakllava', 'moondream'],
  };

  /// 每个服务商里"要换成哪个模型才能做批量导入"的建议。
  ///
  /// 用途：用户在 DeepSeek 上点批量导入时，提示不能只说"不行"，
  /// 要告诉他具体改什么。
  static const Map<String, List<String>> suggestedVisionModels = {
    'openai': ['gpt-4o-mini', 'gpt-4o'],
    'anthropic': ['claude-3-5-sonnet-20241022', 'claude-3-5-haiku-20241022'],
    'gemini': ['gemini-1.5-flash', 'gemini-2.0-flash'],
    'qwen': ['qwen-vl-max', 'qwen-vl-plus'],
    'zhipu': ['glm-4v-flash', 'glm-4v-plus'],
    'moonshot': ['moonshot-v1-8k-vision-preview', 'kimi-latest'],
    'ollama': ['llava', 'qwen2.5vl'],
  };

  /// 整个服务商**都没有**视觉模型。
  ///
  /// 这一条比逐模型匹配更可靠：DeepSeek 的公开模型（deepseek-chat /
  /// deepseek-reasoner）都是纯文本的，逐个去猜模型名没有意义。
  static const Set<String> providersWithoutVision = {'deepseek'};
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

  /// 该服务商是否**能**直接接收 PDF（不用先转成图片）。
  ///
  /// 只有 Anthropic（`document` block）与 Gemini（`inline_data` +
  /// `application/pdf`）可以。OpenAI 的 `/chat/completions` 不行 ——
  /// 那需要走 Files + Responses API，V1 不做。
  final bool acceptsPdf;

  /// 单次请求的**输出上限**（token）。null = 服务商没这个硬限制。
  ///
  /// ## 为什么必须当成数据放在这里
  ///
  /// 真机实测（2026-09-18，智谱 `glm-4v-flash`）：
  ///
  /// ```
  /// {max_tokens: 8192} → 400 {"error":{"code":"1210",
  ///   "message":"max_tokens参数非法：限制数值范围[1,1024]"}}
  /// ```
  ///
  /// 而批量导入写死了 `maxTokens: 8192`（为了一页多题留足输出空间）。
  /// 两者一撞，**智谱上的批量导入一次都跑不通**，用户只看到"请求不合法"。
  /// 同一家的文本模型 `glm-4-flash` 收 8192 没问题 —— 所以这个限制是
  /// **按模型**来的，只能当数据描述 + 用实测校准：
  ///
  /// | 服务商 | 模型 | 上限 | 实测 |
  /// |---|---|---|---|
  /// | zhipu | `glm-4v-flash` | **1024** | 8192 → 400 code 1210 |
  /// | zhipu | `glm-4-flash` | ≥ 8192 | 4096 / 8192 均通过 |
  ///
  /// 取最保守值：宁可输出空间小一点，也不能让整个服务商用不了。
  /// 代价如实告诉用户 —— 见 `estimateIngest` 的 `maxOutputTokens` 提示。
  final int? maxOutputTokens;

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
    this.acceptsPdf = false,
    this.maxOutputTokens,
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
  ///
  /// ## ⚠️ 这些数字是**实测**出来的，不是拍的
  ///
  /// 初版写的是 0.70 / 0.78 / 0.85 —— 纯属估计。T17 用真实 API 跑了
  /// 67 道题（四个金标准集）后，置信度校准结果如下：
  ///
  /// | 自报置信度 | 样本 | 实际准确率 |
  /// |---|---|---|
  /// | [0.80, 0.90) | 5 | **40.0%** |
  /// | [0.90, 0.95) | 4 | 75.0% |
  /// | [0.95, 1.00] | 57 | **96.5%** |
  ///
  /// 结论有两条：
  /// 1. **自报置信度是校准的** —— 0.90 以下准确率只有 40%，
  ///    0.95 以上 96.5%，区分度明确。所以门禁这个设计成立。
  /// 2. **原门槛低了约 0.2** —— 0.70 时 67 题里只有 1 题进人工确认队列，
  ///    7 个错例只拦住 1 个（14%）；抬到 0.90 则拦 6 题（9% 的样本量）
  ///    就能捕获 4/7 个错例（57%）。用 9% 的人工确认换掉 43% 的静默错误，
  ///    这个交易是划算的。
  ///
  /// 复现：`python tools/data/calibrate_t17.py app/build/t17b_*.json`
  /// （样本量偏小，采集更多真实数据后应重新校准。）
  double get confidenceThreshold => switch (this) {
        ModelTier.recommended => 0.90,
        ModelTier.acceptable => 0.92,
        ModelTier.discouraged => 0.95,
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
      note: '国内直连，中文与数学推理表现好，价格低。⚠️ 纯文本模型，'
          '不能做批量导入（需要视觉模型）',
      helpUrl: 'https://platform.deepseek.com/api_keys',
    ),
    ProviderSpec(
      id: 'qwen',
      label: '通义千问',
      baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      protocol: LlmProtocol.openAiCompatible,
      auth: LlmAuthStyle.bearer,
      defaultModel: 'qwen-plus',
      suggestedModels: [
        'qwen-plus', 'qwen-max', 'qwen-turbo',
        // 视觉模型：批量导入要用这几个（模型名里带 vl）
        'qwen-vl-max', 'qwen-vl-plus',
      ],
      note: '国内直连，阿里云百炼平台。批量导入请选带 vl 的视觉模型',
      helpUrl: 'https://bailian.console.aliyun.com/',
    ),
    ProviderSpec(
      id: 'zhipu',
      label: '智谱 GLM',
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      protocol: LlmProtocol.openAiCompatible,
      auth: LlmAuthStyle.bearer,
      defaultModel: 'glm-4-flash',
      suggestedModels: [
        'glm-4-flash', 'glm-4-air', 'glm-4-plus',
        // 视觉模型：批量导入要用这几个（模型名里带 4v）
        'glm-4v-flash', 'glm-4v-plus',
      ],
      note: '国内直连，glm-4-flash 有免费额度。批量导入请选带 4v 的视觉模型',
      helpUrl: 'https://open.bigmodel.cn/usercenter/apikeys',
      // 实测（2026-09-18）：glm-4v-flash 的 max_tokens 只接受 [1,1024]，
      // 发 8192 直接 400 code 1210；而同家的 glm-4-flash 收 8192 没问题。
      // 取最保守的 1024，否则智谱上的批量导入一次都跑不通。
      maxOutputTokens: 1024,
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
      note: '需要海外网络环境；长文本理解强。**批量导入推荐**（支持图片与 PDF）',
      helpUrl: 'https://console.anthropic.com/settings/keys',
      acceptsPdf: true,
    ),
    ProviderSpec(
      id: 'gemini',
      label: 'Google Gemini',
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      protocol: LlmProtocol.gemini,
      auth: LlmAuthStyle.queryParam,
      defaultModel: 'gemini-1.5-flash',
      suggestedModels: ['gemini-1.5-flash', 'gemini-1.5-pro', 'gemini-2.0-flash'],
      note: '需要海外网络环境；有免费额度。**批量导入性价比高**（支持图片与 PDF）',
      helpUrl: 'https://aistudio.google.com/app/apikey',
      acceptsPdf: true,
    ),
    ProviderSpec(
      id: 'moonshot',
      label: 'Moonshot Kimi',
      baseUrl: 'https://api.moonshot.cn/v1',
      protocol: LlmProtocol.openAiCompatible,
      auth: LlmAuthStyle.bearer,
      defaultModel: 'moonshot-v1-8k',
      suggestedModels: [
        'moonshot-v1-8k', 'moonshot-v1-32k',
        'moonshot-v1-8k-vision-preview', 'kimi-latest',
      ],
      note: '国内直连，长上下文。批量导入请选带 vision 的模型',
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

  // ───────────────────────────────────────────────────────────────────────
  // 视觉 / PDF 能力
  // ───────────────────────────────────────────────────────────────────────

  /// 当前"服务商 + 模型"能不能接收图片。
  ///
  /// 判据顺序（先粗后细，因为粗判据更可靠）：
  /// 1. 整个服务商没有视觉模型 → [VisionSupport.no]
  /// 2. 模型名命中已知视觉模型片段 → [VisionSupport.yes]
  /// 3. 其余 → [VisionSupport.unknown]（自建代理、我们不认识的新模型）
  VisionSupport get visionSupport {
    final s = spec;
    if (s == null) return VisionSupport.no;
    if (LlmVision.providersWithoutVision.contains(s.id)) {
      return VisionSupport.no;
    }
    final m = model.toLowerCase();
    if (m.isEmpty) return VisionSupport.unknown;
    final patterns = LlmVision.modelPatterns[s.id];
    if (patterns != null && patterns.any(m.contains)) {
      return VisionSupport.yes;
    }
    return VisionSupport.unknown;
  }

  /// 能不能把 PDF 原样发过去（而不是先转成图片）。
  ///
  /// PDF 支持是"协议级"的，所以先看服务商，再看模型是否至少能读图 ——
  /// 一个连图片都不认的模型，服务商支持 PDF 也没用。
  VisionSupport get pdfSupport {
    final s = spec;
    if (s == null) return VisionSupport.no;
    if (!s.acceptsPdf) return VisionSupport.no;
    if (visionSupport == VisionSupport.no) return VisionSupport.no;
    return VisionSupport.yes;
  }

  /// 能不能跑批量导入。返回 null 表示可以。
  ///
  /// [needPdf] 为 true 时，来源里包含 PDF，于是还要 PDF 能力。
  ///
  /// ## 为什么要把这件事**提前**判掉
  ///
  /// 批量导入一次可能有 100+ 个来源。如果配置不对却放它跑，
  /// 结果是 100 次调用全部失败 —— 用户等服务商报错等几分钟，
  /// 还可能为其中的成功部分付了钱。提前拦下来的成本是一次方法调用。
  String? visionBlockReason({bool needPdf = false}) {
    final s = spec;
    final label = s?.label ?? providerId;

    if (visionSupport == VisionSupport.no) {
      if (LlmVision.providersWithoutVision.contains(s?.id)) {
        return '「$label」提供的是纯文本模型，不能读图片，因此无法做批量导入。'
            '请换用支持视觉模型的服务商（Claude / Gemini / 通义 VL / 智谱 4V / Kimi 视觉版）。';
      }
      return '「$label」当前模型「$model」不支持图片输入，无法做批量导入。';
    }

    if (needPdf && pdfSupport == VisionSupport.no) {
      return '「$label」不支持直接发送 PDF（只有 Claude 与 Gemini 支持）。'
          '可以先把 PDF 导出成图片，或改用 Claude / Gemini。';
    }

    return null;
  }

  /// 配置可以跑但**并不确定**能跑通时的提醒。
  ///
  /// 返回 null 表示没有需要额外提醒的事。
  String? visionWarning({bool needPdf = false}) {
    if (visionBlockReason(needPdf: needPdf) != null) return null;

    if (visionSupport == VisionSupport.unknown) {
      final alt = LlmVision.suggestedVisionModels[spec?.id];
      final hint = (alt == null || alt.isEmpty)
          ? '请确认该模型支持图片输入。'
          : '已知可用的有：${alt.join('、')}。';
      return '无法确认模型「$model」是否支持图片输入 —— 若解析全部失败，'
          '请换模型。$hint';
    }
    return null;
  }

  /// 建议改成哪个模型就能做批量导入。没有建议时返回空表。
  List<String> get suggestedVisionModels =>
      LlmVision.suggestedVisionModels[providerId] ?? const [];

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
