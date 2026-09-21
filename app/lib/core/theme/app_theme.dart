/// 设计系统 —— 与 `ui-mockups/*.html` 里定义的 token 一一对应。
///
/// 改这里的值，UI 原型和实际 App 会同步变化。**不要在各页面里写死颜色、字号。**
library;

import 'package:flutter/material.dart';

import 'app_fonts.dart';

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

  /// 警示文字色。
  ///
  /// ⚠️ 这个值由**对比度**定，不是审美定的：早先是 `#B96A05`，在卡片底色
  /// (`bg`) 上只有 **3.82:1**、白底上 4.10:1，都低于 WCAG AA 对正文的
  /// 4.5:1 —— 而它承载的是"常见陷阱""导出注意事项"这类**必须读**的内容。
  /// 现取 `#9A5604`：bg 上 5.28:1、白底 5.67:1、`warningWeak` 上 5.21:1。
  /// 由 `test/knowledge_palette_test.dart` 守着。
  static const warningInk = Color(0xFF9A5604);

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
///
/// ## ⚠️ 每一条也都必须带**字体族**
///
/// 与 `color` 是同一个机制：这些 token 会被 `textTheme.copyWith(...)`
/// **整体替换**掉默认样式，而默认样式是带 `fontFamily` 的。不写字体族，
/// 继承链就在这里断掉 —— 而 `DefaultTextStyle` 正是从 `bodyMedium` 派生的，
/// 于是页面上所有 `TextStyle(fontSize: X)`（它们自己不带字体族）全部失去
/// 中文字体，退回 Skia 的隐式回退。
///
/// 这就是「字体类型不定」的机制：本文件里漏一条，那一处的文字就换一个字体。
abstract final class AppTypography {
  static const pageTitle = TextStyle(
    fontFamily: AppFonts.sans,
    fontFamilyFallback: AppFonts.sansFallback,
    fontSize: 22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    height: 1.3,
    color: AppColors.ink1,
  );

  static const sectionTitle = TextStyle(
    fontFamily: AppFonts.sans,
    fontFamilyFallback: AppFonts.sansFallback,
    fontSize: 16,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
    height: 1.4,
    color: AppColors.ink1,
  );

  static const body = TextStyle(
    fontFamily: AppFonts.sans,
    fontFamilyFallback: AppFonts.sansFallback,
    fontSize: 14,
    height: 1.6,
    color: AppColors.ink1,
  );
  static const bodyStrong = TextStyle(
    fontFamily: AppFonts.sans,
    fontFamilyFallback: AppFonts.sansFallback,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.6,
    color: AppColors.ink1,
  );

  /// 题干正文。行高刻意放大以容纳公式。
  static const stem = TextStyle(
    fontFamily: AppFonts.sans,
    fontFamilyFallback: AppFonts.sansFallback,
    fontSize: 15,
    height: 2.1,
    color: AppColors.ink1,
  );

  static const caption = TextStyle(
    fontFamily: AppFonts.sans,
    fontFamilyFallback: AppFonts.sansFallback,
    fontSize: 12,
    color: AppColors.ink3,
  );
  static const label = TextStyle(
    fontFamily: AppFonts.sans,
    fontFamilyFallback: AppFonts.sansFallback,
    fontSize: 11.5,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.4,
    color: AppColors.ink3,
  );

  /// 等宽：显示 LaTeX 源码与文件路径。
  ///
  /// 同样带 color —— 理由见上面的说明，漏一条就会有一处文字隐形。
  ///
  /// ⚠️ 这里**必须带中文回退**：它渲染的路径完全可能是中文
  /// （`D:\我的题库\library`），而 Consolas 没有汉字字形。
  static const mono = TextStyle(
    fontFamily: AppFonts.mono,
    fontFamilyFallback: AppFonts.monoFallback,
    fontSize: 12,
    height: 1.6,
    color: AppColors.ink2,
  );
}

/// 公式字号。
///
/// ## 为什么需要集中
///
/// 改这里之前，公式字号散落在 12.5 / 13 / 13.5 / 14 四个值上，而且
/// **同一个页面里就不一致**：知识库详情页的「核心公式」显式传了 12.5、
/// 而「别名公式」没传（用默认 14）—— 两行公式一大一小，用户看到的就是
/// 「公式大小不一致」。
///
/// 更具体的教训：`kFormulaFontSize` 的注释早就写明「为什么是 14 而不是
/// 12.5」（KaTeX 上下标只有 70%，12.5px 时下标只剩 8.8px），但调用点
/// 硬编码传了 12.5，把那个决定整个覆盖掉了 —— 常量改对了、行为没变。
/// **所以字号要能从一个地方看见全貌**，而不是散在各调用点。
///
/// 同一处缺陷后来还**残留了一次**：核心公式修好之后，
/// 「别名公式」那行仍留着 `fontSize: 13`，于是变成 16 与 13 并存。
/// 现在由 `test/knowledge_size_test.dart` 直接扫源码守住调用点不得覆盖。
///
/// ## 为什么是两档而不是一档
///
/// 分档依据是**阅读距离**，不是页面：
/// - [compact] 列表、核对这类一屏要塞下更多条目、以扫读为主的地方
/// - [reading] 详情、复习、知识库、录入预览这类逐字读的地方
///
/// 强行拉成一档会让列表项变高（减小每屏信息量）或让详情页的公式变小
/// （正是上面那个 12.5 的老问题），两个都得付出代价。
abstract final class AppMathSizes {
  const AppMathSizes._();

  /// 紧凑：错题本列表、批量导入核对。
  static const double compact = 13;

  /// 阅读：知识库详情、复习、录入预览。
  ///
  /// ## 为什么是 16（用户反馈"公式过小"后从 14 提上来）
  ///
  /// KaTeX 的上下标按主字号的 **70%** 渲染，正文里的公式大小直接决定
  /// 上下标可不可读：
  ///
  /// | 主字号 | 上下标 | 评价 |
  /// |---|---|---|
  /// | 12.5 | 8.8 | 用户反馈"公式太小"（第一次） |
  /// | 14 | 9.8 | 仍偏小（第二次反馈） |
  /// | **16** | **11.2** | 与 `secondary` 档（12）接近，能读 |
  ///
  /// 另一条依据是与周围文字的关系：知识库详情正文是 13、题干是 15，
  /// 公式却只有 14 —— **公式比正文还小**。提到 16 后它与题干同档，
  /// 视觉上"公式是主角"这件事才立得住。
  static const double reading = 16;

  /// 独立公式（`MathStyle.display`）。
  ///
  /// 比 [reading] 再大一档：独立成行的公式是"要盯着看"的内容。
  static const double display = 18;
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

    // ⚠️ 字体族必须在**这一层**给出，它是全应用继承链的根。
    //
    // `ThemeData` 的 `fontFamilyFallback` 只会被应用到它自己构造出来的
    // **默认** textTheme 上（见 Flutter 的 `theme_data.dart` 第 514 行附近），
    // 而下面 `copyWith(textTheme: ...)` 又替换掉了其中四个条目 ——
    // 那四个条目自己也带字体族（见 `AppTypography`）。两边都写才是一条
    // 完整的链：少写这一层，页面上所有裸 `TextStyle(fontSize: X)` 都会
    // 退回 Skia 的隐式回退，「字体类型不定」就是这么来的。
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.bg,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      fontFamily: AppFonts.sans,
      fontFamilyFallback: AppFonts.sansFallback,
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
          textStyle: const TextStyle(
            fontFamily: AppFonts.sans,
            fontFamilyFallback: AppFonts.sansFallback,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.ink1,
          side: const BorderSide(color: AppColors.line, width: 1.2),
          minimumSize: const Size(0, AppSpacing.minTouchTarget),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.rMd),
          textStyle: const TextStyle(
            fontFamily: AppFonts.sans,
            fontFamilyFallback: AppFonts.sansFallback,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primary,
          minimumSize: const Size(0, AppSpacing.minTouchTarget),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.rMd),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface2,
        contentPadding:
            EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: AppRadius.rMd,
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.rMd,
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.rMd,
          borderSide: BorderSide(color: AppColors.primary, width: 1.6),
        ),
        hintStyle: TextStyle(
          fontFamily: AppFonts.sans,
          fontFamilyFallback: AppFonts.sansFallback,
          color: AppColors.ink4,
          fontSize: 14,
        ),
      ),
      chipTheme: const ChipThemeData(
        backgroundColor: AppColors.surface2,
        side: BorderSide.none,
        labelStyle: TextStyle(
          fontFamily: AppFonts.sans,
          fontFamilyFallback: AppFonts.sansFallback,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: AppColors.ink2,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(7)),
        ),
        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 0),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: AppColors.ink1,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        textStyle: const TextStyle(
          fontFamily: AppFonts.sans,
          fontFamilyFallback: AppFonts.sansFallback,
          fontSize: 12,
          color: Colors.white,
        ),
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
