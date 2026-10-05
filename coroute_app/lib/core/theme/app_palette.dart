import 'package:flutter/material.dart';

/// Every colour the app uses, for one theme. The dark palette is the
/// original CoRoute look; the light one keeps the same cyan/amber identity
/// with deeper shades so text and icons stay readable on white.
@immutable
class AppPalette {
  final Brightness brightness;

  // Backgrounds
  final Color obsidianVoid;
  final Color darkCanvas;
  final Color slateCard;
  final Color elevatedCard;
  final Color glassBorder;
  final Color subtleBorder;

  // Accents & signals
  final Color neonCyan;
  final Color electricBlue;
  final Color hyperAmber;
  final Color laserRed;
  final Color emeraldSafe;
  final Color speedWarning;
  final Color devmonksPurple;

  // Text
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  /// Shadow under floating cards.
  final Color shadow;

  /// Top colour of the home screen hero gradient (bottom is [slateCard]).
  final Color heroTop;

  /// One colour per convoy member, distinct and readable on this background.
  final List<Color> members;

  const AppPalette({
    required this.brightness,
    required this.obsidianVoid,
    required this.darkCanvas,
    required this.slateCard,
    required this.elevatedCard,
    required this.glassBorder,
    required this.subtleBorder,
    required this.neonCyan,
    required this.electricBlue,
    required this.hyperAmber,
    required this.laserRed,
    required this.emeraldSafe,
    required this.speedWarning,
    required this.devmonksPurple,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.shadow,
    required this.heroTop,
    required this.members,
  });

  bool get isLight => brightness == Brightness.light;

  static const AppPalette dark = AppPalette(
    brightness: Brightness.dark,
    obsidianVoid: Color(0xFF090D14),
    darkCanvas: Color(0xFF0F1520),
    slateCard: Color(0xFF161F2E),
    elevatedCard: Color(0xFF1C2738),
    glassBorder: Color(0x334FD1C5),
    subtleBorder: Color(0x1FFFFFFF),
    neonCyan: Color(0xFF00E5FF),
    electricBlue: Color(0xFF2979FF),
    hyperAmber: Color(0xFFFF9100),
    laserRed: Color(0xFFFF1744),
    emeraldSafe: Color(0xFF00E676),
    speedWarning: Color(0xFFFF5252),
    devmonksPurple: Color(0xFF7C4DFF),
    textPrimary: Color(0xFFF8FAFC),
    textSecondary: Color(0xFF94A3B8),
    textMuted: Color(0xFF64748B),
    shadow: Color(0x80000000),
    heroTop: Color(0xFF0F2B48),
    members: [
      Color(0xFF00E5FF), // cyan
      Color(0xFF7CFF6B), // green
      Color(0xFFFFD54F), // yellow
      Color(0xFFFF80AB), // pink
      Color(0xFF82B1FF), // blue
      Color(0xFFB388FF), // violet
      Color(0xFF64FFDA), // teal
      Color(0xFFFFAB91), // peach
      Color(0xFFE6EE9C), // lime
      Color(0xFF80DEEA), // aqua
    ],
  );

  /// Accents are the same hues as [dark], deepened to about 4.5:1 against
  /// white (text on cards) and against black (black text on accent buttons).
  static const AppPalette light = AppPalette(
    brightness: Brightness.light,
    obsidianVoid: Color(0xFFF3F6F9),
    darkCanvas: Color(0xFFEDF1F5),
    slateCard: Color(0xFFFFFFFF),
    elevatedCard: Color(0xFFF1F5F9),
    glassBorder: Color(0x3300838F),
    subtleBorder: Color(0x1F0F172A),
    neonCyan: Color(0xFF00838F),
    electricBlue: Color(0xFF1565C0),
    hyperAmber: Color(0xFFBD5B00),
    laserRed: Color(0xFFC62828),
    emeraldSafe: Color(0xFF1E8540),
    speedWarning: Color(0xFFC62828),
    devmonksPurple: Color(0xFF5E35B1),
    textPrimary: Color(0xFF0F172A),
    textSecondary: Color(0xFF475569),
    textMuted: Color(0xFF5B6B80),
    shadow: Color(0x290F172A),
    heroTop: Color(0xFFDDEFF5),
    members: [
      Color(0xFF00838F), // cyan
      Color(0xFF2E7D32), // green
      Color(0xFF9A6A00), // yellow
      Color(0xFFC2185B), // pink
      Color(0xFF1565C0), // blue
      Color(0xFF6A1B9A), // violet
      Color(0xFF00695C), // teal
      Color(0xFFBF360C), // peach
      Color(0xFF5F7A00), // lime
      Color(0xFF0277BD), // aqua
    ],
  );
}
