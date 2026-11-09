// 3.55 sound awareness: small DSP building blocks shared by the siren / horn detector and the
// intercom voice cleanup. Pure Dart (dart:math + dart:typed_data only, no Flutter), so the same
// code runs in unit tests, in a plain `dart` script and on the phone.
//
// Everything works on mono float samples in [-1, 1].

import 'dart:math' as math;
import 'dart:typed_data';

/// Converts little-endian PCM16 bytes to floats in [-1, 1].
Float64List pcm16BytesToFloat(Uint8List bytes) {
  final n = bytes.length ~/ 2;
  final out = Float64List(n);
  final bd = ByteData.sublistView(bytes, 0, n * 2);
  for (var i = 0; i < n; i++) {
    out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

/// Converts Int16 samples to floats in [-1, 1].
Float64List int16ToFloat(Int16List pcm) {
  final out = Float64List(pcm.length);
  for (var i = 0; i < pcm.length; i++) {
    out[i] = pcm[i] / 32768.0;
  }
  return out;
}

/// Converts floats to little-endian PCM16 bytes (clamped, rounded).
Uint8List floatToPcm16Bytes(Float64List x) {
  final out = Uint8List(x.length * 2);
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < x.length; i++) {
    final v = (x[i] * 32768.0).round().clamp(-32768, 32767);
    bd.setInt16(i * 2, v, Endian.little);
  }
  return out;
}

/// RMS of [x].
double rmsOf(Float64List x) {
  if (x.isEmpty) return 0;
  var acc = 0.0;
  for (final v in x) {
    acc += v * v;
  }
  return math.sqrt(acc / x.length);
}

/// Power ratio to decibels (floor at -200 dB).
double powerDb(double p) => p <= 1e-20 ? -200.0 : 10.0 * math.log(p) / math.ln10;

/// Amplitude ratio to decibels.
double ampDb(double a) => a <= 1e-10 ? -200.0 : 20.0 * math.log(a) / math.ln10;

/// Decibels to an amplitude ratio.
double dbToAmp(double db) => math.pow(10.0, db / 20.0).toDouble();

/// Second-order IIR section (RBJ audio EQ cookbook), direct form I.
class Biquad {
  final double b0, b1, b2, a1, a2;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  Biquad._(this.b0, this.b1, this.b2, this.a1, this.a2);

  /// 2nd-order Butterworth-like high-pass at [f0] Hz (q = 0.707).
  factory Biquad.highPass(double sampleRate, double f0, {double q = 0.7071}) {
    final w0 = 2 * math.pi * f0 / sampleRate;
    final alpha = math.sin(w0) / (2 * q);
    final c = math.cos(w0);
    final a0 = 1 + alpha;
    return Biquad._((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0);
  }

  /// 2nd-order low-pass at [f0] Hz.
  factory Biquad.lowPass(double sampleRate, double f0, {double q = 0.7071}) {
    final w0 = 2 * math.pi * f0 / sampleRate;
    final alpha = math.sin(w0) / (2 * q);
    final c = math.cos(w0);
    final a0 = 1 + alpha;
    return Biquad._((1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0);
  }

  double process(double x) {
    final y = b0 * x + b1 * _x1 + b2 * _x2 - a1 * _y1 - a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }

  /// Filters [x] in place.
  void processInPlace(Float64List x) {
    for (var i = 0; i < x.length; i++) {
      x[i] = process(x[i]);
    }
  }

  void reset() {
    _x1 = _x2 = _y1 = _y2 = 0;
  }
}

/// In-place iterative radix-2 complex FFT of a fixed size (power of two).
class Fft {
  final int n;
  final Float64List _cos;
  final Float64List _sin;
  final Int32List _rev;

  Fft(this.n)
      : _cos = Float64List(n ~/ 2),
        _sin = Float64List(n ~/ 2),
        _rev = Int32List(n) {
    if (n < 2 || (n & (n - 1)) != 0) throw ArgumentError('FFT size must be a power of two');
    for (var i = 0; i < n ~/ 2; i++) {
      _cos[i] = math.cos(2 * math.pi * i / n);
      _sin[i] = math.sin(2 * math.pi * i / n);
    }
    var bits = 0;
    while ((1 << bits) < n) {
      bits++;
    }
    for (var i = 0; i < n; i++) {
      var r = 0;
      var v = i;
      for (var b = 0; b < bits; b++) {
        r = (r << 1) | (v & 1);
        v >>= 1;
      }
      _rev[i] = r;
    }
  }

  /// Forward transform (inverse when [inverse]; the inverse is NOT scaled by 1/n).
  void transform(Float64List re, Float64List im, {bool inverse = false}) {
    for (var i = 0; i < n; i++) {
      final j = _rev[i];
      if (j > i) {
        var t = re[i];
        re[i] = re[j];
        re[j] = t;
        t = im[i];
        im[i] = im[j];
        im[j] = t;
      }
    }
    final sign = inverse ? 1.0 : -1.0;
    for (var size = 2; size <= n; size <<= 1) {
      final half = size >> 1;
      final step = n ~/ size;
      for (var start = 0; start < n; start += size) {
        var k = 0;
        for (var j = start; j < start + half; j++) {
          final wr = _cos[k];
          final wi = sign * _sin[k];
          final l = j + half;
          final tr = re[l] * wr - im[l] * wi;
          final ti = re[l] * wi + im[l] * wr;
          re[l] = re[j] - tr;
          im[l] = im[j] - ti;
          re[j] += tr;
          im[j] += ti;
          k += step;
        }
      }
    }
  }
}

/// Periodic Hann window of length [n].
Float64List hannWindow(int n) {
  final w = Float64List(n);
  for (var i = 0; i < n; i++) {
    w[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / n);
  }
  return w;
}

/// Light look-back peak limiter for playback / transmit: keeps every sample below [ceiling]
/// with a fast attack (within the block) and a slow release (~[releaseMs]). No look-ahead,
/// so it adds no latency; the gain moves in a ramp across a block, so there are no clicks.
class PeakLimiter {
  final double ceiling;
  final double releasePerBlock;
  double _gain = 1.0;

  PeakLimiter({this.ceiling = 0.89, double releaseDbPerSecond = 12.0, double blockMs = 20.0})
      : releasePerBlock = dbToAmp(releaseDbPerSecond * blockMs / 1000.0);

  double get gain => _gain;

  /// Limits [x] in place.
  void process(Float64List x) {
    if (x.isEmpty) return;
    var peak = 0.0;
    for (final v in x) {
      final a = v.abs();
      if (a > peak) peak = a;
    }
    var target = math.min(1.0, _gain * releasePerBlock);
    if (peak * target > ceiling) target = ceiling / peak;
    final start = _gain;
    final n = x.length;
    for (var i = 0; i < n; i++) {
      // Attack: when the target is lower, reach it within the first quarter of the block.
      final g = target < start ? (i < n ~/ 4 ? start + (target - start) * (i + 1) / (n ~/ 4) : target) : start + (target - start) * (i + 1) / n;
      var v = x[i] * g;
      if (v > ceiling) v = ceiling;
      if (v < -ceiling) v = -ceiling;
      x[i] = v;
    }
    _gain = target;
  }

  /// Limits little-endian PCM16 bytes, returning a new buffer.
  Uint8List processPcm16(Uint8List bytes) {
    final x = pcm16BytesToFloat(bytes);
    process(x);
    return floatToPcm16Bytes(x);
  }

  void reset() => _gain = 1.0;
}

/// 2:1 decimator (16 kHz → 8 kHz) with a 31-tap windowed-sinc low-pass at ~3.4 kHz.
class Decimator2 {
  static final Float64List _taps = _design();
  final Float64List _hist = Float64List(31);
  int _pos = 0;
  bool _odd = false;

  static Float64List _design() {
    const n = 31;
    const fc = 3400.0 / 16000.0; // normalised cut-off (cycles / sample)
    final t = Float64List(n);
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final m = i - (n - 1) / 2;
      final sinc = m == 0 ? 2 * fc : math.sin(2 * math.pi * fc * m) / (math.pi * m);
      final w = 0.54 - 0.46 * math.cos(2 * math.pi * i / (n - 1));
      t[i] = sinc * w;
      sum += t[i];
    }
    for (var i = 0; i < n; i++) {
      t[i] /= sum;
    }
    return t;
  }

  /// Returns half as many samples as [x] (keeps phase across calls).
  Float64List process(Float64List x) {
    final out = <double>[];
    for (final v in x) {
      _hist[_pos] = v;
      _pos = (_pos + 1) % 31;
      _odd = !_odd;
      if (_odd) continue;
      var acc = 0.0;
      var idx = _pos;
      for (var k = 0; k < 31; k++) {
        acc += _taps[k] * _hist[idx];
        idx = (idx + 1) % 31;
      }
      out.add(acc);
    }
    return Float64List.fromList(out);
  }
}
