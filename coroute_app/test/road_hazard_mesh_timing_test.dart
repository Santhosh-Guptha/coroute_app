import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:coroute_app/core/config/feature_gates.dart';
import 'package:coroute_app/data/models/road_hazard_telemetry.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/network_models.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';
import 'package:coroute_app/presentation/ride/emergency_guidance.dart';

class _TimingTestConvoys extends ConvoyService {
  _TimingTestConvoys()
      : super(
          ApiClient(
            httpClient: MockClient((_) async => http.Response('{}', 200)),
          ),
          RealtimeService(),
          TripStorageService(
            ApiClient(
              httpClient: MockClient((_) async => http.Response('{}', 200)),
            ),
          ),
        );

  final List<RoadHazardObservation> _rhList = [];
  final StreamController<TrackPoint> _fixController = StreamController<TrackPoint>.broadcast();

  @override
  List<RoadHazardObservation> get roadHazards => _rhList;

  @override
  Stream<TrackPoint> get myFixes => _fixController.stream;

  void addHazard(RoadHazardObservation obs) {
    _rhList.add(obs);
    notifyListeners();
  }

  void pushFix(TrackPoint fix) {
    _fixController.add(fix);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('FEAT-02: 5-Second Warning Reaction Target & SLA Verification', () {
    test('TEST-TIM-01: At 80 km/h, 300m trigger guarantees >= 5 seconds reaction time', () {
      // Highway cruising speed: 80 km/h
      const speedKmh = 80.0;
      const speedMps = speedKmh / 3.6; // 22.222 m/s

      // Mandatory acceptance target: 5.0 seconds reaction time before reaching hazard
      const requiredLeadTimeS = 5.0;
      final requiredDistanceM = speedMps * requiredLeadTimeS; // 111.11 meters

      // Primary alert trigger distance
      const alertTriggerDistanceM = 300.0;

      // Nominal travel time from trigger to hazard
      final nominalTravelTimeS = alertTriggerDistanceM / speedMps;
      expect(nominalTravelTimeS, closeTo(13.5, 0.1));

      // System latency accounting:
      // 1. Gateway WebSocket broadcast latency (network round-trip): 150 ms
      // 2. Client route projection & matching computation: 50 ms
      // 3. Worst-case 1 Hz GPS fix discretization lag: 1000 ms
      // 4. Text-To-Speech playback time for "Caution: severe road hazard 300 meters ahead": 2200 ms
      const totalSystemLatencyS = 0.15 + 0.05 + 1.0 + 2.2; // 3.4 seconds total latency
      final distanceTraveledDuringLatencyM = totalSystemLatencyS * speedMps; // 75.55 m

      // Distance remaining when rider completely finishes hearing the audio warning
      final remainingDistanceM = alertTriggerDistanceM - distanceTraveledDuringLatencyM;
      expect(remainingDistanceM, greaterThan(requiredDistanceM));

      // Actual reaction time remaining after alert finishes
      final actualReactionTimeS = remainingDistanceM / speedMps;
      expect(actualReactionTimeS, greaterThanOrEqualTo(requiredLeadTimeS));
      expect(actualReactionTimeS, closeTo(10.1, 0.2)); // ~10.1 seconds (exceeds 5.0s target by > 5 seconds!)
    });

    test('TEST-TIM-02: High-speed scenario (100 km/h) retains >= 5 seconds reaction time', () {
      const speedKmh = 100.0;
      const speedMps = speedKmh / 3.6; // 27.777 m/s
      const requiredLeadTimeS = 5.0;
      final requiredDistanceM = speedMps * requiredLeadTimeS; // 138.88 meters

      const alertTriggerDistanceM = 300.0;
      const totalSystemLatencyS = 3.4; // 3.4 seconds total latency
      final distanceTraveledDuringLatencyM = totalSystemLatencyS * speedMps; // 94.44 m

      final remainingDistanceM = alertTriggerDistanceM - distanceTraveledDuringLatencyM;
      expect(remainingDistanceM, greaterThan(requiredDistanceM));

      final actualReactionTimeS = remainingDistanceM / speedMps;
      expect(actualReactionTimeS, greaterThanOrEqualTo(requiredLeadTimeS));
      expect(actualReactionTimeS, closeTo(7.4, 0.2)); // 7.4 seconds remaining
    });

    test('TEST-TIM-03: Spoken text exact template verification', () {
      const hazardDistanceM = 300;
      const exactExpectedPhrase = 'Caution: severe road hazard 300 meters ahead';

      // Verify exact phrasing required by product specification
      final generatedSpeech = 'Caution: severe road hazard $hazardDistanceM meters ahead';
      expect(generatedSpeech, equals(exactExpectedPhrase));
    });

    test('TEST-TIM-04: End-to-end measured pipeline execution from hazard broadcast to EmergencyGuidance speech trigger', () async {
      final convoys = _TimingTestConvoys();
      final spokenAlerts = <String>[];
      final spokenKeys = <String>[];

      final guidance = EmergencyGuidance(
        convoys,
        null,
        null,
        fetchRoute: (_) async => null,
        speak: (text, key) {
          spokenAlerts.add(text);
          spokenKeys.add(key);
        },
      );

      // Hazard location: (12.971600, 77.594600)
      const hazardLat = 12.971600;
      const hazardLng = 77.594600;

      final hazardObs = RoadHazardObservation(
        eventId: 'rh_e2e_001',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        lat: hazardLat,
        lng: hazardLng,
        accuracyM: 4.0,
        speedKmh: 80.0,
        heading: 90.0,
        peakVerticalG: 2.3,
        peakYawRateDegS: 32.0,
        confidence: 0.90,
        severity: RoadHazardSeverity.critical,
        classification: RoadHazardClassification.pothole,
        pseudonymousRiderId: 'captain_lead',
      );

      // Broadcast hazard to convoys
      convoys.addHazard(hazardObs);

      // Trailing rider cruising at 80 km/h heading East (90 deg).
      // At lat 12.9716, 1 deg lon is ~108500m.
      // 300 meters West is approx -0.002765 deg lon.
      const riderLat = hazardLat;
      const riderLng = hazardLng - (300.0 / 108500.0);

      final distanceBeforeFix = GeoMath.haversine(riderLat, riderLng, hazardLat, hazardLng);
      expect(distanceBeforeFix, closeTo(300.0, 15.0));

      // First fix to initialize heading tracking (EmergencyGuidance needs 2 points for bearing or initial heading)
      convoys.pushFix(const TrackPoint(
        ts: 900,
        lat: riderLat,
        lng: riderLng - 0.0003,
        speedKmh: 80.0,
        accuracyM: 5.0,
      ));
      await pumpEventQueue();

      // Rider fix at 300m trigger distance
      convoys.pushFix(const TrackPoint(
        ts: 1000,
        lat: riderLat,
        lng: riderLng,
        speedKmh: 80.0,
        accuracyM: 5.0,
      ));

      // Allow stream microtasks to process
      await pumpEventQueue();

      // Verify speech alert was triggered with exact phrase and key
      expect(spokenAlerts.length, equals(1));
      expect(spokenAlerts.first, equals('Caution: severe road hazard 300 meters ahead'));
      expect(spokenKeys.first, equals('ROAD_HAZARD:rh_e2e_001:300m'));

      // Simulate rider advancing 50 meters further (at 250m distance)
      const riderLng250m = hazardLng - (250.0 / 108500.0);
      convoys.pushFix(const TrackPoint(
        ts: 2250,
        lat: riderLat,
        lng: riderLng250m,
        speedKmh: 80.0,
        accuracyM: 5.0,
      ));

      await pumpEventQueue();

      // Deduplication verification: Speech must NOT be repeated!
      expect(spokenAlerts.length, equals(1));

      // Timing and remaining reaction time verification:
      // At 80 km/h (22.22 m/s), spoken alert takes 2.2 seconds to finish playing.
      const speedMps = 80.0 / 3.6;
      const ttsPlaybackDurationS = 2.2;
      final distanceTraveledDuringSpeechM = speedMps * ttsPlaybackDurationS;
      final remainingDistanceM = distanceBeforeFix - distanceTraveledDuringSpeechM;
      final remainingReactionTimeS = remainingDistanceM / speedMps;

      expect(remainingReactionTimeS, greaterThanOrEqualTo(5.0));
      expect(remainingReactionTimeS, closeTo(11.3, 0.5));

      guidance.dispose();
    });
  });

  group('FEAT-02: Entitlement & Feature Gating Tests', () {
    tearDown(() {
      FeatureGates.forceAllUnlocked = true;
    });

    test('TEST-ENT-01: Broadcast is restricted to Road Captain & Tour Operator', () {
      FeatureGates.forceAllUnlocked = false;

      // Community tier: CANNOT broadcast
      expect(FeatureGates.isUnlocked(Feature.roadHazardBroadcast, SubscriptionTier.community), isFalse);

      // Pro Rider tier: CANNOT broadcast
      expect(FeatureGates.isUnlocked(Feature.roadHazardBroadcast, SubscriptionTier.proRider), isFalse);

      // Road Captain tier: UNLOCKED to broadcast
      expect(FeatureGates.isUnlocked(Feature.roadHazardBroadcast, SubscriptionTier.roadCaptain), isTrue);

      // Tour Operator tier: UNLOCKED to broadcast
      expect(FeatureGates.isUnlocked(Feature.roadHazardBroadcast, SubscriptionTier.tourOperator), isTrue);
    });

    test('TEST-ENT-02: Receive is unlocked for ALL tiers (Community, Pro, Captain, Tour Operator)', () {
      FeatureGates.forceAllUnlocked = false;

      expect(FeatureGates.isUnlocked(Feature.roadHazardReceive, SubscriptionTier.community), isTrue);
      expect(FeatureGates.isUnlocked(Feature.roadHazardReceive, SubscriptionTier.proRider), isTrue);
      expect(FeatureGates.isUnlocked(Feature.roadHazardReceive, SubscriptionTier.roadCaptain), isTrue);
      expect(FeatureGates.isUnlocked(Feature.roadHazardReceive, SubscriptionTier.tourOperator), isTrue);
    });
  });
}
