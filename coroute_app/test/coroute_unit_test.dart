import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/constants/app_constants.dart';
import 'package:coroute_app/core/constants/telemetry_utils.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/sos_alert_model.dart';
import 'package:coroute_app/data/models/trip_history_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TelemetryUtils Tests', () {
    test('Cardinal compass directions', () {
      expect(TelemetryUtils.getCardinalDirection(0), 'N');
      expect(TelemetryUtils.getCardinalDirection(45), 'NE');
      expect(TelemetryUtils.getCardinalDirection(90), 'E');
      expect(TelemetryUtils.getCardinalDirection(135), 'SE');
      expect(TelemetryUtils.getCardinalDirection(180), 'S');
      expect(TelemetryUtils.getCardinalDirection(225), 'SW');
      expect(TelemetryUtils.getCardinalDirection(270), 'W');
      expect(TelemetryUtils.getCardinalDirection(315), 'NW');
      expect(TelemetryUtils.getCardinalDirection(360), 'N');
    });

    test('16-point cardinal compass', () {
      expect(TelemetryUtils.getCardinalDirection16(0), 'N');
      expect(TelemetryUtils.getCardinalDirection16(22.5), 'NNE');
      expect(TelemetryUtils.getCardinalDirection16(45), 'NE');
      expect(TelemetryUtils.getCardinalDirection16(90), 'E');
    });

    test('Speed categories', () {
      expect(TelemetryUtils.getSpeedCategory(0.0), 'Parked');
      expect(TelemetryUtils.getSpeedCategory(15.0), 'Slow Pace');
      expect(TelemetryUtils.getSpeedCategory(45.0), 'City Cruising');
      expect(TelemetryUtils.getSpeedCategory(80.0), 'Highway Pace');
      expect(TelemetryUtils.getSpeedCategory(110.0), 'High Speed');
    });

    test('Haversine distance calculation', () {
      // Distance between Bangalore (12.9716, 77.5946) and Mysore (12.2958, 76.6394) is ~128 km
      final distMeters = TelemetryUtils.calculateDistanceMeters(
        const LatLng(12.9716, 77.5946),
        const LatLng(12.2958, 76.6394),
      );
      expect((distMeters / 1000).round(), closeTo(128, 5));
    });

    test('Convoy formation metrics', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final riders = [
        RiderModel(
          userId: 'r1',
          name: 'Lead',
          lat: 12.9716,
          lng: 77.5946,
          speedKmh: 65.0,
          lastSeenEpochMs: now,
        ),
        RiderModel(
          userId: 'r2',
          name: 'Wingman',
          lat: 12.9720,
          lng: 77.5950,
          speedKmh: 60.0,
          lastSeenEpochMs: now,
        ),
      ];

      final metrics = TelemetryUtils.calculateConvoyMetrics(riders);
      expect(metrics.activeRiderCount, 2);
      expect(metrics.movingRiderCount, 2);
      expect(metrics.averageSpeedKmh, 62.5);
      expect(metrics.status, 'Tight Convoy');
    });

    test('Relative position ahead/behind', () {
      final posAhead = TelemetryUtils.getRelativePosition(
        myLat: 12.9716,
        myLng: 77.5946,
        myHeading: 0.0, // Heading North
        otherLat: 12.9750, // Farther North
        otherLng: 77.5946,
      );
      expect(posAhead.label, 'Ahead');

      final posBehind = TelemetryUtils.getRelativePosition(
        myLat: 12.9716,
        myLng: 77.5946,
        myHeading: 0.0, // Heading North
        otherLat: 12.9650, // South of me
        otherLng: 77.5946,
      );
      expect(posBehind.label, 'Behind');
    });
  });

  group('Model Serialization Tests', () {
    test('RiderModel serialization and copyWith', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final rider = RiderModel(
        userId: 'r-101',
        name: 'Phoenix',
        vehicleType: 'Superbike',
        lat: 12.9716,
        lng: 77.5946,
        speedKmh: 75.0,
        heading: 90.0,
        batteryLevel: 88,
        lastSeenEpochMs: now,
      );

      final json = rider.toJson();
      expect(json['userId'], 'r-101');
      expect(json['name'], 'Phoenix');
      expect(json['speedKmh'], 75.0);

      final deserialized = RiderModel.fromJson(json);
      expect(deserialized.userId, 'r-101');
      expect(deserialized.name, 'Phoenix');
      expect(deserialized.speedKmh, 75.0);

      final updated = rider.copyWith(speedKmh: 90.0);
      expect(updated.speedKmh, 90.0);
      expect(updated.name, 'Phoenix');
    });

    test('SosAlertModel serialization', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final sos = SosAlertModel(
        alertId: 'sos-1',
        userId: 'r-101',
        userName: 'Phoenix',
        lat: 12.9716,
        lng: 77.5946,
        alertType: 'CRASH',
        timestamp: now,
      );

      final json = sos.toJson();
      expect(json['alertId'], 'sos-1');
      expect(json['alertType'], 'CRASH');

      final fromMap = SosAlertModel.fromJson(json);
      expect(fromMap.alertId, 'sos-1');
      expect(fromMap.userName, 'Phoenix');
      expect(fromMap.resolved, false);
    });

    test('TripHistoryModel breadcrumb serialization', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final breadcrumbs = [
        TripBreadcrumbPoint(lat: 12.9716, lng: 77.5946, speedKmh: 45.0, heading: 90.0, timestamp: now),
        TripBreadcrumbPoint(lat: 12.9720, lng: 77.5950, speedKmh: 55.0, heading: 95.0, timestamp: now + 5000),
      ];

      final trip = TripHistoryModel(
        tripId: 'trip-001',
        tripName: 'Western Ghats Expedition',
        startTimeEpochMs: now - 7200000,
        endTimeEpochMs: now,
        totalDistanceKm: 142.5,
        avgSpeedKmh: 68.2,
        topSpeedKmh: 112.0,
        breadcrumbTrail: breadcrumbs,
      );

      final json = trip.toJson();
      expect(json['tripId'], 'trip-001');
      expect(json['breadcrumbTrail'].length, 2);

      final restored = TripHistoryModel.fromJson(json);
      expect(restored.tripId, 'trip-001');
      expect(restored.totalDistanceKm, 142.5);
      expect(restored.breadcrumbTrail.length, 2);
    });
  });

  group('AuthService (gateway-backed) Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
    });

    MockClient fakeGateway({bool adminRole = false}) {
      return MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/auth/login') || path.endsWith('/auth/register') || path.endsWith('/auth/google')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (path.endsWith('/auth/login') && body['password'] != 'Password#123') {
            return http.Response(jsonEncode({'error': 'Invalid credentials.'}), 401);
          }
          return http.Response(jsonEncode({
            'token': 'jwt-token',
            'user': {
              'userId': 'usr_ghostrider',
              'name': body['name'] ?? 'GhostRider',
              'email': body['email'] ?? 'ghost@coroute.test',
              'role': adminRole ? AppConstants.adminRole : AppConstants.riderRole,
              'phone': body['phone'] ?? '+91 9876543210',
              'vehicleType': body['vehicleType'] ?? 'Adventure Bike',
              'vehicleNo': body['vehicleNo'] ?? 'KA-01-AB-1234',
              'emergencyContact': body['emergencyContact'] ?? '',
              'emergencyContactName': body['emergencyContactName'] ?? '',
            },
          }), 200);
        }
        if (path.endsWith('/me')) {
          if (request.headers['Authorization'] != 'Bearer jwt-token') {
            return http.Response(jsonEncode({'error': 'Your session has ended.', 'code': 'SESSION_INVALID'}), 401);
          }
          return http.Response(jsonEncode({'userId': 'usr_ghostrider', 'name': 'GhostRider', 'email': 'ghost@coroute.test', 'role': 'RIDER'}), 200);
        }
        return http.Response(jsonEncode({'error': 'Not found'}), 404);
      });
    }

    test('Role is taken from the server, never decided in the app', () async {
      final api = ApiClient(httpClient: fakeGateway(adminRole: true), storage: const FlutterSecureStorage());
      final auth = AuthService(api);
      await Future.delayed(const Duration(milliseconds: 50));

      final res = await auth.loginRiderWithPassword(identifier: 'admin@coroute.test', password: 'Password#123');
      expect(res['success'], true);
      expect(res['isAdmin'], true);
      expect(auth.isMasterAdmin, true);
      expect(auth.currentUserRole, AppConstants.adminRole);
      expect(api.token, 'jwt-token');
    });

    test('Wrong password is rejected and no session is created', () async {
      final api = ApiClient(httpClient: fakeGateway(), storage: const FlutterSecureStorage());
      final auth = AuthService(api);
      await Future.delayed(const Duration(milliseconds: 50));

      final res = await auth.loginRiderWithPassword(identifier: 'ghost@coroute.test', password: 'nope');
      expect(res['success'], false);
      expect(res['error'], 'Invalid credentials.');
      expect(auth.isAuthenticated, false);
      expect(api.hasToken, false);
    });

    test('Registration stores profile, logout clears everything', () async {
      final api = ApiClient(httpClient: fakeGateway(), storage: const FlutterSecureStorage());
      final auth = AuthService(api);
      await Future.delayed(const Duration(milliseconds: 50));

      final res = await auth.registerRider(
        name: 'GhostRider',
        email: 'ghost@coroute.test',
        password: 'Password#123',
        phone: '+91 9876543210',
        vehicleType: 'Adventure Bike',
        vehicleNo: 'KA-01-AB-1234',
        emergencyContact: '+91 9123456780',
        emergencyContactName: 'Captain Safe',
      );
      expect(res['success'], true);
      expect(auth.isMasterAdmin, false);
      expect(auth.isAuthenticated, true);
      expect(auth.currentUserId, 'usr_ghostrider');
      expect(auth.currentUserName, 'GhostRider');
      expect(auth.vehicleType, 'Adventure Bike');
      expect(auth.phone, '+91 9876543210');
      expect(auth.emergencyContact, '+91 9123456780');
      expect(auth.emergencyContactName, 'Captain Safe');
      expect(auth.vehicleNo, 'KA-01-AB-1234');

      await auth.logout();
      expect(auth.isAuthenticated, false);
      expect(auth.currentUserName, null);
      expect(auth.phone, null);
      expect(api.hasToken, false);
    });

    test('Expired token drops the session on 401', () async {
      final api = ApiClient(httpClient: fakeGateway(), storage: const FlutterSecureStorage());
      await api.setToken('stale-token');
      expect(() => api.get('/me'), throwsA(isA<ApiException>()));
      await Future.delayed(const Duration(milliseconds: 50));
      expect(api.hasToken, false);
    });

    test('Bad networks never sign anyone out; only the gateway saying so does', () async {
      var mode = 'portal';
      final client = MockClient((request) async {
        switch (mode) {
          case 'portal': // a Wi-Fi login page or carrier proxy answering in place of our server
            return http.Response('<html><body>Please log in to the hotspot</body></html>', 401, headers: {'content-type': 'text/html'});
          case 'outage':
            return http.Response('<html>502 Bad Gateway</html>', 502);
          case 'plain401': // a 401 without the gateway's session code (for example a wrong password)
            return http.Response(jsonEncode({'error': 'Invalid credentials.'}), 401);
          case 'refresh':
            return http.Response(jsonEncode({'userId': 'u'}), 200, headers: {'x-coroute-token': 'fresh-token'});
          default:
            return http.Response(jsonEncode({'error': 'Your session has ended.', 'code': 'SESSION_INVALID'}), 401);
        }
      });
      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      await api.setToken('good-token');
      for (final m in ['portal', 'outage', 'plain401']) {
        mode = m;
        await expectLater(api.get('/me'), throwsA(isA<ApiException>()));
        expect(api.token, 'good-token', reason: m);
      }
      mode = 'refresh';
      await api.get('/me');
      expect(api.token, 'fresh-token'); // sliding session
      mode = 'ended';
      try {
        await api.get('/me');
      } on ApiException catch (e) {
        expect(e.endsSession, true);
      }
      expect(api.hasToken, false);
    });

    test('Rider profile registration serialization test', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final fullRider = RiderModel(
        userId: 'usr_neo',
        name: 'Neo',
        vehicleType: 'Sportbike',
        lat: 13.0827,
        lng: 80.2707,
        phone: '+91 9900011223',
        emergencyContact: '+91 8800011223',
        emergencyContactName: 'Trinity',
        vehicleNo: 'TN-09-CD-5678',
        statusReason: 'FUELING',
        statusMessage: 'Shell Gas Station',
        stoppedSince: now,
        lastSeenEpochMs: now,
      );

      final json = fullRider.toJson();
      expect(json['phone'], '+91 9900011223');
      expect(json['emergencyContact'], '+91 8800011223');
      expect(json['emergencyContactName'], 'Trinity');
      expect(json['vehicleNo'], 'TN-09-CD-5678');
      expect(json['statusReason'], 'FUELING');
      expect(json['statusMessage'], 'Shell Gas Station');

      final restored = RiderModel.fromJson(json);
      expect(restored.phone, '+91 9900011223');
      expect(restored.vehicleNo, 'TN-09-CD-5678');
      expect(restored.statusReason, 'FUELING');
      expect(restored.emergencyContactName, 'Trinity');
    });
  });
}
