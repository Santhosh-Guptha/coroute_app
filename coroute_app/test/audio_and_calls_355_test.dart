import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/l10n/l10n.dart';
import 'package:coroute_app/data/services/audio_priority_manager.dart';
import 'package:coroute_app/data/services/phone_call_service.dart';
import 'package:coroute_app/data/services/ride_notification_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/voice_service.dart';

/// An engine with the 3.55 native extras (in-call phrase, after-call, tone fallback).
class ExtrasEngine implements VoiceEngine, VoiceEngineExtras {
  bool initResult = true;
  bool speakResult = true;
  final List<({String text, bool isEmergency, bool pauseOthers, bool inCall, bool afterCall})> calls = [];
  final List<bool> fallbacks = [];

  @override
  Future<bool> init() async => initResult;

  @override
  Future<bool> speak(String text, {required bool interrupt, required String id, bool isEmergency = false, bool pauseOthers = false}) async {
    if (!speakResult) return false;
    calls.add((text: text, isEmergency: isEmergency, pauseOthers: pauseOthers, inCall: false, afterCall: false));
    return true;
  }

  @override
  Future<bool> speakExtended(String text,
      {required bool interrupt, required String id, bool isEmergency = false, bool pauseOthers = false, bool inCall = false, bool afterCall = false}) async {
    if (!speakResult) return false;
    calls.add((text: text, isEmergency: isEmergency, pauseOthers: pauseOthers, inCall: inCall, afterCall: afterCall));
    return true;
  }

  @override
  Future<void> fallbackAlert({required bool critical, bool inCall = false}) async => fallbacks.add(critical);

  @override
  Future<void> stop() async {}

  @override
  Future<void> release() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;
  late ExtrasEngine engine;
  late VoiceService voice;
  late PhoneCallService phone;
  final notified = <String>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService();
    await settings.load();
    L10n.setLanguage(AppLanguage.en);
    engine = ExtrasEngine();
    phone = PhoneCallService(autoStart: false);
    voice = VoiceService(settings, engine: engine);
    voice.attachPhoneCallService(phone);
    notified.clear();
    AudioPriorityManager.criticalNotifier = (title, body) async => notified.add(body);
  });

  tearDown(() {
    AudioPriorityManager.criticalNotifier = null;
    voice.dispose();
    phone.dispose();
  });

  group('other apps\' sound', () {
    test('ordinary lines duck (no pause, guidance stream); critical lines pause and use the alarm stream', () async {
      await voice.speakHazard('Pothole ahead');
      expect(engine.calls.last.isEmergency, isFalse);
      expect(engine.calls.last.pauseOthers, isFalse);
      await voice.speakFatigueConfirmation('Are you OK?');
      expect(engine.calls.last.isEmergency, isTrue, reason: 'P1 is critical: alarm stream');
      expect(engine.calls.last.pauseOthers, isTrue, reason: 'P1 always pauses music');
    });

    test('far over the limit the overspeed line is critical', () async {
      expect(await voice.speakOverspeed(currentSpeedKmh: 120, limitKmh: 80), isTrue);
      expect(engine.calls.last.text, startsWith('Slow down'));
      expect(engine.calls.last.isEmergency, isTrue);
      expect(engine.calls.last.pauseOthers, isTrue);
    });

    test('announce() speaks at the given priority (API for the siren detector)', () async {
      final ok = await voice.priorityManager.announce(AudioPriority.p0CriticalEmergency, 'Emergency vehicle close behind', key: 'siren');
      expect(ok, isTrue);
      expect(engine.calls.last.isEmergency, isTrue);
      expect(await voice.priorityManager.announce(AudioPriority.p0CriticalEmergency, 'Emergency vehicle close behind', key: 'siren'), isFalse,
          reason: 'same key within the dedupe window');
    });
  });

  group('phone calls', () {
    test('critical line during a call: in-call short phrase + heads-up; replay after', () async {
      phone.simulateCallState(PhoneCallStatus.offhook);
      await voice.speakEmergency('Emergency. Rahul may have met with an accident 4.8 kilometers behind you.');
      expect(engine.calls.last.inCall, isTrue);
      expect(engine.calls.last.text.length, lessThanOrEqualTo(70));
      expect(notified, hasLength(1));

      await voice.speak('Asha fell behind', priority: VoicePriority.important, key: 'BEHIND:asha');
      expect(engine.calls.where((c) => c.text.contains('Asha')), isEmpty);
      expect(voice.willSpeak(VoicePriority.important), isFalse, reason: 'held: the notification sounds instead');
      expect(voice.willSpeak(VoicePriority.critical), isTrue);

      phone.simulateCallState(PhoneCallStatus.idle);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final after = engine.calls.where((c) => c.afterCall).map((c) => c.text).toList();
      expect(after.any((t) => t.startsWith('Safety alert during your call: Emergency. Rahul')), isTrue);
      expect(after.any((t) => t == 'While you were on the call: Asha fell behind.'), isTrue);
    });

    test('ringing: a critical line plays in full on the alarm stream (not the call stream)', () async {
      phone.simulateCallState(PhoneCallStatus.ringing);
      await voice.speakEmergency('Crash detected. Countdown 15 seconds.');
      expect(engine.calls.last.inCall, isFalse);
      expect(engine.calls.last.text, 'Crash detected. Countdown 15 seconds.');
    });

    test('nothing held: no summary after the call', () async {
      phone.simulateCallState(PhoneCallStatus.offhook);
      phone.simulateCallState(PhoneCallStatus.idle);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(engine.calls, isEmpty);
    });
  });

  group('no speech engine', () {
    test('a failed critical line falls back to tone + vibration and a notification', () async {
      engine.speakResult = false;
      await voice.speakEmergency('SOS from Ravi');
      expect(engine.fallbacks, contains(true));
      expect(notified, contains('SOS from Ravi'));
    });

    test('informational lines stay visual only', () async {
      engine.speakResult = false;
      await voice.speakInformational('Weather update');
      expect(engine.fallbacks, isEmpty);
    });
  });

  group('ride notification status line', () {
    test('speed, limit, warning ahead and intercom state', () {
      expect(RideNotificationService.rideStatusLine(speedKmh: 52, limitKmh: 60, hazardAheadM: 1240, intercom: 'Receiving Asha'),
          '50 km/h · limit 60 · Warning in 1.2 km · Receiving Asha');
      expect(RideNotificationService.rideStatusLine(speedKmh: 78, limitKmh: 60), '80 km/h (over 60)');
      expect(RideNotificationService.rideStatusLine(hazardAheadM: 430), 'Warning in 450 m');
      expect(RideNotificationService.rideStatusLine(), '');
    });
  });

  group('settings', () {
    // Round 9 (docs/quality/ROUND9_SETTINGS_NOTES.md): no switch any more; always on.
    test('Lower music when speeding is always on; "off" is ignored and nothing is stored', () async {
      expect(settings.lowerMusicWhenSpeeding, isTrue);
      await settings.setLowerMusicWhenSpeeding(false);
      expect(settings.lowerMusicWhenSpeeding, isTrue);
      final again = SettingsService();
      await again.load();
      expect(again.lowerMusicWhenSpeeding, isTrue);
    });
  });
}
