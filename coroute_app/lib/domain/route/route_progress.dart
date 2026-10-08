import 'dart:math' as math;

import '../../core/constants/route_constants.dart';
import '../tracking/geo_math.dart';

/// Where a position falls on a route line.
class RouteMatch {
  /// The segment: from vertex [index] to vertex [index] + 1.
  final int index;

  /// Position on the segment, 0 at its start, 1 at its end.
  final double t;

  /// Metres from the start of the line to the matched point.
  final double alongM;

  /// Metres from the position to the matched point.
  final double offM;

  /// The matched point on the line.
  final double lat;
  final double lng;

  /// True when the position was close enough to count as on the line.
  final bool onLine;

  const RouteMatch({
    required this.index,
    required this.t,
    required this.alongM,
    required this.offM,
    required this.lat,
    required this.lng,
    this.onLine = true,
  });

  RouteMatch withOnLine(bool v) => RouteMatch(index: index, t: t, alongM: alongM, offM: offM, lat: lat, lng: lng, onLine: v);
}

/// Follows one rider along one route line, fix after fix.
///
/// Cheap: each fix searches only a window around the last matched point
/// ([RouteConstants.matchBackM] back, [RouteConstants.matchAheadM] ahead),
/// never the whole line. Safe on loops and out-and-back roads: the window
/// cannot slide back past the last match, and when the line passes the same
/// place twice the earlier pass wins until the rider has really passed it.
/// Only while the rider is not on the line is the whole line searched again,
/// at most once per [RouteConstants.reacquireEveryM] of movement.
///
/// Pure Dart: no timers, no Flutter.
class RouteProgress {
  RouteProgress(List<(double, double)> points)
      : points = List<(double, double)>.unmodifiable(points),
        _cum = _cumulative(points);

  /// The route line (lat, lng).
  final List<(double, double)> points;
  final List<double> _cum;

  RouteMatch? _anchor;
  RouteMatch? _last;
  int? _guessIndex;
  double? _globalLat;
  double? _globalLng;

  /// Segments looked at by the last [update] (for tests and tuning).
  int lastSearchCount = 0;

  /// True when the last [update] searched the whole line.
  bool lastSearchWasGlobal = false;

  bool get isUsable => points.length >= 2;

  /// Length of the line in metres.
  double get lengthM => _cum.isEmpty ? 0 : _cum.last;

  /// The last position that was on the line (where the remaining part starts).
  RouteMatch? get matched => _anchor;

  /// The result of the last [update], on the line or not.
  RouteMatch? get last => _last;

  /// Metres from the last matched point to the end of the line.
  double? get remainingM {
    final a = _anchor;
    if (a == null) return null;
    final left = lengthM - a.alongM;
    return left < 0 ? 0.0 : left;
  }

  /// Metres from the start of the line to vertex [i].
  double alongAtVertex(int i) => _cum[math.max(0, math.min(i, _cum.length - 1))];

  /// The part of the line still to ride: the matched point, then every
  /// vertex after it. The whole line before the first match.
  List<(double, double)> remainingLine() {
    if (!isUsable) return const [];
    final a = _anchor;
    if (a == null) return points;
    return [(a.lat, a.lng), ...points.sublist(a.index + 1)];
  }

  /// Forgets the matched position (the next fix searches the whole line).
  void reset() {
    _anchor = null;
    _last = null;
    _guessIndex = null;
    _globalLat = null;
    _globalLng = null;
  }

  /// Matches one fix. [acceptM] is how far from the line still counts as
  /// on it (the off-route limit); [accuracyM] widens what counts as "here"
  /// when choosing between two passes of the same road.
  ///
  /// Returns the nearest point found, with [RouteMatch.onLine] set when it
  /// was within [acceptM] (then it also becomes [matched]). Null for a line
  /// with fewer than two points.
  RouteMatch? update(double lat, double lng, {double acceptM = RouteConstants.offRouteM, double? accuracyM}) {
    lastSearchCount = 0;
    lastSearchWasGlobal = false;
    if (!isUsable) return null;
    final near = math.max(RouteConstants.matchNearM, accuracyM ?? 0.0);
    final anchor = _anchor;
    final guess = _guessIndex;
    RouteMatch? best;
    if (anchor != null) {
      best = _search(lat, lng, near,
          minAlong: anchor.alongM - RouteConstants.matchBackM,
          maxAlong: anchor.alongM + RouteConstants.matchAheadM,
          startIndex: anchor.index);
    } else if (guess != null) {
      final g = _cum[guess];
      best = _search(lat, lng, near,
          minAlong: g - RouteConstants.matchAheadM, maxAlong: g + RouteConstants.matchAheadM, startIndex: guess);
    }
    if (best == null || best.offM > acceptM) {
      final gLat = _globalLat;
      final gLng = _globalLng;
      final due = gLat == null || gLng == null || GeoMath.haversine(gLat, gLng, lat, lng) >= RouteConstants.reacquireEveryM;
      if (due) {
        _globalLat = lat;
        _globalLng = lng;
        lastSearchWasGlobal = true;
        final g = _search(lat, lng, near, preferAlong: anchor?.alongM);
        if (g != null && (best == null || g.offM < best.offM)) best = g;
      }
    }
    if (best == null) return null;
    final accepted = best.offM <= acceptM;
    final result = best.withOnLine(accepted);
    _last = result;
    if (accepted) {
      _anchor = result;
      _guessIndex = null;
      _globalLat = null;
      _globalLng = null;
    } else if (anchor == null) {
      _guessIndex = result.index;
    }
    return result;
  }

  /// Where a place falls along the line, looking only at or after
  /// [fromAlongM] (minus [RouteConstants.matchBackM]). For ordering a new
  /// stop among the remaining ones. Null for an unusable line.
  RouteMatch? locateAhead(double lat, double lng, {double fromAlongM = 0}) {
    if (!isUsable) return null;
    return _search(lat, lng, RouteConstants.matchNearM, minAlong: fromAlongM - RouteConstants.matchBackM);
  }

  /// Nearest point within the along range.
  ///
  /// The line may pass near the position more than once (a loop, an
  /// out-and-back road, a hairpin). Candidates are grouped into passes: a
  /// new pass starts whenever the line went farther than [_passSplitM] from
  /// the position in between. Each pass offers its nearest point; among
  /// passes about as near as the best one (no more than [near] farther than
  /// it, so one drifting fix on a hairpin or a divided road cannot pull the
  /// match onto the next pass of the road) the earliest along
  /// the line wins, or the one closest to [preferAlong] when it is given.
  RouteMatch? _search(
    double lat,
    double lng,
    double near, {
    double minAlong = double.negativeInfinity,
    double maxAlong = double.infinity,
    int? startIndex,
    double? preferAlong,
  }) {
    final n = points.length;
    if (n < 2) return null;
    const rad = math.pi / 180.0;
    const ky = GeoMath.earthRadiusM * rad;
    final kx = ky * math.cos(lat * rad);
    final split = math.max(_passSplitM, 2 * near);

    // Segment range to look at, in line order.
    var lo = 0, hi = n - 2;
    final s = startIndex;
    if (s != null) {
      final start = math.max(0, math.min(s, n - 2));
      lo = start;
      while (lo > 0 && _cum[lo] >= minAlong) {
        lo--;
      }
      hi = start;
      while (hi < n - 2 && _cum[hi + 1] <= maxAlong) {
        hi++;
      }
    }

    var bestOff = double.infinity;
    var pass = 0;
    var away = false;
    // Nearest candidate of each pass, in line order.
    final passBest = <RouteMatch>[];
    final passIds = <int>[];

    for (var i = lo; i <= hi; i++) {
      if (_cum[i + 1] < minAlong || _cum[i] > maxAlong) continue;
      lastSearchCount++;
      final (aLat, aLng) = points[i];
      final (bLat, bLng) = points[i + 1];
      final ax = (aLng - lng) * kx, ay = (aLat - lat) * ky;
      if (math.sqrt(ax * ax + ay * ay) > split) {
        if (!away) pass++;
        away = true;
      }
      final segLen = _cum[i + 1] - _cum[i];
      double tLo = 0, tHi = 1;
      if (segLen > 0) {
        tLo = ((minAlong - _cum[i]) / segLen).clamp(0.0, 1.0).toDouble();
        tHi = ((maxAlong - _cum[i]) / segLen).clamp(0.0, 1.0).toDouble();
      }
      if (tLo > tHi) continue;
      final dx = (bLng - aLng) * kx, dy = (bLat - aLat) * ky;
      final len2 = dx * dx + dy * dy;
      final raw = len2 > 0 ? (-ax * dx - ay * dy) / len2 : 0.0;
      // Behind the start of the window on this segment: not a real candidate
      // (after a U-turn the cut-off end of the old pass must not win).
      if (tLo > 0 && raw < tLo - 1e-9) continue;
      final t = raw.clamp(tLo, tHi).toDouble();
      final cx = ax + t * dx, cy = ay + t * dy;
      final off = math.sqrt(cx * cx + cy * cy);
      if (off <= split) away = false;
      if (off > math.max(near, bestOff + near)) continue;
      if (off < bestOff) bestOff = off;
      final c = RouteMatch(
        index: i,
        t: t,
        alongM: _cum[i] + t * segLen,
        offM: off,
        lat: aLat + t * (bLat - aLat),
        lng: aLng + t * (bLng - aLng),
      );
      if (passIds.isNotEmpty && passIds.last == pass) {
        // Same pass: keep the nearer point (the earlier one when about equal).
        if (off < passBest.last.offM - _sameOffM) passBest[passBest.length - 1] = c;
      } else {
        passIds.add(pass);
        passBest.add(c);
      }
    }
    if (passBest.isEmpty) return null;

    final limit = math.max(near, bestOff + near);
    RouteMatch? pick;
    for (final c in passBest) {
      if (c.offM > limit) continue;
      if (pick == null) {
        pick = c;
        continue;
      }
      final p = preferAlong;
      if (p != null && (c.alongM - p).abs() < (pick.alongM - p).abs()) pick = c;
    }
    return pick;
  }

  /// The line went at least this far away (metres) between two candidates: they are different passes.
  static const double _passSplitM = 100;

  /// Two candidates of one pass within this many metres are equally near; the earlier wins.
  static const double _sameOffM = 1;

  static List<double> _cumulative(List<(double, double)> pts) {
    final out = List<double>.filled(pts.length, 0);
    for (var i = 1; i < pts.length; i++) {
      out[i] = out[i - 1] + GeoMath.haversine(pts[i - 1].$1, pts[i - 1].$2, pts[i].$1, pts[i].$2);
    }
    return out;
  }
}
