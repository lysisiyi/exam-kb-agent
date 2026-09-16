/// 统一的空态与错误态。
///
/// ## 为什么值得抽出来
///
/// 打磨之前，七个页面的这两类状态是各写各的：
///
/// | 页面 | 错误态长什么样 |
/// |---|---|
/// | 知识库 | 图标 + 标题 + **可选中的原始错误** + 「重新载入」按钮 |
/// | 错题本 | 一行灰字 `载入失败：xxx`，**没有重试** |
/// | 录入 | 一行灰字，**没有重试** |
/// | 组卷 | 表单里一行红字 |
///
/// 不一致本身是小事，真正的毛病是**有的页面出错了没有出路** ——
/// 用户看到"载入失败"，唯一能做的是关掉再打开应用。
/// 而绝大多数失败（数据库刚被占用、一次 IO 抖动）重试一下就好了。
///
/// 所以这里定两条规矩：
/// 1. **错误态必须给出下一步**：能重试的就给按钮，不能重试的说清找谁
/// 2. **原始错误要能选中复制** —— 用户报障时能直接贴出来，
///    这也正是"如实告知"在 UI 上的落点
library;

import 'package:flutter/material.dart';

/// 统一的错误态。
class AppErrorView extends StatelessWidget {
  /// 一句话说明出了什么事（用户看得懂的那种）。
  final String title;

  /// 原始错误。显示在标题下方的小字里，**可选中复制**。
  final Object? error;

  /// 重试。为 null 时不显示按钮 —— 但那种情况应当在 [hint] 里说清下一步。
  final VoidCallback? onRetry;

  final String retryLabel;

  /// 补充说明（比如"请到设置里配置 API Key"）。
  final String? hint;

  const AppErrorView({
    super.key,
    required this.title,
    this.error,
    this.onRetry,
    this.retryLabel = '重试',
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  size: 44, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (hint != null) ...[
                const SizedBox(height: 8),
                Text(
                  hint!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.7,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 10),
                // 可选中：用户报障时能直接复制，而不用复述或截图
                SelectableText(
                  '$error',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.6,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (onRetry != null) ...[
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(retryLabel),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 统一的空态。
///
/// 空态不是错误 —— 它要回答的是"这里现在是空的，那我该做什么"，
/// 所以 [hint] 里应当写**下一步动作**，而不是"暂无数据"。
class AppEmptyView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? hint;

  /// 可选的下一步按钮。
  final Widget? action;

  const AppEmptyView({
    super.key,
    this.icon = Icons.inbox_outlined,
    required this.title,
    this.hint,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 44, color: theme.colorScheme.outline),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (hint != null) ...[
                const SizedBox(height: 8),
                Text(
                  hint!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.8,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (action != null) ...[
                const SizedBox(height: 18),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
