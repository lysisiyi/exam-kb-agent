/// 统一页头（V3 手账风，对齐 `docs/design/ui/*.png` 的版式）：
/// 大标题 + 一句副标语，可选右侧动作区。
///
/// V2 各页原来各有各的头（工具栏/标签页直接顶到第一行），重设计就是把
/// 「这页是干什么的、现在处于什么状态」用同一版式说出来。逐页接入中。
library;

import 'package:flutter/material.dart';


class PageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> trailing;

  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(subtitle!,
                      style: TextStyle(
                          fontSize: 12.5,
                          height: 1.7,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant)),
                ],
              ],
            ),
          ),
          if (trailing.isNotEmpty) ...[
            const SizedBox(width: 12),
            Wrap(spacing: 8, runSpacing: 8, children: trailing),
          ],
        ],
      ),
    );
  }
}
