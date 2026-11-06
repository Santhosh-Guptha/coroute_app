import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/trip_history_model.dart';
import 'package:coroute_app/presentation/rider/live_cockpit_map_screen.dart';
import 'package:coroute_app/presentation/rider/rider_home_screen.dart';

void main() {
  RiderModel rider(String id, String name, {double lat = 17.0}) => RiderModel(userId: id, name: name, lat: lat, lng: 78.0, lastSeenEpochMs: 0);

  test('"is this me" uses the account id only, never the name', () {
    expect(isMeRider(rider('usr_a', 'Ravi'), 'usr_a'), isTrue);
    expect(isMeRider(rider('usr_b', 'Ravi'), 'usr_a'), isFalse, reason: 'another Ravi is not me');
    expect(isMeRider(rider('', 'Ravi'), ''), isFalse);
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
