// 3.55 intercom voice cleanup (lib/domain/audio/voice_cleanup.dart): breath and wind are taken
// out, voiced speech is kept, the hands-free gate opens on voice only. Synthesised signals,
// 20 ms blocks exactly as the ride mic hub sends them. Measured numbers:
// docs/features_355/sound_awareness_and_intercom.md.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/audio/dsp_core.dart';
import 'package:coroute_app/domain/audio/voice_cleanup.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';

import 'support/audio_synth_355.dart';

double _segDb(Float64List x, double a, double b) {
  final i0 = (a * fs).round(), i1 = math.min(x.length, (b * fs).round());
  var e = 0.0;
  for (var i = i0; i < i1; i++) {
    e += x[i] * x[i];
  }
  return 10 * math.log(e / (i1 - i0) + 1e-20) / math.ln10;
}

class _Out {
  final Float64List out;
  final List<bool> gate;
  _Out(this.out, this.gate);
  int gateFrames(double a, double b) {
    var c = 0;
    for (var f = (a / 0.02).round(); f < math.min(gate.length, (b / 0.02).round()); f++) {
      if (gate[f]) c++;
    }
    return c;
  }
}

_Out _clean(Float64List x, VoiceCleanup c) {
  final out = Float64List(x.length);
  final gate = <bool>[];
  for (var i = 0; i + 320 <= x.length; i += 320) {
    out.setRange(i, i + 320, c.process(Float64List.sublistView(x, i, i + 320)));
    gate.add(c.gateOpen);
  }
  return _Out(out, gate);
}

/// 0-1 hiss, 1-3 voice (140 Hz), 3-5 breath, 5-6 voice (210 Hz), 6-8 wind gusts, 8-9 speech,
/// 9-11 loud breath, 11-12 hiss.
Float64List _timeline() {
  final s = Synth(3);
  const total = 12.0;
  return mix([
    s.noise(total, amp: 0.002),
    place(s.vowel(2, amp: 0.08, f0: 140), 1, total),
    place(s.breath(2, amp: 0.05), 3, total),
    place(s.vowel(1, amp: 0.08, f0: 210), 5, total),
    place(s.wind(2, amp: 0.25), 6, total),
    place(s.speech(1, amp: 0.08, f0: 120), 8, total),
    place(s.breath(2, amp: 0.12), 9, total),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('3.55 voice cleanup, hands-free (strict gate), AGC off', () {
    final x = _timeline();
    final r = _clean(x, VoiceCleanup(handsFree: true, agc: false));
    double change(double a, double b) => _segDb(r.out, a + 0.008, b + 0.008) - _segDb(x, a, b);

    test('voiced speech is kept within 2 dB', () {
      expect(change(1.2, 3).abs(), lessThan(2.0));
      expect(change(5.1, 6).abs(), lessThan(2.0));
      expect(change(8, 9).abs(), lessThan(2.0));
    });
    test('breath is attenuated by at least 15 dB', () {
      expect(change(3.6, 5), lessThan(-15.0));
      expect(change(9.6, 11), lessThan(-15.0));
    });
    test('wind gusts are attenuated by at least 15 dB', () {
      expect(change(6.6, 8), lessThan(-15.0));
    });
    test('the gate opens on voice, never on breath or wind alone', () {
      expect(r.gateFrames(1, 3), greaterThanOrEqualTo(90)); // of 100
      expect(r.gateFrames(5, 6), greaterThanOrEqualTo(45)); // of 50
      expect(r.gateFrames(8, 9), greaterThanOrEqualTo(40)); // of 50 (syllables with gaps)
      expect(r.gateFrames(3.6, 5), 0);
      expect(r.gateFrames(6.6, 8), 0);
      expect(r.gateFrames(9.6, 11), 0);
      expect(r.gateFrames(0, 1), 0);
    });
  });

  group('3.55 voice cleanup, push-to-talk (soft gate)', () {
    final x = _timeline();
    final r = _clean(x, VoiceCleanup(handsFree: false, agc: false));
    double change(double a, double b) => _segDb(r.out, a + 0.008, b + 0.008) - _segDb(x, a, b);
    test('voice kept, breath and wind still at least 15 dB down', () {
      expect(change(1.2, 3).abs(), lessThan(2.0));
      expect(change(3.6, 5), lessThan(-15.0));
      expect(change(6.6, 8), lessThan(-15.0));
    });
  });

  group('3.55 noise suppression, AGC, limiter, latency', () {
    test('steady riding noise is reduced by >= 15 dB while clean speech stays within 2 dB', () {
      const total = 8.0;
      final s = Synth(9);
      final bg = mix([s.wind(total, amp: 0.12), s.engine(total, amp: 0.02), s.noise(total, amp: 0.003)], clip: false);
      final v = place(s.speech(4, amp: 0.06, f0: 125), 3, total);
      final outBg = _clean(bg, VoiceCleanup(agc: false, gate: false)).out;
      final outV = _clean(v, VoiceCleanup(agc: false, gate: false)).out;
      expect(_segDb(outBg, 3, 7) - _segDb(bg, 3, 7), lessThan(-15.0));
      expect((_segDb(outV, 3, 7) - _segDb(v, 3, 7)).abs(), lessThan(2.0));
    });

    test('a word said the instant the mic opens is not taken for noise', () {
      final s = Synth(6);
      final v = mix([s.noise(3, amp: 0.002), s.speech(3, amp: 0.06, f0: 130)]);
      final r = _clean(v, VoiceCleanup(agc: false));
      expect((_segDb(r.out, 0.1, 1.0) - _segDb(v, 0.1, 1.0)).abs(), lessThan(3.0));
      expect(r.gateFrames(0, 1), greaterThanOrEqualTo(35)); // of 50
    });

    test('quiet speaker is raised by the AGC (toward -20 dBFS)', () {
      final s = Synth(2);
      const total = 6.0;
      final v = mix([s.noise(total, amp: 0.0005), place(s.speech(5, amp: 0.01, f0: 150), 1, total)]); // speech at -40 dBFS
      final out = _clean(v, VoiceCleanup()).out;
      expect(_segDb(out, 4, 6) - _segDb(v, 4, 6), greaterThan(10.0));
    });

    test('a shout never clips (limiter at -1 dBFS)', () {
      final s = Synth(2);
      final v = s.vowel(2, amp: 0.7, f0: 150);
      final out = _clean(v, VoiceCleanup()).out;
      var peak = 0.0;
      for (final y in out) {
        peak = math.max(peak, y.abs());
      }
      expect(peak, lessThanOrEqualTo(0.9));
    });

    test('added latency is 12 ms (128-sample STFT + 64-sample block alignment), under 30 ms', () {
      final x = Float64List(16000);
      x[4000] = 0.5;
      final out = _clean(x, VoiceCleanup(agc: false, gate: false, suppressNoise: false)).out;
      var best = 0;
      for (var i = 0; i < out.length; i++) {
        if (out[i].abs() > out[best].abs()) best = i;
      }
      expect(best - 4000, inInclusiveRange(120, 200));
    });

    test('playback limiter keeps a loud rider under 0.8 full scale', () {
      final lim = PeakLimiter(ceiling: 0.8, releaseDbPerSecond: 6);
      final loud = Float64List(320);
      for (var i = 0; i < 320; i++) {
        loud[i] = 0.99 * math.sin(2 * math.pi * 440 * i / 16000);
      }
      final pcm = floatToPcm16Bytes(loud);
      final out = pcm16BytesToFloat(lim.processPcm16(pcm));
      expect(out.map((v) => v.abs()).reduce(math.max), lessThanOrEqualTo(0.8 + 1e-3));
    });

    test('data saver 2:1 decimator keeps speech band, removes 6 kHz', () {
      Float64List tone(double f) {
        final x = Float64List(16000);
        for (var i = 0; i < x.length; i++) {
          x[i] = 0.5 * math.sin(2 * math.pi * f * i / 16000);
        }
        return x;
      }

      final pass = Decimator2().process(tone(1000));
      final stop = Decimator2().process(tone(6000));
      expect(pass.length, 8000);
      expect(rmsOf(Float64List.sublistView(pass, 100)), greaterThan(0.3));
      expect(ampDb(rmsOf(Float64List.sublistView(stop, 100)) / 0.3535), lessThan(-30.0));
    });
  });

  group('3.55 intercom public actions', () {
    test('toggleGroupMute flips hearing the group', () {
      final ic = IntercomService(RealtimeService());
      expect(ic.toggleGroupMute(), isTrue);
      expect(ic.isDeafened, isTrue);
      expect(ic.toggleGroupMute(), isFalse);
      expect(ic.isDeafened, isFalse);
      ic.dispose();
    });

    test('toggleHandsFreeTalk offline stays off (no mic opened)', () async {
      final ic = IntercomService(RealtimeService());
      expect(await ic.toggleHandsFreeTalk(), isFalse);
      expect(ic.isVoxArmed, isFalse);
      expect(ic.mode, IntercomMode.ptt);
      ic.dispose();
    });

    test('voice cleanup follows the admin switch (unknown = on)', () {
      final ic = IntercomService(RealtimeService());
      expect(ic.voiceCleanupOn, isTrue);
      ic.featureOn = (id) => id != 'voiceCleanup';
      expect(ic.voiceCleanupOn, isFalse);
      ic.dispose();
    });
  });
}
