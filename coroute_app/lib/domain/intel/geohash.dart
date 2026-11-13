/// Geohash cell ids (public domain algorithm, own code). Must match gateway/src/intel/geohash.js.
///  precision 4 ≈ 39 × 20 km (read tiles), 6 ≈ 1.2 × 0.6 km (stretches), 7 ≈ 153 × 153 m (spots).
class Geohash {
  Geohash._();

  static const String _base32 = '0123456789bcdefghjkmnpqrstuvwxyz';

  static String? encode(double lat, double lng, [int precision = 7]) {
    if (!lat.isFinite || !lng.isFinite || lat.abs() > 90 || lng.abs() > 180) return null;
    var latLo = -90.0, latHi = 90.0, lngLo = -180.0, lngHi = 180.0;
    final out = StringBuffer();
    var bit = 0, ch = 0;
    var even = true;
    var n = 0;
    while (n < precision) {
      if (even) {
        final mid = (lngLo + lngHi) / 2;
        if (lng >= mid) {
          ch = (ch << 1) | 1;
          lngLo = mid;
        } else {
          ch <<= 1;
          lngHi = mid;
        }
      } else {
        final mid = (latLo + latHi) / 2;
        if (lat >= mid) {
          ch = (ch << 1) | 1;
          latLo = mid;
        } else {
          ch <<= 1;
          latHi = mid;
        }
      }
      even = !even;
      if (++bit == 5) {
        out.write(_base32[ch]);
        n++;
        bit = 0;
        ch = 0;
      }
    }
    return out.toString();
  }

  /// (south, west, north, east) of a cell, or null for an invalid id.
  static (double, double, double, double)? bbox(String hash) {
    var latLo = -90.0, latHi = 90.0, lngLo = -180.0, lngHi = 180.0;
    var even = true;
    for (final c in hash.split('')) {
      final v = _base32.indexOf(c);
      if (v < 0) return null;
      for (var b = 4; b >= 0; b--) {
        final on = (v >> b) & 1 == 1;
        if (even) {
          final mid = (lngLo + lngHi) / 2;
          if (on) {
            lngLo = mid;
          } else {
            lngHi = mid;
          }
        } else {
          final mid = (latLo + latHi) / 2;
          if (on) {
            latLo = mid;
          } else {
            latHi = mid;
          }
        }
        even = !even;
      }
    }
    return (latLo, lngLo, latHi, lngHi);
  }

  /// Read tiles (precision 4) along a line, at most [max] (route prefetch).
  static List<String> tilesAlong(List<(double, double)> line, {int max = 64}) {
    final out = <String>{};
    for (var i = 0; i < line.length; i++) {
      final (lat, lng) = line[i];
      final h = encode(lat, lng, 4);
      if (h != null) out.add(h);
      // Fill long segments (a straight 50 km leg may cross a tile between two points).
      if (i > 0) {
        final (pLat, pLng) = line[i - 1];
        final steps = ((lat - pLat).abs() / 0.08).ceil().clamp(0, 50) + ((lng - pLng).abs() / 0.15).ceil().clamp(0, 50);
        for (var k = 1; k < steps; k++) {
          final t = k / steps;
          final m = encode(pLat + (lat - pLat) * t, pLng + (lng - pLng) * t, 4);
          if (m != null) out.add(m);
        }
      }
      if (out.length >= max) break;
    }
    return out.take(max).toList();
  }
}
