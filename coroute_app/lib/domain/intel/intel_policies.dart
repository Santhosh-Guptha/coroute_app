import 'dart:math' as math;

import '../tracking/geo_math.dart';
import '../tracking/track_point.dart';
import 'sha256.dart';

/// "Help make roads safer": the one-time friendly prompt after the first completed ride (pure).
/// Never during a ride or an SOS / crash alarm, never when already answered or already on.
class ConsentPromptPolicy {
  ConsentPromptPolicy._();

  static const String title = 'Help make roads safer?';
  static const String body =
      'Share anonymous road and safety signals from your rides (hard braking, potholes, where riders stop). Never your route, name or phone number, and never the first and last 300 m of a ride. Everyone gets the hazard warnings either way.';

  static bool shouldPrompt({required int completedRides, required bool answered, required bool consentOn, required bool riding, required bool emergency}) =>
      completedRides >= 1 && !answered && !consentOn && !riding && !emergency;
}

/// The pre-ride tip at most once per day (local date).
class RideTipGate {
  RideTipGate._();
  static String dayKey(DateTime local) => '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  static bool allowed({required String? lastShownDay, required DateTime local}) => lastShownDay != dayKey(local);
}

/// A stretch of the planned route without known fuel.
class FuelGap {
  const FuelGap({required this.fromKm, required this.toKm, required this.after, required this.toEnd});
  final double fromKm, toKm;

  /// The last fuel station before the gap ('' = the start of the route).
  final String after;
  final bool toEnd;
  double get lengthKm => toKm - fromKm;

  /// "No known fuel for 110 km after HP Highway".
  String get text => 'No known fuel for ${lengthKm.round()} km after ${after.isEmpty ? 'the start' : after}';
}

/// Feature 9: no-fuel gaps on a planned route (pure; also offline). [fuel] are known fuel places (map places
/// corridor, learned stops tagged fuel); a place counts within [maxOffM] of the route.
class FuelGapFinder {
  FuelGapFinder._();

  static List<FuelGap> gaps(List<(double, double)> route, Iterable<({double lat, double lng, String name})> fuel, {double gapKm = 80, double maxOffM = 1500}) {
    if (route.length < 2) return const [];
    var total = 0.0;
    for (var i = 1; i < route.length; i++) {
      total += GeoMath.haversine(route[i - 1].$1, route[i - 1].$2, route[i].$1, route[i].$2);
    }
    final marks = <({double at, String name})>[];
    for (final f in fuel) {
      final a = GeoMath.alongRoute(f.lat, f.lng, route);
      if (a == null || a.offRoute > maxOffM) continue;
      marks.add((at: a.along, name: f.name));
    }
    marks.sort((a, b) => a.at.compareTo(b.at));
    final all = [(at: 0.0, name: ''), ...marks, (at: total, name: '')];
    final out = <FuelGap>[];
    for (var i = 1; i < all.length; i++) {
      final len = all[i].at - all[i - 1].at;
      if (len > gapKm * 1000) {
        out.add(FuelGap(fromKm: all[i - 1].at / 1000, toKm: all[i].at / 1000, after: i == 1 ? '' : (all[i - 1].name.isEmpty ? 'the last fuel station' : all[i - 1].name), toEnd: i == all.length - 1));
      }
    }
    return out;
  }
}

/// Feature 8 (own ride): kilometres of twisty road in this ride, from my own fixes (pure, on the phone only).
/// A kilometre is twisty when the heading changed by [twistyDegPerKm] (150 degrees, the server's ghat level) or
/// more in it, counted at riding speed (≥ 20 km/h, steps ≥ 15 m, turns under 120 degrees: no U-turns or jitter).
class TwistyMeter {
  static const double twistyDegPerKm = 150;
  TrackPoint? _last;
  double? _heading;
  double _chunkM = 0, _chunkTurn = 0;
  int twistyKm = 0;

  void reset() {
    _last = null;
    _heading = null;
    _chunkM = _chunkTurn = 0;
    twistyKm = 0;
  }

  void onFix(TrackPoint p) {
    final q = _last;
    if (q != null && p.ts <= q.ts) return;
    if (q == null) {
      _last = p;
      return;
    }
    final dt = (p.ts - q.ts) / 1000;
    final d = GeoMath.haversine(q.lat, q.lng, p.lat, p.lng);
    if (d < 15) return; // keep the anchor until the step is long enough for a heading
    _last = p;
    if (dt > 30 || d / dt > 70) {
      _heading = null; // a gap or a bad fix
      return;
    }
    final kmh = d / dt * 3.6;
    if (kmh < 20) {
      _heading = null;
      return;
    }
    final h = GeoMath.bearing(q.lat, q.lng, p.lat, p.lng);
    final prev = _heading;
    if (prev != null) {
      final t = GeoMath.bearingDiff(prev, h);
      if (t < 120) _chunkTurn += t;
    }
    _heading = h;
    _chunkM += d;
    while (_chunkM >= 1000) {
      final share = math.min(1.0, 1000 / _chunkM);
      if (_chunkTurn * share >= twistyDegPerKm) twistyKm++;
      _chunkTurn -= _chunkTurn * share;
      _chunkM -= 1000;
    }
  }
}

/// Feature 14 on the phone: approved crash brain parameters from GET /api/intel/crash-params. Anything unexpected
/// (wrong checksum, not approved, out of range, no version) means the defaults (scale 1.0). Never above 1.15
/// (the hard safety floor); the countdown and the severe-impact path are never touched by it.
class CrashBrainParams {
  CrashBrainParams._();
  static const double maxScale = 1.15;
  static const double minScale = 0.9;

  static String checksumOf(int version, String group, double? scale) =>
      Sha256.hexOf('$version|$group|${scale == null ? 'none' : scale.toStringAsFixed(4)}');

  /// The impact threshold multiplier to use (1.0 = the built-in rule).
  static double impactScaleOf(Object? j) {
    try {
      if (j is! Map || j['mode'] != 'approved') return 1.0;
      final v = j['version'], g = j['group'], p = j['params'], sum = j['checksum'];
      if (v is! num || v <= 0 || g is! String || p is! Map || sum is! String) return 1.0;
      final s = p['impactScale'];
      if (s is! num || !s.isFinite || s < minScale || s > maxScale) return 1.0;
      if (checksumOf(v.toInt(), g, s.toDouble()) != sum) return 1.0;
      return s.toDouble();
    } catch (_) {
      return 1.0;
    }
  }
}
