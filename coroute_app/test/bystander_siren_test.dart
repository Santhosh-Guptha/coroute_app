import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/emergency_roster.dart';
import 'package:coroute_app/data/models/network_wire.dart';
import 'package:coroute_app/data/models/pending_sos.dart';
import 'package:coroute_app/data/models/safety_wire.dart';
import 'package:coroute_app/data/services/accel_source.dart';
import 'package:coroute_app/data/services/safety_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/sms_sender.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/safety/crash_detector.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

const int t0 = 1700000000000;

class FakeSirenPort extends ChangeNotifier implements SafetyPort, SafetySourcePort, SafetyCheckInPort {
  FakeSirenPort(this.clock);
  final int Function() clock;

  final StreamController<TrackPoint> fixes = StreamController<TrackPoint>.broadcast();
  ConvoyModel? convoy;
  final List<Map<String, Object?>> raised = [];

  @override
  Stream<TrackPoint> get myFixes => fixes.stream;
  @override
  ConvoyModel? get activeConvoy => convoy;
  @override
  String? get myUserId => 'me';
  @override
  String get myName => 'Rider';
  @override
  String? get myPhone => '+91 90000 99999';
  @override
  bool get rideActive => true;
  @override
  bool get hasOpenSos => false;
  @override
  PendingSos? get pendingSos => null;
  @override
  EmergencyRoster? get emergencyRoster => null;
  @override
  RosterContact? get myEmergencyContact => null;

  @override
  SosDelivery raiseSos({
    required String type,
    required double lat,
    required double lng,
    bool auto = false,
    double? speedBeforeKmh,
    double? impactG,
    int? occurredAtMs,
  }) {
    raised.add({
      'type': type,
      'source': EmergencySource.needHelp,
      'auto': auto,
      'lat': lat,
      'lng': lng,
      'impactG': impactG,
    });
    return SosDelivery.queued;
  }

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
  }) {
    raised.add({
      'type': type,
      'source': source,
      'auto': auto,
      'lat': lat,
      'lng': lng,
      'impactG': impactG,
    });
    return SosDelivery.queued;
  }

  @override
  bool sendCheckIn(CheckInResult result, {double? awayM}) => true;

  @override
  bool sendCheckInWith(CheckInResult result, {double? awayM, CheckInContext? context}) => true;
}

class FakeSirenAccel extends AccelSource {
  final StreamController<AccelBucket> ctrl = StreamController<AccelBucket>.broadcast();
  @override
  Stream<AccelBucket> buckets({
    int samplingUs = SafetyConstants.accelSamplingUs,
    int maxLatencyUs = SafetyConstants.accelMaxLatencyUs,
  }) => ctrl.stream;
}

class FakeSirenSms implements SmsSender {
  @override
  Future<SmsCapability> capability() async => const SmsCapability(hasTelephony: true, permission: true, simReady: true);
  @override
  Future<SmsStatus> send(String phone, String text) async => SmsStatus.sent;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('Dual-State Bystander Siren Audio Beacon Tests', () {
    test('CrashAlarmState holds responsiveness and siren active state', () {
      final state = CrashAlarmState(
        startedAtMs: 1000,
        secondsLeft: 30,
        impactG: 4.5,
        speedBeforeKmh: 65.0,
      );

      expect(state.isUnresponsive, isFalse);
      expect(state.isSirenActive, isFalse);

      final sirenState = state.copyWith(
        sent: true,
        isUnresponsive: true,
        isSirenActive: true,
      );

      expect(sirenState.sent, isTrue);
      expect(sirenState.isUnresponsive, isTrue);
      expect(sirenState.isSirenActive, isTrue);

      final silencedState = sirenState.copyWith(isSirenActive: false);
      expect(silencedState.isUnresponsive, isTrue);
      expect(silencedState.isSirenActive, isFalse);
    });

    test('Manual Need Help sets sent=true but does NOT trigger bystander siren', () async {
      int now = t0;
      final port = FakeSirenPort(() => now);
      final settings = SettingsService();
      await settings.load();
      final safety = SafetyService.forTest(
        port,
        settings,
        accel: FakeSirenAccel(),
        sms: FakeSirenSms(),
        clock: () => now,
      );

      safety.debugRaiseCrash(const CrashEvent(
        impactAtMs: t0,
        impactG: 4.2,
        speedBeforeKmh: 55.0,
        lat: 12.9,
        lng: 77.5,
      ));

      expect(safety.alarm, isNotNull);
      expect(safety.alarm!.secondsLeft, equals(SafetyConstants.crashCountdown.inSeconds));

      // Rider actively taps "Need Help" -> Conscious interaction
      safety.alarmSendNow();

      expect(safety.alarm!.sent, isTrue);
      expect(safety.alarm!.isUnresponsive, isFalse);
      expect(safety.alarm!.isSirenActive, isFalse);
      expect(port.raised.first['source'], equals(EmergencySource.needHelp));

      safety.dispose();
    });

    test('silenceSiren mutes siren and clears isSirenActive', () async {
      int now = t0;
      final port = FakeSirenPort(() => now);
      final settings = SettingsService();
      await settings.load();
      final safety = SafetyService.forTest(
        port,
        settings,
        accel: FakeSirenAccel(),
        sms: FakeSirenSms(),
        clock: () => now,
      );

      safety.debugRaiseCrash(const CrashEvent(
        impactAtMs: t0,
        impactG: 6.0,
        speedBeforeKmh: 80.0,
        lat: 13.0,
        lng: 77.6,
      ));

      safety.alarmSendNow();
      safety.silenceSiren();
      expect(safety.alarm?.isSirenActive, isFalse);

      safety.dispose();
    });
  });
}
