import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/network_models.dart';
import 'package:coroute_app/data/models/road_hazard_telemetry.dart';
import 'package:coroute_app/data/models/outbox_item.dart';
import 'package:coroute_app/data/models/pending_sos.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/presentation/rider/live_cockpit_map_screen.dart';

class MockWakelockPlatform extends WakelockPlusPlatformInterface {
  bool isEnabled = false;
  final List<bool> toggleCalls = [];

  @override
  Future<void> toggle({required bool enable}) async {
    isEnabled = enable;
    toggleCalls.add(enable);
  }

  @override
  Future<bool> get enabled async => isEnabled;

  void reset() {
    isEnabled = false;
    toggleCalls.clear();
  }
}

class MockAuthService extends ChangeNotifier implements AuthService {
  @override
  String? currentUserId = 'rider_me';

  @override
  String? currentUserName = 'Test Rider';

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isGetter) {
      return null;
    }
    return super.noSuchMethod(invocation);
  }
}

class MockConvoyService extends ChangeNotifier implements ConvoyService {
  @override
  String? activeGroupId = 'GRP-COCKPIT-1';

  @override
  ConvoyModel? activeConvoy;

  @override
  Map<String, ConvoyModel> allConvoys = {};

  @override
  String? myUserId = 'rider_me';

  @override
  bool canEditRoute = true;

  @override
  bool isOnline = true;

  @override
  bool isRealGpsActive = true;

  @override
  String? lastError;

  @override
  double? get myFixAccuracyM => 5.0;

  @override
  bool get serverUnreachable => false;

  @override
  bool get leaveRequestedFromNotification => false;

  @override
  bool get sosRequestedFromNotification => false;

  @override
  int get p2pMeshPeerCount => 0;

  @override
  List<AssistRequest> get assistRequests => const [];

  @override
  List<AssistNotice> get assistNotices => const [];

  @override
  List<Encounter> get encounters => const [];

  @override
  List<HazardWarning> get hazards => const [];

  @override
  List<RoadHazardObservation> get roadHazards => const [];

  @override
  List<OutboxItem> get outbox => const [];

  @override
  AssistRequest? get activeAssist => null;

  @override
  PendingSos? get pendingSos => null;

  @override
  String? get sosOkNotice => null;

  @override
  String? get systemBroadcastMessage => null;

  @override
  bool supports(dynamic feature) => true;

  @override
  void updateTripState(String state) {
    final c = allConvoys[activeGroupId];
    if (c != null) {
      allConvoys[activeGroupId!] = c.copyWith(tripStatus: state);
      activeConvoy = allConvoys[activeGroupId];
    }
    notifyListeners();
  }

  @override
  Future<void> leaveActiveConvoy(String userId) async {
    final gid = activeGroupId;
    if (gid != null) {
      allConvoys.remove(gid);
    }
    activeGroupId = null;
    activeConvoy = null;
    notifyListeners();
  }

  void triggerUpdate() {
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isGetter) {
      return null;
    }
    return super.noSuchMethod(invocation);
  }
}

RiderModel createTestRider(String id, String name) {
  return RiderModel(
    userId: id,
    name: name,
    lat: 17.4330,
    lng: 78.3782,
    speedKmh: 45.0,
    statusReason: '',
    lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
  );
}

ConvoyModel createTestConvoy(RiderModel me, {String tripStatus = 'STARTED'}) {
  return ConvoyModel(
    groupId: 'GRP-COCKPIT-1',
    name: 'Hyderabad Riders Club',
    joinCode: '456789',
    tripStatus: tripStatus,
    createdByUserId: me.userId,
    createdByUserName: me.name,
    createdAtEpochMs: 1700000000000,
    riders: {me.userId: me},
  );
}

Widget createTestApp({
  required Widget child,
  required MockAuthService auth,
  required MockConvoyService convoys,
  RouteObserver<ModalRoute<void>>? routeObserver,
  ApiClient? apiClient,
}) {
  final api = apiClient ?? ApiClient();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<ApiClient>.value(value: api),
      ChangeNotifierProvider<AuthService>.value(value: auth),
      ChangeNotifierProvider<ConvoyService>.value(value: convoys),
    ],
    child: MaterialApp(
      navigatorObservers: [?routeObserver],
      home: child,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockWakelockPlatform mockWakelock;
  late MockAuthService auth;
  late MockConvoyService convoys;
  late RiderModel me;
  late ConvoyModel convoy;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockWakelock = MockWakelockPlatform();
    WakelockPlusPlatformInterface.instance = mockWakelock;
    wakelockPlusPlatformInstance = mockWakelock;

    auth = MockAuthService();
    convoys = MockConvoyService();
    me = createTestRider('rider_me', 'Test Rider');
    convoy = createTestConvoy(me, tripStatus: 'STARTED');
    convoys.allConvoys[convoy.groupId] = convoy;
    convoys.activeConvoy = convoy;
    convoys.activeGroupId = convoy.groupId;
  });

  group('ISSUE-9: Active Trip Screen Visibility & Keep Screen Awake (FLAG_KEEP_SCREEN_ON)', () {
    testWidgets('1. Wakelock is enabled when active cockpit is visible in the foreground', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          auth: auth,
          convoys: convoys,
          child: const LiveCockpitMapScreen(
            convoyId: 'GRP-COCKPIT-1',
            isVisible: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(mockWakelock.isEnabled, isTrue, reason: 'Wakelock must be enabled during active foreground cockpit navigation');
      expect(mockWakelock.toggleCalls, contains(true));
    });

    testWidgets('2. Wakelock is disabled when active cockpit is closed/disposed', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          auth: auth,
          convoys: convoys,
          child: const LiveCockpitMapScreen(
            convoyId: 'GRP-COCKPIT-1',
            isVisible: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(mockWakelock.isEnabled, isTrue);

      // Unmount the cockpit (replace with placeholder)
      await tester.pumpWidget(
        createTestApp(
          auth: auth,
          convoys: convoys,
          child: const Scaffold(body: Text('Outside Cockpit')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(mockWakelock.isEnabled, isFalse, reason: 'Normal Android screen timeout must be restored when cockpit is closed');
      expect(mockWakelock.toggleCalls.last, isFalse);
    });

    testWidgets('3. Wakelock disables when switching away from active tab and restores when returning', (tester) async {
      final routeObserver = RouteObserver<ModalRoute<void>>();

      await tester.pumpWidget(
        createTestApp(
          auth: auth,
          convoys: convoys,
          routeObserver: routeObserver,
          child: LiveCockpitMapScreen(
            convoyId: 'GRP-COCKPIT-1',
            isVisible: true,
            routeObserver: routeObserver,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(mockWakelock.isEnabled, isTrue);

      // User navigates away to another tab (isVisible = false)
      await tester.pumpWidget(
        createTestApp(
          auth: auth,
          convoys: convoys,
          routeObserver: routeObserver,
          child: LiveCockpitMapScreen(
            convoyId: 'GRP-COCKPIT-1',
            isVisible: false,
            routeObserver: routeObserver,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(mockWakelock.isEnabled, isFalse, reason: 'Wakelock must be disabled when user navigates away to another tab');

      // User switches back to active cockpit tab (isVisible = true)
      await tester.pumpWidget(
        createTestApp(
          auth: auth,
          convoys: convoys,
          routeObserver: routeObserver,
          child: LiveCockpitMapScreen(
            convoyId: 'GRP-COCKPIT-1',
            isVisible: true,
            routeObserver: routeObserver,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(mockWakelock.isEnabled, isTrue, reason: 'Wakelock must re-enable when user returns to active cockpit tab');
    });

    testWidgets('4. Wakelock disables when navigating away via pushed route and restores on pop', (tester) async {
      final routeObserver = RouteObserver<ModalRoute<void>>();
      final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ApiClient>.value(value: ApiClient()),
            ChangeNotifierProvider<AuthService>.value(value: auth),
            ChangeNotifierProvider<ConvoyService>.value(value: convoys),
          ],
          child: MaterialApp(
            navigatorKey: navKey,
            navigatorObservers: [routeObserver],
            home: LiveCockpitMapScreen(
              convoyId: 'GRP-COCKPIT-1',
              isVisible: true,
              routeObserver: routeObserver,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(mockWakelock.isEnabled, isTrue);

      // Push a new screen on top (navigating away from active cockpit)
      navKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Settings / Secondary View')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(mockWakelock.isEnabled, isFalse, reason: 'Wakelock must be disabled when another route obscures the cockpit');

      // Pop the screen to return to the active cockpit
      navKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(mockWakelock.isEnabled, isTrue, reason: 'Wakelock must re-enable when returning to the cockpit');
    });

    testWidgets('5. Wakelock disables when app is backgrounded / paused and re-enables when resumed', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          auth: auth,
          convoys: convoys,
          child: const LiveCockpitMapScreen(
            convoyId: 'GRP-COCKPIT-1',
            isVisible: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(mockWakelock.isEnabled, isTrue);

      // App transitions to paused (backgrounded)
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(mockWakelock.isEnabled, isFalse, reason: 'Wakelock must be disabled when app is paused/backgrounded');

      // App transitions back to resumed
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(mockWakelock.isEnabled, isTrue, reason: 'Wakelock must be enabled when app resumes');
    });

    testWidgets('6. Rider manually pressed power to lock device: screen does NOT turn on repeatedly', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          auth: auth,
          convoys: convoys,
          child: const LiveCockpitMapScreen(
            convoyId: 'GRP-COCKPIT-1',
            isVisible: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(mockWakelock.isEnabled, isTrue);

      // Rider presses power button: lifecycle changes to inactive/paused
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(mockWakelock.isEnabled, isFalse);

      final callsCountWhileLocked = mockWakelock.toggleCalls.length;

      // Simulated background GPS fixes and convoy location updates while device is locked
      for (int i = 0; i < 5; i++) {
        convoys.triggerUpdate();
        await tester.pump(const Duration(milliseconds: 100));
      }

      // Assert that wakelock was NOT re-enabled and no toggle calls were made to wake the display
      expect(mockWakelock.isEnabled, isFalse, reason: 'Display must stay off when power button locked device');
      expect(mockWakelock.toggleCalls.length, equals(callsCountWhileLocked),
          reason: 'No redundant enable/toggle calls should be issued while device is locked');
    });

    testWidgets('7. Wakelock is disabled when trip is ended or cancelled', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          auth: auth,
          convoys: convoys,
          child: const LiveCockpitMapScreen(
            convoyId: 'GRP-COCKPIT-1',
            isVisible: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(mockWakelock.isEnabled, isTrue);

      // Trip ends
      convoys.updateTripState('ENDED');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(mockWakelock.isEnabled, isFalse, reason: 'Wakelock must be disabled when trip is completed or cancelled');
    });

    testWidgets('8. Wakelock is disabled when rider leaves the active convoy', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          auth: auth,
          convoys: convoys,
          child: const LiveCockpitMapScreen(
            convoyId: 'GRP-COCKPIT-1',
            isVisible: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(mockWakelock.isEnabled, isTrue);

      // Rider leaves convoy
      await convoys.leaveActiveConvoy('rider_me');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(mockWakelock.isEnabled, isFalse, reason: 'Wakelock must be disabled when rider leaves convoy');
    });
  });
}
