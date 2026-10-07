import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/trip_history_model.dart';
import 'package:coroute_app/presentation/rider/live_cockpit_map_screen.dart';
import 'package:coroute_app/presentation/rider/rider_home_screen.dart';

/// Stands in for ConvoyService: notifies on every change, like a GPS fix does.
class _FakeConvoys extends ChangeNotifier {
  ConvoyModel? active;
  void set(ConvoyModel c) {
    active = c;
    notifyListeners();
  }
}

void main() {
  RiderModel rider(String id, String name, {double lat = 17.0}) => RiderModel(userId: id, name: name, lat: lat, lng: 78.0, lastSeenEpochMs: 0);

  ConvoyModel convoy({double myLat = 17.0}) => ConvoyModel(
        groupId: 'GRP-1',
        name: 'Coast run',
        joinCode: '123456',
        createdByUserId: 'usr_a',
        createdByUserName: 'Asha',
        createdAtEpochMs: 0,
        destinationName: 'Goa',
        riders: {'usr_a': rider('usr_a', 'Asha', lat: myLat), 'usr_b': rider('usr_b', 'Bala')},
      );

  test('home facts ignore positions and change with what the home screen shows', () {
    expect(homeConvoyFacts(convoy(myLat: 17.0)), homeConvoyFacts(convoy(myLat: 17.5)));
    expect(homeConvoyFacts(convoy()).riders, 2);
    expect(homeConvoyFacts(null).groupId, isNull);
    final renamed = convoy().copyWith(name: 'Hill run');
    expect(homeConvoyFacts(renamed) == homeConvoyFacts(convoy()), isFalse);
  });

  testWidgets('a position-only update does not rebuild a widget that selects the home facts', (tester) async {
    final fake = _FakeConvoys()..active = convoy();
    var builds = 0;
    await tester.pumpWidget(ChangeNotifierProvider<_FakeConvoys>.value(
      value: fake,
      child: MaterialApp(
        home: Builder(builder: (context) {
          final facts = context.select<_FakeConvoys, HomeConvoyFacts>((s) => homeConvoyFacts(s.active));
          builds++;
          return Text('${facts.name} ${facts.riders}');
        }),
      ),
    ));
    expect(builds, 1);
    fake.set(convoy(myLat: 17.2)); // a GPS fix
    await tester.pump();
    fake.set(convoy(myLat: 17.3));
    await tester.pump();
    expect(builds, 1, reason: 'no rebuild for position updates');
    fake.set(convoy().copyWith(name: 'Hill run'));
    await tester.pump();
    expect(builds, 2);
    expect(find.text('Hill run 2'), findsOneWidget);
  });

  test('"is this me" uses the account id only, never the name', () {
    expect(isMeRider(rider('usr_a', 'Ravi'), 'usr_a'), isTrue);
    expect(isMeRider(rider('usr_b', 'Ravi'), 'usr_a'), isFalse, reason: 'another Ravi is not me');
    expect(isMeRider(rider('', 'Ravi'), ''), isFalse);
  });

  test('rider marker label for screen readers', () {
    final r = RiderModel(userId: 'usr_b', name: 'Bala', lat: 1, lng: 1, speedKmh: 42.4, lastSeenEpochMs: 0);
    expect(riderSemanticsLabel(r, isMe: false), 'Bala, 42 km per hour');
    expect(riderSemanticsLabel(r, isMe: true, statusLabel: 'Fueling'), 'You, 42 km per hour, stopped: Fueling');
  });

  test('home ride totals', () {
    TripHistoryModel t(double km, int minutes, double top, {int moving = 0, int rest = 0}) => TripHistoryModel(
          tripId: 'T$km',
          tripName: 'r',
          startTimeEpochMs: 0,
          endTimeEpochMs: minutes * 60000,
          totalDistanceKm: km,
          topSpeedKmh: top,
          avgSpeedKmh: 40,
          riderCount: 3,
          movingMs: moving,
          restMs: rest,
        );
    final a = HomeAnalytics.of([t(100, 120, 90, moving: 3, rest: 1), t(50, 60, 110, moving: 1, rest: 3)]);
    expect(a.rides, 2);
    expect(a.totalDistanceKm, 150);
    expect(a.totalMinutes, 180);
    expect(a.maxSpeedKmh, 110);
    expect(a.avgDistanceKm, 75);
    expect(a.avgRiders, 3);
    expect(a.movingPercent, 50);
    expect(HomeAnalytics.of(const []).movingPercent, 100);
  });
}
