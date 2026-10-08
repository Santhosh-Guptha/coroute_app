import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/constants/ride_notification_constants.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/voice_service.dart';

class FakeEngine implements VoiceEngine {
  bool initResult = true;
  bool speakResult = true;
  bool throwOnInit = false;
  int inits = 0;
  int stops = 0;
  int releases = 0;
  final List<(String, bool)> spoken = [];

  @override
  Future<bool> init() async {
    inits++;
    if (throwOnInit) throw PlatformException(code: 'NO_ENGINE');
    return initResult;
  }

  @override
  Future<bool> speak(String text, {required bool interrupt, required String id}) async {
    if (!speakResult) return false;
    spoken.add((text, interrupt));
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
    voice = VoiceService(settings, engine: engine, clock: () => now);
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

  test('critical speaks with "Speak emergency alerts" on, and interrupts', () async {
    expect(await voice.speak('Emergency. Rahul may have met with an accident.', priority: VoicePriority.critical, key: 'SOS:1'), isTrue);
    expect(engine.spoken.single, ('Emergency. Rahul may have met with an accident.', true));
    await settings.setVoiceCritical(false);
    expect(await voice.speak('Emergency again.', priority: VoicePriority.critical, key: 'SOS:2'), isFalse);
    expect(engine.spoken, hasLength(1));
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
}
