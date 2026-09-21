/// WCAG 对比度工具（测试专用）。
///
/// ## 为什么提取出来
///
/// 这个公式原先只住在 `knowledge_palette_test.dart` 里。掌握度着色
/// （`masteryThemeOf`）新增了三种底色 —— 它们必须过**同一条线**，
/// 所以该复用一个公式，而不是在各处再写一份。
///
/// 两处用它守的都是同一件事：**颜色改浅就会红**。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// WCAG 相对亮度。
double relativeLuminance(Color c) {
  double f(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
}

/// 对比度（1:1 – 21:1）。
double contrast(Color fg, Color bg) {
  final a = relativeLuminance(fg);
  final b = relativeLuminance(bg);
  final hi = math.max(a, b);
  final lo = math.min(a, b);
  return (hi + 0.05) / (lo + 0.05);
}

/// WCAG AA 对**正文**的阈值。
///
/// 知识点卡片与大纲里的字最大也就 15px，都属于"正文"，
/// 所以一律按 4.5 卡（大号字的 3:1 不适用）。
const double wcagAa = 4.5;
