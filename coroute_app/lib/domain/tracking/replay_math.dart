import 'geo_math.dart';

/// One rider's recorded route for the replay view: points sorted by time.
class ReplayTrack {
  final String userId;
  final String name;
  final List<ReplayPoint> points;

  const ReplayTrack({required this.userId, required this.name, required this.points});

  int get firstTs => points.isEmpty ? 0 : points.first.ts;
  int get lastTs => points.isEmpty ? 0 : points.last.ts;

  /// Parses the gateway's compact form `[[ts, lat, lng, kmh], ...]`.
  factory ReplayTrack.fromJson(Map<String, dynamic> j) {
    final pts = <ReplayPoint>[];
    for (final raw in (j['points'] as List? ?? const [])) {
      if (raw is List && raw.length >= 3 && raw[0] is num && raw[1] is num && raw[2] is num) {
        pts.add(ReplayPoint((raw[0] as num).toInt(), (raw[1] as num).toDouble(), (raw[2] as num).toDouble(),
            raw.length > 3 && raw[3] is num ? (raw[3] as num).toDouble() : 0));
      }
    }
    pts.sort((a, b) => a.ts.compareTo(b.ts));
    return ReplayTrack(userId: j['userId']?.toString() ?? '', name: j['name']?.toString() ?? '', points: pts);
  }

  /// Where the rider was at [ts]: interpolated between the two nearest points.
  /// Null before the first point, after the last one, or across a gap longer
  /// than [maxGap] (signal lost: we do not invent a position).
  ReplayPoint? positionAt(int ts, {Duration maxGap = const Duration(minutes: 10)}) {
    if (points.isEmpty || ts < points.first.ts || ts > points.last.ts) return null;
    var lo = 0, hi = points.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (points[mid].ts <= ts) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = points[lo], b = points[hi];
    if (a.ts == ts || hi == lo) return a;
    if (b.ts - a.ts > maxGap.inMilliseconds) return null;
    final f = (ts - a.ts) / (b.ts - a.ts);
    return ReplayPoint(ts, a.lat + (b.lat - a.lat) * f, a.lng + (b.lng - a.lng) * f, a.kmh + (b.kmh - a.kmh) * f);
  }

  /// The route cut where the phone had no signal: a pause longer than
  /// [maxGap] with movement, or a jump faster than [maxKmh] (a bad fix).
  /// [pieces] are drawn as the ridden route, [gaps] as dotted links, so a
  /// dead zone is never drawn as if the rider rode a straight line.
  ({List<List<ReplayPoint>> pieces, List<(ReplayPoint, ReplayPoint)> gaps}) split({
    Duration maxGap = const Duration(minutes: 5),
    double minGapMoveM = 200,
    double maxKmh = 250,
  }) {
    final pieces = <List<ReplayPoint>>[];
    final gaps = <(ReplayPoint, ReplayPoint)>[];
    var cur = <ReplayPoint>[];
    for (final p in points) {
      if (cur.isNotEmpty) {
        final a = cur.last;
        final d = GeoMath.haversine(a.lat, a.lng, p.lat, p.lng);
        final dt = p.ts - a.ts;
        final kmh = dt > 0 ? d / (dt / 1000) * 3.6 : double.infinity;
        if ((dt > maxGap.inMilliseconds && d > minGapMoveM) || (d > minGapMoveM && kmh > maxKmh)) {
          if (cur.length >= 2) pieces.add(cur);
          gaps.add((a, p));
          cur = <ReplayPoint>[];
        }
      }
      cur.add(p);
    }
    if (cur.length >= 2) pieces.add(cur);
    return (pieces: pieces, gaps: gaps);
  }

  /// The points of the last [window] before [ts] (the tail drawn behind a marker).
  List<ReplayPoint> tail(int ts, {Duration window = const Duration(minutes: 10)}) {
    final from = ts - window.inMilliseconds;
    // Binary search for the first point in the window: this runs every frame of a replay.
    var lo = 0, hi = points.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (points[mid].ts < from) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final out = <ReplayPoint>[];
    for (var i = lo; i < points.length && points[i].ts <= ts; i++) {
      out.add(points[i]);
    }
    final here = positionAt(ts);
    if (here != null && (out.isEmpty || out.last.ts != ts)) out.add(here);
    return out;
  }
}

class ReplayPoint {
  final int ts;
  final double lat;
  final double lng;
  final double kmh;
  const ReplayPoint(this.ts, this.lat, this.lng, this.kmh);
}
