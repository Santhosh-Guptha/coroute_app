import 'package:flutter/material.dart';

/// Every colour the app uses, for one theme.
///
/// Tokens follow the CoRoute design canvas (Manrope + teal): a calm
/// `bg / card / soft` ground, one teal accent, one amber warning and the
/// SOS red. The old names (`obsidianVoid`, `neonCyan`, …) are kept as the
/// public API so every existing screen keeps compiling; they map onto the
/// new tokens below.
@immutable
class AppPalette {
  final Brightness brightness;

  // ── Design tokens (canvas names) ─────────────────────────────────────
  /// Screen background.
  final Color bg;

  /// Cards, sheets, floating pills.
  final Color card;

  /// Soft fill inside a card (dock tiles, inset rows).
  final Color soft;

  /// Map canvas and progress-track background.
  final Color map;

  /// Road strokes on the stylised map.
  final Color road;

  /// Hairline borders.
  final Color border;

  /// Stronger borders, dividers, switch-off track.
  final Color border2;

  /// Pale teal tint behind accent chips and selected rows.
  final Color tint;

  /// The brand teal used as a solid fill (hero card, primary buttons).
  final Color brand;

  /// Teal for text and icons on `card` / `bg` (deeper in light, lighter in dark).
  final Color accentText;

  /// Amber warning text and strokes.
  final Color warnText;

  /// Pale amber fill behind warnings.
  final Color warnTint;

  /// Amber border around warning cards.
  final Color warnBorder;

  /// Emergency red (SOS screen and button).
  final Color sos;

  /// Primary, secondary and muted text.
  final Color text;
  final Color text2;
  final Color muted;

  // ── Legacy names, kept so existing screens compile ───────────────────
  Color get obsidianVoid => bg;
  Color get darkCanvas => soft;
  Color get slateCard => card;
  Color get elevatedCard => soft;
  Color get glassBorder => border;
  Color get subtleBorder => border;
  Color get neonCyan => accentText;
  Color get electricBlue => accentText;
  Color get hyperAmber => warnText;
  Color get laserRed => sos;
  Color get emeraldSafe => accentText;
  Color get speedWarning => warnText;
  Color get devmonksPurple => brand;
  Color get infoBlue => accentText;
  Color get textPrimary => text;
  Color get textSecondary => text2;
  Color get textMuted => muted;
  Color get heroTop => brand;

  /// Status grey for a rider who is offline (no update for a while).
  final Color offlineGrey;

  /// Shadow under floating cards.
  final Color shadow;

  /// One colour per convoy member, distinct and readable on this background.
  final List<Color> members;

  const AppPalette({
    required this.brightness,
    required this.bg,
    required this.card,
    required this.soft,
    required this.map,
    required this.road,
    required this.border,
    required this.border2,
    required this.tint,
    required this.brand,
    required this.accentText,
    required this.warnText,
    required this.warnTint,
    required this.warnBorder,
    required this.sos,
    required this.text,
    required this.text2,
    required this.muted,
    required this.offlineGrey,
    required this.shadow,
    required this.members,
  });

  bool get isLight => brightness == Brightness.light;

  /// Canvas "dark" theme.
  static const AppPalette dark = AppPalette(
    brightness: Brightness.dark,
    bg: Color(0xFF0F171D),
    card: Color(0xFF1A262F),
    soft: Color(0xFF24323B),
    map: Color(0xFF141E25),
    road: Color(0xFF233038),
    border: Color(0xFF2A3842),
    border2: Color(0xFF3A4A55),
    tint: Color(0xFF163A3F),
    brand: Color(0xFF0B6E78),
    accentText: Color(0xFF5CCAD3),
    warnText: Color(0xFFF0A070),
    warnTint: Color(0xFF3A2616),
    warnBorder: Color(0xFF5A3A22),
    sos: Color(0xFFC8102E),
    text: Color(0xFFF2F6F8),
    text2: Color(0xFFC9D4DB),
    muted: Color(0xFF9BAAB5),
    offlineGrey: Color(0xFF8B98AB),
    shadow: Color(0x80000000),
    members: [
      Color(0xFF5CCAD3), // teal
      Color(0xFF7CFF6B), // green
      Color(0xFFFFD54F), // yellow
      Color(0xFFFF80AB), // pink
      Color(0xFF82B1FF), // blue
      Color(0xFFB388FF), // violet
      Color(0xFF64FFDA), // mint
      Color(0xFFF0A070), // amber
      Color(0xFFE6EE9C), // lime
      Color(0xFF80DEEA), // aqua
    ],
  );

  /// Canvas "light" theme.
  static const AppPalette light = AppPalette(
    brightness: Brightness.light,
    bg: Color(0xFFF4F7F9),
    card: Color(0xFFFFFFFF),
    soft: Color(0xFFEEF3F5),
    map: Color(0xFFE8EFF2),
    road: Color(0xFFFFFFFF),
    border: Color(0xFFE1E9EE),
    border2: Color(0xFFC2CED6),
    tint: Color(0xFFE3F3F5),
    brand: Color(0xFF0B6E78),
    accentText: Color(0xFF0B6E78),
    warnText: Color(0xFFB4541C),
    warnTint: Color(0xFFFFF1E6),
    warnBorder: Color(0xFFF0C9B3),
    sos: Color(0xFFC8102E),
    text: Color(0xFF15232E),
    text2: Color(0xFF3E4F5C),
    muted: Color(0xFF5B6B78),
    offlineGrey: Color(0xFF5F6B7A),
    shadow: Color(0x2415232E),
    members: [
      Color(0xFF0B6E78), // teal
      Color(0xFF2E7D32), // green
      Color(0xFF9A6A00), // yellow
      Color(0xFFC2185B), // pink
      Color(0xFF1565C0), // blue
      Color(0xFF6A1B9A), // violet
      Color(0xFF00695C), // mint
      Color(0xFFB4541C), // amber
      Color(0xFF5F7A00), // lime
      Color(0xFF0277BD), // aqua
    ],
  );
}
