/// Rules for following the route during a ride: matching my position to the
/// route line, deciding when I left it, and how often a new route may be
/// asked for. One place, so the ride screen and the tests agree.
///
/// Battery and cost: all of this runs on the location fixes the app already
/// gets. Nothing here starts a timer or asks for extra GPS fixes.
class RouteConstants {
  RouteConstants._();

  // ------------------------------------------------------------ off route

  /// Farther than this from the route line counts as off the route (metres).
  static const double offRouteM = 150;

  /// With poor GPS the limit grows to accuracy x this factor, so a wobbly
  /// fix is not mistaken for leaving the route.
  static const double offRouteAccuracyFactor = 2;

  /// Fixes less accurate than this (metres) are ignored for off-route decisions.
  static const double maxUsableAccuracyM = 100;

  /// Off the route for at least this many fixes in a row...
  static const int offRouteFixes = 3;

  /// ...and for at least this long, while moving.
  static const Duration offRouteFor = Duration(seconds: 20);

  /// Back on a route: within this distance (or the GPS accuracy, if larger).
  static const double rejoinM = 50;

  /// Back on a route for this many fixes in a row, moving forward along it.
  static const int rejoinFixes = 2;

  // ------------------------------------------------------------- matching

  /// Matching looks this far ahead of the last matched point (metres)...
  static const double matchAheadM = 3000;

  /// ...and only this far back (GPS jitter), so a loop or an out-and-back
  /// road never snaps to the wrong pass.
  static const double matchBackM = 30;

  /// Candidates this close to the line (or within the GPS accuracy) count
  /// as "here"; among them the earliest point along the route wins.
  static const double matchNearM = 35;

  /// While not matched, the whole line is searched again at most once per
  /// this much movement (metres), so the search stays cheap.
  static const double reacquireEveryM = 250;

  // -------------------------------------------------------------- reroute

  /// At most one new-route request per this interval...
  static const Duration rerouteMinInterval = Duration(seconds: 60);

  /// ...or per this interval while data saver is on.
  static const Duration rerouteMinIntervalLowData = Duration(minutes: 3);

  /// After failed requests the wait doubles (from [rerouteMinInterval]) up to this.
  static const Duration rerouteMaxBackoff = Duration(minutes: 10);

  /// The route service accepts at most this many points (start, stops, destination).
  static const int maxWaypoints = 25;

  /// Within this many metres of the end of the route (along it) I have
  /// arrived: riding around the destination town is not "off the route",
  /// so no new route is asked for from then on.
  static const double nearDestinationM = 300;

  /// "Back on the planned route" stays in the status line this long (checked on the next fixes, no timer).
  static const Duration backOnRouteNoticeFor = Duration(seconds: 30);
}
