import 'dart:math' as math;

/// Everything the position cadence depends on at one GPS fix (plain values, no plugins: unit-tested in
/// `test/rt8_adaptive_position_rate_test.dart` with the plain Dart VM).
class PositionContext {
  final double speedKmh;
  final double headingDeg;

  /// The phone thinks the bike is moving (>= 3 km/h in ConvoyService).
  final bool moving;

  /// Parked for minutes (the GPS idle profile is on): only a "last seen" heartbeat is needed.
  final bool parked;

  /// Data saver, battery conserving / low battery or the battery saver's slow telemetry.
  final bool lowData;

  /// The group has an open alert, an assistance request or a hazard: normal cadence is kept (existing rule).
  final bool critical;

  /// This rider's own SOS / crash alert is open: the group follows them closely.
  final bool ownSos;

  /// This rider is the LEAD or the SWEEPER: their position anchors the group.
  final bool leadOrSweep;

  final int groupSize;

  const PositionContext({
    required this.speedKmh,
    this.headingDeg = 0,
    required this.moving,
    this.parked = false,
    this.lowData = false,
    this.critical = false,
    this.ownSos = false,
    this.leadOrSweep = false,
    this.groupSize = 1,
  });
}

/// Round 8 adaptive position rate (HIGH_TRAFFIC_PLAN_v3.57 item 4): how often this phone sends its position to the
/// group, by speed and context, and when it sends at once.
///
/// Cadence (normal data, normal battery):
///   above 60 km/h            1 s
///   town (15-60 km/h)        2.5 s
///   slow (moving, < 15)      5 s
///   stopped (< 3 km/h)       10 s
///   parked (idle profile)    30 s (the existing "last seen" heartbeat)
/// Context:
///   own SOS open             1 s, always (the group must follow the rider in trouble)
///   LEAD / SWEEPER           at most 2.5 s while moving, 5 s stopped
///   group alert (critical)   at most 2.5 s while moving, 5 s stopped or parked; data saver never slows it (as before)
///   data saver / battery     twice as long, at most 10 s moving and 30 s stopped (as before: radio work first)
///   big groups               at least 2 s above 25 riders, 2.5 s above 50 (every fix fans out to everyone)
///   floor                    1 s (the gateway accepts 3 positions a second; never plan near it)
/// At once (still never closer than the 1 s floor): a sharp turn (>= 30 degrees since the last sent fix while above
/// 15 km/h), a sharp stop (from >= 20 km/h to stopped), moving off from a stop, the own SOS opening, becoming LEAD or
/// SWEEPER.
class AdaptivePositionRate {
  static const int floorMs = 1000;
  static const int highwayMs = 1000;
  static const int townMs = 2500;
  static const int slowMs = 5000;
  static const int stoppedMs = 10000;
  static const int parkedMs = 30000;
  static const double fastKmh = 60;
  static const double townKmh = 15;
  static const double sharpTurnDeg = 30;

  /// The send interval for one context.
  static Duration interval(PositionContext c) {
    if (c.ownSos) return const Duration(milliseconds: highwayMs);
    int ms;
    if (c.parked && !c.moving) {
      ms = parkedMs;
    } else if (!c.moving) {
      ms = stoppedMs;
    } else if (c.speedKmh > fastKmh) {
      ms = highwayMs;
    } else if (c.speedKmh >= townKmh) {
      ms = townMs;
    } else {
      ms = slowMs;
    }
    if (c.lowData && !c.critical) ms = c.moving ? math.min(ms * 2, 10000) : math.min(ms * 2, parkedMs);
    if (c.leadOrSweep) ms = math.min(ms, c.moving ? townMs : slowMs);
    if (c.critical) ms = math.min(ms, c.moving ? townMs : slowMs);
    final groupFloor = c.groupSize > 50 ? 2500 : (c.groupSize > 25 ? 2000 : floorMs);
    ms = math.max(ms, math.max(groupFloor, floorMs));
    return Duration(milliseconds: ms);
  }

  int _lastSentMs = -1;
  double _lastSpeed = 0;
  double _lastHeading = 0;
  bool _lastOwnSos = false;
  bool _lastLeadOrSweep = false;

  /// Why the next fix goes out at once, or null.
  String? immediateReason(PositionContext c) {
    if (_lastSentMs < 0) return 'first';
    if (c.ownSos && !_lastOwnSos) return 'sos';
    if (c.leadOrSweep && !_lastLeadOrSweep) return 'role';
    if (c.speedKmh >= townKmh && _headingDelta(_lastHeading, c.headingDeg) >= sharpTurnDeg) return 'turn';
    if (_lastSpeed >= 20 && !c.moving) return 'stop';
    if (_lastSpeed < 3 && c.speedKmh >= 10) return 'start';
    return null;
  }

  /// True when the fix at [nowMs] should be sent (the caller then calls [noteSent]).
  bool shouldSend(PositionContext c, int nowMs) {
    if (_lastSentMs < 0) return true;
    final since = nowMs - _lastSentMs;
    if (since < floorMs && !(c.ownSos && !_lastOwnSos)) return false;
    if (immediateReason(c) != null) return true;
    return since >= interval(c).inMilliseconds;
  }

  /// A position went out (from here or from any other path that pushes telemetry).
  void noteSent(int nowMs, {required double speedKmh, required double headingDeg, bool ownSos = false, bool leadOrSweep = false}) {
    _lastSentMs = nowMs;
    _lastSpeed = speedKmh;
    _lastHeading = headingDeg;
    _lastOwnSos = ownSos;
    _lastLeadOrSweep = leadOrSweep;
  }

  void reset() {
    _lastSentMs = -1;
    _lastSpeed = 0;
    _lastHeading = 0;
    _lastOwnSos = false;
    _lastLeadOrSweep = false;
  }

  static double _headingDelta(double a, double b) {
    final d = ((b - a) % 360 + 360) % 360;
    return d > 180 ? 360 - d : d;
  }
}
