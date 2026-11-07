import '../notify/relation.dart';
import '../tracking/geo_math.dart';

/// 3.55 risky-stretch heads-up: the grid and heading buckets shared with gateway/src/road_risk.js.
class RiskGrid {
  RiskGrid._();

  /// Degrees per cell (~200-220 m). Must match road_risk.js STEP.
  static const double step = 0.002;

  static ({String key, double lat, double lng}) cellOf(double lat, double lng) {
    final i = (lat / step).round(), j = (lng / step).round();
    return (key: '$i:$j', lat: _r5(i * step), lng: _r5(j * step));
  }

  /// 8 buckets of 45 degrees, 0 = north (337.5..22.5).
  static int headingBucket(double deg) {
    if (!deg.isFinite) return 0;
    final d = ((deg % 360) + 360) % 360;
    return ((d + 22.5) ~/ 45) % 8;
  }

  static double _r5(double v) => (v * 1e5).round() / 1e5;
}

/// One anonymous hard-brake event as sent: the cell centre and the heading bucket, nothing else.
class BrakeEvent {
  final double lat;
  final double lng;
  final int h;
  const BrakeEvent(this.lat, this.lng, this.h);

  Map<String, Object> toJson() => {'lat': lat, 'lng': lng, 'h': h};
}

/// Hard brakes waiting to be sent (pure). Rounded to the cell centre at once (the exact spot is
/// never kept), at most [perCell] per cell and direction and [cap] in all; sent every
/// [flushEvery] while non-empty, and at ride end.
class BrakeReportQueue {
  BrakeReportQueue({this.cap = 200, this.perCell = 3, this.flushEvery = const Duration(minutes: 10)});

  final int cap;
  final int perCell;
  final Duration flushEvery;

  final List<BrakeEvent> _events = [];
  final Map<String, int> _perKey = {};
  int? _firstAt;

  int get length => _events.length;
  bool get isEmpty => _events.isEmpty;

  /// Adds one hard brake at this position and heading. False when dropped (bad position, full).
  bool add({required double lat, required double lng, required double heading, required int nowMs}) {
    if (!lat.isFinite || !lng.isFinite || (lat == 0 && lng == 0) || lat.abs() > 85) return false;
    if (_events.length >= cap) return false;
    final c = RiskGrid.cellOf(lat, lng);
    final h = RiskGrid.headingBucket(heading);
    final key = '${c.key}:$h';
    final n = _perKey[key] ?? 0;
    if (n >= perCell) return false;
    _perKey[key] = n + 1;
    _events.add(BrakeEvent(c.lat, c.lng, h));
    _firstAt ??= nowMs;
    return true;
  }

  bool due(int nowMs) => _events.isNotEmpty && _firstAt != null && nowMs - _firstAt! >= flushEvery.inMilliseconds;

  /// The batch to send ({events: [...]}, no user id) and an empty queue.
  Map<String, Object> take() {
    final body = <String, Object>{'events': [for (final e in _events) e.toJson()]};
    _events.clear();
    _perKey.clear();
    _firstAt = null;
    return body;
  }

  /// Puts a batch that could not be sent back (kept within the cap).
  void restore(Map<String, Object> body, int nowMs) {
    final list = body['events'];
    if (list is! List) return;
    for (final e in list) {
      if (e is Map && _events.length < cap) {
        final lat = (e['lat'] as num?)?.toDouble(), lng = (e['lng'] as num?)?.toDouble(), h = (e['h'] as num?)?.toInt();
        if (lat != null && lng != null && h != null) _events.add(BrakeEvent(lat, lng, h));
      }
    }
    if (_events.isNotEmpty) _firstAt ??= nowMs;
  }
}

/// A confirmed cell from GET /road-risk/near (k >= 10 riders behind it).
class RiskCell {
  final String id;
  final double lat;
  final double lng;
  final int headingBucket;
  const RiskCell({required this.id, required this.lat, required this.lng, required this.headingBucket});

  static RiskCell? fromJson(Object? j) {
    if (j is! Map) return null;
    final lat = (j['lat'] as num?)?.toDouble(), lng = (j['lng'] as num?)?.toDouble();
    final hb = (j['headingBucket'] as num?)?.toInt();
    if (lat == null || lng == null || hb == null || hb < 0 || hb > 7) return null;
    return RiskCell(id: j['id']?.toString() ?? '$lat,$lng,$hb', lat: lat, lng: lng, headingBucket: hb);
  }

  double get headingDeg => headingBucket * 45.0;
}

/// Says the heads-up once per cell per ride when the cell is up to [aheadM] ahead in my direction
/// (pure). Along the route when both are on it; otherwise as the crow flies within [aheadM] and in
/// front of me. My heading must match the cell's direction within [headingTolDeg].
class RiskyStretchAnnouncer {
  RiskyStretchAnnouncer({this.aheadM = 500, this.headingTolDeg = 67.5, this.minSpeedKmh = 15});

  final double aheadM;
  final double headingTolDeg;
  final double minSpeedKmh;

  List<RiskCell> _cells = const [];
  final Set<String> _said = {};

  int get cellCount => _cells.length;

  void setCells(List<RiskCell> cells) => _cells = List.unmodifiable(cells);

  /// A new ride: every cell may be said again.
  void reset() {
    _cells = const [];
    _said.clear();
  }

  /// The cell to announce now, or null.
  RiskCell? update({
    required double lat,
    required double lng,
    required double headingDeg,
    required double speedKmh,
    List<(double, double)> route = const [],
  }) {
    if (_cells.isEmpty || speedKmh < minSpeedKmh || (lat == 0 && lng == 0)) return null;
    for (final c in _cells) {
      if (_said.contains(c.id)) continue;
      if (GeoMath.bearingDiff(headingDeg, c.headingDeg) > headingTolDeg) continue;
      final straight = GeoMath.haversine(lat, lng, c.lat, c.lng);
      if (straight > aheadM + 200) continue;
      final d = Relation.alongDelta(myLat: lat, myLng: lng, lat: c.lat, lng: c.lng, route: route);
      final ahead = d != null
          ? d >= 0 && d <= aheadM
          : straight <= aheadM && GeoMath.isForward(riderLat: lat, riderLng: lng, riderHeadingDeg: headingDeg, targetLat: c.lat, targetLng: c.lng, maxDiffDeg: 60);
      if (!ahead) continue;
      _said.add(c.id);
      return c;
    }
    return null;
  }

  static const String title = 'Many riders brake hard on this stretch';
  static const String spoken = 'Many riders brake hard on this stretch. Ride carefully.';
}
