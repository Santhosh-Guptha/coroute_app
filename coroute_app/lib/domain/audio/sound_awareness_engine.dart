// 3.55 sound awareness: emergency-vehicle siren detector for the ride microphone.
//
// Pure Dart (dart:math + dart:typed_data only): unit tested with synthesised signals and runnable
// in a plain `dart` script. Audio is processed on the phone, frame by frame, and thrown away: it
// is never recorded, stored or sent. Horn detection was removed in 3.55 (owner's decision).
//
// Input: 16 kHz mono floats in [-1, 1], any block size (the ride mic hub sends 20 ms = 320 samples).
// Every 20 ms the last 512 samples (32 ms, Hann window) go through one 512-point FFT
// (31.25 Hz bins). Per bin an adaptive noise floor follows the ambient sound (wind, engine,
// tyres, rain): it drops fast and rises slowly (~2 dB/s), so a steady engine drone or wind roar
// becomes "floor" and only sounds that stand out of it are looked at.
//
//  * TONAL frame: the narrow peak in 380-2100 Hz that stands highest above its floor is >= 8 dB
//    above it, holds most of the floor-normalised excess energy around it (a gust or rain is
//    broadband and fails; a second siren's peak counts too), is not part of a harmonic comb over
//    a low fundamental (speech, engines) and the mic is not clipping. With two peaks (two sirens)
//    the one that continues the previous frame's track is followed.
//  * CONTINUITY: a siren is only considered once the tonal sound has run CONTINUOUSLY for
//    [continuousSec] (2.5 s) with no gap longer than [maxGapSec] (0.4 s). Short chirps, a horn
//    honk, a "whoop" or a reversing beeper (0.5 s gaps) never get that far.
//  * PATTERN (every 100 ms over the current run, at most the last 4 s):
//      - hi-lo: two tight frequency clusters (ratio 1.12-1.7), alternating at a REGULAR dwell
//        (segment-length spread <= 30 %), each tone sustained (a struck / plucked note decays),
//        almost nothing in between (a melody has 3+ notes: musical truck horns, ringtones);
//      - yelp: a smooth triangular sweep reversing 2.5-12 times a second with regular half
//        cycles and steady turning points (singing / melisma wanders);
//      - wail: a smooth, mostly one-way sweep reversing at most ~1.2 times a second (a 2-10 s
//        cycle; also a mechanical siren's slow spin-up).
//    3 positive evaluations in a row (300 ms) confirm. Typical alert: 2.6-3.0 s after the start.
//  * KIND (said only when confident): from the pattern mix of the episode, the hi-lo dwell and
//    ratio, the sweep rate and centre: hi-lo (and hi-lo/wail switching) = ambulance; yelp,
//    wail/yelp switching, very fast hi-lo = police; a low, slow (mechanical) wail = fire engine;
//    an electronic wail alone stays a generic "emergency vehicle" (used by all services).
//  * Episodes and cool-down: one alert per episode (ends 8 s after the siren stops); a new episode
//    alerts only 30 s after the last alert; within the cool-down only a clearly closer siren
//    (nearness step and >= 6 dB) re-alerts, and an approaching trend re-alerts once per 30 s.
//  * Trend: least-squares loudness slope of the tone over the run (>= +1 dB/s approaching,
//    <= -1 dB/s moving away) plus the Doppler drop of the hi-lo / yelp pitch (>= 3 % = passed).
//  * Nearness: how far the tone stands above the ambient floor (>= 24 dB very near, >= 14 dB near).
//  * [suppress] (set by the owner while the phone itself plays sound on its speaker: music, a
//    ringtone, our own alert) treats frames as silent, so the phone never alerts on itself.

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

  /// True only when [kindConfidence] is high enough to say the kind ("Ambulance siren ...").
  final bool kindConfident;

  /// How sure the detector is that this is a siren (0..1).
  final double confidence;

  /// How sure it is of [kind] (0..1).
  final double kindConfidence;
  final SirenTrend trend;
  final SoundNearness nearness;
  final double snrDb;
  final double centreHz;

  /// Loudness trend of the tone (dB per second, least squares over the run, at most 5 s).
  final double levelSlopeDbPerSec;

  /// How long the siren has sounded without a break (seconds).
  final double continuousSec;

  const SirenObservation({
    required this.timeSec,
    required this.pattern,
    required this.kind,
    required this.kindConfident,
    required this.confidence,
    this.kindConfidence = 0,
    required this.trend,
    required this.nearness,
    required this.snrDb,
    required this.centreHz,
    this.levelSlopeDbPerSec = 0,
    this.continuousSec = 0,
  });

  @override
  String toString() => 'Siren(${pattern.name}, ${kind.name}${kindConfident ? '' : '?'} ${kindConfidence.toStringAsFixed(2)}, '
      'conf ${confidence.toStringAsFixed(2)}, ${trend.name} ${levelSlopeDbPerSec.toStringAsFixed(1)} dB/s, ${nearness.name}, '
      'snr ${snrDb.toStringAsFixed(1)} dB, ${centreHz.round()} Hz, run ${continuousSec.toStringAsFixed(1)} s @ ${timeSec.toStringAsFixed(2)} s)';
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

/// Result of one [SoundAwarenessEngine.process] call.
class SoundAwarenessUpdate {
  /// Present while a siren episode runs (for the cockpit card and ducking).
  final SirenObservation? siren;
  final bool sirenEpisodeEnded;
  final SirenAlert? sirenAlert;

  const SoundAwarenessUpdate({this.siren, this.sirenEpisodeEnded = false, this.sirenAlert});

  static const SoundAwarenessUpdate none = SoundAwarenessUpdate();
}

class _TonalFrame {
  final double t;
  final bool tonal;
  final double f;
  final double levelDb;
  final double snrDb;

  /// Not tonal because broadband sound (a gust, rain burst, clipping) covered the band: the siren
  /// may still be there, so the frame neither breaks nor extends a run.
  final bool masked;
  const _TonalFrame(this.t, this.tonal, this.f, this.levelDb, this.snrDb, {this.masked = false});
}

class _Classification {
  final SirenPattern pattern;
  final double confidence;
  final double centreHz;
  final double snrDb;

  /// hi-lo: median tone dwell (s) and the frequency ratio of the two tones.
  final double dwellSec;
  final double ratio;

  /// Sweeps: modulation cycles per second and mean sweep speed (Hz/s).
  final double rate;
  final double speedHzPerSec;

  /// 0..1: how regular the pattern is (dwell / half-cycle spread).
  final double regularity;

  /// Pitch drop between the first and second half of the window (Doppler; hi-lo / yelp only).
  final double dopplerDrop;

  const _Classification(this.pattern, this.confidence, this.centreHz, this.snrDb,
      {this.dwellSec = 0, this.ratio = 0, this.rate = 0, this.speedHzPerSec = 0, this.regularity = 0, this.dopplerDrop = 0});
}

/// Streaming siren detector (see the file header for the method).
class SoundAwarenessEngine {
  static const int sampleRate = 16000;
  static const int hop = 320; // 20 ms
  static const int fftSize = 512;
  static const double binHz = sampleRate / fftSize; // 31.25 Hz
  static const double hopSec = hop / sampleRate;

  // Tuning.
  static const double tonalSnrDb = 8.0;
  static const double tonalConcentration = 0.45;
  static const double continuousSec = 2.5;
  static const double maxGapSec = 0.4;
  static const double maxMaskedSec = 1.2;
  static const double windowSec = 4.0;
  static const int confirmEvaluations = 3;
  static const double cooldownSec = 30.0;
  static const double episodeEndSec = 8.0;
  static const double veryNearSnrDb = 24.0;
  static const double nearSnrDb = 14.0;

  /// The kind is said only at or above this confidence.
  static const double kindSayConfidence = 0.8;
  static const double _clipLevel = 0.97;

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

  /// Set by the owner while the phone itself plays sound on its loudspeaker (music, a ringtone or
  /// notification, our own spoken alert, the intercom on the speaker): frames count as silent.
  bool suppress = false;

  /// Diagnostics for tuning scripts (off on the phone).
  bool debug = false;
  String debugLine = '';
  String debugClass = '';

  // State.
  final List<_TonalFrame> _hist = [];
  int _positives = 0;
  bool _episode = false;
  double _lastPositiveT = -1e9;
  double _lastAlertT = -1e9;
  double _lastApproachAlertT = -1e9;
  SoundNearness? _lastAlertNearness;
  double _lastAlertSnr = -1e9;
  SirenObservation? _current;

  /// Positive pattern evaluations of this episode (time, pattern, classification), last 20 s.
  final List<(double, _Classification)> _episodeEvals = [];

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
        out = out == null
            ? u
            : SoundAwarenessUpdate(
                siren: u.siren,
                sirenEpisodeEnded: out.sirenEpisodeEnded || u.sirenEpisodeEnded,
                sirenAlert: u.sirenAlert ?? out.sirenAlert,
              );
      }
    }
    return out ?? SoundAwarenessUpdate(siren: _current);
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
    _lastApproachAlertT = -1e9;
    _lastAlertNearness = null;
    _lastAlertSnr = -1e9;
    _current = null;
    _episodeEvals.clear();
  }

  SoundAwarenessUpdate _processHop(Float64List x) {
    _frames++;
    _t += hopSec;
    _ring.setRange(0, fftSize - hop, _ring, hop);
    _ring.setRange(fftSize - hop, fftSize, x);
    var clipped = 0;
    for (final v in x) {
      if (v.abs() >= _clipLevel) clipped++;
    }
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

    // Adaptive noise floor (on a lightly smoothed spectrum). While the phone plays its own sound
    // the floor is left alone (that sound is not the road).
    if (!suppress) {
      final warm = _frames <= 25; // first 0.5 s: adapt fast
      final rise = warm ? 1.25 : 1.0093; // ~2 dB/s
      for (var k = 0; k <= half; k++) {
        _ps[k] = _frames == 1 ? _p[k] : 0.5 * _ps[k] + 0.5 * _p[k];
        final f = _floor[k];
        if (_frames == 1 || f <= 0) {
          _floor[k] = _ps[k];
        } else if (_ps[k] < f) {
          _floor[k] = f + 0.15 * (_ps[k] - f);
        } else {
          _floor[k] = math.min(_ps[k], f * rise);
        }
      }
    }

    final r = _sirenFrame(clipping || suppress || _floor[_sLo] <= 0, masked: clipping || (!suppress && _bandCovered()));
    return SoundAwarenessUpdate(siren: r.$1, sirenEpisodeEnded: r.$2, sirenAlert: r.$3);
  }

  // ------------------------------------------------------------------ per frame
  static final int _sLo = _bin(380), _sHi = _bin(2100);
  static final int _cLo = _bin(300), _cHi = _bin(4000);

  /// Ratio of a peak to its own floor (3-bin sums), or 0 when [k] is not a usable local peak.
  double _peakRatio(int k) {
    final p = _p[k];
    if (p < 3.0 * _floor[k] || p < _p[k - 1] || p < _p[k + 1]) return 0;
    return (p + _p[k - 1] + _p[k + 1]) / (_floor[k] + _floor[k - 1] + _floor[k + 1]);
  }

  double _subBinHz(int k) {
    final a = math.log(_p[k - 1]), b = math.log(_p[k]), c = math.log(_p[k + 1]);
    final den = a - 2 * b + c;
    final delta = den.abs() > 1e-12 ? 0.5 * (a - c) / den : 0.0;
    return (k + delta.clamp(-0.5, 0.5)) * binHz;
  }

  double _snrAt(int k) {
    var region = 0.0, regionFloor = 0.0;
    for (var j = k - 2; j <= k + 2; j++) {
      region += _p[j];
      regionFloor += _floor[j];
    }
    return powerDb(region / regionFloor);
  }

  /// A harmonic comb around [k] (speech, engine overtones): a narrow partial 94-406 Hz below it,
  /// repeated at the same spacing above it or further below. A siren tone is its own lowest partial.
  bool _combAround(int k) {
    const half = fftSize ~/ 2;
    bool partialAt(int c) {
      for (var j = c - 1; j <= c + 1; j++) {
        if (j < 3 || j > half - 3) continue;
        final p = _p[j];
        if (p >= 0.125 * _p[k] && p >= 10.0 * _floor[j] && p >= _p[j - 1] && p >= _p[j + 1]) return true;
      }
      return false;
    }

    for (var d = 3; d <= 13; d++) {
      if (partialAt(k - d) && (partialAt(k + d) || partialAt(k - 2 * d))) return true;
    }
    return false;
  }

  /// Broadband sound covers the siren band: at least half its bins are >= 6 dB over their floor.
  bool _bandCovered() {
    var up = 0, n = 0;
    for (var k = _sLo; k <= _sHi; k++) {
      n++;
      if (_p[k] >= 4.0 * _floor[k]) up++;
    }
    return up * 2 >= n;
  }

  (SirenObservation?, bool, SirenAlert?) _sirenFrame(bool silent, {bool masked = false}) {
    var k1 = -1, k2 = -1;
    var r1 = 0.0, r2 = 0.0;
    if (!silent) {
      for (var k = _sLo; k <= _sHi; k++) {
        final r = _peakRatio(k);
        if (r <= 0) continue;
        if (r > r1) {
          if (k1 >= 0 && (k - k1).abs() >= 4) {
            k2 = k1;
            r2 = r1;
          }
          k1 = k;
          r1 = r;
        } else if (r > r2 && (k - k1).abs() >= 4) {
          k2 = k;
          r2 = r;
        }
      }
    }
    // A siren's 2nd / 3rd harmonic can stand higher above the floor than its fundamental (wind
    // noise is low-pitched): the fundamental is followed when it is tonal too.
    if (k1 > 0) k1 = _fundamentalOf(k1);
    if (k2 > 0) k2 = _fundamentalOf(k2);
    if (k2 > 0 && (k2 - k1).abs() < 4) k2 = -1;
    var tonal = false;
    var f = 0.0;
    var levelDb = -200.0;
    var snrDb = 0.0;
    if (k1 > 0) {
      final snr1 = _snrAt(k1);
      final second = k2 > 0 && _snrAt(k2) >= tonalSnrDb && !_combAround(k2) ? k2 : -1;
      // Concentration of the floor-normalised excess within +-25 bins (+-780 Hz): the peak's own
      // +-3 bins (and a second siren's) against everything around it.
      var total = 0.0, near = 0.0;
      final lo = math.max(_cLo, k1 - 25), hi = math.min(_cHi, k1 + 25);
      for (var k = lo; k <= hi; k++) {
        final e = _p[k] / _floor[k] - 1.0;
        if (e <= 0) continue;
        total += e;
        if ((k - k1).abs() <= 3 || (second > 0 && (k - second).abs() <= 3)) near += e;
      }
      final conc = total > 0 ? near / total : 0.0;
      final comb = _combAround(k1);
      tonal = snr1 >= tonalSnrDb && conc >= tonalConcentration && !comb;
      var k = k1;
      if (tonal && second > 0) {
        // Two tonal peaks (two sirens, or a siren and a steady tone): follow the track.
        final prev = _lastTonalF();
        if (prev > 0) {
          final fa = _subBinHz(k1), fb = _subBinHz(second);
          if ((fb - prev).abs() < (fa - prev).abs() && (fa - prev).abs() > 0.12 * prev) k = second;
        }
      }
      f = _subBinHz(k);
      snrDb = k == k1 ? snr1 : _snrAt(k);
      var region = 0.0, regionFloor = 0.0;
      for (var j = k - 2; j <= k + 2; j++) {
        region += _p[j];
        regionFloor += _floor[j];
      }
      levelDb = powerDb(math.max(region - regionFloor, 1e-12));
      if (debug) debugLine = 't=${_t.toStringAsFixed(2)} f=${f.round()} snr=${snrDb.toStringAsFixed(1)} conc=${conc.toStringAsFixed(2)} comb=$comb tonal=$tonal';
    } else if (debug) {
      debugLine = 't=${_t.toStringAsFixed(2)} no peak';
    }
    _hist.add(_TonalFrame(_t, tonal, f, levelDb, snrDb, masked: masked && !tonal));
    final maxFrames = (8.0 / hopSec).round();
    if (_hist.length > maxFrames) _hist.removeRange(0, _hist.length - maxFrames);

    SirenAlert? alert;
    var ended = false;
    if (_frames % 5 == 0) {
      final cls = _classify();
      if (cls != null) {
        _positives++;
        _episodeEvals.add((_t, cls));
        _episodeEvals.removeWhere((e) => _t - e.$1 > 20.0);
        if (_positives >= confirmEvaluations) {
          _lastPositiveT = _t;
          final obs = _observe(cls);
          _current = obs;
          if (!_episode) {
            _episode = true;
            if (_t - _lastAlertT >= cooldownSec || _clearlyCloser(obs)) {
              alert = SirenAlert(obs, SirenAlertReason.newEpisode);
            }
          } else if (_t - _lastAlertT >= 8.0 &&
              (_clearlyCloser(obs) ||
                  (obs.trend == SirenTrend.approaching && obs.nearness != SoundNearness.far && _t - _lastApproachAlertT >= cooldownSec))) {
            alert = SirenAlert(obs, SirenAlertReason.closer);
          }
          if (alert != null) {
            if (obs.trend == SirenTrend.approaching) _lastApproachAlertT = _t;
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
      _episodeEvals.clear();
      ended = true;
    }
    return (_episode ? _current : null, ended, alert);
  }

  int _fundamentalOf(int k) {
    for (final div in const [3, 2]) {
      final c = (k / div).round();
      if (c < _sLo) continue;
      for (var j = c - 1; j <= c + 1; j++) {
        // (the fundamental is the stronger partial in absolute power; only its floor is higher.
        // Siren tones are square-ish, so the 3rd harmonic is the usual stray pick: its
        // fundamental needs to stand only 5 dB out of the floor)
        if (_p[j] >= _p[k] && _peakRatio(j) > 0 && _snrAt(j) >= (div == 3 ? 5.0 : tonalSnrDb)) return j;
      }
    }
    return k;
  }

  double _lastTonalF() {
    for (var i = _hist.length - 1; i >= 0 && i >= _hist.length - 3; i--) {
      if (_hist[i].tonal) return _hist[i].f;
    }
    return 0;
  }

  bool _clearlyCloser(SirenObservation obs) {
    final last = _lastAlertNearness;
    if (last == null) return false;
    return obs.nearness.index > last.index && obs.snrDb >= _lastAlertSnr + 6.0 && obs.trend != SirenTrend.movingAway;
  }

  /// Start time of the current continuous run of tonal sound, or null when the tone is not
  /// sounding now. The run breaks at more than [maxGapSec] without the tone; frames where a gust,
  /// rain or clipping covered the band ([_TonalFrame.masked]) do not count as a gap (up to
  /// [maxMaskedSec] in a row). An isolated tonal frame (no tonal neighbour: a noise blip) neither
  /// starts nor bridges a run.
  double? _runStart() {
    bool counts(int i) =>
        _hist[i].tonal && ((i > 0 && _hist[i - 1].tonal) || (i + 1 < _hist.length && _hist[i + 1].tonal));
    double? start;
    var gap = 0.0, masked = 0.0;
    for (var i = _hist.length - 1; i >= 0; i--) {
      final fr = _hist[i];
      if (counts(i)) {
        start = fr.t;
        gap = 0;
        masked = 0;
        continue;
      }
      if (fr.masked) {
        masked += hopSec;
        if (masked > maxMaskedSec) break;
      } else {
        gap += hopSec;
        if (gap > maxGapSec + 1e-9) break;
      }
      if (start == null && gap + masked > maxGapSec + 1e-9 && gap > 0) return null; // not sounding now
    }
    return start;
  }

  // ------------------------------------------------------------------ classification
  _Classification? _classify() {
    final runStart = _runStart();
    if (runStart == null) {
      if (debug) debugClass = 'no run';
      return null;
    }
    final run = _t - runStart;
    if (run < continuousSec) {
      if (debug) debugClass = 'short run ${run.toStringAsFixed(2)}';
      return null;
    }
    final startT = math.max(runStart - 1e-6, _t - windowSec);
    final w = <_TonalFrame>[];
    var frames = 0; // frames not covered by a gust / rain / clipping
    for (final fr in _hist) {
      if (fr.t <= startT || fr.masked) continue;
      frames++;
      if (fr.tonal) w.add(fr);
    }
    if (w.length < 20 || w.length / frames < 0.5) {
      if (debug) debugClass = 'cover ${w.length}/$frames';
      return null;
    }

    final fs = w.map((e) => e.f).toList()..sort();
    double pct(double q) => fs[((fs.length - 1) * q).round()];
    final fLo = pct(0.05), fHi = pct(0.95);
    final span = fHi - fLo;
    if (span < math.max(40.0, 0.08 * fLo)) {
      if (debug) debugClass = 'span';
      return null; // constant tone (horn, alarm, whistle, reversing beeper)
    }
    final snrs = w.map((e) => e.snrDb).toList()..sort();
    final snrMed = snrs[snrs.length ~/ 2];
    final cover = math.min(1.0, w.length * hopSec / 3.0);
    final snrScore = ((snrMed - tonalSnrDb) / 16.0).clamp(0.0, 1.0);

    final hl = _hiLo(w, fs, fLo, fHi, cover, snrScore, snrMed);
    if (hl != null) return hl;
    if (_twoClusterReject) {
      if (debug) debugClass = 'two tones, not a siren ($debugClass)';
      return null;
    }
    return _sweep(w, fs, fLo, fHi, span, frames, cover, snrScore, snrMed);
  }

  /// Set by [_hiLo] when the sound was two (or more) steady tones that failed the siren checks
  /// (a melody, a decaying chime): then it is not tried as a sweep either.
  bool _twoClusterReject = false;

  _Classification? _hiLo(List<_TonalFrame> w, List<double> fs, double fLo, double fHi, double cover, double snrScore, double snrMed) {
    _twoClusterReject = false;
    var c1 = fLo, c2 = fHi;
    for (var it = 0; it < 8; it++) {
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
    if (c1 <= 0 || c2 / c1 < 1.1 || c2 / c1 > 1.7) return null;
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
    // Mostly steady tones at two pitches: a hi-lo candidate (or a melody / chime).
    final steadyTwo = n1 + n2 >= 0.6 * n;
    if (n1 < 0.2 * n || n2 < 0.2 * n || between > 0.18 * n) {
      // 3+ steady notes (a melody: musical truck horn, ringtone, temple loudspeaker): not a siren.
      if (steadyTwo && between > 0.18 * n && _steadyNotes(w) >= 0.6) {
        _twoClusterReject = true;
        if (debug) debugClass = 'melody';
      }
      return null;
    }
    // Segments (runs of the same tone, in time order; short dropouts inside a tone do not split
    // it). A stray frame or two picked on the other tone inside a tone is merged back.
    // Majority of the frames within +-60 ms, so a few frames picked on noise inside a weak tone
    // do not split it.
    final raw = [for (final fr in w) (fr.f - c1).abs() <= (fr.f - c2).abs() ? 1 : 2];
    final labels = List<int>.filled(raw.length, 1);
    for (var i = 0; i < raw.length; i++) {
      var ones = 0, twos = 0;
      for (var j = math.max(0, i - 4); j <= math.min(raw.length - 1, i + 4); j++) {
        if ((w[j].t - w[i].t).abs() > 0.061) continue;
        if (raw[j] == 1) {
          ones++;
        } else {
          twos++;
        }
      }
      labels[i] = ones == twos ? raw[i] : (ones > twos ? 1 : 2);
    }
    final segs = <(int side, double t0, double t1, double l0, double l1)>[];
    int? side;
    double t0 = 0, last = 0;
    final levels = <double>[];
    void close() {
      if (side == null || levels.isEmpty) return;
      final m = levels.length;
      final third = math.max(1, m ~/ 3);
      double mean(List<double> v) => v.reduce((x, y) => x + y) / v.length;
      segs.add((side, t0, last, mean(levels.sublist(0, third)), mean(levels.sublist(m - third))));
    }
    for (var i = 0; i < w.length; i++) {
      final fr = w[i];
      final s = labels[i];
      if (side == null || s != side) {
        close();
        side = s;
        t0 = fr.t;
        levels.clear();
      }
      last = fr.t;
      levels.add(fr.levelDb);
    }
    close();
    final switches = segs.length - 1;
    if (switches < 2 || switches > windowSec * 6) {
      if (debug) debugClass = 'switches $switches';
      _twoClusterReject = switches > windowSec * 6;
      return null;
    }
    // Interior segments are whole tones (the first and last may be cut by the window).
    final interior = segs.length > 2 ? segs.sublist(1, segs.length - 1) : const <(int, double, double, double, double)>[];
    // Dwell = from one tone change to the next (robust to dropouts inside a tone).
    final durs = [for (var i = 1; i < segs.length - 1; i++) segs[i + 1].$2 - segs[i].$2];
    var regularity = 0.6;
    var dwell = 0.0;
    if (durs.isNotEmpty) {
      final sorted = [...durs]..sort();
      dwell = sorted[sorted.length ~/ 2];
      if (durs.length >= 2) {
        // Robust spread of the dwell (interquartile range / median / 1.35; with two tones only,
        // their difference over the mean): a siren's tones are equally long, a tune's are not.
        final double cv;
        if (durs.length >= 4) {
          cv = (sorted[(sorted.length * 3) ~/ 4] - sorted[sorted.length ~/ 4]) / dwell / 1.35;
        } else {
          cv = (sorted.last - sorted.first) / (durs.reduce((a, b) => a + b) / durs.length) / 2;
        }
        if (cv > 0.3) {
          if (debug) debugClass = 'irregular dwell cv=${cv.toStringAsFixed(2)}';
          _twoClusterReject = true;
          return null; // a tune, not a siren
        }
        regularity = (1.0 - cv / 0.3).clamp(0.0, 1.0);
      }
      if (dwell < 0.12 || dwell > 1.6) {
        if (debug) debugClass = 'dwell ${dwell.toStringAsFixed(2)}';
        _twoClusterReject = true;
        return null;
      }
      // Each tone is sustained: a struck / plucked note (chime, ringtone, marimba) decays.
      final drops = [for (final s in interior) s.$4 - s.$5]..sort();
      final drop = drops[drops.length ~/ 2];
      if (drop > 6.0) {
        if (debug) debugClass = 'decaying notes ${drop.toStringAsFixed(1)} dB';
        _twoClusterReject = true;
        return null;
      }
    } else {
      dwell = (w.last.t - w.first.t) / math.max(1, segs.length);
    }
    final sd = math.sqrt((v1 + v2) / math.max(1, n1 + n2));
    final tight = (1.0 - sd / (0.03 * (c1 + c2) / 2)).clamp(0.0, 1.0);
    // Doppler: the two tones' centre in the first vs the second half of the window.
    final mid = (w.first.t + w.last.t) / 2;
    double centreOf(bool first) {
      var s = 0.0, m = 0;
      for (final fr in w) {
        if ((fr.t < mid) != first) continue;
        final lowSide = (fr.f - c1).abs() <= (fr.f - c2).abs();
        s += fr.f / (lowSide ? c1 : c2);
        m++;
      }
      return m == 0 ? 1.0 : s / m;
    }

    final drop = centreOf(true) - centreOf(false);
    final conf = 0.55 + 0.15 * cover + 0.15 * snrScore + 0.15 * (0.5 * tight + 0.5 * regularity);
    return _Classification(SirenPattern.hiLo, conf, (c1 + c2) / 2, snrMed,
        dwellSec: dwell, ratio: c2 / c1, regularity: regularity, dopplerDrop: drop);
  }

  /// Share of tonal frames whose pitch is within 1.2 % of the pitch 80 ms earlier (held notes; a
  /// siren sweep moves further than that except right at its turning points).
  double _steadyNotes(List<_TonalFrame> w) {
    var steady = 0, steps = 0;
    var j = 0;
    for (var i = 0; i < w.length; i++) {
      while (j < i && w[i].t - w[j].t > 0.08 + 1e-6) {
        j++;
      }
      if (j == i || (w[i].t - w[j].t) < 0.08 - 1e-6) continue;
      steps++;
      if ((w[i].f - w[j].f).abs() <= 0.012 * w[j].f) steady++;
    }
    return steps == 0 ? 0 : steady / steps;
  }

  _Classification? _sweep(List<_TonalFrame> w, List<double> fs, double fLo, double fHi, double span, int frames, double cover,
      double snrScore, double snrMed) {
    // A steady tone with stray peaks is not a sweep: a sweep spreads its frames over the span.
    final med = fs[fs.length ~/ 2];
    final atMedian = fs.where((f) => (f - med).abs() <= 0.03 * med).length;
    if (atMedian > 0.35 * fs.length) {
      if (debug) debugClass = 'static';
      return null;
    }
    // Steady notes (a melody of held pitches) are not a sweep either.
    if (_steadyNotes(w) > 0.55) {
      if (debug) debugClass = 'held notes';
      return null;
    }
    if (w.length / frames < 0.7) {
      if (debug) debugClass = 'cover2';
      return null;
    }
    // Continuity: steps between consecutive tonal frames (<= 3 frames apart) must be small.
    var steps = 0, smooth = 0;
    for (var i = 1; i < w.length; i++) {
      final dt = w[i].t - w[i - 1].t;
      if (dt > 3.5 * hopSec) continue;
      steps++;
      final lim = (60.0 + 0.35 * w[i].f) * (dt / hopSec);
      if ((w[i].f - w[i - 1].f).abs() <= lim) smooth++;
    }
    if (steps == 0 || smooth / steps < 0.85) {
      if (debug) debugClass = 'smooth';
      return null;
    }
    // 3-point median, then turning points with a hysteresis of 40 Hz.
    final tr = <double>[];
    for (var i = 0; i < w.length; i++) {
      final a = w[math.max(0, i - 1)].f, b = w[i].f, c = w[math.min(w.length - 1, i + 1)].f;
      tr.add(math.max(math.min(a, b), math.min(math.max(a, b), c)));
    }
    final turnT = <double>[];
    final turnF = <double>[];
    final turnUp = <bool>[]; // true = a peak (top of the sweep)
    var dir = 0;
    var ext = tr.first;
    var extT = w.first.t;
    for (var i = 0; i < tr.length; i++) {
      final v = tr[i];
      if (dir >= 0) {
        if (v > ext) {
          ext = v;
          extT = w[i].t;
          if (dir == 0 && v - tr.first > 40) dir = 1;
        } else if (ext - v > 40) {
          if (dir == 1) {
            turnT.add(extT);
            turnF.add(ext);
            turnUp.add(true);
          }
          dir = -1;
          ext = v;
          extT = w[i].t;
        }
      } else {
        if (v < ext) {
          ext = v;
          extT = w[i].t;
        } else if (v - ext > 40) {
          turnT.add(extT);
          turnF.add(ext);
          turnUp.add(false);
          dir = 1;
          ext = v;
          extT = w[i].t;
        }
      }
    }
    final reversals = turnT.length;
    final dur = math.max(hopSec, w.last.t - w.first.t);
    final rate = reversals / 2.0 / dur; // modulation cycles per second
    final smoothScore = ((smooth / steps - 0.85) / 0.15).clamp(0.0, 1.0);
    final centre = (fLo + fHi) / 2;
    var travel = 0.0;
    for (var i = 1; i < tr.length; i++) {
      travel += (tr[i] - tr[i - 1]).abs();
    }
    final speed = travel / dur;
    if (debug) debugClass = 'n=${w.length} span=${span.round()} rev=$reversals rate=${rate.toStringAsFixed(2)} smooth=${(smooth / steps).toStringAsFixed(2)}';

    // Robust spread (interquartile range / median / 1.35, about the coefficient of variation; a
    // stray turning point picked in a gust does not count).
    double cvOf(List<double> v) {
      if (v.length < 4) return 0;
      final s = [...v]..sort();
      final m = s[s.length ~/ 2];
      if (m.abs() < 1e-9) return 0;
      return (s[(s.length * 3) ~/ 4] - s[s.length ~/ 4]) / m.abs() / 1.35;
    }

    if (span >= 300 && rate >= 2.5 && rate <= 12) {
      // Yelp: regular half cycles and steady turning points (singing and melisma wander).
      final halves = [for (var i = 1; i < turnT.length; i++) turnT[i] - turnT[i - 1]];
      final tops = [for (var i = 0; i < turnF.length; i++) if (turnUp[i]) turnF[i]];
      final bottoms = [for (var i = 0; i < turnF.length; i++) if (!turnUp[i]) turnF[i]];
      final halfCv = cvOf(halves);
      final topCv = cvOf(tops), bottomCv = cvOf(bottoms);
      // (above ~5 cycles/s a half cycle is only a few 20 ms frames: its length is not measurable)
      final halfLimit = rate > 5 ? double.infinity : 0.35;
      if (halfCv > halfLimit || topCv > 0.1 || bottomCv > 0.12) {
        if (debug) debugClass = '$debugClass irregular yelp half=${halfCv.toStringAsFixed(2)} top=${topCv.toStringAsFixed(2)} bot=${bottomCv.toStringAsFixed(2)}';
        return null;
      }
      final regularity = (1.0 - (rate > 5 ? topCv / 0.1 : halfCv / halfLimit)).clamp(0.0, 1.0);
      // Doppler: the turning points in the first vs the second half.
      final mid = (w.first.t + w.last.t) / 2;
      double meanTurn(bool first, bool up) {
        var s = 0.0, m = 0;
        for (var i = 0; i < turnF.length; i++) {
          if ((turnT[i] < mid) != first || turnUp[i] != up) continue;
          s += turnF[i];
          m++;
        }
        return m == 0 ? 0 : s / m;
      }

      final a = meanTurn(true, true) + meanTurn(true, false), b = meanTurn(false, true) + meanTurn(false, false);
      final drop = a > 0 && b > 0 && meanTurn(true, true) > 0 && meanTurn(false, true) > 0 && meanTurn(true, false) > 0 && meanTurn(false, false) > 0
          ? (a - b) / a
          : 0.0;
      return _Classification(SirenPattern.yelp, 0.55 + 0.15 * cover + 0.15 * snrScore + 0.15 * (0.5 * smoothScore + 0.5 * regularity), centre,
          snrMed,
          rate: rate, speedHzPerSec: speed, regularity: regularity, dopplerDrop: drop);
    }
    if (span >= 350 && rate <= 1.2 && fLo >= 360 && fHi <= 2200 && speed >= 80 && speed <= 3000) {
      // Wail: each half cycle is a mostly one-way sweep of >= 0.8 s (a 2-10 s cycle).
      final bounds = [w.first.t, ...turnT, w.last.t];
      for (var i = 1; i < bounds.length - 1; i++) {
        if (bounds[i + 1] - bounds[i] < 0.8 && i + 1 < bounds.length - 1) {
          if (debug) debugClass = '$debugClass short half cycle';
          return null;
        }
      }
      var along = 0, moved = 0;
      var segDir = tr.length > 1 && tr[1] >= tr[0] ? 1 : -1;
      var ti = 0;
      for (var i = 1; i < tr.length; i++) {
        while (ti < turnT.length && w[i].t > turnT[ti]) {
          segDir = turnUp[ti] ? -1 : 1;
          ti++;
        }
        final d = tr[i] - tr[i - 1];
        if (d.abs() < 2) continue;
        moved++;
        if ((d > 0 ? 1 : -1) == segDir) along++;
      }
      final mono = moved == 0 ? 0.0 : along / moved;
      if (mono < 0.75) {
        if (debug) debugClass = '$debugClass wandering ${mono.toStringAsFixed(2)}';
        return null;
      }
      return _Classification(SirenPattern.wail, 0.55 + 0.15 * cover + 0.15 * snrScore + 0.15 * smoothScore, centre, snrMed,
          rate: rate, speedHzPerSec: speed, regularity: ((mono - 0.75) / 0.25).clamp(0.0, 1.0));
    }
    // Other smooth sweeps (1.2-2.5 cycles/s) are NOT reported: speech intonation looks like that.
    if (debug) debugClass = '$debugClass nomatch';
    return null;
  }

  // ------------------------------------------------------------------ kind
  /// The kind of vehicle, from the pattern mix of this episode (see the file header).
  (EmergencyVehicleKind, double) _kind(_Classification cls, double snr) {
    var nWail = 0, nYelp = 0, nHiLo = 0;
    final dwells = <double>[];
    final ratios = <double>[];
    final wailCentres = <double>[];
    final wailSpeeds = <double>[];
    for (final e in _episodeEvals) {
      switch (e.$2.pattern) {
        case SirenPattern.wail:
          nWail++;
          wailCentres.add(e.$2.centreHz);
          wailSpeeds.add(e.$2.speedHzPerSec);
        case SirenPattern.yelp:
          nYelp++;
        case SirenPattern.hiLo:
          nHiLo++;
          if (e.$2.dwellSec > 0) dwells.add(e.$2.dwellSec);
          ratios.add(e.$2.ratio);
        case SirenPattern.unknown:
          break;
      }
    }
    final total = nWail + nYelp + nHiLo;
    if (total == 0) return (EmergencyVehicleKind.unknown, 0);
    double median(List<double> v) {
      if (v.isEmpty) return 0;
      final s = [...v]..sort();
      return s[s.length ~/ 2];
    }

    final evidence = math.min(1.0, total / 10.0); // more evaluations, more sure
    final weak = snr < 12 ? 0.06 : 0.0;
    EmergencyVehicleKind kind;
    double conf;
    if (nWail >= 3 && nYelp >= 3) {
      // Wail / yelp switching ("wail-yelp"): police.
      kind = EmergencyVehicleKind.police;
      conf = 0.9;
    } else if (nHiLo >= 3 && nYelp >= 3) {
      kind = EmergencyVehicleKind.police;
      conf = 0.82;
    } else if (nHiLo >= 3 && nWail >= 3) {
      // Hi-lo / wail switching: typical of Indian ambulances.
      kind = EmergencyVehicleKind.ambulance;
      conf = 0.85;
    } else if (nHiLo >= 0.7 * total) {
      final dwell = median(dwells);
      final ratio = median(ratios);
      if (dwell > 0 && dwell < 0.33) {
        kind = EmergencyVehicleKind.police; // fast hi-lo / "hi-lo yelp"
        conf = 0.72 + 0.1 * evidence;
      } else if (ratio >= 1.18 && ratio <= 1.6) {
        // (a narrower two-tone, ratio ~1.12 like the French police "pin-pon", stays generic)
        kind = EmergencyVehicleKind.ambulance;
        conf = 0.72 + 0.1 * evidence + 0.08 * cls.regularity;
      } else {
        kind = EmergencyVehicleKind.unknown;
        conf = 0;
      }
    } else if (nYelp >= 0.7 * total) {
      kind = EmergencyVehicleKind.police;
      conf = 0.78 + 0.1 * evidence;
    } else if (nWail >= 0.7 * total) {
      final centre = median(wailCentres);
      final speed = median(wailSpeeds);
      if (centre < 850 && speed < 700) {
        kind = EmergencyVehicleKind.fire; // low, slow mechanical wail
        conf = 0.78 + 0.1 * evidence;
      } else {
        kind = EmergencyVehicleKind.unknown; // electronic wail: all services use it
        conf = 0;
      }
    } else {
      kind = EmergencyVehicleKind.unknown;
      conf = 0;
    }
    if (kind == EmergencyVehicleKind.unknown) return (kind, 0);
    return (kind, (conf - weak).clamp(0.0, 1.0));
  }

  // ------------------------------------------------------------------ observation
  SirenObservation _observe(_Classification cls) {
    final runStart = _runStart() ?? _t;
    // Loudness trend over the current run, at most the last 5 s (long enough to span a whole wail
    // cycle, so the siren's own frequency-dependent loudness averages out).
    final from = math.max(_t - 5.0, runStart - 1e-6);
    var n = 0;
    var st = 0.0, sl = 0.0, stt = 0.0, stl = 0.0;
    var tMin = double.infinity;
    for (final fr in _hist) {
      if (!fr.tonal || fr.t <= from) continue;
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
    // (needs >= 2 s of tonal frames spread over >= 4 s, about a whole wail cycle; until then the
    // trend is unknown and not spoken)
    if (_t - tMin < 4.0) n = 0;
    final doppler = cls.pattern == SirenPattern.wail ? 0.0 : cls.dopplerDrop;
    SirenTrend trend;
    if (n >= 100 && (slope <= -1.0 || (doppler >= 0.03 && slope <= 0.3))) {
      trend = SirenTrend.movingAway;
    } else if (n >= 100 && slope >= 1.0) {
      trend = SirenTrend.approaching;
    } else if (n >= 100) {
      trend = SirenTrend.steady;
    } else {
      trend = SirenTrend.unknown;
    }
    final recent = _hist.where((f) => f.tonal && f.t > _t - 1.0).map((f) => f.snrDb).toList()..sort();
    final snr = recent.isEmpty ? cls.snrDb : recent[recent.length ~/ 2];
    final nearness = snr >= veryNearSnrDb ? SoundNearness.veryNear : (snr >= nearSnrDb ? SoundNearness.near : SoundNearness.far);
    final (kind, kindConf) = _kind(cls, snr);
    final conf = cls.confidence.clamp(0.0, 1.0);
    return SirenObservation(
      timeSec: _t,
      pattern: cls.pattern,
      kind: kind,
      kindConfident: kind != EmergencyVehicleKind.unknown && kindConf >= kindSayConfidence,
      confidence: conf,
      kindConfidence: kindConf,
      trend: trend,
      nearness: nearness,
      snrDb: snr,
      centreHz: cls.centreHz,
      levelSlopeDbPerSec: slope,
      continuousSec: _t - runStart,
    );
  }
}
