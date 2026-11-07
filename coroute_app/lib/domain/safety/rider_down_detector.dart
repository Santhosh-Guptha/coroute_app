// Rider-down check (3.55): "Bike down?" when the bike falls while stopped or at walking pace.
//
// The crash detector arms only at riding pace; a bike that tips over at a junction, on a slope
// while parking, or while being pushed is a different pattern: a quick tilt of more than 60
// degrees with a thud, then the phone lies still. Pure Dart, no Flutter, no timers: fed with
// the same 1 s accelerometer buckets and fixes as the crash detector. It returns a
// [RiderDownEvent] once; SafetyService then opens the existing crash alarm ("Bike down?"),
// with the same countdown, SOS and text fallback.
//
// Conservative on purpose (false alarms teach riders to ignore alarms):
//  * slow: the last fix (at most [fixFreshFor] old) is below [slowKmh] (8 km/h);
//  * tip-over: within [tipWindow] (~2 s) the tilt rose by more than [tipDeltaDeg] (60 deg), and
//    the bike reached at least [tipMinTiltDeg] from the riding baseline. A side stand
//    (10-15 deg) never qualifies;
//  * a thud: peak >= [thudG] or dynamic peak >= [thudDynG] within the tip window. A phone lifted
//    out of the mount and slid into a pocket turns as much, but without the impact;
//  * nobody was walking with the phone before ([walkStdG] in [walkBuckets] of the 5 s before);
//  * then [stillFor] (60 s) without movement, after a [settle] of 3 s: every bucket calm
//    (std <= [stillStdG], gyro <= [stillGyroRadS]) for at least 75% of the seconds, the bike
//    still down (tilt >= [downMinTiltDeg]), no fix faster than [slowKmh] and none farther than
//    [maxMoveM] away. Steps (std > [moveStdG]), body sway in a pocket (gyro above
//    [bodyGyroRadS] for [bodyBuckets] seconds), the bike lifted back up, or riding on cancel.
import 'dart:math' as math;

import '../tracking/geo_math.dart';
import '../tracking/track_point.dart';
import 'accel_bucket.dart';

/// The bike went down and nobody moved for a minute.
class RiderDownEvent {
  final int tipAtMs;
  final int atMs;
  final double lat;
  final double lng;
  final double tiltDeg;
  final double peakG;
  final double speedBeforeKmh;

  const RiderDownEvent({
    required this.tipAtMs,
    required this.atMs,
    required this.lat,
    required this.lng,
    required this.tiltDeg,
    required this.peakG,
    required this.speedBeforeKmh,
  });

  @override
  String toString() => 'RiderDownEvent(tip $tipAtMs, at $atMs, tilt ${tiltDeg.toStringAsFixed(0)}, peak ${peakG.toStringAsFixed(1)} g)';
}

class _Down {
  final int tipAt;
  final double tilt;
  final double peakG;
  final double speedBefore;
  final double lat;
  final double lng;
  int still = 0;
  int body = 0;

  _Down({required this.tipAt, required this.tilt, required this.peakG, required this.speedBefore, required this.lat, required this.lng});
}

class RiderDownDetector {
  RiderDownDetector({
    this.slowKmh = 8,
    this.fixFreshFor = const Duration(seconds: 30),
    this.tipWindow = const Duration(seconds: 2),
    this.tipDeltaDeg = 60,
    this.tipMinTiltDeg = 60,
    this.thudG = 1.5,
    this.thudDynG = 0.6,
    this.walkStdG = 0.15,
    this.walkBuckets = 3,
    this.settle = const Duration(seconds: 3),
    this.stillFor = const Duration(seconds: 60),
    this.stillStdG = 0.06,
    this.stillGyroRadS = 0.15,
    this.moveStdG = 0.12,
    this.bodyGyroRadS = 0.3,
    this.bodyBuckets = 10,
    this.downMinTiltDeg = 35,
    this.maxMoveM = 30,
    this.giveUpAfter = const Duration(seconds: 120),
    this.cooldown = const Duration(minutes: 5),
  });

  final double slowKmh;
  final Duration fixFreshFor;
  final Duration tipWindow;
  final double tipDeltaDeg;
  final double tipMinTiltDeg;
  final double thudG;
  final double thudDynG;
  final double walkStdG;
  final int walkBuckets;
  final Duration settle;
  final Duration stillFor;
  final double stillStdG;
  final double stillGyroRadS;
  final double moveStdG;
  final double bodyGyroRadS;
  final int bodyBuckets;
  final double downMinTiltDeg;
  final double maxMoveM;
  final Duration giveUpAfter;
  final Duration cooldown;

  TrackPoint? _fix;
  final List<AccelBucket> _recent = [];
  _Down? _c;
  int _cooldownUntil = 0;

  /// A tip-over is being watched (the sensor must stay on for the minute of stillness).
  bool get evaluating => _c != null;

  /// Why the last candidate was dropped (tests and diagnostics).
  String? lastCancel;

  void onFix(TrackPoint p) {
    final last = _fix;
    if (last != null && p.ts < last.ts) return;
    _fix = p;
    final c = _c;
    if (c == null || p.ts < c.tipAt) return;
    if (p.speedKmh >= slowKmh) {
      _cancel('riding');
      return;
    }
    if (!(c.lat == 0 && c.lng == 0) && !(p.lat == 0 && p.lng == 0)) {
      if (GeoMath.haversine(c.lat, c.lng, p.lat, p.lng) > maxMoveM) _cancel('moved');
    }
  }

  RiderDownEvent? onAccel(AccelBucket b) {
    if (_recent.isNotEmpty && b.tMs < _recent.last.tMs) return null;
    final c = _c;
    RiderDownEvent? out;
    if (c == null) {
      if (b.tMs >= _cooldownUntil) _maybeStart(b);
    } else {
      out = _watch(c, b);
    }
    _recent.add(b);
    while (_recent.isNotEmpty && _recent.first.tMs < b.tMs - 6000) {
      _recent.removeAt(0);
    }
    return out;
  }

  bool _slow(int tMs) {
    final f = _fix;
    if (f == null) return false; // unknown speed (no fix yet, or GPS lost in a tunnel): never
    if (tMs - f.ts > fixFreshFor.inMilliseconds) return false;
    return f.speedKmh < slowKmh;
  }

  void _maybeStart(AccelBucket b) {
    if (b.sensorConfidence < 0.5) return;
    if (!_slow(b.tMs)) return;
    if (b.tiltDeg < tipMinTiltDeg) return;
    final from = b.tMs - tipWindow.inMilliseconds;
    var minTilt = double.infinity;
    var thud = b.peakG >= thudG || b.peakDynG >= thudDynG;
    for (final r in _recent) {
      if (r.tMs < from) continue;
      minTilt = math.min(minTilt, r.tiltDeg);
      if (r.peakG >= thudG || r.peakDynG >= thudDynG) thud = true;
    }
    if (!minTilt.isFinite) return; // no earlier second to compare with
    if (b.tiltDeg - minTilt <= tipDeltaDeg) return;
    if (!thud) return;
    // Steps before the tip-over: the phone was carried, not on the bike.
    var walking = 0;
    for (final r in _recent) {
      if (r.tMs >= b.tMs - 5000 && r.tMs < from && r.stdG >= walkStdG && r.peakGyroRadS < 1.0) walking++;
    }
    if (walking >= walkBuckets) return;
    final f = _fix;
    var peak = b.peakG;
    for (final r in _recent) {
      if (r.tMs >= from) peak = math.max(peak, r.peakG);
    }
    _c = _Down(
      tipAt: b.tMs,
      tilt: b.tiltDeg,
      peakG: peak,
      speedBefore: f?.speedKmh ?? 0,
      lat: f?.lat ?? 0,
      lng: f?.lng ?? 0,
    );
    lastCancel = null;
  }

  RiderDownEvent? _watch(_Down c, AccelBucket b) {
    if (b.tMs < c.tipAt + settle.inMilliseconds) return null;
    if (b.tMs - c.tipAt > giveUpAfter.inMilliseconds) {
      _cancel('timeout');
      return null;
    }
    if (b.stdG > moveStdG) {
      _cancel('moving');
      return null;
    }
    if (b.tiltDeg < downMinTiltDeg) {
      _cancel('lifted');
      return null;
    }
    if (b.peakGyroRadS > bodyGyroRadS) {
      c.body++;
      if (c.body >= bodyBuckets) {
        _cancel('carried');
        return null;
      }
    }
    if (b.stdG <= stillStdG && b.peakGyroRadS <= stillGyroRadS) c.still++;
    final watched = b.tMs - (c.tipAt + settle.inMilliseconds);
    if (watched < stillFor.inMilliseconds) return null;
    final need = (stillFor.inSeconds * 0.75).ceil();
    if (c.still < need) return null; // keep watching until enough calm seconds or the give-up
    _c = null;
    _cooldownUntil = b.tMs + cooldown.inMilliseconds;
    return RiderDownEvent(
      tipAtMs: c.tipAt,
      atMs: b.tMs,
      lat: c.lat,
      lng: c.lng,
      tiltDeg: c.tilt,
      peakG: c.peakG,
      speedBeforeKmh: c.speedBefore,
    );
  }

  void _cancel(String why) {
    _c = null;
    lastCancel = why;
  }

  /// After an alarm (any answer), or while the crash detector owns the moment.
  void suppress(int nowMs, {Duration? forDuration}) {
    _c = null;
    _cooldownUntil = math.max(_cooldownUntil, nowMs + (forDuration ?? cooldown).inMilliseconds);
  }

  void reset() {
    _fix = null;
    _recent.clear();
    _c = null;
    _cooldownUntil = 0;
    lastCancel = null;
  }
}
