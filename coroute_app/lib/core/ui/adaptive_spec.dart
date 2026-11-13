/// Responsive layout rules (pure Dart). The widget side is in adaptive.dart.
/// docs/features_355/motion_and_loading.md
library;

/// Width classes. Measured on the window, not the device, so split-screen and
/// folded/unfolded states are handled.
enum WindowClass {
  /// Narrower than 360 dp (small phones, split-screen halves).
  compact,

  /// 360 to 599 dp (most phones).
  normal,

  /// 600 dp and wider (tablets, unfolded foldables, phones in landscape).
  large,
}

abstract final class AdaptiveSpec {
  static const double compactBelow = 360;
  static const double largeFrom = 600;

  /// Two panes need this much width (list 320 + detail 400 + divider).
  static const double twoPaneFrom = 720;

  /// Text never stretches wider than this on a single-pane screen.
  static const double maxContentWidth = 640;

  /// Smallest tap target.
  static const double minTap = 48;

  /// The app lays out for text up to this scale; larger settings are capped.
  static const double maxTextScale = 1.3;
  static const double minTextScale = 0.85;

  static WindowClass classFor(double width) {
    if (width < compactBelow) return WindowClass.compact;
    if (width >= largeFrom) return WindowClass.large;
    return WindowClass.normal;
  }

  /// Side padding of a page.
  static double gutter(double width) {
    switch (classFor(width)) {
      case WindowClass.compact:
        return 12;
      case WindowClass.normal:
        return 16;
      case WindowClass.large:
        return 24;
    }
  }

  static bool twoPane(double width) => width >= twoPaneFrom;

  /// Width of the list pane in a two-pane layout: 38 % of the window, kept
  /// between 300 and 400 dp.
  static double listPaneWidth(double width) {
    final w = width * 0.38;
    return w < 300 ? 300 : (w > 400 ? 400 : w);
  }

  /// Grid columns for tiles at least [minTile] dp wide, inside the gutters.
  static int columns(double width, {double minTile = 156, double gap = 12, int max = 6}) {
    final usable = width - 2 * gutter(width);
    if (usable <= minTile) return 1;
    final n = ((usable + gap) / (minTile + gap)).floor();
    return n < 1 ? 1 : (n > max ? max : n);
  }

  /// Short window (landscape phone, keyboard open): keep the primary action
  /// visible and let the rest scroll.
  static bool shortHeight(double height) => height < 480;

  static bool landscape(double width, double height) => width > height;

  static double clampTextScale(double scale) {
    if (scale.isNaN) return 1;
    if (scale < minTextScale) return minTextScale;
    if (scale > maxTextScale) return maxTextScale;
    return scale;
  }

  /// A size (icon box, avatar) that grows with the text scale but only half
  /// as fast, so rows stay inside the screen at 1.3x.
  static double softScale(double base, double textScale) => base * (1 + (clampTextScale(textScale) - 1) * 0.5);

  /// Whether a row with a leading item, a flexible text and a trailing item
  /// should stack the trailing item below (narrow window or big text).
  static bool stackTrailing(double width, double textScale) =>
      classFor(width) == WindowClass.compact || (width < 400 && clampTextScale(textScale) >= 1.2);

  /// Horizontal padding that centres content of [maxWidth] in [width].
  static double centeredInset(double width, {double maxWidth = maxContentWidth}) {
    final g = gutter(width);
    final extra = (width - maxWidth) / 2;
    return extra > g ? extra : g;
  }
}
