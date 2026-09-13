/// 「AI 标注」按钮。
///
/// ## 这个按钮有三种状态，每一种都要说人话
///
/// | 状态 | 按钮 | 点了之后 |
/// |---|---|---|
/// | 没配 API Key | 「AI 标注（需配置）」 | 打开配置对话框，说明为什么需要、Key 存在哪 |
/// | 配了、正在跑 | 转圈 + 「标注中…」 | — |
/// | 调用失败 | 按错误类型给**具体**处置建议 | 401 → 检查 Key；429 → 稍后重试；超时 → 检查网络 |
///
/// 第三种是重点：`LlmErrorKind` 已经做了 9 类错误分类，每条都带
/// `needsUserAction`（是"配置问题"还是"临时故障"）。直接把它翻成中文，
/// 而不是笼统报"调用失败"—— 用户看到"API Key 无效"才知道该干什么。
///
/// ## 为什么标注失败不影响录入
///
/// 打标是加速器。任何失败都只是 `onMessage` 提示一句，表单内容一个字不动。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../domain/knowledge/knowledge_point.dart';
import '../../../domain/problem_draft.dart';
import '../../../services/llm/llm_settings.dart';
import '../../../services/tagger/knowledge_tagger.dart';
import '../../../services/tagger/tag_cache_store.dart';
import 'llm_settings_dialog.dart';

/// 标注结果，回填给录入页。
class AiTagSuggestion {
  final String? primaryKpId;
  final List<String> secondaryKpIds;
  final double confidence;
  final bool needsReview;

  /// 模型给的难度（1–3）。
  final int? difficulty;

  /// 模型预判的错因（受控词表子集）。
  final List<String> errorCauses;

  /// 模型的判断依据，展示给用户看"为什么"。
  final String reason;

  const AiTagSuggestion({
    this.primaryKpId,
    this.secondaryKpIds = const [],
    this.confidence = 0,
    this.needsReview = false,
    this.difficulty,
    this.errorCauses = const [],
    this.reason = '',
  });
}

class EntryAiButton extends ConsumerStatefulWidget {
  final ProblemDraft draft;
  final KnowledgeBase knowledge;

  /// 成功拿到结果时回调。
  final void Function(AiTagSuggestion) onResult;

  /// 给用户看的一句话（`error: true` 时用错误色）。
  final void Function(String message, {bool error}) onMessage;

  const EntryAiButton({
    super.key,
    required this.draft,
    required this.knowledge,
    required this.onResult,
    required this.onMessage,
  });

  @override
  ConsumerState<EntryAiButton> createState() => _EntryAiButtonState();
}

class _EntryAiButtonState extends ConsumerState<EntryAiButton> {
  bool _running = false;
  LlmSettings? _settings;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final s = await const LlmSettingsStore().load();
      if (mounted) setState(() => _settings = s);
    } catch (_) {
      if (mounted) setState(() => _settings = LlmSettings.none);
    }
  }

  Future<void> _onPressed() async {
    final settings = _settings ?? await const LlmSettingsStore().load();
    if (!settings.isConfigured) {
      final saved = await showLlmSettingsDialog(context, initial: settings);
      if (!mounted) return;
      if (saved != null) {
        setState(() => _settings = saved);
        widget.onMessage('已保存配置，再点一次「AI 标注」即可');
      }
      return;
    }

    if (widget.draft.stem.trim().isEmpty) {
      widget.onMessage('先把题干填上再标注', error: true);
      return;
    }

    setState(() => _running = true);
    try {
      // 缓存与用量台账都落在本地 sqlite 里。
      // ⚠️ 拿不到数据库**不能**让标注失败 —— 缓存只是省钱的手段，
      // 没有它照样能标注。所以这里用一个空实现兜底。
      TagCache? cache;
      UsageLedger? ledger;
      final providerId = settings.providerId;
      try {
        final db = await ref.read(databaseProvider.future);
        final model = settings.toConfig().model;
        cache = SqliteTagCache(db: db, model: model);
        ledger = UsageLedger(db);
      } catch (_) {
        cache = null;
        ledger = null;
      }

      final tagger = await buildTagger(
        knowledge: widget.knowledge,
        settings: settings,
        cache: cache,
        onUsage: ledger == null
            ? null
            : (usage) => ledger!.record(provider: providerId, usage: usage),
      );
      if (tagger == null) {
        widget.onMessage('配置不完整，请检查服务商与 Key', error: true);
        return;
      }

      final problem = widget.draft.build(knowledge: widget.knowledge);
      final outcome = await tagger.tag(problem);

      if (!mounted) return;
      if (!outcome.ok || outcome.result == null) {
        // `TagOutcome.failure` 里已经含了 `LlmErrorKind.advice`
        // （见 knowledge_tagger.dart 的 catch 分支），
        // 所以这里**不要**再写一份"错误类型 → 建议"的映射 ——
        // 那会变成两处需要同步维护的真相。
        widget.onMessage(outcome.failure ?? '标注失败', error: true);
        return;
      }

      final r = outcome.result!;
      final threshold = settings.toConfig().confidenceThreshold;
      widget.onResult(AiTagSuggestion(
        primaryKpId: r.primaryKpId,
        secondaryKpIds: r.secondary.map((s) => s.kpId).toList(),
        confidence: r.confidence,
        needsReview: r.needsReview(threshold),
        difficulty: r.difficulty,
        errorCauses: r.errorCauses,
        reason: r.reason,
      ));
      widget.onMessage(
        'AI 建议已填入（置信度 ${(r.confidence * 100).toStringAsFixed(0)}%'
        '${r.needsReview(threshold) ? "，偏低，建议人工确认" : ""}）'
        // 命中缓存时说明一声：用户会看到"秒回"，需要知道为什么快
        '${outcome.fromCache ? " · 命中本地缓存，未消耗 token" : ""}',
      );
    } catch (e) {
      if (mounted) widget.onMessage('标注失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final configured = _settings?.isConfigured ?? false;
    return OutlinedButton.icon(
      onPressed: _running ? null : _onPressed,
      icon: _running
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(configured ? Icons.auto_awesome : Icons.key_outlined, size: 16),
      label: Text(
        _running
            ? '标注中…'
            : (configured ? 'AI 标注' : 'AI 标注（需配置 Key）'),
      ),
    );
  }
}
