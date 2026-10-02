import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/constants/app_constants.dart';
import 'package:coroute_app/core/constants/telemetry_utils.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/sos_alert_model.dart';
import 'package:coroute_app/data/models/trip_history_model.dart';
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

  group('AuthService Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('Master Admin authentication succeeds for santhoshbukka5@gmail.com', () async {
      final auth = AuthService();
      await Future.delayed(const Duration(milliseconds: 50));

      final success = await auth.loginMasterAdmin(
        email: AppConstants.masterAdminEmail,
        password: 'secure_admin_pass',
      );

      expect(success, true);
      expect(auth.isMasterAdmin, true);
      expect(auth.currentUserRole, AppConstants.adminRole);
      expect(auth.currentUserEmail, AppConstants.masterAdminEmail);
    });

    test('Master Admin rejects invalid email or empty password', () async {
      final auth = AuthService();
      await Future.delayed(const Duration(milliseconds: 50));

      final failureWrongEmail = await auth.loginMasterAdmin(
        email: 'attacker@example.com',
        password: 'password123',
      );

      expect(failureWrongEmail, false);
      expect(auth.isMasterAdmin, false);

      final failureEmptyPass = await auth.loginMasterAdmin(
        email: AppConstants.masterAdminEmail,
        password: '',
      );

      expect(failureEmptyPass, false);
      expect(auth.isMasterAdmin, false);
    });

    test('Rider authentication and logout', () async {
      final auth = AuthService();
      await Future.delayed(const Duration(milliseconds: 50));

      await auth.loginRider(
        riderName: 'GhostRider',
        vehicleType: 'Adventure Bike',
        phone: '+91 9876543210',
        emergencyContact: '+91 9123456780',
        emergencyContactName: 'Captain Safe',
        vehicleNo: 'KA-01-AB-1234',
      );

      expect(auth.isMasterAdmin, false);
      expect(auth.isAuthenticated, true);
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
