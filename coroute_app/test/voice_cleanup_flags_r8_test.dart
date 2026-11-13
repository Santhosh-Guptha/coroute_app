// Round 8: the VoiceCleanup switches used with the native RNNoise stage (pure Dart; tool/pure_dart_test/run.sh).
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:coroute_app/domain/audio/voice_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';

/// Wind-like rumble: white noise through a one-pole low-pass at ~60 Hz, about -20 dBFS.
Float64List rumble(int n, int seed) {
  final r = math.Random(seed);
  final out = Float64List(n);
  var lp = 0.0;
  for (var i = 0; i < n; i++) {
    lp += 0.024 * ((r.nextDouble() * 2 - 1) - lp);
    out[i] = lp * 2.2;
  }
  return out;
}

double rms(Float64List x, [int from = 0]) {
  var e = 0.0;
  for (var i = from; i < x.length; i++) {
    e += x[i] * x[i];
  }
  return math.sqrt(e / (x.length - from));
}

void main() {
  test('windSuppression: off = the 20 ms wind class never fires (the native ducker does that job)', () {
    final on = VoiceCleanup(handsFree: false, agc: false, gate: false);
    final off = VoiceCleanup(handsFree: false, agc: false, gate: false, windSuppression: false);
    final x = rumble(16000, 7);
    var windOn = 0, windOff = 0;
    for (var i = 0; i + 320 <= x.length; i += 320) {
      on.process(Float64List.sublistView(x, i, i + 320));
      off.process(Float64List.sublistView(x, i, i + 320));
      if (on.last.wind) windOn++;
      if (off.last.wind) windOff++;
    }
    expect(windOn, greaterThan(10));
    expect(windOff, 0);
  });

  test('spectralSuppression: off = no Wiener stage (steady noise passes the 140 Hz high-pass untouched)', () {
    final r = math.Random(3);
    final hiss = Float64List.fromList(List.generate(32000, (_) => (r.nextDouble() * 2 - 1) * 0.05));
    final wiener = VoiceCleanup(handsFree: false, agc: false, gate: false);
    final none = VoiceCleanup(handsFree: false, agc: false, gate: false, spectralSuppression: false, windSuppression: false);
    final a = Float64List(hiss.length), b = Float64List(hiss.length);
    for (var i = 0; i + 320 <= hiss.length; i += 320) {
      a.setRange(i, i + 320, wiener.process(Float64List.sublistView(hiss, i, i + 320)));
      b.setRange(i, i + 320, none.process(Float64List.sublistView(hiss, i, i + 320)));
    }
    final inDb = 20 * math.log(rms(hiss, 16000)) / math.ln10;
    final wDb = 20 * math.log(rms(a, 16000)) / math.ln10;
    final nDb = 20 * math.log(rms(b, 16000)) / math.ln10;
    expect(inDb - wDb, greaterThan(8), reason: 'the Wiener stage cuts steady hiss');
    expect((inDb - nDb).abs(), lessThan(1.5), reason: 'without it the hiss stays (RNNoise did the job before)');
  });
}
