// 3.55 siren alert policy: how loud an alert is, from whether the rider can hear outside
// sound (lib/domain/audio/sound_alert_policy.dart; pure Dart, also sanity-run with plain dart).

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/audio/sound_alert_policy.dart';
import 'package:coroute_app/domain/audio/sound_awareness_engine.dart';

SirenAlert _alert({SoundNearness near = SoundNearness.near, SirenTrend trend = SirenTrend.unknown, SirenAlertReason reason = SirenAlertReason.newEpisode}) =>
    SirenAlert(
      SirenObservation(
        timeSec: 10,
        pattern: SirenPattern.hiLo,
        kind: EmergencyVehicleKind.unknown,
        kindConfident: false,
        confidence: 0.7,
        trend: trend,
        nearness: near,
        snrDb: 18,
        centreHz: 860,
      ),
      reason,
    );

void main() {
  group('listening isolated', () {
    test('any headset, music, intercom or call = isolated', () {
      expect(ListeningState.open.isolated, isFalse, reason: 'phone speaker, no music');
      expect(const ListeningState(headset: HeadsetKind.bluetooth).isolated, isTrue, reason: 'ANC earbuds / helmet set');
      expect(const ListeningState(headset: HeadsetKind.wired).isolated, isTrue);
      expect(const ListeningState(headset: HeadsetKind.hearingAid).isolated, isTrue);
      expect(const ListeningState(musicActive: true).isolated, isTrue, reason: 'music on the speaker');
      expect(const ListeningState(intercomPlaying: true).isolated, isTrue);
      expect(const ListeningState(inCall: true).isolated, isTrue);
    });

    test('native map parsing', () {
      expect(ListeningState.fromMap({'headset': 'bluetooth', 'musicActive': true, 'inCall': false}),
          const ListeningState(headset: HeadsetKind.bluetooth, musicActive: true));
      expect(ListeningState.fromMap({'headset': 'wired'}).headset, HeadsetKind.wired);
      expect(ListeningState.fromMap({'headset': 'hearingAid'}).headset, HeadsetKind.hearingAid);
      expect(ListeningState.fromMap({'headset': ''}), ListeningState.open);
      expect(ListeningState.fromMap({}), ListeningState.open);
      expect(ListeningState.open.withIntercom(true).isolated, isTrue);
    });
  });

  group('siren alert level', () {
    test('close / approaching / closer count as close; far does not', () {
      expect(SoundAlertPolicy.sirenClose(_alert()), isTrue);
      expect(SoundAlertPolicy.sirenClose(_alert(near: SoundNearness.veryNear)), isTrue);
      expect(SoundAlertPolicy.sirenClose(_alert(near: SoundNearness.far)), isFalse);
      expect(SoundAlertPolicy.sirenClose(_alert(near: SoundNearness.far, trend: SirenTrend.approaching)), isTrue);
      expect(SoundAlertPolicy.sirenClose(_alert(near: SoundNearness.far, reason: SirenAlertReason.closer)), isTrue);
    });

    test('isolated rider: full spoken alert (P1 when close, P2 when far)', () {
      final close = SoundAlertPolicy.sirenStyle(close: true, isolated: true);
      expect(close.speak, isTrue);
      expect(close.urgent, isTrue);
      expect(close.strongVibration, isTrue);
      expect(close.tone, isFalse);
      final far = SoundAlertPolicy.sirenStyle(close: false, isolated: true);
      expect(far.speak, isTrue);
      expect(far.urgent, isFalse);
      expect(far.strongVibration, isFalse);
    });

    test('rider who can hear: softer (tone + vibration when close, vibration only when far)', () {
      final close = SoundAlertPolicy.sirenStyle(close: true, isolated: false);
      expect(close.speak, isFalse);
      expect(close.urgent, isFalse);
      expect(close.tone, isTrue);
      expect(close.strongVibration, isTrue);
      final far = SoundAlertPolicy.sirenStyle(close: false, isolated: false);
      expect(far.speak, isFalse);
      expect(far.tone, isFalse);
      expect(far.strongVibration, isFalse);
    });
  });

  group('own sound on the phone speaker (ignored by detection)', () {
    test('music, intercom or our own line on the speaker; never with a headset', () {
      expect(ListeningState.open.ownSoundOnSpeaker, isFalse);
      expect(const ListeningState(musicActive: true).ownSoundOnSpeaker, isTrue, reason: 'music from the phone speaker reaches the mic');
      expect(const ListeningState(intercomPlaying: true).ownSoundOnSpeaker, isTrue);
      expect(const ListeningState(ownSpeech: true).ownSoundOnSpeaker, isTrue, reason: 'our own alert line');
      expect(const ListeningState(headset: HeadsetKind.bluetooth, musicActive: true, ownSpeech: true).ownSoundOnSpeaker, isFalse,
          reason: 'with a headset the sound goes to the ears, the mic still hears the road');
      expect(ListeningState.fromMap({'ownSpeech': true}).ownSpeech, isTrue);
      expect(ListeningState.open.withOwnSpeech(true).ownSoundOnSpeaker, isTrue);
      expect(ListeningState.open.withOwnSpeech(true).isolated, isFalse, reason: 'our own speech does not make the rider isolated');
    });
  });
}
