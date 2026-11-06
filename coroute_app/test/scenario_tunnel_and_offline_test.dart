import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/tracking/dead_reckoning_engine.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('Scenario Tunnel Blackout and Offline Safety Suite', () {
    const int t0 = 1700000000000;

    // Atal Tunnel Rohtang polyline segment:
    // South Portal: lat 32.3639, lng 77.1462 (elevation ~3060m)
    // North Portal: lat 32.4411, lng 77.1594 (elevation ~3040m, approx 9.02 km)
    final atalTunnelPolyline = <(double, double)>[
      for (double step = 0; step <= 1.0 + 1e-9; step += 0.05)
        (
          32.3639 + (32.4411 - 32.3639) * step,
          77.1462 + (32.1594 - 32.1462) * step,
        )
    ];

    group('REQ-03: Dead-Zone Tunnel Coasting and GPS Shadow Dead-Reckoning Engine', () {
      test('Recognizes Indian highway tunnel portals and entry proximities', () {
        expect(DeadReckoningEngine.knownTunnels, isNotEmpty);

        // Atal Tunnel Rohtang
        final atal = DeadReckoningEngine.knownTunnels.firstWhere(
          (t) => t.name.contains('Atal Tunnel'),
        );
        expect(atal.lengthMeters, equals(9020));
        expect(atal.entryLat, closeTo(32.3639, 0.001));

        // Proximity detection at South Portal
        const southPortalLat = 32.3639;
        const southPortalLng = 77.1462;
        expect(
          DeadReckoningEngine.isNearTunnelPortal(southPortalLat, southPortalLng),
          isTrue,
        );

        final nearby = DeadReckoningEngine.findNearbyTunnel(southPortalLat, southPortalLng);
        expect(nearby, isNotNull);
        expect(nearby!.name, contains('Atal Tunnel'));

        // Point far away from any tunnel
        expect(
          DeadReckoningEngine.isNearTunnelPortal(12.9716, 77.5946),
          isFalse,
        );
        expect(
          DeadReckoningEngine.findNearbyTunnel(12.9716, 77.5946),
          isNull,
        );
      });

      test('Smooth coasting projection through Atal Tunnel with speed exponential decay', () {
        final engine = DeadReckoningEngine(plannedRoute: atalTunnelPolyline);

        const entryLat = 32.3639;
        const entryLng = 77.1462;
        const entrySpeedKmh = 72.0; // 20 m/s entry cruising speed
        const entryHeading = 10.0;

        engine.startCoasting(
          lat: entryLat,
          lng: entryLng,
          speedKmh: entrySpeedKmh,
          heading: entryHeading,
          timestampMs: t0,
        );

        expect(engine.isCoasting, isTrue);
        expect(engine.crashDetectedInTunnel, isFalse);

        // Point along route lookup
        final p0 = DeadReckoningEngine.pointAlongRoute(0.0, atalTunnelPolyline);
        expect(p0, isNotNull);
        expect(p0!.$1, closeTo(entryLat, 0.001));

        // 1 minute (60s) into blackout: speed decays smoothly
        final fix60s = engine.computeFix(t0 + 60000);
        expect(fix60s.isCoasting, isTrue);
        expect(fix60s.confidence, TrackingConfidence.tunnelCoasting);
        expect(fix60s.elapsedSeconds, 60);
        expect(fix60s.statusDescription, contains('Tunnel Coasting (60s)'));
        expect(fix60s.speedKmh, lessThan(entrySpeedKmh));
        expect(fix60s.speedKmh, greaterThan(55.0)); // exponential decay v0 * exp(-0.0025 * 60) ~ 62 km/h
        expect(fix60s.alongRouteM, greaterThan(900.0));
        expect(fix60s.hasTimedOut, isFalse);
        expect(fix60s.isCrashStop, isFalse);

        // 3 minutes (180s) into blackout: progressive forward motion along polyline
        final fix180s = engine.computeFix(t0 + 180000);
        expect(fix180s.isCoasting, isTrue);
        expect(fix180s.confidence, TrackingConfidence.tunnelCoasting);
        expect(fix180s.elapsedSeconds, 180);
        expect(fix180s.alongRouteM, greaterThan(fix60s.alongRouteM));
        expect(fix180s.speedKmh, lessThan(fix60s.speedKmh));

        // RiderModel integration flag
        final rider = RiderModel(
          userId: 'u_rider_1',
          name: 'Karan',
          lat: fix180s.lat,
          lng: fix180s.lng,
          speedKmh: fix180s.speedKmh,
          lastSeenEpochMs: t0 + 180000,
          trackingConfidence: fix180s.confidence,
        );
        expect(rider.isTunnelCoasting, isTrue);
        expect(rider.trackingConfidence.toWire(), 'TUNNEL_COASTING');

        // Tunnel exit GPS re-acquisition
        engine.onGpsRecovered();
        expect(engine.isCoasting, isFalse);
        final fixRecovered = engine.computeFix(t0 + 200000);
        expect(fixRecovered.isCoasting, isFalse);
        expect(fixRecovered.confidence, TrackingConfidence.gpsFix);
        expect(fixRecovered.statusDescription, 'GPS Fix Active');
      });

      test('Tunnel crash detection halts projection at impact point and flags crash stop', () {
        final engine = DeadReckoningEngine(plannedRoute: atalTunnelPolyline);

        engine.startCoasting(
          lat: 32.3639,
          lng: 77.1462,
          speedKmh: 65.0,
          heading: 10.0,
          timestampMs: t0,
        );

        // Coast for 45s normally
        final normalFix = engine.computeFix(t0 + 45000);
        expect(normalFix.isCrashStop, isFalse);

        // Ingest normal road vibration (peakG 1.8, stdG 0.25): no crash triggered
        engine.checkAccelerometer(
          const AccelBucket(tMs: t0 + 46000, peakG: 1.8, meanG: 1.05, stdG: 0.25),
        );
        expect(engine.crashDetectedInTunnel, isFalse);

        // Sudden deceleration impact bucket inside tunnel (peakG 4.8 >= 3.2, phone motionless stdG 0.04 <= 0.09)
        engine.checkAccelerometer(
          const AccelBucket(tMs: t0 + 50000, peakG: 4.8, meanG: 2.2, stdG: 0.04),
        );

        expect(engine.crashDetectedInTunnel, isTrue);

        // Dead reckoning halts and reports impact stop
        final crashFix = engine.computeFix(t0 + 55000);
        expect(crashFix.isCrashStop, isTrue);
        expect(crashFix.speedKmh, equals(0.0));
        expect(crashFix.confidence, TrackingConfidence.degradedMultipath);
        expect(crashFix.statusDescription, 'Tunnel Impact Stop Detected');

        final frozenLat = crashFix.lat;
        final frozenLng = crashFix.lng;
        final frozenAlong = crashFix.alongRouteM;

        // Subsequent queries at later timestamps remain frozen at the accident site
        final laterFix = engine.computeFix(t0 + 120000);
        expect(laterFix.isCrashStop, isTrue);
        expect(laterFix.lat, equals(frozenLat));
        expect(laterFix.lng, equals(frozenLng));
        expect(laterFix.alongRouteM, equals(frozenAlong));
        expect(laterFix.speedKmh, equals(0.0));
      });

      test('Max coasting duration timeout after 720 seconds transitions confidence to lost', () {
        final engine = DeadReckoningEngine(plannedRoute: atalTunnelPolyline);

        engine.startCoasting(
          lat: 32.3639,
          lng: 77.1462,
          speedKmh: 60.0,
          heading: 10.0,
          timestampMs: t0,
        );

        // Check at 719 seconds: still coasting
        final fix719s = engine.computeFix(t0 + 719000);
        expect(fix719s.hasTimedOut, isFalse);
        expect(fix719s.isCoasting, isTrue);

        // Check at 720+ seconds: timeout reached
        final fix721s = engine.computeFix(t0 + 721000);
        expect(fix721s.hasTimedOut, isTrue);
        expect(fix721s.isCoasting, isFalse);
        expect(fix721s.confidence, TrackingConfidence.lost);
        expect(fix721s.statusDescription, 'Tunnel Signal Lost');
        expect(fix721s.speedKmh, equals(0.0));
      });
    });

  });
}
