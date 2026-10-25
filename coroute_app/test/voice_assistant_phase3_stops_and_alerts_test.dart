import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/voice/intent_resolver.dart';
import 'package:coroute_app/data/services/voice/speech_recognition_adapter.dart';
import 'package:coroute_app/data/services/voice/text_to_speech_adapter.dart';
import 'package:coroute_app/data/services/voice/voice_action_executor.dart';
import 'package:coroute_app/data/services/voice/voice_assistant_controller.dart';
import 'package:coroute_app/data/services/voice/voice_command_intent.dart';

/// Fake implementation of ConvoyService for testing Phase 3 voice commands.
class FakeConvoyService extends ChangeNotifier implements ConvoyService {
  @override
  String? myUserId = 'user_rider';

  @override
  bool canEditRoute = true;

  @override
  ConvoyModel? activeConvoy;

  // Recorded actions for test verification
  final List<Map<String, dynamic>> sentMessages = [];
  final List<String> waitRequests = [];
  final List<Map<String, dynamic>> addedStops = [];

  @override
  void sendGroupMessage({
    required String senderId,
    required String senderName,
    required String text,
    String? groupId,
    String? localClientId,
    bool isQuickCard = false,
    String cardType = 'CUSTOM',
  }) {
    sentMessages.add({
      'senderId': senderId,
      'senderName': senderName,
      'text': text,
      'groupId': groupId,
      'isQuickCard': isQuickCard,
      'cardType': cardType,
    });
  }

  @override
  void requestWait(String requesterName) {
    waitRequests.add(requesterName);
  }

  @override
  void addStopPoint({
    required String name,
    required double lat,
    required double lng,
    String category = 'REST',
  }) {
    addedStops.add({
      'name': name,
      'lat': lat,
      'lng': lng,
      'category': category,
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('CoRoute Voice Assistant Phase 3: Stops, Essentials & Convoy Regrouping/Alerts Test Suite', () {
    late MockSpeechRecognitionAdapter mockSpeech;
    late MockTextToSpeechAdapter mockTts;
    late FakeConvoyService fakeConvoy;
    late VoiceActionExecutor actionExecutor;
    late VoiceAssistantController controller;

    ConvoyModel buildConvoy({
      required String myRole,
      required bool isGpsStale,
    }) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final myTimestamp = isGpsStale ? now - 90000 : now; // 90s ago if stale (>60s)

      return ConvoyModel(
        groupId: 'grp_phase3_test',
        name: 'Nilgiris Expedition',
        joinCode: 'NILG01',
        tripStatus: 'STARTED',
        createdByUserId: myRole == 'LEAD' ? 'user_rider' : 'lead_captain',
        createdByUserName: myRole == 'LEAD' ? 'Rider Lead' : 'Captain Vikram',
        createdAtEpochMs: now - 3600000,
        voiceGuidanceEnabled: true,
        riders: {
          'user_rider': RiderModel(
            userId: 'user_rider',
            name: 'Rider Me',
            role: myRole,
            vehicleType: 'BIKE',
            vehicleColor: 'Black',
            lat: 11.4102,
            lng: 76.6950,
            speedKmh: 58.0,
            heading: 180.0,
            batteryLevel: 90,
            isCharging: false,
            statusReason: '',
            statusMessage: '',
            lastSeenEpochMs: myTimestamp,
            phone: '9876543210',
            emergencyContact: '9876543211',
            emergencyContactName: 'ICE Contact',
            vehicleNo: 'KA01AB1234',
            isCoRiding: false,
            ridingWithUserId: '',
            fuelUpdatedAt: 0,
          ),
          'lead_captain': RiderModel(
            userId: 'lead_captain',
            name: 'Captain Vikram',
            role: 'LEAD',
            vehicleType: 'BIKE',
            vehicleColor: 'Orange',
            lat: 11.4150,
            lng: 76.6960,
            speedKmh: 60.0,
            heading: 180.0,
            batteryLevel: 88,
            isCharging: false,
            statusReason: '',
            statusMessage: '',
            lastSeenEpochMs: now,
            phone: '9876543220',
            emergencyContact: '9876543221',
            emergencyContactName: 'ICE Vikram',
            vehicleNo: 'KA01CD5678',
            isCoRiding: false,
            ridingWithUserId: '',
            fuelUpdatedAt: 0,
          ),
        },
      );
    }

    setUp(() {
      mockSpeech = MockSpeechRecognitionAdapter();
      mockTts = MockTextToSpeechAdapter();
      fakeConvoy = FakeConvoyService();
      fakeConvoy.activeConvoy = buildConvoy(myRole: 'LEAD', isGpsStale: false);
      fakeConvoy.canEditRoute = true;

      actionExecutor = VoiceActionExecutor(
        initialVolume: 0.8,
        convoyService: fakeConvoy,
      );

      controller = VoiceAssistantController(
        speechAdapter: mockSpeech,
        actionExecutor: actionExecutor,
        ttsAdapter: mockTts,
        convoyService: fakeConvoy,
        initialLocale: 'en-IN',
        enforcePhase1Scope: false,
        allowMessaging: true,
        allowStopsAndAlerts: true,
      );
    });

    tearDown(() {
      controller.dispose();
    });

    // ------------------------------------------------------------------------
    // 1. FIND ESSENTIALS (Category Slot Extraction & Radius Parsing)
    // ------------------------------------------------------------------------
    group('1. Find Essentials Parsing & Immediate Local Execution', () {
      test('Extracts FUEL category and default 10km radius', () {
        final intent = IntentResolver.resolve('Find petrol pump nearby', currentLocale: 'en-IN');
        expect(intent.type, equals(VoiceIntentType.findEssentials));
        expect(intent.slots['category'], equals('FUEL'));
        expect(intent.slots['radiusKm'], equals(10.0));
        expect(intent.requiresConfirmation, isFalse);
      });

      test('Extracts FUEL category with explicit 5 km distance constraint', () {
        final intent = IntentResolver.resolve('Find petrol station within 5 km', currentLocale: 'en-IN');
        expect(intent.type, equals(VoiceIntentType.findEssentials));
        expect(intent.slots['category'], equals('FUEL'));
        expect(intent.slots['radiusKm'], equals(5.0));
      });

      test('Extracts PUNCTURE category and parses distance constraint', () {
        final intent = IntentResolver.resolve('Find puncture repair shop 15 km', currentLocale: 'en-IN');
        expect(intent.type, equals(VoiceIntentType.findEssentials));
        expect(intent.slots['category'], equals('PUNCTURE'));
        expect(intent.slots['radiusKm'], equals(15.0));
      });

      test('Extracts HOSPITAL category and clinic keywords', () {
        final intent = IntentResolver.resolve('Nearest emergency hospital clinic', currentLocale: 'en-IN');
        expect(intent.type, equals(VoiceIntentType.findEssentials));
        expect(intent.slots['category'], equals('HOSPITAL'));
      });

      test('Extracts FOOD/REST category with Indian dhaba / chai keywords', () {
        final intent = IntentResolver.resolve('Find restaurant or dhaba along route', currentLocale: 'en-IN');
        expect(intent.type, equals(VoiceIntentType.findEssentials));
        expect(intent.slots['category'], equals('FOOD'));
      });

      test('Executes findEssentials immediately and returns spoken on-route guidance', () async {
        await controller.startListening();
        await controller.handleSpeechComplete('Find petrol pump nearby');

        expect(controller.state, equals(VoiceSessionState.idle));
        expect(mockTts.spokenHistory.last, contains('fuel station'));
        expect(mockTts.spokenHistory.last, contains('on your route'));
      });
    });

    // ------------------------------------------------------------------------
    // 2. BROADCAST ALERT (2-Step Confirmation Loop & Quick Card Dispatch)
    // ------------------------------------------------------------------------
    group('2. Broadcast Group Alert Confirmation & Dispatch', () {
      test('Broadcast alert transitions to confirming state and prompts for verbal consent', () async {
        await controller.startListening();
        await controller.handleSpeechComplete('Broadcast alert heavy oil spill on road');

        expect(controller.state, equals(VoiceSessionState.confirming));
        expect(controller.pendingIntent, isNotNull);
        expect(controller.pendingIntent?.type, equals(VoiceIntentType.broadcastAlert));
        expect(controller.pendingIntent?.slots['body'], equals('heavy oil spill on road'));
        expect(mockTts.spokenHistory.last, contains('Broadcast alert to all riders'));
      });

      test('Saying "Confirm" dispatches hazard quick-card to convoy and completes session', () async {
        await controller.startListening();
        await controller.handleSpeechComplete('Broadcast alert sharp blind turn ahead');

        expect(controller.state, equals(VoiceSessionState.confirming));

        // Rider confirms verbally
        await controller.handleSpeechComplete('Confirm');

        expect(controller.pendingIntent, isNull);
        expect(controller.state, equals(VoiceSessionState.idle));
        expect(fakeConvoy.sentMessages.length, equals(1));
        final msg = fakeConvoy.sentMessages.first;
        expect(msg['isQuickCard'], isTrue);
        expect(msg['cardType'], equals('HAZARD'));
        expect(msg['text'], contains('sharp blind turn ahead'));
        expect(mockTts.spokenHistory.last, contains('Group alert broadcast to all riders'));
      });

      test('Saying "Cancel" discards alert without dispatching to convoy', () async {
        await controller.startListening();
        await controller.handleSpeechComplete('Broadcast alert slow moving tractor');

        expect(controller.state, equals(VoiceSessionState.confirming));

        // Rider cancels
        await controller.handleSpeechComplete('Cancel');

        expect(controller.pendingIntent, isNull);
        expect(fakeConvoy.sentMessages, isEmpty);
        expect(mockTts.spokenHistory.last, contains('cancelled'));
      });
    });

    // ------------------------------------------------------------------------
    // 3. REQUEST REGROUP (Wait Signal to Convoy)
    // ------------------------------------------------------------------------
    group('3. Request Convoy Regroup / Wait', () {
      test('Parses regroup utterances in English and Indian idioms', () {
        final e1 = IntentResolver.resolve('Regroup convoy', currentLocale: 'en-IN');
        expect(e1.type, equals(VoiceIntentType.requestRegroup));

        final e2 = IntentResolver.resolve('Wait for me', currentLocale: 'en-IN');
        expect(e2.type, equals(VoiceIntentType.requestRegroup));

        final e3 = IntentResolver.resolve('koncham aagandi', currentLocale: 'te-IN');
        expect(e3.type, equals(VoiceIntentType.requestRegroup));
      });

      test('Request regroup enters confirmation and calls convoyService.requestWait upon confirm', () async {
        await controller.startListening();
        await controller.handleSpeechComplete('Wait for me');

        expect(controller.state, equals(VoiceSessionState.confirming));
        expect(mockTts.spokenHistory.last, contains('wait and regroup'));

        // Confirm
        await controller.handleSpeechComplete('Confirm');

        expect(fakeConvoy.waitRequests.length, equals(1));
        expect(fakeConvoy.waitRequests.first, equals('Rider Me'));
        expect(mockTts.spokenHistory.last, contains('Wait request broadcast to convoy'));
      });
    });

    // ------------------------------------------------------------------------
    // 4. PROPOSE STOP & ROAD CAPTAIN AUTHORIZATION GATE
    // ------------------------------------------------------------------------
    group('4. Propose Stop & Road Captain Role Authorization', () {
      test('Road Captain proposing official waypoint succeeds and adds stop point', () async {
        fakeConvoy.canEditRoute = true;
        fakeConvoy.activeConvoy = buildConvoy(myRole: 'LEAD', isGpsStale: false);

        await controller.startListening();
        await controller.handleSpeechComplete('Change route add official stop at CCD Cafe');

        expect(controller.state, equals(VoiceSessionState.confirming));
        expect(controller.pendingIntent?.slots['name'].toString().toLowerCase(), equals('ccd cafe'));
        expect(controller.pendingIntent?.slots['forceWaypoint'], isTrue);

        await controller.handleSpeechComplete('Confirm');

        expect(fakeConvoy.addedStops.length, equals(1));
        expect(fakeConvoy.addedStops.first['name'].toString().toLowerCase(), equals('ccd cafe'));
        expect(mockTts.spokenHistory.last.toLowerCase(), contains('official convoy stop published at ccd cafe'));
      });

      test('Pack Member attempting official route mutation is blocked by VoiceSafetyPolicy', () async {
        fakeConvoy.canEditRoute = false;
        fakeConvoy.activeConvoy = buildConvoy(myRole: 'PACK', isGpsStale: false);

        await controller.startListening();
        await controller.handleSpeechComplete('Change route add official stop at Petrol Pump');

        // Blocked immediately by VoiceSafetyPolicy.validateIntent and dismissed
        expect(mockTts.spokenHistory.last, contains('Only the Road Captain may alter the official route polyline'));
        expect(fakeConvoy.addedStops, isEmpty);
      });

      test('Pack Member proposing stop suggestion (forceWaypoint: false) is permitted', () async {
        fakeConvoy.canEditRoute = false;
        fakeConvoy.activeConvoy = buildConvoy(myRole: 'PACK', isGpsStale: false);

        await controller.startListening();
        await controller.handleSpeechComplete('Suggest stop at Hilltop Viewpoint');

        expect(controller.state, equals(VoiceSessionState.confirming));
        expect(controller.pendingIntent?.slots['forceWaypoint'], isFalse);

        await controller.handleSpeechComplete('Confirm');

        expect(mockTts.spokenHistory.last.toLowerCase(), contains('stop suggested to road captain at hilltop viewpoint'));
      });
    });

    // ------------------------------------------------------------------------
    // 5. STALE GPS TELEMETRY GUARD
    // ------------------------------------------------------------------------
    group('5. Stale GPS Telemetry Guard (>60s age)', () {
      test('Stop proposal with GPS fix older than 60s issues re-validation warning without crashing', () async {
        fakeConvoy.canEditRoute = true;
        fakeConvoy.activeConvoy = buildConvoy(myRole: 'LEAD', isGpsStale: true);

        await controller.startListening();
        await controller.handleSpeechComplete('Propose stop at Pine Forest');

        expect(controller.state, equals(VoiceSessionState.confirming));
        expect(controller.pendingIntent?.slots['staleGpsWarning'], isTrue);

        await controller.handleSpeechComplete('Confirm');

        // Blocked by stale GPS re-validation guard
        expect(mockTts.spokenHistory.last, contains('Warning: GPS position is older than sixty seconds'));
        expect(fakeConvoy.addedStops.where((s) => s['name'] == 'pine forest'), isEmpty);
      });
    });

    // ------------------------------------------------------------------------
    // 6. SAFETY PRE-EMPTION DURING DIALOGUE
    // ------------------------------------------------------------------------
    group('6. Safety Pre-emption During Dialogue', () {
      test('Emergency crash or SOS pre-emption immediately halts confirmation dialogue', () async {
        await controller.startListening();
        await controller.handleSpeechComplete('Broadcast alert rocks falling on left side');

        expect(controller.state, equals(VoiceSessionState.confirming));
        expect(controller.pendingIntent, isNotNull);

        // Crash detector fires emergency pre-emption
        controller.onEmergencyPreempt();

        expect(controller.state, equals(VoiceSessionState.idle));
        expect(controller.pendingIntent, isNull);
        expect(controller.statusFeedback, contains('Preempted by Safety SOS'));
        expect(fakeConvoy.sentMessages, isEmpty);
      });
    });

    // ------------------------------------------------------------------------
    // 7. PHASE SCOPE GATING
    // ------------------------------------------------------------------------
    group('7. Phase Scope Gating Enforcement', () {
      test('When allowStopsAndAlerts is disabled, Phase 3 commands are deferred', () async {
        final scopedController = VoiceAssistantController(
          speechAdapter: mockSpeech,
          actionExecutor: actionExecutor,
          ttsAdapter: mockTts,
          convoyService: fakeConvoy,
          enforcePhase1Scope: true,
          allowStopsAndAlerts: false,
        );

        await scopedController.startListening();
        await scopedController.handleSpeechComplete('Broadcast alert fallen branch');

        expect(scopedController.state, equals(VoiceSessionState.idle));
        expect(mockTts.spokenHistory.last, contains('enabled in the next release phase'));

        scopedController.dispose();
      });
    });
  });
}
