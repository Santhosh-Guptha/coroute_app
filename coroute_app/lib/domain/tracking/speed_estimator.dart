import 'dart:collection';
import 'dart:math' as math;

/// One GPS fix as the speed estimator sees it (plugin-free, so it is testable in plain Dart).
class SpeedFix {
  /// Fix time, epoch ms (the platform's fix timestamp, not the arrival time).
  final int tMs;
  final double lat;
  final double lng;

  /// GNSS Doppler speed in m/s, or null when the platform did not report one
  /// (geolocator `hasSpeed == false`, or a negative / non-finite value).
  final double? dopplerMps;

  /// 1-sigma speed accuracy in m/s, or null when unknown.
  final double? speedAccuracyMps;

  /// Horizontal accuracy in metres, or null when unknown.
  final double? accuracyM;

  const SpeedFix({
    required this.tMs,
    required this.lat,
    required this.lng,
    this.dopplerMps,
    this.speedAccuracyMps,
    this.accuracyM,
  });
}

/// Where the last accepted speed measurement came from.
enum SpeedSource { none, doppler, derived }

/// The estimator's answer after a fix.
class SpeedEstimate {
  /// Speed to show and to judge the limit with, km/h (0 while stopped, with hysteresis).
  final double kmh;

  /// The filtered speed without the stop hysteresis, km/h.
  final double filteredKmh;

  /// The measurement this fix produced, km/h (null: none usable, e.g. a rejected outlier).
  final double? measuredKmh;
  final SpeedSource source;

  /// True when this fix's measurement was rejected as an outlier.
  final bool rejected;

  const SpeedEstimate({
    required this.kmh,
    required this.filteredKmh,
    required this.measuredKmh,
    required this.source,
    required this.rejected,
  });
}

/// Ride speed from GPS fixes (pure Dart; see `test/speed_estimator_test.dart` and
/// docs/features_355/speed_accuracy.md).
///
/// * Uses the GNSS Doppler speed whenever the platform reports one: it is instantaneous and
///   does not under-read on curves the way distance / time between fixes does.
/// * Falls back to distance / time over a short window (1-4 s) when a fix has no Doppler speed,
///   weighted by the fixes' horizontal accuracy; a window whose positions are too uncertain gives
///   no measurement (the last speed is held) instead of a made-up number.
/// * A 2-state (speed, acceleration) Kalman filter tuned for < 1 s lag: a constant-acceleration
///   ramp is tracked with no steady-state lag; while steady, 1 Hz Doppler noise is cut about 3x.
/// * Outliers: a measurement implying more than [maxAccelMps2] (1.2 g) of change since the last
///   estimate, or above [maxPlausibleMps] (300 km/h), is rejected; three rejections in a row that
///   agree with each other re-seed the filter (a genuine jump after a GPS outage). Large but
///   physically possible jumps are down-weighted, not rejected.
/// * Stop: shows 0 below [stopKmh] and only leaves 0 above [moveKmh] (no jitter at a light).
/// * Never clamps to a limit, never truncates: callers round for display.
class SpeedEstimator {
  SpeedEstimator();

  static const double maxAccelMps2 = 1.2 * 9.80665;
  static const double maxPlausibleMps = 300 / 3.6;
  static const double stopKmh = 2.5;
  static const double moveKmh = 4.0;

  /// Doppler speed with a reported accuracy worse than this (m/s) is not used.
  static const double maxDopplerAccuracyMps = 8.0;

  /// A fix older than this after the last one restarts the filter (ms).
  static const int resetGapMs = 10000;

  /// Fallback window: distance / time over the fixes of the last [fallbackWindowMs], spanning at
  /// least [fallbackMinSpanMs].
  static const int fallbackWindowMs = 4000;
  static const int fallbackMinSpanMs = 1000;

  /// Fallback measurements less certain than this (m/s, 1 sigma) are not used.
  static const double maxDerivedSigmaMps = 4.0;

  /// Assumed horizontal accuracy when the platform gives none (m).
  static const double defaultAccuracyM = 15.0;

  /// Jerk spectral density of the process model ((m/s^3)^2 * s), adaptive between [jerkSteady]
  /// (steady riding: strong smoothing, 1 Hz Doppler noise cut about 3x) and [jerkManeuver]
  /// (accelerating / braking: speed gain about 0.7, so the readout follows within a second). The
  /// switch is driven by the running mean of the signed innovations: noise averages out, a real
  /// change of speed does not.
  static const double jerkSteady = 0.0005;
  static const double jerkManeuver = 1.5;

  /// Maneuver threshold in noise sigmas of the innovation mean.
  static const double maneuverSigmas = 2.5;

  // Filter state.
  bool _init = false;
  double _v = 0; // m/s
  double _a = 0; // m/s^2
  double _p00 = 0, _p01 = 0, _p11 = 0;
  double _innovMean = 0; // running mean of signed innovations, m/s
  double _noiseVar = 0.09; // observed innovation variance while steady, (m/s)^2
  double _jerk = jerkManeuver;
  int _lastT = 0;
  bool _moving = false;
  SpeedSource _source = SpeedSource.none;

  // Outlier re-seed.
  final List<double> _rejects = [];
  int _firstRejectT = 0;

  final ListQueue<SpeedFix> _window = ListQueue<SpeedFix>();

  bool get hasEstimate => _init;
  int get lastFixMs => _lastT;
  SpeedSource get source => _source;

  /// The current display speed (km/h); 0 before the first fix.
  double get kmh => _moving ? math.max(0.0, _v * 3.6) : 0.0;

  /// Filtered speed without the stop hysteresis (km/h).
  double get filteredKmh => math.max(0.0, _v * 3.6);

  void reset() {
    _init = false;
    _v = 0;
    _a = 0;
    _p00 = _p01 = _p11 = 0;
    _innovMean = 0;
    _noiseVar = 0.09;
    _jerk = jerkManeuver;
    _lastT = 0;
    _moving = false;
    _source = SpeedSource.none;
    _rejects.clear();
    _window.clear();
  }

  SpeedEstimate update(SpeedFix f) {
    // Out of order or repeated (a cached fix after re-subscribing): nothing new.
    if (_init && f.tMs <= _lastT) return _estimate(null, SpeedSource.none, false);
    if (_init && f.tMs - _lastT > resetGapMs) {
      // Too old to carry over: start again (unknown until this or the next fix measures it).
      reset();
    }

    _window.addLast(f);
    while (_window.length > 1 && f.tMs - _window.first.tMs > fallbackWindowMs) {
      _window.removeFirst();
    }

    // 1. The measurement: Doppler when present, else distance / time over the window.
    double? z;
    double sigma = 0.5;
    var src = SpeedSource.none;
    final d = f.dopplerMps;
    final sAcc = f.speedAccuracyMps;
    final dopplerOk = d != null &&
        d.isFinite &&
        d >= 0 &&
        (sAcc == null || !sAcc.isFinite || sAcc <= 0 || sAcc <= maxDopplerAccuracyMps);
    // An exact 0 with no accuracy is also what a platform sends as a placeholder when it has no
    // speed (old Android plugin versions): believe the positions if they clearly say "moving".
    final placeholderZero = dopplerOk && d == 0 && (sAcc == null || !sAcc.isFinite || sAcc <= 0);
    final placeholderDerived = placeholderZero ? _derived(f) : null;
    if (placeholderDerived != null && placeholderDerived.$1 > 3.0) {
      z = placeholderDerived.$1;
      sigma = placeholderDerived.$2;
      src = SpeedSource.derived;
    } else if (dopplerOk) {
      z = d;
      // A reported accuracy sets the weight, within limits: some phones report a very
      // conservative figure, which must not turn the filter sluggish.
      sigma = (sAcc != null && sAcc.isFinite && sAcc > 0) ? sAcc.clamp(0.3, 1.5).toDouble() : 0.5;
      src = SpeedSource.doppler;
    } else {
      final derived = _derived(f);
      if (derived != null) {
        z = derived.$1;
        sigma = derived.$2;
        src = SpeedSource.derived;
      }
    }

    if (z == null) {
      // No usable measurement: keep the estimate, advance time.
      if (_init) {
        _predict((f.tMs - _lastT) / 1000.0);
        _a *= 0.5; // holding: do not keep extrapolating an old acceleration
        _lastT = f.tMs;
      }
      return _estimate(null, SpeedSource.none, false);
    }

    if (z > maxPlausibleMps) {
      if (_init) {
        _predict((f.tMs - _lastT) / 1000.0);
        _lastT = f.tMs;
      }
      return _estimate(z * 3.6, src, true);
    }

    final r = sigma * sigma;
    if (!_init) {
      _seed(z, r, f.tMs, src);
      return _estimate(z * 3.6, src, false);
    }

    final dt = (f.tMs - _lastT) / 1000.0;
    final vBefore = _v;
    // Maneuver detection from the last innovations (before this fix is used).
    // Mean of the last innovations (EMA 0.5, so ~1/sqrt(3) of the noise): beyond 2.5 of its own
    // sigmas it is a real change of speed, fully a maneuver one noise-sigma further.
    final noise = math.sqrt(_noiseVar);
    final m = ((_innovMean.abs() - maneuverSigmas * noise / math.sqrt(3)) / noise).clamp(0.0, 1.0).toDouble();
    _jerk = jerkSteady + (jerkManeuver - jerkSteady) * m;
    _predict(dt);
    _lastT = f.tMs;

    // 2. Physical gate: more change than a motorcycle can do (1.2 g) plus the noise.
    final allowed = maxAccelMps2 * dt + 3 * sigma + 1.0;
    if ((z - vBefore).abs() > allowed) {
      if (_rejects.isEmpty) _firstRejectT = f.tMs;
      _rejects.add(z);
      // Three rejections in a row that agree (within 3 m/s) over 2 s or more: the old estimate is
      // the wrong one (e.g. a long outage); start again from the new value. A sudden stop (faster
      // than any brake: a fall) is believed after two agreeing fixes 1 s apart, so the crash
      // detector and the readout see the stop without delay.
      final stopped = z < 1.5;
      final need = stopped ? 2 : 3;
      final span = stopped ? 1000 : 2000;
      if (_rejects.length >= need && f.tMs - _firstRejectT >= span) {
        final lo = _rejects.reduce(math.min), hi = _rejects.reduce(math.max);
        if (hi - lo <= 3.0) {
          _seed(z, r, f.tMs, src);
          return _estimate(z * 3.6, src, false);
        }
        _rejects.removeAt(0);
      }
      return _estimate(z * 3.6, src, true);
    }
    _rejects.clear();

    // 3. Robust update: a surprising but possible measurement counts less (Huber-style).
    final y = z - _v;
    _innovMean = 0.5 * _innovMean + 0.5 * y;
    if (_jerk <= jerkSteady * 2) {
      // Learn this phone's Doppler noise while steady (bounded: 0.1..2 m/s).
      _noiseVar = (0.95 * _noiseVar + 0.05 * y * y).clamp(0.01, 4.0).toDouble();
    }
    final s0 = _p00 + r;
    final gate = 3.0 * math.sqrt(s0);
    final rEff = y.abs() > gate ? r * math.pow(y.abs() / gate, 2).toDouble() : r;
    final s = _p00 + rEff;
    final k0 = _p00 / s;
    final k1 = _p01 / s;
    _v += k0 * y;
    _a += k1 * y;
    final p00 = (1 - k0) * _p00;
    final p01 = (1 - k0) * _p01;
    final p11 = _p11 - k1 * _p01;
    _p00 = p00;
    _p01 = p01;
    _p11 = p11;
    if (_v < 0) _v = 0;
    _a = _a.clamp(-maxAccelMps2, maxAccelMps2).toDouble();
    _source = src;
    return _estimate(z * 3.6, src, false);
  }

  void _seed(double z, double r, int tMs, SpeedSource src) {
    _init = true;
    _v = z;
    _a = 0;
    _p00 = r;
    _p01 = 0;
    _p11 = 4.0;
    _innovMean = 0;
    _jerk = jerkManeuver;
    _lastT = tMs;
    _source = src;
    _rejects.clear();
  }

  void _predict(double dt) {
    if (dt <= 0) return;
    _v = math.max(0.0, _v + _a * dt);
    final dt2 = dt * dt, dt3 = dt2 * dt;
    final p00 = _p00 + 2 * dt * _p01 + dt2 * _p11 + _jerk * dt3 / 3;
    final p01 = _p01 + dt * _p11 + _jerk * dt2 / 2;
    final p11 = _p11 + _jerk * dt;
    _p00 = p00;
    _p01 = p01;
    _p11 = p11;
  }

  /// Distance / time from the oldest fix in the window to [f], with its 1-sigma uncertainty.
  (double, double)? _derived(SpeedFix f) {
    SpeedFix? from;
    for (final w in _window) {
      if (identical(w, f)) break;
      if (f.tMs - w.tMs >= fallbackMinSpanMs) {
        from = w;
        break;
      }
    }
    if (from == null) return null;
    final dt = (f.tMs - from.tMs) / 1000.0;
    if (dt <= 0) return null;
    final dist = _haversine(from.lat, from.lng, f.lat, f.lng);
    final accA = _acc(from.accuracyM), accB = _acc(f.accuracyM);
    final sigma = math.max(0.5, math.sqrt(accA * accA + accB * accB) / dt);
    if (sigma > maxDerivedSigmaMps) return null;
    return (dist / dt, sigma);
  }

  static double _acc(double? a) => (a == null || !a.isFinite || a <= 0) ? defaultAccuracyM : a;

  SpeedEstimate _estimate(double? measuredKmh, SpeedSource src, bool rejected) {
    final v = math.max(0.0, _v * 3.6);
    if (_moving) {
      if (v < stopKmh) _moving = false;
    } else if (v >= moveKmh) {
      _moving = true;
    }
    return SpeedEstimate(
      kmh: _moving ? v : 0.0,
      filteredKmh: v,
      measuredKmh: measuredKmh,
      source: src,
      rejected: rejected,
    );
  }

  static double _haversine(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371008.8;
    const k = math.pi / 180.0;
    final dLat = (lat2 - lat1) * k;
    final dLng = (lng2 - lng1) * k;
    final h = math.pow(math.sin(dLat / 2), 2) +
        math.cos(lat1 * k) * math.cos(lat2 * k) * math.pow(math.sin(dLng / 2), 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(h.toDouble())));
  }
}
