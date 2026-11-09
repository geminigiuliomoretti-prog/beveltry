import 'package:flutter/material.dart';

class WhoopColors {
  static const Color background = Color(0xFF0B0E14);
  static const Color surface = Color(0xFF121721);
  static const Color surfaceHighlight = Color(0xFF1B2230);
  static const Color surfaceBorder = Color(0xFF263245);

  static const Color textPrimary = Color(0xFFF0F4F8);
  static const Color textSecondary = Color(0xFF8B9CB0);
  static const Color textMuted = Color(0xFF5A6878);

  static const Color green = Color(0xFF00E676);
  static const Color yellow = Color(0xFFFFD600);
  static const Color red = Color(0xFFFF3D00);

  static const Color strainBlue = Color(0xFF00B0FF);
  static const Color sleepTeal = Color(0xFF00E5FF);
  static const Color stressPurple = Color(0xFFB388FF);
  static const Color hrRed = Color(0xFFFF1744);
}

ThemeData buildWhoopTheme() {
  return ThemeData.dark().copyWith(
    scaffoldBackgroundColor: WhoopColors.background,
    primaryColor: WhoopColors.green,
    cardColor: WhoopColors.surface,
    colorScheme: const ColorScheme.dark(
      primary: WhoopColors.green,
      secondary: WhoopColors.strainBlue,
      surface: WhoopColors.surface,
      error: WhoopColors.red,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: WhoopColors.background,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: WhoopColors.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
      ),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: WhoopColors.surface,
      selectedItemColor: WhoopColors.green,
      unselectedItemColor: WhoopColors.textMuted,
      showUnselectedLabels: true,
      type: BottomNavigationBarType.fixed,
      elevation: 8,
    ),
  );
}
