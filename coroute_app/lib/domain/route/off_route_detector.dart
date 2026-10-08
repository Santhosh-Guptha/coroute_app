import 'dart:math' as math;

import '../../core/constants/ride_thresholds.dart';
import '../../core/constants/route_constants.dart';

/// Where the rider is relative to one route line.
enum OffRouteState {
  /// On the line (or not decided yet).
  onRoute,

  /// Farther than the limit, but not for long enough yet.
  leaving,

  /// Off the line: farther than the limit for [RouteConstants.offRouteFixes]
  /// moving fixes in a row and for at least [RouteConstants.offRouteFor].
  offRoute,
}

/// Decides, fix by fix, whether the rider left a route line or came back to
/// it. Pure state machine: it only looks at the fixes it is given (distance
/// from the line, accuracy, speed, time), never starts a timer.
///
/// * Going off needs [RouteConstants.offRouteFixes] moving fixes in a row
///   farther than [limitFor] AND at least [RouteConstants.offRouteFor]
///   between the first and the last of them.
/// * Coming back needs [RouteConstants.rejoinFixes] moving fixes in a row
///   within [rejoinLimitFor], each farther along the line than the one
///   before when the position along the line is known (riding the planned
///   road backwards is not "back on the route").
/// * Fixes with accuracy worse than [RouteConstants.maxUsableAccuracyM] are
///   ignored. Fixes slower than [RideThresholds.movingSpeedKmh] neither count
///   nor reset (a rider waiting at a fuel pump next to the road is not
///   rerouted, and a red light does not undo a count).
class OffRouteDetector {
  OffRouteDetector({OffRouteState initial = OffRouteState.onRoute}) : _state = initial;

  OffRouteState _state;
  int _count = 0;
  int _firstAtMs = 0;
  double? _lastAlong;

  OffRouteState get state => _state;
  bool get isOff => _state == OffRouteState.offRoute;

  /// Off-route limit for a fix with this accuracy (metres).
  static double limitFor(double? accuracyM) =>
      math.max(RouteConstants.offRouteM, (accuracyM ?? 0.0) * RouteConstants.offRouteAccuracyFactor);

  /// Back-on-route limit for a fix with this accuracy (metres).
  static double rejoinLimitFor(double? accuracyM) => math.max(RouteConstants.rejoinM, accuracyM ?? 0.0);

  /// Starts over in [state] (a new line, or a new personal route).
  void reset([OffRouteState state = OffRouteState.onRoute]) {
    _state = state;
    _count = 0;
    _firstAtMs = 0;
    _lastAlong = null;
  }

  /// One fix: [offM] metres from the line, [alongM] metres along it (when
  /// known). Returns the state after this fix.
  OffRouteState onFix({
    required int tsMs,
    required double offM,
    double? alongM,
    double? accuracyM,
    required double speedKmh,
  }) {
    final acc = accuracyM;
    if (acc != null && acc > RouteConstants.maxUsableAccuracyM) return _state;
    if (!offM.isFinite) return _state;
    final moving = speedKmh >= RideThresholds.movingSpeedKmh;

    if (_state == OffRouteState.offRoute) {
      if (offM > rejoinLimitFor(acc)) {
        _count = 0;
        _lastAlong = null;
        return _state;
      }
      if (!moving) return _state;
      final prev = _lastAlong;
      if (alongM != null && prev != null && alongM <= prev) {
        // On the line but not going forward along it: start counting again from here.
        _count = 1;
        _lastAlong = alongM;
        return _state;
      }
      _count++;
      _lastAlong = alongM;
      if (_count >= RouteConstants.rejoinFixes) reset(OffRouteState.onRoute);
      return _state;
    }

    if (offM <= limitFor(acc)) {
      if (_state == OffRouteState.leaving || _count > 0) reset(OffRouteState.onRoute);
      return _state;
    }
    if (!moving) return _state;
    _count++;
    if (_count == 1) _firstAtMs = tsMs;
    if (_count >= RouteConstants.offRouteFixes && tsMs - _firstAtMs >= RouteConstants.offRouteFor.inMilliseconds) {
      _state = OffRouteState.offRoute;
      _count = 0;
      _lastAlong = null;
    } else {
      _state = OffRouteState.leaving;
    }
    return _state;
  }
}
