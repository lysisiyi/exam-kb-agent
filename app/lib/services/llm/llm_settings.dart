/// 用户自带 API Key（BYOK）的存取与客户端装配。
///
/// ## 纯本地架构下这是唯一需要联网配置的东西
///
/// 产品的核心承诺是"用户自己的 Key、数据不出本机"。所以这里：
/// - Key 只存**本机 DPAPI 加密存储**（Windows 上是用户账户绑定的加密）
/// - 产品自己的服务器不参与（本项目根本没有服务器）
/// - 界面永远只显示掩码（`sk-••••••••3f2a`），绝不回显明文
///
/// ## 为什么是非阻断的
///
/// 没配 Key **不能**影响任何核心功能：录入、错题本、复习、组卷、
/// 导出全都离线可用，只是没有 AI 打标。所以这里所有读取失败都返回
/// "未配置"，而不是抛异常。
library;

import '../../core/platform/platform_services.dart';
import '../../core/platform/secure_store_windows.dart' show SecureKeys;
import '../../domain/knowledge/knowledge_point.dart';
import '../tagger/knowledge_recall.dart';
import '../tagger/knowledge_tagger.dart';
import 'dio_http_adapter.dart';
import 'llm_client.dart';
import 'provider_registry.dart';

/// 当前生效的 LLM 配置（内存态，Key 已解密）。
class LlmSettings {
  final String providerId;
  final String apiKey;
  final String? baseUrlOverride;
  final String? modelOverride;

  const LlmSettings({
    required this.providerId,
    required this.apiKey,
    this.baseUrlOverride,
    this.modelOverride,
  });

  static const LlmSettings none = LlmSettings(providerId: '', apiKey: '');

  bool get isConfigured => providerId.isNotEmpty && apiKey.trim().isNotEmpty;

  LlmConfig toConfig() => LlmConfig(
        providerId: providerId,
        apiKey: apiKey,
        baseUrlOverride: baseUrlOverride,
        modelOverride: modelOverride,
      );

  ProviderSpec? get spec => LlmProviders.byId(providerId);

  /// 掩码显示，供 UI 使用。
  String get maskedKey {
    final k = apiKey.trim();
    if (k.isEmpty) return '';
    if (k.length <= 10) return '••••';
    return '${k.substring(0, 3)}••••••••${k.substring(k.length - 4)}';
  }

  LlmSettings copyWith({
    String? providerId,
    String? apiKey,
    String? baseUrlOverride,
    String? modelOverride,
  }) =>
      LlmSettings(
        providerId: providerId ?? this.providerId,
        apiKey: apiKey ?? this.apiKey,
        baseUrlOverride: baseUrlOverride ?? this.baseUrlOverride,
        modelOverride: modelOverride ?? this.modelOverride,
      );
}

/// 配置存取。
class LlmSettingsStore {
  const LlmSettingsStore();

  SecureStore get _store => PlatformServices.instance.secureStore;

  /// 读取配置。任何失败都返回"未配置"。
  Future<LlmSettings> load() async {
    try {
      final providerId =
          await _store.read(SecureKeys.currentProvider) ?? '';
      if (providerId.isEmpty) return LlmSettings.none;

      final apiKey = await _store.read(SecureKeys.llmApiKey(providerId)) ?? '';
      final baseUrl = await _store.read(SecureKeys.customBaseUrl);
      final model = await _store.read(SecureKeys.customModel);

      return LlmSettings(
        providerId: providerId,
        apiKey: apiKey,
        baseUrlOverride: (baseUrl == null || baseUrl.isEmpty) ? null : baseUrl,
        modelOverride: (model == null || model.isEmpty) ? null : model,
      );
    } catch (_) {
      // 解密失败/存储不可用 → 当作未配置，让用户重新填
      return LlmSettings.none;
    }
  }

  /// 保存配置。写失败会抛出，由 UI 提示（这是用户主动操作，应当知道结果）。
  Future<void> save(LlmSettings s) async {
    await _store.write(SecureKeys.currentProvider, s.providerId);
    await _store.write(SecureKeys.llmApiKey(s.providerId), s.apiKey.trim());
    if (s.baseUrlOverride == null || s.baseUrlOverride!.trim().isEmpty) {
      await _store.delete(SecureKeys.customBaseUrl);
    } else {
      await _store.write(SecureKeys.customBaseUrl, s.baseUrlOverride!.trim());
    }
    if (s.modelOverride == null || s.modelOverride!.trim().isEmpty) {
      await _store.delete(SecureKeys.customModel);
    } else {
      await _store.write(SecureKeys.customModel, s.modelOverride!.trim());
    }
  }

  /// 清空配置（同时删掉 Key）。
  Future<void> clear() async {
    for (final p in LlmProviders.all) {
      await _store.delete(SecureKeys.llmApiKey(p.id));
    }
    await _store.delete(SecureKeys.currentProvider);
    await _store.delete(SecureKeys.customBaseUrl);
    await _store.delete(SecureKeys.customModel);
  }
}

/// 用当前配置装配标注引擎。未配置时返回 null。
///
/// [http] 可注入，便于测试不真的发请求。
/// [cache] 传 null 表示不缓存（每次都真的调 API，只在测试/排查时用）。
/// [onUsage] 每次**真实**调用后回调一次，用于写用量台账。
/// 命中缓存不会触发它 —— 那种情况没花钱。
Future<KnowledgeTagger?> buildTagger({
  required KnowledgeBase knowledge,
  required LlmSettings settings,
  HttpAdapter? http,
  RecallConfig recallConfig = RecallConfig.defaults,
  TagCache? cache,
  void Function(LlmUsage)? onUsage,
}) async {
  if (!settings.isConfigured) return null;
  final config = settings.toConfig();
  final (ok, _) = config.validate();
  if (!ok) return null;

  return KnowledgeTagger(
    knowledge: knowledge,
    // DioHttpAdapter 只负责"怎么发"，URL 由 LlmClient 从 config 里算
    // （见 LlmClient.chat 里对 config.baseUrl 的拼接），所以这里不传地址。
    client: LlmClient(
      config: config,
      http: http ?? DioHttpAdapter(),
      onUsage: onUsage,
    ),
    recallConfig: recallConfig,
    cache: cache,
  );
}
