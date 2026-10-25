import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/services/voice/intent_resolver.dart';
import 'package:coroute_app/data/services/voice/language_resolver.dart';
import 'package:coroute_app/data/services/voice/localized_response_service.dart';
import 'package:coroute_app/data/services/voice/speech_recognition_adapter.dart';
import 'package:coroute_app/data/services/voice/voice_action_executor.dart';
import 'package:coroute_app/data/services/voice/voice_assistant_controller.dart';
import 'package:coroute_app/data/services/voice/voice_command_intent.dart';
import 'package:coroute_app/data/services/voice/voice_safety_policy.dart';

void main() {
  group('CoRoute Multilingual Voice Assistant Acceptance Tests (VA-001 to VA-020)', () {
    late MockSpeechRecognitionAdapter mockAdapter;
    late VoiceActionExecutor actionExecutor;
    late VoiceAssistantController controller;

    setUp(() {
      mockAdapter = MockSpeechRecognitionAdapter();
      actionExecutor = VoiceActionExecutor(initialVolume: 0.8);
      controller = VoiceAssistantController(
        speechAdapter: mockAdapter,
        actionExecutor: actionExecutor,
        initialLocale: 'en-IN',
        enforcePhase1Scope: false,
      );
    });

    tearDown(() {
      controller.dispose();
    });

    // ------------------------------------------------------------------------
    // VA-001: Telugu-English Mixed Code-Switching
    // ------------------------------------------------------------------------
    test('VA-001: Recognize Telugu-English mixed command: "Rohit ki message send chey"', () {
      final intent = IntentResolver.resolve(
        'Rohit ki message send chey five minutes lo reach avtha',
        currentLocale: 'te-IN',
      );

      expect(intent.type, equals(VoiceIntentType.sendMessage));
      expect(intent.slots['recipient'], equals('Rohit'));
      expect(intent.slots['body'], equals('five minutes lo reach avtha'));
      expect(intent.requiresConfirmation, isTrue);
      expect(intent.riskTier, equals(2));
    });

    // ------------------------------------------------------------------------
    // VA-002: Equivalent Commands in Hindi-English and Tamil-English
    // ------------------------------------------------------------------------
    test('VA-002: Equivalent commands in Hindi-English and Tamil-English resolve identically', () {
      final hindiIntent = IntentResolver.resolve(
        'Rohit ko message bhejo main thoda late ho jaunga',
        currentLocale: 'hi-IN',
      );
      expect(hindiIntent.type, equals(VoiceIntentType.sendMessage));
      expect(hindiIntent.slots['recipient'], equals('Rohit'));
      expect(hindiIntent.slots['body'], equals('main thoda late ho jaunga'));

      final tamilIntent = IntentResolver.resolve(
        'Rohit ku message anupu ready ah iru',
        currentLocale: 'ta-IN',
      );
      expect(tamilIntent.type, equals(VoiceIntentType.sendMessage));
      expect(tamilIntent.slots['recipient'], equals('Rohit'));
      expect(tamilIntent.slots['body'], equals('ready ah iru'));
    });

    // ------------------------------------------------------------------------
    // VA-003: 12-Language Matrix Coverage
    // ------------------------------------------------------------------------
    test('VA-003: Resolve intents correctly across all 12 target locales', () {
      final corpus = {
        'te-IN': 'Voice volume reduce chey',
        'hi-IN': 'Sab riders ko alert bhejo roadblock ahead',
        'en-IN': 'Find a petrol pump within five kilometres',
        'ta-IN': 'Voice volume konjam kammi pannu',
        'kn-IN': 'Next petrol bunk find maadi',
        'mr-IN': 'Pudhil stop kiti lamb ahe',
        'ml-IN': 'Rohit inu private intercom request ayakkuka',
        'bn-IN': 'Group alert pathao heavy rain',
        'gu-IN': 'Trip summary vancho',
        'pa-IN': 'Agla stop kithe hai',
        'or-IN': 'Aau kete dur achhi destination',
        'as-IN': 'Aamar speed kiba beshi hoise',
      };

      for (final entry in corpus.entries) {
        final intent = IntentResolver.resolve(entry.value, currentLocale: entry.key);
        expect(
          intent.type != VoiceIntentType.unknown,
          isTrue,
          reason: 'Failed to recognize locale ${entry.key}: "${entry.value}"',
        );
      }
    });

    // ------------------------------------------------------------------------
    // VA-004: Offline Unavailable Language Negotiation
    // ------------------------------------------------------------------------
    test('VA-004: Querying an unavailable offline language returns limitation notice', () async {
      final isOfflineOdia = await mockAdapter.isLocaleAvailableOffline('or-IN');
      expect(isOfflineOdia, isFalse);

      final notice = LocalizedResponseService.offlineLanguageUnavailable('Odia', 'English');
      expect(notice, contains('Offline mode active'));
      expect(notice, contains('Operating in English'));
    });

    // ------------------------------------------------------------------------
    // VA-005: Disambiguate Multiple Recipients ("Which Rohit?")
    // ------------------------------------------------------------------------
    test('VA-005: Disambiguation prompt generated when multiple candidates share a name', () {
      final prompt = LocalizedResponseService.disambiguatePrompt(
        name: 'Rohit',
        candidates: ['Rohit Sharma', 'Rohit Verma'],
        locale: 'en-IN',
      );

      expect(prompt, equals('Which Rohit? Rohit Sharma or Rohit Verma?'));
    });

    // ------------------------------------------------------------------------
    // VA-006: Message Cancellation Loop
    // ------------------------------------------------------------------------
    test('VA-006: Dictate message and say "Cancel" discards pending action', () async {
      await controller.startListening();
      mockAdapter.simulateUtterance('Send message to Rohit wait for me');

      expect(controller.state, equals(VoiceSessionState.confirming));
      expect(controller.pendingIntent, isNotNull);

      // Rider says "Cancel"
      await controller.handleSpeechComplete('Cancel');
      expect(controller.pendingIntent, isNull);
    });

    // ------------------------------------------------------------------------
    // VA-007: Offline Outbox Queueing Notice
    // ------------------------------------------------------------------------
    test('VA-007: Offline messaging queues to outbox with verbal notice', () async {
      final intent = VoiceCommandIntent(
        type: VoiceIntentType.sendMessage,
        slots: {'recipient': 'Vikram', 'body': 'Flat tyre'},
        sourceLocale: 'en-IN',
        rawTranscript: 'message Vikram Flat tyre',
      );

      final result = await actionExecutor.execute(intent, locale: 'en-IN');
      expect(result.success, isTrue);
      expect(result.isOfflineQueued, isTrue);
      expect(result.spokenFeedback, contains('queued in outbox'));
    });

    // ------------------------------------------------------------------------
    // VA-008: Essentials Query with Distance Constraint
    // ------------------------------------------------------------------------
    test('VA-008: Essentials query extracts category and radius', () {
      final intent = IntentResolver.resolve(
        'Find a petrol pump within five kilometres',
        currentLocale: 'en-IN',
      );

      expect(intent.type, equals(VoiceIntentType.findEssentials));
      expect(intent.slots['category'], equals('FUEL'));
      expect(intent.slots['radiusKm'], equals(5.0));
    });

    // ------------------------------------------------------------------------
    // VA-009: Dative Suffix Stripping Across Indian Grammars
    // ------------------------------------------------------------------------
    test('VA-009: Extract base recipient accurately from Dravidian/Indo-Aryan postpositions', () {
      expect(LanguageResolver.extractBaseRecipient('Rohit-ki'), equals('Rohit'));
      expect(LanguageResolver.extractBaseRecipient('Rohit-ku'), equals('Rohit'));
      expect(LanguageResolver.extractBaseRecipient('Rohit-ge'), equals('Rohit'));
      expect(LanguageResolver.extractBaseRecipient('Rohit-inu'), equals('Rohit'));
      expect(LanguageResolver.extractBaseRecipient('Rohit-la'), equals('Rohit'));
      expect(LanguageResolver.extractBaseRecipient('Rohit-ne'), equals('Rohit'));
    });

    // ------------------------------------------------------------------------
    // VA-010: Private Intercom Consent Handshake
    // ------------------------------------------------------------------------
    test('VA-010: Private intercom request prompts consent notice', () async {
      final intent = VoiceCommandIntent(
        type: VoiceIntentType.requestIntercom,
        slots: {'recipient': 'Ananya'},
        sourceLocale: 'en-IN',
        rawTranscript: 'connect private intercom to Ananya',
      );

      final result = await actionExecutor.execute(intent, locale: 'en-IN');
      expect(result.success, isTrue);
      expect(result.spokenFeedback, contains('Awaiting consent'));
    });

    // ------------------------------------------------------------------------
    // VA-011: Voice Volume Adjustment
    // ------------------------------------------------------------------------
    test('VA-011: Adjust voice volume by delta and absolute level', () async {
      final decreaseIntent = IntentResolver.resolve(
        'Voice volume konjam kammi pannu',
        currentLocale: 'ta-IN',
      );
      expect(decreaseIntent.type, equals(VoiceIntentType.setVoiceVolume));
      expect(decreaseIntent.slots['delta'], equals(-0.2));

      final result1 = await actionExecutor.execute(decreaseIntent, locale: 'en-IN');
      expect(actionExecutor.currentVolume, closeTo(0.6, 0.01));
      expect(result1.spokenFeedback, contains('60 percent'));

      final setIntent = IntentResolver.resolve(
        'set volume to 80 percent',
        currentLocale: 'en-IN',
      );
      expect(setIntent.slots['level'], equals(80));

      final result2 = await actionExecutor.execute(setIntent, locale: 'en-IN');
      expect(actionExecutor.currentVolume, closeTo(0.8, 0.01));
      expect(result2.spokenFeedback, contains('80 percent'));
    });

    // ------------------------------------------------------------------------
    // VA-012: Session Interruption Handling
    // ------------------------------------------------------------------------
    test('VA-012: Cancel session transitions controller state to cancelled', () async {
      await controller.startListening();
      expect(controller.isListening, isTrue);

      await controller.cancelSession(reason: 'Bluetooth headset disconnected');
      expect(controller.state, equals(VoiceSessionState.cancelled));
      expect(controller.statusFeedback, equals('Bluetooth headset disconnected'));
    });

    // ------------------------------------------------------------------------
    // VA-013: Fast-Path Emergency SOS Execution
    // ------------------------------------------------------------------------
    test('VA-013: Spoken "Emergency SOS" executes immediately without confirmation gate', () {
      final intent = IntentResolver.resolve('CoRoute emergency', currentLocale: 'en-IN');
      expect(intent.type, equals(VoiceIntentType.triggerSos));
      expect(intent.requiresConfirmation, isFalse);
      expect(intent.riskTier, equals(4));
    });

    // ------------------------------------------------------------------------
    // VA-014: Safety Pre-emption by Crash Detector
    // ------------------------------------------------------------------------
    test('VA-014: Crash alarm pre-emption instantly aborts active voice session', () async {
      await controller.startListening();
      expect(controller.isListening, isTrue);

      // Accelerometer detects crash -> triggers emergency preemption
      controller.onEmergencyPreempt();

      expect(controller.state, equals(VoiceSessionState.idle));
      expect(controller.statusFeedback, contains('Preempted by Safety SOS'));
      expect(controller.pendingIntent, isNull);
    });

    // ------------------------------------------------------------------------
    // VA-015: Group Alert Authorization Policy
    // ------------------------------------------------------------------------
    test('VA-015: Proposing route waypoint without Road Captain role is rejected', () {
      final intent = VoiceCommandIntent(
        type: VoiceIntentType.proposeStop,
        slots: {'forceWaypoint': true},
        sourceLocale: 'en-IN',
        rawTranscript: 'change route',
        riskTier: 3,
      );

      final rejection = VoiceSafetyPolicy.validateIntent(
        intent: intent,
        isRoadCaptain: false,
        isConvoyActive: true,
      );

      expect(rejection, contains('Road Captain'));
    });

    // ------------------------------------------------------------------------
    // VA-016: Forbidden Voice Safety Modification Gate
    // ------------------------------------------------------------------------
    test('VA-016: Attempting to disable crash detection via voice is rejected', () {
      final intent = VoiceCommandIntent(
        type: VoiceIntentType.unknown,
        sourceLocale: 'en-IN',
        rawTranscript: 'disable crash detection',
      );

      final rejection = VoiceSafetyPolicy.validateIntent(
        intent: intent,
        isRoadCaptain: true,
        isConvoyActive: true,
      );

      expect(rejection, contains('Safety rule'));
    });

    // ------------------------------------------------------------------------
    // VA-017: Single Active Session Guard
    // ------------------------------------------------------------------------
    test('VA-017: Concurrent startListening calls do not duplicate sessions', () async {
      final first = await controller.startListening();
      final second = await controller.startListening();

      expect(first, isTrue);
      expect(second, isTrue);
      expect(controller.state, equals(VoiceSessionState.listening));
    });

    // ------------------------------------------------------------------------
    // VA-018: Microphone Permission / Hardware Failure
    // ------------------------------------------------------------------------
    test('VA-018: Speech adapter error cancels session gracefully', () async {
      await controller.startListening();
      mockAdapter.simulateError('Microphone permission denied');

      expect(controller.state, equals(VoiceSessionState.cancelled));
      expect(controller.statusFeedback, equals('Microphone error'));
    });

    // ------------------------------------------------------------------------
    // VA-019: Silence Siren Voice Command
    // ------------------------------------------------------------------------
    test('VA-019: Silence siren executes immediately to reassure conscious rider', () {
      final intent = IntentResolver.resolve('silence siren', currentLocale: 'en-IN');
      expect(intent.type, equals(VoiceIntentType.silenceSiren));
      expect(intent.requiresConfirmation, isFalse);
    });

    // ------------------------------------------------------------------------
    // VA-020: Levenshtein Callsign Similarity Matcher
    // ------------------------------------------------------------------------
    test('VA-020: Fuzzy phonetic match correctly resolves minor speech variations', () {
      expect(LanguageResolver.calculateSimilarity('Rohit', 'Rohith'), greaterThanOrEqualTo(0.8));
      expect(LanguageResolver.calculateSimilarity('Vikram', 'Bikram'), greaterThanOrEqualTo(0.8));
      expect(LanguageResolver.calculateSimilarity('Suresh', 'Ramesh'), lessThan(0.7));
    });
  });
}
