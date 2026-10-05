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

  /// The points of the last [window] before [ts] (the tail drawn behind a marker).
  List<ReplayPoint> tail(int ts, {Duration window = const Duration(minutes: 10)}) {
    final from = ts - window.inMilliseconds;
    final out = points.where((p) => p.ts >= from && p.ts <= ts).toList();
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
