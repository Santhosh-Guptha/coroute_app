import 'package:flutter/material.dart';

/// Every colour the app uses, for one theme.
///
/// Design system v3.55 (docs/DESIGN_SYSTEM_v3.55.md): calm, warm and flat.
/// A warm off-white (light) or soft charcoal (dark, never pure black)
/// ground, one muted teal for actions, one warm amber accent, and a strong
/// SOS red that is kept high-contrast on purpose.
///
/// The token fields ([background], [surface], [primary], ...) are the source
/// of truth. The older names (`bg`, `card`, `brand`, `neonCyan`, ...) are kept
/// as getters so every existing screen keeps compiling and follows the new
/// look at once.
@immutable
class AppPalette {
  final Brightness brightness;

  // ── v3.55 tokens ─────────────────────────────────────────────────────
  /// Screen background.
  final Color background;

  /// Cards, sheets, dialogs, floating pills.
  final Color surface;

  /// Soft fill inside a card (inset rows, chips, tiles).
  final Color surfaceAlt;

  /// Hairline borders and dividers.
  final Color border;

  /// Stronger border: switch-off track, dashed outlines, unselected radio.
  final Color borderStrong;

  /// Body text, secondary text, faint text (hints, timestamps only).
  final Color text;
  final Color textMuted;
  final Color textFaint;

  /// Muted teal for actions, links, selected states and focus.
  final Color primary;

  /// Text and icons on a [primary] fill.
  final Color onPrimary;

  /// Pale teal behind selected rows and info chips.
  final Color primarySoft;

  /// A deeper teal that always carries white text (legacy screens put
  /// `Colors.white` on `brand`). Light: same as [primary].
  final Color primaryFill;

  /// Warm amber accent (icons, fills, highlights).
  final Color accent;

  /// Pale amber fill.
  final Color accentSoft;

  /// Amber that is readable as text on [surface] / [background]
  /// (warning text). Use [accent] for icons and fills.
  final Color accentStrong;

  /// Amber border around warning cards.
  final Color accentBorder;

  final Color success;
  final Color warning;
  final Color danger;
  final Color info;

  /// Emergency red (SOS button, crash alarm). Stays strong on purpose.
  final Color sos;

  /// Map canvas and progress-track background.
  final Color map;

  /// Road strokes on the stylised map.
  final Color road;

  /// Status grey for a rider who is offline.
  final Color offlineGrey;

  /// Very soft shadow under floating cards.
  final Color shadow;

  /// One colour per convoy member: distinct, muted, readable on this background.
  final List<Color> members;

  // ── Older names, kept so existing screens compile ────────────────────
  Color get bg => background;
  Color get card => surface;
  Color get soft => surfaceAlt;
  Color get border2 => borderStrong;
  Color get tint => primarySoft;

  /// Solid teal fill that carries white text (see [primaryFill]).
  Color get brand => primaryFill;

  /// Teal text and icons on `card` / `bg` (legacy name, = [primary]).
  Color get accentText => primary;
  Color get warnText => accentStrong;
  Color get warnTint => accentSoft;
  Color get warnBorder => accentBorder;
  Color get text2 => textMuted;
  Color get muted => textMuted;

  Color get obsidianVoid => background;
  Color get darkCanvas => surfaceAlt;
  Color get slateCard => surface;
  Color get elevatedCard => surfaceAlt;
  Color get glassBorder => border;
  Color get subtleBorder => border;
  Color get neonCyan => primary;
  Color get electricBlue => primary;
  Color get hyperAmber => accentStrong;
  Color get laserRed => danger;
  Color get emeraldSafe => success;
  Color get speedWarning => accentStrong;
  Color get devmonksPurple => primary;
  Color get infoBlue => info;
  Color get textPrimary => text;
  Color get textSecondary => textMuted;
  Color get heroTop => primaryFill;

  const AppPalette({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceAlt,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.textMuted,
    required this.textFaint,
    required this.primary,
    required this.onPrimary,
    required this.primarySoft,
    required this.primaryFill,
    required this.accent,
    required this.accentSoft,
    required this.accentStrong,
    required this.accentBorder,
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.sos,
    required this.map,
    required this.road,
    required this.offlineGrey,
    required this.shadow,
    required this.members,
  });

  bool get isLight => brightness == Brightness.light;

  /// Light: warm off-white, white cards, muted teal.
  static const AppPalette light = AppPalette(
    brightness: Brightness.light,
    background: Color(0xFFF6F4F0),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFEFECE6),
    border: Color(0xFFE3DED6),
    borderStrong: Color(0xFFCFC8BD),
    text: Color(0xFF1F2328),
    textMuted: Color(0xFF5B616B),
    textFaint: Color(0xFF8A8F96),
    primary: Color(0xFF2B7A8C),
    onPrimary: Color(0xFFFFFFFF),
    primarySoft: Color(0xFFD7ECEF),
    primaryFill: Color(0xFF2B7A8C),
    accent: Color(0xFFD9822B),
    accentSoft: Color(0xFFF7E6D3),
    accentStrong: Color(0xFF94600F),
    accentBorder: Color(0xFFEBCBA6),
    success: Color(0xFF3E8E5E),
    warning: Color(0xFFB9821C),
    danger: Color(0xFFC8463D),
    info: Color(0xFF3D7BC8),
    sos: Color(0xFFD93A2F),
    map: Color(0xFFECE8E1),
    road: Color(0xFFFFFFFF),
    offlineGrey: Color(0xFF7A7F86),
    shadow: Color(0x1F1F2328),
    members: [
      Color(0xFF2B7A8C), // teal
      Color(0xFF3E8E5E), // green
      Color(0xFFB9821C), // ochre
      Color(0xFFB5546E), // rose
      Color(0xFF3D7BC8), // blue
      Color(0xFF7A62B0), // violet
      Color(0xFF2E8F86), // sea green
      Color(0xFFD9822B), // amber
      Color(0xFF7D8A2E), // olive
      Color(0xFF4F6FA8), // slate blue
    ],
  );

  /// Dark: soft charcoal (not black), warm off-white text, lighter teal.
  static const AppPalette dark = AppPalette(
    brightness: Brightness.dark,
    background: Color(0xFF15181C),
    surface: Color(0xFF1C2026),
    surfaceAlt: Color(0xFF242932),
    border: Color(0xFF2F3540),
    borderStrong: Color(0xFF3E4652),
    text: Color(0xFFE7E3DC),
    textMuted: Color(0xFFA7A39B),
    textFaint: Color(0xFF7C7A75),
    primary: Color(0xFF5FB3C4),
    onPrimary: Color(0xFF0E1A1D),
    primarySoft: Color(0xFF1F3A40),
    primaryFill: Color(0xFF29707E),
    accent: Color(0xFFE9A55B),
    accentSoft: Color(0xFF3A2C1D),
    accentStrong: Color(0xFFE9A55B),
    accentBorder: Color(0xFF5A4228),
    success: Color(0xFF6CC08B),
    warning: Color(0xFFE0B15A),
    danger: Color(0xFFE5675C),
    info: Color(0xFF79A8E8),
    sos: Color(0xFFFF5A4E),
    map: Color(0xFF1A1E23),
    road: Color(0xFF2A3038),
    offlineGrey: Color(0xFF8A8780),
    shadow: Color(0x59000000),
    members: [
      Color(0xFF5FB3C4), // teal
      Color(0xFF6CC08B), // green
      Color(0xFFE0B15A), // ochre
      Color(0xFFE58BA3), // rose
      Color(0xFF79A8E8), // blue
      Color(0xFFA993DE), // violet
      Color(0xFF63C2B6), // sea green
      Color(0xFFE9A55B), // amber
      Color(0xFFB5C267), // olive
      Color(0xFF8FA8D8), // slate blue
    ],
  );
}
