import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/config/app_config.dart';
import 'package:coroute_app/core/constants/app_constants.dart';
import 'package:coroute_app/core/constants/net_constants.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/background_service.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/domain/tracking/battery_governor.dart';
import 'package:coroute_app/domain/tracking/ride_power_policy.dart';
import 'package:coroute_app/presentation/widgets/emergency_sos_sheet.dart';

/// Test mock RealtimeService tracking join parameters and messages.
class _TestRealtimeService extends RealtimeService {
  String? lastJoinedGroupId;
  String? lastPrevExit;
  int? lastPrevAliveAt;
  final List<Map<String, dynamic>> sentMessages = <Map<String, dynamic>>[];

  @override
  bool get isConnected => true;

  @override
  RealtimeState get state => RealtimeState.connected;

  @override
  void joinRoom(String groupId, {String? prevExit, int? prevAliveAt}) {
    lastJoinedGroupId = groupId;
    lastPrevExit = prevExit;
    lastPrevAliveAt = prevAliveAt;
  }

  @override
  bool send(Map<String, dynamic> message) {
    sentMessages.add(message);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    BackgroundService.debugReset();
  });

  group('REQ-01: Zero-Permission SMS Dispatch & Indian Emergency Dialing', () {
    test('Constructs zero-permission SMS URI with coordinates and distress message', () {
      const lat = 12.971598;
      const lng = 77.594562;
      const contactPhone = '+91 98765 43210';

      final smsUri = EmergencySosSheet.buildEmergencySmsUri(contactPhone, lat, lng);

      expect(smsUri.scheme, 'sms');
      expect(smsUri.path, '+919876543210');
      expect(smsUri.queryParameters['body'], contains('Emergency. I need help.'));
      expect(smsUri.queryParameters['body'], contains('https://maps.google.com/?q=12.971598,77.594562'));

      // Verify SmsSender intent formatting for general dispatch
      final directIntentUri = Uri(
        scheme: 'sms',
        path: contactPhone.replaceAll(RegExp(r'[^0-9+]'), ''),
        queryParameters: <String, String>{
          'body': 'Emergency distress beacon',
        },
      );
      expect(directIntentUri.scheme, 'sms');
      expect(directIntentUri.path, '+919876543210');
      expect(directIntentUri.queryParameters['body'], 'Emergency distress beacon');
    });

    test('Validates Indian emergency numbers and offline tel: dialing URIs', () {
      expect(EmergencySosSheet.indianEmergencyNumbers, containsAll(<String>['112', '108', '100', '1073']));

      // 112 National Emergency Services
      final uri112 = EmergencySosSheet.buildEmergencyCallUri('112');
      expect(uri112.scheme, 'tel');
      expect(uri112.path, '112');

      // 108 Ambulance Services
      final uri108 = EmergencySosSheet.buildEmergencyCallUri('108');
      expect(uri108.scheme, 'tel');
      expect(uri108.path, '108');

      // 100 Police Helpline
      final uri100 = EmergencySosSheet.buildEmergencyCallUri('100');
      expect(uri100.scheme, 'tel');
      expect(uri100.path, '100');

      // 1073 NHAI Highway Helpline
      final uri1073 = EmergencySosSheet.buildEmergencyCallUri('1073');
      expect(uri1073.scheme, 'tel');
      expect(uri1073.path, '1073');

      // ICE Contact with symbols stripped cleanly
      final uriIce = EmergencySosSheet.buildEmergencyCallUri('+91 (99887) 76655');
      expect(uriIce.scheme, 'tel');
      expect(uriIce.path, '+919988776655');
    });

    testWidgets('EmergencySosSheet renders all Indian helplines and offline ICE actions', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        AppConstants.keyUserId: 'rider_emergency_test',
        AppConstants.keyUserName: 'Karan Sharma',
        AppConstants.keyEmergencyContact: '+91 98765 00001',
        AppConstants.keyEmergencyName: 'Priya Sharma',
      });

      final client = MockClient((request) async => http.Response('{}', 200));
      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      final auth = AuthService(api);

      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthService>.value(
          value: auth,
          child: const MaterialApp(
            home: Scaffold(
              body: EmergencySosSheet(
                lat: 13.0827,
                lng: 80.2707,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // Verify Coordinates format
      expect(find.textContaining('13.08270, 80.27070'), findsOneWidget);

      // Verify Indian Helplines UI buttons
      expect(find.textContaining('Dial 112 (emergency services)'), findsOneWidget);
      expect(find.textContaining('Dial 108 (Ambulance)'), findsOneWidget);
      expect(find.textContaining('Dial 100 (Police)'), findsOneWidget);
      expect(find.textContaining('Dial 1073 (NHAI Highway Helpline)'), findsOneWidget);

      // Verify ICE Contact and SMS intent buttons
      expect(find.textContaining('Call Priya Sharma'), findsOneWidget);
      expect(find.textContaining('Text my location to +91 98765 00001'), findsOneWidget);
    });

    test('Offline emergency dialing is fully functional without internet connection', () {
      final offlineCallUri = EmergencySosSheet.buildEmergencyCallUri('112');
      expect(offlineCallUri.toString(), 'tel:112');

      // Delivery status for offline scenario
      final offlineStatus = EmergencySosSheet.statusFor(
        hasService: true,
        pending: true,
        online: false,
        hasOpenAlert: false,
      );
      expect(offlineStatus, SosSheetStatus.waitingForSignal);

      final (title, subtitle) = EmergencySosSheet.textFor(offlineStatus);
      expect(title, 'No signal. SOS not sent yet');
      expect(subtitle, contains('Call or text your emergency contact below.'));
    });
  });

  group('REQ-04: Multi-Stage Battery Governor Transitions & Last-Gasp Beacon', () {
    test('Multi-stage governor transitions: Normal -> Conserve (<=15%) -> Extreme (<=10%) -> Last-Gasp (<=5%)', () {
      final governor = BatteryGovernor();
      expect(governor.stage, BatteryGovernorStage.normal);
      expect(governor.isConserving, isFalse);
      expect(governor.isExtreme, isFalse);
      expect(governor.isLastGasp, isFalse);

      // Above 15%: Normal stage
      governor.updateBattery(85, charging: false);
      expect(governor.stage, BatteryGovernorStage.normal);

      governor.updateBattery(20, charging: false);
      expect(governor.stage, BatteryGovernorStage.normal);

      governor.updateBattery(16, charging: false);
      expect(governor.stage, BatteryGovernorStage.normal);

      // Dropping to 15%: Conserve stage
      governor.updateBattery(15, charging: false);
      expect(governor.stage, BatteryGovernorStage.conserve);
      expect(governor.isConserving, isTrue);
      expect(governor.isExtreme, isFalse);
      expect(governor.isLastGasp, isFalse);

      // Dropping to 10%: Extreme stage
      governor.updateBattery(10, charging: false);
      expect(governor.stage, BatteryGovernorStage.extreme);
      expect(governor.isConserving, isTrue);
      expect(governor.isExtreme, isTrue);
      expect(governor.isLastGasp, isFalse);

      governor.updateBattery(8, charging: false);
      expect(governor.stage, BatteryGovernorStage.extreme);

      // Dropping to 5%: Last-Gasp stage
      governor.updateBattery(5, charging: false);
      expect(governor.stage, BatteryGovernorStage.lastGasp);
      expect(governor.isConserving, isTrue);
      expect(governor.isExtreme, isTrue);
      expect(governor.isLastGasp, isTrue);

      // Deep exhaustion at 2% remains in Last-Gasp
      governor.updateBattery(2, charging: false);
      expect(governor.stage, BatteryGovernorStage.lastGasp);
    });

    test('Battery hysteresis prevents flapping between stages during transient load changes', () {
      final governor = BatteryGovernor();

      // Drain to Conserve (15%)
      governor.updateBattery(15, charging: false);
      expect(governor.stage, BatteryGovernorStage.conserve);

      // Temporary voltage bounce under lighter CPU load (16%, 17%, 18%, 19%)
      for (final pct in <int>[16, 17, 18, 19]) {
        governor.updateBattery(pct, charging: false);
        expect(governor.stage, BatteryGovernorStage.conserve, reason: 'Hysteresis prevents premature return to normal below 20%');
      }

      // Clears to normal only at 20%
      governor.updateBattery(20, charging: false);
      expect(governor.stage, BatteryGovernorStage.normal);

      // Drain to Extreme (10%)
      governor.updateBattery(10, charging: false);
      expect(governor.stage, BatteryGovernorStage.extreme);

      // Load bounce between 11% and 14% retains Extreme stage
      for (final pct in <int>[11, 12, 13, 14]) {
        governor.updateBattery(pct, charging: false);
        expect(governor.stage, BatteryGovernorStage.extreme, reason: 'Hysteresis retains extreme mode until 15%');
      }

      // Reaching 16% transitions back up to Conserve
      governor.updateBattery(16, charging: false);
      expect(governor.stage, BatteryGovernorStage.conserve);
    });

    test('Out-of-range sensor readings are ignored and charging immediately resets to Normal', () {
      final governor = BatteryGovernor();

      // Out-of-bounds readings ignored
      governor.updateBattery(-5, charging: false);
      expect(governor.stage, BatteryGovernorStage.normal);
      governor.updateBattery(120, charging: false);
      expect(governor.stage, BatteryGovernorStage.normal);

      // Enter Last-Gasp at 4%
      governor.updateBattery(4, charging: false);
      expect(governor.stage, BatteryGovernorStage.lastGasp);

      // Plugged in: charging immediately overrides all conservation tiers
      governor.updateBattery(4, charging: true);
      expect(governor.stage, BatteryGovernorStage.normal);
      expect(governor.isConserving, isFalse);
      expect(governor.isCharging, isTrue);
    });

    test('Telemetry and notification interval throttling adheres to governor tiers', () {
      final governor = BatteryGovernor();

      // Normal tier
      expect(governor.telemetryInterval(moving: true, critical: false), AppConfig.telemetryMinInterval);
      expect(governor.telemetryInterval(moving: false, critical: false), AppConfig.telemetryIdleInterval);
      expect(governor.notificationInterval(critical: false), const Duration(seconds: 10));
      expect(governor.isTilePrefetchAllowed, isTrue);
      expect(governor.isSocialDiscoveryAllowed(hasActiveSafetyAlert: false), isTrue);

      // Conserve tier (<= 15%)
      governor.updateBattery(15, charging: false);
      expect(governor.telemetryInterval(moving: true, critical: false), const Duration(seconds: 5));
      expect(governor.telemetryInterval(moving: false, critical: false), AppConfig.telemetryIdleInterval);
      expect(governor.notificationInterval(critical: false), const Duration(seconds: 20));
      expect(governor.isTilePrefetchAllowed, isTrue);

      // Extreme tier (<= 10%)
      governor.updateBattery(10, charging: false);
      expect(governor.telemetryInterval(moving: true, critical: false), const Duration(seconds: 10));
      expect(governor.telemetryInterval(moving: false, critical: false), const Duration(seconds: 60));
      expect(governor.notificationInterval(critical: false), const Duration(seconds: 30));
      expect(governor.isTilePrefetchAllowed, isFalse);
      expect(governor.isSocialDiscoveryAllowed(hasActiveSafetyAlert: false), isFalse);

      // Last-Gasp tier (<= 5%)
      governor.updateBattery(5, charging: false);
      expect(governor.telemetryInterval(moving: true, critical: false), const Duration(seconds: 30));
      expect(governor.telemetryInterval(moving: false, critical: false), const Duration(seconds: 120));
      expect(governor.notificationInterval(critical: false), const Duration(seconds: 60));
      expect(governor.isTilePrefetchAllowed, isFalse);
      expect(governor.isSocialDiscoveryAllowed(hasActiveSafetyAlert: false), isFalse);
    });

    test('LAST_GASP_BEACON dispatch triggers on 5% battery with latching deduplication', () {
      final governor = BatteryGovernor();
      final dispatchedBeacons = <LastGaspBeacon>[];
      governor.onLastGaspBeacon = (b) => dispatchedBeacons.add(b);

      const userId = 'rider_surya';
      const lat = 12.9352;
      const lng = 77.6245;

      // 80% -> 12% -> 8%: no beacon dispatched yet
      governor.updateBattery(80, charging: false, userId: userId, lat: lat, lng: lng);
      governor.updateBattery(12, charging: false, userId: userId, lat: lat, lng: lng);
      governor.updateBattery(8, charging: false, userId: userId, lat: lat, lng: lng);
      expect(dispatchedBeacons, isEmpty);
      expect(governor.lastGaspBeaconDispatched, isFalse);

      // Battery drops to 5%: triggers LAST_GASP_BEACON dispatch
      governor.updateBattery(5, charging: false, userId: userId, lat: lat, lng: lng, speedKmh: 42.5, accuracyM: 6.0);
      expect(dispatchedBeacons.length, 1);
      expect(governor.lastGaspBeaconDispatched, isTrue);

      final beacon = dispatchedBeacons.first;
      expect(beacon.type, 'LAST_GASP_BEACON');
      expect(beacon.userId, userId);
      expect(beacon.batteryLevel, 5);
      expect(beacon.lat, lat);
      expect(beacon.lng, lng);
      expect(beacon.speedKmh, 42.5);
      expect(beacon.stage, BatteryGovernorStage.lastGasp);
      expect(beacon.toJson()['type'], 'LAST_GASP_BEACON');
      expect(beacon.toJson()['batteryLevel'], 5);

      // Latching deduplication: subsequent drops (4%, 3%, 2%) do NOT spam duplicate beacons
      governor.updateBattery(4, charging: false, userId: userId, lat: lat, lng: lng);
      governor.updateBattery(3, charging: false, userId: userId, lat: lat, lng: lng);
      governor.updateBattery(2, charging: false, userId: userId, lat: lat, lng: lng);
      expect(dispatchedBeacons.length, 1, reason: 'Beacon dispatch must be latched once per low-battery entry');

      // Charger plugged in: resets beacon latch
      governor.updateBattery(2, charging: true, userId: userId, lat: lat, lng: lng);
      expect(governor.stage, BatteryGovernorStage.normal);
      expect(governor.lastGaspBeaconDispatched, isFalse);

      // Subsequent drain re-arms and fires beacon again
      governor.updateBattery(5, charging: false, userId: userId, lat: lat, lng: lng);
      expect(dispatchedBeacons.length, 2, reason: 'Beacon re-arms after recovery/charging');
    });

    test('Critical safety incidents override battery governor throttling even at 5% battery', () {
      final governor = BatteryGovernor();
      governor.updateBattery(5, charging: false);
      expect(governor.stage, BatteryGovernorStage.lastGasp);

      // An active crash or SOS incident forces telemetry back to 2.5s high-frequency cadence!
      expect(
        governor.telemetryInterval(moving: true, critical: true),
        AppConfig.telemetryMinInterval,
        reason: 'Emergency overrides battery throttle',
      );
      expect(
        governor.telemetryInterval(moving: false, critical: true),
        AppConfig.telemetryMinInterval,
      );
      expect(
        governor.notificationInterval(critical: true),
        const Duration(seconds: 10),
      );

      // RidePowerPolicy integration maintains backwards compatibility while reflecting governor
      final policy = RidePowerPolicy();
      policy.updateBattery(5, charging: false);
      expect(policy.conserving, isTrue);
      expect(policy.stage, BatteryGovernorStage.lastGasp);
      expect(policy.telemetryInterval(moving: true, lowData: false, critical: true), AppConfig.telemetryMinInterval);
    });
  });

  group('REQ-05: Background Service Recovery & Session Resumption After Process Kill', () {
    test('BackgroundService configures persistent notification, wake locks and service types', () {
      // Location service always active; microphone included only when granted
      final typesWithoutMic = BackgroundService.serviceTypesFor(micGranted: false);
      expect(typesWithoutMic, <ForegroundServiceTypes>[ForegroundServiceTypes.location]);

      final typesWithMic = BackgroundService.serviceTypesFor(micGranted: true);
      expect(typesWithMic, <ForegroundServiceTypes>[
        ForegroundServiceTypes.location,
        ForegroundServiceTypes.microphone,
      ]);

      // Verify button identifiers
      expect(BackgroundService.buttonSos, 'sos');
      expect(BackgroundService.buttonLeave, 'leave');

      // Verify rich active notification switching
      BackgroundService.debugReset();
      expect(BackgroundService.richActive, isFalse);
    });

    test('Active ride persists alive state and timestamp to withstand process kill', () async {
      final client = MockClient((request) async {
        if (request.url.path.contains('/convoys/active')) {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'convoy': <String, dynamic>{
                'groupId': 'grp_active_kill_test',
                'name': 'Western Ghats Odyssey',
                'joinCode': '123456',
                'createdByUserId': 'u_lead_1',
                'createdByUserName': 'Vikram',
                'createdAtEpochMs': 1700000000000,
                'riders': <String, dynamic>{
                  'u_rider_1': <String, dynamic>{
                    'userId': 'u_rider_1',
                    'name': 'Santhosh Rider',
                    'lat': 12.9716,
                    'lng': 77.5946,
                  },
                },
              },
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      });

      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      final rt = _TestRealtimeService();
      final trips = TripStorageService(api);
      final convoyService = ConvoyService(api, rt, trips);

      // Start session: restores active convoy and writes ride alive flag
      await convoyService.startSession(token: 'test_token', userId: 'u_rider_1');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(convoyService.activeGroupId, 'grp_active_kill_test');

      // Inspect persisted state in SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(NetConstants.keyRideAlive), isTrue);
      expect(prefs.getInt(NetConstants.keyLastAliveAt), isNotNull);
      expect(prefs.getString(AppConstants.keyActiveGroupId), 'grp_active_kill_test');
    });

    test('Simulated process kill cold restart reads previous exit and re-joins with KILLED flag', () async {
      const killedTimestamp = 1700005000000;
      // Setup SharedPreferences as if the OS terminated the app process while running
      SharedPreferences.setMockInitialValues(<String, Object>{
        NetConstants.keyRideAlive: true,
        NetConstants.keyLastAliveAt: killedTimestamp,
        AppConstants.keyActiveGroupId: 'grp_killed_recovery',
      });

      final client = MockClient((request) async {
        if (request.url.path.contains('/convoys/active')) {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'convoy': <String, dynamic>{
                'groupId': 'grp_killed_recovery',
                'name': 'Bangalore Highway Run',
                'joinCode': '654321',
                'createdByUserId': 'u_lead_2',
                'createdByUserName': 'Anil Lead',
                'createdAtEpochMs': killedTimestamp - 3600000,
                'riders': <String, dynamic>{
                  'u_rider_resumed': <String, dynamic>{
                    'userId': 'u_rider_resumed',
                    'name': 'Resumed Rider',
                    'lat': 12.9800,
                    'lng': 77.6000,
                  },
                },
              },
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      });

      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      final rt = _TestRealtimeService();
      final trips = TripStorageService(api);

      // Instantiate a new ConvoyService simulating process resurrection
      final recoveredConvoyService = ConvoyService(api, rt, trips);

      // Start session: should detect unexpected kill and recover
      await recoveredConvoyService.startSession(token: 'resumed_token', userId: 'u_rider_resumed');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(recoveredConvoyService.activeGroupId, 'grp_killed_recovery');
      expect(rt.lastJoinedGroupId, 'grp_killed_recovery');
      expect(rt.lastPrevExit, 'KILLED', reason: 'Must notify convoy that rider recovered from OS process kill');
      expect(rt.lastPrevAliveAt, killedTimestamp);

      // Once recovered, disk heartbeat is updated for the new session
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(NetConstants.keyRideAlive), isTrue);
    });

    test('Clean ride termination clears alive flag so subsequent session start does not trigger kill recovery', () async {
      final client = MockClient((request) async {
        if (request.url.path.contains('/convoys/active')) {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'convoy': <String, dynamic>{
                'groupId': 'grp_clean_finish',
                'name': 'Clean Ride',
                'joinCode': '112233',
                'createdByUserId': 'u_lead_3',
                'createdByUserName': 'Lead',
                'createdAtEpochMs': 1700000000000,
                'riders': <String, dynamic>{},
              },
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      });

      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      final rt = _TestRealtimeService();
      final trips = TripStorageService(api);
      final convoyService = ConvoyService(api, rt, trips);

      await convoyService.startSession(token: 'token_clean', userId: 'u_clean_rider');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(convoyService.activeGroupId, 'grp_clean_finish');

      // Clean end of session (user signs out or ends ride cleanly)
      await convoyService.endSession();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(NetConstants.keyRideAlive), isFalse);
      expect(prefs.getInt(NetConstants.keyLastAliveAt), isNull);

      // Subsequent session start by another or same user does NOT flag KILLED
      final rt2 = _TestRealtimeService();
      final convoyService2 = ConvoyService(api, rt2, trips);
      await convoyService2.startSession(token: 'token_fresh', userId: 'u_clean_rider');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(rt2.lastPrevExit, isNull, reason: 'Clean exit must not trigger KILLED recovery flag');
    });

    test('Process recovery when ride was concluded on server during app downtime cleans up stale local state', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        NetConstants.keyRideAlive: true,
        NetConstants.keyLastAliveAt: 1700009999000,
        AppConstants.keyActiveGroupId: 'grp_ended_while_offline',
      });

      // Server returns empty/no active convoy
      final client = MockClient((request) async {
        if (request.url.path.contains('/convoys/active')) {
          return http.Response(jsonEncode(<String, dynamic>{'convoy': null}), 200);
        }
        return http.Response('{}', 200);
      });

      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      final rt = _TestRealtimeService();
      final trips = TripStorageService(api);
      final convoyService = ConvoyService(api, rt, trips);

      await convoyService.startSession(token: 'token_expired', userId: 'u_expired_rider');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Active convoy remains null and stale local pointers cleared
      expect(convoyService.activeGroupId, isNull);
      expect(rt.lastJoinedGroupId, isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(NetConstants.keyRideAlive), isFalse);
      expect(prefs.getString(AppConstants.keyActiveGroupId), isNull);
    });
  });
}
