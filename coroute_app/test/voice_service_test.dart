import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/constants/ride_notification_constants.dart';
import 'package:coroute_app/core/l10n/l10n.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/voice_service.dart';

class FakeEngine implements VoiceEngine, VoiceEngineLanguage {
  bool initResult = true;

  /// The tag the engine "found" (3.16): what the phone's voices allow.
  @override
  String language = 'en-IN';
  bool speakResult = true;
  bool throwOnInit = false;
  int inits = 0;
  int stops = 0;
  int releases = 0;
  final List<(String, bool)> spoken = [];
  final List<({String text, bool interrupt, bool isEmergency, bool pauseOthers})> spokenCalls = [];

  @override
  Future<bool> init() async {
    inits++;
    if (throwOnInit) throw PlatformException(code: 'NO_ENGINE');
    return initResult;
  }

  @override
  Future<bool> speak(
    String text, {
    required bool interrupt,
    required String id,
    bool isEmergency = false,
    bool pauseOthers = false,
  }) async {
    if (!speakResult) return false;
    spoken.add((text, interrupt));
    spokenCalls.add((text: text, interrupt: interrupt, isEmergency: isEmergency, pauseOthers: pauseOthers));
    return true;
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> release() async => releases++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;
  late FakeEngine engine;
  late VoiceService voice;
  late int now;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService();
    await settings.load();
    engine = FakeEngine();
    now = 1700000000000;
    L10n.setLanguage(AppLanguage.en);
    voice = VoiceService(settings, engine: engine, clock: () => now);
  });

  tearDown(() {
    L10n.setLanguage(AppLanguage.en);
    voice.dispose();
  });

  test('nothing starts until the first alert (no engine at idle)', () async {
    expect(engine.inits, 0);
    expect(voice.available, isFalse);
    expect(voice.started, isFalse);
    expect(await voice.speak('Emergency.', priority: VoicePriority.critical, key: 'SOS:1'), isTrue);
    expect(engine.inits, 1);
    expect(voice.available, isTrue);
    expect(await voice.speak('Caution.', key: 'HAZ:1'), isTrue);
    expect(engine.inits, 1, reason: 'started once per ride');
  });

  // Emergency voice has no switch any more: critical alerts always speak.
  test('critical always speaks, even with spoken alerts off, and interrupts', () async {
    expect(await voice.speak('Emergency. Rahul may have met with an accident.', priority: VoicePriority.critical, key: 'SOS:1'), isTrue);
    expect(engine.spoken.single, ('Emergency. Rahul may have met with an accident.', true));
    await settings.setVoiceWarnings(false);
    expect(await voice.speak('Emergency again.', priority: VoicePriority.critical, key: 'SOS:2'), isTrue);
    expect(engine.spoken, hasLength(2));
  });

  test('warnings need "Speak warnings" AND the group voice switch, and queue', () async {
    expect(await voice.speak('Caution. Rider accident reported 2 kilometers ahead.', key: 'HAZ:1:2000'), isTrue);
    expect(engine.spoken.single.$2, isFalse, reason: 'queued, not interrupting');
    voice.setGroupVoice(false);
    expect(await voice.speak('Caution 1 km.', key: 'HAZ:1:1000'), isFalse);
    expect(await voice.speak('Critical still speaks.', priority: VoicePriority.critical, key: 'SOS:9'), isTrue);
    voice.setGroupVoice(true);
    await settings.setVoiceWarnings(false);
    expect(await voice.speak('Caution 500 m.', key: 'HAZ:1:500'), isFalse);
  });

  test('the same key is spoken once per 10 minutes', () async {
    expect(await voice.speak('Emergency.', priority: VoicePriority.critical, key: 'SOS:1'), isTrue);
    expect(await voice.speak('Emergency.', priority: VoicePriority.critical, key: 'SOS:1'), isFalse);
    now += NotifConstants.voiceDedupe.inMilliseconds - 1000;
    expect(await voice.speak('Emergency.', priority: VoicePriority.critical, key: 'SOS:1'), isFalse);
    now += 2000;
    expect(await voice.speak('Emergency.', priority: VoicePriority.critical, key: 'SOS:1'), isTrue);
    expect(engine.spoken, hasLength(2));
  });

  test('two calls at once with the same key speak once', () async {
    final a = voice.speak('Caution.', key: 'HAZ:2');
    final b = voice.speak('Caution.', key: 'HAZ:2');
    expect(await a, isTrue);
    expect(await b, isFalse);
    expect(engine.spoken, hasLength(1));
  });

  test('never more than 2 warnings waiting; critical always gets through', () async {
    const long = 'Caution. Rider accident reported 2 kilometers ahead. Reduce speed and stay alert.';
    expect(await voice.speak(long, key: 'W1'), isTrue);
    expect(await voice.speak(long, key: 'W2'), isTrue);
    expect(await voice.speak(long, key: 'W3'), isFalse, reason: 'queue full');
    expect(await voice.speak('Emergency.', priority: VoicePriority.critical, key: 'C1'), isTrue);
    expect(engine.spoken.last.$2, isTrue);
    // The critical flush emptied the queue.
    expect(await voice.speak(long, key: 'W4'), isTrue);
    // Time passes: the queue drains.
    now += 60000;
    expect(await voice.speak(long, key: 'W5'), isTrue);
    expect(await voice.speak(long, key: 'W6'), isTrue);
  });

  test('a dropped warning can be spoken later (its key is not used up)', () async {
    const long = 'Caution. Rider accident reported 2 kilometers ahead. Reduce speed and stay alert.';
    await voice.speak(long, key: 'W1');
    await voice.speak(long, key: 'W2');
    expect(await voice.speak(long, key: 'W3'), isFalse);
    now += 60000;
    expect(await voice.speak(long, key: 'W3'), isTrue);
  });

  test('no engine or no English voice: silent for the ride, no retry storm', () async {
    engine.initResult = false;
    expect(await voice.speak('Emergency.', priority: VoicePriority.critical, key: 'SOS:1'), isFalse);
    expect(voice.available, isFalse);
    expect(await voice.speak('Emergency 2.', priority: VoicePriority.critical, key: 'SOS:2'), isFalse);
    expect(engine.inits, 1);
    expect(engine.spoken, isEmpty);
    // Next ride: tried again.
    await voice.release();
    engine.initResult = true;
    expect(await voice.speak('Emergency 3.', priority: VoicePriority.critical, key: 'SOS:3'), isTrue);
    expect(engine.inits, 2);
  });

  test('an engine that throws is treated as missing', () async {
    engine.throwOnInit = true;
    expect(await voice.speak('Emergency.', priority: VoicePriority.critical, key: 'SOS:1'), isFalse);
    expect(voice.available, isFalse);
  });

  test('a failed speak does not use up the key', () async {
    engine.speakResult = false;
    expect(await voice.speak('Emergency.', priority: VoicePriority.critical, key: 'SOS:1'), isFalse);
    engine.speakResult = true;
    expect(await voice.speak('Emergency.', priority: VoicePriority.critical, key: 'SOS:1'), isTrue);
  });

  test('long text is cut to 300 characters; empty text is not spoken', () async {
    expect(await voice.speak('a' * 500, priority: VoicePriority.critical, key: 'L'), isTrue);
    expect(engine.spoken.single.$1.length, NotifConstants.voiceMaxChars);
    expect(await voice.speak('   ', priority: VoicePriority.critical, key: 'E'), isFalse);
  });

  test('release unbinds the engine only when it was started', () async {
    await voice.release();
    expect(engine.releases, 0);
    await voice.speak('Emergency.', priority: VoicePriority.critical, key: 'SOS:1');
    await voice.release();
    expect(engine.releases, 1);
    expect(voice.available, isFalse);
    expect(voice.started, isFalse);
    // Dedupe memory is per ride.
    expect(await voice.speak('Emergency.', priority: VoicePriority.critical, key: 'SOS:1'), isTrue);
  });

  test('stop reaches the engine once started', () async {
    await voice.stop();
    expect(engine.stops, 0);
    await voice.speak('Emergency.', priority: VoicePriority.critical, key: 'SOS:1');
    await voice.stop();
    expect(engine.stops, 1);
  });

  group('3.16: important after dark, language', () {
    test('important is spoken by day like a warning (needs warnings on and group voice)', () async {
      expect(await voice.speak('Kiran has been stopped for 5 min.', priority: VoicePriority.important, key: 'STOPPED:k'), isTrue);
      expect(engine.spoken.single.$2, isFalse, reason: 'never interrupts');
      await settings.setVoiceWarnings(false);
      expect(await voice.speak('Kiran is 2 km from the group.', priority: VoicePriority.important, key: 'SEP:k'), isFalse);
      await settings.setVoiceWarnings(true);
      voice.setGroupVoice(false);
      expect(await voice.speak('Kiran is 2 km from the group.', priority: VoicePriority.important, key: 'SEP:k'), isFalse);
    });

    // "Speak more after dark" is always on now (no switch).
    test('after dark: important is spoken even with warnings off; by day it is not', () async {
      await settings.setVoiceWarnings(false);
      voice.setNight(true);
      expect(await voice.speak('Kiran has been stopped for 5 min.', priority: VoicePriority.important, key: 'STOPPED:k'), isTrue);
      expect(await voice.speak('Hazard ahead.', priority: VoicePriority.warning, key: 'HAZ:1'), isFalse, reason: 'plain warnings stay off');
      voice.setNight(false);
      expect(await voice.speak('Kiran is far.', priority: VoicePriority.important, key: 'SEP:k'), isFalse, reason: 'by day');
    });

    test('speechLang is the safety language only when the engine confirmed that voice', () async {
      expect(voice.speechLang, 'en');
      L10n.setLanguage(AppLanguage.hi);
      engine.language = 'hi-IN';
      await voice.speak('x', priority: VoicePriority.critical, key: 'a');
      expect(voice.speechLang, 'hi');
      await voice.release();
      engine.language = 'en-IN'; // no Hindi voice on this phone
      await voice.speak('x', priority: VoicePriority.critical, key: 'b');
      expect(voice.speechLang, 'en');
      await voice.release();
      L10n.setLanguage(AppLanguage.te);
      engine.language = 'te';
      await voice.speak('x', priority: VoicePriority.critical, key: 'c');
      expect(voice.speechLang, 'te', reason: 'a bare language tag counts');
    });

    test('a language change releases a started engine so the next alert re-inits', () async {
      await voice.speak('x', priority: VoicePriority.critical, key: 'a');
      expect(voice.started, isTrue);
      L10n.setLanguage(AppLanguage.hi);
      await Future<void>.delayed(Duration.zero);
      expect(voice.started, isFalse);
      expect(engine.releases, 1);
      expect(voice.speechLang, 'en');
    });

    test('the native engine passes the language tag to init', () async {
      final channel = MethodChannel(NotifConstants.ttsChannel);
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'init') return {'ok': true, 'language': 'hi-IN'};
        return true;
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        L10n.setLanguage(AppLanguage.hi);
        final native = NativeVoiceEngine(channel: channel);
        expect(await native.init(), isTrue);
        expect(native.language, 'hi-IN');
        expect(calls.single.method, 'init');
        expect((calls.single.arguments as Map)['language'], 'hi-IN');
        expect(L10n.ttsTag, 'hi-IN');
        L10n.setLanguage(AppLanguage.en);
        expect(L10n.ttsTag, 'en-IN');
      } finally {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      }
    });
  });

  test('native engine off Android: not available, never throws', () async {
    final native = NativeVoiceEngine();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      expect(await native.init(), isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    // On Android without the native side (tests): MissingPluginException is swallowed.
    expect(await native.init(), isFalse);
    expect(await native.speak('x', interrupt: true, id: '1'), isFalse);
    await native.stop();
    await native.release();
  });

  group('audio priority & music ducking/pausing', () {
    test('default pauseOtherAudio is false: warnings duck music (pauseOthers: false)', () async {
      expect(settings.pauseOtherAudio, isFalse);
      expect(await voice.speakOverspeed(currentSpeedKmh: 95, limitKmh: 80), isTrue);
      expect(engine.spokenCalls, hasLength(1));
      expect(engine.spokenCalls.first.pauseOthers, isFalse);
      expect(engine.spokenCalls.first.isEmergency, isFalse);
    });

    test('pauseOtherAudio is true: warnings pause music (pauseOthers: true)', () async {
      await settings.setPauseOtherAudio(true);
      expect(settings.pauseOtherAudio, isTrue);
      expect(await voice.speakOverspeed(currentSpeedKmh: 110, limitKmh: 80), isTrue);
      expect(engine.spokenCalls, hasLength(1));
      expect(engine.spokenCalls.first.pauseOthers, isTrue);
      expect(engine.spokenCalls.first.isEmergency, isFalse);
    });

    test('emergency alerts always pause others and set isEmergency true', () async {
      expect(settings.pauseOtherAudio, isFalse);
      expect(await voice.speakEmergency('Emergency: Rahul crashed 2km behind.'), isTrue);
      expect(engine.spokenCalls, hasLength(1));
      expect(engine.spokenCalls.first.isEmergency, isTrue);
      expect(engine.spokenCalls.first.pauseOthers, isTrue);
    });

    test('native engine forwards pauseOthers to method channel', () async {
      final channel = MethodChannel(NotifConstants.ttsChannel);
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final native = NativeVoiceEngine(channel: channel);
        await native.speak('Slow down', interrupt: true, id: 'alert_1', isEmergency: false, pauseOthers: true);
        expect(calls, hasLength(1));
        expect(calls.single.method, 'speak');
        expect(calls.single.arguments['pauseOthers'], isTrue);
        expect(calls.single.arguments['isEmergency'], isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      }
    });
  });
}
