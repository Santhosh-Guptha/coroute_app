import 'geo_math.dart';
import 'track_point.dart';

/// The rules that decide what of a recorded track is "the route the rider
/// really rode". The gateway uses the same numbers (gateway/src/tracks.js:
/// filterPoints, splitSegments, analyseTrack): keep them in step.
class TrackRules {
  TrackRules._();

  /// Fixes less accurate than this are not part of the route (accuracy 0 = not reported).
  static const double maxAccuracyM = 50;

  /// Faster than this over more than [minJumpM] is a teleport, not a ride.
  static const double maxKmh = 250;
  static const double minJumpM = 200;

  /// Runs this short that are only reachable by a teleport are bad fixes.
  static const int maxOutlierRun = 2;

  /// No fix for longer than this while moving more than [segmentGapMoveM]: a signal gap.
  static const int segmentGapMs = 2 * 60 * 1000;
  static const double segmentGapMoveM = 50;

  /// A jump longer than this at more than [segmentJumpKmh] always cuts the line.
  static const double segmentJumpM = 500;
  static const double segmentJumpKmh = 250;

  /// Gaps this long (and moving) are not riding time (the gateway's offline alert time).
  static const int timeGapMs = 5 * 60 * 1000;

  /// Stop rule (same as the live stop detector and the gateway).
  static const double stopRadiusM = 50;
  static const double stopExitM = 60;

  /// True when going from (lat1, lng1) at [ts1] to (lat2, lng2) at [ts2] must
  /// not be drawn as a ridden line: a signal gap while moving, or a jump.
  static bool breaksBetween(double lat1, double lng1, int ts1, double lat2, double lng2, int ts2) {
    final d = GeoMath.haversine(lat1, lng1, lat2, lng2);
    final dt = ts2 - ts1;
    final jump = d > segmentJumpM && (dt <= 0 || d / (dt / 1000) * 3.6 > segmentJumpKmh);
    return jump || (dt > segmentGapMs && d > segmentGapMoveM);
  }

  /// Only the impossible-jump half of [breaksBetween] (for simplified trails
  /// without gap marks, where long straight lines between points are normal).
  static bool jumpBetween(double lat1, double lng1, int ts1, double lat2, double lng2, int ts2) {
    final d = GeoMath.haversine(lat1, lng1, lat2, lng2);
    final dt = ts2 - ts1;
    return d > segmentJumpM && (dt <= 0 || d / (dt / 1000) * 3.6 > segmentJumpKmh);
  }
}

/// Cleans a recorded track the way the trip summary needs it.
class TrackCleaner {
  TrackCleaner._();

  static bool _impossible(TrackPoint a, TrackPoint b) {
    final d = GeoMath.haversine(a.lat, a.lng, b.lat, b.lng);
    if (d <= TrackRules.minJumpM) return false;
    final dt = (b.ts - a.ts) / 1000;
    return dt <= 0 || d / dt * 3.6 > TrackRules.maxKmh;
  }

  /// Valid, accurate fixes only, sorted by time, one per timestamp, without
  /// bad fixes. A bad fix is a short run that is only reachable from the rest
  /// by an impossible jump: a wild fix in the middle, a wrong first fix after a
  /// cold start, a stray last fix. One wrong first fix never throws the ride away.
  static List<TrackPoint> clean(Iterable<TrackPoint> points) {
    final list = <TrackPoint>[
      for (final p in points)
        if (p.lat.isFinite &&
            p.lng.isFinite &&
            p.lat.abs() <= 90 &&
            p.lng.abs() <= 180 &&
            !(p.lat == 0 && p.lng == 0) &&
            !(p.accuracyM > TrackRules.maxAccuracyM))
          p,
    ]..sort((a, b) => a.ts.compareTo(b.ts));
    final sorted = <TrackPoint>[];
    for (final p in list) {
      if (sorted.isEmpty || sorted.last.ts != p.ts) sorted.add(p);
    }
    var runs = <List<TrackPoint>>[];
    var cur = <TrackPoint>[];
    for (final p in sorted) {
      if (cur.isNotEmpty && _impossible(cur.last, p)) {
        runs.add(cur);
        cur = <TrackPoint>[];
      }
      cur.add(p);
    }
    if (cur.isNotEmpty) runs.add(cur);
    if (runs.length <= 1) return runs.isEmpty ? <TrackPoint>[] : runs.first;
    if (runs.any((r) => r.length > TrackRules.maxOutlierRun)) {
      runs = runs.where((r) => r.length > TrackRules.maxOutlierRun).toList();
    }
    return [for (final r in runs) ...r];
  }

  /// The stretches that were really recorded: a new one starts after a signal
  /// gap or a jump (see [TrackRules.breaksBetween]).
  static List<List<TrackPoint>> segments(List<TrackPoint> points) {
    final segs = <List<TrackPoint>>[];
    var cur = <TrackPoint>[];
    for (final p in points) {
      if (cur.isNotEmpty) {
        final a = cur.last;
        if (TrackRules.breaksBetween(a.lat, a.lng, a.ts, p.lat, p.lng, p.ts)) {
          segs.add(cur);
          cur = <TrackPoint>[];
        }
      }
      cur.add(p);
    }
    if (cur.isNotEmpty) segs.add(cur);
    return segs;
  }

  /// Douglas-Peucker on track points (indices kept in order).
  static List<TrackPoint> simplify(List<TrackPoint> pts, double toleranceM) {
    if (toleranceM <= 0 || pts.length <= 2) return List.of(pts);
    final line = [for (final p in pts) (p.lat, p.lng)];
    final kept = GeoMath.simplify(line, toleranceM: toleranceM);
    // GeoMath.simplify returns a subsequence of the input in order: walk both lists once.
    final out = <TrackPoint>[];
    var j = 0;
    for (var i = 0; i < pts.length && j < kept.length; i++) {
      if (pts[i].lat == kept[j].$1 && pts[i].lng == kept[j].$2) {
        out.add(pts[i]);
        j++;
      }
    }
    if (out.isEmpty || out.last.ts != pts.last.ts) out.add(pts.last);
    return out;
  }

  /// The cleaned track simplified segment by segment for the saved trip trail:
  /// at most [maxPoints] points (the tolerance doubles until it fits). Each
  /// entry says whether a signal gap comes before it.
  static List<({TrackPoint point, bool gapBefore})> trail(List<TrackPoint> cleaned, {double toleranceM = 20, int maxPoints = 4000}) {
    final segs = segments(cleaned);
    var tol = toleranceM;
    var out = <({TrackPoint point, bool gapBefore})>[];
    for (var round = 0; round < 12; round++) {
      out = [];
      for (var i = 0; i < segs.length; i++) {
        final pts = segs[i].length > 2 ? simplify(segs[i], tol) : segs[i];
        for (var j = 0; j < pts.length; j++) {
          out.add((point: pts[j], gapBefore: i > 0 && j == 0));
        }
      }
      if (out.length <= maxPoints) break;
      tol = tol > 0 ? tol * 2 : 5;
    }
    return out.length > maxPoints ? out.sublist(0, maxPoints) : out;
  }
}

/// A stop found in a finished track.
class TrackStop {
  final int startTs;
  final int endTs;
  const TrackStop(this.startTs, this.endTs);
  int get durationMs => endTs - startTs;
}

/// The trip summary numbers, computed on the phone from its own recorded
/// track (the same rules as the gateway's analyseTrack, so both agree). Sent
/// with the trip as `clientStats`: the gateway uses them when it never got the
/// track, and the phone shows them at once, also offline.
class TripStats {
  final double distanceM;
  final double recordedDistanceM;
  final double gapDistanceM;
  final int movingMs;
  final int restMs;
  final int gapMs;
  final double maxKmh;
  final double avgMovingKmh;
  final List<TrackStop> stops;
  final int firstFixAt;
  final int lastFixAt;
  final int points;
  final int pieces;

  const TripStats({
    required this.distanceM,
    required this.recordedDistanceM,
    required this.gapDistanceM,
    required this.movingMs,
    required this.restMs,
    required this.gapMs,
    required this.maxKmh,
    required this.avgMovingKmh,
    required this.stops,
    required this.firstFixAt,
    required this.lastFixAt,
    required this.points,
    required this.pieces,
  });

  static const TripStats empty = TripStats(
      distanceM: 0, recordedDistanceM: 0, gapDistanceM: 0, movingMs: 0, restMs: 0, gapMs: 0, maxKmh: 0, avgMovingKmh: 0, stops: [], firstFixAt: 0, lastFixAt: 0, points: 0, pieces: 0);

  bool get isEmpty => points < 2;
  int get longestStopMs => stops.fold(0, (m, s) => s.durationMs > m ? s.durationMs : m);

  /// Stops: the rider stays within [TrackRules.stopRadiusM] of a moving centre for at least [minStopMs].
  static List<TrackStop> detectStops(List<TrackPoint> points, {int minStopMs = 120000}) {
    final stops = <TrackStop>[];
    if (points.isEmpty) return stops;
    var first = points.first, last = points.first;
    var sumLat = first.lat, sumLng = first.lng;
    var n = 1;
    void close() {
      if (last.ts - first.ts >= minStopMs) stops.add(TrackStop(first.ts, last.ts));
    }

    for (final p in points.skip(1)) {
      final d = GeoMath.haversine(sumLat / n, sumLng / n, p.lat, p.lng);
      if (d <= TrackRules.stopRadiusM || (d <= TrackRules.stopExitM && last.ts - first.ts >= minStopMs)) {
        last = p;
        sumLat += p.lat;
        sumLng += p.lng;
        n++;
      } else {
        close();
        first = p;
        last = p;
        sumLat = p.lat;
        sumLng = p.lng;
        n = 1;
      }
    }
    close();
    return stops;
  }

  /// Computes the summary from raw recorded points (cleaned here first).
  static TripStats compute(Iterable<TrackPoint> raw, {Duration minStop = const Duration(minutes: 3)}) {
    final pts = TrackCleaner.clean(raw);
    if (pts.isEmpty) return empty;
    final stops = detectStops(pts, minStopMs: minStop.inMilliseconds);
    bool inStop(int ts) => stops.any((s) => ts > s.startTs && ts <= s.endTs);
    var distance = 0.0, maxKmh = 0.0, gapTotal = 0, gapDistance = 0.0;
    for (var i = 1; i < pts.length; i++) {
      final a = pts[i - 1], b = pts[i];
      final d = GeoMath.haversine(a.lat, a.lng, b.lat, b.lng);
      final dt = b.ts - a.ts;
      if (inStop(b.ts) && inStop(a.ts + 1)) continue; // jitter while parked
      if (TrackCleaner._impossible(a, b)) continue;
      if (dt > TrackRules.timeGapMs && d > TrackRules.stopExitM) {
        gapTotal += dt;
        gapDistance += d;
      }
      distance += d;
      final implied = dt > 0 ? d / (dt / 1000) * 3.6 : 0.0;
      // Trust the GPS speed only when the positions roughly agree with it.
      final v = b.speedKmh < implied * 1.5 + 15 ? b.speedKmh : implied * 1.5 + 15;
      if (v > maxKmh) maxKmh = v;
    }
    final segs = TrackCleaner.segments(pts);
    var recorded = 0.0;
    for (final seg in segs) {
      for (var i = 1; i < seg.length; i++) {
        final a = seg[i - 1], b = seg[i];
        if (inStop(b.ts) && inStop(a.ts + 1)) continue;
        recorded += GeoMath.haversine(a.lat, a.lng, b.lat, b.lng);
      }
    }
    final span = pts.last.ts - pts.first.ts;
    final rest = stops.fold<int>(0, (s, x) => s + x.durationMs);
    final moving = span - rest - gapTotal;
    final movingMs = moving > 0 ? moving : 0;
    final avg = movingMs > 0 ? ((distance - gapDistance).clamp(0, double.infinity) / 1000) / (movingMs / 3600000) : 0.0;
    return TripStats(
      distanceM: distance,
      recordedDistanceM: recorded,
      gapDistanceM: (distance - recorded).clamp(0, double.infinity).toDouble(),
      movingMs: movingMs,
      restMs: rest,
      gapMs: gapTotal,
      maxKmh: maxKmh.roundToDouble(),
      avgMovingKmh: double.parse(avg.toStringAsFixed(1)),
      stops: stops,
      firstFixAt: pts.first.ts,
      lastFixAt: pts.last.ts,
      points: pts.length,
      pieces: segs.length,
    );
  }

  /// The `clientStats` the gateway accepts with a trip (gateway/src/validate.js CLIENT_STATS).
  Map<String, num> toJson() => {
        'v': 1,
        'distanceM': distanceM.round(),
        'recordedDistanceM': recordedDistanceM.round(),
        'gapDistanceM': gapDistanceM.round(),
        'movingMs': movingMs,
        'restMs': restMs,
        'gapMs': gapMs,
        'maxKmh': maxKmh.round(),
        'avgMovingKmh': avgMovingKmh,
        'stops': stops.length,
        'longestStopMs': longestStopMs,
        'firstFixAt': firstFixAt,
        'lastFixAt': lastFixAt,
        'points': points,
        'pieces': pieces,
      };
}
