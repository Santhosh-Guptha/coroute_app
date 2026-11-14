/// Round 11 ride HUD: "Ride so far" and "Distance by speed" for the ride sheet (pure Dart; test:
/// test/hud_ride_stats_accumulator_test.dart).
///
/// Fed with every GPS fix of the ride by SafetyService (the same fixes as crash detection and the
/// fuel count), saved with the ride (JSON in SharedPreferences, keyed by ride and rider like the fuel
/// count) so the numbers survive an app restart.
///
/// GPS rules (round 6, gateway tracks.js / TrackRules):
///  * fixes less accurate than [TrackRules.maxAccuracyM] are ignored;
///  * a jump faster than [TrackRules.maxKmh] over more than [TrackRules.minJumpM] is a teleport: ignored;
///  * a signal gap ([TrackRules.segmentGapMs] while moving) adds no distance or time;
///  * standing still (below [movingKmh]) adds no distance (parked jitter never grows the trip).
///
/// Peak speed rejects single-fix spikes: a speed counts toward the peak only when the fix before it
/// (at most [peakPairMs] earlier) was within [maxAccelKmhPerS] of it, and the peak is the lower of the
/// two speeds, so one wild reading never becomes the peak.
///
/// Distance is binned per 10 km/h ([binKmh]); the bands shown ("< 40", "40-60", ...) are made from the
/// bins at display time ([bands]), so the band edges can follow the vehicle profile ([SpeedBandProfile])
/// without losing data.
library;

import 'dart:math' as math;

import '../tracking/geo_math.dart';
import '../tracking/track_cleaner.dart';

/// One band of "Distance by speed".
class SpeedBand {
  const SpeedBand({required this.fromKmh, required this.toKmh, required this.distanceM, required this.timeMs});

  /// Lower edge (0 for the first band).
  final int fromKmh;

  /// Upper edge, null for the last ("100+").
  final int? toKmh;
  final double distanceM;
  final int timeMs;

  /// "< 40", "40-60", "100+" (km/h is shown once in the section title).
  String get label {
    final to = toKmh;
    if (fromKmh <= 0 && to != null) return '< $to';
    if (to == null) return '$fromKmh+';
    return '$fromKmh-$to';
  }

  /// Share of [totalM] (0..1).
  double shareOf(double totalM) => totalM <= 0 ? 0 : (distanceM / totalM).clamp(0.0, 1.0).toDouble();
}

/// Band edges by vehicle (km/h). Scooters and electric bikes ride slower, so finer low bands.
class SpeedBandProfile {
  const SpeedBandProfile._();

  static const List<int> scooter = [20, 40, 60, 80];
  static const List<int> motorcycle = [40, 60, 80, 100];
  static const List<int> touring = [40, 60, 80, 100, 120];

  /// [vehicleKind]: the BikeType wire name ('scooter', 'sport', ...) or a car kind; '' = motorcycle.
  static List<int> forVehicle(String vehicleKind) {
    final k = vehicleKind.trim().toLowerCase();
    if (k == 'scooter' || k == 'electric') return scooter;
    if (k == 'sport' || k == 'adventure' || k == 'car' || k == 'suv' || k == 'jeep' || k == 'van' || k.startsWith('car_')) return touring;
    return motorcycle;
  }
}

class RideStatsAccumulator {
  RideStatsAccumulator();

  /// Moving threshold (same as RideThresholds.movingSpeedKmh).
  static const double movingKmh = 5;

  /// Bin width of the speed histogram.
  static const int binKmh = 10;

  /// Bins 0-10, 10-20, ... 240-250 (anything faster lands in the last bin; faster than 250 is a teleport).
  static const int binCount = 25;

  /// A stretch below [movingKmh] at least this long counts as one stop.
  static const int stopAfterMs = 60 * 1000;

  /// Two fixes further apart than this are not a pair for the peak.
  static const int peakPairMs = 5000;

  /// Faster speed change than this between two fixes is a spike (about 0.45 g, more than a sport bike
  /// accelerates or brakes in normal riding; hard braking tops out near 1 g but then the peak is not
  /// being set).
  static const double maxAccelKmhPerS = 16;

  /// GPS allowance before a fix counts as over the limit (speedometers read high, GPS reads true).
  static const double overLimitAllowanceKmh = 2;

  /// One point of the speed trace per this many ms (the mini chart in the full sheet).
  static const int traceStepMs = 30 * 1000;

  /// The trace is halved (every second point kept, step doubled) when it grows past this.
  static const int traceMax = 240;

  double _distanceM = 0;
  int _movingMs = 0;
  int _stoppedMs = 0;
  double _peakKmh = 0;
  int _stops = 0;
  int _overLimitMs = 0;
  double _overLimitM = 0;
  final List<double> _binM = List<double>.filled(binCount, 0);
  final List<int> _binMs = List<int>.filled(binCount, 0);
  int _startedAt = 0;

  // Last accepted fix.
  int _lastTs = 0;
  double _lastLat = 0;
  double _lastLng = 0;
  double _lastKmh = 0;
  bool _hasLast = false;

  // Stop tracking.
  int _stillSince = 0;
  bool _stopCounted = false;
  bool _hasMoved = false;

  // Speed trace (average speed per step, km/h, rounded).
  final List<int> _trace = <int>[];
  int _traceStepMs = traceStepMs;
  int _traceBucketStart = -1;
  double _traceBucketM = 0;
  int _traceBucketMs = 0;

  /// Bumped on every accepted change (cheap change detection for listeners).
  int revision = 0;

  double get distanceM => _distanceM;
  int get movingMs => _movingMs;
  int get stoppedMs => _stoppedMs;
  double get peakKmh => _peakKmh;
  int get stops => _stops;
  int get overLimitMs => _overLimitMs;
  double get overLimitM => _overLimitM;
  int get startedAt => _startedAt;
  List<int> get speedTrace => List<int>.unmodifiable(_trace);
  int get traceStep => _traceStepMs;

  /// Average speed while moving (km/h), 0 before any moving time.
  double get avgMovingKmh => _movingMs <= 0 ? 0 : _distanceM / (_movingMs / 1000) * 3.6;

  /// Share of the distance ridden over the limit (0..1).
  double get overLimitShare => _distanceM <= 0 ? 0 : (_overLimitM / _distanceM).clamp(0.0, 1.0).toDouble();

  /// Distance per 10 km/h bin (read-only copy, for tests).
  List<double> get binDistancesM => List<double>.unmodifiable(_binM);

  /// The bands for [edgesKmh] (ascending, e.g. [40, 60, 80, 100] gives 5 bands). Edges are rounded down
  /// to the bin width.
  List<SpeedBand> bands(List<int> edgesKmh) {
    final edges = <int>[for (final e in edgesKmh) (e ~/ binKmh) * binKmh]..sort();
    final out = <SpeedBand>[];
    var from = 0;
    for (var i = 0; i <= edges.length; i++) {
      final to = i < edges.length ? edges[i] : null;
      var m = 0.0;
      var ms = 0;
      for (var b = 0; b < binCount; b++) {
        final lo = b * binKmh;
        if (lo >= from && (to == null || lo < to)) {
          m += _binM[b];
          ms += _binMs[b];
        }
      }
      out.add(SpeedBand(fromKmh: from, toKmh: to, distanceM: m, timeMs: ms));
      if (to != null) from = to;
    }
    return out;
  }

  /// Adds one fix. [limitKmh]: the effective limit at this fix (0 = none known). Returns true when
  /// the numbers changed.
  bool onFix({
    required int ts,
    required double lat,
    required double lng,
    double speedKmh = 0,
    double accuracyM = 0,
    int limitKmh = 0,
  }) {
    if (!lat.isFinite || !lng.isFinite || (lat == 0 && lng == 0)) return false;
    if (accuracyM > TrackRules.maxAccuracyM) return false;
    if (_startedAt == 0) _startedAt = ts;
    if (!_hasLast) {
      _accept(ts, lat, lng, _clean(speedKmh));
      _traceBucketStart = ts;
      return false;
    }
    final dt = ts - _lastTs;
    if (dt <= 0) return false; // out of order or duplicate
    final d = GeoMath.haversine(_lastLat, _lastLng, lat, lng);
    final derivedKmh = d / (dt / 1000) * 3.6;
    // Teleport: ignore the fix (the next good one is measured from the last good one).
    if (d > TrackRules.minJumpM && derivedKmh > TrackRules.maxKmh) return false;
    final reported = _clean(speedKmh);
    // A gap while moving: start again from here without distance or time.
    if (dt > TrackRules.segmentGapMs && d > TrackRules.segmentGapMoveM) {
      _accept(ts, lat, lng, reported);
      _flushTraceTo(ts);
      return false;
    }
    // The speed of this stretch: the GPS speed when it has one, else from the positions.
    final segKmh = reported > 0 ? (reported + (_lastKmh > 0 ? _lastKmh : reported)) / 2 : derivedKmh;
    // Moving: the GPS says so; or, when the fix has no speed, a move clearly larger than the
    // position noise (parked jitter of 10-20 m between two fixes is not riding).
    final moving = reported > 0
        ? reported >= movingKmh && segKmh >= movingKmh
        : derivedKmh >= movingKmh && d >= math.max(25.0, 2 * accuracyM);
    var changed = false;
    if (moving) {
      // Long silent stretches (over 30 s between fixes) count distance but not as moving time
      // beyond 30 s, so a weak-signal patch does not lower the average.
      final countMs = math.min(dt, 30 * 1000);
      _distanceM += d;
      _movingMs += countMs;
      final bin = math.min(binCount - 1, segKmh ~/ binKmh);
      _binM[bin] += d;
      _binMs[bin] += countMs;
      if (limitKmh > 0 && segKmh > limitKmh + overLimitAllowanceKmh) {
        _overLimitMs += countMs;
        _overLimitM += d;
      }
      _traceBucketM += d;
      _traceBucketMs += countMs;
      _hasMoved = true;
      _stillSince = 0;
      _stopCounted = false;
      changed = true;
    } else {
      _stoppedMs += math.min(dt, 5 * 60 * 1000);
      _traceBucketMs += math.min(dt, 30 * 1000);
      if (_stillSince == 0) _stillSince = _lastTs;
      if (_hasMoved && !_stopCounted && ts - _stillSince >= stopAfterMs) {
        _stops++;
        _stopCounted = true;
        changed = true;
      }
    }
    // Peak with spike rejection.
    if (reported > _peakKmh && dt <= peakPairMs && _lastKmh > 0) {
      final accel = (reported - _lastKmh).abs() / (dt / 1000);
      if (accel <= maxAccelKmhPerS) {
        final pair = math.min(reported, _lastKmh);
        if (pair > _peakKmh) {
          _peakKmh = pair;
          changed = true;
        }
      }
    }
    _accept(ts, lat, lng, reported);
    _flushTraceTo(ts);
    if (changed) revision++;
    return changed;
  }

  static double _clean(double kmh) => kmh.isFinite && kmh > 0 ? math.min(kmh, TrackRules.maxKmh) : 0;

  void _accept(int ts, double lat, double lng, double kmh) {
    _lastTs = ts;
    _lastLat = lat;
    _lastLng = lng;
    _lastKmh = kmh;
    _hasLast = true;
  }

  void _flushTraceTo(int ts) {
    if (_traceBucketStart < 0) _traceBucketStart = ts;
    while (ts - _traceBucketStart >= _traceStepMs) {
      final kmh = _traceBucketMs <= 0 ? 0 : (_traceBucketM / (_traceBucketMs / 1000) * 3.6).round();
      _trace.add(kmh);
      _traceBucketM = 0;
      _traceBucketMs = 0;
      _traceBucketStart += _traceStepMs;
      revision++;
      if (_trace.length > traceMax) _halveTrace();
      // A long gap: jump the bucket start instead of adding hundreds of zero points one by one.
      if (ts - _traceBucketStart > _traceStepMs * traceMax) {
        _traceBucketStart = ts;
      }
    }
  }

  void _halveTrace() {
    final kept = <int>[];
    for (var i = 0; i + 1 < _trace.length; i += 2) {
      kept.add(((_trace[i] + _trace[i + 1]) / 2).round());
    }
    if (_trace.length.isOdd) kept.add(_trace.last);
    _trace
      ..clear()
      ..addAll(kept);
    _traceStepMs *= 2;
  }

  // ---------------------------------------------------------------- persistence

  Map<String, dynamic> toJson() => {
        'v': 1,
        'd': _distanceM,
        'mm': _movingMs,
        'sm': _stoppedMs,
        'pk': _peakKmh,
        'st': _stops,
        'om': _overLimitMs,
        'od': _overLimitM,
        'bm': _binM,
        'bt': _binMs,
        'at': _startedAt,
        'tr': _trace,
        'ts': _traceStepMs,
        // The last fix, so a restart within a minute continues the line (a longer pause is a gap).
        'l': _hasLast ? [_lastTs, _lastLat, _lastLng, _lastKmh] : null,
      };

  static RideStatsAccumulator? fromJson(Map? j) {
    if (j == null || j['v'] != 1) return null;
    try {
      final a = RideStatsAccumulator();
      a._distanceM = (j['d'] as num).toDouble();
      a._movingMs = (j['mm'] as num).toInt();
      a._stoppedMs = (j['sm'] as num? ?? 0).toInt();
      a._peakKmh = (j['pk'] as num).toDouble();
      a._stops = (j['st'] as num).toInt();
      a._overLimitMs = (j['om'] as num? ?? 0).toInt();
      a._overLimitM = (j['od'] as num? ?? 0).toDouble();
      final bm = j['bm'] as List;
      final bt = j['bt'] as List;
      for (var i = 0; i < binCount && i < bm.length; i++) {
        a._binM[i] = (bm[i] as num).toDouble();
      }
      for (var i = 0; i < binCount && i < bt.length; i++) {
        a._binMs[i] = (bt[i] as num).toInt();
      }
      a._startedAt = (j['at'] as num? ?? 0).toInt();
      a._trace.addAll([for (final v in (j['tr'] as List? ?? const [])) (v as num).toInt()]);
      a._traceStepMs = (j['ts'] as num? ?? traceStepMs).toInt();
      final l = j['l'];
      if (l is List && l.length == 4) {
        a._accept((l[0] as num).toInt(), (l[1] as num).toDouble(), (l[2] as num).toDouble(), (l[3] as num).toDouble());
        a._traceBucketStart = a._lastTs;
      }
      a._hasMoved = a._distanceM > 0;
      if (!a._distanceM.isFinite || a._distanceM < 0) return null;
      return a;
    } catch (_) {
      return null;
    }
  }
}
