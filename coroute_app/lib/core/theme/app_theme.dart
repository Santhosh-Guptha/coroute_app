import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../ui/ui_tokens.dart';
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
  static Color get infoBlue => _p.infoBlue;
  static Color get offlineGrey => _p.offlineGrey;

  // Text
  static Color get textPrimary => _p.textPrimary;
  static Color get textSecondary => _p.textSecondary;
  static Color get textMuted => _p.textMuted;

  static Color get shadow => _p.shadow;
  static Color get heroTop => _p.heroTop;

  // Design-canvas tokens (preferred in new/restyled screens)
  static Color get bg => _p.bg;
  static Color get card => _p.card;
  static Color get soft => _p.soft;
  static Color get map => _p.map;
  static Color get road => _p.road;
  static Color get border => _p.border;
  static Color get border2 => _p.border2;
  static Color get tint => _p.tint;
  static Color get brand => _p.brand;
  static Color get accentText => _p.accentText;
  static Color get warnText => _p.warnText;
  static Color get warnTint => _p.warnTint;
  static Color get warnBorder => _p.warnBorder;
  static Color get sos => _p.sos;
  static Color get text => _p.text;
  static Color get text2 => _p.text2;
  static Color get muted => _p.muted;

  /// App typeface (bundled, see pubspec `fonts`).
  static const String fontFamily = 'Manrope';

  static SystemUiOverlayStyle get overlayStyle => SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: _p.isLight ? Brightness.dark : Brightness.light,
        statusBarBrightness: _p.isLight ? Brightness.light : Brightness.dark, // iOS
        systemNavigationBarColor: _p.bg,
        systemNavigationBarIconBrightness: _p.isLight ? Brightness.dark : Brightness.light,
      );

  static ThemeData get darkTheme => themeFor(AppPalette.dark);
  static ThemeData get lightTheme => themeFor(AppPalette.light);

  static ThemeData themeFor(AppPalette p) {
    final base = p.isLight
        ? ColorScheme.light(
            primary: p.brand,
            secondary: p.warnText,
            surface: p.card,
            error: p.sos,
            onPrimary: Colors.white,
            onSecondary: Colors.white,
            onSurface: p.text,
            outline: p.border2,
          )
        : ColorScheme.dark(
            primary: p.brand,
            secondary: p.warnText,
            surface: p.card,
            error: p.sos,
            onPrimary: Colors.white,
            onSecondary: Colors.black,
            onSurface: p.text,
            outline: p.border2,
          );
    return ThemeData(
      brightness: p.brightness,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: p.bg,
      primaryColor: p.brand,
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
          color: p.text,
          fontFamily: fontFamily,
          fontSize: 22,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.3,
        ),
      ),
      iconTheme: IconThemeData(color: p.textSecondary),
      listTileTheme: ListTileThemeData(textColor: p.textPrimary, iconColor: p.textSecondary),
      dialogTheme: DialogThemeData(
        backgroundColor: p.slateCard,
        shape: const RoundedRectangleBorder(borderRadius: Radii.xlAll),
      ),
      // The drag handle is not switched on for every sheet here: older sheets
      // draw their own. showAppSheet (lib/core/ui) turns it on.
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.slateCard,
        modalBackgroundColor: p.slateCard,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: Radii.sheetTop),
        dragHandleColor: p.border2,
        dragHandleSize: const Size(44, 5),
      ),
      cardTheme: CardThemeData(
        color: p.card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: Radii.lgAll, side: BorderSide(color: p.border, width: 2)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.brand,
          foregroundColor: Colors.white,
          minimumSize: const Size(64, 56),
          shape: const RoundedRectangleBorder(borderRadius: Radii.lgAll),
          textStyle: const TextStyle(fontFamily: fontFamily, fontSize: 16, fontWeight: FontWeight.w800),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.text,
          backgroundColor: p.card,
          minimumSize: const Size(64, 56),
          side: BorderSide(color: p.border, width: 2),
          shape: const RoundedRectangleBorder(borderRadius: Radii.lgAll),
          textStyle: const TextStyle(fontFamily: fontFamily, fontSize: 15, fontWeight: FontWeight.w800),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.accentText,
          shape: const RoundedRectangleBorder(borderRadius: Radii.mdAll),
          textStyle: const TextStyle(fontFamily: fontFamily, fontSize: 14, fontWeight: FontWeight.w800),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStatePropertyAll(p.card),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? p.brand : p.border2,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: p.soft,
        selectedColor: p.tint,
        side: BorderSide(color: p.border),
        labelStyle: TextStyle(color: p.text, fontFamily: fontFamily, fontWeight: FontWeight.w700, fontSize: 13),
        shape: const RoundedRectangleBorder(borderRadius: Radii.smAll),
      ),
      dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.bg,
        surfaceTintColor: Colors.transparent,
        indicatorColor: Colors.transparent,
        indicatorShape: const RoundedRectangleBorder(borderRadius: Radii.mdAll),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        height: 64,
        elevation: 0,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 24,
            color: states.contains(WidgetState.selected) ? p.accentText : p.muted,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontFamily: fontFamily,
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w700,
            color: states.contains(WidgetState.selected) ? p.accentText : p.muted,
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(color: p.card),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.isLight ? const Color(0xFF15232E) : p.soft,
        contentTextStyle: const TextStyle(color: Color(0xFFF8FAFC)),
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: Radii.mdAll),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.brand,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: const RoundedRectangleBorder(borderRadius: Radii.lgAll),
          textStyle: const TextStyle(
            fontFamily: fontFamily,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.card,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: p.border, width: 2),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: p.border, width: 2),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: p.brand, width: 2),
        ),
        hintStyle: TextStyle(color: p.muted, fontWeight: FontWeight.w600),
        labelStyle: TextStyle(color: p.text2, fontWeight: FontWeight.w700),
      ),
    );
  }
}
