import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/route_essential.dart';
import 'package:coroute_app/domain/fuel/group_fuel_consensus.dart';
import 'package:coroute_app/presentation/rider/widgets/cockpit_action_stack.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final lead = RiderModel(
    userId: 'user_lead',
    name: 'Santhosh',
    lat: 12.9716,
    lng: 77.5946,
    fuelUsableKm: 450.0,
    lastSeenEpochMs: 1000,
  );

  final riderKiran = RiderModel(
    userId: 'user_kiran',
    name: 'Kiran Rao',
    lat: 12.9720,
    lng: 77.5950,
    fuelUsableKm: 320.0,
    lastSeenEpochMs: 1000,
  );

  final riderRahul = RiderModel(
    userId: 'user_rahul',
    name: 'Rahul S',
    lat: 12.9710,
    lng: 77.5940,
    fuelUsableKm: 65.0, // Bottleneck bike with low fuel!
    lastSeenEpochMs: 1000,
  );

  final station1 = RouteEssential(
    placeId: 'st_1',
    visitId: 'v_1',
    name: 'Shell Highway',
    category: 'FUEL',
    source: 'OSM',
    lat: 13.0000,
    lng: 77.6000,
    routePositionM: 15000, // 15 km ahead
    entryM: 14900,
    exitM: 15100,
    accessDistanceM: 50,
    detourDistanceM: 100,
    detourDurationS: 60,
  );

  final station2 = RouteEssential(
    placeId: 'st_2',
    visitId: 'v_2',
    name: 'HP Petrol Pump',
    category: 'FUEL',
    source: 'OSM',
    lat: 13.5000,
    lng: 77.8000,
    routePositionM: 80000, // 80 km ahead
    entryM: 79900,
    exitM: 80100,
    accessDistanceM: 50,
    detourDistanceM: 100,
    detourDurationS: 60,
  );

  group('GroupFuelConsensus Algorithm Tests', () {
    test('Identifies bottleneck rider and generates stop recommendation before rider runs dry', () {
      final convoy = ConvoyModel(
        groupId: 'grp_convoy',
        name: 'South India Ride',
        joinCode: 'SOUTH1',
        createdByUserId: 'user_lead',
        createdByUserName: 'Santhosh',
        createdAtEpochMs: 1000,
        riders: {
          'user_lead': lead,
          'user_kiran': riderKiran,
          'user_rahul': riderRahul,
        },
      );

      final consensus = GroupFuelConsensus.evaluate(
        convoy: convoy,
        upcomingStations: [station1, station2],
        progressM: 0,
      );

      expect(consensus, isNotNull);
      expect(consensus!.bottleneckUserId, equals('user_rahul'));
      expect(consensus.lowestRangeKm, equals(65.0));
      expect(consensus.alertLead, isTrue);
      expect(consensus.recommendedStation?.name, equals('Shell Highway'));
      expect(consensus.distanceToStationKm, closeTo(15.0, 0.1));
    });
  });

  group('GroupFuelConsensus UI Action Stack Tests', () {
    testWidgets('Lead rider sees GROUP FUEL alert card for bottleneck teammate', (tester) async {
      final convoy = ConvoyModel(
        groupId: 'grp_convoy',
        name: 'South India Ride',
        joinCode: 'SOUTH1',
        createdByUserId: 'user_lead',
        createdByUserName: 'Santhosh',
        createdAtEpochMs: 1000,
        riders: {
          'user_lead': lead,
          'user_kiran': riderKiran,
          'user_rahul': riderRahul,
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CockpitActionStack(
              convoy: convoy,
              me: lead,
              estimatedUsableKm: 450.0,
              isLead: true,
            ),
          ),
        ),
      );

      await tester.pump();

      // Lead sees Group Fuel Consensus alert card for Rahul
      expect(find.textContaining('GROUP FUEL · Rahul: 65 km left'), findsOneWidget);

      // Lead also sees their own healthy fuel button
      expect(find.textContaining('450 km'), findsOneWidget);
    });
  });
}
