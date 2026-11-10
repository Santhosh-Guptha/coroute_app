// 3.55 sound awareness: emergency-vehicle siren detection on synthesised ride audio (horn alerts
// were removed). The engine is pure Dart (lib/domain/audio/sound_awareness_engine.dart); these
// tests feed it 20 ms frames exactly as the RideMicHub does, over a riding background (engine
// drone + wind + mic hiss, about -26 dBFS). Measured numbers:
// docs/features_355/sound_awareness_and_intercom.md (the engine groups also pass under a
// plain-`dart` harness; the SirenAcousticDetector group needs the Flutter test runner).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/audio/sound_awareness_engine.dart';

import 'support/audio_synth_355.dart';
// ---- FLUTTER ONLY BEGIN (imports)
import 'package:record/record.dart' show InputDevice, InputDeviceType;
import 'package:coroute_app/domain/audio/sound_alert_policy.dart';
import 'package:coroute_app/data/services/ride_mic_hub.dart';
import 'package:coroute_app/data/services/siren_acoustic_detector.dart';
// ---- FLUTTER ONLY END

class _Run {
  final List<SirenAlert> alerts = [];
  final List<SirenObservation> observations = [];
  SirenObservation? get first => alerts.isEmpty ? null : alerts.first.observation;
  SirenObservation? get last => observations.isEmpty ? null : observations.last;
}

_Run _run(Float64List x, {bool Function(double t)? suppressAt}) {
  final e = SoundAwarenessEngine();
  final r = _Run();
  for (var i = 0; i + 320 <= x.length; i += 320) {
    if (suppressAt != null) e.suppress = suppressAt(i / 16000);
    final u = e.process(Float64List.sublistView(x, i, i + 320));
    if (u.sirenAlert != null) r.alerts.add(u.sirenAlert!);
    if (u.siren != null) r.observations.add(u.siren!);
  }
  return r;
}

void main() {
  const sec = 12.0;
  const start = 2.0; // every siren starts 2 s into the ride audio

  group('3.55 sirens: continuous siren -> one alert with the kind', () {
    // (signal, pattern, kind said at the end of the episode, max detection delay)
    // A null kind: a weak siren may stay generic (the kind is said only when confident).
    final cases = <String, (Float64List Function(Synth s), SirenPattern?, EmergencyVehicleKind?, double)>{
      'ambulance hi-lo 960/770 Hz, 0.5 s (EU / India)': ((s) => s.hiLo(9, amp: 0.02), SirenPattern.hiLo, EmergencyVehicleKind.ambulance, 3.5),
      'ambulance hi-lo 1050/700 Hz, 0.7 s (India)': ((s) => s.hiLo(9, amp: 0.02, hi: 1050, lo: 700, dwell: 0.7), SirenPattern.hiLo, EmergencyVehicleKind.ambulance, 3.5),
      'two-tone 410/550 Hz, 0.6 s (DE-style)': ((s) => s.hiLo(9, amp: 0.03, hi: 550, lo: 410, dwell: 0.6), SirenPattern.hiLo, EmergencyVehicleKind.ambulance, 3.5),
      'narrow two-tone 435/488 Hz (FR police "pin-pon"): generic': ((s) => s.hiLo(9, amp: 0.03, hi: 488, lo: 435, dwell: 0.45), SirenPattern.hiLo, EmergencyVehicleKind.unknown, 3.5),
      'ambulance switching hi-lo and wail (India)': ((s) => s.hiLoWail(10, amp: 0.03), null, EmergencyVehicleKind.ambulance, 3.5),
      'police yelp 3.5 Hz': ((s) => s.yelp(9, amp: 0.02, rate: 3.5), SirenPattern.yelp, EmergencyVehicleKind.police, 4.0),
      'police yelp 5 Hz': ((s) => s.yelp(9, amp: 0.02, rate: 5), SirenPattern.yelp, EmergencyVehicleKind.police, 3.5),
      'police yelp 8 Hz': ((s) => s.yelp(9, amp: 0.02, rate: 8), SirenPattern.yelp, EmergencyVehicleKind.police, 3.5),
      'police wail-yelp switching': ((s) => s.wailYelp(10, amp: 0.03), null, EmergencyVehicleKind.police, 3.5),
      'fire engine: slow, low mechanical wail': ((s) => s.mechanicalWail(10, amp: 0.04), SirenPattern.wail, EmergencyVehicleKind.fire, 3.5),
      'electronic wail 500-1800 Hz (all services): generic': ((s) => s.wail(9, amp: 0.02), SirenPattern.wail, EmergencyVehicleKind.unknown, 3.5),
      'hi-lo in a tunnel (echo)': ((s) => s.echo(s.hiLo(9, amp: 0.02)), SirenPattern.hiLo, EmergencyVehicleKind.ambulance, 3.5),
      'wail in a tunnel (echo)': ((s) => s.echo(s.wail(9, amp: 0.02)), SirenPattern.wail, EmergencyVehicleKind.unknown, 3.5),
      'hi-lo in rain': ((s) => mix([s.hiLo(9, amp: 0.02), s.rain(9, amp: 0.03)]), SirenPattern.hiLo, EmergencyVehicleKind.ambulance, 3.5),
      'hi-lo in clipping wind at 100 km/h': ((s) => mix([s.hiLo(9, amp: 0.05), s.wind(9, amp: 0.3, clip: true)]), SirenPattern.hiLo, EmergencyVehicleKind.ambulance, 3.5),
      'quiet hi-lo (-45 dBFS under -26 dBFS ride noise)': ((s) => s.hiLo(9, amp: 0.01), SirenPattern.hiLo, null, 6.0),
      'quiet wail': ((s) => s.wail(9, amp: 0.01), SirenPattern.wail, EmergencyVehicleKind.unknown, 4.0),
    };
    cases.forEach((name, c) {
      test('$name: one alert, only after it ran >= 2.5 s, right kind', () {
        final s = Synth(11);
        final r = _run(mix([s.ride(sec), place(c.$1(s), start, sec)]));
        expect(r.alerts.length, 1, reason: 'one alert per episode: ${r.alerts}');
        final o = r.first!;
        if (c.$2 != null) expect(o.pattern, c.$2);
        expect(o.continuousSec, greaterThanOrEqualTo(SoundAwarenessEngine.continuousSec));
        final delay = o.timeSec - start;
        expect(delay, greaterThanOrEqualTo(2.4), reason: 'continuous for a few seconds first');
        expect(delay, lessThanOrEqualTo(c.$4), reason: 'detection delay from the siren start');
        final end = r.last!;
        final kind = c.$3;
        if (kind == null) {
          expect(!end.kindConfident || end.kind == EmergencyVehicleKind.ambulance, isTrue, reason: 'never a wrong kind: $end');
        } else {
          expect(end.kind, kind, reason: '$end');
          expect(end.kindConfident, kind != EmergencyVehicleKind.unknown, reason: '$end');
        }
      });
    });
  });

  group('3.55 sirens: short sounds never alert', () {
    final chirps = <String, Float64List Function(Synth s)>{
      '1 s yelp chirp': (s) => mix([s.ride(sec), place(s.yelp(1, amp: 0.05), 3, sec)]),
      '1.5 s hi-lo chirp': (s) => mix([s.ride(sec), place(s.hiLo(1.5, amp: 0.05), 3, sec)]),
      '2 s wail': (s) => mix([s.ride(sec), place(s.wail(2, amp: 0.05), 3, sec)]),
      'two 1 s chirps, 2 s apart': (s) => mix([s.ride(sec), place(s.yelp(1, amp: 0.05), 2, sec), place(s.yelp(1, amp: 0.05), 5, sec)]),
    };
    chirps.forEach((name, gen) {
      test('$name: no alert', () {
        for (final seed in [1, 3, 7, 11]) {
          expect(_run(gen(Synth(seed))).alerts, isEmpty, reason: 'seed $seed');
        }
      });
    });
  });

  group('3.55 sirens: no false alarms', () {
    final negatives = <String, Float64List Function(Synth s)>{
      'musical truck pressure horn (a tune), 4 s': (s) => mix([s.ride(sec), place(s.melodyHorn(4, seed: s.rnd.nextInt(99)), 3, sec)]),
      'musical truck pressure horn, 8 s': (s) => mix([s.ride(sec), place(s.melodyHorn(8, seed: s.rnd.nextInt(99)), 2, sec)]),
      'car horns honking (incl. a 1.2 s blast)': (s) =>
          mix([s.ride(sec), place(s.horn(8, [(0, 0.4), (0.8, 0.5), (1.6, 0.3), (2.2, 1.2), (4, 0.4), (4.6, 0.4)], amp: 0.15), 2, sec)]),
      'one long 3 s car horn': (s) => mix([s.ride(sec), place(s.horn(4, [(0, 3.0)], amp: 0.15), 2, sec)]),
      'truck air horn 180 / 225 Hz': (s) => mix([s.ride(sec), place(s.horn(5, [(0, 0.5), (0.9, 2.0)], amp: 0.2, f1: 180, f2: 225), 3, sec)]),
      'reversing beeper 1.1 kHz, 0.5 s on / off': (s) => mix([s.ride(sec), place(s.beeper(9), 2, sec)]),
      'reversing beeper 2.7 kHz, 0.25 s on / off': (s) => mix([s.ride(sec), place(s.beeper(9, on: 0.25, off: 0.25, f: 2700), 2, sec)]),
      'ringtone (struck notes, a tune)': (s) => mix([s.ride(sec), place(s.ringtone(8), 2, sec)]),
      'chime "ding-dong" (two decaying notes)': (s) => mix([s.ride(sec), place(s.ringtone(8, twoNote: true), 2, sec)]),
      'rain': (s) => mix([s.ride(sec), s.rain(sec, amp: 0.06)]),
      'temple / loudspeaker music (drone + gliding singer)': (s) => mix([s.ride(sec), s.templeMusic(sec, amp: 0.06)]),
      'wind gusts with clipping at 100 km/h': (s) => mix([s.wind(sec, amp: 0.4, clip: true), s.engine(sec, amp: 0.03)]),
      'wind only': (s) => s.wind(sec, amp: 0.2),
      'engine drone (45 Hz harmonic series + noise)': (s) => mix([s.engine(sec, amp: 0.15), s.noise(sec, amp: 0.01)]),
      'engine at high rpm (160 Hz series)': (s) => mix([s.engine(sec, amp: 0.15, f0: 160), s.noise(sec, amp: 0.01)]),
      'male speech over the ride': (s) => mix([s.ride(sec), s.speech(sec, amp: 0.08)]),
      'female speech over the ride': (s) => mix([s.ride(sec), s.speech(sec, amp: 0.08, f0: 220)]),
      'child-like speech (300 Hz)': (s) => mix([s.ride(sec), s.speech(sec, amp: 0.08, f0: 300)]),
      'music from a nearby car (chords)': (s) => mix([s.ride(sec), s.chords(sec, amp: 0.08)]),
      'constant 1 kHz tone (alarm / whistle)': (s) => mix([s.ride(sec), place(s.siren(6, (t) => 1000, amp: 0.05), 2, sec)]),
      'near silence': (s) => s.noise(sec, amp: 0.0005),
    };
    negatives.forEach((name, gen) {
      test('$name: no siren alert', () {
        for (final seed in [1, 3, 7, 11]) {
          final r = _run(gen(Synth(seed)));
          expect(r.alerts, isEmpty, reason: 'seed $seed: ${r.alerts}');
        }
      });
    });

    test('everything at once (engine, clipping wind, speech, chords, horns)', () {
      for (var seed = 20; seed < 26; seed++) {
        final z = Synth(seed);
        final r = _run(mix([
          z.engine(sec, amp: 0.06, f0: 30.0 + seed * 4),
          z.wind(sec, amp: 0.15, clip: true),
          z.speech(sec, amp: 0.05, f0: 100.0 + seed * 6),
          z.chords(sec, amp: 0.03),
          place(z.horn(3, [(0, 0.4), (0.8, 0.5)], amp: 0.1), 5, sec),
        ]));
        expect(r.alerts, isEmpty, reason: 'seed $seed');
      }
    });

    test("the phone's own sound on its speaker is ignored (suppress)", () {
      final s = Synth(5);
      final x = mix([s.ride(sec), place(s.hiLo(9, amp: 0.05), start, sec)]);
      expect(_run(x).alerts, hasLength(1), reason: 'heard normally');
      expect(_run(x, suppressAt: (_) => true).alerts, isEmpty, reason: 'phone playing on its speaker the whole time');
      // Own sound only for the first 3 s of the siren: the 2.5 s run starts after it.
      final late = _run(x, suppressAt: (t) => t < start + 3).first;
      expect(late, isNotNull);
      expect(late!.timeSec, greaterThanOrEqualTo(start + 3 + 2.4));
    });
  });

  group('3.55 sirens: approaching, leaving, passing, long episodes', () {
    test('approaching: rising loudness gives trend approaching', () {
      final s = Synth(11);
      final x = mix([s.ride(14), place(s.wail(12, amp: 0.004, ampAt: (t) => math.pow(10, 2.5 * t / 20).toDouble()), 1, 14)]);
      final r = _run(x);
      expect(r.alerts, isNotEmpty);
      expect(r.observations.any((o) => o.trend == SirenTrend.approaching), isTrue);
      expect(r.observations.any((o) => o.trend == SirenTrend.movingAway), isFalse);
    });

    test('moving away: falling loudness + Doppler drop gives trend moving away', () {
      final s = Synth(11);
      final x = mix([
        s.ride(sec),
        place(s.hiLo(10, amp: 0.04, ampAt: (t) => math.pow(10, -1.5 * t / 20).toDouble(), doppler: (t) => t < 3 ? 1.0 : 0.94), 1, sec),
      ]);
      final r = _run(x);
      expect(r.alerts, isNotEmpty);
      expect(r.last!.trend, SirenTrend.movingAway);
    });

    test('passing: approaching, then moving away after it passed (pitch drop + fading)', () {
      final s = Synth(11);
      final x = mix([
        s.ride(14),
        place(
            s.hiLo(12,
                amp: 0.05,
                ampAt: (t) => math.pow(10, -(t - 6).abs() * 3 / 20).toDouble(),
                doppler: (t) => 1.03 - 0.06 / (1 + math.exp(-(t - 6) * 3))),
            1,
            14),
      ]);
      final r = _run(x);
      expect(r.alerts, hasLength(1));
      final trends = r.observations.map((o) => o.trend).toList();
      final firstApproach = trends.indexOf(SirenTrend.approaching);
      expect(firstApproach, greaterThanOrEqualTo(0));
      expect(trends.lastIndexOf(SirenTrend.movingAway), greaterThan(firstApproach));
    });

    test('cool-down: the same siren back within 30 s does not alert again', () {
      final s = Synth(3);
      const total = 34.0;
      final x = mix([s.ride(total), place(s.hiLo(6, amp: 0.02), 1, total), place(s.hiLo(6, amp: 0.02), 20, total)]);
      expect(_run(x).alerts.where((a) => a.reason == SirenAlertReason.newEpisode).length, 1);
    });

    test('a siren that clearly gets closer alerts again inside the episode', () {
      final s = Synth(4);
      const total = 24.0;
      final x = mix([s.ride(total), place(s.hiLo(20, amp: 0.01, ampAt: (t) => t < 8 ? 1.0 : 10.0), 2, total)]);
      final r = _run(x);
      expect(r.alerts.length, greaterThanOrEqualTo(2));
      expect(r.alerts.last.reason, SirenAlertReason.closer);
    });

    test('stuck behind an ambulance for 60 s at the same distance: one alert only', () {
      final s = Synth(4);
      const total = 70.0;
      final r = _run(mix([s.ride(total), place(s.hiLo(60, amp: 0.03), 2, total)]));
      expect(r.alerts, hasLength(1));
    });

    test('a long siren that starts approaching after 35 s alerts again (approaching)', () {
      final s = Synth(4);
      const total = 70.0;
      final x = mix([
        s.ride(total),
        place(s.hiLo(60, amp: 0.01, ampAt: (t) => t < 35 ? 1.0 : math.pow(10, 2 * (t - 35) / 20).toDouble().clamp(1.0, 12.0)), 2, total),
      ]);
      final r = _run(x);
      expect(r.alerts.length, greaterThanOrEqualTo(2));
      final later = r.alerts.where((a) => a.observation.timeSec > 35).toList();
      expect(later.any((a) => a.observation.trend == SirenTrend.approaching), isTrue, reason: '$later');
    });

    test('two sirens at once (hi-lo + wail) are still one detected episode', () {
      final s = Synth(11);
      final r = _run(mix([s.ride(sec), place(mix([s.hiLo(9, amp: 0.02), s.wail(9, amp: 0.015)]), start, sec)]));
      expect(r.alerts, hasLength(1));
    });
  });

  // ---- FLUTTER ONLY BEGIN (service tests)
  group('3.55 SirenAcousticDetector (hub path) alerts', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    Int16List toInt16(Float64List x) {
      final out = Int16List(x.length);
      for (var i = 0; i < x.length; i++) {
        out[i] = (x[i] * 32768).round().clamp(-32768, 32767);
      }
      return out;
    }

    void feed(SirenAcousticDetector d, Int16List x, {MicFrameInfo info = const MicFrameInfo(processed: false, headset: false), void Function()? each}) {
      for (var i = 0; i + 320 <= x.length; i += 320) {
        d.onHubFrame(Int16List.sublistView(x, i, i + 320), info);
        each?.call();
      }
    }

    test('rider isolated (earbuds): a siren speaks once (P1 when close), shows the card, ducks, then clears', () {
      final d = SirenAcousticDetector()..setNativeListening(const ListeningState(headset: HeadsetKind.bluetooth));
      final spoken = <(String, bool)>[];
      var tones = 0;
      d.speak = (text, {required urgent, required key}) async {
        spoken.add((text, urgent));
        return true;
      };
      d.tone = () => tones++;
      final s = Synth(5);
      const total = 24.0;
      var cardSeen = false, duckSeen = false;
      feed(d, toInt16(mix([s.ride(total), place(s.hiLo(8, amp: 0.15), 1, total)])), each: () {
        if (d.activeSirenNotifier.value != null) cardSeen = true;
        if (d.isDucked) duckSeen = true;
      });
      expect(spoken.length, 1);
      expect(spoken.first.$2, isTrue, reason: 'very close siren = P1');
      expect(spoken.first.$1, contains('Keep left and give way'));
      expect(SirenAcousticDetector.allSirenLines(), contains(spoken.first.$1), reason: 'every line is pre-synthesised');
      expect(cardSeen, isTrue);
      expect(duckSeen, isTrue);
      expect(tones, 0, reason: 'isolated: spoken, no tone');
      expect(d.activeSirenNotifier.value, isNull, reason: 'card gone 15 s after the siren stopped');
      expect(d.isDucked, isFalse);
      d.dispose();
    });

    test('rider not isolated (phone speaker, no music): no speech, one tone, card still shows', () {
      final d = SirenAcousticDetector();
      var spoken = 0, tones = 0;
      d.speak = (text, {required urgent, required key}) async {
        spoken++;
        return true;
      };
      d.tone = () => tones++;
      final s = Synth(5);
      var cardSeen = false;
      feed(d, toInt16(mix([s.ride(sec), place(s.hiLo(8, amp: 0.15), 1, sec)])), each: () {
        if (d.activeSirenNotifier.value != null) cardSeen = true;
      });
      expect(spoken, 0);
      expect(tones, 1);
      expect(cardSeen, isTrue);
      d.dispose();
    });

    test("music playing on the phone's own speaker: the mic hears the phone, detection ignores it", () {
      final d = SirenAcousticDetector()..setNativeListening(const ListeningState(musicActive: true));
      var alerts = 0;
      d.speak = (text, {required urgent, required key}) async {
        alerts++;
        return true;
      };
      d.tone = () => alerts++;
      final s = Synth(5);
      feed(d, toInt16(mix([s.ride(sec), place(s.hiLo(8, amp: 0.15), 1, sec)])));
      expect(alerts, 0);
      // The same with earbuds: the music goes to the ears, the phone mic hears the road.
      d.setNativeListening(const ListeningState(headset: HeadsetKind.bluetooth, musicActive: true));
      d.resetForRide();
      feed(d, toInt16(mix([s.ride(sec), place(s.hiLo(8, amp: 0.15), 1, sec)])));
      expect(alerts, 1);
      d.dispose();
    });

    test('our own line playing on the speaker is ignored (Dart side, before the native poll)', () {
      final d = SirenAcousticDetector()..ownSpeechActive = () => true;
      expect(d.listening.ownSoundOnSpeaker, isTrue);
      d.dispose();
    });

    test('headset-mic frames (push-to-talk on a helmet set) are skipped', () {
      final d = SirenAcousticDetector()..setNativeListening(const ListeningState(headset: HeadsetKind.bluetooth));
      var spoken = 0;
      d.speak = (text, {required urgent, required key}) async {
        spoken++;
        return true;
      };
      final s = Synth(5);
      feed(d, toInt16(mix([s.ride(sec), place(s.hiLo(8, amp: 0.15), 1, sec)])), info: const MicFrameInfo(processed: true, headset: true));
      expect(spoken, 0);
      expect(d.activeSirenNotifier.value, isNull);
      d.dispose();
    });

    test('siren setting off: frames are ignored and the mic is not wanted', () {
      final d = SirenAcousticDetector()..sirenSettingOn = () => false;
      expect(d.detectionWanted, isFalse);
      var spoken = 0;
      d.speak = (text, {required urgent, required key}) async {
        spoken++;
        return true;
      };
      final s = Synth(5);
      feed(d, toInt16(mix([s.ride(sec), place(s.hiLo(8, amp: 0.15), 1, sec)])));
      expect(spoken, 0);
      expect(d.activeSirenNotifier.value, isNull);
      d.dispose();
    });

    test('alert texts: the kind only when confident, give-way side', () {
      SirenObservation obs({
        SirenTrend trend = SirenTrend.unknown,
        SoundNearness near = SoundNearness.near,
        EmergencyVehicleKind kind = EmergencyVehicleKind.ambulance,
        bool confident = false,
      }) =>
          SirenObservation(
            timeSec: 10,
            pattern: SirenPattern.hiLo,
            kind: kind,
            kindConfident: confident,
            confidence: 0.9,
            kindConfidence: confident ? 0.85 : 0.6,
            trend: trend,
            nearness: near,
            snrDb: 18,
            centreHz: 860,
          );
      String text(SirenObservation o, {SirenAlertReason reason = SirenAlertReason.newEpisode, String side = 'left'}) =>
          SirenAcousticDetector.sirenAlertText(SirenAlert(o, reason), keepSide: side);
      expect(text(obs()), 'Emergency vehicle siren close by. Keep left and give way.');
      expect(text(obs(confident: true)), 'Ambulance siren close by. Keep left and give way.');
      expect(text(obs(confident: true, kind: EmergencyVehicleKind.police, trend: SirenTrend.approaching)), 'Police approaching. Keep left and give way.');
      expect(text(obs(confident: true, kind: EmergencyVehicleKind.fire, near: SoundNearness.far)), 'Fire engine siren in the distance.');
      expect(text(obs(), reason: SirenAlertReason.closer, side: 'right'), 'Emergency vehicle getting closer. Keep right and give way.');
      for (final o in [obs(), obs(confident: true), obs(confident: true, kind: EmergencyVehicleKind.police)]) {
        for (final r in SirenAlertReason.values) {
          expect(SirenAcousticDetector.allSirenLines(keepSide: 'right'), contains(text(o, reason: r, side: 'right')));
        }
      }
      expect(SirenAcousticDetector.keepSideForCountry('IN'), 'left');
      expect(SirenAcousticDetector.keepSideForCountry('de'), 'right');
      expect(SirenAcousticDetector.keepSideForCountry(null), 'left');
    });

    test('headset label guess', () {
      expect(RideMicHub.isHeadsetLabel('Moto Intercom (BLUETOOTH_SCO)'), isTrue);
      expect(RideMicHub.isHeadsetLabel('Pixel (BUILTIN_MIC)'), isFalse);
    });

    test("detection captures from the phone's built-in mic, never a headset mic", () {
      const builtIn = InputDevice(id: '1', label: 'Pixel', type: InputDeviceType.builtIn);
      const sco = InputDevice(id: '2', label: 'Moto Intercom', type: InputDeviceType.bluetoothSco);
      const wired = InputDevice(id: '3', label: 'Earphones', type: InputDeviceType.wiredHeadset);
      expect(RideMicHub.pickBuiltIn([sco, wired, builtIn]), builtIn);
      expect(RideMicHub.pickBuiltIn([const InputDevice(id: '4', label: 'Pixel (BUILTIN_MIC)'), sco])?.id, '4');
      expect(RideMicHub.pickBuiltIn([sco]), isNull);
      expect(RideMicHub.isHeadsetDevice(sco), isTrue);
      expect(RideMicHub.isHeadsetDevice(wired), isTrue);
      expect(RideMicHub.isHeadsetDevice(builtIn), isFalse);
    });

    test('mic plan: built-in for detection; headset mic only while push-to-talk is held', () {
      MicPlan plan({bool det = true, bool ic = false, bool vox = false, bool hs = false}) =>
          MicPlan.forNeeds(detection: det, intercom: ic, intercomHandsFree: vox, headset: hs);
      expect(plan(), MicPlan.detection);
      expect(plan(hs: true), MicPlan.detection, reason: 'headset connected, no talk: phone mic, no SCO');
      expect(plan(ic: true, vox: true, hs: true), MicPlan.detection, reason: 'hands-free + headset: one capture, phone mic');
      expect(plan(ic: true), MicPlan.detection, reason: 'talk without headset: phone mic');
      expect(plan(ic: true, hs: true), MicPlan.headsetTalk, reason: 'push-to-talk held with a headset');
      expect(plan(det: false, ic: true, vox: true, hs: true), MicPlan.headsetTalk, reason: 'talk only: as before');
      expect(MicPlan.detection.builtInMic && !MicPlan.detection.bluetooth && !MicPlan.detection.processed, isTrue);
    });
  });
  // ---- FLUTTER ONLY END
}
