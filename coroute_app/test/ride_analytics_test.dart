import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/data/models/ride_analytics_inputs.dart';
import 'package:coroute_app/data/models/trip_history_model.dart';
import 'package:coroute_app/domain/analytics/ride_analytics.dart';

int ms(String iso) => DateTime.parse(iso).millisecondsSinceEpoch;

/// Saturday 7 Nov 2026, 12:00 UTC (the week started Monday 2 Nov).
final int now = ms('2026-11-07T12:00:00Z');
const int ist = 330; // UTC+05:30
const int hour = 3600000;

RideEntry ride(String startIso, double km, {int movingMin = 60, double top = 80, int riders = 1, String id = '', String name = '', bool phone = true}) {
  final s = ms(startIso);
  return RideEntry(
    id: id.isEmpty ? startIso : id,
    name: name,
    startMs: s,
    endMs: s + 2 * hour,
    km: km,
    movingMs: movingMin * 60000,
    topKmh: top,
    riders: riders,
    fromPhone: phone,
  );
}

RideAnalytics run(List<RideEntry> rides, {int offset = 0, List<RideSafetyEntry> safety = const [], FuelInputs? fuel, int? nowMs}) =>
    RideAnalyticsCalculator.compute(RideAnalyticsInput(rides: rides, safety: safety, fuel: fuel, nowMs: nowMs ?? now, utcOffsetMinutes: offset));

void main() {
  group('empty', () {
    test('no rides: empty, 12 zero weeks, no streak, no fuel', () {
      final a = run(const [], fuel: const FuelInputs(kmPerUnit: 40));
      expect(a.isEmpty, isTrue);
      expect(a.rides, 0);
      expect(a.totalKm, 0);
      expect(a.weeks.length, 12);
      expect(a.weeks.every((w) => w.km == 0), isTrue);
      expect(a.streakText, isNull);
      expect(a.fuel, isNull);
      expect(a.avgMovingKmh, 0);
    });
  });

  group('totals', () {
    test('rides, distance, riding time, longest, top speed, weighted moving speed', () {
      final a = run([
        ride('2026-11-03T04:00:00Z', 100, movingMin: 120, top: 92, name: 'Coast run'),
        ride('2026-11-04T04:00:00Z', 50, movingMin: 60, top: 70),
        ride('2026-10-20T04:00:00Z', 30, movingMin: 0, top: 400), // GPS glitch speed, no moving time
      ]);
      expect(a.rides, 3);
      expect(a.totalKm, closeTo(180, 1e-9));
      // 120 + 60 min moving + 2 h duration for the ride without moving time.
      expect(a.ridingMs, (180 + 120) * 60000);
      expect(a.longestKm, 100);
      expect(a.longestName, 'Coast run');
      expect(a.topSpeedKmh, 92, reason: 'impossible speeds are ignored');
      // (100 + 50) km over 3 h of moving time.
      expect(a.avgMovingKmh, closeTo(50, 1e-9));
    });

    test('group vs solo split', () {
      final a = run([
        ride('2026-11-03T04:00:00Z', 100, riders: 4),
        ride('2026-11-04T04:00:00Z', 20, riders: 1),
        ride('2026-11-05T04:00:00Z', 30, riders: 2),
      ]);
      expect(a.groupRides, 2);
      expect(a.soloRides, 1);
      expect(a.groupKm, 130);
      expect(a.soloKm, 20);
    });

    test('rides without a start time are skipped', () {
      final a = run([RideEntry(id: 'x', startMs: 0, endMs: 0, km: 10), ride('2026-11-03T04:00:00Z', 5)]);
      expect(a.rides, 1);
    });
  });

  group('months and weeks', () {
    test('this month vs last month, January rolls back to December', () {
      final jan = ms('2027-01-15T12:00:00Z');
      final a = run([
        ride('2027-01-03T04:00:00Z', 40),
        ride('2026-12-28T04:00:00Z', 60),
        ride('2026-12-01T04:00:00Z', 10),
        ride('2026-11-30T04:00:00Z', 999), // two months back: neither
      ], nowMs: jan);
      expect(a.thisMonth.rides, 1);
      expect(a.thisMonth.km, 40);
      expect(a.lastMonth.rides, 2);
      expect(a.lastMonth.km, 70);
    });

    test('a ride just after local midnight belongs to the local day (timezone)', () {
      // 18:45 UTC on Sunday 1 Nov = 00:15 IST on Monday 2 Nov.
      final r = ride('2026-11-01T18:45:00Z', 42);
      final utc = run([r]);
      final india = run([r], offset: ist);
      expect(utc.weeks.last.km, 0, reason: 'in UTC it is last week (Sunday)');
      expect(utc.weeks[10].km, 42);
      expect(india.weeks.last.km, 42, reason: 'in India it is this week (Monday)');
      expect(india.weeks[10].km, 0);
    });

    test('a ride at 01:30 IST on 1 Nov is this month in India, last month in UTC', () {
      final r = ride('2026-10-31T20:00:00Z', 25);
      expect(run([r], offset: ist).thisMonth.km, 25);
      expect(run([r]).lastMonth.km, 25);
      expect(run([r]).thisMonth.km, 0);
    });

    test('12 weeks, Monday starts, oldest first; older rides are not charted', () {
      final a = run([
        ride('2026-11-02T00:00:00Z', 10), // Monday of this week
        ride('2026-11-01T23:59:00Z', 20), // Sunday of last week
        ride('2026-08-17T08:00:00Z', 30), // Monday, 11 weeks back: first bar
        ride('2026-08-16T08:00:00Z', 40), // 12 weeks back: off the chart
      ]);
      expect(a.weeks.length, 12);
      expect((a.weeks.last.year, a.weeks.last.month, a.weeks.last.day), (2026, 11, 2));
      expect((a.weeks.first.year, a.weeks.first.month, a.weeks.first.day), (2026, 8, 17));
      expect(a.weeks.last.km, 10);
      expect(a.weeks[10].km, 20);
      expect(a.weeks.first.km, 30);
      expect(a.weeks.fold<double>(0, (s, w) => s + w.km), 60);
      expect(a.totalKm, 100, reason: 'totals still count every ride');
    });
  });

  group('streaks', () {
    test('three weekends in a row; this weekend not ridden yet does not break it', () {
      final a = run([
        ride('2026-10-31T05:00:00Z', 50), // Sat
        ride('2026-10-25T05:00:00Z', 50), // Sun
        ride('2026-10-17T05:00:00Z', 50), // Sat
        ride('2026-10-07T05:00:00Z', 50), // Wednesday: a weekday, not a weekend
      ]);
      expect(a.weekendStreak, 3);
      expect(a.streakText, '3 weekends in a row');
    });

    test('riding today extends the weekend streak; a gap ends it', () {
      final a = run([
        ride('2026-11-07T05:00:00Z', 50), // today, Saturday
        ride('2026-10-31T05:00:00Z', 50),
        // weekend of 24/25 Oct skipped
        ride('2026-10-17T05:00:00Z', 50),
        ride('2026-10-10T05:00:00Z', 50),
        ride('2026-10-03T05:00:00Z', 50),
      ]);
      expect(a.weekendStreak, 2);
      expect(a.bestWeekendStreak, 3);
    });

    test('week streak when weekends do not line up', () {
      final a = run([
        ride('2026-11-04T05:00:00Z', 10), // Wed this week
        ride('2026-10-28T05:00:00Z', 10), // Wed last week
        ride('2026-10-21T05:00:00Z', 10),
      ]);
      expect(a.weekendStreak, 0);
      expect(a.weekStreak, 3);
      expect(a.streakText, '3 weeks in a row');
    });

    test('a Sunday-night ride counts for the local weekend', () {
      // 19:00 UTC on Sunday 1 Nov is 00:30 IST Monday: no weekend in India.
      final r = ride('2026-11-01T19:00:00Z', 10);
      expect(run([r]).weekendStreak, 1);
      expect(run([r], offset: ist).weekendStreak, 0);
    });
  });

  group('safety and fuel', () {
    test('safety counts add up', () {
      final a = run([ride('2026-11-03T04:00:00Z', 10)], safety: const [
        RideSafetyEntry(groupId: 'G1', breaks: 2, alerts: 3),
        RideSafetyEntry(groupId: 'G2', breaks: 1, alerts: 0, sos: true),
        RideSafetyEntry(groupId: 'G3', crashCheck: true),
      ]);
      expect(a.safety.rides, 3);
      expect(a.safety.breaks, 3);
      expect(a.safety.alerts, 3);
      expect(a.safety.sosRides, 1);
      expect(a.safety.crashChecks, 1);
    });

    test('fuel used from mileage, cost only with a price', () {
      final rides = [ride('2026-11-03T04:00:00Z', 100), ride('2026-10-03T04:00:00Z', 60)];
      final noPrice = run(rides, fuel: const FuelInputs(kmPerUnit: 40, unit: 'L'));
      expect(noPrice.fuel!.usedTotal, closeTo(4, 1e-9));
      expect(noPrice.fuel!.usedThisMonth, closeTo(2.5, 1e-9));
      expect(noPrice.fuel!.costTotal, isNull);
      final priced = run(rides, fuel: const FuelInputs(kmPerUnit: 40, unit: 'L', pricePerUnit: 100));
      expect(priced.fuel!.costTotal, closeTo(400, 1e-9));
      expect(priced.fuel!.costThisMonth, closeTo(250, 1e-9));
      expect(run(rides, fuel: const FuelInputs(kmPerUnit: 0)).fuel, isNull);
    });
  });

  group('trip history inputs', () {
    TripHistoryModel trip({Map<String, num>? stats, String id = 'T1'}) => TripHistoryModel(
          tripId: id,
          tripName: 'Ride',
          startTimeEpochMs: ms('2026-11-03T04:00:00Z'),
          endTimeEpochMs: ms('2026-11-03T08:00:00Z'),
          totalDistanceKm: 120,
          topSpeedKmh: 95,
          avgSpeedKmh: 40,
          movingMs: 3 * hour,
          riderCount: 3,
          groupId: 'GRP-1',
          source: 'server',
          clientStats: stats,
        );

    test('the phone\'s own numbers come first', () {
      final e = RideAnalyticsInputs.entryOf(trip(stats: {'distanceM': 118400, 'movingMs': 2 * hour, 'maxKmh': 91, 'points': 900}));
      expect(e.fromPhone, isTrue);
      expect(e.km, closeTo(118.4, 1e-9));
      expect(e.movingMs, 2 * hour);
      expect(e.topKmh, 91);
      expect(e.riders, 3);
    });

    test('account history only when the phone has no numbers', () {
      final e = RideAnalyticsInputs.entryOf(trip());
      expect(e.fromPhone, isFalse);
      expect(e.km, 120);
      expect(e.movingMs, 3 * hour);
      expect(e.topKmh, 95);
      // A track too short to count is not "the phone's numbers".
      expect(RideAnalyticsInputs.entryOf(trip(stats: {'distanceM': 0, 'points': 1})).fromPhone, isFalse);
    });

    test('one entry per trip id', () {
      final list = RideAnalyticsInputs.entriesOf([trip(), trip(), trip(id: 'T2')]);
      expect(list.length, 2);
      final a = run(list);
      expect(a.fromAccount, 2);
      expect(a.fromPhone, 0);
    });
  });
}
