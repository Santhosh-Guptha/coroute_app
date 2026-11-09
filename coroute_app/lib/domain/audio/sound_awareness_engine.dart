// 3.55 sound awareness: emergency-vehicle siren and horn detector for the ride microphone.
//
// Pure Dart (dart:math + dart:typed_data only): unit tested with synthesised signals and runnable
// in a plain `dart` script. Audio is processed on the phone, frame by frame, and thrown away: it
// is never recorded, stored or sent.
//
// Input: 16 kHz mono floats in [-1, 1], any block size (the ride mic hub sends 20 ms = 320 samples).
// Every 20 ms the last 512 samples (32 ms, Hann window) go through one 512-point FFT
// (31.25 Hz bins). Per bin an adaptive noise floor follows the ambient sound (wind, engine,
// tyres): it drops fast and rises slowly (~2 dB/s), so a steady engine drone or wind roar becomes
// "floor" and only sounds that stand out of it are looked at.
//
// Siren (wail / yelp / hi-lo):
//  * a frame is TONAL when one narrow peak in 400-2000 Hz stands >= 8 dB above the floor, holds
//    most of the excess energy (a gust is broadband and fails this), has no strong partial BELOW it
//    (speech and engines are harmonic combs over a low fundamental; a siren's tone is its lowest
//    partial) and the mic is not clipping;
//  * every 100 ms the last 4 s of tonal frames are classified: at least 1.5 s of tonal sound,
//    a frequency span >= 120 Hz (a constant tone / horn is not a siren), then
//      - hi-lo: two tight frequency clusters (ratio 1.12-1.7) with >= 2 switches,
//      - yelp: a smooth sweep reversing 2.5-11 times a second,
//      - wail: a smooth sweep reversing at most ~1.2 times a second (or one long sweep >= 1.5 s),
//      - other smooth sweeps with a span >= 300 Hz: "unknown siren";
//  * 3 positive evaluations in a row (300 ms) confirm. Episode cool-down: one alert per 30 s;
//    inside that time a new alert only when it is clearly closer (a nearness step up and >= 6 dB).
//  * trend: loudness slope of the tone over the last 3 s (>= +1 dB/s approaching, <= -1 dB/s
//    moving away) plus the Doppler drop of the sweep centre (>= 3 % drop = it passed);
//  * nearness: how far the tone stands above the ambient floor (>= 24 dB very near, >= 14 dB near).
//  * kind (a best guess, shown only when confident): hi-lo = ambulance-like, yelp = police-like,
//    a low slow wail (centre < 850 Hz) = fire-like.
//
// Horn: a harmonic sound (1 or 2 fundamentals 140-900 Hz with their overtones holding most of the
// energy), a sudden onset (>= 10 dB above the level 100 ms before), a steady pitch (+-4 %) for
// >= 250 ms and at most 4 s. Clipping or a level above -6 dBFS = the rider's own horn (ignored).
// Alert: two close horns (>= 18 dB over ambient) within 8 s, or one very close long horn
// (>= 24 dB, >= 1 s); at most one horn alert per 20 s; never while a siren episode runs or while
// the rider is talking on the intercom ([suppressHorn]).

import 'dart:math' as math;
import 'dart:typed_data';

import 'dsp_core.dart';

enum SirenPattern { wail, yelp, hiLo, unknown }

enum EmergencyVehicleKind { ambulance, police, fire, unknown }

enum SirenTrend { approaching, steady, movingAway, unknown }

enum SoundNearness { far, near, veryNear }

/// What the detector believes about the siren it hears right now.
class SirenObservation {
  final double timeSec;
  final SirenPattern pattern;
  final EmergencyVehicleKind kind;

  /// True only when [confidence] is high enough to name the kind ("ambulance-like").
  final bool kindConfident;
  final double confidence;
  final SirenTrend trend;
  final SoundNearness nearness;
  final double snrDb;
  final double centreHz;

  /// Loudness trend of the tone (dB per second, least squares over the last 5 s).
  final double levelSlopeDbPerSec;

  const SirenObservation({
    required this.timeSec,
    required this.pattern,
    required this.kind,
    required this.kindConfident,
    required this.confidence,
    required this.trend,
    required this.nearness,
    required this.snrDb,
    required this.centreHz,
    this.levelSlopeDbPerSec = 0,
  });

  @override
  String toString() => 'Siren(${pattern.name}, ${kind.name}${kindConfident ? '' : '?'}, conf ${confidence.toStringAsFixed(2)}, '
      '${trend.name} ${levelSlopeDbPerSec.toStringAsFixed(1)} dB/s, ${nearness.name}, snr ${snrDb.toStringAsFixed(1)} dB, ${centreHz.round()} Hz @ ${timeSec.toStringAsFixed(2)} s)';
}

/// One horn sound that ended.
class HornEvent {
  final double timeSec;
  final double durationSec;
  final double snrDb;
  final double f0Hz;

  /// Clipping / very loud onset: the bike's own horn.
  final bool ownHorn;

  const HornEvent({required this.timeSec, required this.durationSec, required this.snrDb, required this.f0Hz, required this.ownHorn});

  bool get close => snrDb >= SoundAwarenessEngine.hornCloseSnrDb;

  @override
  String toString() => 'Horn(${durationSec.toStringAsFixed(2)} s, snr ${snrDb.toStringAsFixed(1)} dB, f0 ${f0Hz.round()} Hz'
      '${ownHorn ? ', own' : ''} @ ${timeSec.toStringAsFixed(2)} s)';
}

/// Why a siren alert fires.
enum SirenAlertReason { newEpisode, closer }

class SirenAlert {
  final SirenObservation observation;
  final SirenAlertReason reason;
  const SirenAlert(this.observation, this.reason);
  @override
  String toString() => 'SirenAlert(${reason.name}, $observation)';
}

class HornAlert {
  final HornEvent event;
  final int hornsInWindow;
  const HornAlert(this.event, this.hornsInWindow);
  @override
  String toString() => 'HornAlert($hornsInWindow horns, $event)';
}

/// Result of one [SoundAwarenessEngine.process] call.
class SoundAwarenessUpdate {
  /// Present while a siren episode runs (for the cockpit card and ducking).
  final SirenObservation? siren;
  final bool sirenEpisodeEnded;
  final SirenAlert? sirenAlert;
  final HornEvent? hornEvent;
  final HornAlert? hornAlert;

  const SoundAwarenessUpdate({this.siren, this.sirenEpisodeEnded = false, this.sirenAlert, this.hornEvent, this.hornAlert});

  static const SoundAwarenessUpdate none = SoundAwarenessUpdate();
}

class _TonalFrame {
  final double t;
  final bool tonal;
  final double f;
  final double levelDb;
  final double snrDb;
  const _TonalFrame(this.t, this.tonal, this.f, this.levelDb, this.snrDb);
}

class _Classification {
  final SirenPattern pattern;
  final double confidence;
  final double centreHz;
  final double snrDb;
  const _Classification(this.pattern, this.confidence, this.centreHz, this.snrDb);
}

/// Streaming siren + horn detector (see the file header for the method).
class SoundAwarenessEngine {
  static const int sampleRate = 16000;
  static const int hop = 320; // 20 ms
  static const int fftSize = 512;
  static const double binHz = sampleRate / fftSize; // 31.25 Hz
  static const double hopSec = hop / sampleRate;

  // Siren tuning.
  static const double tonalSnrDb = 8.0;
  static const double tonalConcentration = 0.45;
  static const double minTonalSec = 1.5;
  static const double windowSec = 4.0;
  static const int confirmEvaluations = 3;
  static const double cooldownSec = 30.0;
  static const double episodeEndSec = 8.0;
  static const double veryNearSnrDb = 24.0;
  static const double nearSnrDb = 14.0;

  // Horn tuning.
  static const double hornMinSec = 0.25;
  static const double hornMaxSec = 4.0;
  static const double hornOnsetDb = 10.0;
  static const double hornMinSnrDb = 12.0;
  static const double hornCloseSnrDb = 16.0;
  static const double hornVeryCloseSnrDb = 22.0;
  static const double hornRepeatWindowSec = 8.0;
  static const double hornAlertGapSec = 20.0;
  static const double ownHornPeak = 0.97;
  static const double ownHornRms = 0.5;

  final Fft _fft = Fft(fftSize);
  final Float64List _win = hannWindow(fftSize);
  final Float64List _ring = Float64List(fftSize);
  final Float64List _re = Float64List(fftSize);
  final Float64List _im = Float64List(fftSize);
  final Float64List _p = Float64List(fftSize ~/ 2 + 1);
  final Float64List _ps = Float64List(fftSize ~/ 2 + 1);
  final Float64List _floor = Float64List(fftSize ~/ 2 + 1);
  final Float64List _pending = Float64List(hop);
  int _pendingLen = 0;
  int _frames = 0;
  double _t = 0;

  /// Set by the owner while the rider talks on the intercom (their voice is not a horn).
  bool suppressHorn = false;

  /// Diagnostics for tuning scripts (off on the phone).
  bool debug = false;
  String debugLine = '';
  String debugLine2 = '';
  String debugHorn = '';
  String debugClass = '';

  /// Horn detection on/off (the rider's / admin's switch); sirens always run.
  bool hornEnabled = true;

  // Siren state.
  final List<_TonalFrame> _hist = [];
  int _positives = 0;
  bool _episode = false;
  double _lastPositiveT = -1e9;
  double _lastAlertT = -1e9;
  SoundNearness? _lastAlertNearness;
  double _lastAlertSnr = -1e9;
  SirenObservation? _current;
  bool _approachAlerted = false;

  // Horn state.
  final List<Float64List> _specHist = [];
  final List<double> _onsetHist = [];
  bool _hornOn = false;
  double _hornStart = 0;
  int _hornFrames = 0;
  int _hornGap = 0;
  final List<double> _hornF0s = [];
  final List<double> _hornRefs = [];
  double _hornMaxSnr = 0;
  bool _hornOnsetOk = false;
  bool _hornOwn = false;
  final List<HornEvent> _recentHorns = [];
  double _lastHornAlertT = -1e9;

  double get timeSec => _t;
  bool get sirenEpisodeActive => _episode;
  SirenObservation? get currentSiren => _current;

  static int _bin(double hz) => (hz / binHz).round();

  /// Feeds samples; returns what changed (alerts are returned once).
  SoundAwarenessUpdate process(Float64List samples) {
    SoundAwarenessUpdate? out;
    var i = 0;
    while (i < samples.length) {
      final take = math.min(hop - _pendingLen, samples.length - i);
      _pending.setRange(_pendingLen, _pendingLen + take, samples, i);
      _pendingLen += take;
      i += take;
      if (_pendingLen == hop) {
        _pendingLen = 0;
        final u = _processHop(_pending);
        if (out == null || u.sirenAlert != null || u.hornAlert != null || u.hornEvent != null || u.sirenEpisodeEnded) {
          out = _merge(out, u);
        } else {
          out = SoundAwarenessUpdate(siren: u.siren, sirenAlert: out.sirenAlert, hornAlert: out.hornAlert, hornEvent: out.hornEvent, sirenEpisodeEnded: out.sirenEpisodeEnded);
        }
      }
    }
    return out ?? SoundAwarenessUpdate(siren: _current);
  }

  static SoundAwarenessUpdate _merge(SoundAwarenessUpdate? a, SoundAwarenessUpdate b) {
    if (a == null) return b;
    return SoundAwarenessUpdate(
      siren: b.siren,
      sirenEpisodeEnded: a.sirenEpisodeEnded || b.sirenEpisodeEnded,
      sirenAlert: b.sirenAlert ?? a.sirenAlert,
      hornEvent: b.hornEvent ?? a.hornEvent,
      hornAlert: b.hornAlert ?? a.hornAlert,
    );
  }

  /// Forgets everything (new ride).
  void reset() {
    _ring.fillRange(0, _ring.length, 0);
    _floor.fillRange(0, _floor.length, 0);
    _ps.fillRange(0, _ps.length, 0);
    _pendingLen = 0;
    _frames = 0;
    _t = 0;
    _hist.clear();
    _positives = 0;
    _episode = false;
    _lastPositiveT = -1e9;
    _lastAlertT = -1e9;
    _lastAlertNearness = null;
    _lastAlertSnr = -1e9;
    _current = null;
    _specHist.clear();
    _onsetHist.clear();
    _hornOn = false;
    _hornF0s.clear();
    _recentHorns.clear();
    _lastHornAlertT = -1e9;
  }

  SoundAwarenessUpdate _processHop(Float64List x) {
    _frames++;
    _t += hopSec;
    // Shift the analysis ring and append.
    _ring.setRange(0, fftSize - hop, _ring, hop);
    _ring.setRange(fftSize - hop, fftSize, x);
    var peakAbs = 0.0;
    var sumSq = 0.0;
    var clipped = 0;
    for (final v in x) {
      final a = v.abs();
      if (a > peakAbs) peakAbs = a;
      if (a >= ownHornPeak) clipped++;
      sumSq += v * v;
    }
    final frameRms = math.sqrt(sumSq / x.length);
    final clipping = clipped >= 3;

    for (var n = 0; n < fftSize; n++) {
      _re[n] = _ring[n] * _win[n];
      _im[n] = 0;
    }
    _fft.transform(_re, _im);
    const half = fftSize ~/ 2;
    for (var k = 0; k <= half; k++) {
      _p[k] = _re[k] * _re[k] + _im[k] * _im[k] + 1e-9;
    }

    // Adaptive noise floor (on a lightly smoothed spectrum).
    final warm = _frames <= 25; // first 0.5 s: adapt fast
    final rise = warm ? 1.25 : 1.0093; // ~2 dB/s
    for (var k = 0; k <= half; k++) {
      _ps[k] = _frames == 1 ? _p[k] : 0.5 * _ps[k] + 0.5 * _p[k];
      final f = _floor[k];
      if (_frames == 1) {
        _floor[k] = _ps[k];
      } else if (_ps[k] < f) {
        _floor[k] = f + 0.15 * (_ps[k] - f);
      } else {
        _floor[k] = math.min(_ps[k], f * rise);
      }
    }

    final siren = _sirenFrame(clipping);
    final horn = hornEnabled ? _hornFrame(peakAbs, frameRms, clipping) : null;
    return SoundAwarenessUpdate(
      siren: siren.$1,
      sirenEpisodeEnded: siren.$2,
      sirenAlert: siren.$3,
      hornEvent: horn?.$1,
      hornAlert: horn?.$2,
    );
  }

  // ------------------------------------------------------------------ siren
  static final int _sLo = _bin(400), _sHi = _bin(2000);
  static final int _cLo = _bin(300), _cHi = _bin(4000);

  (SirenObservation?, bool, SirenAlert?) _sirenFrame(bool clipping) {
    const half = fftSize ~/ 2;
    // Strongest peak that stands out of the floor in the siren band.
    // (picked by how far it stands above its own floor, not by raw power: low-frequency road
    // and wind noise is louder in absolute terms but sits on a high floor).
    var kStar = -1;
    var best = 0.0;
    for (var k = _sLo; k <= _sHi; k++) {
      final p = _p[k];
      final r = (p + _p[k - 1] + _p[k + 1]) / (_floor[k] + _floor[k - 1] + _floor[k + 1]);
      if (r > best && p >= 3.0 * _floor[k] && p >= _p[k - 1] && p >= _p[k + 1]) {
        best = r;
        kStar = k;
      }
    }
    var tonal = false;
    var f = 0.0;
    var levelDb = -200.0;
    var snrDb = 0.0;
    if (kStar > 0 && !clipping) {
      var region = 0.0, regionFloor = 0.0;
      for (var k = kStar - 2; k <= kStar + 2; k++) {
        region += _p[k];
        regionFloor += _floor[k];
      }
      snrDb = powerDb(region / regionFloor);
      levelDb = powerDb(math.max(region - regionFloor, 1e-12)); // the tone's own power
      // Concentration of the floor-normalised excess within +-25 bins (+-780 Hz): the peak's own
      // +-3 bins (plus its 2nd/3rd harmonic) against everything around it. A broadband gust or
      // road roar spreads its excess over all bins and fails.
      var total = 0.0, near = 0.0;
      final lo = math.max(_cLo, kStar - 25), hi = math.min(_cHi, kStar + 25);
      for (var k = lo; k <= hi; k++) {
        final e = _p[k] / _floor[k] - 1.0;
        if (e <= 0) continue;
        total += e;
        if ((k - kStar).abs() <= 3) near += e;
      }
      final conc = total > 0 ? near / total : 0.0;
      // Harmonic comb around the peak (speech, engine overtones): a neighbouring narrow partial
      // 80-400 Hz below it, repeated at the same spacing above it or further below.
      var lower = false;
      bool partialAt(int k) {
        for (var j = k - 1; j <= k + 1; j++) {
          if (j < 3 || j > half - 3) continue;
          final p = _p[j];
          if (p >= 0.125 * _p[kStar] && p >= 10.0 * _floor[j] && p >= _p[j - 1] && p >= _p[j + 1]) return true;
        }
        return false;
      }
      for (var d = 3; d <= 13 && !lower; d++) {
        if (partialAt(kStar - d) && (partialAt(kStar + d) || partialAt(kStar - 2 * d))) {
          lower = true;
          if (debug) debugLine2 = 'comb d=$d k*=$kStar ${[for (var j = math.max(1, kStar - 2 * d - 1); j <= kStar + d + 1; j++) powerDb(_p[j] / _p[kStar]).round()]} fl ${[for (var j = math.max(1, kStar - 2 * d - 1); j <= kStar + d + 1; j++) powerDb(_p[j] / _floor[j]).round()]}';
        }
      }
      // Sub-bin frequency (parabolic on log power).
      final a = math.log(_p[kStar - 1]), b = math.log(_p[kStar]), c = math.log(_p[kStar + 1]);
      final den = a - 2 * b + c;
      final delta = den.abs() > 1e-12 ? 0.5 * (a - c) / den : 0.0;
      f = (kStar + delta.clamp(-0.5, 0.5)) * binHz;
      tonal = snrDb >= tonalSnrDb && conc >= tonalConcentration && !lower;
      if (debug) debugLine = 't=${_t.toStringAsFixed(2)} f=${f.round()} snr=${snrDb.toStringAsFixed(1)} conc=${conc.toStringAsFixed(2)} lower=$lower tonal=$tonal';
    } else if (debug) {
      debugLine = 't=${_t.toStringAsFixed(2)} no peak (k=$kStar clip=$clipping)';
    }
    _hist.add(_TonalFrame(_t, tonal, f, levelDb, snrDb));
    final maxFrames = (6.0 / hopSec).round();
    if (_hist.length > maxFrames) _hist.removeRange(0, _hist.length - maxFrames);

    SirenAlert? alert;
    var ended = false;
    if (_frames % 5 == 0) {
      final cls = _classify();
      if (cls != null) {
        _positives++;
        if (_positives >= confirmEvaluations) {
          _lastPositiveT = _t;
          final obs = _observe(cls);
          _current = obs;
          if (!_episode) {
            _episode = true;
            _approachAlerted = false;
            if (_t - _lastAlertT >= cooldownSec || _clearlyCloser(obs)) {
              alert = SirenAlert(obs, SirenAlertReason.newEpisode);
            }
          } else if (_t - _lastAlertT >= 8.0 &&
              (_clearlyCloser(obs) ||
                  (!_approachAlerted && obs.trend == SirenTrend.approaching && obs.nearness != SoundNearness.far))) {
            alert = SirenAlert(obs, SirenAlertReason.closer);
          }
          if (alert != null) {
            if (obs.trend == SirenTrend.approaching) _approachAlerted = true;
            _lastAlertT = _t;
            _lastAlertNearness = obs.nearness;
            _lastAlertSnr = obs.snrDb;
          }
        }
      } else {
        _positives = 0;
      }
    }
    if (_episode && _t - _lastPositiveT >= episodeEndSec) {
      _episode = false;
      _current = null;
      ended = true;
    }
    return (_episode ? _current : null, ended, alert);
  }

  bool _clearlyCloser(SirenObservation obs) {
    final last = _lastAlertNearness;
    if (last == null) return false;
    return obs.nearness.index > last.index && obs.snrDb >= _lastAlertSnr + 6.0 && obs.trend != SirenTrend.movingAway;
  }

  _Classification? _classify() {
    final startT = _t - windowSec;
    final w = <_TonalFrame>[];
    var firstTonal = -1;
    var frames = 0;
    for (final fr in _hist) {
      if (fr.t <= startT) continue;
      frames++;
      if (fr.tonal) {
        if (firstTonal < 0) firstTonal = frames;
        w.add(fr);
      }
    }
    if (w.length * hopSec < minTonalSec) { if (debug) debugClass = 'few'; return null; }
    final spanFrames = frames - firstTonal + 1;
    if (w.length / spanFrames < 0.45) { if (debug) debugClass = 'cover'; return null; }
    // The tone must still be there now (last 0.5 s).
    if (w.last.t < _t - 0.5) { if (debug) debugClass = 'stale'; return null; }

    final fs = w.map((e) => e.f).toList()..sort();
    double pct(double q) => fs[((fs.length - 1) * q).round()];
    final fLo = pct(0.05), fHi = pct(0.95);
    final span = fHi - fLo;
    if (span < 120) { if (debug) debugClass = 'span'; return null; } // constant tone (horn, alarm, whistle)
    final snrs = w.map((e) => e.snrDb).toList()..sort();
    final snrMed = snrs[snrs.length ~/ 2];
    final cover = math.min(1.0, w.length * hopSec / 3.0);
    final snrScore = ((snrMed - tonalSnrDb) / 16.0).clamp(0.0, 1.0);

    // ---- hi-lo: two tight clusters.
    var c1 = fLo, c2 = fHi;
    for (var it = 0; it < 6; it++) {
      var s1 = 0.0, n1 = 0, s2 = 0.0, n2 = 0;
      for (final f in fs) {
        if ((f - c1).abs() <= (f - c2).abs()) {
          s1 += f;
          n1++;
        } else {
          s2 += f;
          n2++;
        }
      }
      if (n1 > 0) c1 = s1 / n1;
      if (n2 > 0) c2 = s2 / n2;
    }
    if (c1 > 0 && c2 / c1 >= 1.12 && c2 / c1 <= 1.7) {
      var n1 = 0, n2 = 0, between = 0;
      var v1 = 0.0, v2 = 0.0;
      for (final f in fs) {
        if ((f - c1).abs() <= 0.05 * c1) {
          n1++;
          v1 += (f - c1) * (f - c1);
        } else if ((f - c2).abs() <= 0.05 * c2) {
          n2++;
          v2 += (f - c2) * (f - c2);
        } else {
          between++;
        }
      }
      final n = fs.length;
      if (n1 >= 0.2 * n && n2 >= 0.2 * n && between <= 0.15 * n) {
        // Switches between the clusters, in time order.
        var switches = 0;
        int? side;
        for (final fr in w) {
          final s = (fr.f - c1).abs() <= (fr.f - c2).abs() ? 1 : 2;
          if (side != null && s != side) switches++;
          side = s;
        }
        final sd = math.sqrt((v1 + v2) / math.max(1, n1 + n2));
        if (switches >= 2 && switches <= windowSec * 6) {
          final tight = (1.0 - sd / (0.03 * (c1 + c2) / 2)).clamp(0.0, 1.0);
          final conf = 0.55 + 0.15 * cover + 0.15 * snrScore + 0.15 * tight;
          return _Classification(SirenPattern.hiLo, conf, (c1 + c2) / 2, snrMed);
        }
      }
    }

    // ---- sweeps: smooth track, count reversals (need denser tonal coverage than hi-lo).
    // A steady tone with a few stray peaks is not a sweep: a sweep spreads its frames over the
    // span, so at most ~a third of them sit within 3 % of the median.
    final med = fs[fs.length ~/ 2];
    final atMedian = fs.where((f) => (f - med).abs() <= 0.03 * med).length;
    if (atMedian > 0.35 * fs.length) { if (debug) debugClass = 'static'; return null; }
    if (w.length / spanFrames < 0.55) { if (debug) debugClass = 'cover2'; return null; }
    // Continuity: steps between consecutive tonal frames (<= 3 frames apart) must be small.
    var steps = 0, smooth = 0;
    for (var i = 1; i < w.length; i++) {
      final dt = w[i].t - w[i - 1].t;
      if (dt > 3.5 * hopSec) continue;
      steps++;
      final lim = (60.0 + 0.35 * w[i].f) * (dt / hopSec);
      if ((w[i].f - w[i - 1].f).abs() <= lim) smooth++;
    }
    if (steps == 0 || smooth / steps < 0.85) { if (debug) debugClass = 'smooth'; return null; }
    // 3-point median then reversal count with hysteresis of 40 Hz.
    final tr = <double>[];
    for (var i = 0; i < w.length; i++) {
      final a = w[math.max(0, i - 1)].f, b = w[i].f, c = w[math.min(w.length - 1, i + 1)].f;
      tr.add(math.max(math.min(a, b), math.min(math.max(a, b), c)));
    }
    var reversals = 0;
    var dir = 0;
    var ext = tr.first;
    for (final v in tr) {
      if (dir >= 0) {
        if (v > ext) {
          ext = v;
          if (dir == 0 && v - tr.first > 40) dir = 1;
        } else if (ext - v > 40) {
          if (dir == 1) reversals++;
          dir = -1;
          ext = v;
        }
      } else {
        if (v < ext) {
          ext = v;
        } else if (v - ext > 40) {
          reversals++;
          dir = 1;
          ext = v;
        }
      }
    }
    final dur = math.max(hopSec, w.last.t - w.first.t);
    if (debug) debugClass = 'n=${w.length} span=${span.round()} rev=$reversals smooth=${(smooth / steps).toStringAsFixed(2)}';
    final rate = reversals / 2.0 / dur; // modulation cycles per second
    final smoothScore = ((smooth / steps - 0.85) / 0.15).clamp(0.0, 1.0);
    final centre = (fLo + fHi) / 2;
    if (span >= 300 && rate >= 2.5 && rate <= 11) {
      return _Classification(SirenPattern.yelp, 0.55 + 0.15 * cover + 0.15 * snrScore + 0.15 * smoothScore, centre, snrMed);
    }
    if (span >= 350 && rate <= 1.2 && fLo >= 380 && fHi <= 2100) {
      // Mean sweep speed of a wail: a few hundred Hz per second (not a jump, not frozen).
      var travel = 0.0;
      for (var i = 1; i < tr.length; i++) {
        travel += (tr[i] - tr[i - 1]).abs();
      }
      final speed = travel / dur;
      if (speed >= 80 && speed <= 3000) {
        return _Classification(SirenPattern.wail, 0.55 + 0.15 * cover + 0.15 * snrScore + 0.15 * smoothScore, centre, snrMed);
      }
    }
    // Other smooth sweeps (1.2-2.5 cycles/s) are NOT reported: speech intonation looks like that.
    { if (debug) debugClass = 'nomatch'; return null; }
  }

  SirenObservation _observe(_Classification cls) {
    // Loudness trend of the tone over the last 5 s (least squares slope, dB/s; long enough to span
    // a whole wail cycle, so the siren's own frequency-dependent loudness averages out).
    // Only the current run of siren sound counts (it starts after the last >= 0.6 s without a tone).
    var runStart = _t;
    var lastTonal = _t;
    for (var i = _hist.length - 1; i >= 0; i--) {
      final fr = _hist[i];
      if (fr.tonal) {
        if (lastTonal - fr.t >= 0.6) break;
        lastTonal = fr.t;
        runStart = fr.t;
      }
    }
    final from = math.max(_t - 5.0, runStart - 1e-6);
    var n = 0;
    var st = 0.0, sl = 0.0, stt = 0.0, stl = 0.0;
    var tMin = double.infinity;
    final firstHalf = <double>[], secondHalf = <double>[];
    final mid = _t - windowSec / 2;
    for (final fr in _hist) {
      if (!fr.tonal) continue;
      if (fr.t > _t - windowSec) (fr.t < mid ? firstHalf : secondHalf).add(fr.f);
      if (fr.t <= from) continue;
      n++;
      if (fr.t < tMin) tMin = fr.t;
      st += fr.t;
      sl += fr.levelDb;
      stt += fr.t * fr.t;
      stl += fr.t * fr.levelDb;
    }
    var slope = 0.0;
    if (n >= 100) {
      final den = n * stt - st * st;
      if (den.abs() > 1e-9) slope = (n * stl - st * sl) / den;
    }
    double centreOf(List<double> v) {
      if (v.length < 10) return 0;
      v.sort();
      return (v[(v.length * 0.1).floor()] + v[(v.length * 0.9).floor().clamp(0, v.length - 1)]) / 2;
    }

    final c1 = centreOf(firstHalf), c2 = centreOf(secondHalf);
    final dopplerDrop = c1 > 0 && c2 > 0 && cls.pattern == SirenPattern.hiLo ? (c1 - c2) / c1 : 0.0;
    SirenTrend trend;
    // (needs >= 2 s of tonal frames spread over >= 4 s, about a whole wail cycle; until then the
    // trend is unknown and not spoken)
    if (_t - tMin < 4.0) n = 0;
    if (n >= 100 && (slope <= -1.0 || (dopplerDrop >= 0.03 && slope <= 0.3))) {
      trend = SirenTrend.movingAway;
    } else if (n >= 100 && slope >= 1.0) {
      trend = SirenTrend.approaching;
    } else if (n >= 100) {
      trend = SirenTrend.steady;
    } else {
      trend = SirenTrend.unknown;
    }
    // Nearness from the last second's SNR.
    final recent = _hist.where((f) => f.tonal && f.t > _t - 1.0).map((f) => f.snrDb).toList()..sort();
    final snr = recent.isEmpty ? cls.snrDb : recent[recent.length ~/ 2];
    final nearness = snr >= veryNearSnrDb ? SoundNearness.veryNear : (snr >= nearSnrDb ? SoundNearness.near : SoundNearness.far);
    final kind = switch (cls.pattern) {
      SirenPattern.hiLo => EmergencyVehicleKind.ambulance,
      SirenPattern.yelp => EmergencyVehicleKind.police,
      SirenPattern.wail => cls.centreHz < 850 ? EmergencyVehicleKind.fire : EmergencyVehicleKind.unknown,
      SirenPattern.unknown => EmergencyVehicleKind.unknown,
    };
    final conf = cls.confidence.clamp(0.0, 1.0);
    return SirenObservation(
      timeSec: _t,
      pattern: cls.pattern,
      kind: kind,
      kindConfident: conf >= 0.85 && kind != EmergencyVehicleKind.unknown,
      confidence: conf,
      trend: trend,
      nearness: nearness,
      snrDb: snr,
      centreHz: cls.centreHz,
      levelSlopeDbPerSec: slope,
    );
  }

  // ------------------------------------------------------------------- horn
  static final int _hLo = _bin(120), _hHi = _bin(4000);

  (HornEvent?, HornAlert?)? _hornFrame(double peakAbs, double frameRms, bool clipping) {
    // Spectrum history (for the onset test: the same bins 100 ms ago).
    final past = _specHist.length >= 6 ? _specHist[_specHist.length - 6] : null;
    final keep = _specHist.length >= 7 ? _specHist.removeAt(0) : Float64List(_p.length);
    keep.setAll(0, _p);
    _specHist.add(keep);

    var pmax = 0.0, excessBand = 0.0;
    for (var k = _hLo; k <= _hHi; k++) {
      if (_p[k] > pmax) pmax = _p[k];
      final e = _p[k] - _floor[k];
      if (e > 0) excessBand += e;
    }
    // Partials: narrow local maxima >= 10 dB above the floor and within 20 dB of the strongest.
    final partialBins = <int>[];
    for (var k = _hLo; k <= _hHi; k++) {
      final p = _p[k];
      if (p < 10.0 * _floor[k] || p < pmax * 0.01 || p < _p[k - 1] || p < _p[k + 1]) continue;
      if (p < 4.0 * math.min(_p[k - 3], _p[k + 3])) continue; // a line, not a noise hump
      if (partialBins.isNotEmpty && k - partialBins.last <= 2) {
        if (p > _p[partialBins.last]) partialBins[partialBins.length - 1] = k;
        continue;
      }
      partialBins.add(k);
    }
    final partials = <double>[];
    final lineEx = <double>[];
    var strongest = 0.0;
    for (final k in partialBins) {
      if (_p[k] > strongest) strongest = _p[k];
    }
    var lineP = 0.0, lineFloor = 0.0, linePast = 0.0;
    final strong = <bool>[];
    for (final k in partialBins) {
      final a = math.log(_p[k - 1]), b = math.log(_p[k]), c = math.log(_p[k + 1]);
      final den = a - 2 * b + c;
      final d = den.abs() > 1e-12 ? (0.5 * (a - c) / den).clamp(-0.5, 0.5) : 0.0;
      partials.add((k + d) * binHz);
      strong.add(_p[k] >= strongest * 0.03); // within 15 dB of the strongest line
      var ex = 0.0;
      for (var j = k - 1; j <= k + 1; j++) {
        lineP += _p[j];
        lineFloor += _floor[j];
        final e = _p[j] - _floor[j];
        if (e > 0) ex += e;
        if (past != null) linePast += past[j];
      }
      lineEx.add(ex);
    }
    // Fundamentals (>= 140 Hz, strong lines): lines not explained as an overtone of a lower one.
    // Each line's excess energy is credited to the fundamental that explains it.
    final funds = <double>[];
    final fundEx = <double>[];
    var lineExTotal = 0.0;
    for (var i = 0; i < partials.length; i++) {
      final f = partials[i];
      lineExTotal += lineEx[i];
      if (f < 140) continue;
      var owner = -1;
      for (var g = 0; g < funds.length; g++) {
        final r = f / funds[g];
        final n = r.round();
        if (n >= 2 && n <= 12 && (r - n).abs() <= 0.04 * n) {
          owner = g;
          break;
        }
      }
      if (owner >= 0) {
        fundEx[owner] += lineEx[i];
      } else if (strong[i]) {
        funds.add(f);
        fundEx.add(lineEx[i]);
      }
    }
    // Significant fundamentals: each holds >= 20 % of the line energy (a horn has 1-2, a chord 3+).
    var sig = 0, top1 = 0.0, top2 = 0.0;
    var f0 = 0.0, lowest = double.infinity;
    for (var g = 0; g < funds.length; g++) {
      final e = fundEx[g];
      if (lineExTotal > 0 && e >= 0.2 * lineExTotal) {
        sig++;
        if (funds[g] < lowest) lowest = funds[g];
      }
      if (e > top1) {
        top2 = top1;
        top1 = e;
        f0 = funds[g];
      } else if (e > top2) {
        top2 = e;
      }
    }
    final snrDb = lineFloor > 0 ? powerDb(lineP / lineFloor) : 0.0;
    final frac = excessBand > 0 ? (top1 + top2) / excessBand : 0.0;
    final isHorn = sig >= 1 && sig <= 2 && lowest >= 140 && lowest <= 900 && frac >= 0.55 && snrDb >= hornMinSnrDb;
    final onsetDb = past != null && linePast > 0 ? powerDb(lineP / linePast) : 0.0;
    _onsetHist.add(onsetDb);
    if (_onsetHist.length > 10) _onsetHist.removeAt(0);
    if (debug) {
      debugHorn = 't=${_t.toStringAsFixed(2)} horn=$isHorn snr=${snrDb.toStringAsFixed(1)} onset=${onsetDb.toStringAsFixed(1)} frac=${frac.toStringAsFixed(2)} '
          'funds=${funds.map((f) => f.round()).toList()} partials=${partials.map((f) => f.round()).toList()}';
    }

    HornEvent? ended;
    if (isHorn && (!_hornOn || _pitchMatches(partials))) {
      if (!_hornOn) {
        _hornOn = true;
        _hornStart = _t - hopSec;
        _hornFrames = 0;
        _hornF0s.clear();
        _hornRefs.clear();
        _hornMaxSnr = 0;
        _hornOwn = false;
        // Sudden onset: the same lines were >= 10 dB weaker 100 ms before.
        // (the best of the last 200 ms: the first frames of a horn can be masked by a gust).
        _hornOnsetOk = _onsetHist.reduce(math.max) >= hornOnsetDb;
      }
      _hornFrames++;
      _hornGap = 0;
      _hornF0s.add(f0);
      _hornRefs
        ..clear()
        ..addAll(partials);
      if (snrDb > _hornMaxSnr) _hornMaxSnr = snrDb;
    } else if (_hornOn) {
      _hornGap++;
      if (_hornGap > 3) ended = _endHorn();
    }
    if (_hornOn && (clipping || peakAbs >= ownHornPeak || frameRms >= ownHornRms)) _hornOwn = true;
    if (_hornOn && _t - _hornStart > hornMaxSec) {
      // Too long for a horn (a steady alarm / tone): drop it.
      _hornOn = false;
    }

    HornAlert? alert;
    if (ended != null) {
      final e = ended;
      if (!e.ownHorn && e.close && !suppressHorn && !_episode) {
        _recentHorns.add(e);
        _recentHorns.removeWhere((h) => e.timeSec - h.timeSec > hornRepeatWindowSec);
        final repeated = _recentHorns.length >= 2;
        final longVeryClose = e.durationSec >= 1.0 && e.snrDb >= hornVeryCloseSnrDb;
        // A siren that is not confirmed yet (a hi-lo tone switch looks like a horn blast): no horn
        // alert while a third or more of the last 2 s was siren-like tone.
        var tonal = 0, all = 0;
        for (var i = _hist.length - 1; i >= 0 && _hist[i].t > _t - 2.0; i--) {
          all++;
          if (_hist[i].tonal) tonal++;
        }
        final sirenLike = all > 0 && tonal / all >= 0.35;
        if ((repeated || longVeryClose) && !sirenLike && _t - _lastHornAlertT >= hornAlertGapSec) {
          alert = HornAlert(e, _recentHorns.length);
          _lastHornAlertT = _t;
          _recentHorns.clear();
        }
      }
    }
    return (ended, alert);
  }

  /// Steady pitch: at least two of this frame's lines (or its only line) sit within 3 % of the
  /// lines of the previous horn frame.
  bool _pitchMatches(List<double> lines) {
    if (_hornRefs.isEmpty) return true;
    var hits = 0;
    for (final f in lines) {
      for (final r in _hornRefs) {
        if ((f - r).abs() <= 0.03 * r) {
          hits++;
          break;
        }
      }
    }
    return hits >= math.min(2, lines.length);
  }

  HornEvent? _endHorn() {
    _hornOn = false;
    final dur = _hornFrames * hopSec;
    if (dur < hornMinSec || dur > hornMaxSec || !_hornOnsetOk) return null;
    final s = List<double>.from(_hornF0s)..sort();
    return HornEvent(timeSec: _t, durationSec: dur, snrDb: _hornMaxSnr, f0Hz: s[s.length ~/ 2], ownHorn: _hornOwn);
  }
}
