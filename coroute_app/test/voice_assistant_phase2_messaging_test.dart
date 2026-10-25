import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/voice/intent_resolver.dart';
import 'package:coroute_app/data/services/voice/language_resolver.dart';
import 'package:coroute_app/data/services/voice/recipient_resolver.dart';
import 'package:coroute_app/data/services/voice/speech_recognition_adapter.dart';
import 'package:coroute_app/data/services/voice/text_to_speech_adapter.dart';
import 'package:coroute_app/data/services/voice/voice_action_executor.dart';
import 'package:coroute_app/data/services/voice/voice_assistant_controller.dart';
import 'package:coroute_app/data/services/voice/voice_command_intent.dart';

void main() {
  group('CoRoute Voice Assistant Phase 2: Recipient-Resolved Messaging & Outbox Test Suite', () {
    late MockSpeechRecognitionAdapter mockSpeech;
    late MockTextToSpeechAdapter mockTts;
    late VoiceActionExecutor actionExecutor;
    late VoiceAssistantController controller;

    final mockRoster = [
      RiderModel(
        userId: 'u1',
        name: 'Rohit Sharma',
        vehicleType: 'BIKE',
        vehicleColor: 'Black',
        lat: 12.9716,
        lng: 77.5946,
        speedKmh: 65.0,
        heading: 90.0,
        batteryLevel: 85,
        isCharging: false,
        role: 'LEAD',
        statusReason: '',
        statusMessage: '',
        lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
        phone: '9876543210',
        emergencyContact: '9876543211',
        emergencyContactName: 'Contact',
        vehicleNo: 'KA01AB1234',
        isCoRiding: false,
        ridingWithUserId: '',
        fuelUpdatedAt: 0,
      ),
      RiderModel(
        userId: 'u2',
        name: 'Rohit Verma',
        vehicleType: 'BIKE',
        vehicleColor: 'Blue',
        lat: 12.9720,
        lng: 77.5950,
        speedKmh: 60.0,
        heading: 90.0,
        batteryLevel: 78,
        isCharging: false,
        role: 'PACK',
        statusReason: '',
        statusMessage: '',
        lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
        phone: '9876543212',
        emergencyContact: '9876543213',
        emergencyContactName: 'Contact2',
        vehicleNo: 'KA01CD5678',
        isCoRiding: false,
        ridingWithUserId: '',
        fuelUpdatedAt: 0,
      ),
      RiderModel(
        userId: 'u3',
        name: 'Ananya Rao',
        vehicleType: 'BIKE',
        vehicleColor: 'Red',
        lat: 12.9710,
        lng: 77.5940,
        speedKmh: 62.0,
        heading: 90.0,
        batteryLevel: 92,
        isCharging: true,
        role: 'SWEEPER',
        statusReason: '',
        statusMessage: '',
        lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
        phone: '9876543214',
        emergencyContact: '9876543215',
        emergencyContactName: 'Contact3',
        vehicleNo: 'KA01EF9012',
        isCoRiding: false,
        ridingWithUserId: '',
        fuelUpdatedAt: 0,
      ),
    ];

    setUp(() {
      mockSpeech = MockSpeechRecognitionAdapter();
      mockTts = MockTextToSpeechAdapter();
      actionExecutor = VoiceActionExecutor(initialVolume: 0.8);
      controller = VoiceAssistantController(
        speechAdapter: mockSpeech,
        actionExecutor: actionExecutor,
        ttsAdapter: mockTts,
        initialLocale: 'en-IN',
        enforcePhase1Scope: false, // Phase 2: Messaging allowed
        allowMessaging: true,
      );
    });

    tearDown(() {
      controller.dispose();
    });

    // ------------------------------------------------------------------------
    // 1. Recipient Resolver Unit Tests
    // ------------------------------------------------------------------------
    test('RecipientResolver: Exact match on full name returns single rider', () {
      final res = RecipientResolver.resolve(
        rawRecipient: 'Ananya Rao',
        activeRiders: mockRoster,
        locale: 'en-IN',
      );

      expect(res.isExact, isTrue);
      expect(res.matchedRider?.name, equals('Ananya Rao'));
      expect(res.matchedRider?.userId, equals('u3'));
    });

    test('RecipientResolver: Dative postposition stripping across Dravidian/Indo-Aryan grammars', () {
      final postpositions = [
        ('Rohit-ki', 'Rohit'),
        ('Rohit-ko', 'Rohit'),
        ('Rohit-ku', 'Rohit'),
        ('Rohit-ge', 'Rohit'),
        ('Rohit-inu', 'Rohit'),
        ('Rohit-la', 'Rohit'),
        ('Rohit-ne', 'Rohit'),
      ];

      for (final (raw, expected) in postpositions) {
        final stripped = LanguageResolver.extractBaseRecipient(raw);
        expect(stripped, equals(expected));
      }
    });

    test('RecipientResolver: Disambiguation triggered when multiple candidates share first name', () {
      final res = RecipientResolver.resolve(
        rawRecipient: 'Rohit',
        activeRiders: mockRoster,
        locale: 'en-IN',
      );

      expect(res.isAmbiguous, isTrue);
      expect(res.candidates.length, equals(2));
      expect(res.candidates.map((r) => r.name), containsAll(['Rohit Sharma', 'Rohit Verma']));
      expect(res.clarificationPrompt, equals('Which Rohit? Rohit Sharma or Rohit Verma?'));
    });

    test('RecipientResolver: Phonetic fuzzy match resolves slight speech transcription variations', () {
      final res = RecipientResolver.resolve(
        rawRecipient: 'Ananya',
        activeRiders: mockRoster,
        locale: 'en-IN',
      );

      expect(res.isExact, isTrue);
      expect(res.matchedRider?.name, equals('Ananya Rao'));
    });

    test('RecipientResolver: Returns not found when queried name is absent from convoy', () {
      final res = RecipientResolver.resolve(
        rawRecipient: 'Kiran Kumar',
        activeRiders: mockRoster,
        locale: 'en-IN',
      );

      expect(res.isNotFound, isTrue);
      expect(res.matchedRider, isNull);
      expect(res.clarificationPrompt, contains('not found in your convoy'));
    });

    // ------------------------------------------------------------------------
    // 2. Two-Step Confirmation Loop (Execute, Cancel, Timeout)
    // ------------------------------------------------------------------------
    test('Confirmation Loop: User says "Send" confirms and executes message', () async {
      await controller.startListening();
      await controller.handleSpeechComplete('Send message to Ananya wait for me');

      expect(controller.state, equals(VoiceSessionState.confirming));
      expect(controller.pendingIntent, isNotNull);
      expect(controller.pendingIntent?.slots['recipient'], equals('Ananya'));

      // Rider verbally confirms "Send"
      await controller.handleSpeechComplete('Send');

      expect(controller.pendingIntent, isNull);
      expect(mockTts.spokenHistory.any((s) => s.contains('outbox') || s.contains('sent')), isTrue);
    });

    test('Confirmation Loop: User says "Cancel" discards message without sending', () async {
      await controller.startListening();
      await controller.handleSpeechComplete('Send message to Ananya road is clear');

      expect(controller.state, equals(VoiceSessionState.confirming));
      expect(controller.pendingIntent, isNotNull);

      // Rider cancels
      await controller.handleSpeechComplete('Cancel');

      expect(controller.pendingIntent, isNull);
      expect(mockTts.spokenHistory.last, contains('cancelled'));
    });

    test('Confirmation Loop: Discard on 10s confirmation timeout', () async {
      await controller.startListening();
      await controller.handleSpeechComplete('Send message to Ananya check tyre pressure');

      expect(controller.state, equals(VoiceSessionState.confirming));
      expect(controller.pendingIntent, isNotNull);

      // Trigger timeout cancel
      await controller.cancelSession(reason: 'Confirmation timed out');

      expect(controller.state, equals(VoiceSessionState.cancelled));
      expect(controller.pendingIntent, isNull);
    });

    // ------------------------------------------------------------------------
    // 3. Offline Outbox Queueing & Notice
    // ------------------------------------------------------------------------
    test('Offline Outbox: Sending message while offline queues to outbox with verbal notice', () async {
      final intent = VoiceCommandIntent(
        type: VoiceIntentType.sendMessage,
        slots: {'recipient': 'Vikram', 'body': 'Taking short water break'},
        sourceLocale: 'en-IN',
        rawTranscript: 'message Vikram Taking short water break',
        requiresConfirmation: false,
      );

      final result = await actionExecutor.execute(intent, locale: 'en-IN');

      expect(result.success, isTrue);
      expect(result.isOfflineQueued, isTrue);
      expect(result.spokenFeedback, contains('queued in outbox'));
      expect(result.visualNotification, equals('Sent to Vikram'));
    });

    // ------------------------------------------------------------------------
    // 4. 12-Language Messaging Corpus Coverage
    // ------------------------------------------------------------------------
    test('Multilingual Corpus: Validates message command parsing across all 12 target locales', () {
      final corpus = {
        'te-IN': 'Rohit ki message send chey five minutes lo reach avtha',
        'hi-IN': 'Rohit ko message bhejo main thoda late ho jaunga',
        'ta-IN': 'Rohit ku message anupu ready ah iru',
        'kn-IN': 'Rohit ge message maadi slow down maadi',
        'mr-IN': 'Rohit la message pathva rastyat traffic ahe',
        'ml-IN': 'Rohit inu message ayakkuka njan etharayi',
        'bn-IN': 'Rohit ke message pathao ami aschi',
        'gu-IN': 'Rohit ne message moko hu aavu chu',
        'pa-IN': 'Rohit nu message bhejo raste vich haan',
        'or-IN': 'Rohit ku message pathao mu pahanchu chi',
        'as-IN': 'Rohit k message pothua moi aahi asu',
        'en-IN': 'Send message to Rohit wait for me',
      };

      for (final entry in corpus.entries) {
        final intent = IntentResolver.resolve(entry.value, currentLocale: entry.key);
        expect(
          intent.type,
          equals(VoiceIntentType.sendMessage),
          reason: 'Failed to resolve sendMessage for ${entry.key}: "${entry.value}"',
        );
        expect(intent.slots['recipient'], equals('Rohit'));
        expect(intent.requiresConfirmation, isTrue);
        expect(intent.riskTier, equals(2));
      }
    });

    // ------------------------------------------------------------------------
    // 5. Safety Pre-emption During Active Messaging
    // ------------------------------------------------------------------------
    test('Safety Preemption: 3.2G crash alarm during pending message immediately cancels draft', () async {
      await controller.startListening();
      await controller.handleSpeechComplete('Send message to Rohit five minutes');

      expect(controller.state, equals(VoiceSessionState.confirming));
      expect(controller.pendingIntent, isNotNull);

      // Accelerometer detects crash -> triggers emergency pre-emption
      controller.onEmergencyPreempt();

      expect(controller.state, equals(VoiceSessionState.idle));
      expect(controller.statusFeedback, contains('Preempted by Safety SOS'));
      expect(controller.pendingIntent, isNull);
      expect(controller.disambiguationCandidates, isEmpty);
    });
  });
}
