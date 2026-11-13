import 'package:flutter/cupertino.dart' show CupertinoFullscreenDialogTransition, CupertinoPageTransition, CupertinoRouteTransitionMixin;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'motion_spec.dart';

export 'motion_spec.dart';

/// The app's motion system: durations, curves, springs, reduced motion, page
/// transitions, dialogs, scroll physics and haptics. One place; every screen
/// uses it. docs/features_355/motion_and_loading.md
///
/// SAFETY RULE: routes whose name starts with `safety/` (crash alarm, SOS
/// hold, emergency SOS) are drawn at full size and full opacity on their first
/// frame. They never slide, fade or wait for anything here.
abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: MotionMs.fast);
  static const Duration medium = Duration(milliseconds: MotionMs.medium);
  static const Duration slow = Duration(milliseconds: MotionMs.slow);
  static const Duration page = Duration(milliseconds: MotionMs.page);
  static const Duration sheetIn = Duration(milliseconds: 230);
  static const Duration shimmer = Duration(milliseconds: MotionMs.shimmer);

  /// Things entering or settling (the default).
  static const Curve standard = Curves.easeOutCubic;

  /// Things leaving.
  static const Curve exit = Curves.easeInCubic;

  /// Things moving from A to B on screen.
  static const Curve move = Curves.easeInOutCubic;

  /// Sheets and dialogs: a spring that settles without overshoot.
  static const Curve spring = SpringCurve(SpringSpec.sheet);

  /// The rider's battery saver setting (and the SOS battery reserve). Set by
  /// main.dart; while true, looping and decorative motion is off.
  static final ValueNotifier<bool> batterySaver = ValueNotifier<bool>(false);

  /// Test hook / kill switch: forces a level whatever the device says.
  @visibleForTesting
  static MotionLevel? debugLevelOverride;

  static MotionLevel levelOf(BuildContext context) {
    final forced = debugLevelOverride;
    if (forced != null) return forced;
    return MotionSpec.level(
      disableAnimations: MediaQuery.maybeDisableAnimationsOf(context) ?? false,
      batterySaver: batterySaver.value,
    );
  }

  /// True when animations must be skipped or cut short.
  static bool reducedOf(BuildContext context) => levelOf(context) != MotionLevel.full;

  /// [d] after the reduce-motion rules (zero when animations are removed).
  static Duration durationOf(BuildContext context, Duration d) =>
      Duration(milliseconds: MotionSpec.scaledMs(d.inMilliseconds, levelOf(context)));

  /// Style for showModalBottomSheet (spring in, ease out).
  static AnimationStyle sheetStyleOf(BuildContext context) {
    final level = levelOf(context);
    if (level == MotionLevel.none) return AnimationStyle.noAnimation;
    if (level == MotionLevel.reduced) {
      return const AnimationStyle(duration: fast, reverseDuration: fast, curve: standard, reverseCurve: exit);
    }
    // 230 ms, the sheet time the app already had (never slower than before): the spring curve covers
    // most of the distance in the first 100 ms, so a sheet is readable sooner than with the old ease.
    return const AnimationStyle(duration: sheetIn, reverseDuration: medium, curve: spring, reverseCurve: exit);
  }

  static SpringDescription springOf(SpringSpec s) =>
      SpringDescription(mass: s.mass, stiffness: s.stiffness, damping: s.damping);

  /// A spring from [from] to [to] with the finger's [velocity] (units/s), for
  /// `controller.animateWith(...)` after a drag is released.
  static SpringSimulation release({required double from, required double to, double velocity = 0, SpringSpec spec = SpringSpec.dragRelease}) =>
      SpringSimulation(springOf(spec), from, to, velocity);

  /// Route names that must appear at once (see the safety rule above).
  static bool isInstantRoute(String? name) => name != null && name.startsWith(instantRoutePrefix);
  static const String instantRoutePrefix = 'safety/';

  /// Route names that slide like the others but have no edge-swipe back
  /// (full-screen maps where the left edge is used for panning).
  static bool isNoSwipeRoute(String? name) => name != null && name.startsWith(noSwipeRoutePrefix);
  static const String noSwipeRoutePrefix = 'map/';
}

/// A spring as a [Curve] (0 to 1 over the animation's duration). Never above
/// 1, so a sheet cannot lift off the bottom edge.
class SpringCurve extends Curve {
  final SpringSpec spec;

  /// Seconds of spring time mapped onto the curve.
  final double seconds;
  const SpringCurve(this.spec, {this.seconds = 0.55});

  @override
  double transformInternal(double t) {
    final sim = SpringSimulation(AppMotion.springOf(spec), 0, 1, 0);
    final end = sim.x(seconds);
    final v = sim.x(t * seconds) / (end == 0 ? 1 : end);
    return v.clamp(0.0, 1.0).toDouble();
  }
}

/// Page transitions for every MaterialPageRoute: iOS-style horizontal slide
/// with parallax of the page below and an interactive edge-swipe back;
/// full-screen dialogs rise from the bottom. Only transforms and opacity are
/// animated. Safety routes are not animated at all.
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  static NavigatorState? _findNavigator() {
    NavigatorState? found;
    void search(Element e) {
      if (found != null) return;
      if (e is StatefulElement && e.state is NavigatorState) {
        found = e.state as NavigatorState;
        return;
      }
      e.visitChildren(search);
    }
    final root = WidgetsBinding.instance.rootElement;
    if (root != null) search(root);
    return found;
  }

  @override
  Duration get transitionDuration {
    final nav = _findNavigator();
    if (nav != null) {
      Route? topRoute;
      try {
        nav.popUntil((r) {
          topRoute = r;
          return true;
        });
      } catch (_) {}
      final name = topRoute?.settings.name;
      if (AppMotion.isInstantRoute(name)) return Duration.zero;
      if (AppMotion.levelOf(nav.context) == MotionLevel.none) return Duration.zero;
    }
    return AppMotion.page;
  }

  @override
  Duration get reverseTransitionDuration => transitionDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final name = route.settings.name;
    if (AppMotion.isInstantRoute(name)) return child;
    switch (AppMotion.levelOf(context)) {
      case MotionLevel.none:
        return child;
      case MotionLevel.reduced:
        return FadeTransition(opacity: CurvedAnimation(parent: animation, curve: const Interval(0, 0.4, curve: Curves.easeOut)), child: child);
      case MotionLevel.full:
        break;
    }
    final linear = route.popGestureInProgress;
    if (route.fullscreenDialog) {
      return CupertinoFullscreenDialogTransition(
        primaryRouteAnimation: animation,
        secondaryRouteAnimation: secondaryAnimation,
        linearTransition: linear,
        child: child,
      );
    }
    if (AppMotion.isNoSwipeRoute(name)) {
      return CupertinoPageTransition(
        primaryRouteAnimation: animation,
        secondaryRouteAnimation: secondaryAnimation,
        linearTransition: linear,
        child: child,
      );
    }
    // Slide + parallax + edge-swipe back (disabled by the framework on the first route,
    // on PopScope(canPop: false) screens and on full-screen dialogs).
    return CupertinoRouteTransitionMixin.buildPageTransitions<T>(route, context, animation, secondaryAnimation, child);
  }
}

/// The transitions theme used by AppTheme (all platforms the same).
const PageTransitionsTheme appPageTransitionsTheme = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: AppPageTransitionsBuilder(),
    TargetPlatform.iOS: AppPageTransitionsBuilder(),
    TargetPlatform.fuchsia: AppPageTransitionsBuilder(),
    TargetPlatform.linux: AppPageTransitionsBuilder(),
    TargetPlatform.macOS: AppPageTransitionsBuilder(),
    TargetPlatform.windows: AppPageTransitionsBuilder(),
  },
);

/// A page route for code that cannot use MaterialPageRoute. Same motion.
/// `appRoute((_) => const ProfileScreen())`.
MaterialPageRoute<T> appRoute<T>(WidgetBuilder builder, {String? name, bool fullscreenDialog = false}) =>
    MaterialPageRoute<T>(builder: builder, fullscreenDialog: fullscreenDialog, settings: name == null ? null : RouteSettings(name: name));

/// A page that replaces the current one without a direction (splash -> home,
/// sign-in -> home, sign-out -> welcome): a short cross-fade, opacity only.
/// Reduce motion: at once. Edge-swipe back does not apply (nothing to go back to).
PageRoute<T> appFadeRoute<T>(WidgetBuilder builder, {String? name}) => PageRouteBuilder<T>(
      settings: name == null ? null : RouteSettings(name: name),
      transitionDuration: AppMotion.medium,
      reverseTransitionDuration: AppMotion.medium,
      pageBuilder: (context, _, _) => builder(context),
      transitionsBuilder: (context, animation, _, child) {
        if (AppMotion.levelOf(context) == MotionLevel.none) return child;
        return FadeTransition(opacity: CurvedAnimation(parent: animation, curve: AppMotion.standard), child: child);
      },
    );

/// Same scroll feel on every list: iOS-style bounce, no glow, no stretch.
/// Lists shorter than the screen still bounce (so pull-to-refresh works).
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  static const ScrollPhysics physics = BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) => const BouncingScrollPhysics();

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) => child;
}

/// Tab bodies: every visited tab stays alive (scroll position, loaded data),
/// tabs are built on first visit, and a switch is a short fade-through
/// (opacity + a 2 % scale; nothing is laid out again).
class FadeThroughIndexedStack extends StatefulWidget {
  final int index;
  final List<WidgetBuilder> builders;
  const FadeThroughIndexedStack({super.key, required this.index, required this.builders});

  @override
  State<FadeThroughIndexedStack> createState() => _FadeThroughIndexedStackState();
}

class _FadeThroughIndexedStackState extends State<FadeThroughIndexedStack> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: AppMotion.medium, value: 1);
  late final Set<int> _built = <int>{widget.index};

  @override
  void didUpdateWidget(FadeThroughIndexedStack old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      _built.add(widget.index);
      final d = AppMotion.durationOf(context, AppMotion.medium);
      if (d == Duration.zero) {
        _c.value = 1;
      } else {
        _c.duration = d;
        _c.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fade = CurvedAnimation(parent: _c, curve: AppMotion.standard);
    return FadeTransition(
      opacity: fade,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.98, end: 1).animate(fade),
        child: IndexedStack(
          index: widget.index,
          children: [
            for (var i = 0; i < widget.builders.length; i++)
              _built.contains(i) ? KeyedSubtree(key: ValueKey<int>(i), child: Builder(builder: widget.builders[i])) : const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }
}

/// Content swap in place (A fades out, B fades in with a small rise).
class FadeThroughSwitcher extends StatelessWidget {
  final Widget child;
  final Alignment alignment;
  const FadeThroughSwitcher({super.key, required this.child, this.alignment = Alignment.topCenter});

  @override
  Widget build(BuildContext context) {
    final d = AppMotion.durationOf(context, AppMotion.medium);
    if (d == Duration.zero) return child;
    return AnimatedSwitcher(
      duration: d,
      switchInCurve: AppMotion.standard,
      switchOutCurve: AppMotion.exit,
      layoutBuilder: (current, previous) => Stack(alignment: alignment, children: [...previous, ?current]),
      transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
      child: child,
    );
  }
}

/// A dialog with the app's motion: fades in while scaling from 94 % on the
/// sheet spring. Use instead of showDialog. Reduce motion: appears at once.
Future<T?> showAppDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color barrierColor = const Color(0x7315181C),
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
}) {
  final level = AppMotion.levelOf(context);
  final themes = InheritedTheme.capture(from: context, to: Navigator.of(context, rootNavigator: useRootNavigator).context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: barrierColor,
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    transitionDuration: Duration(milliseconds: MotionSpec.scaledMs(MotionMs.slow, level)),
    pageBuilder: (ctx, _, _) => themes.wrap(SafeArea(child: Builder(builder: builder))),
    transitionBuilder: (ctx, animation, _, child) {
      if (level != MotionLevel.full) return FadeTransition(opacity: animation, child: child);
      final a = CurvedAnimation(parent: animation, curve: AppMotion.spring, reverseCurve: AppMotion.exit);
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: const Interval(0, 0.5, curve: Curves.easeOut)),
        child: ScaleTransition(scale: Tween<double>(begin: 0.94, end: 1).animate(a), child: child),
      );
    },
  );
}

/// The three haptics the app uses. Never throws; does nothing in tests
/// without a platform.
abstract final class AppHaptics {
  /// Off switch (battery reserve, tests).
  static bool enabled = true;

  /// Count of calls, for tests.
  @visibleForTesting
  static int debugCount = 0;

  static void _run(Future<void> Function() f) {
    debugCount++;
    if (!enabled) return;
    try {
      f().catchError((Object _) {});
    } catch (_) {}
  }

  /// A normal tap on a primary control.
  static void light() => _run(HapticFeedback.lightImpact);

  /// A value changed: switch, segment, tab, picker.
  static void selection() => _run(HapticFeedback.selectionClick);

  /// A committed action: joined, saved, sent, refreshed.
  static void medium() => _run(HapticFeedback.mediumImpact);
}
