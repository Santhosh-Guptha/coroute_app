import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/stop_point_model.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/presentation/trip_planner/route_stops_panel.dart';
import 'package:coroute_app/data/services/offline_nav_service.dart';
import 'package:coroute_app/domain/route/lost_rider_recovery_coordinator.dart';
import 'package:coroute_app/presentation/ride/navigate_to.dart';
import 'package:coroute_app/data/models/outbox_item.dart';
import 'package:coroute_app/presentation/rider/widgets/glove_quick_settings_modal.dart';

class _FakeConvoyService extends ChangeNotifier implements ConvoyService {
  @override
  String? myUserId = 'user_lead';

  @override
  bool canEditRoute = true;

  @override
  bool isOnline = true;

  @override
  List<OutboxItem> outbox = [];

  @override
  Map<String, ConvoyModel> allConvoys = {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    navigateLauncherOverride = null;
    OfflineNavService.exportOverride = null;
  });

  tearDown(() {
    navigateLauncherOverride = null;
    OfflineNavService.exportOverride = null;
  });

  group('Standard Navigation URI resolution (navigate_to.dart)', () {
    test('navigationUris generates prioritized list with standard intents', () {
      final uris = navigationUris(
        17.500000,
        78.500000,
        label: 'Fort & Lake',
        startLat: 17.400000,
        startLng: 78.400000,
      );

      expect(uris.length, 3);

      // 1. Google Maps / Android Navigation Turn-by-Turn
      expect(uris[0].scheme, 'google.navigation');
      expect(uris[0].toString(), contains('mode=d'));
      expect(uris[0].toString(), contains('17.500000,78.500000'));

      // 2. Any map app (geo:)
      expect(uris[1].scheme, 'geo');
      expect(uris[1].toString(), contains('17.500000,78.500000'));

      // 3. Browser fallback
      expect(uris[2].scheme, 'https');
      expect(uris[2].host, 'www.google.com');
      expect(uris[2].toString(), contains('17.500000,78.500000'));
    });

    test('navigateTo tries links in order until one succeeds', () async {
      final tried = <String>[];
      navigateLauncherOverride = (uri) async {
        tried.add(uri.toString());
        // Simulate google.navigation not installed (fails), but geo succeeding
        if (uri.scheme == 'google.navigation') return false;
        return true;
      };

      final ok = await navigateTo(17.5, 78.5, label: 'Target');
      expect(ok, isTrue);
      expect(tried.length, 2);
      expect(tried[0], startsWith('google.navigation:'));
      expect(tried[1], startsWith('geo:'));
    });

    test('navigateTo succeeds on first link if google.navigation is available', () async {
      final tried = <String>[];
      navigateLauncherOverride = (uri) async {
        tried.add(uri.toString());
        return true;
      };

      final ok = await navigateTo(17.5, 78.5, label: 'Target');
      expect(ok, isTrue);
      expect(tried.length, 1);
      expect(tried[0], startsWith('google.navigation:'));
    });

    test('navigateTo returns false on invalid coordinates', () async {
      var called = false;
      navigateLauncherOverride = (uri) async {
        called = true;
        return true;
      };

      expect(await navigateTo(0, 0), isFalse);
      expect(await navigateTo(double.nan, 78.5), isFalse);
      expect(await navigateTo(17.5, double.infinity), isFalse);
      expect(called, isFalse);
    });
  });

  group('OfflineNavService GPX generation & export', () {
    test('buildGpxContent generates valid GPX 1.1 XML structure', () {
      final xml = OfflineNavService.buildGpxContent(
        tripName: 'Western Ghats Ridge & Peak',
        points: [
          (17.400000, 78.400000),
          (17.410000, 78.410000),
          (17.420000, 78.420000),
        ],
        checkpoints: [
          ('Fuel Stop 1', 17.405000, 78.405000),
          ('Regroup Point', 17.415000, 78.415000),
        ],
      );

      expect(xml, contains('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(xml, contains('<gpx version="1.1" creator="CoRoute Convoy Safety Telemetry"'));
      expect(xml, contains('<name>Western Ghats Ridge &amp; Peak</name>'));

      // Checkpoints
      expect(xml, contains('<wpt lat="17.405000" lon="78.405000">'));
      expect(xml, contains('<name>Fuel Stop 1</name>'));
      expect(xml, contains('<wpt lat="17.415000" lon="78.415000">'));
      expect(xml, contains('<name>Regroup Point</name>'));

      // Trackpoints
      expect(xml, contains('<trk>'));
      expect(xml, contains('<trkseg>'));
      expect(xml, contains('<trkpt lat="17.400000" lon="78.400000" />'));
      expect(xml, contains('<trkpt lat="17.410000" lon="78.410000" />'));
      expect(xml, contains('<trkpt lat="17.420000" lon="78.420000" />'));
      expect(xml, contains('</trkseg>'));
      expect(xml, contains('</trk>'));
      expect(xml, contains('</gpx>'));
    });

    test('buildGpxContent handles XML entity escaping correctly', () {
      final xml = OfflineNavService.buildGpxContent(
        tripName: 'Ride <Fast> & "Safe"',
        points: [(17.0, 78.0)],
        checkpoints: [('Cafe <Brews>', 17.0, 78.0)],
      );

      expect(xml, contains('<name>Ride &lt;Fast&gt; &amp; &quot;Safe&quot;</name>'));
      expect(xml, contains('<name>Cafe &lt;Brews&gt;</name>'));
    });

    test('exportGpxRoute rejects empty route points', () async {
      final ok = await OfflineNavService.exportGpxRoute(
        tripName: 'Empty Route',
        points: [],
      );
      expect(ok, isFalse);
    });

    test('exportGpxRoute delegates to exportOverride in tests', () async {
      String? exportedName;
      int pointsCount = 0;
      int checkpointsCount = 0;

      OfflineNavService.exportOverride = ({
        required String tripName,
        required List<(double lat, double lng)> points,
        List<(String name, double lat, double lng)> checkpoints = const [],
      }) async {
        exportedName = tripName;
        pointsCount = points.length;
        checkpointsCount = checkpoints.length;
        return true;
      };

      final ok = await OfflineNavService.exportGpxRoute(
        tripName: 'Araku Valley Loop',
        points: [(18.3, 82.8), (18.4, 82.9)],
        checkpoints: [('Tunnel 1', 18.35, 82.85)],
      );

      expect(ok, isTrue);
      expect(exportedName, 'Araku Valley Loop');
      expect(pointsCount, 2);
      expect(checkpointsCount, 1);
    });
  });

  group('LostRiderRecoveryCoordinator Navigation Integration', () {
    test('launchHomingNavigation delegates to navigateTo', () async {
      Uri? launchedUri;
      navigateLauncherOverride = (uri) async {
        launchedUri = uri;
        return true;
      };

      const vector = RecoveryVector(
        targetType: RecoveryTargetType.routeLine,
        targetLat: 17.5000,
        targetLng: 78.5000,
        distanceMeters: 450,
        bearingDegrees: 45,
        instruction: 'Turn North-East to rejoin route',
        usingGpsCourse: true,
      );

      final ok = await LostRiderRecoveryCoordinator.launchHomingNavigation(vector, 17.4950, 78.4950);
      expect(ok, isTrue);
      expect(launchedUri, isNotNull);
      expect(launchedUri!.scheme, 'google.navigation');
      expect(launchedUri!.toString(), contains('17.500000,78.500000'));
    });
  });

  group('GloveQuickSettingsModal offline navigation trigger', () {
    testWidgets('renders Offline voice nav button and calls callback when tapped', (tester) async {
      var navTapped = false;

      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GloveQuickSettingsModal(
            keepScreenOn: true,
            autoFollow: true,
            onToggleKeepScreenOn: () {},
            onToggleAutoFollow: () {},
            onLaunchOfflineNav: () => navTapped = true,
          ),
        ),
      ));

      expect(find.text('Offline voice nav'), findsOneWidget);
      expect(find.byIcon(Icons.navigation_outlined), findsOneWidget);

      await tester.ensureVisible(find.text('Offline voice nav'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Offline voice nav'));
      await tester.pump();

      expect(navTapped, isTrue);
    });
  });

  group('RouteStopsPanel In-Ride Navigation Tests', () {
    testWidgets('destination navigate button triggers navigateTo with destination coords', (tester) async {
      Uri? launchedUri;
      navigateLauncherOverride = (uri) async {
        launchedUri = uri;
        return true;
      };

      final me = RiderModel(
        userId: 'user_lead',
        name: 'Lead Rider',
        lat: 17.3850,
        lng: 78.4867,
        speedKmh: 40.0,
        statusReason: '',
        lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
      );

      final convoy = ConvoyModel(
        groupId: 'GRP-TEST-NAV',
        name: 'Highway Run',
        joinCode: '112233',
        createdByUserId: me.userId,
        createdByUserName: me.name,
        createdAtEpochMs: 1700000000000,
        destinationLat: 17.5000,
        destinationLng: 78.5000,
        destinationName: 'Lake Viewpoint',
        riders: {me.userId: me},
      );

      final fakeSvc = _FakeConvoyService();
      fakeSvc.allConvoys[convoy.groupId] = convoy;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider<ConvoyService>.value(
              value: fakeSvc,
              child: RouteStopsPanel(convoy: convoy),
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('destination_navigate_button')), findsOneWidget);

      await tester.tap(find.byKey(const Key('destination_navigate_button')));
      await tester.pump();

      expect(launchedUri, isNotNull);
      expect(launchedUri!.scheme, 'google.navigation');
      expect(launchedUri!.toString(), contains('17.500000,78.500000'));
    });

    testWidgets('stop navigate button triggers navigateTo with stop coords', (tester) async {
      Uri? launchedUri;
      navigateLauncherOverride = (uri) async {
        launchedUri = uri;
        return true;
      };

      final me = RiderModel(
        userId: 'user_lead',
        name: 'Lead Rider',
        lat: 17.3850,
        lng: 78.4867,
        speedKmh: 40.0,
        statusReason: '',
        lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
      );

      final stop = StopPointModel(
        stopId: 'stop_1',
        name: 'Hilltop Dhaba',
        category: 'FOOD',
        lat: 17.4500,
        lng: 78.4900,
        orderIndex: 0,
      );

      final convoy = ConvoyModel(
        groupId: 'GRP-TEST-NAV',
        name: 'Highway Run',
        joinCode: '112233',
        createdByUserId: me.userId,
        createdByUserName: me.name,
        createdAtEpochMs: 1700000000000,
        stopPoints: [stop],
        riders: {me.userId: me},
      );

      final fakeSvc = _FakeConvoyService();
      fakeSvc.allConvoys[convoy.groupId] = convoy;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider<ConvoyService>.value(
              value: fakeSvc,
              child: RouteStopsPanel(convoy: convoy),
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('stop_navigate_button_stop_1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('stop_navigate_button_stop_1')));
      await tester.pump();

      expect(launchedUri, isNotNull);
      expect(launchedUri!.scheme, 'google.navigation');
      expect(launchedUri!.toString(), contains('17.450000,78.490000'));
    });
  });
}
