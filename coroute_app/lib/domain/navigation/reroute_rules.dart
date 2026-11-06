import 'dart:math' as math;

/// Rules for leaving the route, coming back to it, asking for a new route
/// and what is said about it. One place, so the ride and the tests agree.
///
/// Pure Dart: no Flutter, no timers. Everything is decided on the location
/// fixes the app already gets.
class RerouteRules {
  RerouteRules._();

  // ------------------------------------------------------------ off route

  /// Farther than this from the active route (metres) may be off the route...
  static const double offRouteM = 40;

  /// ...or farther than the GPS accuracy times this factor, if larger.
  static const double accuracyFactor = 2.5;

  /// ...for at least this long while moving (and heading away from the route).
  static const Duration offRouteHold = Duration(seconds: 8);

  /// Farther than this (or [accuracyFactor] x accuracy, if larger) on one
  /// good moving fix is off the route at once.
  static const double offRouteNowM = 120;

  /// My direction differs from the route's by more than this (degrees):
  /// heading away from it.
  static const double divergeDeg = 30;

  /// Heading away also counts when the distance grew this much (metres)
  /// since the closest fix of this departure (direction unknown, or a road
  /// that slowly leaves the route).
  static const double divergeGrowM = 15;

  /// Back on the route: closer than this (metres)...
  static const double rejoinM = 25;

  /// ...widened by poor GPS up to this much at most (metres)...
  static const double rejoinMaxM = 40;

  /// ...for at least this long while moving.
  static const Duration rejoinHold = Duration(seconds: 5);

  /// Slower than this (km/h) is stopped: such fixes neither count nor reset.
  static const double minSpeedKmh = 5;

  /// Fixes less accurate than this (metres) are ignored.
  static const double maxAccuracyM = 50;

  /// A longer gap between two fixes counts as only this much time.
  static const Duration maxFixGap = Duration(seconds: 10);

  // -------------------------------------------------------------- reroute

  /// At most one new-route request per this interval (from its start).
  static const Duration minRerouteInterval = Duration(seconds: 15);

  /// A request with no answer after this long counts as failed.
  static const Duration requestTimeout = Duration(seconds: 20);

  /// After this many failed requests in a row, stop asking.
  static const int maxFailures = 3;

  /// After giving up, one quiet new try at most once per this interval.
  static const Duration retryAfterGiveUp = Duration(minutes: 5);

  // ------------------------------------------------------------ prompts

  /// No off-route prompt within this long after a new route arrived.
  static const Duration quietAfterReroute = Duration(seconds: 60);

  /// Never more than one off-route prompt per this interval.
  static const Duration offRoutePromptEvery = Duration(minutes: 2);

  /// "New route ready." at most once per this interval.
  static const Duration readyPromptEvery = Duration(minutes: 2);

  /// Off-route limit for a fix with this accuracy (metres).
  static double offLimitFor(double? accuracyM) => math.max(offRouteM, (accuracyM ?? 0) * accuracyFactor);

  /// Immediate off-route limit for a fix with this accuracy (metres).
  static double offNowLimitFor(double? accuracyM) => math.max(offRouteNowM, (accuracyM ?? 0) * accuracyFactor);

  /// Back-on-route limit for a fix with this accuracy (metres).
  static double rejoinLimitFor(double? accuracyM) => math.max(rejoinM, math.min(accuracyM ?? 0, rejoinMaxM));

  /// Smallest angle between two directions (degrees, 0 to 180).
  static double angleBetween(double a, double b) {
    final d = ((a - b) % 360 + 360) % 360;
    return d > 180 ? 360 - d : d;
  }

  /// Initial bearing from point 1 to point 2, 0 to 360 degrees (0 = north).
  static double bearing(double lat1, double lng1, double lat2, double lng2) {
    const r = math.pi / 180;
    final p1 = lat1 * r, p2 = lat2 * r;
    final dl = (lng2 - lng1) * r;
    final y = math.sin(dl) * math.cos(p2);
    final x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
    return (math.atan2(y, x) / r + 360) % 360;
  }
}
