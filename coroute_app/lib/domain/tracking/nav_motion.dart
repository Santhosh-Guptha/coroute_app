import 'dart:math' as math;

/// Pure math behind the riding map's smooth camera and markers (no Flutter,
/// no plugins, so every piece is unit-tested in `test/nav_motion_test.dart`).
///
/// Conventions: bearings/headings are degrees clockwise from north in
/// [0, 360); map rotation follows flutter_map (a camera rotation of `-h`
/// puts heading `h` at the top of the screen); screen offsets are logical
/// pixels with +x right and +y down.
class NavMath {
  NavMath._();

  /// Web Mercator sphere (EPSG:3857), the CRS flutter_map uses by default.
  static const double earthRadiusM = 6378137.0;
  static const double _tileSize = 256.0;
  static const double _maxMercatorLat = 85.05112878;

  static double _rad(double d) => d * math.pi / 180.0;
  static double _deg(double r) => r * 180.0 / math.pi;

  /// [deg] in [0, 360). Non-finite input gives 0.
  static double normalizeDeg(double deg) {
    if (!deg.isFinite) return 0.0;
    final r = deg % 360.0; // Dart's % is non-negative for a positive divisor.
    return (r >= 360.0 || r < 0.0) ? 0.0 : r;
  }

  /// Signed shortest turn from [from] to [to], in (-180, 180]: 359 -> 1 is +2, never -358.
  static double shortestDelta(double from, double to) {
    var d = normalizeDeg(to - from);
    if (d > 180.0) d -= 360.0;
    return d;
  }

  /// Interpolates angles along the shortest arc; [t] 0 gives [from], 1 gives [to].
  static double lerpAngle(double from, double to, double t) =>
      normalizeDeg(from + shortestDelta(from, to) * t.clamp(0.0, 1.0).toDouble());

  /// Frame-rate independent exponential smoothing factor: the share of the
  /// remaining distance covered in [dtSec] with time constant [tauSec].
  static double smoothingAlpha(double dtSec, double tauSec) {
    if (!dtSec.isFinite || dtSec <= 0) return 0.0;
    if (!tauSec.isFinite || tauSec <= 0) return 1.0;
    return (1.0 - math.exp(-dtSec / tauSec)).clamp(0.0, 1.0).toDouble();
  }

  /// Great-circle distance in metres.
  static double distanceM(double lat1, double lng1, double lat2, double lng2) {
    final p1 = _rad(lat1), p2 = _rad(lat2);
    final dp = p2 - p1, dl = _rad(lng2 - lng1);
    final a = math.sin(dp / 2) * math.sin(dp / 2) + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
    return 2 * 6371008.8 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  /// Initial bearing from point 1 to point 2, [0, 360).
  static double bearingDeg(double lat1, double lng1, double lat2, double lng2) {
    final p1 = _rad(lat1), p2 = _rad(lat2);
    final dl = _rad(lng2 - lng1);
    final y = math.sin(dl) * math.cos(p2);
    final x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
    return normalizeDeg(_deg(math.atan2(y, x)));
  }

  /// Local east/north metres from point 1 to point 2 (equirectangular; fine below a few km).
  static (double east, double north) deltaMeters(double lat1, double lng1, double lat2, double lng2) {
    const mPerDeg = 111319.49;
    final cosLat = math.cos(_rad((lat1 + lat2) / 2));
    var dLng = lng2 - lng1;
    if (dLng > 180) dLng -= 360;
    if (dLng < -180) dLng += 360;
    return (dLng * mPerDeg * cosLat, (lat2 - lat1) * mPerDeg);
  }

  /// The point [east]/[north] metres from ([lat], [lng]).
  static (double lat, double lng) offsetMeters(double lat, double lng, double east, double north) {
    const mPerDeg = 111319.49;
    final cosLat = math.cos(_rad(lat)).abs().clamp(1e-6, 1.0).toDouble();
    final newLat = (lat + north / mPerDeg).clamp(-89.999, 89.999).toDouble();
    var newLng = lng + east / (mPerDeg * cosLat);
    if (newLng > 180) newLng -= 360;
    if (newLng < -180) newLng += 360;
    return (newLat, newLng);
  }

  /// Dead reckoning between fixes: where a rider at ([lat], [lng]) heading
  /// [headingDeg] at [speedMps] is [dtSec] later. Never more than [maxSec]
  /// ahead (a stale fix freezes instead of drifting away); negative or
  /// non-finite input does not move the point.
  static (double lat, double lng) extrapolate(double lat, double lng, double headingDeg, double speedMps, double dtSec,
      {double maxSec = 1.5}) {
    if (!speedMps.isFinite || speedMps <= 0 || !dtSec.isFinite || dtSec <= 0 || !headingDeg.isFinite) return (lat, lng);
    final d = speedMps * math.min(dtSec, maxSec);
    final h = _rad(headingDeg);
    return offsetMeters(lat, lng, d * math.sin(h), d * math.cos(h));
  }

  /// World pixel of ([lat], [lng]) at [zoom] (256 px tiles, Web Mercator).
  static (double x, double y) project(double lat, double lng, double zoom) {
    final scale = _tileSize * math.pow(2.0, zoom).toDouble();
    final clampedLat = lat.clamp(-_maxMercatorLat, _maxMercatorLat).toDouble();
    final s = math.sin(_rad(clampedLat));
    final x = (lng + 180.0) / 360.0 * scale;
    final y = (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * scale;
    return (x, y);
  }

  /// Inverse of [project].
  static (double lat, double lng) unproject(double x, double y, double zoom) {
    final scale = _tileSize * math.pow(2.0, zoom).toDouble();
    final lng = x / scale * 360.0 - 180.0;
    final n = math.pi - 2.0 * math.pi * y / scale;
    final lat = _deg(math.atan(0.5 * (math.exp(n) - math.exp(-n))));
    return (lat, lng);
  }

  /// The camera centre that shows ([lat], [lng]) at [screenOffsetX]/[screenOffsetY]
  /// pixels from the middle of the map (+y = lower on screen) when the map is
  /// rotated by [rotationDeg] (flutter_map's camera rotation) at [zoom].
  ///
  /// flutter_map draws `screen = R(rotation) * (world - centre)`, so the
  /// centre is `world - R(-rotation) * offset`.
  static (double lat, double lng) cameraCenterFor({
    required double lat,
    required double lng,
    required double zoom,
    required double rotationDeg,
    double screenOffsetX = 0,
    double screenOffsetY = 0,
  }) {
    if (screenOffsetX == 0 && screenOffsetY == 0) return (lat, lng);
    final (px, py) = project(lat, lng, zoom);
    final t = _rad(rotationDeg);
    final c = math.cos(t), s = math.sin(t);
    final wx = screenOffsetX * c + screenOffsetY * s;
    final wy = -screenOffsetX * s + screenOffsetY * c;
    return unproject(px - wx, py - wy, zoom);
  }

  /// Where ([lat], [lng]) lands on screen, relative to the map's middle, for a
  /// camera at ([centerLat], [centerLng]) (the inverse of [cameraCenterFor]).
  static (double x, double y) screenOffsetOf({
    required double lat,
    required double lng,
    required double centerLat,
    required double centerLng,
    required double zoom,
    required double rotationDeg,
  }) {
    final (px, py) = project(lat, lng, zoom);
    final (cx, cy) = project(centerLat, centerLng, zoom);
    final dx = px - cx, dy = py - cy;
    final t = _rad(rotationDeg);
    final c = math.cos(t), s = math.sin(t);
    return (dx * c - dy * s, dx * s + dy * c);
  }
}

/// One step of position smoothing between GPS fixes, in a local metric frame.
///
/// The displayed point chases the target (the newest fix extrapolated along
/// the heading) with exponential smoothing; while moving it never slides
/// backwards along the direction of travel (a fix that lands slightly behind
/// the prediction only corrects sideways until the rider catches up), and a
/// target too far away is taken at once instead of animating across town.
class PositionSmoother {
  PositionSmoother({this.tauSec = 0.28, this.snapDistanceM = 250.0, this.noBackwardsWithinM = 35.0});

  final double tauSec;
  final double snapDistanceM;
  final double noBackwardsWithinM;

  double? _lat;
  double? _lng;

  double? get lat => _lat;
  double? get lng => _lng;
  bool get hasValue => _lat != null && _lng != null;

  void snap(double lat, double lng) {
    _lat = lat;
    _lng = lng;
  }

  void reset() {
    _lat = null;
    _lng = null;
  }

  /// Advances by [dtSec] towards the target; returns the metres moved this step.
  double step({
    required double targetLat,
    required double targetLng,
    required double headingDeg,
    required double speedMps,
    required double dtSec,
  }) {
    final lat = _lat, lng = _lng;
    if (lat == null || lng == null) {
      snap(targetLat, targetLng);
      return 0.0;
    }
    final (east, north) = NavMath.deltaMeters(lat, lng, targetLat, targetLng);
    final dist = math.sqrt(east * east + north * north);
    if (dist > snapDistanceM) {
      snap(targetLat, targetLng);
      return dist;
    }
    if (dist < 0.02) {
      snap(targetLat, targetLng);
      return dist;
    }
    final a = NavMath.smoothingAlpha(dtSec, tauSec);
    var me = east * a, mn = north * a;
    if (speedMps > 1.0 && dist < noBackwardsWithinM && headingDeg.isFinite) {
      final h = headingDeg * math.pi / 180.0;
      final ux = math.sin(h), uy = math.cos(h);
      final along = me * ux + mn * uy;
      if (along < 0) {
        me -= along * ux;
        mn -= along * uy;
      }
    }
    final (nLat, nLng) = NavMath.offsetMeters(lat, lng, me, mn);
    _lat = nLat;
    _lng = nLng;
    return math.sqrt(me * me + mn * mn);
  }
}

/// Bearing source for the course-up map: GPS course while moving (above
/// [gpsAboveKmh]), the compass when slow or stopped (below [compassBelowKmh]);
/// the gap between the two is the hysteresis so the source never flickers.
/// Compass samples are low-pass filtered (with a small dead band) and every
/// blend goes the shortest way round.
class HeadingFusion {
  HeadingFusion({
    this.gpsAboveKmh = 9.0,
    this.compassBelowKmh = 6.5,
    this.courseBlend = 0.65,
    this.compassTauSec = 0.45,
    this.compassDeadbandDeg = 2.0,
  });

  final double gpsAboveKmh;
  final double compassBelowKmh;

  /// Share of a new GPS course sample taken at once (GPS course is already smooth).
  final double courseBlend;
  final double compassTauSec;
  final double compassDeadbandDeg;

  bool _useGps = false;
  double? _bearing;
  int? _lastCompassMs;

  bool get usingGps => _useGps;
  double? get bearing => _bearing;

  /// Feeds the current speed; returns true when the source switched.
  bool updateSpeed(double speedKmh) {
    if (!speedKmh.isFinite) return false;
    if (_useGps && speedKmh < compassBelowKmh) {
      _useGps = false;
      return true;
    }
    if (!_useGps && speedKmh > gpsAboveKmh) {
      _useGps = true;
      return true;
    }
    return false;
  }

  /// A GPS course sample; ignored while the compass is the source. Returns true when used.
  bool addCourse(double deg) {
    if (!_useGps || !deg.isFinite) return false;
    final b = _bearing;
    _bearing = b == null ? NavMath.normalizeDeg(deg) : NavMath.lerpAngle(b, deg, courseBlend);
    return true;
  }

  /// A compass sample at [nowMs]; ignored while GPS is the source. Returns true when the bearing changed.
  bool addCompass(double deg, int nowMs) {
    if (_useGps || !deg.isFinite) return false;
    final b = _bearing;
    final last = _lastCompassMs;
    _lastCompassMs = nowMs;
    if (b == null) {
      _bearing = NavMath.normalizeDeg(deg);
      return true;
    }
    if (NavMath.shortestDelta(b, deg).abs() < compassDeadbandDeg) return false;
    final dt = last == null ? 0.05 : ((nowMs - last) / 1000.0).clamp(0.0, 1.0).toDouble();
    _bearing = NavMath.lerpAngle(b, deg, NavMath.smoothingAlpha(dt, compassTauSec));
    return true;
  }

  /// Seeds the bearing (first fix) without filtering.
  void seed(double deg) {
    if (deg.isFinite) _bearing = NavMath.normalizeDeg(deg);
  }
}

/// Picks a level from ascending [thresholds] with hysteresis: it moves up
/// once the value is [marginUp] above a boundary for [upDwellMs], and down
/// once it is [marginDown] below for [downDwellMs]. Level `i` covers
/// `[thresholds[i - 1], thresholds[i])`.
class BandSelector {
  BandSelector({
    required this.thresholds,
    this.marginUp = 0.0,
    this.marginDown = 0.0,
    this.upDwellMs = 0,
    this.downDwellMs = 0,
    int initialLevel = 0,
  }) : _level = initialLevel.clamp(0, thresholds.length).toInt();

  final List<double> thresholds;
  final double marginUp;
  final double marginDown;
  final int upDwellMs;
  final int downDwellMs;

  int _level;
  int? _pending;
  int _pendingSinceMs = 0;

  int get level => _level;

  /// The level for [value] without hysteresis.
  int rawLevelFor(double value) {
    var i = 0;
    while (i < thresholds.length && value >= thresholds[i]) {
      i++;
    }
    return i;
  }

  /// Feeds [value] at [nowMs]; returns the (possibly unchanged) level.
  int update(double value, int nowMs) {
    if (!value.isFinite) return _level;
    var target = _level;
    while (target < thresholds.length && value >= thresholds[target] + marginUp) {
      target++;
    }
    if (target == _level) {
      while (target > 0 && value < thresholds[target - 1] - marginDown) {
        target--;
      }
    }
    if (target == _level) {
      _pending = null;
      return _level;
    }
    final pending = _pending;
    final sameDirection = pending != null && ((pending > _level) == (target > _level));
    if (!sameDirection) _pendingSinceMs = nowMs;
    _pending = target;
    final dwell = target > _level ? upDwellMs : downDwellMs;
    if (nowMs - _pendingSinceMs >= dwell) {
      _level = target;
      _pending = null;
    }
    return _level;
  }

  void reset(int level) {
    _level = level.clamp(0, thresholds.length).toInt();
    _pending = null;
  }
}

/// Camera zoom from speed: close in town, wider on the highway, with
/// hysteresis so a speed hovering near a boundary never pumps the zoom.
class SpeedZoomPolicy {
  SpeedZoomPolicy()
      : _bands = BandSelector(
          thresholds: const [15.0, 35.0, 60.0, 90.0],
          marginUp: 2.0,
          marginDown: 4.0,
          upDwellMs: 2500,
          downDwellMs: 4000,
        );

  /// Zoom per band: < 15, 15-35, 35-60, 60-90, > 90 km/h.
  static const List<double> zooms = [16.5, 16.2, 15.7, 15.2, 14.7];

  final BandSelector _bands;

  int get level => _bands.level;
  double get zoom => zooms[_bands.level];

  double update(double speedKmh, int nowMs) {
    _bands.update(speedKmh, nowMs);
    return zoom;
  }

  /// Jumps straight to the band for [speedKmh] (first fix, recenter).
  void seed(double speedKmh) => _bands.reset(_bands.rawLevelFor(speedKmh));
}

/// What [FixGate] decided about a fix.
enum FixVerdict {
  /// Good fix.
  accept,

  /// Accepted after a run of rejects: the old anchor was probably the bad one.
  reanchor,

  /// Not a usable coordinate.
  rejectInvalid,

  /// Horizontal accuracy worse than the limit.
  rejectInaccurate,

  /// Would need an impossible speed from the last good fix.
  rejectJump,
}

extension FixVerdictX on FixVerdict {
  bool get accepted => this == FixVerdict.accept || this == FixVerdict.reanchor;
}

/// Drops fixes that would throw the camera around: accuracy worse than
/// [maxAccuracyM], or a jump that needs more than [maxSpeedMps] (70 m/s is
/// 252 km/h) from the last good fix. After [reanchorAfterRejects] rejects in a
/// row, or [reanchorAfterMs] of rejects, the next plausible-coordinate fix is
/// taken anyway so a wrong anchor can never freeze the map.
class FixGate {
  FixGate({
    this.maxAccuracyM = 50.0,
    this.maxSpeedMps = 70.0,
    this.reanchorAfterRejects = 5,
    this.reanchorAfterMs = 10000,
  });

  final double maxAccuracyM;
  final double maxSpeedMps;
  final int reanchorAfterRejects;
  final int reanchorAfterMs;

  double? _lat;
  double? _lng;
  int? _ts;
  int _rejects = 0;
  int? _firstRejectMs;

  int get consecutiveRejects => _rejects;

  void reset() {
    _lat = null;
    _lng = null;
    _ts = null;
    _rejects = 0;
    _firstRejectMs = null;
  }

  /// [accuracyM] null or <= 0 means unknown (an estimated fix): only the jump test applies.
  FixVerdict check({required double lat, required double lng, required int tsMs, double? accuracyM}) {
    if (!lat.isFinite || !lng.isFinite || lat.abs() > 90 || lng.abs() > 180 || (lat == 0 && lng == 0)) {
      return FixVerdict.rejectInvalid;
    }
    final acc = (accuracyM != null && accuracyM.isFinite && accuracyM > 0) ? accuracyM : null;
    final pLat = _lat, pLng = _lng, pTs = _ts;
    FixVerdict verdict;
    if (acc != null && acc > maxAccuracyM) {
      verdict = FixVerdict.rejectInaccurate;
    } else if (pLat == null || pLng == null || pTs == null) {
      verdict = FixVerdict.accept;
    } else {
      final dtSec = math.max(tsMs - pTs, 250) / 1000.0;
      final dist = NavMath.distanceM(pLat, pLng, lat, lng);
      final slack = acc ?? 0.0;
      final implied = math.max(0.0, dist - slack) / dtSec;
      verdict = implied > maxSpeedMps ? FixVerdict.rejectJump : FixVerdict.accept;
    }
    if (verdict == FixVerdict.accept) {
      _take(lat, lng, tsMs);
      return FixVerdict.accept;
    }
    _rejects++;
    _firstRejectMs ??= tsMs;
    final longRun = _rejects >= reanchorAfterRejects || (tsMs - _firstRejectMs!) >= reanchorAfterMs;
    // An inaccurate fix is re-anchored only when it is not hopeless (within 3x the limit).
    final usable = verdict == FixVerdict.rejectJump || (acc != null && acc <= maxAccuracyM * 3);
    if (longRun && usable) {
      _take(lat, lng, tsMs);
      return FixVerdict.reanchor;
    }
    return verdict;
  }

  void _take(double lat, double lng, int tsMs) {
    _lat = lat;
    _lng = lng;
    _ts = tsMs;
    _rejects = 0;
    _firstRejectMs = null;
  }
}

/// Animated position + heading of one map marker between two reports:
/// linear in time from where it is drawn now to the new report, over about
/// the time between reports (so a steady 1 Hz rider glides continuously).
class MarkerTrack {
  MarkerTrack(double lat, double lng, double heading, int nowMs)
      : _fromLat = lat,
        _fromLng = lng,
        _toLat = lat,
        _toLng = lng,
        _fromHeading = NavMath.normalizeDeg(heading),
        _toHeading = NavMath.normalizeDeg(heading),
        _startMs = nowMs,
        _lastReportMs = nowMs;

  static const int minDurationMs = 250;
  static const int maxDurationMs = 2000;

  /// Farther than this, a report is a teleport (rejoin, mesh hop): snap.
  static const double snapDistanceM = 1500.0;

  double _fromLat, _fromLng, _toLat, _toLng, _fromHeading, _toHeading;
  int _startMs;
  int _durationMs = 0;
  int _lastReportMs;

  double get targetLat => _toLat;
  double get targetLng => _toLng;
  double get targetHeading => _toHeading;

  double _t(int nowMs) {
    if (_durationMs <= 0) return 1.0;
    return ((nowMs - _startMs) / _durationMs).clamp(0.0, 1.0).toDouble();
  }

  bool isAnimating(int nowMs) => _t(nowMs) < 1.0;

  (double lat, double lng, double heading) valueAt(int nowMs) {
    final t = _t(nowMs);
    return (
      _fromLat + (_toLat - _fromLat) * t,
      _fromLng + (_toLng - _fromLng) * t,
      NavMath.lerpAngle(_fromHeading, _toHeading, t),
    );
  }

  /// A new report. Returns true when it changed anything.
  bool retarget(double lat, double lng, double heading, int nowMs) {
    final h = NavMath.normalizeDeg(heading);
    if (lat == _toLat && lng == _toLng && (h - _toHeading).abs() < 0.01) return false;
    final (cLat, cLng, cHeading) = valueAt(nowMs);
    final interval = nowMs - _lastReportMs;
    _lastReportMs = nowMs;
    _fromLat = cLat;
    _fromLng = cLng;
    _fromHeading = cHeading;
    _toLat = lat;
    _toLng = lng;
    _toHeading = h;
    _startMs = nowMs;
    final jump = NavMath.distanceM(cLat, cLng, lat, lng);
    _durationMs = jump > snapDistanceM ? 0 : interval.clamp(minDurationMs, maxDurationMs).toInt();
    if (_durationMs == 0) {
      _fromLat = lat;
      _fromLng = lng;
      _fromHeading = h;
    }
    return true;
  }
}

/// Grid clustering of map markers at one zoom: points whose screen
/// positions share a [cellPx] cell become one group. [pinned] points (me,
/// the selected rider, the lead, anyone in trouble) always stay alone.
/// Returns groups of indices into the input; order is stable.
List<List<int>> clusterByGrid(List<({double lat, double lng, bool pinned})> points, {required double zoom, double cellPx = 64}) {
  final groups = <List<int>>[];
  final cells = <int, List<int>>{};
  final z = zoom.isFinite ? zoom : 10.0;
  for (var i = 0; i < points.length; i++) {
    final p = points[i];
    if (p.pinned) {
      groups.add([i]);
      continue;
    }
    final (x, y) = NavMath.project(p.lat, p.lng, z);
    final key = (x / cellPx).floor() * 1000003 + (y / cellPx).floor();
    final cell = cells[key];
    if (cell == null) {
      final g = [i];
      cells[key] = g;
      groups.add(g);
    } else {
      cell.add(i);
    }
  }
  return groups;
}
