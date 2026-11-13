// Round 10 rescue beacon: the sound the victim's phone plays (pure Dart, no Flutter).
//
// Two parts, mixed into one PCM stream for the phone's ALARM stream:
//
// 1. The audible SIREN: a modulated sweep between 2 and 4 kHz (where small phone speakers are
//    loudest and the human ear is most sensitive, and where the ear localises sound well from
//    level differences between the ears). A sine plus a small third harmonic (6..12 kHz) for
//    "edge" on tiny speakers; no clipping, so nothing lands in the beacon bands above 14 kHz.
//    It escalates: level and sweep rate rise over the first two minutes.
//
// 2. The near-ultrasonic LOCATOR packet: 4-FSK, 16 symbols of 40 ms tone + 10 ms gap (800 ms):
//      4 sync symbols  [3, 0, 2, 1]   (all four tones: a steady insect / whistle tone can never match)
//      12 data symbols 24 bits = rescue id (16) + CRC-8 of the id (8), 2 bits per symbol, MSB first.
//    Each tone has 4 ms raised-cosine edges: an abrupt start or stop of a high tone makes an
//    audible click, which is exactly what a near-ultrasonic signal must not do.
//    Bands (see [BeaconBand]):
//      high 17.8 / 18.2 / 18.6 / 19.0 kHz  (inaudible to most adults, plays on most phones)
//      low  14.4 / 14.8 / 15.2 / 15.6 kHz  (fallback for speakers that roll off above ~17 kHz)
//    The packet peak is capped at [beaconPeak] (-13 dBFS), always well below the siren.
//
// The same generator feeds the app (RescueBeaconService) and the lab (tool/rescue_lab/), so the
// lab measures exactly what the phone plays.
import 'dart:math' as math;
import 'dart:typed_data';

import 'rescue_id.dart';

/// Which near-ultrasonic band a packet uses.
enum BeaconBand { high, low }

/// What the phone plays for the locator: decided by the speaker self-test at ride start.
enum BeaconBandMode {
  high,
  low,

  /// Unknown speaker response: alternate high and low packets.
  both;

  List<BeaconBand> get bands => switch (this) {
        BeaconBandMode.high => const [BeaconBand.high],
        BeaconBandMode.low => const [BeaconBand.low],
        BeaconBandMode.both => const [BeaconBand.high, BeaconBand.low],
      };

  static BeaconBandMode fromName(String? s) =>
      BeaconBandMode.values.firstWhere((m) => m.name == s, orElse: () => BeaconBandMode.both);
}

class BeaconBandSpec {
  /// The four FSK tones (Hz), symbol value 0..3.
  final List<double> tones;

  /// Reference frequencies between and beside the tones (Hz): the noise floor for the SNR.
  final List<double> noiseRefs;

  const BeaconBandSpec(this.tones, this.noiseRefs);

  static const BeaconBandSpec high = BeaconBandSpec(
    [17800, 18200, 18600, 19000],
    [17600, 18000, 18400, 18800, 19200],
  );
  static const BeaconBandSpec low = BeaconBandSpec(
    [14400, 14800, 15200, 15600],
    [14200, 14600, 15000, 15400, 15800],
  );

  static BeaconBandSpec of(BeaconBand b) => b == BeaconBand.high ? high : low;
}

/// The packet layout and timing, shared by the synthesiser and the detector.
class BeaconFormat {
  BeaconFormat._();

  static const List<int> sync = [3, 0, 2, 1];
  static const int dataSymbols = 12;
  static const int symbols = 16; // sync + data
  static const double toneS = 0.040;
  static const double gapS = 0.010;
  static const double symbolS = toneS + gapS;
  static const double packetS = symbols * symbolS; // 0.8 s
  static const double rampS = 0.004;

  /// One packet every [packetIntervalS] (with two bands: high at 0 s, low at 1 s).
  static const double packetIntervalS = 2.0;

  /// The 16 symbol values of a packet for [id] (1..65535).
  static List<int> symbolsFor(int id) {
    final bits = ((id & 0xFFFF) << 8) | RescueId.crc8(id & 0xFFFF); // 24 bits
    return [
      ...sync,
      for (var i = dataSymbols - 1; i >= 0; i--) (bits >> (2 * i)) & 0x3,
    ];
  }

  /// The id carried by 12 data symbols, or null when the CRC does not match.
  static int? idFromData(List<int> data) {
    if (data.length != dataSymbols) return null;
    var bits = 0;
    for (final s in data) {
      bits = (bits << 2) | (s & 0x3);
    }
    final id = (bits >> 8) & 0xFFFF;
    final crc = bits & 0xFF;
    if (id == 0 || RescueId.crc8(id) != crc) return null;
    return id;
  }
}

/// Generates the siren and the locator packets as float samples (-1..1).
class RescueSynth {
  RescueSynth({this.sampleRate = 48000});

  final int sampleRate;

  /// Locator packet peak (-13 dBFS). The siren peak is at least 0.35 (-9 dBFS) and rises to
  /// [sirenPeakMax]; together they never exceed full scale.
  static const double beaconPeak = 0.22;
  static const double sirenPeakMax = 0.78;

  /// One locator packet ([BeaconFormat.packetS] long).
  Float64List packet(int id, BeaconBand band, {double peak = beaconPeak}) {
    final spec = BeaconBandSpec.of(band);
    final sym = BeaconFormat.symbolsFor(id);
    final n = (BeaconFormat.packetS * sampleRate).round();
    final out = Float64List(n);
    final tone = (BeaconFormat.toneS * sampleRate).round();
    final ramp = math.max(1, (BeaconFormat.rampS * sampleRate).round());
    for (var k = 0; k < sym.length; k++) {
      final start = (k * BeaconFormat.symbolS * sampleRate).round();
      final w = 2 * math.pi * spec.tones[sym[k]] / sampleRate;
      for (var i = 0; i < tone && start + i < n; i++) {
        var env = 1.0;
        if (i < ramp) {
          env = 0.5 - 0.5 * math.cos(math.pi * i / ramp);
        } else if (i >= tone - ramp) {
          env = 0.5 - 0.5 * math.cos(math.pi * (tone - 1 - i) / ramp);
        }
        out[start + i] = peak * env * math.sin(w * i);
      }
    }
    return out;
  }

  /// The siren: a sweep 2..4 kHz and back every [sweepPeriodS], peak [level] (0..[sirenPeakMax]).
  /// [phaseOffsetS] keeps consecutive chunks continuous. 20 ms fades at both ends.
  Float64List siren(double seconds, {required double level, required double sweepPeriodS, double phaseOffsetS = 0}) {
    final n = (seconds * sampleRate).round();
    final out = Float64List(n);
    final peak = level.clamp(0.0, sirenPeakMax);
    const fLo = 2000.0, fHi = 4000.0;
    final period = sweepPeriodS.clamp(0.15, 4.0);
    final fade = math.min(n ~/ 2, (0.02 * sampleRate).round());
    var phase = 0.0;
    // Normalised so that sin + 0.25 sin(3x) (= 1.75 s - s^3, max 0.8911 at s = 0.764) peaks at [peak].
    const norm = 1 / 0.8912;
    for (var i = 0; i < n; i++) {
      final t = phaseOffsetS + i / sampleRate;
      // Triangle sweep up and down (a "yelp" when fast, a "wail" when slow).
      final p = (t / period) % 1.0;
      final tri = p < 0.5 ? p * 2 : (1 - p) * 2;
      final f = fLo + (fHi - fLo) * tri;
      phase += 2 * math.pi * f / sampleRate;
      if (phase > 2 * math.pi * 1000) phase -= 2 * math.pi * 1000;
      var v = (math.sin(phase) + 0.25 * math.sin(3 * phase)) * norm;
      if (i < fade) v *= i / fade;
      if (i >= n - fade) v *= (n - 1 - i) / fade;
      out[i] = peak * v;
    }
    return out;
  }

  /// A full audio segment: [seconds] long; the siren when [sirenLevel] > 0, locator packets every
  /// [BeaconFormat.packetIntervalS] (alternating bands when [bands] has two) starting at
  /// [firstPacketAtS]. Packets that would not fit are left out.
  Float64List segment({
    required double seconds,
    required int rescueId,
    double sirenLevel = 0,
    double sweepPeriodS = 1.0,
    List<BeaconBand> bands = const [BeaconBand.high],
    double firstPacketAtS = 0.1,
    int bandOffset = 0,
  }) {
    final n = (seconds * sampleRate).round();
    final out = sirenLevel > 0 ? siren(seconds, level: sirenLevel, sweepPeriodS: sweepPeriodS) : Float64List(n);
    if (rescueId > 0 && bands.isNotEmpty) {
      final step = bands.length == 1 ? BeaconFormat.packetIntervalS : BeaconFormat.packetIntervalS / 2;
      var k = 0;
      for (var t = firstPacketAtS; t + BeaconFormat.packetS <= seconds + 1e-9; t += step, k++) {
        final p = packet(rescueId, bands[(k + bandOffset) % bands.length]);
        final start = (t * sampleRate).round();
        for (var i = 0; i < p.length && start + i < n; i++) {
          out[start + i] += p[i];
        }
      }
    }
    return out;
  }

  /// Float (-1..1) to PCM16 with a hard limit (the mix never exceeds 1.0 by design).
  static Int16List toPcm16(Float64List x) {
    final out = Int16List(x.length);
    for (var i = 0; i < x.length; i++) {
      final v = x[i].clamp(-1.0, 1.0);
      out[i] = (v * 32767).round();
    }
    return out;
  }
}
