import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/tracking/dead_reckoning_engine.dart';

void main() {
  group('Enhanced IMU Dead Reckoning & Tunnel Zero-GPS Motion Estimator Tests', () {
    const double atalEntryLat = 32.3639;
    const double atalEntryLng = 77.1462;
    const double atalExitLat = 32.4411;
    const double atalExitLng = 77.1594;

    final routePolyline = [
      (atalEntryLat, atalEntryLng),
      (32.3800, 77.1500),
      (32.4000, 77.1550),
      (atalExitLat, atalExitLng),
    ];

    test('Detects proximity to known Indian touring tunnels', () {
      expect(DeadReckoningEngine.isNearTunnelPortal(atalEntryLat, atalEntryLng), isTrue);
      expect(DeadReckoningEngine.isNearTunnelPortal(atalExitLat, atalExitLng), isTrue);

      // 50 km away
      expect(DeadReckoningEngine.isNearTunnelPortal(32.0, 76.5), isFalse);

      final portal = DeadReckoningEngine.findNearbyTunnel(atalEntryLat, atalEntryLng);
      expect(portal, isNotNull);
      expect(portal!.name, contains('Atal Tunnel'));
    });

    test('Initiates coasting and projects position along route polyline', () {
      final engine = DeadReckoningEngine(plannedRoute: routePolyline);
      const startMs = 1700000000000;

      engine.startCoasting(
        lat: atalEntryLat,
        lng: atalEntryLng,
        speedKmh: 60.0,
        heading: 10.0,
        timestampMs: startMs,
      );

      expect(engine.isCoasting, isTrue);

      // Check projection at 60 seconds
      final fix60 = engine.computeFix(startMs + 60000);
      expect(fix60.isCoasting, isTrue);
      expect(fix60.confidence, equals(TrackingConfidence.tunnelCoasting));
      expect(fix60.speedKmh, greaterThan(45.0)); // still cruising
      expect(fix60.alongRouteM, greaterThan(0.0));
      expect(fix60.isCrashStop, isFalse);
    });

    test('Analyzes motorcycle engine vibration signature vs stall/unpowered roll', () {
      final engine = DeadReckoningEngine(plannedRoute: routePolyline);
      const startMs = 1700000000000;

      engine.startCoasting(
        lat: atalEntryLat,
        lng: atalEntryLng,
        speedKmh: 60.0,
        heading: 10.0,
        timestampMs: startMs,
      );

      expect(engine.isEngineRunning, isTrue);

      // Ingest structural engine vibration buckets (single-cylinder / twin engine hum)
      // stdG: 0.18, meanG: 1.02
      engine.checkAccelerometer(const AccelBucket(
        tMs: startMs + 1000,
        peakG: 1.45,
        meanG: 1.02,
        stdG: 0.18,
      ));

      expect(engine.isEngineRunning, isTrue);

      // Ingest sustained silence / zero vibration (engine stalled or bike cut off)
      for (int i = 0; i < 5; i++) {
        engine.checkAccelerometer(AccelBucket(
          tMs: startMs + 2000 + (i * 1000),
          peakG: 1.01,
          meanG: 1.0,
          stdG: 0.02,
        ));
      }

      expect(engine.isEngineRunning, isFalse);
    });

    test('Detects severe tunnel impact (> 4.0G) and freezes coordinate at crash location', () {
      final engine = DeadReckoningEngine(plannedRoute: routePolyline);
      const startMs = 1700000000000;

      engine.startCoasting(
        lat: atalEntryLat,
        lng: atalEntryLng,
        speedKmh: 70.0,
        heading: 15.0,
        timestampMs: startMs,
      );

      // Severe tunnel crash impact
      engine.checkAccelerometer(const AccelBucket(
        tMs: startMs + 5000,
        peakG: 4.8, // severe crash impact
        meanG: 1.0,
        stdG: 0.04, // stationary rest on road
      ));

      expect(engine.crashDetectedInTunnel, isTrue);

      final crashFix = engine.computeFix(startMs + 10000);
      expect(crashFix.isCrashStop, isTrue);
      expect(crashFix.speedKmh, equals(0.0));
      expect(crashFix.confidence, equals(TrackingConfidence.degradedMultipath));
      expect(crashFix.statusDescription, contains('Impact Stop'));
    });

    test('isVehicularMoving suppresses false Rider Stopped alerts while coasting', () {
      final engine = DeadReckoningEngine(plannedRoute: routePolyline);
      const startMs = 1700000000000;

      engine.startCoasting(
        lat: atalEntryLat,
        lng: atalEntryLng,
        speedKmh: 65.0,
        heading: 10.0,
        timestampMs: startMs,
      );

      // Moving through tunnel at 30 seconds
      expect(engine.isVehicularMoving(startMs + 30000), isTrue);

      // Crashed
      engine.checkAccelerometer(const AccelBucket(
        tMs: startMs + 35000,
        peakG: 5.2,
        meanG: 1.0,
        stdG: 0.03,
      ));

      expect(engine.isVehicularMoving(startMs + 40000), isFalse);
    });

    test('convergeToGps smoothly blends coasted coordinate towards recovered GPS fix', () {
      const coastedLat = 32.4400;
      const coastedLng = 77.1580;
      const trueGpsLat = 32.4411;
      const trueGpsLng = 77.1594;

      // Blend at 30% factor
      final blend1 = DeadReckoningEngine.convergeToGps(
        coastedLat: coastedLat,
        coastedLng: coastedLng,
        gpsLat: trueGpsLat,
        gpsLng: trueGpsLng,
        blendFactor: 0.3,
        gpsSpeedKmh: 58.0,
        gpsHeading: 12.0,
      );

      expect(blend1.isCompleted, isFalse);
      expect(blend1.lat, greaterThan(coastedLat));
      expect(blend1.lat, lessThan(trueGpsLat));

      // Final convergence (100% factor or close proximity)
      final blendDone = DeadReckoningEngine.convergeToGps(
        coastedLat: coastedLat,
        coastedLng: coastedLng,
        gpsLat: trueGpsLat,
        gpsLng: trueGpsLng,
        blendFactor: 1.0,
        gpsSpeedKmh: 58.0,
        gpsHeading: 12.0,
      );

      expect(blendDone.isCompleted, isTrue);
      expect(blendDone.lat, equals(trueGpsLat));
      expect(blendDone.lng, equals(trueGpsLng));
    });

    test('shouldInitiateCoasting triggers near portal or on degraded accuracy', () {
      // Normal good GPS fix
      expect(
        DeadReckoningEngine.shouldInitiateCoasting(
          fixAgeSec: 1.0,
          accuracyM: 5.0,
          lat: 32.0,
          lng: 76.0,
        ),
        isFalse,
      );

      // Near Atal Tunnel with GPS lost for 4s
      expect(
        DeadReckoningEngine.shouldInitiateCoasting(
          fixAgeSec: 4.0,
          accuracyM: 90.0,
          lat: atalEntryLat,
          lng: atalEntryLng,
          speedKmh: 50.0,
        ),
        isTrue,
      );
    });
  });
}
