import 'dart:math' as math;

import 'reroute_rules.dart';

/// Where I am relative to the route I follow.
enum FollowState {
  /// On the route (or not decided yet).
  onRoute,

  /// Beyond the off-route limit, not for long enough yet.
  leaving,

  /// Off the route.
  offRoute,
}

/// What changed with one fix.
enum FollowEvent { none, wentOff, cameBack }

/// One location fix, as the navigation logic needs it.
class NavFix {
  const NavFix({required this.tsMs, required this.speedKmh, this.accuracyM, this.headingDeg});

  /// Time of the fix (epoch ms).
  final int tsMs;

  /// Speed (km/h).
  final double speedKmh;

  /// GPS accuracy (metres), when known.
  final double? accuracyM;

  /// Direction of travel (degrees, 0 = north), when known.
  final double? headingDeg;
}

/// Decides, fix by fix, whether I left the route I follow or came back to it
/// ([RerouteRules]). Pure state machine: no timers, only the fixes given.
///
/// * Off: farther than [RerouteRules.offLimitFor] for at least
///   [RerouteRules.offRouteHold] of moving time while heading away from the
///   route, or farther than [RerouteRules.offNowLimitFor] on one good fix.
/// * Back: closer than [RerouteRules.rejoinLimitFor] for at least
///   [RerouteRules.rejoinHold] of moving time.
/// * Between the two limits nothing changes (hysteresis), so GPS jitter
///   around one distance never flips the state back and forth.
/// * Fixes slower than [RerouteRules.minSpeedKmh] neither count nor reset
///   (a red light or a fuel stop next to the road); fixes worse than
///   [RerouteRules.maxAccuracyM] are ignored.
class OffRouteMonitor {
  OffRouteMonitor({bool off = false}) : _state = off ? FollowState.offRoute : FollowState.onRoute;

  FollowState _state;

  // Leaving: moving time beyond the limit, and how it developed.
  int _heldMs = 0;
  int? _prevTs;
  double _minOffM = double.infinity;
  double? _prevOffM;
  int _divergingFixes = 0;

  // Coming back: moving time within the rejoin limit.
  bool _rejoining = false;
  int _rejoinMs = 0;
  int? _rejoinPrevTs;

  FollowState get state => _state;
  bool get isOff => _state == FollowState.offRoute;

  /// Starts over: on the route, or off it with [off] (a new line to follow).
  void reset({bool off = false}) {
    _state = off ? FollowState.offRoute : FollowState.onRoute;
    _clearLeaving();
    _clearRejoin();
  }

  void _clearLeaving() {
    _heldMs = 0;
    _prevTs = null;
    _minOffM = double.infinity;
    _prevOffM = null;
    _divergingFixes = 0;
  }

  void _clearRejoin() {
    _rejoining = false;
    _rejoinMs = 0;
    _rejoinPrevTs = null;
  }

  static int _dt(int from, int to) => math.max(0, math.min(to - from, RerouteRules.maxFixGap.inMilliseconds));

  /// One fix [offM] metres from the route; [routeBearingDeg] is the route's
  /// direction at the nearest point. With [suppress] (tunnel coasting, a
  /// tunnel portal) a departure in progress is dropped and nothing is decided.
  FollowEvent onFix(NavFix fix, {required double offM, double? routeBearingDeg, bool suppress = false}) {
    if (suppress) {
      if (_state == FollowState.leaving) {
        _state = FollowState.onRoute;
        _clearLeaving();
      }
      _rejoinPrevTs = null;
      return FollowEvent.none;
    }
    if (!offM.isFinite || offM < 0) return FollowEvent.none;
    final acc = fix.accuracyM;
    if (acc != null && (!acc.isFinite || acc > RerouteRules.maxAccuracyM)) return FollowEvent.none;
    final moving = fix.speedKmh.isFinite && fix.speedKmh >= RerouteRules.minSpeedKmh;
    if (_state == FollowState.offRoute) return _whileOff(fix, offM, acc, moving);

    if (offM <= RerouteRules.offLimitFor(acc)) {
      if (_state == FollowState.leaving) {
        _state = FollowState.onRoute;
        _clearLeaving();
      }
      return FollowEvent.none;
    }
    if (!moving) {
      _prevTs = null; // paused: the time stopped is not counted
      return FollowEvent.none;
    }
    if (offM > RerouteRules.offNowLimitFor(acc)) return _goOff();

    if (_state != FollowState.leaving) {
      _state = FollowState.leaving;
      _clearLeaving();
    } else {
      final prev = _prevTs;
      if (prev != null) _heldMs += _dt(prev, fix.tsMs);
    }
    _prevTs = fix.tsMs;

    final prevOff = _prevOffM;
    final approaching = prevOff != null && offM < prevOff - 2;
    final h = fix.headingDeg;
    final b = routeBearingDeg;
    if (!approaching && h != null && b != null && h.isFinite && b.isFinite && RerouteRules.angleBetween(h, b) > RerouteRules.divergeDeg) {
      _divergingFixes++;
    }
    if (offM < _minOffM) _minOffM = offM;
    _prevOffM = offM;
    final away = _divergingFixes >= 2 || offM - _minOffM >= RerouteRules.divergeGrowM;
    if (_heldMs >= RerouteRules.offRouteHold.inMilliseconds && away) return _goOff();
    return FollowEvent.none;
  }

  FollowEvent _goOff() {
    _state = FollowState.offRoute;
    _clearLeaving();
    _clearRejoin();
    return FollowEvent.wentOff;
  }

  FollowEvent _whileOff(NavFix fix, double offM, double? acc, bool moving) {
    if (offM >= RerouteRules.rejoinLimitFor(acc)) {
      _clearRejoin();
      return FollowEvent.none;
    }
    if (!moving) {
      _rejoinPrevTs = null;
      return FollowEvent.none;
    }
    if (!_rejoining) {
      _rejoining = true;
      _rejoinMs = 0;
    } else {
      final prev = _rejoinPrevTs;
      if (prev != null) _rejoinMs += _dt(prev, fix.tsMs);
    }
    _rejoinPrevTs = fix.tsMs;
    if (_rejoinMs >= RerouteRules.rejoinHold.inMilliseconds) {
      _state = FollowState.onRoute;
      _clearLeaving();
      _clearRejoin();
      return FollowEvent.cameBack;
    }
    return FollowEvent.none;
  }
}
