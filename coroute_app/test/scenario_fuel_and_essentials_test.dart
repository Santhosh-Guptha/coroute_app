import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/data/models/route_essential.dart';
import 'package:coroute_app/domain/safety/essentials_discovery.dart';
import 'package:coroute_app/domain/safety/fuel_consumption_learner.dart';
import 'package:coroute_app/domain/safety/group_fuel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Scenario Fuel Management and Essentials Discovery Suite', () {
    const int t0 = 1700000000000;

    group('REQ-06: Speed-Bin Fuel Consumption Learner and Dynamic Usable Range', () {
      test('Classifies speeds into city, cruise, and highway bins with physics-based multipliers', () {
        expect(SpeedBinConsumptionLearner.binForSpeed(25.0), SpeedBinCategory.city);
        expect(SpeedBinConsumptionLearner.binForSpeed(44.9), SpeedBinCategory.city);
        expect(SpeedBinConsumptionLearner.binForSpeed(45.0), SpeedBinCategory.cruise);
        expect(SpeedBinConsumptionLearner.binForSpeed(75.0), SpeedBinCategory.cruise);
        expect(SpeedBinConsumptionLearner.binForSpeed(84.9), SpeedBinCategory.cruise);
        expect(SpeedBinConsumptionLearner.binForSpeed(85.0), SpeedBinCategory.highway);
        expect(SpeedBinConsumptionLearner.binForSpeed(110.0), SpeedBinCategory.highway);

        // Efficiency multipliers: Cruise is peak (1.15), Highway is drag-penalized (0.88), City has stop-and-go (0.82)
        expect(SpeedBinConsumptionLearner.defaultMultiplier(SpeedBinCategory.cruise), equals(1.15));
        expect(SpeedBinConsumptionLearner.defaultMultiplier(SpeedBinCategory.highway), equals(0.88));
        expect(SpeedBinConsumptionLearner.defaultMultiplier(SpeedBinCategory.city), equals(0.82));
      });

      test('Learns composite mileage from recorded telemetry segments', () {
        final learner = SpeedBinConsumptionLearner();

        // 10 km of slow city commuting at 30 km/h (1200 seconds)
        learner.recordSegment(speedKmh: 30.0, distanceM: 10000, durationS: 1200);

        // 40 km of smooth state highway cruising at 65 km/h (2215 seconds)
        learner.recordSegment(speedKmh: 65.0, distanceM: 40000, durationS: 2215);

        // 50 km of fast national highway riding at 95 km/h (1894 seconds)
        learner.recordSegment(speedKmh: 95.0, distanceM: 50000, durationS: 1894);

        const baselineKmL = 35.0;
        final effectiveKmL = learner.effectiveMileageKmL(baselineKmL: baselineKmL);

        // Weighted distance calculation:
        // (10000*0.82 + 40000*1.15 + 50000*0.88) / 100000 = (8200 + 46000 + 44000) / 100000 = 0.982
        // Effective mileage = 35.0 * 0.982 = 34.37 km/L
        expect(effectiveKmL, closeTo(34.37, 0.2));
      });

      test('Projects speed-adjusted dynamic usable range deducting reserve and buffer', () {
        final learner = SpeedBinConsumptionLearner();
        const baselineKmL = 30.0;
        const remainingLiters = 14.0;
        const reserveLiters = 2.0; // 2L reserve
        const bufferKm = 20.0; // 20 km safety buffer

        // Case A: Cruising speed (65 km/h) -> Multiplier 1.15 -> 34.5 km/L
        // Usable fuel: 14 - 2 = 12 L -> Raw range: 12 * 34.5 = 414 km -> Usable: 414 - 20 = 394 km
        final cruiseRangeKm = learner.dynamicUsableKm(
          remainingLiters: remainingLiters,
          currentSpeedKmh: 65.0,
          baselineKmL: baselineKmL,
          reserveL: reserveLiters,
          bufferKm: bufferKm,
        );
        expect(cruiseRangeKm, closeTo(394.0, 1.0));

        // Case B: High-speed highway (105 km/h) -> Multiplier 0.88 -> 26.4 km/L
        // Usable fuel: 12 L -> Raw range: 12 * 26.4 = 316.8 km -> Usable: 316.8 - 20 = 296.8 km
        final highwayRangeKm = learner.dynamicUsableKm(
          remainingLiters: remainingLiters,
          currentSpeedKmh: 105.0,
          baselineKmL: baselineKmL,
          reserveL: reserveLiters,
          bufferKm: bufferKm,
        );
        expect(highwayRangeKm, closeTo(296.8, 1.0));

        // Aerodynamic drag creates substantial range difference (> 90 km gap)
        expect(cruiseRangeKm - highwayRangeKm, greaterThan(90.0));

        // Case C: Fuel at or below reserve returns 0.0 usable range
        final emptyRange = learner.dynamicUsableKm(
          remainingLiters: 1.5,
          currentSpeedKmh: 65.0,
          baselineKmL: baselineKmL,
          reserveL: reserveLiters,
          bufferKm: bufferKm,
        );
        expect(emptyRange, equals(0.0));
      });

      test('Serializes and deserializes SpeedBinConsumptionLearner state cleanly', () {
        final original = SpeedBinConsumptionLearner();
        original.recordSegment(speedKmh: 60.0, distanceM: 25000, durationS: 1500);

        final json = original.toJson();
        expect(json.containsKey('cruise'), isTrue);

        final restored = SpeedBinConsumptionLearner.fromJson(json);
        expect(restored.stats[SpeedBinCategory.cruise]?.totalDistanceM, equals(25000.0));
        expect(restored.stats[SpeedBinCategory.cruise]?.sampleCount, equals(1));
      });
    });

    group('REQ-07: Refuel EMA Calibration and Outlier Rejection', () {
      test('Calibrates baseline mileage with Exponential Moving Average over refuel history', () {
        final calibrator = RefuelEmaCalibrator(
          initialBaselineKmL: 32.0,
          alpha: 0.25,
        );

        expect(calibrator.calibratedMileageKmL, equals(32.0));
        expect(calibrator.refuelCount, equals(0));
        expect(calibrator.confidence, equals(0.50));

        // Refuel 1: 300 km on 10.0 L = 30.0 km/L observed
        // New EMA = 0.25 * 30.0 + 0.75 * 32.0 = 7.5 + 24.0 = 31.5 km/L
        final r1 = calibrator.logRefuel(
          timestamp: t0,
          distanceKm: 300.0,
          litersFilled: 10.0,
        );
        expect(r1, isTrue);
        expect(calibrator.calibratedMileageKmL, closeTo(31.5, 0.01));
        expect(calibrator.refuelCount, equals(1));
        expect(calibrator.confidence, greaterThan(0.50));

        // Refuel 2: 350 km on 10.0 L = 35.0 km/L observed
        // New EMA = 0.25 * 35.0 + 0.75 * 31.5 = 8.75 + 23.625 = 32.375 km/L
        final r2 = calibrator.logRefuel(
          timestamp: t0 + 86400000,
          distanceKm: 350.0,
          litersFilled: 10.0,
        );
        expect(r2, isTrue);
        expect(calibrator.calibratedMileageKmL, closeTo(32.375, 0.01));
        expect(calibrator.refuelCount, equals(2));
        expect(calibrator.confidence, greaterThan(0.70));
      });

      test('Filters physical outliers without corrupting calibrated mileage', () {
        final calibrator = RefuelEmaCalibrator(initialBaselineKmL: 32.0);

        // Valid refuel
        calibrator.logRefuel(timestamp: t0, distanceKm: 320.0, litersFilled: 10.0);
        final safeMileage = calibrator.calibratedMileageKmL;

        // Outlier A: Impossible super-high mileage (500 km on 1 L = 500 km/L > 120 max bound)
        final bad1 = calibrator.logRefuel(timestamp: t0 + 1000, distanceKm: 500.0, litersFilled: 1.0);
        expect(bad1, isFalse);
        expect(calibrator.calibratedMileageKmL, equals(safeMileage));

        // Outlier B: Impossible tiny mileage (10 km on 10 L = 1 km/L < 5 min bound)
        final bad2 = calibrator.logRefuel(timestamp: t0 + 2000, distanceKm: 10.0, litersFilled: 10.0);
        expect(bad2, isFalse);
        expect(calibrator.calibratedMileageKmL, equals(safeMileage));

        // Outlier C: Negative or zero inputs
        final bad3 = calibrator.logRefuel(timestamp: t0 + 3000, distanceKm: -50.0, litersFilled: 5.0);
        expect(bad3, isFalse);
        final bad4 = calibrator.logRefuel(timestamp: t0 + 4000, distanceKm: 100.0, litersFilled: 0.0);
        expect(bad4, isFalse);
        expect(calibrator.calibratedMileageKmL, equals(safeMileage));
      });

      test('Refuel log entries record timestamps, volumes, and observed efficiencies', () {
        final calibrator = RefuelEmaCalibrator(initialBaselineKmL: 35.0);
        calibrator.logRefuel(timestamp: t0, distanceKm: 280.0, litersFilled: 8.0);

        expect(calibrator.logs, hasLength(1));
        final entry = calibrator.logs.first;
        expect(entry.timestamp, equals(t0));
        expect(entry.distanceKm, equals(280.0));
        expect(entry.litersFilled, equals(8.0));
        expect(entry.observedKmL, equals(35.0));

        final json = entry.toJson();
        final restored = RefuelLogEntry.fromJson(json);
        expect(restored, isNotNull);
        expect(restored!.observedKmL, equals(35.0));
      });
    });

    group('REQ-08: Group Fuel Stop Optimization and Bottleneck Convergence', () {
      // 40 km highway segment on NH44
      final highwaySegment = <(double, double)>[
        for (double lat = 13.000; lat <= 13.360 + 1e-9; lat += 0.010) (lat, 77.600)
      ];

      test('Identifies bottleneck rider and calculates individual road distances to fuel stop', () {
        // 4 riders along the highway:
        // - Lead at km 16.7 (lat 13.150) with 150 km range
        // - Scout at km 16.2 (lat 13.146) with 120 km range
        // - Bottleneck at km 9.7 (lat 13.087) with only 35 km range
        // - Sweeper at km 9.6 (lat 13.086) with 130 km range
        final riders = <PositionedFuelRange>[
          PositionedFuelRange(
            SharedFuelRange('u_lead', 150.0, t0, t0),
            13.150,
            77.600,
          ),
          PositionedFuelRange(
            SharedFuelRange('u_scout', 120.0, t0, t0),
            13.146,
            77.600,
          ),
          PositionedFuelRange(
            SharedFuelRange('u_bottleneck', 35.0, t0, t0),
            13.087,
            77.600,
          ),
          PositionedFuelRange(
            SharedFuelRange('u_sweeper', 130.0, t0, t0),
            13.086,
            77.600,
          ),
        ];

        // Candidate pump at km 25 (routePositionM: 25000, access: 200m)
        final pump = RouteEssential(
          placeId: 'fuel_stop_km25',
          visitId: 'v_fuel_km25',
          name: 'Highway HP Petrol Pump',
          category: 'FUEL',
          source: 'test',
          lat: 13.225,
          lng: 77.600,
          routePositionM: 25000,
          entryM: 25000,
          exitM: 25500,
          accessDistanceM: 200,
          detourDistanceM: 400,
          detourDurationS: 60,
        );

        final stop = commonFuelStop(
          riders: riders,
          total: 4,
          now: t0,
          route: highwaySegment,
          stations: [pump],
          reliable: true,
        );

        expect(stop, isNotNull);
        expect(stop!.bottleneckRiderId, equals('u_bottleneck'));
        expect(stop.totalRiders, equals(4));
        expect(stop.contributors, equals(4));
        expect(stop.isCompleteCoverage, isTrue);

        // Bottleneck rider has lowest headroom
        expect(stop.smallestRemainingKm, greaterThan(15.0)); // 35 km range - ~15.5 km distance
        expect(stop.smallestRemainingKm, lessThan(25.0));
      });

      test('Prioritizes reachable verified COCO pump over closer unbranded pump', () {
        final riders = <PositionedFuelRange>[
          PositionedFuelRange(
            SharedFuelRange('u_rider_1', 60.0, t0, t0),
            13.087,
            77.600,
          ),
          PositionedFuelRange(
            SharedFuelRange('u_rider_2', 70.0, t0, t0),
            13.087,
            77.600,
          ),
        ];

        final unbrandedPump = RouteEssential(
          placeId: 'fuel_unbranded_km18',
          visitId: 'v_unbranded',
          name: 'Local Rural Bunk',
          category: 'FUEL',
          source: 'test',
          lat: 13.160,
          lng: 77.600,
          routePositionM: 18000,
          entryM: 18000,
          exitM: 18500,
          accessDistanceM: 500,
          detourDistanceM: 1000,
          detourDurationS: 120,
          isCoco: false,
        );

        final cocoPump = RouteEssential(
          placeId: 'fuel_bpcl_coco_km25',
          visitId: 'v_bpcl_coco',
          name: 'BPCL COCO Highway Oasis',
          category: 'FUEL',
          source: 'test',
          lat: 13.225,
          lng: 77.600,
          routePositionM: 25000,
          entryM: 25000,
          exitM: 25500,
          accessDistanceM: 150,
          detourDistanceM: 300,
          detourDurationS: 45,
          isCoco: true,
          operatorName: 'BPCL',
          priority: 1,
        );

        // When both are reachable, COCO station is prioritized
        final stop = commonFuelStop(
          riders: riders,
          total: 2,
          now: t0,
          route: highwaySegment,
          stations: [unbrandedPump, cocoPump],
          reliable: true,
        );

        expect(stop, isNotNull);
        expect(stop!.station.placeId, equals('fuel_bpcl_coco_km25'));
        expect(stop.station.isCoco, isTrue);
      });
    });

    group('REQ-09: Roadside Puncture Repair Facility Discovery and Detour Assessment', () {
      test('Identifies puncture repair facilities via name keywords and OSM tags', () {
        // Keyword recognition
        const kwEssential = RouteEssential(
          placeId: 'p_tyre_shop',
          visitId: 'v_tyre',
          name: 'Balaji Tyre Vulcanizing and Puncture Works',
          category: 'REPAIR',
          source: 'test',
          lat: 13.150,
          lng: 77.600,
          routePositionM: 16000,
          entryM: 16000,
          exitM: 16200,
          accessDistanceM: 50,
          detourDistanceM: 100,
          detourDurationS: 30,
        );
        expect(PunctureDiscovery.isPunctureFacility(kwEssential), isTrue);

        // Category direct recognition
        const catEssential = RouteEssential(
          placeId: 'p_cat',
          visitId: 'v_cat',
          name: 'Highway Quick Service',
          category: 'PUNCTURE',
          source: 'test',
          lat: 13.150,
          lng: 77.600,
          routePositionM: 16000,
          entryM: 16000,
          exitM: 16200,
          accessDistanceM: 50,
          detourDistanceM: 100,
          detourDurationS: 30,
        );
        expect(PunctureDiscovery.isPunctureFacility(catEssential), isTrue);

        // Tag recognition
        const genericName = RouteEssential(
          placeId: 'p_osm_node',
          visitId: 'v_osm',
          name: 'Om Sai Wheel Care',
          category: 'SHOP',
          source: 'test',
          lat: 13.150,
          lng: 77.600,
          routePositionM: 16000,
          entryM: 16000,
          exitM: 16200,
          accessDistanceM: 50,
          detourDistanceM: 100,
          detourDurationS: 30,
        );
        expect(
          PunctureDiscovery.isPunctureFacility(genericName, tags: {'shop': 'tyres'}),
          isTrue,
        );
        expect(
          PunctureDiscovery.isPunctureFacility(genericName, tags: {'puncture_repair': 'yes'}),
          isTrue,
        );

        // Negative recognition: Restaurant or Pharmacy is not puncture shop
        const pharmacy = RouteEssential(
          placeId: 'p_pharmacy',
          visitId: 'v_pharmacy',
          name: 'Apollo Pharmacy Highway',
          category: 'MEDICAL',
          source: 'test',
          lat: 13.150,
          lng: 77.600,
          routePositionM: 16000,
          entryM: 16000,
          exitM: 16200,
          accessDistanceM: 50,
          detourDistanceM: 100,
          detourDurationS: 30,
        );
        expect(PunctureDiscovery.isPunctureFacility(pharmacy), isFalse);
      });

      test('Discovers upcoming puncture shops and computes road distance from rider progress', () {
        const p1 = RouteEssential(
          placeId: 'shop_1',
          visitId: 'v_1',
          name: 'NH44 Tubeless Puncture Shop',
          category: 'TYRE',
          source: 'test',
          lat: 13.150,
          lng: 77.600,
          routePositionM: 18000,
          entryM: 18000,
          exitM: 18200,
          accessDistanceM: 100,
          detourDistanceM: 200,
          detourDurationS: 60,
        );

        const p2 = RouteEssential(
          placeId: 'shop_2',
          visitId: 'v_2',
          name: '24x7 Highway Puncture and Vulcanizing Center',
          category: 'TYRE',
          source: 'test',
          lat: 13.250,
          lng: 77.600,
          routePositionM: 29000,
          entryM: 29000,
          exitM: 29200,
          accessDistanceM: 50,
          detourDistanceM: 100,
          detourDurationS: 30,
        );

        // Rider progress is at km 10 (10000 m)
        final discovered = PunctureDiscovery.discoverPunctureShops(
          places: [p1, p2],
          riderProgressM: 10000,
          tagMap: {
            'shop_1': {'service:vehicle:tyres': 'puncture', 'tubeless': 'yes'},
            'shop_2': {'opening_hours': '24/7', 'vulcanizing': 'yes'},
          },
        );

        expect(discovered, hasLength(2));

        // Shop 1 distance from rider progress: (18000 - 10000) + 100 = 8100 m
        expect(discovered[0].roadDistanceM(10000), equals(8100.0));
        expect(discovered[0].isTubelessRepair, isTrue);

        // Shop 2 distance from rider progress: (29000 - 10000) + 50 = 19050 m
        expect(discovered[1].roadDistanceM(10000), equals(19050.0));
        expect(discovered[1].is24Hours, isTrue);
        expect(discovered[1].isTubeVulcanizing, isTrue);

        // 24x7 filter only returns Shop 2
        final nightOnly = PunctureDiscovery.discoverPunctureShops(
          places: [p1, p2],
          riderProgressM: 10000,
          require24x7: true,
          tagMap: {
            'shop_1': {'service:vehicle:tyres': 'puncture', 'tubeless': 'yes'},
            'shop_2': {'opening_hours': '24/7', 'vulcanizing': 'yes'},
          },
        );
        expect(nightOnly, hasLength(1));
        expect(nightOnly.first.placeId, equals('shop_2'));
      });
    });
  });
}
