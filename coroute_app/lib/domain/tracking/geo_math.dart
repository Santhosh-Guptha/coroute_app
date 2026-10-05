import 'dart:math' as math;

/// Dependency-free geodesy helpers. Mirrors gateway/src/geo_math.js and is
/// tested against the same reference values.
class GeoMath {
  GeoMath._();

  static const double earthRadiusM = 6371008.8;

  static double _rad(double d) => d * math.pi / 180.0;

  /// Great-circle distance in metres.
  static double haversine(double lat1, double lng1, double lat2, double lng2) {
    final dLat = _rad(lat2 - lat1);
    final dLng = _rad(lng2 - lng1);
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * math.pow(math.sin(dLng / 2), 2);
    return 2 * earthRadiusM * math.asin(math.min(1.0, math.sqrt(a.toDouble())));
  }

  /// Distance in metres from the first vertex of [line] to the point on it
  /// closest to (lat, lng), plus how far the point is from the line.
  /// Returns null for a line with fewer than two vertices.
  static ({double along, double offRoute})? alongRoute(double lat, double lng, List<(double, double)> line) {
    if (line.length < 2) return null;
    final k = math.cos(_rad(lat));
    double x(double lo) => _rad(lo) * earthRadiusM * k;
    double y(double la) => _rad(la) * earthRadiusM;
    final px = x(lng), py = y(lat);
    var best = double.infinity, bestAlong = 0.0, acc = 0.0;
    for (var i = 0; i < line.length - 1; i++) {
      final (aLat, aLng) = line[i];
      final (bLat, bLng) = line[i + 1];
      final ax = x(aLng), ay = y(aLat), bx = x(bLng), by = y(bLat);
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      var t = len2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / len2 : 0.0;
      t = t.clamp(0.0, 1.0).toDouble();
      final cx = ax + t * dx, cy = ay + t * dy;
      final d = math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
      final seg = math.sqrt(len2);
      if (d < best) {
        best = d;
        bestAlong = acc + t * seg;
      }
      acc += seg;
    }
    return (along: bestAlong, offRoute: best);
  }

  /// Google encoded polyline, precision 1e5. [points] are (lat, lng) pairs.
  static String encodePolyline(Iterable<(double, double)> points) {
    final out = StringBuffer();
    var lastLat = 0, lastLng = 0;
    for (final (lat, lng) in points) {
      final la = (lat * 1e5).round();
      final ln = (lng * 1e5).round();
      _encodeSigned(la - lastLat, out);
      _encodeSigned(ln - lastLng, out);
      lastLat = la;
      lastLng = ln;
    }
    return out.toString();
  }

  static void _encodeSigned(int v, StringBuffer out) {
    var s = v < 0 ? ~(v << 1) : v << 1;
    while (s >= 0x20) {
      out.writeCharCode((0x20 | (s & 0x1f)) + 63);
      s >>= 5;
    }
    out.writeCharCode(s + 63);
  }

  /// Decodes an encoded polyline; returns null when the input is malformed.
  static List<(double, double)>? decodePolyline(String str) {
    final pts = <(double, double)>[];
    var i = 0, lat = 0, lng = 0;
    int? next() {
      var result = 0, shift = 0, b = 0;
      do {
        if (i >= str.length) return null;
        b = str.codeUnitAt(i++) - 63;
        if (b < 0 || b > 63) return null;
        result |= (b & 0x1f) << shift;
        shift += 5;
        if (shift > 30) return null;
      } while (b >= 0x20);
      return (result & 1) != 0 ? ~(result >> 1) : result >> 1;
    }

    while (i < str.length) {
      final dLat = next();
      if (dLat == null) return null;
      final dLng = next();
      if (dLng == null) return null;
      lat += dLat;
      lng += dLng;
      pts.add((lat / 1e5, lng / 1e5));
    }
    return pts;
  }
}
