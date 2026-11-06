import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/ble_remote_service.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/permission_revocation_safety_service.dart';
import 'package:coroute_app/presentation/rider/widgets/cockpit_permission_warning_banner.dart';

class FakeConvoyService extends ChangeNotifier implements ConvoyService {
  @override
  ConvoyModel? activeConvoy;

  @override
  String? get activeGroupId => activeConvoy?.groupId;

  @override
  String? get myUserId => 'rider_test_1';

  bool stopRealGpsTrackingCalled = false;
  bool startRealGpsTrackingCalled = false;
  bool onLocationRevokedCalled = false;
  bool onLocationRestoredCalled = false;
  bool leaveConvoyCalled = false;

  @override
  bool isRealGpsActive = false;

  @override
  bool isLocationRevoked = false;

  @override
  void stopRealGpsTracking() {
    stopRealGpsTrackingCalled = true;
    isRealGpsActive = false;
    notifyListeners();
  }

  @override
  Future<bool> startRealGpsTracking(String userId) async {
    startRealGpsTrackingCalled = true;
    isRealGpsActive = true;
    notifyListeners();
    return true;
  }

  @override
  void onLocationRevoked() {
    onLocationRevokedCalled = true;
    isLocationRevoked = true;
    stopRealGpsTracking();
  }

  @override
  void onLocationRestored() {
    onLocationRestoredCalled = true;
    isLocationRevoked = false;
    startRealGpsTracking(myUserId!);
  }

  @override
  Future<void> leaveActiveConvoy([String? userId]) async {
    leaveConvoyCalled = true;
    activeConvoy = null;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeIntercomService extends ChangeNotifier implements IntercomService {
  bool onMicrophoneRevokedCalled = false;
  bool onMicrophoneRestoredCalled = false;
  @override
  bool isTransmitting = false;
  bool isMicOpen = false;

  @override
  bool isMicrophoneRevoked = false;

  @override
  Future<void> onMicrophoneRevoked() async {
    onMicrophoneRevokedCalled = true;
    isMicrophoneRevoked = true;
    isTransmitting = false;
    isMicOpen = false;
    notifyListeners();
  }

  @override
  void onMicrophoneRestored() {
    onMicrophoneRestoredCalled = true;
    isMicrophoneRevoked = false;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeBleRemoteService extends ChangeNotifier implements BleRemoteService {
  bool onBluetoothRevokedCalled = false;
  bool onBluetoothRestoredCalled = false;

  @override
  bool isBluetoothRevoked = false;

  @override
  final ValueNotifier<BleRemoteStatus> statusNotifier =
      ValueNotifier<BleRemoteStatus>(BleRemoteStatus.listening);

  @override
  BleRemoteStatus get status => statusNotifier.value;

  @override
  void onBluetoothRevoked() {
    onBluetoothRevokedCalled = true;
    isBluetoothRevoked = true;
    statusNotifier.value = BleRemoteStatus.disconnected;
    notifyListeners();
  }

  @override
  void onBluetoothRestored() {
    onBluetoothRestoredCalled = true;
    isBluetoothRevoked = false;
    statusNotifier.value = BleRemoteStatus.listening;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ConvoyModel createTestConvoy() {
  return ConvoyModel(
    groupId: 'test_group_404',
    name: 'Bangalore Weekend Convoy',
    joinCode: 'BLR99',
    createdByUserId: 'rider_test_1',
    createdByUserName: 'Santhosh (Lead)',
    createdAtEpochMs: DateTime.now().millisecondsSinceEpoch,
    tripStatus: 'ACTIVE',
    riders: {
      'rider_test_1': RiderModel(
        userId: 'rider_test_1',
        name: 'Santhosh (Lead)',
        lat: 12.9716,
        lng: 77.5946,
        heading: 90.0,
        speedKmh: 45.0,
        batteryLevel: 88,
        isCharging: false,
        lastSeenEpochMs: 1000,
        role: 'LEAD',
      ),
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeConvoyService fakeConvoy;
  late FakeIntercomService fakeIntercom;
  late FakeBleRemoteService fakeBle;
  late StreamController<ServiceStatus> serviceStatusCtrl;
  late Map<TripPermission, bool> permissionRegistry;
  late bool locationServiceState;
  late int settingsOpenCount;

  setUp(() {
    fakeConvoy = FakeConvoyService();
    fakeConvoy.activeConvoy = createTestConvoy();
    fakeConvoy.isRealGpsActive = true;

    fakeIntercom = FakeIntercomService();
    fakeBle = FakeBleRemoteService();
    serviceStatusCtrl = StreamController<ServiceStatus>.broadcast();
    settingsOpenCount = 0;
    locationServiceState = true;

    permissionRegistry = {
      TripPermission.location: true,
      TripPermission.locationAlways: true,
      TripPermission.microphone: true,
      TripPermission.notification: true,
      TripPermission.bluetooth: true,
      TripPermission.locationService: true,
    };
  });

  tearDown(() {
    serviceStatusCtrl.close();
  });

  PermissionRevocationSafetyService createService({
    Duration checkInterval = Duration.zero,
  }) {
    return PermissionRevocationSafetyService(
      convoyService: fakeConvoy,
      intercomService: fakeIntercom,
      bleRemoteService: fakeBle,
      permissionChecker: (perm) async => permissionRegistry[perm] ?? false,
      locationServiceChecker: () async => locationServiceState,
      serviceStatusStream: serviceStatusCtrl.stream,
      settingsOpener: () async {
        settingsOpenCount++;
        return true;
      },
      checkInterval: checkInterval,
    );
  }

  group('ISSUE-7: Permission Detection and Lifecycle Recheck (Req 1, 2, 8)', () {
    test('Detects all active trip permission states on initial recheck', () async {
      final service = createService();
      await service.recheckPermissions();

      expect(service.isGranted(TripPermission.location), isTrue);
      expect(service.isGranted(TripPermission.locationAlways), isTrue);
      expect(service.isGranted(TripPermission.microphone), isTrue);
      expect(service.isGranted(TripPermission.notification), isTrue);
      expect(service.isGranted(TripPermission.bluetooth), isTrue);
      expect(service.isGranted(TripPermission.locationService), isTrue);
      expect(service.hasActiveWarning, isFalse);
    });

    test('didChangeAppLifecycleState(resumed) triggers recheck and detects revoked permissions', () async {
      final service = createService();
      await service.recheckPermissions();
      expect(service.hasActiveWarning, isFalse);

      // User switches to Android Settings and revokes location
      permissionRegistry[TripPermission.location] = false;

      // App resumes
      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();

      expect(service.isGranted(TripPermission.location), isFalse);
      expect(service.hasActiveWarning, isTrue);
      expect(service.hasEssentialRevocation, isTrue);
      expect(fakeConvoy.onLocationRevokedCalled, isTrue);
      expect(fakeConvoy.stopRealGpsTrackingCalled, isTrue);
    });

    test('Selective resumption: Resumes only restored features (Req 8)', () async {
      final service = createService();
      await service.recheckPermissions();

      // Revoke both location and microphone
      permissionRegistry[TripPermission.location] = false;
      permissionRegistry[TripPermission.microphone] = false;

      await service.recheckPermissions();
      expect(fakeConvoy.onLocationRevokedCalled, isTrue);
      expect(fakeIntercom.onMicrophoneRevokedCalled, isTrue);

      // Reset test spy flags
      fakeConvoy.startRealGpsTrackingCalled = false;
      fakeConvoy.onLocationRestoredCalled = false;
      fakeIntercom.onMicrophoneRestoredCalled = false;

      // User restores ONLY microphone in settings, keeps location denied
      permissionRegistry[TripPermission.microphone] = true;

      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();

      // Only microphone feature resumed!
      expect(fakeIntercom.onMicrophoneRestoredCalled, isTrue);
      expect(fakeConvoy.onLocationRestoredCalled, isFalse);
      expect(fakeConvoy.startRealGpsTrackingCalled, isFalse);

      // Now user restores location
      permissionRegistry[TripPermission.location] = true;
      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();

      expect(fakeConvoy.onLocationRestoredCalled, isTrue);
      expect(fakeConvoy.startRealGpsTrackingCalled, isTrue);
      expect(service.hasActiveWarning, isFalse);
    });
  });

  group('ISSUE-7: Location Service Status & Quick Settings Changes (Req 3, 4)', () {
    test('GPS toggled off in Quick Settings immediately stops GPS tracking without app resume', () async {
      final service = createService();
      service.init();
      await pumpEventQueue();

      expect(fakeConvoy.stopRealGpsTrackingCalled, isFalse);

      // User pulls down Quick Settings and turns off Location
      locationServiceState = false;
      serviceStatusCtrl.add(ServiceStatus.disabled);
      await pumpEventQueue();

      expect(service.isGranted(TripPermission.locationService), isFalse);
      expect(service.hasEssentialRevocation, isTrue);
      expect(fakeConvoy.onLocationRevokedCalled, isTrue);
      expect(fakeConvoy.stopRealGpsTrackingCalled, isTrue);
    });

    test('GPS toggled on in Quick Settings resumes tracking if permission granted', () async {
      locationServiceState = false;
      permissionRegistry[TripPermission.locationService] = false;

      final service = createService();
      service.init();
      await pumpEventQueue();

      expect(service.hasEssentialRevocation, isTrue);

      // User re-enables GPS in Quick Settings
      locationServiceState = true;
      serviceStatusCtrl.add(ServiceStatus.enabled);
      await pumpEventQueue();

      expect(service.isGranted(TripPermission.locationService), isTrue);
      expect(fakeConvoy.onLocationRestoredCalled, isTrue);
      expect(fakeConvoy.startRealGpsTrackingCalled, isTrue);
      expect(service.hasActiveWarning, isFalse);
    });

    test('GPS toggled on does NOT resume tracking if location permission is still revoked', () async {
      permissionRegistry[TripPermission.location] = false;
      locationServiceState = false;

      final service = createService();
      service.init();
      await pumpEventQueue();

      fakeConvoy.startRealGpsTrackingCalled = false;

      // GPS hardware toggled on, but app permission is denied
      locationServiceState = true;
      serviceStatusCtrl.add(ServiceStatus.enabled);
      await pumpEventQueue();

      expect(fakeConvoy.startRealGpsTrackingCalled, isFalse);
      expect(service.hasEssentialRevocation, isTrue);
    });
  });

  group('ISSUE-7: Stop Relying on Revoked Permissions Immediately (Req 4)', () {
    test('Location revocation stops real GPS tracking immediately', () async {
      final service = createService();
      await service.recheckPermissions();

      service.setPermissionStateForTest(TripPermission.location, false);

      expect(fakeConvoy.onLocationRevokedCalled, isTrue);
      expect(fakeConvoy.stopRealGpsTrackingCalled, isTrue);
    });

    test('Microphone revocation immediately stops intercom stream and aborts transmission', () async {
      final service = createService();
      await service.recheckPermissions();

      fakeIntercom.isTransmitting = true;
      fakeIntercom.isMicOpen = true;

      service.setPermissionStateForTest(TripPermission.microphone, false);

      expect(fakeIntercom.onMicrophoneRevokedCalled, isTrue);
      expect(fakeIntercom.isMicrophoneRevoked, isTrue);
      expect(fakeIntercom.isTransmitting, isFalse);
      expect(fakeIntercom.isMicOpen, isFalse);
    });

    test('Bluetooth revocation immediately disconnects BLE remote accessory', () async {
      final service = createService();
      await service.recheckPermissions();

      expect(fakeBle.status, equals(BleRemoteStatus.listening));

      service.setPermissionStateForTest(TripPermission.bluetooth, false);

      expect(fakeBle.onBluetoothRevokedCalled, isTrue);
      expect(fakeBle.status, equals(BleRemoteStatus.disconnected));
    });
  });

  group('ISSUE-7: Active Trip Retention & Safety Invariance (Req 10)', () {
    test('Trip is NEVER terminated when location permission is revoked', () async {
      final service = createService();
      await service.recheckPermissions();

      service.setPermissionStateForTest(TripPermission.location, false);

      expect(fakeConvoy.leaveConvoyCalled, isFalse);
      expect(fakeConvoy.activeConvoy, isNotNull);
      expect(fakeConvoy.activeGroupId, equals('test_group_404'));
      expect(fakeConvoy.activeConvoy!.tripStatus, equals('ACTIVE'));
    });

    test('Trip is NEVER terminated when location service and all permissions are revoked', () async {
      final service = createService();
      await service.recheckPermissions();

      service.setPermissionStateForTest(TripPermission.location, false);
      service.setPermissionStateForTest(TripPermission.locationService, false);
      service.setPermissionStateForTest(TripPermission.microphone, false);
      service.setPermissionStateForTest(TripPermission.bluetooth, false);
      service.setPermissionStateForTest(TripPermission.notification, false);

      expect(fakeConvoy.leaveConvoyCalled, isFalse);
      expect(fakeConvoy.activeConvoy, isNotNull);
      expect(fakeConvoy.activeConvoy!.riders.length, equals(1));
    });
  });

  group('ISSUE-7: Essential vs Optional Permissions Classification (Req 6, 9)', () {
    test('Accurately identifies Essential vs Optional permissions', () {
      expect(PermissionRevocationSafetyService.isEssential(TripPermission.location), isTrue);
      expect(PermissionRevocationSafetyService.isEssential(TripPermission.locationService), isTrue);
      expect(PermissionRevocationSafetyService.isEssential(TripPermission.microphone), isFalse);
      expect(PermissionRevocationSafetyService.isEssential(TripPermission.bluetooth), isFalse);
      expect(PermissionRevocationSafetyService.isEssential(TripPermission.notification), isFalse);
      expect(PermissionRevocationSafetyService.isEssential(TripPermission.locationAlways), isFalse);
    });

    test('Provides clear feature description and explanation for every permission', () {
      for (final perm in TripPermission.values) {
        final feature = PermissionRevocationSafetyService.affectedFeature(perm);
        final reason = PermissionRevocationSafetyService.reasonRequired(perm);

        expect(feature, isNotEmpty);
        expect(reason, isNotEmpty);
        expect(feature.length, greaterThan(5));
        expect(reason.length, greaterThan(15));
      }
    });
  });

  group('ISSUE-7: Cockpit Warning Banner UI Tests (Req 5, 6, 7, 9, 11)', () {
    testWidgets('Renders prominent CRITICAL warning banner when location is revoked', (tester) async {
      final service = createService();
      service.setPermissionStateForTest(TripPermission.location, false);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CockpitPermissionWarningBanner(service: service),
          ),
        ),
      );

      expect(find.byType(CockpitPermissionWarningBanner), findsOneWidget);
      expect(find.text('CRITICAL · GPS REVOKED'), findsOneWidget);
      expect(find.text('Live Convoy Tracking & Speedometer'), findsOneWidget);
      expect(find.textContaining('Location permission is required'), findsOneWidget);
      expect(find.textContaining('Trip remains active'), findsOneWidget);
      expect(find.byKey(const Key('cockpit_permission_settings_button')), findsOneWidget);
      expect(find.byKey(const Key('cockpit_permission_retry_button')), findsOneWidget);
      // Essential warning cannot have a dismiss button
      expect(find.byKey(const Key('cockpit_permission_dismiss_button')), findsNothing);
    });

    testWidgets('Renders FEATURE LIMITED warning banner when microphone is revoked', (tester) async {
      final service = createService();
      service.setPermissionStateForTest(TripPermission.microphone, false);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CockpitPermissionWarningBanner(service: service),
          ),
        ),
      );

      expect(find.text('FEATURE LIMITED · OPTIONAL PERMISSION'), findsOneWidget);
      expect(find.text('Helmet Intercom Voice Transmission'), findsOneWidget);
      expect(find.textContaining('Microphone permission is required'), findsOneWidget);
      // Optional warnings provide a dismiss button
      expect(find.byKey(const Key('cockpit_permission_dismiss_button')), findsOneWidget);
    });

    testWidgets('Direct button opens Android app settings and meets 48dp touch target (Req 7)', (tester) async {
      final service = createService();
      service.setPermissionStateForTest(TripPermission.location, false);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CockpitPermissionWarningBanner(service: service),
          ),
        ),
      );

      final buttonFinder = find.byKey(const Key('cockpit_permission_settings_button'));
      expect(buttonFinder, findsOneWidget);

      final buttonSize = tester.getSize(buttonFinder);
      expect(buttonSize.height, greaterThanOrEqualTo(48.0));

      await tester.tap(buttonFinder);
      await tester.pump();

      expect(settingsOpenCount, equals(1));
    });

    testWidgets('Tapping RECHECK button triggers recheckPermissions', (tester) async {
      final service = createService();
      service.setPermissionStateForTest(TripPermission.location, false);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CockpitPermissionWarningBanner(service: service),
          ),
        ),
      );

      // Now restore permission in test registry
      permissionRegistry[TripPermission.location] = true;

      await tester.tap(find.byKey(const Key('cockpit_permission_retry_button')));
      await tester.pumpAndSettle();

      expect(service.hasActiveWarning, isFalse);
      expect(find.text('CRITICAL · GPS REVOKED'), findsNothing);
    });

    testWidgets('Optional warning banner can be dismissed, essential cannot', (tester) async {
      final service = createService();
      service.setPermissionStateForTest(TripPermission.microphone, false);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CockpitPermissionWarningBanner(service: service),
          ),
        ),
      );

      expect(find.text('Helmet Intercom Voice Transmission'), findsOneWidget);

      // Tap dismiss
      await tester.tap(find.byKey(const Key('cockpit_permission_dismiss_button')));
      await tester.pumpAndSettle();

      // Dismissed optional warning is hidden
      expect(find.text('Helmet Intercom Voice Transmission'), findsNothing);
      expect(service.hasActiveWarning, isFalse);
    });

    testWidgets('Renders SizedBox.shrink() when all permissions are healthy', (tester) async {
      final service = createService();
      await service.recheckPermissions();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CockpitPermissionWarningBanner(service: service),
          ),
        ),
      );

      expect(find.text('OPEN SETTINGS'), findsNothing);
      expect(find.textContaining('CRITICAL'), findsNothing);
    });
  });
}
