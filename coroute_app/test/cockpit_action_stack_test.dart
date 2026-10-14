import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/route_essential.dart';
import 'package:coroute_app/data/models/stop_point_model.dart';
import 'package:coroute_app/domain/route/route_plan.dart';
import 'package:coroute_app/domain/safety/fuel_profile.dart';
import 'package:coroute_app/presentation/rider/widgets/cockpit_action_stack.dart';
import 'package:coroute_app/presentation/rider/widgets/minimal_cockpit_settings_cards.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final me = RiderModel(
    userId: 'u1',
    name: 'Santhosh Bukka',
    lat: 12.9716,
    lng: 77.5946,
    speedKmh: 45.0,
    heading: 90.0,
    role: 'LEAD',
    lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
  );

  final memberRider = RiderModel(
    userId: 'u2',
    name: 'Rahul Sharma',
    lat: 12.9800,
    lng: 77.6000,
    speedKmh: 0.0,
    heading: 90.0,
    role: 'RIDER',
    statusReason: 'Puncture',
    lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
  );

  final foodStop = StopPointModel(
    stopId: 's1',
    name: 'Highway Dhaba',
    lat: 12.9900,
    lng: 77.6100,
    category: 'FOOD',
    status: 'SUGGESTED',
    suggestedBy: 'u2',
    suggestedByName: 'Rahul Sharma',
  );

  final meetingPoint = StopPointModel(
    stopId: 's2',
    name: 'Toll Plaza Meet',
    lat: 13.0000,
    lng: 77.6200,
    category: RoutePlan.meetingCategory,
    status: 'PLANNED',
    suggestedBy: 'u1',
    suggestedByName: 'Santhosh Bukka',
  );

  final convoy = ConvoyModel(
    groupId: 'test-group',
    name: 'Bangalore Weekend Ride',
    joinCode: 'BLR456',
    createdByUserId: 'u1',
    createdByUserName: 'Santhosh Bukka',
    createdAtEpochMs: 1000,
    riders: {'u1': me, 'u2': memberRider},
    stopPoints: [foodStop, meetingPoint],
    destinationName: 'Nandi Hills',
  );

  testWidgets('CockpitActionStack stacks low fuel pill, stop suggestion, meet point, and stopped rider', (tester) async {
    RouteEssential? addedStation;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CockpitActionStack(
            convoy: convoy,
            me: me,
            estimatedUsableKm: 42.0, // Low fuel threshold (<= 60 km)
            isLead: true,
            onAddStationStop: (st) => addedStation = st,
          ),
        ),
      ),
    );

    // 1. Verify Low Fuel Pill
    expect(find.textContaining('LOW FUEL · 42 km left'), findsOneWidget);
    expect(find.byIcon(Icons.local_gas_station_rounded), findsOneWidget);

    // 2. Verify Member Stop Suggestion (Food)
    expect(find.textContaining('Rahul: Highway Dhaba'), findsOneWidget);
    expect(find.byIcon(Icons.restaurant_rounded), findsOneWidget);

    // 3. Verify Meeting Point
    expect(find.textContaining('MEET HERE · Toll Plaza Meet'), findsOneWidget);
    expect(find.byIcon(Icons.flag_rounded), findsOneWidget);

    // 4. Verify Stopped Rider Pill
    expect(find.textContaining('Rahul stopped: Puncture'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);

    // 5. Tap Low Fuel Pill to open Quick Station Sheet
    await tester.tap(find.textContaining('LOW FUEL · 42 km left'));
    await tester.pumpAndSettle();

    expect(find.text('Low Fuel Warning'), findsOneWidget);
    expect(find.text('Estimated ~42 km usable range left'), findsOneWidget);
  });

  testWidgets('MinimalCockpitSettingsCards renders all 4 structured cards', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                NavigationToolsCard(
                  convoy: convoy,
                  onOpenStops: () {},
                  onOpenMessages: () {},
                  onTurnByTurn: () {},
                  chatQueued: 0,
                  isOnline: true,
                ),
                SafetyFuelCard(
                  estimatedUsableKm: 540.0,
                  profile: const FuelProfile(fullRangeKm: 638.0),
                  nearestFuelAheadM: 3400.0,
                  nearestFuelName: 'Shell Petrol Pump',
                  fuelUncertain: false,
                  riddenSinceFillM: 12000.0,
                  onOpenFuel: () {},
                  onOpenGuardian: () {},
                  onTellWhy: () {},
                ),
                ConvoyCommsCard(
                  convoy: convoy,
                  onShareInvite: () {},
                  onCopyCode: () {},
                  onOpenIntercom: () {},
                  onOpenGroupSettings: () {},
                ),
                RideControlsCard(
                  isLead: true,
                  isPaused: false,
                  onTogglePause: () {},
                  onEndRide: () {},
                  onLeaveRide: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // Verify key elements across the 4 cards
    expect(find.text('Route and stops'), findsOneWidget);
    expect(find.text('Turn-by-turn navigation'), findsOneWidget);
    expect(find.text('Fuel range: 540 km remaining'), findsOneWidget);
    expect(find.text('REFUEL'), findsOneWidget);
    expect(find.text('Share Ride Guardian link'), findsOneWidget);
    expect(find.text('BLR456'), findsOneWidget);
    expect(find.text('Intercom options'), findsOneWidget);
    expect(find.text('Pause Convoy Ride'), findsOneWidget);
    expect(find.text('End Ride'), findsOneWidget);
    expect(find.text('Leave Ride'), findsOneWidget);
  });

  testWidgets('Strict Standards: ZERO emojis and ASCII hyphens across new cockpit components', (tester) async {
    final emojiRegex = RegExp(r'[\u{1F300}-\u{1F9FF}]|[\u{2600}-\u{26FF}]|[\u{2700}-\u{27BF}]', unicode: true);
    final unicodeDashRegex = RegExp(r'[\u2010\u2011\u2012\u2013\u2014\u2015]');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                CockpitActionStack(
                  convoy: convoy,
                  me: me,
                  estimatedUsableKm: 42.0,
                  isLead: true,
                ),
                NavigationToolsCard(
                  convoy: convoy,
                  onOpenStops: () {},
                  onOpenMessages: () {},
                  chatQueued: 0,
                  isOnline: true,
                ),
                SafetyFuelCard(
                  estimatedUsableKm: 540.0,
                  profile: const FuelProfile(fullRangeKm: 638.0),
                  nearestFuelAheadM: 3400.0,
                  nearestFuelName: 'Shell Petrol Pump',
                  fuelUncertain: false,
                  riddenSinceFillM: 12000.0,
                  onOpenFuel: () {},
                  onOpenGuardian: () {},
                  onTellWhy: () {},
                ),
                ConvoyCommsCard(
                  convoy: convoy,
                  onShareInvite: () {},
                  onCopyCode: () {},
                  onOpenIntercom: () {},
                  onOpenGroupSettings: () {},
                ),
                RideControlsCard(
                  isLead: true,
                  isPaused: false,
                  onTogglePause: () {},
                  onEndRide: () {},
                  onLeaveRide: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final texts = tester.widgetList<Text>(find.byType(Text));
    for (final t in texts) {
      final s = t.data ?? t.textSpan?.toPlainText() ?? '';
      expect(emojiRegex.hasMatch(s), isFalse, reason: 'Found forbidden emoji in "$s"');
      expect(unicodeDashRegex.hasMatch(s), isFalse, reason: 'Found unicode dash in "$s"');
    }
  });
}
