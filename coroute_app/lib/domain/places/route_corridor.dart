import 'dart:math' as math;

import '../tracking/geo_math.dart';

/// Grid cells used to fetch and cache map places. Must match gateway/src/poi_cells.js.
class PoiCells {
  PoiCells._();

  /// About 5.5 km of latitude.
  static const double cellDeg = 0.05;

  static String keyOf(double lat, double lng) => '${(lat / cellDeg).floor()}:${(lng / cellDeg).floor()}';

  /// (south, west, north, east) of a cell key, or null for a bad key.
  static ({double s, double w, double n, double e})? bounds(String key) {
    final parts = key.split(':');
    if (parts.length != 2) return null;
    final la = int.tryParse(parts[0]), lo = int.tryParse(parts[1]);
    if (la == null || lo == null) return null;
    return (s: la * cellDeg, w: lo * cellDeg, n: (la + 1) * cellDeg, e: (lo + 1) * cellDeg);
  }

  /// Every cell touching the box of [radiusM] around a point, nearest first.
  static List<String> around(double lat, double lng, double radiusM) =>
      _box(lat, lng, radiusM, radiusM, sortFrom: (lat, lng));

  /// Every cell touching a lat/lng box, nearest to (cLat, cLng) first.
  static List<String> inBox(double s, double w, double n, double e, {required double cLat, required double cLng}) {
    final out = <String>[];
    final la0 = (s / cellDeg).floor(), la1 = (n / cellDeg).floor();
    final lo0 = (w / cellDeg).floor(), lo1 = (e / cellDeg).floor();
    if ((la1 - la0 + 1) * (lo1 - lo0 + 1) > 400) return out; // far zoomed out: nothing
    for (var a = la0; a <= la1; a++) {
      for (var o = lo0; o <= lo1; o++) {
        out.add('$a:$o');
      }
    }
    double d(String k) {
      final b = bounds(k)!;
      return GeoMath.haversine(cLat, cLng, (b.s + b.n) / 2, (b.w + b.e) / 2);
    }

    out.sort((x, y) => d(x).compareTo(d(y)));
    return out;
  }

  static List<String> _box(double lat, double lng, double dyM, double dxM, {(double, double)? sortFrom}) {
    final dLat = dyM / 111320.0;
    final dLng = dxM / (111320.0 * math.max(0.01, math.cos(lat * math.pi / 180)));
    final (cLat, cLng) = sortFrom ?? (lat, lng);
    return inBox(lat - dLat, lng - dLng, lat + dLat, lng + dLng, cLat: cLat, cLng: cLng);
  }
}

/// A route line with cumulative distances (haversine metres), built once per route.
class RoutePath {
  RoutePath(List<(double, double)> line)
      : line = List.unmodifiable(line),
        cum = _cumulative(line);

  final List<(double, double)> line;
  final List<double> cum;

  double get lengthM => cum.isEmpty ? 0 : cum.last;
  bool get valid => line.length >= 2 && lengthM > 0;

  static List<double> _cumulative(List<(double, double)> line) {
    final out = List<double>.filled(line.length, 0);
    for (var i = 1; i < line.length; i++) {
      out[i] = out[i - 1] + GeoMath.haversine(line[i - 1].$1, line[i - 1].$2, line[i].$1, line[i].$2);
    }
    return out;
  }

  /// The point [m] metres along the line (clamped to its ends).
  (double, double) pointAt(double m) {
    if (line.isEmpty) return (0, 0);
    if (m <= 0 || line.length == 1) return line.first;
    if (m >= lengthM) return line.last;
    var lo = 0, hi = cum.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] <= m) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final seg = cum[hi] - cum[lo];
    final t = seg > 0 ? (m - cum[lo]) / seg : 0.0;
    final (aLat, aLng) = line[lo];
    final (bLat, bLng) = line[hi];
    return (aLat + (bLat - aLat) * t, aLng + (bLng - aLng) * t);
  }

  /// Nearest point of segments [from, to) to (lat, lng): distance along the route and off it.
  ({double along, double off, int seg})? project(double lat, double lng, {int from = 0, int? to}) {
    if (line.length < 2) return null;
    final end = math.min(to ?? line.length - 1, line.length - 1);
    final start = math.max(0, math.min(from, end - 1));
    final k = math.cos(lat * math.pi / 180);
    const r = GeoMath.earthRadiusM * math.pi / 180;
    double best = double.infinity, bestAlong = 0;
    var bestSeg = start;
    for (var i = start; i < end; i++) {
      final (aLat, aLng) = line[i];
      final (bLat, bLng) = line[i + 1];
      final ax = (aLng - lng) * r * k, ay = (aLat - lat) * r;
      final bx = (bLng - lng) * r * k, by = (bLat - lat) * r;
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      var t = len2 > 0 ? -(ax * dx + ay * dy) / len2 : 0.0;
      t = t.clamp(0.0, 1.0).toDouble();
      final cx = ax + t * dx, cy = ay + t * dy;
      final d = math.sqrt(cx * cx + cy * cy);
      if (d < best) {
        best = d;
        bestAlong = cum[i] + t * (cum[i + 1] - cum[i]);
        bestSeg = i;
      }
    }
    if (!best.isFinite) return null;
    return (along: bestAlong, off: best, seg: bestSeg);
  }
}

/// Follows the rider along a [RoutePath] cheaply: each fix searches a small
/// window after the last match, and only a fix far off that window scans the whole line.
class RouteCursor {
  RouteCursor(this.path);
  final RoutePath path;
  int _seg = 0;
  double progressM = 0;
  double offM = double.infinity;

  /// Updates and returns the progress along the route (metres).
  double locate(double lat, double lng) {
    var hit = path.project(lat, lng, from: _seg - 3, to: _seg + 80);
    if (hit == null || hit.off > 400) {
      final full = path.project(lat, lng);
      if (full != null && (hit == null || full.off < hit.off)) hit = full;
    }
    if (hit == null) return progressM;
    _seg = hit.seg;
    progressM = hit.along;
    offM = hit.off;
    return progressM;
  }
}

/// Which cells to fetch for a route: the corridor ([bufferM] each side) cut
/// into chunks of [chunkM] so the phone only asks for what is just ahead.
class RouteCorridor {
  RouteCorridor(this.path, {this.bufferM = 2000, this.chunkM = 20000, this.stepM = 1000});

  final RoutePath path;
  final double bufferM, chunkM, stepM;
  final Map<int, List<String>> _chunkCells = {};

  int get chunkCount => path.valid ? (path.lengthM / chunkM).ceil() : 0;
  int chunkOf(double m) => (math.max(0.0, math.min(m, path.lengthM)) / chunkM).floor().clamp(0, math.max(0, chunkCount - 1));

  /// Cells within [bufferM] of the route between [fromM] and [toM], in route order.
  List<String> cellsBetween(double fromM, double toM) {
    final seen = <String>{};
    final out = <String>[];
    if (!path.valid) return out;
    final end = math.min(toM, path.lengthM);
    for (var m = math.max(0.0, fromM);; m += stepM) {
      final at = math.min(m, end);
      final (lat, lng) = path.pointAt(at);
      for (final k in PoiCells.around(lat, lng, bufferM)) {
        if (seen.add(k)) out.add(k);
      }
      if (at >= end) break;
    }
    return out;
  }

  List<String> cellsOfChunk(int chunk) =>
      _chunkCells.putIfAbsent(chunk, () => cellsBetween(chunk * chunkM, (chunk + 1) * chunkM));

  /// The current chunk and [ahead] more, as one ordered, de-duplicated cell list.
  List<String> cellsAhead(double progressM, {int ahead = 2}) {
    final first = chunkOf(progressM);
    final last = math.min(chunkCount - 1, first + ahead);
    final seen = <String>{};
    final out = <String>[];
    for (var c = first; c <= last; c++) {
      for (final k in cellsOfChunk(c)) {
        if (seen.add(k)) out.add(k);
      }
    }
    return out;
  }

  /// How far past [progressM] the cells in [loaded] cover the route without a gap (metres).
  double coveredAheadM(double progressM, bool Function(String key) loaded) {
    var m = math.max(0.0, progressM);
    while (m < path.lengthM) {
      final c = chunkOf(m);
      if (!cellsOfChunk(c).every(loaded)) break;
      m = (c + 1) * chunkM;
    }
    return math.max(0.0, math.min(m, path.lengthM) - progressM);
  }
}
