import '../places/route_corridor.dart';
import '../tracking/geo_math.dart';

/// 3.55 "You left the group's route": when a rider of a group ride misses a turn, first offer the
/// way back to the group, then the other choices (ask the group to wait, or carry on alone).
/// Pure: no Flutter, no I/O, no timers; the cockpit feeds it on rebuilds.

/// Another rider of the ride as this logic needs them.
class GroupPeer {
  const GroupPeer({required this.userId, required this.name, required this.lat, required this.lng, required this.lastSeenMs});
  final String userId;
  final String name;
  final double lat, lng;
  final int lastSeenMs;

  bool get hasPosition => lat != 0 || lng != 0;
  bool freshAt(int nowMs) => hasPosition && nowMs - lastSeenMs <= OffRouteGroupMonitor.freshFor.inMilliseconds;
}

/// Where "Route to group" takes me.
class RejoinTarget {
  const RejoinTarget({required this.lat, required this.lng, required this.name, required this.peer, required this.onRoute});
  final double lat, lng;

  /// Shown as the stop name ("Group near Ravi").
  final String name;

  /// The closest rider with a fresh position.
  final GroupPeer peer;

  /// True when the target is on the group's planned route (else the rider's own position).
  final bool onRoute;
}

/// What the cockpit should do at this moment.
class OffRouteGroupDecision {
  const OffRouteGroupDecision({this.show = false, this.speak = false});
  static const none = OffRouteGroupDecision();

  /// Show the important slot "You left the group's route".
  final bool show;

  /// Say the line once (true on the first moment of [show] in this departure only).
  final bool speak;
}

/// Decides when to offer the way back to the group.
///
/// * Only in a group ride (at least two riders).
/// * Only after I have been off the group's planned route for [showAfter].
/// * Not when every other rider with a fresh position is within [togetherM] of me: the group is
///   with me (a lead whose pack follows them, or a detour taken together).
/// * Once per departure: after a choice (or "Keep my own route") it stays quiet until I am back on
///   the route; the spoken line too.
class OffRouteGroupMonitor {
  static const Duration showAfter = Duration(seconds: 20);
  static const Duration freshFor = Duration(minutes: 2);
  static const double togetherM = 300;

  static const String title = "You left the group's route";
  /// Said once while moving (owner decision: speak while moving, act when stopped).
  static const String spoken = "You're off the route. Stop when safe to route to your group.";

  /// Said once when the rider is already stopped (the buttons are on the screen).
  static const String spokenStopped = "You left the group's route. Choose on the screen.";

  int? _offSinceMs;
  bool _armed = true;
  bool _spoken = false;

  /// True while off route in this departure (for tests and the cockpit).
  bool get off => _offSinceMs != null;

  /// One look at the current state.
  OffRouteGroupDecision update({
    required bool offPlan,
    required int nowMs,
    required int riderCount,
    required double? myLat,
    required double? myLng,
    required Iterable<GroupPeer> others,
  }) {
    if (!offPlan) {
      // Back on the route: the next departure may ask again.
      _offSinceMs = null;
      _armed = true;
      _spoken = false;
      return OffRouteGroupDecision.none;
    }
    final since = _offSinceMs ??= nowMs;
    if (!_armed || riderCount < 2) return OffRouteGroupDecision.none;
    if (nowMs - since < showAfter.inMilliseconds) return OffRouteGroupDecision.none;
    if (myLat != null && myLng != null && (myLat != 0 || myLng != 0)) {
      final fresh = others.where((p) => p.freshAt(nowMs)).toList();
      if (fresh.isNotEmpty && fresh.every((p) => GeoMath.haversine(myLat, myLng, p.lat, p.lng) <= togetherM)) {
        return OffRouteGroupDecision.none;
      }
    }
    final speak = !_spoken;
    _spoken = true;
    return OffRouteGroupDecision(show: true, speak: speak);
  }

  /// A choice was made ("Route to group", "Ask group to wait", "Keep my own route"): quiet until
  /// I am back on the route.
  void resolve() => _armed = false;

  /// The way back: the point of the group's planned route nearest to the closest rider with a
  /// fresh position, or that rider's position when there is no route. Null without such a rider.
  static RejoinTarget? target({
    required double myLat,
    required double myLng,
    required Iterable<GroupPeer> others,
    required int nowMs,
    RoutePath? plan,
  }) {
    GroupPeer? best;
    var bestD = double.infinity;
    for (final p in others) {
      if (!p.freshAt(nowMs)) continue;
      final d = GeoMath.haversine(myLat, myLng, p.lat, p.lng);
      if (d < bestD) {
        bestD = d;
        best = p;
      }
    }
    if (best == null) return null;
    final label = best.name.trim().isEmpty ? 'Group' : 'Group near ${best.name.trim()}';
    if (plan != null && plan.valid) {
      final hit = plan.project(best.lat, best.lng);
      if (hit != null) {
        final (lat, lng) = plan.pointAt(hit.along);
        return RejoinTarget(lat: lat, lng: lng, name: label, peer: best, onRoute: true);
      }
    }
    return RejoinTarget(lat: best.lat, lng: best.lng, name: label, peer: best, onRoute: false);
  }
}
