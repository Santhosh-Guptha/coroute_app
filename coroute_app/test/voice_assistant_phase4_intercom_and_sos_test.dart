import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/safety_service.dart';
import 'package:coroute_app/data/services/voice/intent_resolver.dart';
import 'package:coroute_app/data/services/voice/speech_recognition_adapter.dart';
import 'package:coroute_app/data/services/voice/text_to_speech_adapter.dart';
import 'package:coroute_app/data/services/voice/voice_action_executor.dart';
import 'package:coroute_app/data/services/voice/voice_assistant_controller.dart';
import 'package:coroute_app/data/services/voice/voice_command_intent.dart';

/// Fake implementation of IntercomService for testing Phase 4 intercom commands.
class FakeIntercomService extends ChangeNotifier implements IntercomService {
  bool _micMuted = false;
  String? _talkTargetUserId;
  String? _talkTargetName;

  @override
  bool get isMicMuted => _micMuted;

  @override
  String? get talkTargetUserId => _talkTargetUserId;

  @override
  String? get talkTargetName => _talkTargetName;

  @override
  bool get isPrivateTalk => _talkTargetUserId != null;

  @override
  void setMicMuted(bool v) {
    _micMuted = v;
    notifyListeners();
  }

  @override
  void setTalkTarget({String? userId, String? name}) {
    _talkTargetUserId = (userId == null || userId.isEmpty) ? null : userId;
    _talkTargetName = _talkTargetUserId == null ? null : name;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Fake implementation of SafetyService for testing direct voice SOS commands.
class FakeSafetyService extends ChangeNotifier implements SafetyService {
  int alarmSendNowCount = 0;
  int alarmImOkCount = 0;
  int silenceSirenCount = 0;

  @override
  void alarmSendNow() {
    alarmSendNowCount++;
    notifyListeners();
  }

  @override
  void alarmImOk() {
    alarmImOkCount++;
    notifyListeners();
  }

  @override
  void silenceSiren() {
    silenceSirenCount++;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Fake implementation of ConvoyService for testing Phase 4 voice commands.
class FakeConvoyService extends ChangeNotifier implements ConvoyService {
  @override
  String? myUserId = 'user_me';

  @override
  bool canEditRoute = true;

  @override
  ConvoyModel? activeConvoy;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('CoRoute Voice Assistant Phase 4: Intercom Handshake, Audio Control & Direct SOS Test Suite', () {
    late MockSpeechRecognitionAdapter mockSpeech;
    late MockTextToSpeechAdapter mockTts;
    late FakeIntercomService fakeIntercom;
    late FakeSafetyService fakeSafety;
    late FakeConvoyService fakeConvoy;
    late VoiceActionExecutor actionExecutor;
    late VoiceAssistantController controller;

    final mockRoster = {
      'user_me': RiderModel(
        userId: 'user_me',
        name: 'Lead Me',
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
      'u1': RiderModel(
        userId: 'u1',
        name: 'Rohit Sharma',
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
      'u2': RiderModel(
        userId: 'u2',
        name: 'Rohit Verma',
        vehicleType: 'BIKE',
        vehicleColor: 'Red',
        lat: 12.9710,
        lng: 77.5940,
        speedKmh: 62.0,
        heading: 90.0,
        batteryLevel: 92,
        isCharging: true,
        role: 'PACK',
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
      'u3': RiderModel(
        userId: 'u3',
        name: 'Ananya Rao',
        vehicleType: 'BIKE',
        vehicleColor: 'White',
        lat: 12.9725,
        lng: 77.5955,
        speedKmh: 59.0,
        heading: 90.0,
        batteryLevel: 80,
        isCharging: false,
        role: 'SWEEPER',
        statusReason: '',
        statusMessage: '',
        lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
        phone: '9876543216',
        emergencyContact: '9876543217',
        emergencyContactName: 'Contact4',
        vehicleNo: 'KA01GH3456',
        isCoRiding: false,
        ridingWithUserId: '',
        fuelUpdatedAt: 0,
      ),
    };

    ConvoyModel buildConvoy() {
      return ConvoyModel(
        groupId: 'grp_milestone5',
        name: 'Highway Patrol',
        joinCode: 'PATROL1',
        tripStatus: 'STARTED',
        createdByUserId: 'user_me',
        createdByUserName: 'Lead Me',
        createdAtEpochMs: 1000,
        voiceGuidanceEnabled: true,
        riders: mockRoster,
      );
    }

    setUp(() {
      mockSpeech = MockSpeechRecognitionAdapter();
      mockTts = MockTextToSpeechAdapter();
      fakeIntercom = FakeIntercomService();
      fakeSafety = FakeSafetyService();
      fakeConvoy = FakeConvoyService();
      fakeConvoy.activeConvoy = buildConvoy();

      actionExecutor = VoiceActionExecutor(
        initialVolume: 0.8,
        convoyService: fakeConvoy,
        intercomService: fakeIntercom,
        safetyService: fakeSafety,
      );

      controller = VoiceAssistantController(
        speechAdapter: mockSpeech,
        actionExecutor: actionExecutor,
        ttsAdapter: mockTts,
        convoyService: fakeConvoy,
        intercomService: fakeIntercom,
        safetyService: fakeSafety,
        initialLocale: 'en-IN',
        enforcePhase1Scope: false,
        allowMessaging: true,
        allowStopsAndAlerts: true,
        allowIntercom: true,
      );
    });

    tearDown(() {
      controller.dispose();
    });

    // ------------------------------------------------------------------------
    // 1. REQUEST_INTERCOM (1:1 Private Handshake & Disambiguation)
    // ------------------------------------------------------------------------
    group('1. Request Intercom Handshake & Disambiguation', () {
      test('Exact match recipient resolves and initiates private intercom handshake upon confirm', () async {
        await controller.startListening();
        await controller.handleSpeechComplete('Connect private intercom to Ananya');

        expect(controller.state, equals(VoiceSessionState.confirming));
        expect(controller.pendingIntent?.slots['recipient'], equals('Ananya Rao'));
        expect(controller.pendingIntent?.slots['recipientId'], equals('u3'));
        expect(mockTts.spokenHistory.last, contains('Connect private intercom to Ananya Rao'));

        // Confirm
        await controller.handleSpeechComplete('Confirm');

        expect(fakeIntercom.talkTargetUserId, equals('u3'));
        expect(fakeIntercom.talkTargetName, equals('Ananya Rao'));
        expect(fakeIntercom.isPrivateTalk, isTrue);
        expect(mockTts.spokenHistory.last, contains('Private intercom request sent to Ananya Rao'));
      });

      test('Multilingual postpositions in Telugu/Hindi/Malayalam resolve recipient cleanly', () {
        final te = IntentResolver.resolve('Rohit tho private intercom connect chey', currentLocale: 'te-IN');
        expect(te.type, equals(VoiceIntentType.requestIntercom));
        expect(te.slots['recipient'], equals('Rohit'));

        final hi = IntentResolver.resolve('Rohit se private intercom connect karo', currentLocale: 'hi-IN');
        expect(hi.type, equals(VoiceIntentType.requestIntercom));
        expect(hi.slots['recipient'], equals('Rohit'));

        final ml = IntentResolver.resolve('Rohit-inu private intercom request ayakkuka', currentLocale: 'ml-IN');
        expect(ml.type, equals(VoiceIntentType.requestIntercom));
        expect(ml.slots['recipient'], equals('Rohit'));
      });

      test('Ambiguous recipient triggers multi-turn clarification prompt ("Which Rohit?")', () async {
        await controller.startListening();
        await controller.handleSpeechComplete('Connect private intercom to Rohit');

        expect(controller.state, equals(VoiceSessionState.confirming));
        expect(controller.isDisambiguating, isTrue);
        expect(controller.disambiguationCandidates.length, equals(2));
        expect(mockTts.spokenHistory.last, contains('Which Rohit? Rohit Sharma or Rohit Verma?'));

        // Rider disambiguates by choosing "Rohit Verma"
        await controller.handleSpeechComplete('Rohit Verma');

        expect(controller.isDisambiguating, isFalse);
        expect(controller.pendingIntent?.slots['recipient'], equals('Rohit Verma'));
        expect(controller.pendingIntent?.slots['recipientId'], equals('u2'));
        expect(mockTts.spokenHistory.last, contains('Connect private intercom to Rohit Verma'));

        // Rider confirms
        await controller.handleSpeechComplete('Confirm');

        expect(fakeIntercom.talkTargetUserId, equals('u2'));
        expect(fakeIntercom.talkTargetName, equals('Rohit Verma'));
      });

      test('Recipient absent from convoy returns not-found notice', () async {
        await controller.startListening();
        await controller.handleSpeechComplete('Connect private intercom to Vikram');

        expect(controller.pendingIntent, isNull);
        expect(mockTts.spokenHistory.last, contains('not found in your convoy'));
        expect(fakeIntercom.isPrivateTalk, isFalse);
      });

      test('Solo rider without active convoy is blocked from intercom by VoiceSafetyPolicy', () async {
        fakeConvoy.activeConvoy = null;

        await controller.startListening();
        await controller.handleSpeechComplete('Connect private intercom to Ananya');

        expect(controller.pendingIntent, isNull);
        expect(mockTts.spokenHistory.last, contains('No active convoy found'));
        expect(fakeIntercom.isPrivateTalk, isFalse);
      });
    });

    // ------------------------------------------------------------------------
    // 2. DISCONNECT_INTERCOM & MUTE_MICROPHONE
    // ------------------------------------------------------------------------
    group('2. Audio Management (Disconnect & Mic Mute)', () {
      test('Disconnect intercom resets talk target back to Everyone', () async {
        // Pre-condition: active private talk with Ananya
        fakeIntercom.setTalkTarget(userId: 'u3', name: 'Ananya Rao');
        expect(fakeIntercom.isPrivateTalk, isTrue);

        await controller.startListening();
        await controller.handleSpeechComplete('Disconnect intercom');

        expect(fakeIntercom.isPrivateTalk, isFalse);
        expect(fakeIntercom.talkTargetUserId, isNull);
        expect(fakeIntercom.talkTargetName, isNull);
        expect(mockTts.spokenHistory.last, contains('Switched back to group audio'));
      });

      test('Mute microphone toggles mute state on IntercomService', () async {
        expect(fakeIntercom.isMicMuted, isFalse);

        // Mute
        await controller.startListening();
        await controller.handleSpeechComplete('Mute microphone');

        expect(fakeIntercom.isMicMuted, isTrue);
        expect(mockTts.spokenHistory.last, contains('Microphone muted'));

        // Unmute
        await controller.startListening();
        await controller.handleSpeechComplete('Unmute mic');

        expect(fakeIntercom.isMicMuted, isFalse);
        expect(mockTts.spokenHistory.last, contains('Microphone unmuted'));
      });
    });

    // ------------------------------------------------------------------------
    // 3. DIRECT LIFE SAFETY & SOS (Tier 4 Fast-Path Bypass)
    // ------------------------------------------------------------------------
    group('3. Direct Fast-Path SOS Integration (Zero Conversational Delay)', () {
      test('Utterance "CoRoute Emergency" triggers SOS immediately without confirmation loop', () async {
        await controller.startListening();
        await controller.handleSpeechComplete('CoRoute emergency');

        // Bypasses confirmation: pendingIntent is null, executes at once
        expect(controller.pendingIntent, isNull);
        expect(fakeSafety.alarmSendNowCount, equals(1));
        expect(mockTts.spokenHistory.last, contains('Emergency SOS triggered'));
      });

      test('Utterance "CoRoute I\'m OK" cancels active crash alarm immediately', () async {
        await controller.startListening();
        await controller.handleSpeechComplete('CoRoute im ok');

        expect(controller.pendingIntent, isNull);
        expect(fakeSafety.alarmImOkCount, equals(1));
        expect(mockTts.spokenHistory.last, contains('Crash alarm cancelled'));
      });

      test('Utterance "Silence siren" silences bystander siren immediately', () async {
        await controller.startListening();
        await controller.handleSpeechComplete('Silence siren');

        expect(controller.pendingIntent, isNull);
        expect(fakeSafety.silenceSirenCount, equals(1));
        expect(mockTts.spokenHistory.last, contains('Siren silenced'));
      });
    });

    // ------------------------------------------------------------------------
    // 4. HARDWARE ARBITRATION & EMERGENCY PRE-EMPTION
    // ------------------------------------------------------------------------
    group('4. Hardware Mic Arbitration & Safety Pre-emption', () {
      test('Voice session pauses Intercom VOX during speech and unpauses after finish', () async {
        fakeIntercom.setMicMuted(false);
        expect(fakeIntercom.isMicMuted, isFalse);

        await controller.startListening();

        // While listening, intercom mic must be muted to avoid packet collision
        expect(fakeIntercom.isMicMuted, isTrue);

        await controller.handleSpeechComplete('Mute microphone');

        // Once speech capture ends and action executes, mic state is handled cleanly
        expect(controller.state, equals(VoiceSessionState.idle));
      });

      test('Crash pre-emption immediately halts active intercom dialogue', () async {
        await controller.startListening();
        await controller.handleSpeechComplete('Connect private intercom to Ananya');

        expect(controller.state, equals(VoiceSessionState.confirming));
        expect(controller.pendingIntent, isNotNull);

        // Hardware crash detector fires emergency pre-emption
        controller.onEmergencyPreempt();

        expect(controller.state, equals(VoiceSessionState.idle));
        expect(controller.pendingIntent, isNull);
        expect(controller.statusFeedback, contains('Preempted by Safety SOS'));
        expect(fakeIntercom.isPrivateTalk, isFalse);
      });
    });

    // ------------------------------------------------------------------------
    // 5. PHASE SCOPE GATING
    // ------------------------------------------------------------------------
    group('5. Phase Scope Gating Enforcement', () {
      test('When allowIntercom is false, intercom commands are deferred but SOS commands ALWAYS work', () async {
        final scopedController = VoiceAssistantController(
          speechAdapter: mockSpeech,
          actionExecutor: actionExecutor,
          ttsAdapter: mockTts,
          convoyService: fakeConvoy,
          intercomService: fakeIntercom,
          safetyService: fakeSafety,
          enforcePhase1Scope: true,
          allowIntercom: false,
        );

        // Intercom is scoped out
        await scopedController.startListening();
        await scopedController.handleSpeechComplete('Disconnect intercom');
        expect(mockTts.spokenHistory.last, contains('enabled in the next release phase'));

        // Life Safety SOS is NEVER scoped out (Tier 4 invariant)
        await scopedController.startListening();
        await scopedController.handleSpeechComplete('CoRoute emergency');
        expect(fakeSafety.alarmSendNowCount, equals(1));
        expect(mockTts.spokenHistory.last, contains('Emergency SOS triggered'));

        scopedController.dispose();
      });
    });
  });
}
