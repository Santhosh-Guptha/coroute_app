/// Motion numbers for the whole app (pure Dart: no Flutter import, so the
/// rules can be tested without a device). The Flutter side is in
/// app_motion.dart. docs/features_355/motion_and_loading.md
library;

/// The three durations every animation in the app uses, in milliseconds.
abstract final class MotionMs {
  /// Pressed states, small fades, switch thumbs.
  static const int fast = 120;

  /// Content swaps (skeleton to content, tab fade-through, counters).
  static const int medium = 200;

  /// Sheets, dialogs and the fallback page transition.
  static const int slow = 300;

  /// iOS-style horizontal page push (the Cupertino transition runs on its own
  /// curve; 350 ms reads like iOS on 60 and 120 Hz panels).
  static const int page = 350;

  /// One sweep of the skeleton shimmer.
  static const int shimmer = 1300;

  /// Search fields wait this long after the last key press.
  static const int searchDebounce = 280;

  /// A loader is not shown for work that finishes sooner than this
  /// (a flash of skeleton is worse than a short wait).
  static const int loaderDelay = 90;

  /// Once shown, a loader stays at least this long (no flicker).
  static const int loaderMinVisible = 260;
}

/// Why motion is reduced.
enum MotionLevel {
  /// All animations.
  full,

  /// Battery saver: no looping shimmer, no parallax, short fades only.
  reduced,

  /// The system "remove animations" setting: changes apply at once.
  none,
}

/// Spring constants (mass, stiffness, damping) for sheets and drag release.
/// Critically damped or slightly under: settles without a visible bounce.
class SpringSpec {
  final double mass;
  final double stiffness;
  final double damping;
  const SpringSpec({required this.mass, required this.stiffness, required this.damping});

  /// 1.0 = critically damped, below 1 = a little overshoot.
  double get dampingRatio => damping / (2 * _sqrt(mass * stiffness));

  /// Sheets and dialogs (close to the iOS sheet spring).
  static const SpringSpec sheet = SpringSpec(mass: 1, stiffness: 380, damping: 38);

  /// A dragged card or pane let go.
  static const SpringSpec dragRelease = SpringSpec(mass: 1, stiffness: 520, damping: 40);

  /// A pressed control springing back.
  static const SpringSpec press = SpringSpec(mass: 1, stiffness: 900, damping: 52);

  static double _sqrt(double v) {
    if (v <= 0) return 0;
    var x = v;
    for (var i = 0; i < 24; i++) {
      x = 0.5 * (x + v / x);
    }
    return x;
  }
}

/// Decisions that do not need a widget.
abstract final class MotionSpec {
  /// The level from the two inputs. The system setting always wins.
  static MotionLevel level({required bool disableAnimations, required bool batterySaver}) {
    if (disableAnimations) return MotionLevel.none;
    if (batterySaver) return MotionLevel.reduced;
    return MotionLevel.full;
  }

  /// A duration in ms after the level is applied: full = as given, reduced =
  /// capped at [MotionMs.fast], none = 0.
  static int scaledMs(int ms, MotionLevel level) {
    if (ms <= 0) return 0;
    switch (level) {
      case MotionLevel.full:
        return ms;
      case MotionLevel.reduced:
        return ms < MotionMs.fast ? ms : MotionMs.fast;
      case MotionLevel.none:
        return 0;
    }
  }

  /// Looping animations (shimmer) run only at full motion.
  static bool loops(MotionLevel level) => level == MotionLevel.full;

  /// Parallax, scale-on-press and hero flights run only at full motion.
  static bool decorative(MotionLevel level) => level == MotionLevel.full;

  /// Pressed scale for a control of [shortestSide] dp: big cards shrink less
  /// than small buttons so the movement looks the same on screen.
  static double pressedScale(double shortestSide) {
    if (shortestSide <= 56) return 0.96;
    if (shortestSide >= 240) return 0.985;
    final t = (shortestSide - 56) / (240 - 56);
    return 0.96 + (0.985 - 0.96) * t;
  }

  /// The number shown by an animated counter at progress [t] (0..1).
  static double counterValue(double from, double to, double t) {
    if (t <= 0) return from;
    if (t >= 1) return to;
    return from + (to - from) * t;
  }

  /// How many skeleton rows fill [viewportHeight] (at least 3, at most 12).
  static int skeletonRows(double viewportHeight, double rowExtent) {
    if (rowExtent <= 0 || viewportHeight <= 0) return 3;
    final n = (viewportHeight / rowExtent).ceil();
    return n < 3 ? 3 : (n > 12 ? 12 : n);
  }

  /// Whether a loader may be shown yet: only after [MotionMs.loaderDelay].
  static bool showLoader(int elapsedMs) => elapsedMs >= MotionMs.loaderDelay;

  /// How long a visible loader must still stay so it does not flicker.
  static int loaderHoldMs(int visibleForMs) {
    final left = MotionMs.loaderMinVisible - visibleForMs;
    return left > 0 ? left : 0;
  }
}
