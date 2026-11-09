// 3.55 intercom voice cleanup: makes the rider's voice clean for the group, on the phone, before
// it is sent. Pure Dart (dart:math + dart:typed_data only): unit tested and runnable in plain
// `dart`. Built to run all ride on a mid-range phone: one 256-point FFT pair every 8 ms plus one
// 1024-point FFT pair every 20 ms, and 12 ms of added latency (8 ms STFT + 4 ms block alignment).
//
// Pipeline (16 kHz mono, any block size; the hub sends 20 ms blocks):
//  1. High-pass 140 Hz (2nd-order biquad): wind rumble and engine drone below the voice go.
//  2. Noise suppression: STFT (256 points, hop 128, sqrt-Hann analysis + synthesis = perfect
//     reconstruction), per-bin noise floor that falls fast and rises slowly (frozen while the
//     rider speaks), Wiener gain with the decision-directed a-priori SNR, a -15 dB gain floor and
//     smoothing across bins (no "musical noise").
//  3. Per 20 ms block: voicing (normalised autocorrelation of the 250-4000 Hz band, pitch
//     80-300 Hz), spectral flatness, high-band (1-6 kHz) share, low-band (< 300 Hz) share of the raw
//     input, clipping.
//     * breath = unvoiced, noise-like (flat), energy mostly 1-6 kHz, for >= 60 ms and >= 100 ms
//       after the last voiced block (so the "s" / "t" around words stays): -20 dB;
//     * wind gust = unvoiced with most energy below 300 Hz, or clipping: -18 dB.
//  4. Voice gate: hands-free (VOX) opens only after 2 voiced blocks (40 ms) and holds 500 ms after
//     the last one, so breath and wind alone never open it; push-to-talk uses a soft gate (-12 dB
//     when no voice) so nothing the rider says is cut.
//  5. AGC to -20 dBFS speech (-6..+18 dB, 25 dB/s), then a peak limiter at -1 dBFS (no clipping).

import 'dart:math' as math;
import 'dart:typed_data';

import 'dsp_core.dart';

/// Per-block analysis, for tests and the intercom's VOX decision.
class VoiceBlockInfo {
  final bool voiced;
  final bool breath;
  final bool wind;
  final bool gateOpen;
  final double pitchHz;
  final double voicing;
  const VoiceBlockInfo({this.voiced = false, this.breath = false, this.wind = false, this.gateOpen = false, this.pitchHz = 0, this.voicing = 0});
}

class VoiceCleanup {
  static const int sampleRate = 16000;
  static const int n = 256;
  static const int hop = 128;
  static const int block = 320; // 20 ms analysis block
  static const double gainFloorDb = -15.0;
  static const double breathDb = -20.0;
  static const double windDb = -18.0;
  static const double softGateDb = -12.0;
  static const double closedGateDb = -30.0;
  static const double targetDbfs = -20.0;
  static const int voxOpenBlocks = 2;
  static const int hangoverBlocks = 25; // 500 ms

  /// Hands-free (VOX): strict gate. Push-to-talk: soft gate.
  bool handsFree;

  /// Noise suppression / breath / wind processing; false = only high-pass, AGC and limiter.
  bool suppressNoise;

  /// Automatic gain (on in the app; tests switch it off to measure the other stages alone).
  bool agc;

  /// Voice gate attenuation (tests switch it off to measure noise suppression alone).
  bool gate;

  VoiceCleanup({this.handsFree = true, this.suppressNoise = true, this.agc = true, this.gate = true});

  final Biquad _hpf = Biquad.highPass(sampleRate.toDouble(), 140);
  final Fft _fft = Fft(n);
  final Fft _fftAc = Fft(1024);
  final Float64List _win = _sqrtHann(n);
  final Float64List _in = Float64List(n); // analysis ring (last 256 filtered samples)
  final Float64List _ola = Float64List(n);
  final Float64List _re = Float64List(n), _im = Float64List(n);
  final Float64List _pow = Float64List(n ~/ 2 + 1);
  final Float64List _sm = Float64List(n ~/ 2 + 1);
  // Starts low (about -70 dBFS of white noise per bin) and climbs to the real floor in pauses.
  static const double _noiseSeed = 1e-5;
  final Float64List _noise = Float64List(n ~/ 2 + 1)..fillRange(0, n ~/ 2 + 1, _noiseSeed);
  final Float64List _gPrev = Float64List(n ~/ 2 + 1);
  final Float64List _postPrev = Float64List(n ~/ 2 + 1);
  final Float64List _gain = Float64List(n ~/ 2 + 1);
  final Float64List _blockPow = Float64List(n ~/ 2 + 1);
  int _blockHops = 0;
  int _hops = 0;
  int _inFill = 0; // samples since the last hop

  // Block analysis buffers.
  final Float64List _blkRaw = Float64List(block);
  final Float64List _blkHp = Float64List(block);
  final Float64List _acHist = Float64List(512);
  final Float64List _acRe = Float64List(1024), _acIm = Float64List(1024);
  int _blkFill = 0;

  // Output FIFO (the STFT emits 128 at a time; callers get exactly as many samples as they give).
  final List<double> _outFifo = [];

  // Block decisions.
  int _voicedRun = 0;
  int _sinceVoiced = 1000;
  int _breathRun = 0;
  int _hang = 0;
  bool _gateOpen = false;
  double _blockGain = 1.0; // current breath / wind / gate gain (smoothed)
  double _targetBlockGain = 1.0;
  double _agcDb = 0.0;
  double _speechDb = -30.0;
  final PeakLimiter _limiter = PeakLimiter(ceiling: 0.89);
  VoiceBlockInfo _last = const VoiceBlockInfo();

  VoiceBlockInfo get last => _last;
  bool get gateOpen => _gateOpen;
  double get agcDb => _agcDb;

  static Float64List _sqrtHann(int n) {
    final w = Float64List(n);
    for (var i = 0; i < n; i++) {
      w[i] = math.sqrt(0.5 - 0.5 * math.cos(2 * math.pi * i / n));
    }
    return w;
  }

  /// New talk session: clears the gate, buffers and filters. The learned noise floor is kept
  /// (the road has not changed between two presses of push-to-talk).
  void reset() {
    _hpf.reset();
    _in.fillRange(0, n, 0);
    _ola.fillRange(0, n, 0);
    _gPrev.fillRange(0, _gPrev.length, 1);
    _postPrev.fillRange(0, _postPrev.length, 1);
    _hops = 0;
    _inFill = 0;
    _blkFill = 0;
    _outFifo.clear();
    _voicedRun = 0;
    _sinceVoiced = 1000;
    _breathRun = 0;
    _hang = 0;
    _gateOpen = false;
    _blockGain = 1.0;
    _targetBlockGain = 1.0;
    _agcDb = 0;
    _speechDb = -30;
    _limiter.reset();
  }

  /// Cleans [x] (16 kHz floats); returns the same number of samples, 12 ms later.
  Float64List process(Float64List x) {
    for (var i = 0; i < x.length; i++) {
      final raw = x[i];
      final y = _hpf.process(raw);
      // Analysis block (raw + filtered) for the 20 ms decisions.
      _blkRaw[_blkFill] = raw;
      _blkHp[_blkFill] = y;
      _blkFill++;
      if (_blkFill == block) {
        _blkFill = 0;
        _analyseBlock();
      }
      // STFT ring.
      _in[n - hop + _inFill] = y;
      _inFill++;
      if (_inFill == hop) {
        _inFill = 0;
        _stftHop();
        _in.setRange(0, n - hop, _in, hop);
      }
    }
    final out = Float64List(x.length);
    final available = math.min(_outFifo.length, x.length);
    final pad = x.length - available; // start-up: zeros until the first hop is out
    for (var i = 0; i < available; i++) {
      out[pad + i] = _outFifo[i];
    }
    _outFifo.removeRange(0, available);
    _postProcess(out);
    return out;
  }

  /// Cleans little-endian PCM16 bytes.
  Uint8List processPcm16(Uint8List bytes) => floatToPcm16Bytes(process(pcm16BytesToFloat(bytes)));

  void _stftHop() {
    _hops++;
    for (var i = 0; i < n; i++) {
      _re[i] = _in[i] * _win[i];
      _im[i] = 0;
    }
    _fft.transform(_re, _im);
    const half = n ~/ 2;
    final first = _hops == 1;
    final voicedNow = _sinceVoiced <= 2;
    // Rises ~2.5 dB/s (fast for the first 0.5 s of a session), frozen while the rider speaks, so a
    // word said the moment the mic opens is not taken for noise.
    final rise = voicedNow ? 1.0 : (_hops < 60 ? 1.2 : 1.0046);
    for (var k = 0; k <= half; k++) {
      final p = _re[k] * _re[k] + _im[k] * _im[k] + 1e-12;
      _pow[k] = p;
      _blockPow[k] += p;
      _sm[k] = first ? p : 0.7 * _sm[k] + 0.3 * p;
      if (first) {
        _gPrev[k] = 1;
        _postPrev[k] = 1;
      }
      if (_sm[k] < _noise[k]) {
        _noise[k] = _noise[k] + 0.3 * (_sm[k] - _noise[k]);
      } else {
        _noise[k] = math.min(_sm[k], _noise[k] * rise);
      }
    }
    _blockHops++;
    final gMin = dbToAmp(gainFloorDb);
    if (suppressNoise) {
      for (var k = 0; k <= half; k++) {
        final post = _pow[k] / (_noise[k] * 1.4); // noise is a minimum: scale toward its mean
        final xi = 0.98 * _gPrev[k] * _gPrev[k] * _postPrev[k] + 0.02 * math.max(post - 1, 0);
        var g = xi / (1 + xi);
        if (g < gMin) g = gMin;
        _gain[k] = g;
        _gPrev[k] = g;
        _postPrev[k] = post;
      }
      // Smooth across frequency (3 taps) against isolated "musical" bins.
      var prev = _gain[0];
      for (var k = 1; k < half; k++) {
        final cur = _gain[k];
        _gain[k] = 0.25 * prev + 0.5 * cur + 0.25 * _gain[k + 1];
        prev = cur;
      }
    } else {
      _gain.fillRange(0, half + 1, 1.0);
    }
    for (var k = 0; k <= half; k++) {
      _re[k] *= _gain[k];
      _im[k] *= _gain[k];
      if (k > 0 && k < half) {
        _re[n - k] = _re[k];
        _im[n - k] = -_im[k];
      }
    }
    _fft.transform(_re, _im, inverse: true);
    for (var i = 0; i < n; i++) {
      _ola[i] += _re[i] / n * _win[i];
    }
    for (var i = 0; i < hop; i++) {
      _outFifo.add(_ola[i]);
    }
    _ola.setRange(0, n - hop, _ola, hop);
    _ola.fillRange(n - hop, n, 0);
  }

  void _analyseBlock() {
    // Raw-input wind / clipping features.
    var rawE = 0.0, lowE = 0.0;
    var clipped = 0;
    var lp = _lpState;
    for (final v in _blkRaw) {
      rawE += v * v;
      lp += 0.11 * (v - lp); // ~300 Hz one-pole low-pass
      lowE += lp * lp;
      if (v.abs() >= 0.98) clipped++;
    }
    _lpState = lp;
    final rawRms = math.sqrt(rawE / block);
    final lfFrac = rawE > 0 ? lowE / rawE : 0.0;

    // Spectral features from the block's STFT frames.
    const half = n ~/ 2;
    final hops = math.max(1, _blockHops);
    var arith = 0.0, logSum = 0.0, cnt = 0;
    var hf = 0.0, all = 0.0, noiseSum = 0.0, sigSum = 0.0;
    for (var k = 1; k <= half; k++) {
      final p = _blockPow[k] / hops;
      final f = k * sampleRate / n;
      if (f >= 150) {
        all += p;
        noiseSum += _noise[k];
        sigSum += p;
      }
      if (f >= 1000 && f <= 6000) hf += p;
      if (f >= 300 && f <= 6000) {
        arith += p;
        logSum += math.log(p);
        cnt++;
      }
    }
    _blockPow.fillRange(0, _blockPow.length, 0);
    _blockHops = 0;
    final flatness = cnt > 0 && arith > 0 ? math.exp(logSum / cnt) / (arith / cnt) : 0.0;
    final hfFrac = all > 0 ? hf / all : 0.0;
    final snrDb = noiseSum > 0 ? powerDb(sigSum / (noiseSum * 1.4)) : 0.0;

    // Voicing: normalised autocorrelation of the 250-4000 Hz band (magnitude-compressed
    // spectrum, so wind residue and one strong formant do not dominate), lags for 80-300 Hz.
    _acHist.setRange(0, 512 - block, _acHist, block);
    _acHist.setRange(512 - block, 512, _blkHp);
    for (var i = 0; i < 1024; i++) {
      _acRe[i] = i < 512 ? _acHist[i] * (0.5 - 0.5 * math.cos(2 * math.pi * i / 512)) : 0.0;
      _acIm[i] = 0;
    }
    _fftAc.transform(_acRe, _acIm);
    final lo = (250 * 1024 / sampleRate).round(), hi = (4000 * 1024 / sampleRate).round();
    for (var k = 0; k < 1024; k++) {
      final kk = k <= 512 ? k : 1024 - k;
      final m = kk >= lo && kk <= hi ? math.sqrt(_acRe[k] * _acRe[k] + _acIm[k] * _acIm[k]) : 0.0;
      _acRe[k] = m;
      _acIm[k] = 0;
    }
    _fftAc.transform(_acRe, _acIm, inverse: true);
    final r0 = _acRe[0];
    var best = 0.0, bestLag = 0;
    if (r0 > 1e-12) {
      for (var lag = sampleRate ~/ 300; lag <= sampleRate ~/ 80; lag++) {
        final r = _acRe[lag] / r0 * (512 / (512 - lag)); // window-length bias correction
        if (r > best && _acRe[lag] >= _acRe[lag - 1] && _acRe[lag] >= _acRe[lag + 1]) {
          best = r;
          bestLag = lag;
        }
      }
    }
    final voiced = best >= 0.42 && snrDb >= 6.0 && rawRms > 1e-4;
    final noisy = !voiced && snrDb >= 6.0;
    final breathLike = noisy && flatness >= 0.25 && hfFrac >= 0.45;
    final windLike = (!voiced && lfFrac >= 0.6 && rawRms > 1e-3) || clipped >= 4;

    if (voiced) {
      _voicedRun++;
      _sinceVoiced = 0;
    } else {
      _voicedRun = 0;
      _sinceVoiced++;
    }
    _breathRun = breathLike ? _breathRun + 1 : 0;
    final breath = suppressNoise && breathLike && _breathRun >= 3 && _sinceVoiced >= 5;
    final wind = suppressNoise && windLike && !voiced;

    // Gate.
    if (_voicedRun >= voxOpenBlocks) {
      _gateOpen = true;
      _hang = hangoverBlocks;
    } else if (_gateOpen) {
      if (voiced) {
        _hang = hangoverBlocks;
      } else if (--_hang <= 0) {
        _gateOpen = false;
      }
    }

    // Gain decisions for the next output block.
    var g = 1.0;
    if (breath) g = math.min(g, dbToAmp(breathDb));
    if (wind) g = math.min(g, dbToAmp(windDb));
    if (!_gateOpen && gate) g = math.min(g, dbToAmp(handsFree ? closedGateDb : softGateDb));
    _targetBlockGain = g;

    // AGC: follow the speech level of voiced blocks only.
    if (voiced) {
      var e = 0.0;
      for (final v in _blkHp) {
        e += v * v;
      }
      final lvl = powerDb(e / block);
      _speechDb = 0.9 * _speechDb + 0.1 * lvl;
      final want = (targetDbfs - _speechDb).clamp(-6.0, 18.0);
      final step = (want - _agcDb).clamp(-0.5, 0.5);
      _agcDb += step;
    }
    _last = VoiceBlockInfo(
      voiced: voiced,
      breath: breath,
      wind: wind,
      gateOpen: _gateOpen,
      pitchHz: bestLag > 0 ? sampleRate / bestLag : 0,
      voicing: best,
    );
  }

  double _lpState = 0;

  void _postProcess(Float64List out) {
    // Block gain (breath / wind / gate) ramps over the block; AGC; limiter.
    final start = _blockGain;
    // Fast attack (down within ~10 ms), slower release (up within ~20 ms).
    final target = _targetBlockGain;
    final len = out.length;
    final agcGain = agc ? dbToAmp(_agcDb) : 1.0;
    for (var i = 0; i < len; i++) {
      final a = (i + 1) / len;
      final g = start + (target - start) * a;
      out[i] *= g * agcGain;
    }
    _blockGain = target;
    _limiter.process(out);
  }
}
