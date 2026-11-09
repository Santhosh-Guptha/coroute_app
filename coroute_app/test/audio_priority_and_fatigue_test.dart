import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/emergency_roster.dart';
import 'package:coroute_app/data/models/network_wire.dart';
import 'package:coroute_app/data/models/pending_sos.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/safety_wire.dart';
import 'package:coroute_app/data/services/accel_source.dart';
import 'package:coroute_app/data/services/audio_priority_manager.dart';
import 'package:coroute_app/data/services/phone_call_service.dart';
import 'package:coroute_app/data/services/safety_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/sms_sender.dart';
import 'package:coroute_app/data/services/voice_service.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

class TestVoiceEngine implements VoiceEngine, VoiceEngineLanguage {
  bool initResult = true;
  @override
  String language = 'en-IN';
  final List<(String, bool, String)> spokenList = [];
  int stops = 0;
  int releases = 0;

  @override
  Future<bool> init() => Future.value(initResult);

  @override
  Future<bool> speak(
    String text, {
    required bool interrupt,
    required String id,
    bool isEmergency = false,
    bool pauseOthers = false,
  }) {
    spokenList.add((text, interrupt, id));
    return Future.value(true);
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> release() async {
    releases++;
  }
}

class TestSafetyPort extends ChangeNotifier
    implements SafetyPort, SafetySourcePort, SafetyCheckInPort, SafetyStatusReasonPort {
  final StreamController<TrackPoint> _fixes = StreamController<TrackPoint>.broadcast();
  @override
  Stream<TrackPoint> get myFixes => _fixes.stream;

  void emitFix(TrackPoint p) => _fixes.add(p);

  @override
  bool rideActive = true;
  @override
  bool hasOpenSos = false;
  @override
  PendingSos? pendingSos;
  @override
  EmergencyRoster? emergencyRoster;
  @override
  RosterContact? myEmergencyContact;
  @override
  String? myBloodGroup;
  @override
  String? myUserId = 'rider_1';
  @override
  String myName = 'Test Rider';
  @override
  String? myPhone = '+919876543210';
  @override
  ConvoyModel? activeConvoy;

  final List<(CheckInResult, CheckInContext?, double?)> sentCheckIns = [];
  final List<(String, String, String)> statusReasonUpdates = [];

  @override
  SosDelivery raiseSos({
    required String type,
    required double lat,
    required double lng,
    bool auto = false,
    double? speedBeforeKmh,
    double? impactG,
    int? occurredAtMs,
  }) =>
      SosDelivery.sent;

  @override
  SosDelivery raiseSosFrom(
    EmergencySource source, {
    required String type,
    required double lat,
    required double lng,
    bool auto = false,
    double? speedBeforeKmh,
    double? impactG,
    int? occurredAtMs,
    Map<String, dynamic>? biometrics,
    String? traumaLevel,
  }) =>
      SosDelivery.sent;

  @override
  bool sendCheckIn(CheckInResult result, {double? awayM}) {
    sentCheckIns.add((result, null, awayM));
    return true;
  }

  @override
  bool sendCheckInWith(CheckInResult result, {double? awayM, CheckInContext? context}) {
    sentCheckIns.add((result, context, awayM));
    return true;
  }

  @override
  void updateStatusReason({required String userId, required String reason, String message = ''}) {
    statusReasonUpdates.add((userId, reason, message));
  }
}

class TestAccelSource implements AccelSource {
  final StreamController<AccelBucket> _ctrl = StreamController<AccelBucket>.broadcast();
  @override
  Stream<AccelBucket> buckets({
    int samplingUs = SafetyConstants.accelSamplingUs,
    int maxLatencyUs = SafetyConstants.accelMaxLatencyUs,
  }) =>
      _ctrl.stream;
}

class TestSmsSender implements SmsSender {
  @override
  Future<SmsCapability> capability() async =>
      const SmsCapability(hasTelephony: true, permission: true, simReady: true);

  @override
  Future<SmsStatus> send(String to, String body) async => SmsStatus.sent;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioPriorityManager Architecture & Priority Tests', () {
    late SettingsService settings;
    late TestVoiceEngine engine;
    late AudioPriorityManager priorityManager;
    late int simTime;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = SettingsService();
      await settings.load();
      engine = TestVoiceEngine();
      simTime = 1700000000000;
      priorityManager = AudioPriorityManager(
        engine: engine,
        clock: () => simTime,
      );
    });

    tearDown(() {
      priorityManager.dispose();
    });

    test('P0 critical emergency preempts active speech immediately with interrupt flag', () async {
      // 1. Submit normal P3 navigation guidance
      final navOk = await priorityManager.submit(
        text: 'In 300 meters turn left onto Ring Road',
        priority: AudioPriority.p3Navigation,
        dedupeKey: 'nav_turn_1',
      );
      expect(navOk, isTrue);
      expect(engine.spokenList.last.$1, contains('Ring Road'));
      expect(engine.spokenList.last.$2, isFalse, reason: 'P3 does not interrupt');

      // 2. Submit P0 critical emergency alert
      final sosOk = await priorityManager.submit(
        text: 'Emergency: Crash detected ahead. Slow down.',
        priority: AudioPriority.p0CriticalEmergency,
        dedupeKey: 'sos_alert_1',
      );
      expect(sosOk, isTrue);
      expect(engine.spokenList.last.$1, contains('Crash detected ahead'));
      expect(engine.spokenList.last.$2, isTrue, reason: 'P0 critical interrupts immediately');
    });

    test('Deduplication prevents repeating identical alert within dedupe window', () async {
      final a = await priorityManager.submit(
        text: 'Sharp curve ahead',
        priority: AudioPriority.p2ImmediateHazard,
        dedupeKey: 'hazard_curve_9',
        dedupeWindow: const Duration(seconds: 10),
      );
      expect(a, isTrue);

      // Immediate duplicate within window is dropped
      final b = await priorityManager.submit(
        text: 'Sharp curve ahead',
        priority: AudioPriority.p2ImmediateHazard,
        dedupeKey: 'hazard_curve_9',
        dedupeWindow: const Duration(seconds: 10),
      );
      expect(b, isFalse);

      // Advance time past window
      simTime += 11000;

      final c = await priorityManager.submit(
        text: 'Sharp curve ahead',
        priority: AudioPriority.p2ImmediateHazard,
        dedupeKey: 'hazard_curve_9',
        dedupeWindow: const Duration(seconds: 10),
      );
      expect(c, isTrue);
      expect(engine.spokenList, hasLength(2));
    });

    // The "background voice guidance" switch was removed: spoken alerts are chosen once
    // in Settings (VoiceService applies it) and emergencies always speak.
    test('Visual fallback stream receives alerts', () async {

      final visualAlerts = <AudioAlertItem>[];
      final sub = priorityManager.onVisualAlert.listen(visualAlerts.add);

      await priorityManager.submit(
        text: 'Critical accident 500m ahead',
        priority: AudioPriority.p0CriticalEmergency,
      );

      await Future<void>.delayed(Duration.zero);
      expect(visualAlerts, hasLength(1));
      expect(visualAlerts.first.priority, AudioPriority.p0CriticalEmergency);
      expect(visualAlerts.first.text, contains('Critical accident'));

      await sub.cancel();
    });
  });

  group('Call-Aware Background Voice & Priority Transitions', () {
    late SettingsService settings;
    late TestVoiceEngine engine;
    late VoiceService voice;
    late PhoneCallService phoneCall;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = SettingsService();
      await settings.load();
      engine = TestVoiceEngine();
      phoneCall = PhoneCallService(autoStart: false);
      voice = VoiceService(settings, engine: engine);
      voice.attachPhoneCallService(phoneCall);
    });

    tearDown(() {
      voice.dispose();
      phoneCall.dispose();
    });

    test('3.55 call-aware: no ordinary speech over a call, summary after it', () async {
      phoneCall.simulateCallState(PhoneCallStatus.offhook);
      expect(phoneCall.isCallActive, isTrue);

      final navSpoken = await voice.speakNavigation('Take the second exit at roundabout');
      expect(navSpoken, isFalse, reason: 'directions are stale after a call: dropped');

      final hazardSpoken = await voice.speakHazard('Caution: Animal on road 200 meters ahead');
      expect(hazardSpoken, isTrue, reason: 'held for the after-call summary');
      expect(engine.spokenList.any((t) => t.$1.contains('Animal on road')), isFalse);

      phoneCall.simulateCallState(PhoneCallStatus.idle);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(engine.spokenList.any((t) => t.$1.startsWith('While you were on the call') && t.$1.contains('Animal on road')), isTrue);
    });

    test('3.55 call-aware switch off: the old behaviour (lines spoken during the call)', () async {
      final legacy = AudioPriorityManager(engine: engine, phoneCallService: phoneCall, callAware: () => false);
      phoneCall.simulateCallState(PhoneCallStatus.offhook);
      final ok = await legacy.submit(text: 'Caution: pothole', priority: AudioPriority.p2ImmediateHazard);
      expect(ok, isTrue);
      expect(engine.spokenList.last.$1, contains('pothole'));
      legacy.dispose();
    });

    test('3.55 call-aware: a critical line during a call is a short phrase', () async {
      phoneCall.simulateCallState(PhoneCallStatus.offhook);
      await voice.speakEmergency('Crash detected. Countdown 15 seconds. Say OK to cancel.');
      expect(engine.spokenList.last.$1, 'Crash detected.');
    });

    test('Critical alert during call is spoken and queued into post-call replay', () async {
      phoneCall.simulateCallState(PhoneCallStatus.offhook);

      final sos = await voice.speakEmergency('SOS emergency from Sweeper');
      expect(sos, isTrue);
      expect(phoneCall.pendingPostCallAlerts, contains('SOS emergency from Sweeper'));
      expect(engine.spokenList.last.$1, contains('SOS emergency from Sweeper'));

      // Rider hangs up call -> flushed and replayed
      phoneCall.simulateCallState(PhoneCallStatus.idle);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(phoneCall.pendingPostCallAlerts, isEmpty);
      expect(engine.spokenList.any((t) => t.$1.contains('Safety alert during your call')), isTrue);
    });
  });

  group('Fatigue Continuous-Riding Safety Escalation Tests', () {
    late SettingsService settings;
    late TestSafetyPort port;
    late TestVoiceEngine engine;
    late VoiceService voice;
    late SafetyService safety;
    late int simTime;

    Future<void> initEnvironment() async {
      SharedPreferences.setMockInitialValues({});
      settings = SettingsService();
      await settings.load();
      simTime = 1700000000000;
      port = TestSafetyPort();
      port.activeConvoy = ConvoyModel(
        groupId: 'test_group',
        name: 'Sunday Ride',
        joinCode: '123456',
        createdByUserId: 'captain',
        createdByUserName: 'Captain',
        createdAtEpochMs: simTime,
        tripStatus: 'STARTED',
        riders: {
          'rider_1': RiderModel(
            userId: 'rider_1',
            name: 'Test Rider',
            lat: 17.4,
            lng: 78.4,
            lastSeenEpochMs: 1700000000000,
          ),
        },
      );
      engine = TestVoiceEngine();
      voice = VoiceService(settings, engine: engine, clock: () => simTime);
      safety = SafetyService.forTest(
        port,
        settings,
        accel: TestAccelSource(),
        sms: TestSmsSender(),
        voice: voice,
        clock: () => simTime,
      );
      addTearDown(() {
        safety.dispose();
        voice.dispose();
      });
    }

    testWidgets('Continuous riding for 2 hours triggers P1 break prompt and 60s/90s escalation lifecycle', (tester) async {
      await initEnvironment();

      // 1. Initial moving fix at t0
      port.emitFix(TrackPoint(lat: 17.4, lng: 78.4, speedKmh: 45.0, ts: simTime));
      await tester.pump();
      expect(safety.prompts.any((p) => p.key == SafetyConstants.promptFatigue), isFalse);

      // 2. Traffic stop for 5 minutes (shorter than 10 min break threshold) does NOT reset stretch
      simTime += 5 * 60 * 1000;
      port.emitFix(TrackPoint(lat: 17.401, lng: 78.401, speedKmh: 0.0, ts: simTime));
      await tester.pump();
      expect(safety.prompts.any((p) => p.key == SafetyConstants.promptFatigue), isFalse);

      // 3. Continue riding with fixes every 5 minutes (less than 10m break threshold) until 2 hours continuous stretch
      for (int i = 1; i <= 25; i++) {
        simTime += 5 * 60 * 1000;
        port.emitFix(TrackPoint(lat: 17.4 + (i * 0.005), lng: 78.4 + (i * 0.005), speedKmh: 55.0, ts: simTime));
        await tester.pump();
      }

      // Break prompt is opened and P1 voice alert spoken
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump(const Duration(milliseconds: 10));
      expect(safety.prompts.any((p) => p.key == SafetyConstants.promptFatigue), isTrue);
      expect(engine.spokenList.any((t) => t.$1.contains('Time for a break')), isTrue);

      // 4. Advance timer by 60 seconds (Level 1 escalation)
      await tester.pump(const Duration(seconds: 60));
      expect(engine.spokenList.any((t) => t.$1.contains('Safety confirmation required')), isTrue);
      expect(port.statusReasonUpdates, isEmpty, reason: 'Captain not alerted yet at 60s');

      // 5. Advance timer by another 30 seconds (total 90s, Level 2 escalation)
      await tester.pump(const Duration(seconds: 30));
      expect(engine.spokenList.any((t) => t.$1.contains('Rider unconfirmed')), isTrue);
      expect(port.sentCheckIns.any((c) => c.$1 == CheckInResult.noReply && c.$2 == CheckInContext.fatigue), isTrue);
      expect(port.statusReasonUpdates.any((u) => u.$2 == 'FATIGUE_UNRESPONSIVE'), isTrue);

      // 6. Rider taps "I'm Alert & Safe" (primary answer)
      safety.answerPrompt(SafetyConstants.promptFatigue, primary: true);
      await tester.pump();

      expect(safety.prompts.any((p) => p.key == SafetyConstants.promptFatigue), isFalse);
      expect(port.sentCheckIns.any((c) => c.$1 == CheckInResult.ok && c.$2 == CheckInContext.fatigue), isTrue);
      expect(port.statusReasonUpdates.last.$2, equals(''), reason: 'Cleared status reason');
      expect(engine.spokenList.any((t) => t.$1.contains('Safety confirmed')), isTrue);
    });

    testWidgets('Genuine 10+ minute rest period resets the continuous riding stretch', (tester) async {
      await initEnvironment();
      // 1. Moving fix
      port.emitFix(TrackPoint(lat: 17.4, lng: 78.4, speedKmh: 50.0, ts: simTime));
      await tester.pump();

      // 2. Ride for 1 hour 50 minutes
      simTime += 110 * 60 * 1000;
      port.emitFix(TrackPoint(lat: 17.48, lng: 78.48, speedKmh: 50.0, ts: simTime));
      await tester.pump();
      expect(safety.prompts.any((p) => p.key == SafetyConstants.promptFatigue), isFalse);

      // 3. Genuine 12-minute tea break
      simTime += 12 * 60 * 1000;
      port.emitFix(TrackPoint(lat: 17.48, lng: 78.48, speedKmh: 0.0, ts: simTime));
      await tester.pump();

      // 4. Ride for another 30 minutes (total time is 2h 32m, but stretch was reset by the 12m break!)
      simTime += 30 * 60 * 1000;
      port.emitFix(TrackPoint(lat: 17.52, lng: 78.52, speedKmh: 55.0, ts: simTime));
      await tester.pump();

      // Break prompt should NOT trigger because new stretch is only 30 minutes!
      expect(safety.prompts.any((p) => p.key == SafetyConstants.promptFatigue), isFalse);
    });
  });
}
