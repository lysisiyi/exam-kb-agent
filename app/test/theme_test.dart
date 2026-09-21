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
import 'package:kaoyan_math_agent/core/math/latex_text_split.dart';
import 'package:kaoyan_math_agent/core/theme/app_fonts.dart';
import 'package:kaoyan_math_agent/core/theme/app_theme.dart';
import 'package:kaoyan_math_agent/features/knowledge/knowledge_formula_row.dart';
import 'package:katex/katex.dart' as katex;
import 'package:katex_dart/katex_dart.dart' show KatexOptions, renderToBox;

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

  group('字体链', () {
    // 「字体类型不定」是怎么来的：`AppTypography` 的 token 会被
    // `textTheme.copyWith(...)` **整体替换**掉默认样式，而默认样式是带
    // `fontFamily` 的。漏一条，那一处的文字就退回 Skia 的隐式回退，
    // 与旁边的中文换一套字体。与上面那个 color 的坑是同一个机制 ——
    // 所以这里用同一套写法守住它。

    test('textTheme 里每一条都必须有字体族 —— 否则继承它的文本会换字体', () {
      final theme = AppTheme.light();
      final missing = <String>[];

      void check(String name, TextStyle? style) {
        if (style == null) return;
        if (style.fontFamily == null) missing.add(name);
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
        reason: '这些 textTheme 条目没有 fontFamily：$missing。\n'
            '它们被 ThemeData.textTheme.copyWith 替换后会丢掉字体族，'
            '所有继承它的 Text 都会退回系统的隐式字体回退 —— '
            '用户看到的就是「同一段中文在不同位置字体不一样」。',
      );
    });

    test('关键排版 token 自带字体链（它们会被直接当 style 用）', () {
      for (final (name, style) in [
        ('pageTitle', AppTypography.pageTitle),
        ('sectionTitle', AppTypography.sectionTitle),
        ('body', AppTypography.body),
        ('bodyStrong', AppTypography.bodyStrong),
        ('stem', AppTypography.stem),
        ('caption', AppTypography.caption),
        ('label', AppTypography.label),
        ('mono', AppTypography.mono),
      ]) {
        expect(style.fontFamily, isNotNull,
            reason: 'AppTypography.$name 缺少 fontFamily');
        expect(style.fontFamilyFallback, isNotNull,
            reason: 'AppTypography.$name 缺少 fontFamilyFallback');
        expect(style.fontFamilyFallback, isNotEmpty,
            reason: 'AppTypography.$name 的 fontFamilyFallback 是空的');
      }
    });

    test('等宽样式必须带中文回退 —— 它渲染的是文件路径', () {
      // `'monospace'` **不是 Windows 上真实存在的字体族名**（Windows 的
      // 等宽字体叫 `Consolas`、`Courier New`），解析结果是平台默认字体、
      // 具体落到哪个不写在代码里 —— 这正是"字体类型不定"。
      // 而设置页用它显示题库目录，那完全可能是 `D:\我的题库\...`。
      expect(AppTypography.mono.fontFamily, isNot('monospace'));
      expect(AppFonts.mono, 'Consolas');
      expect(AppTypography.mono.fontFamilyFallback,
          contains('Microsoft YaHei UI'));
      expect(AppFonts.monoFallback, contains('Microsoft YaHei UI'));
    });

    test('界面字体链的首选不在后备链里重复', () {
      // 重复没有功能害处，但会让「链的顺序」读起来有两份真相
      expect(AppFonts.sansFallback, isNot(contains(AppFonts.sans)));
      expect(AppFonts.sansFallback, contains('Microsoft YaHei'));
    });
  });

  group('公式字号', () {
    test('只有三档，且阅读档大于紧凑档', () {
      expect(AppMathSizes.reading, greaterThan(AppMathSizes.compact));
      expect(AppMathSizes.display, greaterThan(AppMathSizes.reading));
    });

    test('公式行的默认字号就是阅读档 —— 调用点不得覆盖', () {
      // 历史缺陷：`kFormulaFontSize` 的注释早就写明「为什么是 14 而不是
      // 12.5」（KaTeX 上下标只有 70%），但 `knowledge_leaf_detail.dart`
      // 的调用点硬编码传了 12.5 —— 常量改对了、行为没变，
      // 于是同一个详情页里核心公式 12.5、别名公式 14。
      expect(kFormulaFontSize, AppMathSizes.reading);
    });
  });

  group('公式宽度口径', () {
    /// 旧口径：把整条 tex 交给 katex 量。保留在这里是为了守住"不许退回去"。
    double? legacyWidth(String tex, double fontSize) {
      try {
        final box = renderToBox(tex, options: const KatexOptions());
        return katex.boxSizePxPadded(box, fontSize).width;
      } catch (_) {
        return null;
      }
    }

    test('纯数学公式：新旧口径必须一致（改动不得影响既有排版）', () {
      for (final tex in [
        r'a_1,a_2,\cdots,a_n',
        r'\int_0^1 x^2\,dx=\frac13',
        r'\lim_{x\to 0}\frac{\sin x}{x}=1',
      ]) {
        resetFormulaWidthCache();
        expect(
          formulaWidth(tex, 14),
          legacyWidth(tex, 14),
          reason: '纯数学公式的宽度不该因这次改动而变化：$tex',
        );
      }
    });

    test('含中文的公式：必须比"整条交给 katex"更宽', () {
      // 这是「公式被裁掉」的根因之一。真正渲染时中文由 Flutter 排，
      // 而旧口径把中文也按 KaTeX 字体度算 —— KaTeX 字体没有汉字字形，
      // 量出来的数偏小。量小了就判成"放得下"，实际排出来溢出、被静默裁掉。
      const tex = r'f(x)=\text{在关于\ x\ 轴对称的}\ D';
      resetFormulaWidthCache();
      final now = formulaWidth(tex, 14)!;
      final legacy = legacyWidth(tex, 14)!;

      expect(
        now,
        greaterThan(legacy),
        reason: '含中文的公式仍按旧口径量（$legacy vs $now）—— '
            '一旦量小，公式会被判成"放得下"然后静默溢出',
      );
      // 实测约 +20%，给一个宽松但有效的下界
      expect(now - legacy, greaterThan(10));
    });

    test('相邻中文片与 LaTeX 片是相加关系', () {
      resetFormulaWidthCache();
      final whole = formulaWidth(r'x=\text{解}', 14)!;
      resetFormulaWidthCache();
      final latexOnly = formulaWidth(r'x=', 14)!;

      // 一个汉字整宽（CJK 是全角，advance = 1em）
      expect(whole - latexOnly, greaterThan(12));
      expect(whole - latexOnly, lessThan(16));
    });

    test('切出来的每一片宽度之和 == 整条宽度（口径自洽）', () {
      const tex = r'\text{若}\ f\ \text{连续}';
      resetFormulaWidthCache();
      final whole = formulaWidth(tex, 14)!;

      var sum = 0.0;
      for (final c in splitLatexText(tex)) {
        resetFormulaWidthCache();
        sum += formulaWidth(
          switch (c) {
            LatexChunk(:final tex) => tex,
            TextChunk(:final text) => '\\text{$text}',          },
          14,
        )!;
      }

      expect(sum, closeTo(whole, 0.01));
    });

    test('非法 LaTeX 仍然返回 null（交给渲染器降级）', () {
      resetFormulaWidthCache();
      expect(formulaWidth(r'\frac{1}{', 14), isNull);
    });
  });
}
