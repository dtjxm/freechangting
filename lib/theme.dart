/// v1.2.0 全局主题：LOGO 橙金主题色 + 浅色/深色/跟随系统
library;

import 'package:flutter/material.dart';

/// LOGO 提取色
const kBrand = Color(0xFFF0801F); // LOGO 橙（主色）
const kGold = Color(0xFFF2B33D); // LOGO 金（辅色）
const kBrandWeakLight = Color(0xFFFDEBD7); // 浅色主题弱底
const kBrandWeakDark = Color(0xFF3B2A16); // 深色主题弱底

/// 深浅色自适应语义色（页面内统一从这里取色，禁止再硬编码）
extension AppThemeX on BuildContext {
  bool get isDark => Theme.of(this).brightness == Brightness.dark;

  Color get brand => kBrand;
  Color get gold => kGold;
  Color get brandWeak => isDark ? kBrandWeakDark : kBrandWeakLight;

  /// 页面背景
  Color get bg => isDark ? const Color(0xFF101216) : const Color(0xFFF6F7F8);

  /// 卡片背景
  Color get card => isDark ? const Color(0xFF1B1E23) : Colors.white;

  /// 次级面板背景（频道栏 / 筛选栏 / 底部弹层）
  Color get subBg => isDark ? const Color(0xFF14171C) : Colors.white;

  /// 芯片 / 占位底色
  Color get chipBg => isDark ? const Color(0xFF24272D) : const Color(0xFFF1F2F3);

  Color get divider => isDark ? const Color(0xFF2A2E35) : const Color(0xFFE3E5E7);

  /// 主文字
  Color get tMain => isDark ? const Color(0xFFE8EAED) : const Color(0xFF18191C);

  /// 次要文字
  Color get tSub => isDark ? const Color(0xFF8A9099) : const Color(0xFF9499A0);

  /// 弱文字（提示/角标）
  Color get tFaint => isDark
      ? Colors.white.withValues(alpha: 0.4)
      : Colors.black.withValues(alpha: 0.4);
}

ThemeData _base(Brightness bright) {
  final isLight = bright == Brightness.light;
  final scheme = ColorScheme.fromSeed(seedColor: kBrand, brightness: bright)
      .copyWith(primary: kBrand, secondary: kGold);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: bright,
    scaffoldBackgroundColor: isLight ? const Color(0xFFF6F7F8) : const Color(0xFF101216),
    appBarTheme: AppBarTheme(
      backgroundColor: isLight ? Colors.white : const Color(0xFF101216),
      foregroundColor: isLight ? const Color(0xFF18191C) : const Color(0xFFE8EAED),
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      elevation: isLight ? 0.4 : 0,
      scrolledUnderElevation: 0.4,
    ),
    cardTheme: CardThemeData(
      color: isLight ? Colors.white : const Color(0xFF1A1D23),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: isLight ? Colors.white : const Color(0xFF14171C),
      indicatorColor: kBrandWeakLight,
    ),
    dividerColor: isLight ? const Color(0xFFE3E5E7) : const Color(0xFF2A2E35),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

ThemeData buildLightTheme() => _base(Brightness.light);
ThemeData buildDarkTheme() => _base(Brightness.dark);
