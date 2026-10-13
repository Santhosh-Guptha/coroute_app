import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/services/offline_nav_service.dart';
import 'package:coroute_app/domain/route/lost_rider_recovery_coordinator.dart';
import 'package:coroute_app/presentation/ride/navigate_to.dart';

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
}
