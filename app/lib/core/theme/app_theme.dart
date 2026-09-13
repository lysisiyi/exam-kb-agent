/// 设计系统 —— 与 `ui-mockups/*.html` 里定义的 token 一一对应。
///
/// 改这里的值，UI 原型和实际 App 会同步变化。**不要在各页面里写死颜色、字号。**
library;

import 'package:flutter/material.dart';

/// 调色板。对应原型里的 CSS 变量。
abstract final class AppColors {
  // 品牌与语义色
  static const primary = Color(0xFF3B5BDB);
  static const primaryStrong = Color(0xFF2F49AF);
  static const primaryWeak = Color(0xFFEDF0FF);
  static const primarySoft = Color(0xFFDDE3FF);

  static const success = Color(0xFF0CA678);
  static const successWeak = Color(0xFFE6F7F1);

  static const warning = Color(0xFFE8850C);
  static const warningWeak = Color(0xFFFFF4E5);
  static const warningInk = Color(0xFFB96A05);

  static const danger = Color(0xFFE03131);
  static const dangerWeak = Color(0xFFFFEBEB);

  static const purple = Color(0xFF7048E8);
  static const purpleWeak = Color(0xFFF0EBFF);

  // 中性色
  static const ink1 = Color(0xFF16181D);
  static const ink2 = Color(0xFF4A4F5C);
  static const ink3 = Color(0xFF8A909E);
  static const ink4 = Color(0xFFB4BAC6);

  static const bg = Color(0xFFF6F7F9);
  static const surface = Color(0xFFFFFFFF);
  static const surface2 = Color(0xFFF1F2F5);
  static const line = Color(0xFFE7E9EE);
  static const sidebar = Color(0xFFFBFAF9);
}

/// 圆角。对应原型的 --r-* 变量。
abstract final class AppRadius {
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;

  static const rSm = BorderRadius.all(Radius.circular(sm));
  static const rMd = BorderRadius.all(Radius.circular(md));
  static const rLg = BorderRadius.all(Radius.circular(lg));
  static const rXl = BorderRadius.all(Radius.circular(xl));
}

/// 间距。
abstract final class AppSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 28.0;

  /// 页面左右边距（手机）。
  static const pageH = 16.0;

  /// 最小触控区尺寸（无障碍要求）。
  static const minTouchTarget = 44.0;
}

/// 阴影。Windows 上阴影表现比移动端含蓄，所以透明度略低。
abstract final class AppShadows {
  static const s1 = [
    BoxShadow(color: Color(0x0F101828), blurRadius: 2, offset: Offset(0, 1)),
  ];

  static const s2 = [
    BoxShadow(color: Color(0x14101828), blurRadius: 14, offset: Offset(0, 4)),
  ];

  static const s3 = [
    BoxShadow(color: Color(0x24101828), blurRadius: 34, offset: Offset(0, 12)),
  ];
}

/// 字号与字重。
///
/// 中文正文最小 13，题干正文 14–15，行高统一偏大（1.9–2.2），
/// 因为数学题里混排公式，行高不够会显得拥挤。
///
/// ## ⚠️ 每一条都必须带 `color`
///
/// 这些 token 会被 `ThemeData.textTheme.copyWith(...)` **整体替换**掉
/// Flutter 默认的对应样式（如 `bodyMedium`），而默认样式是**带颜色的**。
/// 替换时不写 `color`，就等于把颜色抹成 null，于是：
///
/// - 所有**没有显式指定颜色**的 `Text` 都会丢失颜色，在浅色背景上几乎看不见
/// - 症状极具迷惑性：布局、间距、交互全都正常，就是"字没了"，
///   而且 widget 测试不会失败（测试断言的是文本内容，不是颜色）
///
/// 本项目就这样真实翻过一次车：公式键盘的按钮渲染成了 8 个空白按钮。
/// `test/theme_test.dart` 里有一条用例专门守住这件事。
abstract final class AppTypography {
  static const pageTitle = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    height: 1.3,
    color: AppColors.ink1,
  );

  static const sectionTitle = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
    height: 1.4,
    color: AppColors.ink1,
  );

  static const body =
      TextStyle(fontSize: 14, height: 1.6, color: AppColors.ink1);
  static const bodyStrong = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.6,
    color: AppColors.ink1,
  );

  /// 题干正文。行高刻意放大以容纳公式。
  static const stem =
      TextStyle(fontSize: 15, height: 2.1, color: AppColors.ink1);

  static const caption = TextStyle(fontSize: 12, color: AppColors.ink3);
  static const label = TextStyle(
    fontSize: 11.5,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.4,
    color: AppColors.ink3,
  );

  /// 等宽：显示 LaTeX 源码。
  ///
  /// 同样带 color —— 理由见上面的说明，漏一条就会有一处文字隐形。
  static const mono = TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    height: 1.6,
    color: AppColors.ink2,
  );
}

/// 主题构建。
abstract final class AppTheme {
  static ThemeData light() {
    const scheme = ColorScheme.light(
      primary: AppColors.primary,
      onPrimary: Colors.white,
      primaryContainer: AppColors.primaryWeak,
      onPrimaryContainer: AppColors.primaryStrong,
      secondary: AppColors.purple,
      onSecondary: Colors.white,
      secondaryContainer: AppColors.purpleWeak,
      onSecondaryContainer: AppColors.purple,
      error: AppColors.danger,
      onError: Colors.white,
      errorContainer: AppColors.dangerWeak,
      surface: AppColors.surface,
      onSurface: AppColors.ink1,
      onSurfaceVariant: AppColors.ink2,
      outline: AppColors.line,
      outlineVariant: AppColors.line,
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: AppColors.bg,
      surfaceContainer: AppColors.surface2,
      surfaceContainerHigh: AppColors.surface2,
    );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.bg,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
    );

    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        titleLarge: AppTypography.sectionTitle,
        bodyMedium: AppTypography.body,
        bodySmall: AppTypography.caption,
        labelSmall: AppTypography.label,
      ),
      cardTheme: const CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.rLg),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.line,
        thickness: 1,
        space: 1,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.ink1,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: AppTypography.sectionTitle,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, AppSpacing.minTouchTarget),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.rMd),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.ink1,
          side: const BorderSide(color: AppColors.line, width: 1.2),
          minimumSize: const Size(0, AppSpacing.minTouchTarget),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.rMd),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primary,
          minimumSize: const Size(0, AppSpacing.minTouchTarget),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.rMd),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface2,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: const OutlineInputBorder(
          borderRadius: AppRadius.rMd,
          borderSide: BorderSide.none,
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: AppRadius.rMd,
          borderSide: BorderSide.none,
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: AppRadius.rMd,
          borderSide: BorderSide(color: AppColors.primary, width: 1.6),
        ),
        hintStyle: const TextStyle(color: AppColors.ink4, fontSize: 14),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.surface2,
        side: BorderSide.none,
        labelStyle: const TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: AppColors.ink2,
        ),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(7)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: AppColors.ink1,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        textStyle: const TextStyle(fontSize: 12, color: Colors.white),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all(8),
        radius: const Radius.circular(4),
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.hovered)
              ? AppColors.ink4
              : AppColors.line,
        ),
      ),
    );
  }
}
