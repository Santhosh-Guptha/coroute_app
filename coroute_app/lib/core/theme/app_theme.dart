import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../ui/app_motion.dart' show appPageTransitionsTheme;
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

  // v3.55 tokens (preferred in new/restyled code; see docs/DESIGN_SYSTEM_v3.55.md)
  static Color get background => _p.background;
  static Color get surface => _p.surface;
  static Color get surfaceAlt => _p.surfaceAlt;
  static Color get borderStrong => _p.borderStrong;
  static Color get textFaint => _p.textFaint;
  static Color get primary => _p.primary;
  static Color get onPrimary => _p.onPrimary;
  static Color get primarySoft => _p.primarySoft;
  static Color get primaryFill => _p.primaryFill;
  static Color get accent => _p.accent;
  static Color get accentSoft => _p.accentSoft;
  static Color get accentStrong => _p.accentStrong;
  static Color get success => _p.success;
  static Color get warning => _p.warning;
  static Color get danger => _p.danger;
  static Color get info => _p.info;

  // Older canvas names (kept; they map onto the v3.55 tokens)
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

  /// Material text theme on the v3.55 type scale: 400 body, 500 labels,
  /// 600 titles, 700 only for display numbers; line height 1.4-1.5.
  static TextTheme _textTheme(AppPalette p) {
    TextStyle s(double size, FontWeight w, Color c, [double h = 1.45]) =>
        TextStyle(fontFamily: fontFamily, fontSize: size, fontWeight: w, color: c, height: h, letterSpacing: 0);
    return TextTheme(
      displayLarge: s(48, FontWeight.w700, p.text, 1.1),
      displayMedium: s(40, FontWeight.w700, p.text, 1.1),
      displaySmall: s(32, FontWeight.w700, p.text, 1.15),
      headlineLarge: s(28, FontWeight.w600, p.text, 1.25),
      headlineMedium: s(24, FontWeight.w600, p.text, 1.3),
      headlineSmall: s(22, FontWeight.w600, p.text, 1.3),
      titleLarge: s(20, FontWeight.w600, p.text, 1.35),
      titleMedium: s(16, FontWeight.w600, p.text, 1.4),
      titleSmall: s(14, FontWeight.w600, p.text, 1.4),
      bodyLarge: s(16, FontWeight.w400, p.text),
      bodyMedium: s(15, FontWeight.w400, p.text),
      bodySmall: s(13, FontWeight.w400, p.textMuted, 1.4),
      labelLarge: s(15, FontWeight.w500, p.text, 1.4),
      labelMedium: s(13, FontWeight.w500, p.textMuted, 1.4),
      labelSmall: s(12, FontWeight.w500, p.textMuted, 1.4),
    );
  }

  static ThemeData themeFor(AppPalette p) {
    final scheme = ColorScheme(
      brightness: p.brightness,
      primary: p.primary,
      onPrimary: p.onPrimary,
      primaryContainer: p.primarySoft,
      onPrimaryContainer: p.text,
      secondary: p.accent,
      onSecondary: p.isLight ? Colors.white : p.background,
      secondaryContainer: p.accentSoft,
      onSecondaryContainer: p.text,
      tertiary: p.info,
      onTertiary: p.isLight ? Colors.white : p.background,
      error: p.danger,
      onError: p.isLight ? Colors.white : p.background,
      errorContainer: p.isLight ? const Color(0xFFF8E1DE) : const Color(0xFF3D2220),
      onErrorContainer: p.text,
      surface: p.surface,
      onSurface: p.text,
      onSurfaceVariant: p.textMuted,
      surfaceContainerLowest: p.surface,
      surfaceContainerLow: p.surface,
      surfaceContainer: p.surface,
      surfaceContainerHigh: p.surfaceAlt,
      surfaceContainerHighest: p.surfaceAlt,
      outline: p.borderStrong,
      outlineVariant: p.border,
      shadow: p.shadow,
      scrim: const Color(0x66000000),
      inverseSurface: p.text,
      onInverseSurface: p.background,
      inversePrimary: p.isLight ? AppPalette.dark.primary : AppPalette.light.primary,
      surfaceTint: Colors.transparent,
    );
    final text = _textTheme(p);
    const buttonText = TextStyle(fontFamily: fontFamily, fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 0);
    const buttonShape = RoundedRectangleBorder(borderRadius: Radii.mdAll);
    OutlineInputBorder field(Color c, [double w = 1]) =>
        OutlineInputBorder(borderRadius: Radii.mdAll, borderSide: BorderSide(color: c, width: w));

    return ThemeData(
      useMaterial3: true,
      brightness: p.brightness,
      fontFamily: fontFamily,
      colorScheme: scheme,
      textTheme: text,
      primaryTextTheme: text,
      scaffoldBackgroundColor: p.background,
      primaryColor: p.primary,
      canvasColor: p.background,
      cardColor: p.surface,
      dividerColor: p.border,
      hintColor: p.textFaint,
      splashFactory: InkRipple.splashFactory,
      // Round 7: iOS-style slide + parallax + edge-swipe back on every page; safety routes appear at once
      // (lib/core/ui/app_motion.dart).
      pageTransitionsTheme: appPageTransitionsTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: p.background,
        foregroundColor: p.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        systemOverlayStyle: p.isLight ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light,
        iconTheme: IconThemeData(color: p.text, size: 24),
        titleTextStyle: TextStyle(color: p.text, fontFamily: fontFamily, fontSize: 20, fontWeight: FontWeight.w600, height: 1.3),
      ),
      iconTheme: IconThemeData(color: p.textMuted, size: 24),
      listTileTheme: ListTileThemeData(
        textColor: p.text,
        iconColor: p.textMuted,
        titleTextStyle: text.bodyLarge!.copyWith(fontWeight: FontWeight.w500),
        subtitleTextStyle: text.bodySmall,
        shape: const RoundedRectangleBorder(borderRadius: Radii.mdAll),
        minVerticalPadding: 10,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        shadowColor: p.shadow,
        shape: RoundedRectangleBorder(borderRadius: Radii.xlAll, side: BorderSide(color: p.border)),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium!.copyWith(color: p.textMuted),
      ),
      // The drag handle is not switched on for every sheet here: older sheets
      // draw their own. showAppSheet (lib/core/ui) turns it on.
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.surface,
        modalBackgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: Radii.sheetTop),
        dragHandleColor: p.borderStrong,
        dragHandleSize: const Size(36, 4),
      ),
      cardTheme: CardThemeData(
        color: p.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: Radii.lgAll, side: BorderSide(color: p.border)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.primary,
          foregroundColor: p.onPrimary,
          disabledBackgroundColor: p.surfaceAlt,
          disabledForegroundColor: p.textFaint,
          minimumSize: const Size(64, 52),
          elevation: 0,
          shape: buttonShape,
          textStyle: buttonText,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.primary,
          foregroundColor: p.onPrimary,
          disabledBackgroundColor: p.surfaceAlt,
          disabledForegroundColor: p.textFaint,
          elevation: 0,
          shadowColor: Colors.transparent,
          minimumSize: const Size(64, 52),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: buttonShape,
          textStyle: buttonText,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.text,
          backgroundColor: p.surface,
          minimumSize: const Size(64, 52),
          side: BorderSide(color: p.borderStrong),
          shape: buttonShape,
          textStyle: buttonText.copyWith(fontSize: 15, fontWeight: FontWeight.w500),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.primary,
          minimumSize: const Size(48, 48),
          shape: buttonShape,
          textStyle: buttonText.copyWith(fontSize: 15, fontWeight: FontWeight.w500),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: p.textMuted, minimumSize: const Size(48, 48)),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: p.primary,
        foregroundColor: p.onPrimary,
        elevation: 1,
        focusElevation: 1,
        hoverElevation: 2,
        highlightElevation: 1,
        shape: const RoundedRectangleBorder(borderRadius: Radii.lgAll),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? p.onPrimary : p.surface,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? p.primary : p.borderStrong,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? p.primary : Colors.transparent,
        ),
        checkColor: WidgetStatePropertyAll(p.onPrimary),
        side: BorderSide(color: p.borderStrong, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? p.primary : p.borderStrong,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: p.primary,
        inactiveTrackColor: p.surfaceAlt,
        thumbColor: p.primary,
        overlayColor: p.primary.withValues(alpha: 0.12),
        valueIndicatorColor: p.text,
        valueIndicatorTextStyle: TextStyle(color: p.background, fontFamily: fontFamily, fontWeight: FontWeight.w500),
        trackHeight: 4,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.primary,
        linearTrackColor: p.surfaceAlt,
        circularTrackColor: Colors.transparent,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: p.surfaceAlt,
        selectedColor: p.primarySoft,
        disabledColor: p.surfaceAlt,
        checkmarkColor: p.primary,
        side: BorderSide(color: p.border),
        labelStyle: TextStyle(color: p.text, fontFamily: fontFamily, fontWeight: FontWeight.w500, fontSize: 13),
        secondaryLabelStyle: TextStyle(color: p.text, fontFamily: fontFamily, fontWeight: FontWeight.w500, fontSize: 13),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        shape: const StadiumBorder(),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? p.primarySoft : p.surface,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? p.text : p.textMuted,
          ),
          side: WidgetStatePropertyAll(BorderSide(color: p.border)),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: fontFamily, fontWeight: FontWeight.w500)),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: p.text,
        unselectedLabelColor: p.textMuted,
        indicatorColor: p.primary,
        dividerColor: p.border,
        labelStyle: const TextStyle(fontFamily: fontFamily, fontSize: 14, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontFamily: fontFamily, fontSize: 14, fontWeight: FontWeight.w500),
      ),
      dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: p.primarySoft,
        indicatorShape: const StadiumBorder(),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        height: 64,
        elevation: 0,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 24,
            color: states.contains(WidgetState.selected) ? p.primary : p.textMuted,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontFamily: fontFamily,
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
            color: states.contains(WidgetState.selected) ? p.text : p.textMuted,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: p.surface,
        indicatorColor: p.primarySoft,
        selectedIconTheme: IconThemeData(color: p.primary, size: 24),
        unselectedIconTheme: IconThemeData(color: p.textMuted, size: 24),
        selectedLabelTextStyle: TextStyle(fontFamily: fontFamily, fontSize: 12, fontWeight: FontWeight.w600, color: p.text),
        unselectedLabelTextStyle: TextStyle(fontFamily: fontFamily, fontSize: 12, fontWeight: FontWeight.w500, color: p.textMuted),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: p.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: Radii.mdAll, side: BorderSide(color: p.border)),
        textStyle: text.bodyMedium,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(p.surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          side: WidgetStatePropertyAll(BorderSide(color: p.border)),
          shape: const WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: Radii.mdAll)),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: p.text, borderRadius: Radii.smAll),
        textStyle: TextStyle(color: p.background, fontFamily: fontFamily, fontSize: 13, fontWeight: FontWeight.w500),
      ),
      snackBarTheme: SnackBarThemeData(
        // Inverse surface (dark chip on light, light chip on dark): calm and readable.
        backgroundColor: p.text,
        contentTextStyle: TextStyle(color: p.background, fontFamily: fontFamily, fontSize: 15, fontWeight: FontWeight.w500, height: 1.4),
        actionTextColor: p.isLight ? AppPalette.dark.primary : AppPalette.light.primary,
        behavior: SnackBarBehavior.floating,
        elevation: 1,
        shape: const RoundedRectangleBorder(borderRadius: Radii.mdAll),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: field(p.border),
        enabledBorder: field(p.border),
        disabledBorder: field(p.border),
        focusedBorder: field(p.primary, 1.5),
        errorBorder: field(p.danger),
        focusedErrorBorder: field(p.danger, 1.5),
        hintStyle: TextStyle(color: p.textFaint, fontWeight: FontWeight.w400),
        labelStyle: TextStyle(color: p.textMuted, fontWeight: FontWeight.w400),
        floatingLabelStyle: TextStyle(color: p.primary, fontWeight: FontWeight.w500),
        helperStyle: TextStyle(color: p.textMuted, fontSize: 12),
        errorStyle: TextStyle(color: p.danger, fontSize: 12),
        prefixIconColor: p.textMuted,
        suffixIconColor: p.textMuted,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: p.primary,
        selectionColor: p.primary.withValues(alpha: 0.25),
        selectionHandleColor: p.primary,
      ),
    );
  }
}
