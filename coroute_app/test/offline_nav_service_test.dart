import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';
import 'package:coroute_app/presentation/trip_planner/widgets/organic_maps_card.dart';
import 'package:coroute_app/data/services/offline_nav_service.dart';
import 'package:coroute_app/domain/route/lost_rider_recovery_coordinator.dart';
import 'package:coroute_app/presentation/ride/navigate_to.dart';
import 'package:coroute_app/presentation/rider/widgets/glove_quick_settings_modal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    navigateLauncherOverride = null;
    OfflineNavService.exportOverride = null;
    OfflineNavService.installedOverride = null;
    OfflineNavService.downloadRegionOverride = null;
  });

  tearDown(() {
    navigateLauncherOverride = null;
    OfflineNavService.exportOverride = null;
    OfflineNavService.installedOverride = null;
    OfflineNavService.downloadRegionOverride = null;
  });

  group('Organic Maps URI resolution (navigate_to.dart)', () {
    test('navigationUris generates prioritized list with start and destination', () {
      final uris = navigationUris(
        17.500000,
        78.500000,
        label: 'Fort & Lake',
        startLat: 17.400000,
        startLng: 78.400000,
      );

      expect(uris.length, 5);

      // 1. Organic Maps Turn-by-Turn Route
      expect(uris[0].scheme, 'om');
      expect(uris[0].host, 'route');
      expect(uris[0].queryParameters['sll'], '17.400000,78.400000');
      expect(uris[0].queryParameters['saddr'], 'My Location');
      expect(uris[0].queryParameters['dll'], '17.500000,78.500000');
      expect(uris[0].queryParameters['daddr'], 'Fort & Lake');
      expect(uris[0].queryParameters['type'], 'vehicle');

      // 2. Organic Maps Location Pin with CoRoute return link
      expect(uris[1].scheme, 'om');
      expect(uris[1].host, 'map');
      expect(uris[1].queryParameters['ll'], '17.500000,78.500000');
      expect(uris[1].queryParameters['n'], 'Fort & Lake');
      expect(uris[1].queryParameters['backurl'], 'coroute://cockpit');

      // 3. Google Maps Turn-by-Turn
      expect(uris[2].scheme, 'google.navigation');
      expect(uris[2].toString(), contains('mode=d'));

      // 4. Any map app (geo:)
      expect(uris[3].scheme, 'geo');

      // 5. Browser fallback
      expect(uris[4].scheme, 'https');
      expect(uris[4].host, 'www.google.com');
    });

    test('navigationUris generates om://route without start coordinates when omitted', () {
      final uris = navigationUris(17.500000, 78.500000, label: 'Fort');
      expect(uris[0].scheme, 'om');
      expect(uris[0].host, 'route');
      expect(uris[0].queryParameters.containsKey('sll'), isFalse);
      expect(uris[0].queryParameters['dll'], '17.500000,78.500000');
      expect(uris[0].queryParameters['type'], 'vehicle');
    });

    test('navigateTo tries links in order until one succeeds', () async {
      final tried = <String>[];
      navigateLauncherOverride = (uri) async {
        tried.add(uri.toString());
        // Simulate Organic Maps not installed (fails), but Google Maps succeeding
        if (uri.scheme == 'om') return false;
        return true;
      };

      final ok = await navigateTo(17.5, 78.5, label: 'Target');
      expect(ok, isTrue);
      expect(tried.length, 3); // Tried om://route, om://map, then succeeded on google.navigation
      expect(tried[0], startsWith('om://route'));
      expect(tried[1], startsWith('om://map'));
      expect(tried[2], startsWith('google.navigation:'));
    });

    test('navigateTo succeeds on first link if Organic Maps is available', () async {
      final tried = <String>[];
      navigateLauncherOverride = (uri) async {
        tried.add(uri.toString());
        return true;
      };

      final ok = await navigateTo(17.5, 78.5, label: 'Target');
      expect(ok, isTrue);
      expect(tried.length, 1);
      expect(tried[0], startsWith('om://route'));
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

    test('exportRouteToOrganicMaps rejects empty route points', () async {
      final ok = await OfflineNavService.exportRouteToOrganicMaps(
        tripName: 'Empty Trip',
        points: [],
      );
      expect(ok, isFalse);
    });

    test('exportRouteToOrganicMaps delegates to exportOverride in tests', () async {
      var overrideCalled = false;
      OfflineNavService.exportOverride = ({
        required String tripName,
        required List<(double lat, double lng)> points,
        List<(String name, double lat, double lng)> checkpoints = const [],
      }) async {
        overrideCalled = true;
        expect(tripName, 'Monsoon Convoy');
        expect(points.length, 2);
        expect(checkpoints.length, 1);
        return true;
      };

      final ok = await OfflineNavService.exportRouteToOrganicMaps(
        tripName: 'Monsoon Convoy',
        points: [(17.0, 78.0), (17.1, 78.1)],
        checkpoints: [('Fuel', 17.05, 78.05)],
      );

      expect(ok, isTrue);
      expect(overrideCalled, isTrue);
    });
  });

  group('LostRiderRecoveryCoordinator offline homing navigation', () {
    test('launchHomingNavigation delegates to navigateTo with correct coords', () async {
      final tried = <String>[];
      navigateLauncherOverride = (uri) async {
        tried.add(uri.toString());
        return true;
      };

      const vector = RecoveryVector(
        targetType: RecoveryTargetType.routeLine,
        targetLat: 17.450000,
        targetLng: 78.450000,
        distanceMeters: 450,
        bearingDegrees: 45,
        instruction: 'Rejoin Route Line: Head NE for 450 m',
        usingGpsCourse: true,
      );

      final ok = await LostRiderRecoveryCoordinator.launchHomingNavigation(
        vector,
        17.446000,
        78.446000,
      );

      expect(ok, isTrue);
      expect(tried.length, 1);
      expect(tried[0], contains('om://route'));
      expect(tried[0], contains('dll=17.450000,78.450000'));
      expect(tried[0], contains('sll=17.446000,78.446000'));
      expect(tried[0], contains('Rejoin%20Convoy%20Route'));
    });
  });

  group('GloveQuickSettingsModal offline navigation trigger', () {
    testWidgets('renders Offline voice nav button and calls callback when tapped', (tester) async {
      var triggered = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GloveQuickSettingsModal(
            keepScreenOn: true,
            autoFollow: true,
            onToggleKeepScreenOn: () {},
            onToggleAutoFollow: () {},
            onLaunchOfflineNav: () => triggered = true,
          ),
        ),
      ));

      expect(find.byKey(const Key('quick_action_offline_nav')), findsOneWidget);
      expect(find.text('Offline voice nav'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('quick_action_offline_nav')));
      await tester.tap(find.byKey(const Key('quick_action_offline_nav')));
      await tester.pump();

      expect(triggered, isTrue);
    });
  });

  group('OfflineNavService On-Demand Region Download & Route Deep Links', () {
    test('openOrganicMapsRegionDownload generates om://map with destination and backurl', () async {
      Uri? launchedUri;
      OfflineNavService.downloadRegionOverride = (uri) async {
        launchedUri = uri;
        return true;
      };

      final ok = await OfflineNavService.openOrganicMapsRegionDownload(
        lat: 12.971600,
        lng: 77.594600,
        label: 'Bangalore Fort',
      );

      expect(ok, isTrue);
      expect(launchedUri, isNotNull);
      expect(launchedUri!.scheme, 'om');
      expect(launchedUri!.host, 'map');
      expect(launchedUri!.queryParameters['v'], '1');
      expect(launchedUri!.queryParameters['ll'], '12.971600,77.594600');
      expect(launchedUri!.queryParameters['n'], 'Bangalore Fort');
      expect(launchedUri!.queryParameters['backurl'], 'coroute://cockpit');
    });

    test('openOrganicMapsRegionDownload rejects invalid coordinates', () async {
      var called = false;
      OfflineNavService.downloadRegionOverride = (_) async {
        called = true;
        return true;
      };

      expect(await OfflineNavService.openOrganicMapsRegionDownload(lat: 0, lng: 0), isFalse);
      expect(await OfflineNavService.openOrganicMapsRegionDownload(lat: double.nan, lng: 77.0), isFalse);
      expect(called, isFalse);
    });

    test('openOrganicMapsRoute generates om://route with sll, dll, and backurl', () async {
      Uri? launchedUri;
      OfflineNavService.downloadRegionOverride = (uri) async {
        launchedUri = uri;
        return true;
      };

      final ok = await OfflineNavService.openOrganicMapsRoute(
        startLat: 17.385000,
        startLng: 78.486700,
        destLat: 12.971600,
        destLng: 77.594600,
        startName: 'Hyderabad',
        destName: 'Bangalore',
      );

      expect(ok, isTrue);
      expect(launchedUri, isNotNull);
      expect(launchedUri!.scheme, 'om');
      expect(launchedUri!.host, 'route');
      expect(launchedUri!.queryParameters['sll'], '17.385000,78.486700');
      expect(launchedUri!.queryParameters['saddr'], 'Hyderabad');
      expect(launchedUri!.queryParameters['dll'], '12.971600,77.594600');
      expect(launchedUri!.queryParameters['daddr'], 'Bangalore');
      expect(launchedUri!.queryParameters['type'], 'vehicle');
      expect(launchedUri!.queryParameters['backurl'], 'coroute://cockpit');
    });
  });

  group('OrganicMapsCard Widget Tests in Trip Creation', () {
    final testPoints = [(17.385, 78.4867), (17.400, 78.5000), (17.420, 78.5200)];

    testWidgets('renders empty shrink widget when route is null or approximate', (tester) async {
      OfflineNavService.installedOverride = () async => true;

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: OrganicMapsCard(route: null),
        ),
      ));

      expect(find.byType(OrganicMapsCard), findsOneWidget);
      expect(find.text('Organic Maps Offline'), findsNothing);

      final approxRoute = RouteModel(
        distanceM: 5000,
        durationS: 600,
        polyline: GeoMath.encodePolyline(testPoints),
        approximate: true,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OrganicMapsCard(route: approxRoute),
        ),
      ));

      expect(find.text('Organic Maps Offline'), findsNothing);
    });

    testWidgets('renders Install state when Organic Maps is not installed', (tester) async {
      OfflineNavService.installedOverride = () async => false;

      final route = RouteModel(
        distanceM: 5000,
        durationS: 600,
        polyline: GeoMath.encodePolyline(testPoints),
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OrganicMapsCard(
            route: route,
            tripName: 'Highway Ride',
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('Organic Maps Companion'), findsOneWidget);
      expect(find.text('OFFLINE'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Install'), findsOneWidget);
    });

    testWidgets('renders READY state with Download Map and Sync Route when installed', (tester) async {
      OfflineNavService.installedOverride = () async => true;
      Uri? downloadTarget;
      OfflineNavService.downloadRegionOverride = (uri) async {
        downloadTarget = uri;
        return true;
      };

      var exportCalled = false;
      OfflineNavService.exportOverride = ({
        required String tripName,
        required List<(double lat, double lng)> points,
        List<(String name, double lat, double lng)> checkpoints = const [],
      }) async {
        exportCalled = true;
        return true;
      };

      final route = RouteModel(
        distanceM: 5000,
        durationS: 600,
        polyline: GeoMath.encodePolyline(testPoints),
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OrganicMapsCard(
            route: route,
            tripName: 'Srisailam Ghat Run',
            destinationPoint: (17.420, 78.5200),
            destinationName: 'Srisailam Dam',
            checkpoints: const [('Ghat Viewpoint', 17.400, 78.500)],
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('Organic Maps Offline'), findsOneWidget);
      expect(find.text('READY'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Download Map'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Sync Route GPX'), findsOneWidget);

      // Tap Download Map -> triggers on-demand regional map deep link in Organic Maps
      await tester.tap(find.widgetWithText(OutlinedButton, 'Download Map'));
      await tester.pump();

      expect(downloadTarget, isNotNull);
      expect(downloadTarget!.scheme, 'om');
      expect(downloadTarget!.host, 'map');
      expect(downloadTarget!.queryParameters['ll'], '17.420000,78.520000');
      expect(downloadTarget!.queryParameters['backurl'], 'coroute://cockpit');

      // Tap Sync Route GPX -> triggers GPX track export
      await tester.tap(find.widgetWithText(OutlinedButton, 'Sync Route GPX'));
      await tester.pump();

      expect(exportCalled, isTrue);
    });
  });
}

