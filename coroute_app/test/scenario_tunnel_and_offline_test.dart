import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/data/local/emergency_corridor_store.dart';
import 'package:coroute_app/data/local/ice_profile_store.dart';
import 'package:coroute_app/data/models/ice_profile.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/domain/route/lost_rider_recovery_coordinator.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/tracking/dead_reckoning_engine.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';
import 'package:coroute_app/presentation/safety/ice_medical_card.dart';

/// Test mock of EmergencyCorridorStore providing in-memory hospital lookups.
class _TestEmergencyCorridorStore extends EmergencyCorridorStore {
  _TestEmergencyCorridorStore({this.mockPlaces = const []});

  final List<EmergencyPlace> mockPlaces;

  @override
  Future<List<NearbyEmergencyPlace>> getClosestHospitals(
    double lat,
    double lng, {
    int limit = 2,
  }) async {
    return getClosestPlaces(lat, lng, limit: limit, category: 'HOSPITAL');
  }

  @override
  Future<List<NearbyEmergencyPlace>> getClosestPlaces(
    double lat,
    double lng, {
    int limit = 5,
    String? category,
    bool? traumaOnly,
  }) async {
    final filtered = mockPlaces.where((p) {
      if (category != null && p.category != category) return false;
      if (traumaOnly == true && !p.isTraumaCenter) return false;
      return true;
    }).toList();

    final withDistances = filtered.map((place) {
      final dist = GeoMath.haversine(lat, lng, place.lat, place.lng);
      final bearing = _calcBearing(lat, lng, place.lat, place.lng);
      return NearbyEmergencyPlace(
        place: place,
        distanceMeters: dist,
        bearingDegrees: bearing,
      );
    }).toList();

    withDistances.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
    return withDistances.take(limit).toList();
  }

  @override
  Future<int> count() async => mockPlaces.length;

  static double _calcBearing(double lat1, double lng1, double lat2, double lng2) {
    return LostRiderRecoveryCoordinator.calculateBearing(lat1, lng1, lat2, lng2);
  }
}

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

    group('REQ-02: Offline Spatial Emergency Corridor Store and ICE Medical Profile', () {
      test('Serializes EmergencyPlace models and verifies high-risk mountain seed data', () {
        const place = EmergencyPlace(
          id: 'hosp_test_1',
          name: 'Keylong Trauma Centre',
          category: 'HOSPITAL',
          lat: 32.5714,
          lng: 77.0321,
          phone: '+91 1900 222225',
          routeKm: 115.0,
          isTraumaCenter: true,
        );

        final map = place.toMap();
        expect(map['id'], 'hosp_test_1');
        expect(map['is_trauma_center'], 1);

        final restored = EmergencyPlace.fromMap(map);
        expect(restored.id, place.id);
        expect(restored.name, place.name);
        expect(restored.isTraumaCenter, isTrue);
        expect(restored.phone, place.phone);

        // Default seed places cover critical remote Indian corridors
        expect(EmergencyCorridorStore.defaultSeedPlaces, isNotEmpty);
        final traumaPlaces = EmergencyCorridorStore.defaultSeedPlaces.where((p) => p.isTraumaCenter);
        expect(traumaPlaces, isNotEmpty);

        final keylong = EmergencyCorridorStore.defaultSeedPlaces.firstWhere((p) => p.id == 'hosp_keylong_dh');
        expect(keylong.name, contains('Keylong'));
        expect(keylong.isTraumaCenter, isTrue);

        final sissuPolice = EmergencyCorridorStore.defaultSeedPlaces.firstWhere((p) => p.id == 'police_sissu_post');
        expect(sissuPolice.category, 'POLICE');
        expect(sissuPolice.phone, '112');
      });

      test('Calculates NearbyEmergencyPlace distance, cardinal direction, and formatting', () {
        const place = EmergencyPlace(
          id: 'hosp_manali_ch',
          name: 'Civil Hospital Manali',
          category: 'HOSPITAL',
          lat: 32.2396,
          lng: 77.1887,
          phone: '+91 1902 252336',
          isTraumaCenter: true,
        );

        // 12.5 km away due South (180 deg)
        const nearbySouth = NearbyEmergencyPlace(
          place: place,
          distanceMeters: 12500,
          bearingDegrees: 180.0,
        );
        expect(nearbySouth.distanceKmFormatted, '12.5');
        expect(nearbySouth.bearingCardinal, 'S');
        expect(nearbySouth.directionFormatted, '12.5 km - S 180 deg');

        // Due North (0 deg)
        const nearbyNorth = NearbyEmergencyPlace(
          place: place,
          distanceMeters: 5200,
          bearingDegrees: 0.0,
        );
        expect(nearbyNorth.bearingCardinal, 'N');

        // Northeast (45 deg)
        const nearbyNE = NearbyEmergencyPlace(
          place: place,
          distanceMeters: 8000,
          bearingDegrees: 45.0,
        );
        expect(nearbyNE.bearingCardinal, 'NE');

        // West (270 deg)
        const nearbyWest = NearbyEmergencyPlace(
          place: place,
          distanceMeters: 3100,
          bearingDegrees: 270.0,
        );
        expect(nearbyWest.bearingCardinal, 'W');
      });

      test('Stores and retrieves ICE profile offline with fallback extraction', () async {
        const profile = IceProfile(
          bloodGroup: 'B+',
          allergies: 'Penicillin, NSAIDs',
          medications: 'Asthalin Inhaler',
          emergencyContactName: 'Rajesh Sharma',
          emergencyContactPhone: '+91 98765 12345',
          organDonor: true,
          insurancePolicyNumber: 'STAR-HEALTH-998877',
        );

        expect(profile.isEmpty, isFalse);

        // JSON serialization roundtrip
        final json = profile.toJson();
        final restored = IceProfile.fromJson(json);
        expect(restored.bloodGroup, 'B+');
        expect(restored.allergies, 'Penicillin, NSAIDs');
        expect(restored.organDonor, isTrue);
        expect(restored.insurancePolicyNumber, 'STAR-HEALTH-998877');

        // Save to offline storage
        final saved = await IceProfileStore.save(profile);
        expect(saved, isTrue);

        // Load back from offline storage
        final loaded = await IceProfileStore.load();
        expect(loaded.bloodGroup, 'B+');
        expect(loaded.emergencyContactName, 'Rajesh Sharma');
        expect(loaded.emergencyContactPhone, '+91 98765 12345');

        // Fallback test: when empty, extracts from legacy SharedPreferences keys
        final prefs = await SharedPreferences.getInstance();
        await prefs.clear();
        await prefs.setString('emergency_contact_name', 'Sunita Sister');
        await prefs.setString('emergency_phone', '+91 91122 33445');
        await prefs.setString('ice_blood_group', 'O+');

        final fallback = await IceProfileStore.load();
        expect(fallback.bloodGroup, 'O+');
        expect(fallback.emergencyContactName, 'Sunita Sister');
        expect(fallback.emergencyContactPhone, '+91 91122 33445');
      });

      testWidgets('Renders high-visibility IceMedicalCard with hospital references and offline contact actions', (WidgetTester tester) async {
        const profile = IceProfile(
          bloodGroup: 'O+',
          allergies: 'No known drug allergies',
          medications: 'None',
          emergencyContactName: 'Meera Rao',
          emergencyContactPhone: '+91 98765 00000',
          organDonor: true,
        );

        final testStore = _TestEmergencyCorridorStore(
          mockPlaces: const [
            EmergencyPlace(
              id: 'hosp_keylong_dh',
              name: 'District Hospital Keylong',
              category: 'HOSPITAL',
              lat: 32.5714,
              lng: 77.0321,
              phone: '+91 1900 222225',
              isTraumaCenter: true,
            ),
          ],
        );

        tester.view.physicalSize = const Size(800, 1200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: IceMedicalCard(
                  lat: 32.4411, // North portal of Atal Tunnel
                  lng: 77.1594,
                  initialProfile: profile,
                  store: testStore,
                ),
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();

        // Blood group badge rendered clearly
        expect(find.text('O+'), findsOneWidget);

        // Emergency contact name and phone displayed
        expect(find.textContaining('Meera Rao'), findsOneWidget);
        expect(find.textContaining('+91 98765 00000'), findsOneWidget);

        // Organ donor badge displayed
        expect(find.textContaining('ORGAN DONOR'), findsOneWidget);

        // Hospital reference displayed
        expect(find.textContaining('District Hospital Keylong'), findsOneWidget);

        // First-responder action buttons rendered
        expect(find.text('CALL'), findsOneWidget);
        expect(find.text('SMS'), findsOneWidget);
        expect(find.byIcon(Icons.phone_rounded), findsOneWidget);
        expect(find.byIcon(Icons.sms_rounded), findsOneWidget);
      });
    });
  });
}
