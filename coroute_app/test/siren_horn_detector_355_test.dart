// 3.55 sound awareness: emergency-vehicle siren and horn detection on synthesised ride audio.
// The engine is pure Dart (lib/domain/audio/sound_awareness_engine.dart); these tests feed it
// 20 ms frames exactly as the RideMicHub does, over a riding background (engine drone + wind +
// mic hiss, about -26 dBFS). Measured numbers: docs/features_355/sound_awareness_and_intercom.md.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart' show InputDevice, InputDeviceType;
import 'package:coroute_app/domain/audio/sound_alert_policy.dart';
import 'package:coroute_app/domain/audio/sound_awareness_engine.dart';
import 'package:coroute_app/data/services/ride_mic_hub.dart';
import 'package:coroute_app/data/services/siren_acoustic_detector.dart';

import 'support/audio_synth_355.dart';

class _Run {
  final List<SirenAlert> sirens = [];
  final List<HornAlert> horns = [];
  final List<HornEvent> hornEvents = [];
  final List<SirenObservation> observations = [];
}

_Run _run(Float64List x, {bool hornOn = true, bool suppressHorn = false}) {
  final e = SoundAwarenessEngine()
    ..hornEnabled = hornOn
    ..suppressHorn = suppressHorn;
  final r = _Run();
  for (var i = 0; i + 320 <= x.length; i += 320) {
    final u = e.process(Float64List.sublistView(x, i, i + 320));
    if (u.sirenAlert != null) r.sirens.add(u.sirenAlert!);
    if (u.hornAlert != null) r.horns.add(u.hornAlert!);
    if (u.hornEvent != null) r.hornEvents.add(u.hornEvent!);
    if (u.siren != null) r.observations.add(u.siren!);
  }
  return r;
}

Int16List _toInt16(Float64List x) {
  final out = Int16List(x.length);
  for (var i = 0; i < x.length; i++) {
    out[i] = (x[i] * 32768).round().clamp(-32768, 32767);
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sec = 12.0;

  group('3.55 sirens over riding noise', () {
    final cases = <String, (Float64List Function(Synth s), SirenPattern)>{
      'wail 500-1800 Hz, 4.5 s': ((s) => s.wail(9, amp: 0.02), SirenPattern.wail),
      'yelp 3.5 Hz': ((s) => s.yelp(9, amp: 0.02, rate: 3.5), SirenPattern.yelp),
      'yelp 5 Hz': ((s) => s.yelp(9, amp: 0.02, rate: 5), SirenPattern.yelp),
      'yelp 8 Hz': ((s) => s.yelp(9, amp: 0.02, rate: 8), SirenPattern.yelp),
      'hi-lo 960/770 Hz (EU / India ambulance)': ((s) => s.hiLo(9, amp: 0.02), SirenPattern.hiLo),
      'hi-lo 1050/700 Hz, 0.7 s (India)': ((s) => s.hiLo(9, amp: 0.02, hi: 1050, lo: 700, dwell: 0.7), SirenPattern.hiLo),
      'hi-lo quieter (-45 dBFS siren under -26 dBFS ride noise)': ((s) => s.hiLo(9, amp: 0.01), SirenPattern.hiLo),
      'wail quieter': ((s) => s.wail(9, amp: 0.01), SirenPattern.wail),
    };
    cases.forEach((name, c) {
      test('$name is detected once, with the right pattern, within 4 s', () {
        final s = Synth(11);
        final r = _run(mix([s.ride(sec), place(c.$1(s), 2, sec)]));
        expect(r.sirens.length, 1, reason: 'one alert per episode');
        final o = r.sirens.first.observation;
        expect(o.pattern, c.$2);
        expect(o.timeSec - 2.0, lessThan(4.0), reason: 'latency after the siren started');
        expect(r.horns, isEmpty, reason: 'a siren is never reported as a horn');
      });
    });

    test('a loud hi-lo siren (tone switches look like horn blasts) gives no horn alert', () {
      final s = Synth(5);
      final r = _run(mix([s.ride(sec), place(s.hiLo(9, amp: 0.15), 2, sec)]));
      expect(r.sirens, isNotEmpty);
      expect(r.horns, isEmpty);
      expect(r.sirens.first.observation.nearness, SoundNearness.veryNear);
    });

    test('approaching: rising loudness gives trend approaching', () {
      final s = Synth(11);
      final x = mix([s.ride(sec), place(s.wail(10, amp: 0.004, ampAt: (t) => math.pow(10, 2.5 * t / 20).toDouble()), 1, sec)]);
      final r = _run(x);
      expect(r.sirens, isNotEmpty);
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
      expect(r.sirens, isNotEmpty);
      expect(r.observations.last.trend, SirenTrend.movingAway);
    });

    test('kind is a guess named only when confident', () {
      final s = Synth(5);
      final r = _run(mix([s.ride(sec), place(s.hiLo(9, amp: 0.2, hi: 1050, lo: 700, dwell: 0.7), 2, sec)]));
      final o = r.sirens.first.observation;
      expect(o.kind, EmergencyVehicleKind.ambulance);
      expect(o.kindConfident, o.confidence >= 0.85);
    });

    test('cool-down: the same siren back within 30 s does not alert again', () {
      final s = Synth(3);
      const total = 34.0;
      final x = mix([s.ride(total), place(s.hiLo(6, amp: 0.02), 1, total), place(s.hiLo(6, amp: 0.02), 20, total)]);
      final r = _run(x);
      expect(r.sirens.where((a) => a.reason == SirenAlertReason.newEpisode).length, 1);
    });

    test('a siren that clearly gets closer alerts again inside the episode', () {
      final s = Synth(4);
      const total = 24.0;
      // Far (about 10 dB above the floor) for 8 s, then 20 dB louder.
      final x = mix([
        s.ride(total),
        place(s.hiLo(20, amp: 0.01, ampAt: (t) => t < 8 ? 1.0 : 10.0), 2, total),
      ]);
      final r = _run(x);
      expect(r.sirens.length, greaterThanOrEqualTo(2));
      expect(r.sirens.last.reason, SirenAlertReason.closer);
    });
  });

  group('3.55 horns', () {
    test('two close horn blasts: one "horn" alert', () {
      final s = Synth(11);
      final r = _run(mix([s.ride(sec), place(s.horn(3, [(0, 0.4), (0.8, 0.5)], amp: 0.15), 4, sec)]));
      expect(r.horns.length, 1);
      expect(r.sirens, isEmpty);
    });

    test('one long very close horn: alert', () {
      final s = Synth(11);
      final r = _run(mix([s.ride(sec), place(s.horn(3, [(0, 1.3)], amp: 0.3), 4, sec)]));
      expect(r.horns.length, 1);
    });

    test('truck air horn (180 / 225 Hz) twice: alert', () {
      final s = Synth(11);
      final r = _run(mix([s.ride(sec), place(s.horn(3, [(0, 0.5), (0.9, 0.6)], amp: 0.2, f1: 180, f2: 225), 4, sec)]));
      expect(r.horns.length, 1);
    });

    test('far horns are ignored', () {
      final s = Synth(11);
      expect(_run(mix([s.ride(sec), place(s.horn(3, [(0, 0.5)], amp: 0.008), 4, sec)])).horns, isEmpty);
      expect(_run(mix([s.ride(sec), place(s.horn(3, [(0, 0.4), (0.8, 0.4)], amp: 0.006), 4, sec)])).horns, isEmpty);
    });

    test("the bike's own horn (clipping the mic) is ignored", () {
      final s = Synth(11);
      final r = _run(mix([s.ride(sec), place(s.horn(3, [(0, 0.5), (0.9, 0.5)], amp: 1.5), 4, sec)]));
      expect(r.horns, isEmpty);
      expect(r.hornEvents.every((h) => h.ownHorn), isTrue);
    });

    test('at most one horn alert per 20 s', () {
      final s = Synth(11);
      const total = 16.0;
      final x = mix([
        s.ride(total),
        place(s.horn(2, [(0, 0.4), (0.8, 0.4)], amp: 0.15), 2, total),
        place(s.horn(2, [(0, 0.4), (0.8, 0.4)], amp: 0.15), 7, total),
        place(s.horn(2, [(0, 0.4), (0.8, 0.4)], amp: 0.15), 12, total),
      ]);
      expect(_run(x).horns.length, 1);
    });

    test('no horn alert while the rider talks on the intercom, or with horns switched off', () {
      final s = Synth(11);
      final x = mix([s.ride(sec), place(s.horn(3, [(0, 0.4), (0.8, 0.5)], amp: 0.15), 4, sec)]);
      expect(_run(x, suppressHorn: true).horns, isEmpty);
      expect(_run(x, hornOn: false).horns, isEmpty);
    });
  });

  group('3.55 no false alarms', () {
    final negatives = <String, Float64List Function(Synth s)>{
      'wind gusts with clipping at 100 km/h': (s) => mix([s.wind(sec, amp: 0.4, clip: true), s.engine(sec, amp: 0.03)]),
      'wind only': (s) => s.wind(sec, amp: 0.2),
      'engine drone (45 Hz harmonic series + noise)': (s) => mix([s.engine(sec, amp: 0.15), s.noise(sec, amp: 0.01)]),
      'engine at high rpm (160 Hz series)': (s) => mix([s.engine(sec, amp: 0.15, f0: 160), s.noise(sec, amp: 0.01)]),
      'male speech over the ride': (s) => mix([s.ride(sec), s.speech(sec, amp: 0.08)]),
      'female speech over the ride': (s) => mix([s.ride(sec), s.speech(sec, amp: 0.08, f0: 220)]),
      'child-like speech (300 Hz)': (s) => mix([s.ride(sec), s.speech(sec, amp: 0.08, f0: 300)]),
      'music-like chords': (s) => mix([s.ride(sec), s.chords(sec, amp: 0.08)]),
      'constant 1 kHz tone (alarm / whistle)': (s) => mix([s.ride(sec), place(s.siren(6, (t) => 1000, amp: 0.05), 2, sec)]),
      'near silence': (s) => s.noise(sec, amp: 0.0005),
    };
    negatives.forEach((name, gen) {
      test('$name: no siren, no horn alert', () {
        for (final seed in [1, 3, 7, 11]) {
          final r = _run(gen(Synth(seed)));
          expect(r.sirens, isEmpty, reason: 'seed $seed: ${r.sirens}');
          expect(r.horns, isEmpty, reason: 'seed $seed: ${r.horns}');
        }
      });
    });

    test('everything at once (engine, clipping wind, speech, chords)', () {
      for (var seed = 20; seed < 26; seed++) {
        final z = Synth(seed);
        final r = _run(mix([
          z.engine(sec, amp: 0.06, f0: 30.0 + seed * 4),
          z.wind(sec, amp: 0.15, clip: true),
          z.speech(sec, amp: 0.05, f0: 100.0 + seed * 6),
          z.chords(sec, amp: 0.03),
        ]));
        expect(r.sirens, isEmpty, reason: 'seed $seed');
        expect(r.horns, isEmpty, reason: 'seed $seed');
      }
    });
  });

  group('3.55 SirenAcousticDetector (hub path) alerts', () {
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
      final x = _toInt16(mix([s.ride(total), place(s.hiLo(8, amp: 0.15), 1, total)]));
      const info = MicFrameInfo(processed: false, headset: false);
      var cardSeen = false, duckSeen = false;
      for (var i = 0; i + 320 <= x.length; i += 320) {
        d.onHubFrame(Int16List.sublistView(x, i, i + 320), info);
        if (d.activeSirenNotifier.value != null) cardSeen = true;
        if (d.isDucked) duckSeen = true;
      }
      expect(spoken.length, 1);
      expect(spoken.first.$2, isTrue, reason: 'very close siren = P1');
      expect(spoken.first.$1, contains('Keep left and give way'));
      expect(cardSeen, isTrue);
      expect(duckSeen, isTrue);
      expect(tones, 0, reason: 'isolated: spoken, no tone');
      // 15 s after the siren stopped: card gone, ducking lifted.
      expect(d.activeSirenNotifier.value, isNull);
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
      final x = _toInt16(mix([s.ride(sec), place(s.hiLo(8, amp: 0.15), 1, sec)]));
      var cardSeen = false;
      for (var i = 0; i + 320 <= x.length; i += 320) {
        d.onHubFrame(Int16List.sublistView(x, i, i + 320), const MicFrameInfo(processed: false, headset: false));
        if (d.activeSirenNotifier.value != null) cardSeen = true;
      }
      expect(spoken, 0);
      expect(tones, 1);
      expect(cardSeen, isTrue);
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
      final x = _toInt16(mix([s.ride(sec), place(s.hiLo(8, amp: 0.15), 1, sec)]));
      for (var i = 0; i + 320 <= x.length; i += 320) {
        d.onHubFrame(Int16List.sublistView(x, i, i + 320), const MicFrameInfo(processed: true, headset: true));
      }
      expect(spoken, 0);
      expect(d.activeSirenNotifier.value, isNull);
      d.dispose();
    });

    test('Automatic horns follow the audio state, with siren alerts off too (no mic needed to know)', () {
      final d = SirenAcousticDetector()..sirenSettingOn = () => false;
      expect(d.hornAlertsOn, isFalse);
      expect(d.detectionWanted, isFalse);
      d.setNativeListening(const ListeningState(musicActive: true));
      expect(d.listeningIsolated, isTrue);
      expect(d.hornAlertsOn, isTrue);
      expect(d.detectionWanted, isTrue, reason: 'the mic opens for horns');
      d.setNativeListening(ListeningState.open);
      expect(d.detectionWanted, isFalse);
      d.intercomPlaying = () => true;
      expect(d.hornAlertsOn, isTrue, reason: 'the intercom playing counts as isolated');
      d.hornSetting = () => false;
      expect(d.hornAlertsOn, isFalse);
      d.dispose();
    });

    test('siren setting off: frames are ignored', () {
      final d = SirenAcousticDetector()..sirenSettingOn = () => false;
      var spoken = 0;
      d.speak = (text, {required urgent, required key}) async {
        spoken++;
        return true;
      };
      final s = Synth(5);
      final x = _toInt16(mix([s.ride(sec), place(s.hiLo(8, amp: 0.15), 1, sec)]));
      for (var i = 0; i + 320 <= x.length; i += 320) {
        d.onHubFrame(Int16List.sublistView(x, i, i + 320), const MicFrameInfo(processed: false, headset: false));
      }
      expect(spoken, 0);
      expect(d.activeSirenNotifier.value, isNull);
      d.dispose();
    });

    test('alert texts: honest kind, give-way side, horn line', () {
      SirenObservation obs({SirenTrend trend = SirenTrend.unknown, SoundNearness near = SoundNearness.near, bool confident = false}) =>
          SirenObservation(
            timeSec: 10,
            pattern: SirenPattern.hiLo,
            kind: EmergencyVehicleKind.ambulance,
            kindConfident: confident,
            confidence: confident ? 0.9 : 0.7,
            trend: trend,
            nearness: near,
            snrDb: 18,
            centreHz: 860,
          );
      expect(SirenAcousticDetector.sirenAlertText(SirenAlert(obs(), SirenAlertReason.newEpisode)),
          'Emergency vehicle siren close by. Keep left and give way.');
      expect(SirenAcousticDetector.sirenAlertText(SirenAlert(obs(confident: true, trend: SirenTrend.approaching), SirenAlertReason.newEpisode)),
          'Emergency vehicle approaching, sounds like an ambulance. Keep left and give way.');
      expect(SirenAcousticDetector.sirenAlertText(SirenAlert(obs(near: SoundNearness.far), SirenAlertReason.newEpisode)),
          'Emergency vehicle siren in the distance.');
      expect(SirenAcousticDetector.sirenAlertText(SirenAlert(obs(), SirenAlertReason.closer), keepSide: 'right'),
          'Emergency vehicle getting closer. Keep right and give way.');
      expect(SirenAcousticDetector.hornAlertText, 'Horn close by. Check your mirrors.');
      expect(SirenAcousticDetector.keepSideForCountry('IN'), 'left');
      expect(SirenAcousticDetector.keepSideForCountry('de'), 'right');
      expect(SirenAcousticDetector.keepSideForCountry(null), 'left');
    });

    test('headset label guess', () {
      expect(RideMicHub.isHeadsetLabel('Moto Intercom (BLUETOOTH_SCO)'), isTrue);
      expect(RideMicHub.isHeadsetLabel('Pixel (BUILTIN_MIC)'), isFalse);
    });

    test('detection captures from the phone\'s built-in mic, never a headset mic', () {
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
}
