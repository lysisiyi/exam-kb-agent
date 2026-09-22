/// 题目配图的展示条（混合制"正文用图"的 UI 落点）。
///
/// ## 背景
///
/// `Problem.images`（frontmatter `images:`）从解析到导出**全链路早已支持**，
/// 唯独界面从不渲染 —— 导入带图的题在详情页与复习卡上"看不见"配图。
/// 本组件补上这块：按 `LibraryPaths.images` 解析每个文件名。
///
/// ## 宽容原则（与 problem_markdown 同一条）
///
/// - 图片**缺失**不是错误：文件不存在显示"配图缺失"占位，题照常看；
/// - 图片**解码失败**同理（errorBuilder 兜底），绝不抛异常打断页面；
/// - `imagesDirPath` 为 null（题库路径还没就绪）→ 整条不渲染，调用方处理。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// 纵向排布一张题的所有配图。空列表直接不渲染。
class ProblemImageList extends StatelessWidget {
  /// frontmatter `images:` 里的文件名（相对题库 images 目录）。
  final List<String> images;

  /// 题库 images 目录的绝对路径；null 时每张显示"缺失"占位。
  final String? imagesDirPath;

  const ProblemImageList({
    super.key,
    required this.images,
    this.imagesDirPath,
  });

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < images.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _OneImage(name: images[i], imagesDirPath: imagesDirPath),
        ],
      ],
    );
  }
}

class _OneImage extends StatelessWidget {
  final String name;
  final String? imagesDirPath;

  const _OneImage({required this.name, this.imagesDirPath});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = imagesDirPath == null ? null : File('$imagesDirPath/$name');
    final exists = file?.existsSync() ?? false;

    return Container(
      constraints: const BoxConstraints(maxHeight: 320),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor, width: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: exists
          ? Image.file(
              file!,
              fit: BoxFit.contain,
              width: double.infinity,
              // 解码失败（坏图/不支持的格式）与"文件不存在"同等对待：
              // 占位提示，绝不让一张坏图打断整页。
              errorBuilder: (_, __, ___) => _Missing(name: name),
            )
          : _Missing(name: name),
    );
  }
}

class _Missing extends StatelessWidget {
  final String name;

  const _Missing({required this.name});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Text(
        '配图缺失：$name',
        style: const TextStyle(
          fontSize: 11,
          color: AppColors.ink3,
        ),
      ),
    );
  }
}
