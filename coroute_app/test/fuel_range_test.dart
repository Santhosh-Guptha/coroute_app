import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/stop_point_model.dart';
import 'package:coroute_app/data/services/safety_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/domain/safety/fuel_range.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

import 'safety_service_test.dart' show FakePort, FakeAccel, FakeSms, t0;

/// About 1 km north per 0.009 degrees of latitude.
TrackPoint at(int s, double km, {double kmh = 50}) => TrackPoint(ts: t0 + s * 1000, lat: 17.0 + km * 0.009, lng: 78.0, speedKmh: kmh);

void main() {
  group('FuelRangeTracker', () {
    test('sums the distance between consecutive fixes', () {
      final t = FuelRangeTracker();
      for (var i = 0; i <= 10; i++) {
        t.onFix(at(i * 60, i * 0.25)); // 250 m per minute
      }
      expect(t.riddenM, closeTo(2500, 30));
    });

    test('skips a jump over 500 m and a gap over 5 min (GPS teleports, restarts)', () {
      final t = FuelRangeTracker();
      t.onFix(at(0, 0));
      t.onFix(at(10, 0.2));
      expect(t.riddenM, closeTo(200, 5));
      t.onFix(at(20, 3.0)); // 2.8 km in 10 s: a teleport
      expect(t.riddenM, closeTo(200, 5));
      t.onFix(at(30, 3.2));
      expect(t.riddenM, closeTo(400, 8), reason: 'counting goes on from the new place');
      t.onFix(at(30 + 6 * 60, 3.4)); // 6 min later, 200 m: a gap
      expect(t.riddenM, closeTo(400, 8));
      t.onFix(at(30 + 6 * 60 + 10, 3.6));
      expect(t.riddenM, closeTo(600, 12));
    });

    test('warns once per fill at 80% of the range; "Filled up" resets', () {
      final t = FuelRangeTracker();
      expect(t.shouldWarn(0), isFalse, reason: 'off');
      var s = 0;
      var km = 0.0;
      while (km < 7.9) {
        t.onFix(at(s, km));
        s += 10;
        km += 0.1;
      }
      expect(t.shouldWarn(10), isFalse, reason: '${t.riddenM.round()} m is under 8 km');
      t.onFix(at(s, 8.1));
      expect(t.shouldWarn(10), isTrue);
      expect(t.shouldWarn(10), isFalse, reason: 'once per fill');
      t.onFix(at(s + 10, 9.0));
      expect(t.shouldWarn(10), isFalse);
      t.filledUp(t0 + (s + 20) * 1000);
      expect(t.riddenM, 0);
      expect(t.lastFillAt, t0 + (s + 20) * 1000);
      expect(t.shouldWarn(10), isFalse);
      t.onFix(at(s + 30, 9.0));
      t.onFix(at(s + 40, 9.3));
      expect(t.riddenM, closeTo(300, 6), reason: 'the count starts again from the fill');
    });

    test('round-trips through JSON', () {
      final t = FuelRangeTracker();
      t.onFix(at(0, 0));
      t.onFix(at(10, 0.4));
      t.filledUp(t0);
      t.onFix(at(20, 0.6));
      t.onFix(at(30, 0.9));
      final back = FuelRangeTracker.fromJson(t.toJson())!;
      expect(back.riddenM, closeTo(t.riddenM, 1));
      expect(back.lastFillAt, t0);
      expect(back.warned, isFalse);
      back.onFix(at(40, 1.0));
      expect(back.riddenM, closeTo(t.riddenM + 100, 3), reason: 'continues from the saved last fix');
      expect(FuelRangeTracker.fromJson(null), isNull);
      expect(FuelRangeTracker.fromJson({'x': 1}), isNull);
    });
  });

  group('fuel reminder through SafetyService', () {
    late int now;
    late FakePort port;
    late SafetyService safety;
    late SettingsService settings;

    ConvoyModel convoy({List<StopPointModel> stops = const []}) => ConvoyModel(
          groupId: 'G',
          name: 'Ride',
          joinCode: '123456',
          createdByUserId: 'lead',
          createdByUserName: 'Lead',
          createdAtEpochMs: t0,
          tripStatus: 'STARTED',
          riders: {'me': RiderModel(userId: 'me', name: 'Kiran', lat: 17, lng: 78, lastSeenEpochMs: t0)},
          stopPoints: stops,
        );

    Future<void> start(WidgetTester tester, {Map<String, Object> prefs = const {}, int rangeKm = 10}) async {
      SharedPreferences.setMockInitialValues(prefs);
      now = t0;
      port = FakePort(() => now);
      settings = SettingsService();
      await settings.load();
      await settings.setFuelRangeKm(rangeKm);
      safety = SafetyService.forTest(port, settings, accel: FakeAccel(), sms: FakeSms(), clock: () => now);
      port.convoy = convoy();
      port.changed();
      await tester.pump();
    }

    Future<void> ride(WidgetTester tester, {required double fromKm, required double toKm, int fromS = 0}) async {
      var s = fromS;
      for (var km = fromKm; km <= toKm + 0.001; km += 0.1) {
        now = t0 + s * 1000;
        port.fixes.add(at(s, km));
        await tester.pump();
        s += 10;
      }
    }

    Future<void> end(WidgetTester tester) async {
      safety.dispose();
      await port.fixes.close();
      port.dispose();
      await tester.pump();
    }

    testWidgets('prompt at 80% of the range, once; "Filled up" resets the count', (tester) async {
      await start(tester);
      await ride(tester, fromKm: 0, toKm: 7.9);
      expect(safety.prompts, isEmpty);
      expect(safety.riddenSinceFillM, closeTo(7900, 100));
      await ride(tester, fromKm: 8.0, toKm: 8.3, fromS: 800);
      expect(safety.prompts.map((p) => p.key), [SafetyConstants.promptFuel]);
      final p = safety.prompts.single;
      expect(p.title, 'Fuel soon');
      expect(p.message, contains('8 km'));
      expect(p.message, contains('10 km'));
      expect(p.secondaryLabel, 'Filled up');
      expect(safety.fuelReminderActive, isTrue);
      safety.answerPrompt(SafetyConstants.promptFuel, primary: false);
      expect(safety.prompts, isEmpty);
      expect(safety.riddenSinceFillM, 0);
      await ride(tester, fromKm: 8.4, toKm: 9.5, fromS: 840);
      expect(safety.prompts, isEmpty, reason: 'counting again from the fill');
      await end(tester);
    });

    testWidgets('arriving at a FUEL stop never assumes refuelling', (tester) async {
      await start(tester);
      await ride(tester, fromKm: 0, toKm: 5.0);
      expect(safety.riddenSinceFillM, greaterThan(4500));
      final arrivedAt = t0 + 600 * 1000;
      port.convoy = convoy(stops: [
        StopPointModel(stopId: 'f1', name: 'HP pump', lat: 17.04, lng: 78, category: 'FUEL', arrivals: {'me': StopArrival(arrivedAt: arrivedAt)}),
      ]);
      port.changed();
      await tester.pump();
      expect(safety.riddenSinceFillM, greaterThan(4500));
      port.changed();
      await tester.pump();
      expect(safety.riddenSinceFillM, greaterThan(4500), reason: 'only explicit confirmation resets fuel');
      await end(tester);
    });

    testWidgets('the count survives a restart of the app in the same ride', (tester) async {
      await start(tester);
      await ride(tester, fromKm: 0, toKm: 3.0);
      expect(safety.riddenSinceFillM, closeTo(3000, 60));
      await end(tester);
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(SafetyConstants.keyFuelState);
      expect(saved, isNotNull);
      expect(saved, contains('"g":"G"'));

      // A new service for the same group picks the count up.
      port = FakePort(() => now);
      safety = SafetyService.forTest(port, settings, accel: FakeAccel(), sms: FakeSms(), clock: () => now);
      port.convoy = convoy();
      port.changed();
      await tester.pump();
      await tester.pump();
      expect(safety.riddenSinceFillM, closeTo(3000, 60));
      await end(tester);

      // Another group starts from zero.
      port = FakePort(() => now);
      safety = SafetyService.forTest(port, settings, accel: FakeAccel(), sms: FakeSms(), clock: () => now);
      port.convoy = convoy().copyWith(groupId: 'H');
      port.changed();
      await tester.pump();
      await tester.pump();
      expect(safety.riddenSinceFillM, 0);
      await end(tester);
    });

    testWidgets('range 0: no reminder', (tester) async {
      await start(tester, rangeKm: 0);
      await ride(tester, fromKm: 0, toKm: 9.5);
      expect(safety.prompts, isEmpty);
      await end(tester);
    });
  });
}
