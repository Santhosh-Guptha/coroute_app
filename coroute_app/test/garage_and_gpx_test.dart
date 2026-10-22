import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/config/feature_gates.dart';
import 'package:coroute_app/domain/garage/bike_profile.dart';
import 'package:coroute_app/data/services/garage_service.dart';
import 'package:coroute_app/data/services/gpx_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Garage & BikeProfile Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FeatureGates.forceAllUnlocked = true;
    });

    test('Default seeding creates a Royal Enfield Himalayan 450', () async {
      final service = GarageService();
      await service.load();

      final bikes = service.bikesNotifier.value;
      expect(bikes.length, 1);
      expect(bikes.first.model, 'Himalayan 450');
      expect(service.activeBikeNotifier.value?.model, 'Himalayan 450');
      expect(bikes.first.tankCapacityL, 17.0);
      expect(bikes.first.reserveCapacityL, 3.5);
      expect(bikes.first.fullTankRangeKm, 17.0 * 28.0);
    });

    test('Adding and switching active bikes updates notifier and fuel profile', () async {
      final service = GarageService();
      await service.load();

      const ktm = BikeProfile(
        id: 'bike_ktm_390',
        name: 'KTM 390 Adventure',
        make: 'KTM',
        model: '390 Adv',
        tankCapacityL: 14.5,
        reserveCapacityL: 2.8,
        expectedMileageKmL: 27.0,
      );

      await service.saveBike(ktm);
      expect(service.bikesNotifier.value.length, 2);

      await service.setActiveBike(ktm.id);
      expect(service.activeBikeNotifier.value?.id, ktm.id);

      final fuelProfile = service.toFuelProfile();
      expect(fuelProfile.capacityL, 14.5);
      expect(fuelProfile.mileageKmL, 27.0);
      expect(fuelProfile.reserveL, 2.8);
    });

    test('Trip distance increments odometer and service intervals calculate correctly', () async {
      final service = GarageService();
      await service.load();

      final bike = service.activeBikeNotifier.value!;
      expect(bike.totalOdometerKm, 0.0);
      expect(bike.kmUntilService, 5000.0);
      expect(bike.isServiceDueSoon, false);
      expect(bike.isServiceOverdue, false);

      // Ride 4600 km
      await service.addTripDistance(4600.0);
      final updated = service.activeBikeNotifier.value!;
      expect(updated.totalOdometerKm, 4600.0);
      expect(updated.kmUntilService, 400.0);
      expect(updated.isServiceDueSoon, true);
      expect(updated.isServiceOverdue, false);

      // Ride 500 more km -> Overdue
      await service.addTripDistance(500.0);
      final overdueBike = service.activeBikeNotifier.value!;
      expect(overdueBike.totalOdometerKm, 5100.0);
      expect(overdueBike.kmUntilService, -100.0);
      expect(overdueBike.isServiceOverdue, true);

      // Record service completed at 5100 km
      await service.recordServiceCompleted(overdueBike.id, 5100.0);
      final servicedBike = service.activeBikeNotifier.value!;
      expect(servicedBike.lastServiceOdometerKm, 5100.0);
      expect(servicedBike.kmUntilService, 5000.0);
      expect(servicedBike.isServiceOverdue, false);
    });
  });

  group('GpxService Telemetry Tests', () {
    test('Builds valid GPX 1.1 with trackpoints, speeds, and stop waypoints', () {
      final now = DateTime.utc(2026, 10, 21, 10, 0, 0);

      final trackpoints = [
        GpxTrackpoint(
          latitude: 12.9716,
          longitude: 77.5946,
          elevationM: 920.0,
          timestamp: now,
          speedKmh: 45.0,
          bearing: 180.0,
        ),
        GpxTrackpoint(
          latitude: 12.9720,
          longitude: 77.5950,
          elevationM: 922.0,
          timestamp: now.add(const Duration(seconds: 5)),
          speedKmh: 60.0,
          bearing: 182.0,
        ),
      ];

      final waypoints = [
        GpxWaypoint(
          name: 'Shell Fuel Stop',
          description: 'Group refueled to full tank',
          latitude: 12.9716,
          longitude: 77.5946,
          timestamp: now,
          symbol: 'Gas Station',
        ),
      ];

      final xml = GpxService.buildTelemetryGpx(
        rideName: 'Bengaluru Monsoon Ride',
        trackpoints: trackpoints,
        waypoints: waypoints,
      );

      expect(xml.contains('<gpx version="1.1"'), true);
      expect(xml.contains('<name>Bengaluru Monsoon Ride</name>'), true);
      expect(xml.contains('<wpt lat="12.971600" lon="77.594600">'), true);
      expect(xml.contains('<sym>Gas Station</sym>'), true);
      expect(xml.contains('<trkpt lat="12.971600" lon="77.594600">'), true);
      expect(xml.contains('<ele>920.0</ele>'), true);
      expect(xml.contains('<coroute:speed_kmh>45.0</coroute:speed_kmh>'), true);
      expect(xml.contains('</gpx>'), true);
    });
  });
}
