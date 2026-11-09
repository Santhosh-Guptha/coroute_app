// 3.55 owner decision "taps while moving": speak while moving, act when stopped.
//
// Non-urgent cockpit cards that need a tap (off-route "Route to group", bike / rider-pillion swap
// request, historic place on the way, place review question) show their buttons only when the
// rider is stopped. While moving the cockpit says one short line once and shows at most a compact
// chip with no buttons. Safety cards (SOS, crash alarm, rider down, siren) never go through this
// gate.
//
// Pure Dart: no Flutter, no timers. The cockpit feeds the rider's public speed (the rider record's
// speedKmh, from the tracking layer; this class never estimates speed) and the clock.

/// Moving or stopped, with hysteresis.
///
/// * Moving as soon as the speed is [movingKmh] or more.
/// * Stopped once the speed has stayed at [stoppedKmh] or less for [stoppedHold].
/// * Anything in between keeps the current state (and restarts the stop wait).
/// * A pillion ([passenger]) can always tap: someone else is riding.
class RideTapGate {
  static const double movingKmh = 8;
  static const double stoppedKmh = 3;
  static const Duration stoppedHold = Duration(seconds: 5);

  bool _moving = false;
  int? _slowSinceMs;
  double _lastSpeed = 0;

  /// True while the rider rides pillion (set on every [update]).
  bool passenger = false;

  /// True while moving (no buttons on the gated cards, unless [passenger]).
  bool get moving => _moving;

  /// The gated cards may show their buttons now.
  bool get canTap => passenger || !_moving;

  /// When the rider will count as stopped if the speed stays low (epoch ms), else null. The
  /// cockpit arms a one-shot timer for it: a parked phone may send no new fix.
  int? get settleAtMs {
    final s = _slowSinceMs;
    return _moving && s != null ? s + stoppedHold.inMilliseconds : null;
  }

  /// One speed sample. Returns true when [canTap] changed.
  bool update({required double speedKmh, required int nowMs, bool passenger = false}) {
    final before = canTap;
    this.passenger = passenger;
    if (speedKmh.isFinite && speedKmh >= 0) _lastSpeed = speedKmh;
    _step(nowMs);
    return canTap != before;
  }

  /// Re-checks with the last speed (a timer at [settleAtMs]). Returns true when [canTap] changed.
  bool tick(int nowMs) {
    final before = canTap;
    _step(nowMs);
    return canTap != before;
  }

  void _step(int nowMs) {
    final v = _lastSpeed;
    if (v >= movingKmh) {
      _moving = true;
      _slowSinceMs = null;
    } else if (v <= stoppedKmh) {
      final since = _slowSinceMs ??= nowMs;
      if (nowMs - since >= stoppedHold.inMilliseconds) _moving = false;
    } else {
      _slowSinceMs = null;
    }
  }

  void reset() {
    _moving = false;
    _slowSinceMs = null;
    _lastSpeed = 0;
    passenger = false;
  }
}

/// Says each gated card's moving line at most once (per card key).
class MovingLineOnce {
  final Set<String> _said = <String>{};

  /// True the first time for [key] (then false); keeps at most 100 keys.
  bool take(String key) {
    if (_said.contains(key)) return false;
    if (_said.length >= 100) _said.clear();
    _said.add(key);
    return true;
  }

  void reset() => _said.clear();
}

/// The short lines and chip texts for the gated cards (glove-friendly, one line each).
class MovingCardText {
  MovingCardText._();

  // The off-route spoken lines live with the monitor (OffRouteGroupMonitor.spoken / spokenStopped).
  static const String offRouteChip = "Off the group's route · Stop to choose";

  static String swapChip(String title) => '$title · Stop to answer';

  static String heritageChip(String name) => 'Historic place ahead: $name';

  static String reviewSpoken(String placeName) => 'Rate $placeName when you stop.';
  static String reviewChip(String placeName) => 'Rate $placeName when you stop';
}
