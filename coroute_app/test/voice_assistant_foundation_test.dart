import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/services/voice/intent_resolver.dart';
import 'package:coroute_app/data/services/voice/speech_recognition_adapter.dart';
import 'package:coroute_app/data/services/voice/text_to_speech_adapter.dart';
import 'package:coroute_app/data/services/voice/voice_action_executor.dart';
import 'package:coroute_app/data/services/voice/voice_assistant_controller.dart';
import 'package:coroute_app/data/services/voice/voice_capability_registry.dart';
import 'package:coroute_app/data/services/voice/voice_command_intent.dart';

void main() {
  group('CoRoute Voice Assistant Phase 0 & Phase 1 Foundation Test Suite', () {
    late MockSpeechRecognitionAdapter mockSpeech;
    late MockTextToSpeechAdapter mockTts;
    late VoiceActionExecutor actionExecutor;
    late VoiceAssistantController controller;

    setUp(() {
      mockSpeech = MockSpeechRecognitionAdapter();
      mockTts = MockTextToSpeechAdapter();
      actionExecutor = VoiceActionExecutor(initialVolume: 0.8);
      controller = VoiceAssistantController(
        speechAdapter: mockSpeech,
        actionExecutor: actionExecutor,
        ttsAdapter: mockTts,
        initialLocale: 'en-IN',
      );
    });

    tearDown(() {
      controller.dispose();
    });

    // ------------------------------------------------------------------------
    // 1. Permission Tests (Granted, Denied, Revoked)
    // ------------------------------------------------------------------------
    test('Permission: Start listening fails when microphone permission is denied', () async {
      controller.setPermissionState(MicPermissionState.denied);
      final started = await controller.startListening();

      expect(started, isFalse);
      expect(controller.state, equals(VoiceSessionState.failed));
      expect(controller.statusFeedback, equals('Microphone permission needed'));
    });

    test('Permission: Revoking permission mid-session cancels active listening', () async {
      controller.setPermissionState(MicPermissionState.granted);
      await controller.startListening();
      expect(controller.isListening, isTrue);

      controller.setPermissionState(MicPermissionState.permanentlyDenied);
      expect(controller.state, equals(VoiceSessionState.cancelled));
      expect(controller.statusFeedback, equals('Microphone permission revoked'));
    });

    // ------------------------------------------------------------------------
    // 2. Lifecycle & Session Management (Start, Stop, Cancel, Timeout)
    // ------------------------------------------------------------------------
    test('Lifecycle: PTT start, stop, and clean state transitions', () async {
      expect(controller.isIdle, isTrue);

      final started = await controller.startListening();
      expect(started, isTrue);
      expect(controller.isListening, isTrue);

      await controller.stopListening();
      expect(controller.state, equals(VoiceSessionState.cancelled));
      expect(controller.statusFeedback, equals('No speech detected'));
    });

    test('Lifecycle: Single active session guard prevents duplicate capture', () async {
      final first = await controller.startListening();
      final token1 = controller.activeSessionToken;

      final second = await controller.startListening();
      final token2 = controller.activeSessionToken;

      expect(first, isTrue);
      expect(second, isTrue);
      expect(token1, equals(token2));
    });

    test('Lifecycle: Invalidation of stale speech callbacks from expired session token', () async {
      await controller.startListening();
      final oldToken = controller.activeSessionToken;

      // Cancel and start a new session
      await controller.cancelSession(reason: 'Cancelled by user');
      await controller.startListening();
      final newToken = controller.activeSessionToken;
      expect(newToken, isNot(equals(oldToken)));

      // Simulate a late/stale speech callback carrying the old token
      await controller.handleSpeechComplete('volume up', token: oldToken);

      // Current state should remain untouched by the stale callback
      expect(controller.isListening, isTrue);
      expect(controller.currentTranscript, isEmpty);
    });

    // ------------------------------------------------------------------------
    // 3. Audio Focus, Bluetooth SCO & Interruption Handling
    // ------------------------------------------------------------------------
    test('Audio Focus: External audio interruption cleanly cancels listening session', () async {
      await controller.startListening();
      expect(controller.isListening, isTrue);

      controller.onAudioInterrupted(reason: 'Phone call incoming');
      expect(controller.state, equals(VoiceSessionState.cancelled));
      expect(controller.statusFeedback, equals('Phone call incoming'));
    });

    test('Bluetooth SCO: Headset disconnect event cancels active session', () async {
      await controller.startListening();
      expect(controller.isListening, isTrue);

      controller.onBluetoothDeviceChanged(isConnected: false);
      expect(controller.state, equals(VoiceSessionState.cancelled));
      expect(controller.statusFeedback, equals('Bluetooth headset disconnected'));
    });

    // ------------------------------------------------------------------------
    // 4. Foreground / Background Transitions
    // ------------------------------------------------------------------------
    test('Background Restrictions: Backgrounding app cancels active microphone capture', () async {
      await controller.startListening();
      expect(controller.isListening, isTrue);

      controller.onAppBackgrounded();
      expect(controller.state, equals(VoiceSessionState.cancelled));
      expect(controller.statusFeedback, equals('App backgrounded'));
    });

    test('Background Restrictions: Starting capture while backgrounded is rejected', () async {
      controller.onAppBackgrounded();
      final started = await controller.startListening();

      expect(started, isFalse);
      expect(controller.state, equals(VoiceSessionState.failed));
      expect(controller.statusFeedback, equals('Voice commands require foreground app'));
    });

    // ------------------------------------------------------------------------
    // 5. Trip End Lifecycle Cleanup
    // ------------------------------------------------------------------------
    test('Trip End: Ending ride tears down session and resets controller to idle', () async {
      await controller.startListening();
      expect(controller.isListening, isTrue);

      controller.onRideEnded();
      expect(controller.state, equals(VoiceSessionState.idle));
      expect(controller.currentTranscript, isEmpty);
      expect(mockSpeech.isListening, isFalse);
    });

    // ------------------------------------------------------------------------
    // 6. Hard Safety Invariant & Emergency Pre-emption
    // ------------------------------------------------------------------------
    test('Safety: Crash detector emergency preemption instantly aborts voice session', () async {
      await controller.startListening();
      expect(controller.isListening, isTrue);

      controller.onEmergencyPreempt();
      expect(controller.state, equals(VoiceSessionState.idle));
      expect(controller.statusFeedback, contains('Preempted by Safety SOS'));
      expect(mockSpeech.isListening, isFalse);
    });

    // ------------------------------------------------------------------------
    // 7. Language Capability Registry (12 Locales & Truthful Offline Status)
    // ------------------------------------------------------------------------
    test('Capability Registry: Reports accurate offline readiness per platform', () {
      final registry = VoiceCapabilityRegistry.current();
      final capabilities = registry.getCapabilities();

      expect(capabilities.length, equals(12));
      expect(capabilities['en-IN']!.isFullyOffline, isTrue);
      expect(capabilities['hi-IN']!.isFullyOffline, isTrue);
      expect(capabilities['or-IN']!.requiresNetwork, isTrue);
      expect(capabilities['or-IN']!.unavailableReason, isNotNull);
      expect(capabilities['as-IN']!.requiresNetwork, isTrue);
      expect(capabilities['as-IN']!.unavailableReason, isNotNull);
    });

    test('Capability Registry: Test corpus covers all 12 target locales and categories', () {
      final corpus = VoiceCapabilityRegistry.testCorpus;
      expect(corpus.length, equals(15));

      final locales = corpus.map((c) => c.localeTag).toSet();
      expect(locales.contains('te-IN'), isTrue);
      expect(locales.contains('hi-IN'), isTrue);
      expect(locales.contains('en-IN'), isTrue);
      expect(locales.contains('ta-IN'), isTrue);
      expect(locales.contains('kn-IN'), isTrue);
      expect(locales.contains('mr-IN'), isTrue);
      expect(locales.contains('ml-IN'), isTrue);
      expect(locales.contains('bn-IN'), isTrue);
      expect(locales.contains('gu-IN'), isTrue);
      expect(locales.contains('pa-IN'), isTrue);
      expect(locales.contains('or-IN'), isTrue);
      expect(locales.contains('as-IN'), isTrue);
    });

    // ------------------------------------------------------------------------
    // 8. Stage 4 First Commands (Strictly Allowlisted Phase 1 Scope)
    // ------------------------------------------------------------------------
    test('Command 1: Change voice-response volume (decrease delta)', () async {
      final intent = IntentResolver.resolve('Voice volume konjam kammi pannu', currentLocale: 'ta-IN');
      expect(intent.type, equals(VoiceIntentType.setVoiceVolume));

      final result = await actionExecutor.execute(intent, locale: 'ta-IN');
      expect(result.success, isTrue);
      expect(actionExecutor.currentVolume, closeTo(0.6, 0.01));
    });

    test('Command 1: Change voice-response volume (explicit percent)', () async {
      final intent = IntentResolver.resolve('set volume to 80 percent', currentLocale: 'en-IN');
      expect(intent.type, equals(VoiceIntentType.setVoiceVolume));

      final result = await actionExecutor.execute(intent, locale: 'en-IN');
      expect(result.success, isTrue);
      expect(actionExecutor.currentVolume, closeTo(0.8, 0.01));
    });

    test('Command 2: Change preferred response language', () async {
      final intent = IntentResolver.resolve('switch language to telugu', currentLocale: 'en-IN');
      expect(intent.type, equals(VoiceIntentType.switchLanguage));
      expect(intent.slots['targetLocale'], equals('te-IN'));

      final result = await actionExecutor.execute(intent, locale: 'en-IN');
      expect(result.success, isTrue);
      expect(result.spokenFeedback, contains('Telugu'));
    });

    test('Command 3: Repeat last navigation instruction', () async {
      final intent = IntentResolver.resolve('repeat directions', currentLocale: 'en-IN');
      expect(intent.type, equals(VoiceIntentType.repeatDirections));

      final result = await actionExecutor.execute(intent, locale: 'en-IN');
      expect(result.success, isTrue);
      expect(result.spokenFeedback, contains('Continuing straight'));
    });

    test('Command 4: Answer read-only trip questions (speed, distance, status)', () async {
      final intent = IntentResolver.resolve('what is our current speed', currentLocale: 'en-IN');
      expect(intent.type, equals(VoiceIntentType.queryTripStatus));

      final result = await actionExecutor.execute(intent, locale: 'en-IN');
      expect(result.success, isTrue);
      expect(result.spokenFeedback, contains('km/h'));
    });

    test('Scope Guard: Higher-risk commands (messaging) are deferred in Phase 1', () async {
      await controller.startListening();
      await controller.handleSpeechComplete('Send message to Rohit wait for me');

      expect(mockTts.spokenHistory.last, contains('enabled in the next release phase'));
    });
  });
}
