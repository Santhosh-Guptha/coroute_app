import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Spacing scale. Use these instead of raw numbers for padding and gaps.
class Space {
  Space._();

  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s24 = 24;
  static const double s32 = 32;
}

/// Corner radius scale. Pills (StadiumBorder) are for chips only.
class Radii {
  Radii._();

  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;

  /// Top corners of bottom sheets.
  static const double sheet = 20;

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius sheetTop = BorderRadius.vertical(top: Radius.circular(sheet));
}

/// Animation durations and the one curve. No bounce, no looping animation.
class Motion {
  Motion._();

  static const Duration button = Duration(milliseconds: 120);
  static const Duration tab = Duration(milliseconds: 180);
  static const Duration sheet = Duration(milliseconds: 230);
  static const Duration screen = Duration(milliseconds: 260);
  static const Curve curve = Curves.easeOutCubic;
}

/// The five text levels. Getters, so they follow the light/dark switch.
/// Change colour or weight with `copyWith`, never the size scale.
class AppText {
  AppText._();

  /// Big ride numbers ("186 km"), tabular figures so digits do not jump.
  static TextStyle get metric => TextStyle(
        color: AppTheme.textPrimary,
        fontSize: 32,
        fontWeight: FontWeight.w700,
        height: 1.1,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// Screen, card and sheet titles.
  static TextStyle get title => TextStyle(
        color: AppTheme.textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        height: 1.25,
      );

  /// Normal reading text.
  static TextStyle get body => TextStyle(
        color: AppTheme.textPrimary,
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 1.35,
      );

  /// Short labels under metrics, chip text, list secondary lines.
  static TextStyle get label => TextStyle(
        color: AppTheme.textSecondary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        height: 1.25,
        letterSpacing: 0.2,
      );

  /// Smallest text in the app (12 sp): timestamps, hints.
  static TextStyle get caption => TextStyle(
        color: AppTheme.textMuted,
        fontSize: 12,
        fontWeight: FontWeight.w400,
        height: 1.3,
      );
}

/// Status colours. Always pair them with an icon or text, never colour alone.
class StatusColors {
  StatusColors._();

  static Color get success => AppTheme.emeraldSafe;
  static Color get warning => AppTheme.hyperAmber;
  static Color get critical => AppTheme.laserRed;
  static Color get info => AppTheme.infoBlue;
  static Color get offline => AppTheme.offlineGrey;

  /// Text and icons drawn on a solid [critical] background.
  static Color get onCritical => Colors.white;
}
