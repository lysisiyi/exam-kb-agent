/// Windows 安全存储实现（基于 Windows DPAPI）。
///
/// ## 用途
/// 保存用户自带的 LLM API Key。这是**唯一**需要加密存储的数据 ——
/// 题目、错题、复习记录都是学习数据，不必加密（也不该加密，
/// 因为用户要能直接用文本编辑器打开自己的数据）。
///
/// ## 实现原理
/// `flutter_secure_storage` 在 Windows 上走 **DPAPI**（Data Protection API）：
/// 1. 把整个 key-value 集合序列化成 JSON
/// 2. 用 `CryptProtectData` 加密（密钥由 Windows 按用户账户派生）
/// 3. 写入应用数据目录下的加密文件
///
/// **重要含义**：DPAPI 的密钥绑定**当前 Windows 用户账户**。
/// 把文件拷到别的机器或别的用户下都解不开 —— 这正是我们要的安全性。
///
/// ## 绝不做的事
/// - 不把密钥写进普通配置文件或日志
/// - 不把密钥返回给 UI（只返回掩码）
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'platform_services.dart';

/// 存储键前缀。避免与其他模块的键冲突。
const String _kPrefix = 'kma.';

/// 已知的键。集中定义便于审计（哪些敏感数据被存了）。
abstract final class SecureKeys {
  /// LLM API Key，按 provider 区分：`llm.apiKey.deepseek`
  static String llmApiKey(String providerId) => 'llm.apiKey.$providerId';

  /// 当前选中的 provider。
  static const String currentProvider = 'llm.currentProvider';

  /// 自定义 base URL（用户选了"自定义"provider 时）。
  static const String customBaseUrl = 'llm.customBaseUrl';

  /// 自定义模型名。
  static const String customModel = 'llm.customModel';

  /// 需要隐藏的键（用于 UI 展示"已配置的服务"）。
  static const List<String> allLlmKeys = [
    currentProvider,
    customBaseUrl,
    customModel,
  ];
}

/// 基于 `flutter_secure_storage`（Windows 走 DPAPI）的实现。
class SecureStoreWindows implements SecureStore {
  final FlutterSecureStorage _storage;

  SecureStoreWindows({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              // Windows 上这些选项不生效（走 DPAPI 而非 Keychain/Keystore），
              // 但保留以便同一份代码在加 Android/iOS 后仍正确。
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: _kPrefix + key);
    } catch (e) {
      // 解密失败（例如换了 Windows 账户、文件损坏）不应让 App 崩溃。
      // 返回 null 让上层走"未配置"分支，用户重新填一次即可。
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    await _storage.write(key: _kPrefix + key, value: value);
  }

  @override
  Future<void> delete(String key) async {
    await _storage.delete(key: _kPrefix + key);
  }

  @override
  Future<void> deleteAll() async {
    // 只删自己的键，不动同一个存储里其他人的数据。
    for (final key in await _allOurKeys()) {
      await _storage.delete(key: _kPrefix + key);
    }
  }

  @override
  Future<String?> readMasked(String key) async {
    final v = await read(key);
    return maskSecret(v);
  }

  /// 列出本应用写入的全部键（去掉前缀）。
  Future<List<String>> _allOurKeys() async {
    try {
      final all = await _storage.readAll();
      return all.keys
          .where((k) => k.startsWith(_kPrefix))
          .map((k) => k.substring(_kPrefix.length))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 把密钥转成可安全显示的掩码。
  ///
  /// **永远不要**在 UI 上显示完整密钥。这里只保留头 3 位与尾 4 位，
  /// 足以让用户确认"是我这把 key"，又不足以泄露。
  static String? maskSecret(String? secret) {
    if (secret == null || secret.isEmpty) return null;
    if (secret.length <= 8) return '••••••••';
    return '${secret.substring(0, 3)}••••••••${secret.substring(secret.length - 4)}';
  }
}
