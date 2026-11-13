// Round 10 rescue beacon: a simple outdoor acoustic scene for the unit tests and the rescue lab
// (tool/rescue_lab/). NOT used by the app at run time (tree-shaken from the build).
//
// Calibration: 0 dBFS at the responder's microphone = 120 dB SPL (a typical phone MEMS mic's
// acoustic overload point). The mic's own noise is 30 dBA, about -90 dBFS broadband.
//
// Propagation from the victim's phone to the responder (per frequency, narrow-band):
//   SPL(d) = SPL(1 m) - 20 log10(d) - (air(f) + foliage(f)) * d
// air(f): atmospheric absorption at 20 C / 60 % RH (ISO 9613-1, rounded); foliage(f): excess
// attenuation through woodland (ISO 9613-2 annex A, extrapolated above 8 kHz). Ground effect,
// terrain and bodies are left out; real forests vary by +-10 dB, so the lab gives a range, not a
// promise.
import 'dart:math' as math;
import 'dart:typed_data';

class AcousticScene {
  AcousticScene({this.sampleRate = 48000, int seed = 1}) : _r = math.Random(seed);

  final int sampleRate;
  final math.Random _r;

  static const double fullScaleSpl = 120;

  static double dbToAmp(double db) => math.pow(10, db / 20).toDouble();

  /// RMS amplitude (full scale = 1) of a sound at [spl] dB SPL at the mic.
  static double splToRms(double spl) => dbToAmp(spl - fullScaleSpl);

  /// Atmospheric absorption (dB/m) at [f] Hz.
  static double airDbPerM(double f) {
    const pts = [(1000.0, 0.005), (2000.0, 0.009), (4000.0, 0.022), (8000.0, 0.076), (12500.0, 0.16), (16000.0, 0.26), (20000.0, 0.38)];
    return _interp(pts, f);
  }

  /// Woodland excess attenuation (dB/m) at [f] Hz (0 in open ground).
  static double foliageDbPerM(double f) {
    const pts = [(1000.0, 0.04), (2000.0, 0.05), (4000.0, 0.09), (8000.0, 0.12), (16000.0, 0.15), (20000.0, 0.16)];
    return _interp(pts, f);
  }

  static double _interp(List<(double, double)> pts, double f) {
    if (f <= pts.first.$1) return pts.first.$2;
    for (var i = 1; i < pts.length; i++) {
      if (f <= pts[i].$1) {
        final (f0, v0) = pts[i - 1];
        final (f1, v1) = pts[i];
        return v0 + (v1 - v0) * (f - f0) / (f1 - f0);
      }
    }
    return pts.last.$2;
  }

  /// dB SPL at [d] m of a source of [splAt1m] at [f] Hz.
  static double splAt(double splAt1m, double f, double d, {bool forest = true}) {
    final dd = math.max(1.0, d);
    return splAt1m - 20 * math.log(dd) / math.ln10 - (airDbPerM(f) + (forest ? foliageDbPerM(f) : 0)) * dd;
  }

  double _gauss() {
    final u1 = math.max(1e-12, _r.nextDouble()), u2 = _r.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  Float64List white(int n, double rms) {
    final out = Float64List(n);
    for (var i = 0; i < n; i++) {
      out[i] = rms * _gauss();
    }
    return out;
  }

  /// Pink noise (Paul Kellet's filter), normalised to [rms].
  Float64List pink(int n, double rms) {
    final out = Float64List(n);
    var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0;
    for (var i = 0; i < n; i++) {
      final w = _gauss();
      b0 = 0.99886 * b0 + w * 0.0555179;
      b1 = 0.99332 * b1 + w * 0.0750759;
      b2 = 0.96900 * b2 + w * 0.1538520;
      b3 = 0.86650 * b3 + w * 0.3104856;
      b4 = 0.55000 * b4 + w * 0.5329522;
      b5 = -0.7616 * b5 - w * 0.0168980;
      out[i] = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362;
      b6 = w * 0.115926;
    }
    return _norm(out, rms);
  }

  /// Brown (red) noise: wind rumble.
  Float64List brown(int n, double rms) {
    final out = Float64List(n);
    var v = 0.0;
    for (var i = 0; i < n; i++) {
      v = 0.995 * v + 0.05 * _gauss();
      out[i] = v;
    }
    return _norm(out, rms);
  }

  static Float64List _norm(Float64List x, double rms) {
    var s = 0.0;
    for (final v in x) {
      s += v * v;
    }
    final cur = math.sqrt(s / math.max(1, x.length));
    if (cur <= 0) return x;
    final g = rms / cur;
    for (var i = 0; i < x.length; i++) {
      x[i] *= g;
    }
    return x;
  }

  /// One-pole low-pass at [fc] Hz.
  Float64List lowPass(Float64List x, double fc) {
    final a = math.exp(-2 * math.pi * fc / sampleRate);
    var y = 0.0;
    final out = Float64List(x.length);
    for (var i = 0; i < x.length; i++) {
      y = (1 - a) * x[i] + a * y;
      out[i] = y;
    }
    return out;
  }

  /// A motorcycle idling / an engine near the responder: firing harmonics 30..400 Hz plus
  /// low-passed noise. [spl] dB SPL overall.
  Float64List engine(int n, double spl, {double rpm = 1500}) {
    final fire = rpm / 60.0; // a single / twin's firing frequency order
    final out = Float64List(n);
    final ph = List<double>.generate(12, (_) => _r.nextDouble() * 2 * math.pi);
    for (var i = 0; i < n; i++) {
      final t = i / sampleRate;
      var v = 0.0;
      for (var h = 1; h <= 12; h++) {
        v += math.sin(2 * math.pi * fire * h * t * (1 + 0.002 * math.sin(2 * math.pi * 3 * t)) + ph[h - 1]) / h;
      }
      out[i] = v;
    }
    final noise = lowPass(lowPass(white(n, 1), 800), 800); // about 12 dB per octave above 800 Hz
    for (var i = 0; i < n; i++) {
      out[i] += 0.6 * noise[i];
    }
    return _norm(out, splToRms(spl));
  }

  /// Wind on the mic: strong rumble with gusts, a little broadband hiss in the gusts.
  Float64List wind(int n, double spl) {
    final rumble = lowPass(brown(n, 1), 300);
    final hiss = white(n, 1);
    final out = Float64List(n);
    var g = 0.5;
    for (var i = 0; i < n; i++) {
      if (i % 2400 == 0) g = (0.85 * g + 0.15 * (0.2 + 1.6 * _r.nextDouble())).clamp(0.1, 2.0);
      out[i] = g * (rumble[i] + 0.01 * g * hiss[i]);
    }
    return _norm(out, splToRms(spl));
  }

  /// Tyres on a road / traffic far away: pink noise low-passed at 2 kHz.
  Float64List road(int n, double spl) => _norm(lowPass(pink(n, 1), 2000), splToRms(spl));

  /// Forest ambience: pink background, bird chirps (2..8 kHz FM sweeps), insect drones (4..9 kHz
  /// AM tones) and, when [katydid], katydid-like pulse trains at 14..19 kHz (a hard case).
  Float64List forest(int n, double spl, {bool katydid = true}) {
    final out = _norm(pink(n, 1), splToRms(spl - 6));
    final rms = splToRms(spl);
    // Birds: a chirp every ~0.7 s.
    var i = 0;
    while (i < n) {
      final len = (0.08 + 0.12 * _r.nextDouble()) * sampleRate;
      final f0 = 2000 + 5000 * _r.nextDouble(), f1 = f0 * (0.6 + 0.8 * _r.nextDouble());
      final amp = rms * (0.5 + 1.5 * _r.nextDouble());
      var ph = 0.0;
      for (var k = 0; k < len && i + k < n; k++) {
        final f = f0 + (f1 - f0) * k / len;
        ph += 2 * math.pi * f / sampleRate;
        out[i + k] += amp * math.sin(ph) * math.sin(math.pi * k / len);
      }
      i += ((0.3 + 0.8 * _r.nextDouble()) * sampleRate).round();
    }
    // Insects: two steady drones with slow AM.
    for (final f in [4300.0 + 2000 * _r.nextDouble(), 7000.0 + 2000 * _r.nextDouble()]) {
      final amp = rms * 0.4;
      for (var k = 0; k < n; k++) {
        final t = k / sampleRate;
        out[k] += amp * (0.6 + 0.4 * math.sin(2 * math.pi * 23 * t)) * math.sin(2 * math.pi * f * t);
      }
    }
    if (katydid) {
      // Pulse trains: 20 ms pulses at a fixed 14..19 kHz carrier, 10 per second, in bursts.
      final f = 14000 + 5000 * _r.nextDouble();
      final amp = rms * 0.8;
      for (var k = 0; k < n; k++) {
        final t = k / sampleRate;
        final burst = (t % 3.0) < 1.5;
        final pulse = (t % 0.1) < 0.02;
        if (burst && pulse) out[k] += amp * math.sin(2 * math.pi * f * t);
      }
    }
    return out;
  }

  /// Handling noise: clicks and thumps (the phone moved in a hand or pocket), broadband.
  Float64List handling(int n, double spl, {double perSecond = 3}) {
    final out = Float64List(n);
    final amp = splToRms(spl) * 4;
    final expected = (perSecond * n / sampleRate).round();
    for (var e = 0; e < expected; e++) {
      final at = _r.nextInt(n);
      final len = (0.002 + 0.02 * _r.nextDouble()) * sampleRate;
      for (var k = 0; k < len && at + k < n; k++) {
        out[at + k] += amp * _gauss() * math.exp(-5 * k / len);
      }
    }
    return out;
  }

  /// The mic's own noise (30 dBA).
  Float64List micNoise(int n) => white(n, splToRms(30));

  static void addInto(Float64List dst, Float64List src, [double gain = 1]) {
    final m = math.min(dst.length, src.length);
    for (var i = 0; i < m; i++) {
      dst[i] += gain * src[i];
    }
  }
}
