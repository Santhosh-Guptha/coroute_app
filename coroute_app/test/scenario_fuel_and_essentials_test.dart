import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/data/models/route_essential.dart';
import 'package:coroute_app/domain/safety/fuel_range.dart';
import 'package:coroute_app/domain/safety/group_fuel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Scenario Fuel Management and Essentials Discovery Suite', () {
    const int t0 = 1700000000000;



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


    group('REQ-07: Progressive Fuel Alert Tiers, Deduplication, and Station Status Handling', () {
      test('Evaluates progressive alert tiers strictly at 30km, 20km, 10km, and range risk', () {
        final tracker = FuelRangeTracker();

        // Range > 30 km -> none
        expect(tracker.evaluateAlertTier(usableKm: 35.0), equals(FuelAlertTier.none));
        expect(tracker.evaluateAlertTier(usableKm: 120.0), equals(FuelAlertTier.none));

        // Range <= 30 km -> warning
        expect(tracker.evaluateAlertTier(usableKm: 30.0), equals(FuelAlertTier.warning));
        expect(tracker.evaluateAlertTier(usableKm: 25.0), equals(FuelAlertTier.warning));

        // Range <= 20 km -> urgent
        expect(tracker.evaluateAlertTier(usableKm: 20.0), equals(FuelAlertTier.urgent));
        expect(tracker.evaluateAlertTier(usableKm: 15.0), equals(FuelAlertTier.urgent));

        // Range <= 10 km -> critical
        expect(tracker.evaluateAlertTier(usableKm: 10.0), equals(FuelAlertTier.critical));
        expect(tracker.evaluateAlertTier(usableKm: 3.0), equals(FuelAlertTier.critical));

        // Range risk: station ahead is 40 km, but usable range is only 35 km
        expect(
          tracker.evaluateAlertTier(usableKm: 35.0, nextStationDistanceKm: 40.0),
          equals(FuelAlertTier.rangeRisk),
        );
      });

      test('Alert deduplication triggers only once per tier and resets on refuel', () {
        final tracker = FuelRangeTracker();

        // 1st tick at 28 km: warning tier -> triggers
        expect(tracker.shouldTriggerAlert(FuelAlertTier.warning), isTrue);
        expect(tracker.lastAlertTier, equals(FuelAlertTier.warning));

        // Subsequent ticks at 27 km, 26 km, 25 km: still warning tier -> deduplicated, does NOT trigger
        expect(tracker.shouldTriggerAlert(FuelAlertTier.warning), isFalse);
        expect(tracker.shouldTriggerAlert(FuelAlertTier.warning), isFalse);

        // Escalation to 18 km: urgent tier -> triggers!
        expect(tracker.shouldTriggerAlert(FuelAlertTier.urgent), isTrue);
        expect(tracker.lastAlertTier, equals(FuelAlertTier.urgent));

        // Subsequent tick at 17 km: deduplicated
        expect(tracker.shouldTriggerAlert(FuelAlertTier.urgent), isFalse);

        // Escalation to 8 km: critical tier -> triggers!
        expect(tracker.shouldTriggerAlert(FuelAlertTier.critical), isTrue);
        expect(tracker.lastAlertTier, equals(FuelAlertTier.critical));

        // Subsequent tick: deduplicated
        expect(tracker.shouldTriggerAlert(FuelAlertTier.critical), isFalse);

        // Refuel resets alert tier
        tracker.filledUp(1700000100000);
        expect(tracker.lastAlertTier, equals(FuelAlertTier.none));

        // Warning tier can now trigger cleanly again on next drain
        expect(tracker.shouldTriggerAlert(FuelAlertTier.warning), isTrue);
      });

      test('Station closure marking and query tracking', () {
        final tracker = FuelRangeTracker();

        expect(tracker.isStationClosed('bunk_123'), isFalse);

        tracker.markStationClosed('bunk_123');
        expect(tracker.isStationClosed('bunk_123'), isTrue);
        expect(tracker.isStationClosed('bunk_456'), isFalse);

        tracker.clearClosedStations();
        expect(tracker.isStationClosed('bunk_123'), isFalse);
      });
    });
  });
}
