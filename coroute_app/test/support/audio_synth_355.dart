// 3.55 sound awareness: synthetic test signals (16 kHz floats) for the siren detector and the
// intercom voice cleanup tests. Pure Dart, deterministic (seeded).

import 'dart:math' as math;
import 'dart:typed_data';

const int fs = 16000;

class Synth {
  final math.Random rnd;
  Synth([int seed = 7]) : rnd = math.Random(seed);

  double gauss() {
    final u1 = rnd.nextDouble().clamp(1e-12, 1.0), u2 = rnd.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  /// Siren tone with odd harmonics following [freqAt]; amplitude envelope [ampAt].
  Float64List siren(double sec, double Function(double t) freqAt, {double Function(double t)? ampAt, double amp = 0.1}) {
    final n = (sec * fs).round();
    final out = Float64List(n);
    var ph = 0.0;
    for (var i = 0; i < n; i++) {
      final t = i / fs;
      ph += 2 * math.pi * freqAt(t) / fs;
      final a = (ampAt?.call(t) ?? 1.0) * amp;
      out[i] = a * (math.sin(ph) + 0.33 * math.sin(3 * ph) + 0.2 * math.sin(5 * ph)) / 1.2;
    }
    return out;
  }

  Float64List wail(double sec, {double amp = 0.1, double period = 4.5, double lo = 500, double hi = 1800, double Function(double t)? ampAt}) =>
      siren(sec, (t) => (lo + hi) / 2 + (hi - lo) / 2 * math.sin(2 * math.pi * t / period - math.pi / 2), amp: amp, ampAt: ampAt);

  Float64List yelp(double sec, {double amp = 0.1, double rate = 5, double lo = 650, double hi = 1550}) => siren(sec, (t) {
        final p = (t * rate) % 1.0;
        final tri = p < 0.5 ? p * 2 : 2 - p * 2;
        return lo + (hi - lo) * tri;
      }, amp: amp);

  Float64List hiLo(double sec, {double amp = 0.1, double hi = 960, double lo = 770, double dwell = 0.5, double Function(double t)? ampAt, double Function(double t)? doppler}) =>
      siren(sec, (t) => (((t / dwell).floor() % 2 == 0) ? hi : lo) * (doppler?.call(t) ?? 1.0), amp: amp, ampAt: ampAt);

  /// Car horn (a sound that must NOT be taken for a siren): two fundamentals with harmonics;
  /// blasts = list of (start, dur).
  Float64List horn(double sec, List<(double, double)> blasts, {double amp = 0.1, double f1 = 420, double f2 = 500}) {
    final n = (sec * fs).round();
    final out = Float64List(n);
    for (var i = 0; i < n; i++) {
      final t = i / fs;
      var on = 0.0;
      for (final b in blasts) {
        if (t >= b.$1 && t < b.$1 + b.$2) {
          final a = math.min(1.0, (t - b.$1) / 0.01) * math.min(1.0, (b.$1 + b.$2 - t) / 0.01);
          on = math.max(on, a);
        }
      }
      if (on == 0) continue;
      var v = 0.0;
      for (var h = 1; h <= 8; h++) {
        final w = 1.0 / h;
        v += w * math.sin(2 * math.pi * f1 * h * t) + w * 0.8 * math.sin(2 * math.pi * f2 * h * t + 0.5);
      }
      out[i] = amp * on * v / 3.0;
    }
    return out;
  }

  /// Police "wail-yelp": [segment] seconds of wail, then of yelp, alternating.
  Float64List wailYelp(double sec, {double amp = 0.1, double segment = 3.0, double lo = 650, double hi = 1500, double rate = 5}) {
    double wailF(double t) => (lo + hi) / 2 + (hi - lo) / 2 * math.sin(2 * math.pi * t / 4.0 - math.pi / 2);
    double yelpF(double t) {
      final p = (t * rate) % 1.0;
      return lo + (hi - lo) * (p < 0.5 ? p * 2 : 2 - p * 2);
    }

    return siren(sec, (t) => ((t / segment).floor() % 2 == 0) ? wailF(t) : yelpF(t), amp: amp);
  }

  /// Ambulance (India) switching hi-lo and wail every [segment] seconds.
  Float64List hiLoWail(double sec, {double amp = 0.1, double segment = 4.0}) => siren(sec, (t) {
        if ((t / segment).floor() % 2 == 0) return ((t / 0.6).floor() % 2 == 0) ? 960.0 : 770.0;
        return 1100 + 450 * math.sin(2 * math.pi * t / 4.0 - math.pi / 2);
      }, amp: amp);

  /// Mechanical fire siren: a slow, low rise and fall (rotor spin-up / coast-down).
  Float64List mechanicalWail(double sec, {double amp = 0.1, double period = 9, double lo = 380, double hi = 1050}) =>
      siren(sec, (t) => lo + (hi - lo) * (0.5 - 0.5 * math.cos(2 * math.pi * t / period)), amp: amp);

  /// Musical truck "pressure horn": a tune of loud harmonic notes (irregular lengths, short gaps).
  Float64List melodyHorn(double sec, {double amp = 0.2, int seed = 1}) {
    final r = math.Random(seed);
    const scale = [392.0, 440.0, 494.0, 523.0, 587.0, 659.0, 784.0];
    final n = (sec * fs).round();
    final out = Float64List(n);
    var t0 = 0.0;
    var ph = 0.0;
    while (t0 < sec) {
      final f = scale[r.nextInt(scale.length)];
      final d = 0.15 + r.nextDouble() * 0.35;
      final gap = 0.02 + r.nextDouble() * 0.04;
      final i0 = (t0 * fs).round(), i1 = math.min(n, ((t0 + d) * fs).round());
      for (var i = i0; i < i1; i++) {
        final t = (i - i0) / fs;
        ph += 2 * math.pi * f / fs;
        final env = math.min(1.0, t / 0.01) * math.min(1.0, (d - t) / 0.01);
        var v = 0.0;
        for (var h = 1; h <= 6; h++) {
          v += math.sin(h * ph) / h;
        }
        out[i] = amp * env * v / 2;
      }
      t0 += d + gap;
    }
    return out;
  }

  /// Reversing beeper: a constant tone, [on] s on / [off] s off.
  Float64List beeper(double sec, {double amp = 0.08, double f = 1100, double on = 0.5, double off = 0.5}) =>
      siren(sec, (t) => f, amp: amp, ampAt: (t) => (t % (on + off)) < on ? 1.0 : 0.0);

  /// Ringtone / chime: struck notes that decay (marimba-like), a short tune repeated; with
  /// [twoNote] a regular "ding-dong" between two notes.
  Float64List ringtone(double sec, {double amp = 0.1, bool twoNote = false}) {
    const tune = [659.0, 784.0, 988.0, 784.0, 880.0, 659.0];
    const dong = [988.0, 784.0];
    final notes = twoNote ? dong : tune;
    const step = 0.3;
    final n = (sec * fs).round();
    final out = Float64List(n);
    for (var i = 0; i < n; i++) {
      final t = i / fs;
      final k = (t / step).floor();
      final f = notes[k % notes.length];
      final lt = t - k * step;
      final env = math.min(1.0, lt / 0.005) * math.exp(-lt * 9);
      out[i] = amp * env * (math.sin(2 * math.pi * f * lt) + 0.3 * math.sin(2 * math.pi * 4 * f * lt));
    }
    return out;
  }

  /// Rain on the helmet / tank bag: dense random drops (short decaying noise bursts) + hiss.
  Float64List rain(double sec, {double amp = 0.05}) {
    final n = (sec * fs).round();
    final out = Float64List(n);
    var env = 0.0;
    for (var i = 0; i < n; i++) {
      if (rnd.nextDouble() < 250 / fs) env = 0.5 + rnd.nextDouble();
      env *= 0.996;
      out[i] = amp * (env * gauss() + 0.2 * gauss());
    }
    return out;
  }

  /// Temple / loudspeaker devotional music: a held harmonium chord plus a singer gliding between
  /// notes (melisma) with vibrato.
  Float64List templeMusic(double sec, {double amp = 0.1}) {
    final n = (sec * fs).round();
    final out = Float64List(n);
    const contour = [300.0, 360.0, 400.0, 450.0, 400.0, 360.0, 330.0, 450.0, 500.0, 450.0];
    var ph = 0.0;
    for (var i = 0; i < n; i++) {
      final t = i / fs;
      final k = (t / 0.45).floor();
      final a = contour[k % contour.length], b = contour[(k + 1) % contour.length];
      final x = (t / 0.45) - k;
      final f0 = (a + (b - a) * (0.5 - 0.5 * math.cos(math.pi * x))) * (1 + 0.02 * math.sin(2 * math.pi * 5.5 * t));
      ph += 2 * math.pi * f0 / fs;
      var v = 0.0;
      for (var h = 1; h <= 8; h++) {
        final hf = h * f0;
        final g = 1.0 / (1 + math.pow((hf - 800) / 400, 2));
        v += g * math.sin(h * ph);
      }
      var drone = 0.0;
      for (final f in [261.6, 329.6, 392.0]) {
        for (var h = 1; h <= 4; h++) {
          drone += math.sin(2 * math.pi * f * h * t) / (h * 2);
        }
      }
      out[i] = v + 0.3 * drone;
    }
    return normalise(out, amp);
  }

  /// Tunnel / underpass echo: delayed, weaker copies of [x] plus a short diffuse tail.
  Float64List echo(Float64List x) {
    final out = Float64List.fromList(x);
    const taps = [(0.031, 0.6), (0.072, 0.45), (0.118, 0.32), (0.19, 0.22), (0.27, 0.15)];
    for (final tap in taps) {
      final d = (tap.$1 * fs).round();
      for (var i = d; i < x.length; i++) {
        out[i] += tap.$2 * x[i - d];
      }
    }
    return out;
  }

  /// Engine drone: harmonic series of a slowly wandering firing frequency + noise.
  Float64List engine(double sec, {double amp = 0.05, double f0 = 45}) {
    final n = (sec * fs).round();
    final out = Float64List(n);
    final ph = List<double>.filled(14, 0);
    for (var i = 0; i < n; i++) {
      final t = i / fs;
      final f = f0 * (1 + 0.15 * math.sin(2 * math.pi * t / 7)) * (1 + 0.004 * gauss());
      var v = 0.0;
      for (var h = 1; h <= 13; h++) {
        ph[h] += 2 * math.pi * f * h / fs;
        v += math.sin(ph[h]) / math.pow(h, 0.7);
      }
      out[i] = amp * (v / 3 + 0.3 * gauss());
    }
    return out;
  }

  /// Wind: low-passed noise with gusts (bursty envelope), optional clipping.
  Float64List wind(double sec, {double amp = 0.15, bool clip = false}) {
    final n = (sec * fs).round();
    final out = Float64List(n);
    var s1 = 0.0, s2 = 0.0, env = 0.3, target = 0.3;
    for (var i = 0; i < n; i++) {
      if (i % 1600 == 0) target = rnd.nextDouble() < 0.35 ? 1.0 + rnd.nextDouble() * 1.5 : 0.2 + rnd.nextDouble() * 0.3;
      env += (target - env) * 0.0015;
      s1 += 0.08 * (gauss() - s1);
      s2 += 0.08 * (s1 - s2);
      var v = amp * env * s2 * 4 + amp * 0.05 * gauss();
      if (clip) v = v.clamp(-0.999, 0.999);
      out[i] = v;
    }
    return out;
  }

  /// Speech-like: voiced syllables (glottal pulse train through formants) with gaps.
  Float64List speech(double sec, {double amp = 0.1, double f0 = 130}) {
    final n = (sec * fs).round();
    final out = Float64List(n);
    var t0 = 0.0;
    var ph = 0.0;
    // Formant resonators (2-pole) per syllable
    final formants = [
      [700.0, 1200.0, 2600.0],
      [400.0, 2000.0, 2700.0],
      [300.0, 900.0, 2400.0],
      [550.0, 1700.0, 2500.0]
    ];
    var syl = 0;
    var sylEnd = 0.0;
    var gapEnd = 0.0;
    final y1 = [0.0, 0.0, 0.0], y2 = [0.0, 0.0, 0.0];
    for (var i = 0; i < n; i++) {
      final t = i / fs;
      if (t >= gapEnd && t >= sylEnd) {
        t0 = t;
        sylEnd = t + 0.15 + rnd.nextDouble() * 0.2;
        gapEnd = sylEnd + 0.05 + rnd.nextDouble() * 0.15;
        syl++;
      }
      final voiced = t < sylEnd;
      final f = f0 * (1 + 0.25 * math.sin(2 * math.pi * (t - t0) * 1.7)) * (1 + 0.1 * math.sin(syl.toDouble()));
      ph += f / fs;
      var exc = 0.0;
      if (voiced && ph >= 1.0) {
        ph -= 1.0;
        exc = 1.0;
      }
      final fm = formants[syl % 4];
      var v = 0.0;
      for (var k = 0; k < 3; k++) {
        final r = 0.97;
        final th = 2 * math.pi * fm[k] / fs;
        final y = exc + 2 * r * math.cos(th) * y1[k] - r * r * y2[k];
        y2[k] = y1[k];
        y1[k] = y;
        v += y * (k == 0 ? 1.0 : 0.5);
      }
      final env = voiced ? math.min(1.0, (t - t0) / 0.02) * math.min(1.0, (sylEnd - t) / 0.02) : 0.0;
      out[i] = v * 0.05 * env;
    }
    // normalise to amp rms over voiced part
    var acc = 0.0;
    for (final v in out) {
      acc += v * v;
    }
    final r = math.sqrt(acc / n);
    if (r > 0) {
      for (var i = 0; i < n; i++) {
        out[i] *= amp / r;
      }
    }
    return out;
  }

  /// Steady voiced vowel (harmonics of f0 with formant-shaped amplitudes) — "voice-like".
  Float64List vowel(double sec, {double amp = 0.1, double f0 = 140, double vibrato = 0.03}) {
    final n = (sec * fs).round();
    final out = Float64List(n);
    var ph = 0.0;
    const fm = [700.0, 1200.0, 2600.0];
    double formantGain(double f) {
      var g = 0.0;
      for (var k = 0; k < 3; k++) {
        final d = (f - fm[k]) / (90.0 + 40 * k);
        g += (k == 0 ? 1.0 : 0.6 / k) / (1 + d * d);
      }
      return g + 0.02;
    }
    for (var i = 0; i < n; i++) {
      final t = i / fs;
      final f = f0 * (1 + vibrato * math.sin(2 * math.pi * 3 * t));
      ph += 2 * math.pi * f / fs;
      var v = 0.0;
      for (var h = 1; h * f0 < 4000; h++) {
        v += formantGain(h * f0) * math.sin(h * ph);
      }
      out[i] = v;
    }
    return normalise(out, amp);
  }

  /// Breath: noise shaped toward 1-6 kHz with a slow in/out envelope.
  Float64List breath(double sec, {double amp = 0.05}) {
    final n = (sec * fs).round();
    final out = Float64List(n);
    var lp = 0.0, prev = 0.0;
    for (var i = 0; i < n; i++) {
      final t = i / fs;
      final w = gauss();
      final hp = w - prev; // first difference: tilt up
      prev = w;
      lp += 0.6 * (hp - lp); // soft low-pass ~ 3 kHz
      final env = 0.5 - 0.5 * math.cos(2 * math.pi * t / 1.6); // in/out cycle 1.6 s
      out[i] = lp * env;
    }
    return normalise(out, amp);
  }

  /// Music-like: sustained major/minor triads with harmonics, a new chord every second.
  Float64List chords(double sec, {double amp = 0.1}) {
    final n = (sec * fs).round();
    final out = Float64List(n);
    const roots = [261.6, 220.0, 174.6, 196.0];
    for (var i = 0; i < n; i++) {
      final t = i / fs;
      final c = (t).floor() % 4;
      final r = roots[c];
      final notes = [r, r * (c == 1 ? 1.189 : 1.26), r * 1.498];
      var v = 0.0;
      for (final f in notes) {
        for (var h = 1; h <= 5; h++) {
          v += math.sin(2 * math.pi * f * h * t) / (h * h);
        }
      }
      final local = t - t.floor();
      final env = math.min(1.0, local / 0.02) * math.exp(-local * 0.7);
      out[i] = v * env;
    }
    return normalise(out, amp);
  }

  /// Riding background: engine drone + wind + mic hiss (about -26 dBFS).
  Float64List ride(double sec, {double engineAmp = 0.04, double windAmp = 0.08}) =>
      mix([engine(sec, amp: engineAmp), wind(sec, amp: windAmp), noise(sec, amp: 0.003)], clip: false);

  Float64List noise(double sec, {double amp = 0.01}) {
    final n = (sec * fs).round();
    final out = Float64List(n);
    for (var i = 0; i < n; i++) {
      out[i] = amp * gauss();
    }
    return out;
  }
}

Float64List normalise(Float64List x, double rms) {
  var acc = 0.0;
  for (final v in x) {
    acc += v * v;
  }
  final r = math.sqrt(acc / math.max(1, x.length));
  if (r <= 0) return x;
  for (var i = 0; i < x.length; i++) {
    x[i] *= rms / r;
  }
  return x;
}

Float64List mix(List<Float64List> parts, {bool clip = true}) {
  final n = parts.map((p) => p.length).reduce(math.max);
  final out = Float64List(n);
  for (final p in parts) {
    for (var i = 0; i < p.length; i++) {
      out[i] += p[i];
    }
  }
  if (clip) {
    for (var i = 0; i < n; i++) {
      out[i] = out[i].clamp(-1.0, 32767 / 32768);
    }
  }
  return out;
}

/// Inserts [x] at [atSec] into a buffer of [sec] seconds.
Float64List place(Float64List x, double atSec, double sec) {
  final out = Float64List((sec * fs).round());
  final o = (atSec * fs).round();
  for (var i = 0; i < x.length && o + i < out.length; i++) {
    out[o + i] = x[i];
  }
  return out;
}

double rmsDb(Float64List x) {
  var acc = 0.0;
  for (final v in x) {
    acc += v * v;
  }
  return 10 * math.log(acc / x.length + 1e-20) / math.ln10;
}
