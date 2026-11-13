/// How the cockpit lays out its controls for a screen (pure; round 7 responsive cockpit).
enum CockpitForm {
  /// 320-359 dp wide phones, or a large text scale on a normal phone: smaller chips, stacked.
  compact,

  /// Normal phones in portrait.
  regular,

  /// A phone on a handlebar mount in landscape (short height): chips in one row, side by side.
  landscape,

  /// Tablets and wide split-screen panes.
  wide,
}

class CockpitLayout {
  const CockpitLayout({required this.form, required this.signSize, required this.chipHeight, required this.gap, required this.stacked, required this.primaryControl, required this.textScale});

  final CockpitForm form;

  /// Diameter of the limit sign.
  final double signSize;
  final double chipHeight;
  final double gap;

  /// The bend chip sits under the limit sign (true) or beside it.
  final bool stacked;

  /// Least size of a primary (glove) control: always 56 dp.
  final double primaryControl;

  /// The text scale used inside the chips (the system scale, held between 1.0 and 1.3 so a
  /// large-text setting grows the numbers without pushing the chips over the speed dial).
  final double textScale;

  /// Glove-friendly primary controls (SOS, talk, mute): never smaller.
  static const double glove = 56;

  static CockpitLayout of({required double width, required double height, double textScale = 1.0}) {
    final ts = textScale.isFinite ? textScale.clamp(1.0, 1.3).toDouble() : 1.0;
    final bigText = textScale.isFinite && textScale >= 1.3;
    final CockpitForm form;
    if (height < 430 && width > height) {
      form = CockpitForm.landscape;
    } else if (width >= 700 && height >= 500) {
      form = CockpitForm.wide;
    } else if (width < 360 || bigText || height < 520) {
      form = CockpitForm.compact;
    } else {
      form = CockpitForm.regular;
    }
    return switch (form) {
      CockpitForm.compact => CockpitLayout(form: form, signSize: 44, chipHeight: 40, gap: 6, stacked: true, primaryControl: glove, textScale: ts),
      CockpitForm.regular => CockpitLayout(form: form, signSize: 52, chipHeight: 44, gap: 8, stacked: true, primaryControl: glove, textScale: ts),
      CockpitForm.landscape => CockpitLayout(form: form, signSize: 44, chipHeight: 40, gap: 8, stacked: false, primaryControl: glove, textScale: ts),
      CockpitForm.wide => CockpitLayout(form: form, signSize: 64, chipHeight: 52, gap: 10, stacked: false, primaryControl: 64, textScale: ts),
    };
  }

  /// Width the chips need (so the caller can check they fit beside the speed dial).
  double get chipsWidth => stacked ? signSize + 64 * textScale : signSize + gap + 112 * textScale;

  /// Height the chips need.
  double get chipsHeight => stacked ? signSize + 14 * textScale + gap + chipHeight : (signSize + 14 * textScale > chipHeight ? signSize + 14 * textScale : chipHeight);
}
