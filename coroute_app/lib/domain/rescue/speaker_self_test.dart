// Round 10 rescue beacon: which near-ultrasonic band THIS phone's speaker can play (pure Dart).
//
// At ride start (at most once every 30 days per phone, and only when the ride mic is already open
// for siren alerts) the phone plays a quiet test: 250 ms of the high-band tone, 150 ms pause,
// 250 ms of the low-band tone, at the locator's own level (media stream, the rider's media volume),
// and listens with its own mic at 48 kHz for about 1.5 s.
// Most adults hear neither tone; at this level nobody nearby is bothered.
//
// Result (the rescue lab showed the low band carries FARTHER: less air absorption and less speaker
// roll-off at 15 kHz than at 18.6 kHz, so a phone that plays both keeps both):
//  * both bands heard: both, alternating (best range; a packet in each band every 2 s);
//  * only the high band heard: high only;
//  * only the low band heard: low only (an older or cheaper speaker that rolls off at ~17 kHz);
//  * nothing measurable (mic and speaker far apart, covered, noisy, a mic with its own low-pass):
//    both bands, so whichever works on the day reaches the rescuers.
import 'dart:math' as math;

import 'rescue_acoustics.dart';

class SpeakerSelfTestResult {
  final BeaconBandMode mode;

  /// Tone level over the quiet reference (dB); null when not measurable.
  final double? highDb;
  final double? lowDb;

  const SpeakerSelfTestResult(this.mode, {this.highDb, this.lowDb});

  Map<String, Object?> toLog() => {'mode': mode.name, 'highDb': highDb?.toStringAsFixed(1), 'lowDb': lowDb?.toStringAsFixed(1)};
}

class SpeakerSelfTest {
  SpeakerSelfTest._();

  static const double minResponseDb = 12;
  static const double toneS = 0.25;
  static const double pauseS = 0.15;
  static const double leadInS = 0.30; // quiet reference before the first tone

  static double get highHz => BeaconBandSpec.high.tones[2];
  static double get lowHz => BeaconBandSpec.low.tones[2];

  /// The test sound (the caller plays it [leadInS] after the capture started).
  static List<double> testSignal(int sampleRate, {double peak = RescueSynth.beaconPeak}) {
    final tone = (toneS * sampleRate).round();
    final pause = (pauseS * sampleRate).round();
    final ramp = (0.01 * sampleRate).round();
    final out = List<double>.filled(2 * tone + pause, 0);
    void put(int start, double f) {
      for (var i = 0; i < tone; i++) {
        var env = 1.0;
        if (i < ramp) env = i / ramp;
        if (i > tone - ramp) env = (tone - i) / ramp;
        out[start + i] = peak * env * math.sin(2 * math.pi * f * i / sampleRate);
      }
    }

    put(0, highHz);
    put(tone + pause, lowHz);
    return out;
  }

  static double _goertzel(List<double> x, int from, int to, double f, int sampleRate) {
    from = from.clamp(0, x.length);
    to = to.clamp(from, x.length);
    final c = 2 * math.cos(2 * math.pi * f / sampleRate);
    var s1 = 0.0, s2 = 0.0;
    for (var i = from; i < to; i++) {
      final s0 = x[i] + c * s1 - s2;
      s2 = s1;
      s1 = s0;
    }
    final n = math.max(1, to - from);
    return (s1 * s1 + s2 * s2 - c * s1 * s2) / (n * n);
  }

  /// Analyses [captured] (mic samples, -1..1) that contain the test signal somewhere (speaker and
  /// mic latency vary by phone, so no fixed offset is assumed): per 20 ms block, the power at each
  /// test frequency; the response is the strongest block over the median block (the quiet parts).
  /// Captures shorter than the test give "both".
  static SpeakerSelfTestResult analyse(List<double> captured, int sampleRate) {
    final block = (0.02 * sampleRate).round();
    final need = ((2 * toneS + pauseS) * sampleRate).round();
    if (captured.length < need + block * 4) return const SpeakerSelfTestResult(BeaconBandMode.both);
    double response(double f) {
      final p = <double>[];
      for (var i = 0; i + block <= captured.length; i += block) {
        p.add(_goertzel(captured, i, i + block, f, sampleRate));
      }
      final sorted = [...p]..sort();
      final median = sorted[sorted.length ~/ 2];
      const eps = 1e-14;
      return 10 * math.log((sorted.last + eps) / (median + eps)) / math.ln10;
    }

    final hiDb = response(highHz);
    final loDb = response(lowHz);
    final hiOk = hiDb >= minResponseDb, loOk = loDb >= minResponseDb;
    final mode = hiOk && !loOk ? BeaconBandMode.high : (loOk && !hiOk ? BeaconBandMode.low : BeaconBandMode.both);
    return SpeakerSelfTestResult(mode, highDb: hiDb, lowDb: loDb);
  }

  /// A stored result older than this is tested again (speakers age, cases change).
  static const Duration maxAge = Duration(days: 30);
}
