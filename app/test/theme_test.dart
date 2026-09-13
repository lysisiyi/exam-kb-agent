/// 主题的回归测试。
///
/// ## 为什么主题也要测
///
/// 本项目真实翻过一次车：**公式键盘的按钮渲染成了 8 个空白按钮。**
///
/// 根因不在键盘代码里，而在主题：
///
/// ```dart
/// // app_theme.dart
/// bodyMedium: AppTypography.body          // body 没写 color
/// // AppTypography
/// static const body = TextStyle(fontSize: 14, height: 1.6);   // ← 没有 color
/// ```
///
/// `ThemeData.textTheme.copyWith(...)` 会**整体替换** Flutter 默认的对应样式，
/// 而默认样式是带颜色的。于是 `bodyMedium` 的 color 变成 null，
/// 所有没显式指定颜色的 `Text` 全部丢失颜色 —— 布局正常、间距正常、
/// 交互正常，就是"字看不见"。
///
/// 最要命的是**当时的测试全是绿的**：widget 测试断言的是"文本内容存在"，
/// 不是"文本颜色能被看见"。所以这类 bug 必须用专门的一条用例守住。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/theme/app_theme.dart';

void main() {
  group('主题可读性', () {
    test('textTheme 里每一条都必须有颜色 —— 否则继承它的文本会隐形', () {
      final theme = AppTheme.light();
      final missing = <String>[];

      // 逐条检查，而不是只看 bodyMedium：漏掉任何一条，
      // 用到它的 Text 就会静默丢色。
      void check(String name, TextStyle? style) {
        if (style == null) return;
        if (style.color == null) missing.add(name);
      }

      final t = theme.textTheme;
      check('displayLarge', t.displayLarge);
      check('displayMedium', t.displayMedium);
      check('displaySmall', t.displaySmall);
      check('headlineLarge', t.headlineLarge);
      check('headlineMedium', t.headlineMedium);
      check('headlineSmall', t.headlineSmall);
      check('titleLarge', t.titleLarge);
      check('titleMedium', t.titleMedium);
      check('titleSmall', t.titleSmall);
      check('bodyLarge', t.bodyLarge);
      check('bodyMedium', t.bodyMedium);
      check('bodySmall', t.bodySmall);
      check('labelLarge', t.labelLarge);
      check('labelMedium', t.labelMedium);
      check('labelSmall', t.labelSmall);

      expect(
        missing,
        isEmpty,
        reason: '这些 textTheme 条目没有 color：$missing。\n'
            '它们被 ThemeData.textTheme.copyWith 替换后颜色会变成 null，'
            '所有未显式指定颜色的 Text 都会隐形。给 AppTypography 里对应'
            '的 token 补上 color。',
      );
    });

    test('DefaultTextStyle 默认正文颜色非空', () {
      // 这是"没写颜色的 Text 能不能看见"的直接判据
      final theme = AppTheme.light();
      expect(theme.textTheme.bodyMedium?.color, isNotNull);
      expect(theme.textTheme.bodyLarge?.color, isNotNull);
    });

    test('关键排版 token 自带颜色（它们会被直接当 style 用）', () {
      for (final (name, style) in [
        ('pageTitle', AppTypography.pageTitle),
        ('sectionTitle', AppTypography.sectionTitle),
        ('body', AppTypography.body),
        ('bodyStrong', AppTypography.bodyStrong),
        ('stem', AppTypography.stem),
        ('caption', AppTypography.caption),
        ('label', AppTypography.label),
      ]) {
        expect(style.color, isNotNull,
            reason: 'AppTypography.$name 缺少 color');
      }
    });

    test('正文颜色与背景有足够对比（不是白底白字）', () {
      final theme = AppTheme.light();
      final fg = theme.textTheme.bodyMedium!.color!;
      final bg = theme.colorScheme.surface;

      // WCAG 相对亮度。`Color.r/g/b` 是 0–1 的 double（Flutter 3.27+ 的宽色域 API）。
      double lum(Color c) {
        double ch(double v) =>
            v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
        return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
      }

      final l1 = lum(fg), l2 = lum(bg);
      final ratio =
          (l1 > l2 ? (l1 + 0.05) / (l2 + 0.05) : (l2 + 0.05) / (l1 + 0.05));

      // WCAG AA 对正文要求 4.5:1。这里只卡 4.0 —— 断言留一点余量，
      // 目的是拦住"白底白字"这种灾难，不是做无障碍认证。
      expect(ratio, greaterThan(4.0),
          reason: '正文色 $fg 与背景 $bg 对比度仅 ${ratio.toStringAsFixed(2)}:1');
    });
  });
}
