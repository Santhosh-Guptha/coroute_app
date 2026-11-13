import '../places/place_poi.dart';
import '../places/poi_category.dart';
import '../ride/regroup_point.dart';
import '../tracking/geo_math.dart';
import 'hazard_ahead.dart';

/// One rider's along-route position at a moment (from GroupSpread.alongM on the lead / sweep phone).
class GapSample {
  const GapSample(this.tMs, this.gapM);
  final int tMs;
  final double gapM;
}

/// A rider predicted to be falling behind.
class FallingBehind {
  const FallingBehind({required this.userId, required this.name, required this.gapM, required this.rateMPerMin});
  final String userId;
  final String name;
  final double gapM;
  final double rateMPerMin;

  /// "Ravi is falling behind (1.2 km, growing)".
  String get text => '${name.trim().isEmpty ? 'A rider' : name.trim()} is falling behind (${_km(gapM)}, growing)';
  String get speech => '${name.trim().isEmpty ? 'A rider' : name.trim()} is falling behind.';

  static String _km(double m) {
    if (m < 1000) return '${(m / 50).round() * 50} m';
    final s = (m / 1000).toStringAsFixed(1);
    return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s} km';
  }
}

/// Features 12: predicts "falling behind" BEFORE the group stretch alert (pure; GroupSafetyService feeds it every
/// tick on the lead and sweep phones).
///
/// Gap = how far a rider is behind the median along-route position of the other riders (the group's centre on
/// the route). A rider is falling behind when, over the last [window] (2 min, at least [minSamples] samples), the
/// gap grows faster than [minRateMPerMin] (150 m/min, about 9 km/h slower than the group) by a least-squares
/// slope, the gap is at least [minGapM], and the rider is moving. Never for a rider stopped within
/// [regroupRadiusM] of a known regroup / meeting point. At most one alert per rider per [riderQuiet] (10 min) and
/// one for the whole group per [groupQuiet] (2 min). History is kept for [window] only.
class FallingBehindPredictor {
  FallingBehindPredictor({
    this.window = const Duration(minutes: 2),
    this.minSamples = 6,
    this.minRateMPerMin = 150,
    this.minGapM = 500,
    this.regroupRadiusM = 300,
    this.riderQuiet = const Duration(minutes: 10),
    this.groupQuiet = const Duration(minutes: 2),
  });

  final Duration window;
  final int minSamples;
  final double minRateMPerMin;
  final double minGapM;
  final double regroupRadiusM;
  final Duration riderQuiet;
  final Duration groupQuiet;

  final Map<String, List<GapSample>> _hist = {};
  final Map<String, int> _alertedAt = {};
  int? _groupAlertAt;

  void reset() {
    _hist.clear();
    _alertedAt.clear();
    _groupAlertAt = null;
  }

  /// Least-squares slope in metres per minute (null with too few samples or no time spread).
  static double? slopePerMin(List<GapSample> s) {
    if (s.length < 2) return null;
    final t0 = s.first.tMs;
    var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
    for (final p in s) {
      final x = (p.tMs - t0) / 60000.0;
      sx += x;
      sy += p.gapM;
      sxx += x * x;
      sxy += x * p.gapM;
    }
    final n = s.length.toDouble();
    final den = n * sxx - sx * sx;
    if (den.abs() < 1e-9) return null;
    return (n * sxy - sx * sy) / den;
  }

  static double _median(List<double> v) {
    final s = [...v]..sort();
    final m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
  }

  /// [along]: userId -> metres along the route (fresh riders on the route). [speedKmh], [names], [pos]:
  /// per rider. [regroupPoints]: known regroup / meeting points. Returns at most one rider to alert about.
  FallingBehind? update({
    required int nowMs,
    required Map<String, double> along,
    required Map<String, double> speedKmh,
    required Map<String, String> names,
    Map<String, (double, double)> pos = const {},
    List<(double, double)> regroupPoints = const [],
    String? selfId,
  }) {
    final cut = nowMs - window.inMilliseconds;
    _hist.removeWhere((id, _) => !along.containsKey(id));
    if (along.length < 2) return null;
    FallingBehind? pick;
    for (final e in along.entries) {
      final others = [for (final o in along.entries) if (o.key != e.key) o.value];
      final gap = _median(others) - e.value;
      final h = _hist.putIfAbsent(e.key, () => []);
      h.add(GapSample(nowMs, gap));
      while (h.isNotEmpty && h.first.tMs < cut) {
        h.removeAt(0);
      }
      if (e.key == selfId) continue;
      if (h.length < minSamples || nowMs - h.first.tMs < window.inMilliseconds * 0.8) continue;
      final rate = slopePerMin(h);
      if (rate == null || rate < minRateMPerMin || gap < minGapM) continue;
      final v = speedKmh[e.key] ?? 0;
      final p = pos[e.key];
      if (v < 5 && p != null && regroupPoints.any((r) => GeoMath.haversine(r.$1, r.$2, p.$1, p.$2) <= regroupRadiusM)) continue;
      final last = _alertedAt[e.key];
      if (last != null && nowMs - last < riderQuiet.inMilliseconds) continue;
      if (pick == null || gap > pick.gapM) pick = FallingBehind(userId: e.key, name: names[e.key] ?? '', gapM: gap, rateMPerMin: rate);
    }
    if (pick == null) return null;
    final g = _groupAlertAt;
    if (g != null && nowMs - g < groupQuiet.inMilliseconds) return null;
    _groupAlertAt = nowMs;
    _alertedAt[pick.userId] = nowMs;
    return pick;
  }
}

/// Feature 11: the next good regroup point ahead. Learned rider stops (where riders really stop, so there is
/// room) matched to a fuel / food place come first; then the existing places picker (fuel before food before rest
/// places, RegroupPointPicker). Same window rules: 2-10 km ahead of the last rider, never behind the lead.
class RegroupAdvisor {
  RegroupAdvisor._();

  static RegroupSuggestion? pick({
    required List<(double, double)> route,
    required Iterable<PlacePoi> places,
    Iterable<IntelCell> learnedStops = const [],
    required double lastAlongM,
    required double leadAlongM,
  }) {
    final learned = <PlacePoi>[
      for (final s in learnedStops)
        if (s.fuel || s.name.isNotEmpty)
          PlacePoi(id: 'stop:${s.id}', lat: s.lat, lng: s.lng, category: s.fuel ? PoiCategory.fuel : PoiCategory.food, tags: {if (s.name.isNotEmpty) 'name': s.name}),
    ];
    if (learned.isNotEmpty) {
      final hit = RegroupPointPicker.pick(route: route, places: learned, lastAlongM: lastAlongM, leadAlongM: leadAlongM);
      if (hit != null) return hit;
    }
    return RegroupPointPicker.pick(route: route, places: places, lastAlongM: lastAlongM, leadAlongM: leadAlongM);
  }
}
