/// LLM 服务配置对话框（BYOK）。
///
/// ## 几处刻意的设计
///
/// 1. **先说清楚 Key 存哪、发给谁** —— 用户填 API Key 前最想知道这个。
///    本项目没有服务器，Key 只进本机 DPAPI 加密存储，请求直接打到服务商。
/// 2. **默认推荐国内可直连的服务商** —— 目标用户在国内，
///    选 OpenAI 会直接卡在网络那一步，然后再来问"为什么连不上"。
/// 3. **回显永远只有掩码** —— 已配置时输入框显示 `sk-••••••••3f2a`，
///    不把明文放回内存里给 UI。
/// 4. **说清楚已经花了多少** —— BYOK 模式下钱是用户自己出的，
///    所以"花了多少"必须在本地算得出来（见 [_UsagePanel]）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../services/llm/llm_settings.dart';
import '../../../services/llm/provider_registry.dart';
import '../../../services/tagger/tag_cache_store.dart';

/// 打开配置对话框。返回保存后的设置；取消返回 null。
Future<LlmSettings?> showLlmSettingsDialog(
  BuildContext context, {
  required LlmSettings initial,
  bool dismissible = true,
}) {
  return showDialog<LlmSettings>(
    context: context,
    barrierDismissible: dismissible,
    builder: (_) => _LlmSettingsDialog(initial: initial),
  );
}

class _LlmSettingsDialog extends StatefulWidget {
  final LlmSettings initial;

  const _LlmSettingsDialog({required this.initial});

  @override
  State<_LlmSettingsDialog> createState() => _LlmSettingsDialogState();
}

class _LlmSettingsDialogState extends State<_LlmSettingsDialog> {
  late String _providerId = widget.initial.providerId.isEmpty
      ? LlmProviders.all.first.id
      : widget.initial.providerId;
  late final TextEditingController _key =
      TextEditingController(text: widget.initial.apiKey);
  late final TextEditingController _baseUrl =
      TextEditingController(text: widget.initial.baseUrlOverride ?? '');
  late final TextEditingController _model =
      TextEditingController(text: widget.initial.modelOverride ?? '');

  bool _obscure = true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    _baseUrl.dispose();
    _model.dispose();
    super.dispose();
  }

  ProviderSpec get _spec =>
      LlmProviders.byId(_providerId) ?? LlmProviders.all.first;

  bool get _needsCustomBaseUrl => _spec.baseUrl.isEmpty;

  Future<void> _save() async {
    final settings = LlmSettings(
      providerId: _providerId,
      apiKey: _key.text,
      baseUrlOverride: _baseUrl.text.trim().isEmpty ? null : _baseUrl.text,
      modelOverride: _model.text.trim().isEmpty ? null : _model.text,
    );

    final (ok, problem) = settings.toConfig().validate();
    if (!ok) {
      setState(() => _error = problem);
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await const LlmSettingsStore().save(settings);
      if (mounted) Navigator.of(context).pop(settings);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败：$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('配置 AI 标注'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '你的 Key 只存在本机（Windows 走 DPAPI 加密，绑定你的账户），'
                  '请求由本机直接发往服务商 —— 本项目没有服务器，Key 不经过任何第三方。'
                  '不配置也不影响录入、错题本、复习、组卷、导出，只是没有自动打标。',
                  style: TextStyle(fontSize: 11.5, height: 1.65),
                ),
              ),
              const SizedBox(height: 14),
              const Text('服务商', style: TextStyle(fontSize: 12.5)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final p in LlmProviders.all)
                    ChoiceChip(
                      label: Text(p.label),
                      selected: _providerId == p.id,
                      onSelected: (_) => setState(() {
                        _providerId = p.id;
                        _error = null;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                _spec.note.isEmpty
                    ? '默认模型：${_spec.defaultModel}'
                    : '${_spec.note}　·　默认模型：${_spec.defaultModel}',
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _key,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  hintText: _spec.requiresApiKey ? 'sk-…' : '（该服务商无需 Key）',
                  isDense: true,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure ? Icons.visibility_off : Icons.visibility,
                      size: 18,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                onChanged: (_) => setState(() => _error = null),
              ),
              if ((_spec.helpUrl ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: SelectableText(
                    '获取 Key：${_spec.helpUrl}',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              if (_spec.suggestedModels.isNotEmpty) ...[
                const Text('模型（留空用默认）', style: TextStyle(fontSize: 12.5)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final m in _spec.suggestedModels)
                      ActionChip(
                        label: Text(m, style: const TextStyle(fontSize: 11.5)),
                        onPressed: () => setState(() => _model.text = m),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
              ],
              TextField(
                controller: _model,
                decoration: const InputDecoration(
                  labelText: '模型名（可选）',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              if (_needsCustomBaseUrl || _baseUrl.text.isNotEmpty) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: _baseUrl,
                  decoration: const InputDecoration(
                    labelText: 'API 地址（自定义服务商必填）',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
                ),
              ],
              const SizedBox(height: 14),
              const _UsagePanel(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving
              ? null
              : () async {
                  await const LlmSettingsStore().clear();
                  if (context.mounted) {
                    Navigator.of(context).pop(LlmSettings.none);
                  }
                },
          child: const Text('清除已存 Key'),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}

/// 用量面板：已经调用了多少次、花了大概多少钱、缓存省了多少。
///
/// ## 为什么放在配置对话框里
///
/// 用户第一次配 Key 时会犹豫"会不会很贵"。把"上次花了多少"直接放在
/// 配置旁边，比写在文档里有说服力 —— 而且这个数字是他自己的真实数据。
///
/// ## 为什么 future 存在 state 里而不是每次 build 现算
///
/// 对话框里每敲一个字符都会 `setState` 重建，而这是个 `FutureBuilder`。
/// 若 `future:` 写成 `_load(...)`，每次重建都会**重新开一次数据库查询**：
/// Key 输入框打 40 个字符就是 40 次查询 + 40 次重建面板。
/// 所以在 `initState` 里取一次并缓存。
class _UsagePanel extends ConsumerStatefulWidget {
  const _UsagePanel();

  @override
  ConsumerState<_UsagePanel> createState() => _UsagePanelState();
}

class _UsagePanelState extends ConsumerState<_UsagePanel> {
  late final Future<AppUsageView> _future = _load();

  Future<AppUsageView> _load() async {
    try {
      final db = await ref.read(databaseProvider.future);
      final usage = await UsageLedger(db).summary();
      final cacheCount = await SqliteTagCache(db: db).count();
      return AppUsageView(usage: usage, cacheCount: cacheCount);
    } catch (e) {
      // ⚠️ 这里**不能**返回"看起来正常的空数据"。
      //
      // 早先 catch 后给的是 `UsageSummary()` + `cacheCount: 0`，
      // 于是数据库打不开时面板显示「还没有调用过 AI」与「0 道题缓存」——
      // 两句都像是事实，实际什么都读不到。用户会据此以为
      // "AI 没生效 / 缓存没起作用"，而真正的问题是库读不出来。
      return AppUsageView(
        usage: UsageSummary(error: '$e'),
        cacheCount: null,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return FutureBuilder<AppUsageView>(
      future: _future,
      builder: (context, snap) {
        final v = snap.data;
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '本机 AI 用量',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                v == null ? '正在读取…' : describeUsage(v.usage),
                style: const TextStyle(fontSize: 11.5, height: 1.6),
              ),
              if (v != null && describeCacheCount(v.cacheCount).isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  describeCacheCount(v.cacheCount),
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.6,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (v != null && !v.usage.isEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  '平均每次 ${v.usage.tokensPerCall.round()} tokens'
                  '${v.usage.costPerCall > 0 ? " · 约 ¥${v.usage.costPerCall.toStringAsFixed(4)}" : ""}'
                  '　（费用为估算，以服务商账单为准）',
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.6,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// 用量面板要展示的两个数。
class AppUsageView {
  final UsageSummary usage;

  /// 缓存条数。**null 表示读不到**（不是 0）。
  final int? cacheCount;

  const AppUsageView({required this.usage, required this.cacheCount});
}
