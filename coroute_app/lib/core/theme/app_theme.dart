import 'package:flutter/material.dart';

class AppTheme {
  // Backgrounds
  static const Color obsidianVoid = Color(0xFF090D14);
  static const Color darkCanvas = Color(0xFF0F1520);
  static const Color slateCard = Color(0xFF161F2E);
  static const Color elevatedCard = Color(0xFF1C2738);
  static const Color glassBorder = Color(0x334FD1C5);
  static const Color subtleBorder = Color(0x1FFFFFFF);

  // Accents & Signals
  static const Color neonCyan = Color(0xFF00E5FF);
  static const Color electricBlue = Color(0xFF2979FF);
  static const Color hyperAmber = Color(0xFFFF9100);
  static const Color laserRed = Color(0xFFFF1744);
  static const Color emeraldSafe = Color(0xFF00E676);
  static const Color speedWarning = Color(0xFFFF5252);
  static const Color devmonksPurple = Color(0xFF7C4DFF);

  // Text
  static const Color textPrimary = Color(0xFFF8FAFC);
  static const Color textSecondary = Color(0xFF94A3B8);
  static const Color textMuted = Color(0xFF64748B);

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: obsidianVoid,
      primaryColor: neonCyan,
      canvasColor: darkCanvas,
      cardColor: slateCard,
      colorScheme: const ColorScheme.dark(
        primary: neonCyan,
        secondary: hyperAmber,
        surface: slateCard,
        error: laserRed,
        onPrimary: Colors.black,
        onSurface: textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: obsidianVoid,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: neonCyan,
          foregroundColor: Colors.black,
          elevation: 4,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: slateCard,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: subtleBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: subtleBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: neonCyan, width: 1.5),
        ),
        hintStyle: const TextStyle(color: textMuted),
        labelStyle: const TextStyle(color: textSecondary),
      ),
    );
  }
}
