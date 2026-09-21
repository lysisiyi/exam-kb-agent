/// 错因处方面板。
///
/// ## 它解决的是"资产被闲置"这个问题
///
/// `data/error_causes.json` 里每一类错因都写好了三样东西：
/// `action`（该做什么）、`not_action`（**不该**做什么）、
/// `resource_type`（该用什么材料）。但这些内容**从未在界面上显示过一次**
/// —— 它们此前只参与画像页的"错因分布"统计。
///
/// 于是"区分不会和算错"这个卖点只走到**分类**为止，没走到**开方**。
///
/// ## 为什么必须把 `remedy == drill` 单独标出来
///
/// `calc`（计算失误）/ `reading`（审题错误）/ `time`（时间不够）三类错因的
/// `not_action` 里都明确写着"不要靠继续刷题解决"。而复习页的场景恰恰
/// 就是**重做本题** —— 不告诉用户的话，他会把这一遍白做，
/// 还会以为"练了就是这个效果"。
///
/// ## 未知 id 要如实列出
///
/// 题目里存的错因 id 可能来自更早版本的词表。静默丢弃会让人误以为
/// "这题没标错因"，所以这里单独给一个提示块。
library;

import 'package:flutter/material.dart';

import '../../core/theme/app_fonts.dart';
import '../../core/theme/app_theme.dart';
import '../../data/error_causes.dart';

/// 一道题的错因处方。
///
/// 入参是**已解析**的 [ErrorCause] 列表（而不是 id），
/// 这样这个 widget 不依赖任何 provider，可以单独测。
class ErrorPrescriptionPanel extends StatelessWidget {
  /// 已解析出来的错因（按词表展示顺序）。
  final List<ErrorCause> causes;

  /// 在题目的 `error_causes` 里、但当前词表查不到的 id。
  final List<String> unknownIds;

  const ErrorPrescriptionPanel({
    super.key,
    required this.causes,
    this.unknownIds = const [],
  });

  /// 既没有可解析的错因、也没有未知 id。
  bool get isEmpty => causes.isEmpty && unknownIds.isEmpty;

  @override
  Widget build(BuildContext context) {
    if (isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < causes.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          _CauseBlock(cause: causes[i]),
        ],
        if (unknownIds.isNotEmpty) ...[
          if (causes.isNotEmpty) const SizedBox(height: 10),
          _UnknownCausesBlock(ids: unknownIds),
        ],
      ],
    );
  }
}

/// 单个错因的处方。
class _CauseBlock extends StatelessWidget {
  final ErrorCause cause;

  const _CauseBlock({required this.cause});

  @override
  Widget build(BuildContext context) {
    final p = cause.prescription;
    final drill = cause.needsDrill;
    final accent = drill ? AppColors.warningInk : AppColors.primaryStrong;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppRadius.rMd,
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  cause.name,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: AppFonts.bold,
                    color: accent,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _RemedyChip(remedy: cause.remedy),
            ],
          ),
          if (drill) ...[
            const SizedBox(height: 9),
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, size: 15, color: AppColors.warningInk),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '再做一遍这道题帮助有限 —— 这一类要靠专门的训练，不是靠题量。',
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.6,
                      color: AppColors.warningInk,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (p != null && p.action.isNotEmpty) ...[
            const SizedBox(height: 10),
            _PrescriptionRow(label: '该做', text: p.action),
          ],
          if (p != null && p.notAction.isNotEmpty) ...[
            const SizedBox(height: 7),
            _PrescriptionRow(label: '别做', text: p.notAction, dim: true),
          ],
          if (p != null && p.resourceTypes.isNotEmpty) ...[
            const SizedBox(height: 7),
            _PrescriptionRow(label: '材料', text: p.resourceTypes.join(' · ')),
          ],
        ],
      ),
    );
  }
}

/// 「该做 / 别做 / 材料」一行。
class _PrescriptionRow extends StatelessWidget {
  final String label;
  final String text;

  /// 「别做」用更淡的颜色 —— 它是否定式建议，不该和"该做"抢注意力。
  final bool dim;

  const _PrescriptionRow({
    required this.label,
    required this.text,
    this.dim = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 36,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              height: 1.7,
              fontWeight: AppFonts.bold,
              color: dim ? AppColors.ink4 : AppColors.ink3,
            ),
          ),
        ),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.7,
              color: dim ? AppColors.ink3 : AppColors.ink2,
            ),
          ),
        ),
      ],
    );
  }
}

/// 补救方式的标签。
class _RemedyChip extends StatelessWidget {
  final ErrorRemedy remedy;

  const _RemedyChip({required this.remedy});

  @override
  Widget build(BuildContext context) {
    final drill = remedy == ErrorRemedy.drill;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: drill ? AppColors.warningWeak : AppColors.primaryWeak,
        borderRadius: AppRadius.rSm,
      ),
      child: Text(
        remedy.label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: AppFonts.bold,
          color: drill ? AppColors.warningInk : AppColors.primaryStrong,
        ),
      ),
    );
  }
}

/// 词表里查不到的错因 id。
class _UnknownCausesBlock extends StatelessWidget {
  final List<String> ids;

  const _UnknownCausesBlock({required this.ids});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.warningWeak,
        borderRadius: AppRadius.rMd,
        border: Border.all(color: AppColors.line),
      ),
      child: Text(
        '这题还标了 ${ids.length} 个当前词表里不存在的错因'
        '（${ids.join('、')}）—— 可能是词表更新过，'
        '或当初标注时写入了一个无效 id。',
        style: const TextStyle(
          fontSize: 12,
          height: 1.65,
          color: AppColors.warningInk,
        ),
      ),
    );
  }
}
