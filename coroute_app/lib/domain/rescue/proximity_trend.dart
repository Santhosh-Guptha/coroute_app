// Round 10 rescue finder: "hotter / colder" from a noisy strength reading (BLE RSSI in dBm, or the
// locator beacon's SNR in dB). Pure Dart.
//
// Signal strength from a phone lying in a forest jumps by 5..10 dB from one reading to the next
// (multipath, a body or a trunk in the way, the rescuer's own hand). So:
//  * readings are smoothed: median of the last 5 (drops single spikes), then an exponential
//    average;
//  * the trend compares the mean of the last few seconds with the mean of the seconds before,
//    with a dead band, so it only says "hotter" after a real rise.
// It measures proximity, never direction: the finder screen says "walk and watch the meter".

enum TrendDirection { unknown, hotter, colder, steady }

class ProximityTrend {
  ProximityTrend({
    this.recentMs = 6000,
    this.previousMs = 10000,
    this.thresholdDb = 2.5,
    this.minSamples = 2,
    this.alpha = 0.35,
  });

  /// The "now" window and the window before it (ms).
  final int recentMs;
  final int previousMs;

  /// The rise (or fall) needed before the trend says hotter (or colder).
  final double thresholdDb;
  final int minSamples;
  final double alpha;

  final List<(int, double)> _raw = [];
  final List<double> _last5 = [];
  final List<(int, double)> _smooth = [];
  double? _ema;
  int _lastAt = -1;

  /// The smoothed value (null before the first reading).
  double? get smoothed => _ema;

  /// When the last reading came (ms, -1 when none).
  int get lastAt => _lastAt;

  int get count => _raw.length;

  void add(int tMs, double value) {
    if (!value.isFinite) return;
    _raw.add((tMs, value));
    _last5.add(value);
    if (_last5.length > 5) _last5.removeAt(0);
    final sorted = [..._last5]..sort();
    final median = sorted[sorted.length ~/ 2];
    final e = _ema;
    _ema = e == null ? median : e + alpha * (median - e);
    _smooth.add((tMs, _ema!));
    _lastAt = tMs;
    final cutoff = tMs - recentMs - previousMs - 2000;
    _raw.removeWhere((x) => x.$1 < cutoff);
    _smooth.removeWhere((x) => x.$1 < cutoff);
  }

  void reset() {
    _raw.clear();
    _last5.clear();
    _smooth.clear();
    _ema = null;
    _lastAt = -1;
  }

  /// Hotter / colder / steady over the last [recentMs] versus the [previousMs] before; unknown
  /// with too few readings or when nothing came for longer than the recent window.
  TrendDirection at(int nowMs) {
    if (_lastAt < 0 || nowMs - _lastAt > recentMs) return TrendDirection.unknown;
    final recent = <double>[], before = <double>[];
    for (final (t, v) in _smooth) {
      if (t > nowMs - recentMs) {
        recent.add(v);
      } else if (t > nowMs - recentMs - previousMs) {
        before.add(v);
      }
    }
    if (recent.length < minSamples || before.length < minSamples) return TrendDirection.unknown;
    double mean(List<double> l) => l.reduce((a, b) => a + b) / l.length;
    final d = mean(recent) - mean(before);
    if (d >= thresholdDb) return TrendDirection.hotter;
    if (d <= -thresholdDb) return TrendDirection.colder;
    return TrendDirection.steady;
  }
}

/// Very rough distance bands from a smoothed BLE RSSI. Phone-to-phone RSSI at 1 m is about
/// -55..-65 dBm; bodies, pockets and foliage take 5..20 dB more. Only bands, never a number.
enum BleCloseness { veryClose, close, inRange, weak }

class BleRanges {
  BleRanges._();

  static BleCloseness of(double rssiDbm) {
    if (rssiDbm >= -70) return BleCloseness.veryClose; // about 0..10 m
    if (rssiDbm >= -82) return BleCloseness.close; // about 5..30 m
    if (rssiDbm >= -92) return BleCloseness.inRange; // about 20..80 m
    return BleCloseness.weak;
  }

  /// 0..1 for a meter: -100 dBm = 0, -55 dBm = 1.
  static double meter(double rssiDbm) => ((rssiDbm + 100) / 45).clamp(0.0, 1.0);
}
