// 3.55 Siren / horn alert policy (pure Dart, no Flutter): how loud an alert is, based on whether
// the rider can hear outside sound right now.
//
// The real scenario: the rider wears noise-cancelling earbuds or a helmet Bluetooth set, or plays
// music, and does not hear an ambulance. The phone's own microphone (on the mount, in the tank bag
// or a pocket) still hears it, so CoRoute warns THIS rider. Telling the group is not part of it.
//
//  * "Listening isolated" (the rider likely cannot hear outside): ANY of a Bluetooth audio headset
//    (A2DP, LE audio, hearing aid, SCO) or wired / USB headset connected, other apps' music
//    playing, the intercom playing a rider's voice, or a phone call. It comes from the phone's
//    audio state (no microphone needed), see TtsChannel.kt "listeningState".
//  * Sirens (setting "Siren alerts", default on): always detected during a ride.
//      isolated  -> full alert: P1 line (music paused), strong vibration, card, heads-up;
//                   a far siren gets the short P2 "in the distance" line.
//      not isolated (phone speaker, no music) -> softer: card + vibration + a short tone, no speech
//                   (the rider hears the siren); a far siren only vibrates.
//  * Horns (setting "Horn alerts": Automatic (default) / On / Off):
//      Automatic = active only while isolated; On = always; Off = never.
//      isolated -> "Horn close by. Check your mirrors." (P2) + vibration + card;
//      not isolated (On) -> vibration + card only.
//  * The microphone is needed for detection while sirens are on, or horns are effectively active.
//
// Rider-facing wording says "close by" or "approaching", never "behind" (one mic has no direction).

import 'sound_awareness_engine.dart';

/// What is playing to the rider's ears (from the phone's audio state).
enum HeadsetKind { none, bluetooth, wired, hearingAid }

/// The rider's hearing situation, polled from native (no microphone needed).
class ListeningState {
  final HeadsetKind headset;

  /// Another app's music / media is playing (AudioManager.isMusicActive).
  final bool musicActive;

  /// The intercom is playing a rider's voice.
  final bool intercomPlaying;

  /// A phone call rings or is active.
  final bool inCall;

  const ListeningState({
    this.headset = HeadsetKind.none,
    this.musicActive = false,
    this.intercomPlaying = false,
    this.inCall = false,
  });

  static const ListeningState open = ListeningState();

  /// The rider likely cannot hear outside sound.
  bool get isolated => headset != HeadsetKind.none || musicActive || intercomPlaying || inCall;

  /// Parses the native map ({headset: 'bluetooth'|'wired'|'hearingAid'|'', musicActive, inCall}).
  static ListeningState fromMap(Map<Object?, Object?> m, {bool intercomPlaying = false}) {
    final h = m['headset']?.toString() ?? '';
    return ListeningState(
      headset: switch (h) {
        'bluetooth' => HeadsetKind.bluetooth,
        'wired' => HeadsetKind.wired,
        'hearingAid' => HeadsetKind.hearingAid,
        _ => HeadsetKind.none,
      },
      musicActive: m['musicActive'] == true,
      intercomPlaying: intercomPlaying,
      inCall: m['inCall'] == true,
    );
  }

  ListeningState withIntercom(bool playing) =>
      ListeningState(headset: headset, musicActive: musicActive, intercomPlaying: playing, inCall: inCall);

  @override
  bool operator ==(Object other) =>
      other is ListeningState &&
      other.headset == headset &&
      other.musicActive == musicActive &&
      other.intercomPlaying == intercomPlaying &&
      other.inCall == inCall;

  @override
  int get hashCode => Object.hash(headset, musicActive, intercomPlaying, inCall);

  @override
  String toString() => 'ListeningState(headset: ${headset.name}, music: $musicActive, intercom: $intercomPlaying, call: $inCall)';
}

/// How a siren alert is delivered.
class SirenAlertStyle {
  /// The line is spoken.
  final bool speak;

  /// P1: pauses music, never muted. Else the P2 hazard tier.
  final bool urgent;

  /// Strong (triple) vibration, else a medium one.
  final bool strongVibration;

  /// A short tone instead of speech (rider not isolated: they hear the siren themselves).
  final bool tone;

  const SirenAlertStyle({required this.speak, required this.urgent, required this.strongVibration, required this.tone});

  @override
  String toString() => 'SirenAlertStyle(speak: $speak, urgent: $urgent, strong: $strongVibration, tone: $tone)';
}

/// How a horn alert is delivered (the card always shows).
class HornAlertStyle {
  final bool speak;
  const HornAlertStyle({required this.speak});
}

class SoundAlertPolicy {
  SoundAlertPolicy._();

  /// The siren is close, approaching or clearly closer (the safety-critical case).
  static bool sirenClose(SirenAlert a) =>
      a.reason == SirenAlertReason.closer ||
      a.observation.trend == SirenTrend.approaching ||
      a.observation.nearness != SoundNearness.far;

  static SirenAlertStyle sirenStyle({required bool close, required bool isolated}) {
    if (isolated) {
      return SirenAlertStyle(speak: true, urgent: close, strongVibration: close, tone: false);
    }
    return SirenAlertStyle(speak: false, urgent: false, strongVibration: close, tone: close);
  }

  /// Horns effectively active: [setting] true = On, false = Off, null = Automatic (only while isolated).
  static bool hornsActive({required bool? setting, required bool isolated, bool adminOn = true}) {
    if (!adminOn) return false;
    return setting ?? isolated;
  }

  static HornAlertStyle hornStyle({required bool isolated}) => HornAlertStyle(speak: isolated);

  /// The ride microphone is needed for detection (the hub also checks ride, battery, call, permission).
  static bool detectionNeedsMic({required bool sirensOn, required bool hornsActive}) => sirensOn || hornsActive;
}
