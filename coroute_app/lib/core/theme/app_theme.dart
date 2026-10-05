import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_palette.dart';

/// The app's colours and Material theme.
///
/// The colour names are getters over the active [AppPalette], so every screen
/// follows the current theme (dark or light) without passing a context
/// around. [ThemeController] switches the palette; because the getters are
/// not compile-time constants, widgets that use them are not `const`.
class AppTheme {
  AppTheme._();

  static AppPalette _p = AppPalette.dark;

  /// The palette in use right now.
  static AppPalette get palette => _p;
  static bool get isLight => _p.isLight;

  /// Switches the palette. Call [ThemeController] instead of this directly.
  static void use(AppPalette p) {
    _p = p;
    SystemChrome.setSystemUIOverlayStyle(overlayStyle);
  }

  // Backgrounds
  static Color get obsidianVoid => _p.obsidianVoid;
  static Color get darkCanvas => _p.darkCanvas;
  static Color get slateCard => _p.slateCard;
  static Color get elevatedCard => _p.elevatedCard;
  static Color get glassBorder => _p.glassBorder;
  static Color get subtleBorder => _p.subtleBorder;

  // Accents & signals
  static Color get neonCyan => _p.neonCyan;
  static Color get electricBlue => _p.electricBlue;
  static Color get hyperAmber => _p.hyperAmber;
  static Color get laserRed => _p.laserRed;
  static Color get emeraldSafe => _p.emeraldSafe;
  static Color get speedWarning => _p.speedWarning;
  static Color get devmonksPurple => _p.devmonksPurple;

  // Text
  static Color get textPrimary => _p.textPrimary;
  static Color get textSecondary => _p.textSecondary;
  static Color get textMuted => _p.textMuted;

  static Color get shadow => _p.shadow;
  static Color get heroTop => _p.heroTop;

  static SystemUiOverlayStyle get overlayStyle => SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: _p.isLight ? Brightness.dark : Brightness.light,
        statusBarBrightness: _p.isLight ? Brightness.light : Brightness.dark, // iOS
        systemNavigationBarColor: _p.obsidianVoid,
        systemNavigationBarIconBrightness: _p.isLight ? Brightness.dark : Brightness.light,
      );

  static ThemeData get darkTheme => themeFor(AppPalette.dark);
  static ThemeData get lightTheme => themeFor(AppPalette.light);

  static ThemeData themeFor(AppPalette p) {
    final base = p.isLight
        ? ColorScheme.light(
            primary: p.neonCyan,
            secondary: p.hyperAmber,
            surface: p.slateCard,
            error: p.laserRed,
            onPrimary: Colors.black,
            onSecondary: Colors.black,
            onSurface: p.textPrimary,
          )
        : ColorScheme.dark(
            primary: p.neonCyan,
            secondary: p.hyperAmber,
            surface: p.slateCard,
            error: p.laserRed,
            onPrimary: Colors.black,
            onSecondary: Colors.black,
            onSurface: p.textPrimary,
          );
    return ThemeData(
      brightness: p.brightness,
      scaffoldBackgroundColor: p.obsidianVoid,
      primaryColor: p.neonCyan,
      canvasColor: p.darkCanvas,
      cardColor: p.slateCard,
      dividerColor: p.subtleBorder,
      colorScheme: base,
      appBarTheme: AppBarTheme(
        backgroundColor: p.obsidianVoid,
        foregroundColor: p.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        systemOverlayStyle: p.isLight ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light,
        titleTextStyle: TextStyle(
          color: p.textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
      iconTheme: IconThemeData(color: p.textSecondary),
      listTileTheme: ListTileThemeData(textColor: p.textPrimary, iconColor: p.textSecondary),
      dialogTheme: DialogThemeData(backgroundColor: p.slateCard),
      bottomSheetTheme: BottomSheetThemeData(backgroundColor: p.slateCard, modalBackgroundColor: p.slateCard),
      popupMenuTheme: PopupMenuThemeData(color: p.elevatedCard),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.isLight ? const Color(0xFF1E293B) : p.elevatedCard,
        contentTextStyle: const TextStyle(color: Color(0xFFF8FAFC)),
        behavior: SnackBarBehavior.floating,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.neonCyan,
          foregroundColor: Colors.black,
          elevation: p.isLight ? 1 : 4,
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
        fillColor: p.slateCard,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: p.subtleBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: p.isLight ? const Color(0x400F172A) : p.subtleBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: p.neonCyan, width: 1.5),
        ),
        hintStyle: TextStyle(color: p.textMuted),
        labelStyle: TextStyle(color: p.textSecondary),
      ),
    );
  }
}
