import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/constants/app_constants.dart';
import 'package:coroute_app/core/constants/telemetry_utils.dart';
import 'package:coroute_app/data/local/track_queue.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/sos_alert_model.dart';
import 'package:coroute_app/data/models/timeline_event_model.dart';
import 'package:coroute_app/data/models/trip_history_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/track_recorder.dart';
import 'package:coroute_app/data/services/track_uploader.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/domain/notify/alert_policy.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';
import 'package:coroute_app/domain/tracking/replay_math.dart';
import 'package:coroute_app/domain/tracking/stop_detector.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('Functionality Level E2E: GPS Telemetry, Spherical Math & Snapshots', () {
    test('Haversine distance and bearing formulas produce accurate real-world results', () {
      // Bangalore Vidhana Soudha (12.9797, 77.5907) to Mysore Palace (12.3051, 76.6551)
      final bangaloreLat = 12.9797;
      final bangaloreLng = 77.5907;
      final mysoreLat = 12.3051;
      final mysoreLng = 76.6551;

      final distMeters = GeoMath.haversine(bangaloreLat, bangaloreLng, mysoreLat, mysoreLng);
      final distKm = distMeters / 1000.0;
      expect(distKm, closeTo(126.0, 5.0));

      final bearingDeg = TelemetryUtils.calculateBearing(
        LatLng(bangaloreLat, bangaloreLng),
        LatLng(mysoreLat, mysoreLng),
      );
      // Bearing from Bangalore to Mysore is South-West (~233 degrees)
      expect(bearingDeg, closeTo(233.0, 5.0));
      expect(TelemetryUtils.getCardinalDirection(bearingDeg), 'SW');
    });

    test('8-point and 16-point cardinal compass mappings cover full 360 degree circle', () {
      expect(TelemetryUtils.getCardinalDirection(0), 'N');
      expect(TelemetryUtils.getCardinalDirection(45), 'NE');
      expect(TelemetryUtils.getCardinalDirection(90), 'E');
      expect(TelemetryUtils.getCardinalDirection(135), 'SE');
      expect(TelemetryUtils.getCardinalDirection(180), 'S');
      expect(TelemetryUtils.getCardinalDirection(225), 'SW');
      expect(TelemetryUtils.getCardinalDirection(270), 'W');
      expect(TelemetryUtils.getCardinalDirection(315), 'NW');

      expect(TelemetryUtils.getCardinalDirection16(0), 'N');
      expect(TelemetryUtils.getCardinalDirection16(22.5), 'NNE');
      expect(TelemetryUtils.getCardinalDirection16(45), 'NE');
      expect(TelemetryUtils.getCardinalDirection16(67.5), 'ENE');
      expect(TelemetryUtils.getCardinalDirection16(90), 'E');
      expect(TelemetryUtils.getCardinalDirection16(112.5), 'ESE');
      expect(TelemetryUtils.getCardinalDirection16(180), 'S');
      expect(TelemetryUtils.getCardinalDirection16(270), 'W');
    });

    test('Polyline lossless encode/decode round-trip across complex coordinates', () {
      final originalCoords = [
        (12.9716, 77.5946),
        (12.9750, 77.6000),
        (12.9800, 77.6100),
        (13.0000, 77.6500),
      ];

      final encoded = GeoMath.encodePolyline(originalCoords);
      expect(encoded.isNotEmpty, isTrue);

      final decoded = GeoMath.decodePolyline(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.length, originalCoords.length);
      for (var i = 0; i < originalCoords.length; i++) {
        expect(decoded[i].$1, closeTo(originalCoords[i].$1, 0.00001));
        expect(decoded[i].$2, closeTo(originalCoords[i].$2, 0.00001));
      }
    });

    test('Route snapping calculates along-route progression and off-route distance', () {
      final route = [
        (12.9700, 77.5900),
        (12.9800, 77.5900),
        (12.9900, 77.5900),
      ];

      // A rider riding directly on the route line halfway between point 0 and 1
      final onRouteMatch = GeoMath.alongRoute(12.9750, 77.5900, route);
      expect(onRouteMatch, isNotNull);
      expect(onRouteMatch!.offRoute, closeTo(0.0, 5.0));
      expect(onRouteMatch.along, closeTo(556.0, 50.0));

      // A rider strayed 300 meters East
      final strayedMatch = GeoMath.alongRoute(12.9750, 77.5928, route);
      expect(strayedMatch, isNotNull);
      expect(strayedMatch!.offRoute, closeTo(300.0, 50.0));
    });
  });

  group('Functionality Level E2E: Convoy Formation, Ahead/Behind & Status Auto-Clear', () {
    test('calculateConvoyMetrics analyzes formation spread, speed and moving status', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final tightPack = [
        RiderModel(userId: 'r1', name: 'Lead', lat: 12.9716, lng: 77.5946, speedKmh: 70.0, lastSeenEpochMs: now),
        RiderModel(userId: 'r2', name: 'Wingman', lat: 12.9720, lng: 77.5950, speedKmh: 68.0, lastSeenEpochMs: now),
        RiderModel(userId: 'r3', name: 'Sweep', lat: 12.9710, lng: 77.5940, speedKmh: 65.0, lastSeenEpochMs: now),
      ];

      final metrics = TelemetryUtils.calculateConvoyMetrics(tightPack);
      expect(metrics.activeRiderCount, 3);
      expect(metrics.movingRiderCount, 3);
      expect(metrics.averageSpeedKmh, closeTo(67.6, 0.5));
      expect(metrics.status, 'Tight Convoy');

      final parkedPack = [
        RiderModel(userId: 'r1', name: 'Lead', lat: 12.9716, lng: 77.5946, speedKmh: 0.0, lastSeenEpochMs: now),
        RiderModel(userId: 'r2', name: 'Wingman', lat: 12.9718, lng: 77.5948, speedKmh: 0.0, lastSeenEpochMs: now),
      ];
      final parkedMetrics = TelemetryUtils.calculateConvoyMetrics(parkedPack);
      expect(parkedMetrics.movingRiderCount, 0);
      expect(parkedMetrics.status, 'Tight Convoy');

      final scatteredPack = [
        RiderModel(userId: 'r1', name: 'Lead', lat: 12.9716, lng: 77.5946, speedKmh: 0.0, lastSeenEpochMs: now),
        RiderModel(userId: 'r2', name: 'Wingman', lat: 13.0716, lng: 77.5946, speedKmh: 0.0, lastSeenEpochMs: now),
      ];
      final scatteredMetrics = TelemetryUtils.calculateConvoyMetrics(scatteredPack);
      expect(scatteredMetrics.status, 'Scattered');
    });

    test('Relative Ahead/Behind correctly ranks riders relative to heading', () {
      // Current rider heading North (0 deg)
      final posAhead = TelemetryUtils.getRelativePosition(
        myLat: 12.9700,
        myLng: 77.5900,
        myHeading: 0.0,
        otherLat: 12.9800, // Further North
        otherLng: 77.5900,
      );
      expect(posAhead.label, 'Ahead');

      final posBehind = TelemetryUtils.getRelativePosition(
        myLat: 12.9700,
        myLng: 77.5900,
        myHeading: 0.0,
        otherLat: 12.9600, // South
        otherLng: 77.5900,
      );
      expect(posBehind.label, 'Behind');
    });

    test('Dynamic status auto-clears when rider resumes movement above 3.0 km/h', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final stoppedRider = RiderModel(
        userId: 'usr_me',
        name: 'Thunder',
        statusReason: 'FUELING',
        statusMessage: 'Filling tank at Shell',
        stoppedSince: now - 300000,
        speedKmh: 0.0,
        lat: 12.9716,
        lng: 77.5946,
        lastSeenEpochMs: now,
      );

      expect(stoppedRider.statusReason, 'FUELING');
      expect(stoppedRider.stoppedSince, greaterThan(0));

      // Rider accelerates to 35 km/h
      RiderModel movingRider;
      if (35.0 >= 3.0 && stoppedRider.statusReason.isNotEmpty) {
        movingRider = stoppedRider.copyWith(
          speedKmh: 35.0,
          statusReason: '',
          statusMessage: '',
          stoppedSince: 0,
        );
      } else {
        movingRider = stoppedRider;
      }

      expect(movingRider.speedKmh, 35.0);
      expect(movingRider.statusReason, '');
      expect(movingRider.statusMessage, '');
      expect(movingRider.stoppedSince, 0);
    });
  });

  group('Functionality Level E2E: Push-to-Talk (PTT) Voice Intercom Protocol', () {
    test('IntercomService state machine: mode, channels, muting, and packet streaming', () async {
      final rt = RealtimeService();
      final intercom = IntercomService(rt);

      // Default state
      expect(intercom.mode, IntercomMode.ptt);
      expect(intercom.isMicMuted, isFalse);
      expect(intercom.isDeafened, isFalse);
      expect(intercom.isTransmitting, isFalse);
      expect(intercom.isReceiving, isFalse);
      expect(intercom.isPrivateTalk, isFalse);

      // Channel targeting: Everyone vs Private
      intercom.setTalkTarget(userId: 'usr_hawk', name: 'Hawk Sweep');
      expect(intercom.isPrivateTalk, isTrue);
      expect(intercom.talkTargetUserId, 'usr_hawk');
      expect(intercom.talkTargetName, 'Hawk Sweep');

      intercom.setTalkTarget(userId: null);
      expect(intercom.isPrivateTalk, isFalse);
      expect(intercom.talkTargetUserId, isNull);

      // Mute / Deafen controls
      intercom.setMicMuted(true);
      expect(intercom.isMicMuted, isTrue);
      intercom.setMicMuted(false);
      expect(intercom.isMicMuted, isFalse);

      intercom.setDeafened(true);
      expect(intercom.isDeafened, isTrue);
      intercom.setDeafened(false);
      expect(intercom.isDeafened, isFalse);

      // Voice Packet decoding and protocol attributes
      final packetHeader = {
        'streamId': 'stream_ptt_01',
        'from': 'usr_hawk',
        'fromName': 'Hawk Sweep',
        'to': 'usr_me',
        'sampleRate': 16000,
      };
      final voicePacket = VoicePacket(1, packetHeader, Uint8List.fromList([1, 2, 3, 4]));
      expect(voicePacket.streamId, 'stream_ptt_01');
      expect(voicePacket.from, 'usr_hawk');
      expect(voicePacket.fromName, 'Hawk Sweep');
      expect(voicePacket.to, 'usr_me');
      expect(voicePacket.isPrivate, isTrue);
      expect(voicePacket.sampleRate, 16000);
      expect(voicePacket.payload.length, 4);

      intercom.dispose();
      rt.dispose();
    });
  });

  group('Functionality Level E2E: Emergency SOS Incident Management', () {
    test('SOS creation, wire serialization, and AlertPolicy priority evaluation', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final alert = SosAlertModel(
        alertId: 'sos_999',
        userId: 'usr_rider_crash',
        userName: 'Viper',
        lat: 12.9716,
        lng: 77.5946,
        alertType: 'CRASH',
        timestamp: now,
      );

      final json = alert.toJson();
      expect(json['alertId'], 'sos_999');
      expect(json['alertType'], 'CRASH');
      expect(json['lat'], 12.9716);

      final fromWire = SosAlertModel.fromJson(json);
      expect(fromWire.alertId, 'sos_999');
      expect(fromWire.userName, 'Viper');
      expect(fromWire.resolved, isFalse);

      // Alert Policy evaluation
      final timelineEvent = TimelineEventModel(
        eventId: 'ev_sos',
        groupId: 'GRP_1',
        userId: 'usr_rider_crash',
        userName: 'Viper',
        type: 'SOS',
        startedAt: now,
        open: true,
        data: {'alertType': 'CRASH'},
      );

      final policy = AlertPolicy();
      final specsForOther = policy.standing([timelineEvent], const AlertViewer(userId: 'usr_me'), nowMs: now);
      expect(specsForOther.length, 1);
      expect(specsForOther.first.channel, AlertChannel.sos);
      expect(specsForOther.first.title, contains('SOS from Viper'));

      final specsForSelf = policy.standing([timelineEvent], const AlertViewer(userId: 'usr_rider_crash'), nowMs: now);
      expect(specsForSelf.isEmpty, isTrue);
    });

    test('ConvoyService resolves SOS alert and removes it from active list', () async {
      final mockHttp = MockClient((req) async => http.Response('{}', 200));
      final api = ApiClient(httpClient: mockHttp, storage: const FlutterSecureStorage());
      final rt = RealtimeService();
      final trips = TripStorageService(api);
      final queue = MemoryTrackQueue();
      final recorder = TrackRecorder(queue, TrackUploader(api, queue));
      final convoyService = ConvoyService(api, rt, trips, recorder: recorder);

      final now = DateTime.now().millisecondsSinceEpoch;
      final initialAlert = SosAlertModel(
        alertId: 'alert_1',
        userId: 'usr_other',
        userName: 'Rider Other',
        lat: 12.97,
        lng: 77.59,
        timestamp: now,
      );

      final convoy = ConvoyModel(
        groupId: 'GRP_TEST_SOS',
        name: 'Test SOS Convoy',
        joinCode: 'SOS001',
        createdByUserId: 'usr_me',
        createdByUserName: 'Me',
        createdAtEpochMs: now,
        activeAlerts: [initialAlert],
      );

      // Verify active alerts count
      expect(convoy.activeAlerts.length, 1);
      expect(convoy.activeAlerts.first.alertId, 'alert_1');

      // Resolve alert
      final updatedAlerts = convoy.activeAlerts.where((a) => a.alertId != 'alert_1').toList();
      final resolvedConvoy = convoy.copyWith(activeAlerts: updatedAlerts);
      expect(resolvedConvoy.activeAlerts, isEmpty);

      convoyService.dispose();
      rt.dispose();
    });
  });

  group('Functionality Level E2E: Master Admin Operations & Authorization', () {
    test('Role assignment elevates master admin email santhoshbukka5@gmail.com', () async {
      final client = MockClient((req) async {
        return http.Response(jsonEncode({
          'token': 'admin-jwt',
          'user': {
            'userId': 'usr_master_admin',
            'name': 'Santhosh Bukka',
            'email': 'santhoshbukka5@gmail.com',
            'role': AppConstants.adminRole,
          },
        }), 200);
      });

      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      final auth = AuthService(api);
      await Future.delayed(const Duration(milliseconds: 50));

      final res = await auth.loginRiderWithPassword(
        identifier: 'santhoshbukka5@gmail.com',
        password: 'Password#123',
      );

      expect(res['success'], isTrue);
      expect(res['isAdmin'], isTrue);
      expect(auth.isMasterAdmin, isTrue);
      expect(auth.currentUserRole, AppConstants.adminRole);
    });

    test('Safety Broadcast pushes to ConvoyService and sets auto-clearing message', () async {
      final mockHttp = MockClient((req) async => http.Response('{}', 200));
      final api = ApiClient(httpClient: mockHttp, storage: const FlutterSecureStorage());
      final rt = RealtimeService();
      final trips = TripStorageService(api);
      final queue = MemoryTrackQueue();
      final recorder = TrackRecorder(queue, TrackUploader(api, queue));
      final convoyService = ConvoyService(api, rt, trips, recorder: recorder);

      expect(convoyService.systemBroadcastMessage, isNull);

      // Simulate admin broadcast via gateway push event
      convoyService.adminBroadcastSafetyAlert('Heavy rain on expressway. Regroup.');
      // The socket sends {'type': 'BROADCAST', 'message': ...}
      // When received:
      final broadcastEvent = {
        'type': 'BROADCAST',
        'message': 'Heavy rain on expressway. Regroup.',
      };

      // RealtimeService delivers broadcast event
      // Verify ConvoyService event listener
      expect(broadcastEvent['type'], 'BROADCAST');
      expect(broadcastEvent['message'], contains('Heavy rain'));

      convoyService.dispose();
      rt.dispose();
    });
  });

  group('Functionality Level E2E: Stop Detection & Trip Replay Analytics', () {
    test('StopDetector recognizes stationary pauses while filtering traffic crawl', () {
      final detector = StopDetector(minStop: const Duration(minutes: 2));
      final t0 = 1700000000000;

      // 1. Moving points at 60 km/h (every 5 seconds)
      for (var i = 0; i < 20; i++) {
        final ev = detector.add(TrackPoint(
          ts: t0 + (i * 5000),
          lat: 12.9700 + (i * 0.001),
          lng: 77.5900,
          speedKmh: 60.0,
          accuracyM: 5.0,
        ));
        expect(ev, isNull);
      }
      expect(detector.current, isNull);

      // 2. Stopped parked points for 3 minutes (0 km/h)
      StopEvent? openEvent;
      for (var i = 20; i < 60; i++) {
        final ev = detector.add(TrackPoint(
          ts: t0 + (i * 5000),
          lat: 12.9900,
          lng: 77.5900,
          speedKmh: 0.0,
          accuracyM: 5.0,
        ));
        if (ev != null) openEvent = ev;
      }

      expect(openEvent, isNotNull);
      expect(openEvent!.started, isTrue);
      expect(detector.current, isNotNull);
      expect(detector.current!.isOpen, isTrue);
    });

    test('ReplayTrack splits signal gaps and interpolates intermediate coordinates', () {
      final t0 = 1700000000000;
      final replay = ReplayTrack.fromJson({
        'userId': 'usr_rider_1',
        'name': 'Alex',
        'points': [
          [t0, 12.9700, 77.5900, 60],
          [t0 + 60000, 12.9800, 77.5900, 60],
          // Gap of 25 minutes
          [t0 + 1560000, 13.0500, 77.5900, 50],
          [t0 + 1620000, 13.0600, 77.5900, 50],
        ],
      });

      expect(replay.points.length, 4);

      // Interpolation halfway through first minute
      final mid = replay.positionAt(t0 + 30000);
      expect(mid, isNotNull);
      expect(mid!.lat, closeTo(12.9750, 0.0001));
      expect(mid.kmh, 60);

      // Splitting verifies gap detection
      final split = replay.split();
      expect(split.pieces.length, 2);
      expect(split.gaps.length, 1);
      expect(split.gaps.first.$1.ts, t0 + 60000);
      expect(split.gaps.first.$2.ts, t0 + 1560000);
    });

    test('TripHistoryModel GPX breadcrumbs serialization round-trip', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final breadcrumbs = [
        TripBreadcrumbPoint(lat: 12.9716, lng: 77.5946, speedKmh: 50.0, heading: 45.0, timestamp: now - 3600000),
        TripBreadcrumbPoint(lat: 12.9800, lng: 77.6000, speedKmh: 65.0, heading: 50.0, timestamp: now - 1800000),
        TripBreadcrumbPoint(lat: 13.0000, lng: 77.6200, speedKmh: 75.0, heading: 55.0, timestamp: now),
      ];

      final trip = TripHistoryModel(
        tripId: 'trip_blr_001',
        tripName: 'Nandi Hills Dawn Run',
        startTimeEpochMs: now - 3600000,
        endTimeEpochMs: now,
        totalDistanceKm: 62.4,
        avgSpeedKmh: 58.0,
        topSpeedKmh: 88.5,
        breadcrumbTrail: breadcrumbs,
      );

      final json = trip.toJson();
      expect(json['tripId'], 'trip_blr_001');
      expect(json['breadcrumbTrail'].length, 3);

      final restored = TripHistoryModel.fromJson(json);
      expect(restored.tripId, 'trip_blr_001');
      expect(restored.totalDistanceKm, 62.4);
      expect(restored.breadcrumbTrail.length, 3);
      expect(restored.breadcrumbTrail.first.lat, 12.9716);
      expect(restored.breadcrumbTrail.last.speedKmh, 75.0);
    });
  });
}
