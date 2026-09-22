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

import '../../core/math/math_renderer.dart';
import '../../core/theme/app_theme.dart';

/// 纵向排布一张题的所有配图。空列表直接不渲染。
class ProblemImageList extends StatelessWidget {
  /// frontmatter `images:` 里的文件名（相对题库 images 目录）。
  final List<String> images;

  /// 题库 images 目录的绝对路径；null 时每张显示"缺失"占位。
  final String? imagesDirPath;

  /// 单张图的最大高度。图为主的扫描题可以放大些（题目本体，字要看得清）。
  final double maxHeight;

  const ProblemImageList({
    super.key,
    required this.images,
    this.imagesDirPath,
    this.maxHeight = 320,
  });

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < images.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _OneImage(
            name: images[i],
            imagesDirPath: imagesDirPath,
            maxHeight: maxHeight,
          ),
        ],
      ],
    );
  }
}

class _OneImage extends StatelessWidget {
  final String name;
  final String? imagesDirPath;
  final double maxHeight;

  const _OneImage({
    required this.name,
    required this.maxHeight,
    this.imagesDirPath,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = imagesDirPath == null ? null : File('$imagesDirPath/$name');
    final exists = file?.existsSync() ?? false;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
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

/// 「识别文本（仅供检索）」折叠区 —— 图为主（`imagesPrimary`）的题目专用。
///
/// ## 为什么默认收起
///
/// 扫描题的正误判断以**图**为准（印刷原题），OCR 文本公式失真很常见
/// （TexTeller 对复杂分式/矩阵会认错）。把它默认摊开在题干位置，
/// 用户会误把识别错误当成题目本身的错误；但它又是 FTS 检索的索引来源，
/// 完全藏起来会让"为什么搜得到这道题"变得不可解释 —— 折叠区就是这两者的
/// 折中：默认不挡道，想核对时展开。
class OcrTextDisclosure extends StatelessWidget {
  /// OCR 识别的题干文本（Markdown + LaTeX，可能失真）。
  final String stem;

  /// OCR 识别的选项（选择题才有）。
  final List<String> options;

  const OcrTextDisclosure({
    super.key,
    required this.stem,
    this.options = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final renderer = MathRendering.renderer;
    return Theme(
      // ExpansionTile 自带 divider 与展开图标，压掉多余装饰即可。
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        iconColor: theme.colorScheme.onSurfaceVariant,
        collapsedIconColor: theme.colorScheme.onSurfaceVariant,
        title: Text(
          '识别文本（仅供检索，公式可能有误）',
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: DefaultTextStyle.merge(
              style: const TextStyle(fontSize: 13, height: 1.7),
              child: renderer.renderMarkdown(stem),
            ),
          ),
          for (var i = 0; i < options.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: DefaultTextStyle.merge(
                  style: const TextStyle(fontSize: 13, height: 1.7),
                  child:
                      renderer.renderMarkdown('${String.fromCharCode(65 + i)}. ${options[i]}'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
