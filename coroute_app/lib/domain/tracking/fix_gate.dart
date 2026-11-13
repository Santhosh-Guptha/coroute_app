import 'dart:math' as math;

/// Why a GPS fix was not used for the live position.
enum FixReject { none, invalid, outOfOrder, stale, teleport }

/// 3.56 app audit (docs/quality/APP_AUDIT_v3.56.md, G-01..G-04): the gate in front of the LIVE
/// position (own marker, what the group and guardians see, the place an SOS reports).
///
/// The speed has its own filter (SpeedEstimator) and the recorded track its own (TrackFilter,
/// TrackCleaner); before this gate the live position took every fix as it came, so:
///  * a cached fix replayed when the position stream is re-subscribed (every cadence change) could
///    move the marker BACK and make time run backwards;
///  * a wild fix after a tunnel or between tall buildings could teleport the marker;
///  * a parked bike wandered by the GPS noise ("phantom movement" for the group).
///
/// Pure Dart; every rule is covered by test/fix_gate_356_test.dart.
class FixGate {
  /// A fix this much older than the phone's clock is a cached one (or a replay), not "now".
  static const int staleMs = 120000;

  /// After this many "stale" fixes in a row the phone's clock is simply wrong: the rule is switched
  /// off for the rest of the ride (a wrong clock must never cost the rider their position).
  static const int staleGiveUp = 5;

  /// Faster than this between two fixes (and further than [teleportMinM]) is not a motorcycle.
  static const double teleportMps = 100; // 360 km/h
  static const double teleportMinM = 200;

  /// Jumps that keep agreeing are real (GPS came back somewhere else): accept the third.
  static const int teleportReanchor = 3;

  /// A position worse than this is not shown while a recent good one exists.
  static const double coarseM = 100;

  int _lastTs = 0;
  double? _lat;
  double? _lng;
  int _staleRun = 0;
  bool _staleRuleOff = false;
  int _jumpRun = 0;
  double? _jumpLat;
  double? _jumpLng;
  int _jumpTs = 0;

  /// Counters for the diagnostics log (no positions).
  int rejectedOutOfOrder = 0;
  int rejectedStale = 0;
  int rejectedTeleport = 0;
  int rejectedInvalid = 0;

  bool get clockRuleOff => _staleRuleOff;
  int get lastAcceptedTs => _lastTs;

  void reset() {
    _lastTs = 0;
    _lat = null;
    _lng = null;
    _staleRun = 0;
    _staleRuleOff = false;
    _jumpRun = 0;
    _jumpLat = null;
    _jumpLng = null;
    _jumpTs = 0;
  }

  /// Decides on one fix. [tsMs] is the fix's own time, [wallMs] the phone's clock now.
  /// [FixReject.none] = use it (and it becomes the reference for the next one).
  FixReject check({required double lat, required double lng, required int tsMs, required int wallMs}) {
    if (!lat.isFinite || !lng.isFinite || lat.abs() > 90 || lng.abs() > 180 || (lat == 0 && lng == 0) || tsMs <= 0) {
      rejectedInvalid++;
      return FixReject.invalid;
    }
    // Time never runs backwards: a replayed or duplicated fix is dropped.
    if (_lastTs > 0 && tsMs <= _lastTs) {
      rejectedOutOfOrder++;
      return FixReject.outOfOrder;
    }
    if (!_staleRuleOff && wallMs - tsMs > staleMs) {
      _staleRun++;
      if (_staleRun >= staleGiveUp) {
        _staleRuleOff = true; // the clock is wrong, not the fixes
      } else {
        rejectedStale++;
        return FixReject.stale;
      }
    } else {
      _staleRun = 0;
    }
    final pLat = _lat, pLng = _lng;
    if (pLat != null && pLng != null) {
      final d = distanceM(pLat, pLng, lat, lng);
      final dt = (tsMs - _lastTs) / 1000.0;
      if (d > teleportMinM && d > teleportMps * dt) {
        // Does it agree with the previous jump (same new place)? Then GPS really is over there.
        final jLat = _jumpLat, jLng = _jumpLng;
        final agrees = jLat != null && jLng != null && distanceM(jLat, jLng, lat, lng) <= math.max(teleportMinM, teleportMps * (tsMs - _jumpTs) / 1000.0);
        _jumpRun = agrees ? _jumpRun + 1 : 1;
        _jumpLat = lat;
        _jumpLng = lng;
        _jumpTs = tsMs;
        if (_jumpRun < teleportReanchor) {
          rejectedTeleport++;
          return FixReject.teleport;
        }
      }
    }
    _jumpRun = 0;
    _jumpLat = null;
    _jumpLng = null;
    _lastTs = tsMs;
    _lat = lat;
    _lng = lng;
    return FixReject.none;
  }

  /// Should the marker stay where it is although a new (accepted) fix arrived?
  ///
  ///  * stopped (below walking pace) and the fix is within its own noise of the shown position
  ///    (at least [minHoldM], at most [coarseM]): yes, a parked bike does not wander;
  ///  * a coarse fix (worse than [coarseM]) while a good position was shown less than
  ///    [coarseHoldMs] ago: yes, a wild network fix does not replace a good GPS one.
  /// Everything else moves the marker. Speed, battery and "last seen" are always updated.
  static bool holdPosition({
    required bool moving,
    required double accuracyM,
    required double distanceFromShownM,
    required int msSinceShownMoved,
    double minHoldM = 12,
    int coarseHoldMs = 30000,
  }) {
    final acc = accuracyM.isFinite && accuracyM > 0 ? accuracyM : 999.0;
    if (acc > coarseM) return msSinceShownMoved < (moving ? coarseHoldMs ~/ 3 : coarseHoldMs);
    if (moving) return false;
    return distanceFromShownM <= math.max(minHoldM, acc);
  }

  /// Great-circle distance in metres (haversine).
  static double distanceM(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
    final dp = p2 - p1, dl = (lng2 - lng1) * math.pi / 180;
    final a = math.sin(dp / 2) * math.sin(dp / 2) + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
  }
}

/// 3.56 audit G-07: the position stream can END on its own (the provider was restarted, the OS
/// closed the listener after an error). Before, nothing re-opened it: the ride went on without
/// positions until the app was restarted. Re-open with growing waits (no restart storm), and start
/// again from the short wait once fixes arrive.
class GpsRestartBackoff {
  static const List<int> waitsS = [2, 5, 15, 30, 60];
  int _attempt = 0;

  int get attempts => _attempt;

  /// The wait before the next re-open (2 s, 5 s, 15 s, 30 s, then every 60 s).
  Duration next() {
    final s = waitsS[_attempt < waitsS.length ? _attempt : waitsS.length - 1];
    _attempt++;
    return Duration(seconds: s);
  }

  /// A fix arrived: the stream is healthy again.
  void reset() => _attempt = 0;
}

/// 3.56 audit B-01: when to show Android's "run in the background" question at ride start.
class BatteryExemptionAsk {
  BatteryExemptionAsk._();

  static const int everyMs = 7 * 24 * 3600 * 1000;

  static bool shouldAsk({required int nowMs, required int lastAskedMs, required bool alreadyExempt}) {
    if (alreadyExempt) return false;
    if (lastAskedMs <= 0) return true;
    // A clock set back must not silence the question for ever.
    if (lastAskedMs > nowMs) return true;
    return nowMs - lastAskedMs >= everyMs;
  }
}
