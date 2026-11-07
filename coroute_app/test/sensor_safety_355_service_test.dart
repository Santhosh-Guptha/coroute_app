// 3.55 sensor safety wiring: the SOS battery reserve controller, the sensor safety hub (crash
// learning applied to the detector, switches, mount card, rider-down rest) and RideStats'
// backward-compatible safety summary.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/data/local/ride_stats_store.dart';
import 'package:coroute_app/data/services/sensor_safety_hub.dart';
import 'package:coroute_app/data/services/sos_battery_reserve.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/safety/crash_detector.dart';
import 'package:coroute_app/domain/safety/crash_incident.dart';
import 'package:coroute_app/domain/safety/ride_safety_summary.dart';
import 'package:coroute_app/domain/safety/sos_battery_reserve_policy.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';
import 'package:coroute_app/presentation/report/ride_safety_summary_card.dart';

const int t0 = 1700000000000;

SosReserveInputs inputs(int pct, {bool charging = false, bool ride = true, String key = 'g1', double lat = 12.9}) =>
    SosReserveInputs(batteryPercent: pct, charging: charging, rideActive: ride, rideKey: key, lat: lat, lng: 77.5, speedKmh: 30);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('SosBatteryReserve controller', () {
    test('switches on below 10%, pauses heavy work and sends the last location once', () {
      final sent = <Map<String, dynamic>>[];
      final pauses = <bool>[];
      final r = SosBatteryReserve()
        ..sendMessage = (m) {
          sent.add(m);
          return true;
        }
        ..onHeavyWorkPause = pauses.add;
      expect(r.update(inputs(12)), SosReserveChange.none);
      expect(r.update(inputs(9)), SosReserveChange.entered);
      expect(r.active, isTrue);
      expect(r.showCard, isTrue);
      expect(pauses, [true]);
      expect(sent.length, 1);
      expect(sent.single['type'], 'LAST_GASP_BEACON');
      expect(sent.single['batteryLevel'], 9);
      r.update(inputs(8));
      expect(sent.length, 1);
      r.dismissCard();
      expect(r.showCard, isFalse);
      expect(r.update(inputs(16)), SosReserveChange.exited);
      expect(pauses, [true, false]);
      r.update(inputs(9));
      expect(sent.length, 1); // same ride: once
    });

    test('a failed send is tried again on the next update; no position waits', () {
      var ok = false;
      var calls = 0;
      final r = SosBatteryReserve()
        ..sendMessage = (m) {
          calls++;
          return ok;
        };
      r.update(inputs(9, lat: 0).copyNoPos());
      expect(calls, 0);
      r.update(inputs(9));
      expect(calls, 1);
      expect(r.beaconSent, isFalse);
      ok = true;
      r.update(inputs(9));
      expect(calls, 2);
      expect(r.beaconSent, isTrue);
    });

    test('the admin switch off keeps it off', () {
      final r = SosBatteryReserve()..featureOn = (id) => id != 'sosBatteryReserve';
      expect(r.update(inputs(5)), SosReserveChange.none);
      expect(r.active, isFalse);
    });
  });

  group('SensorSafetyHub', () {
    test('false alarms raise this bike\'s learned scales on the detector; switch off restores the rule', () async {
      final d = CrashDetector();
      final hub = SensorSafetyHub(bikeId: () => 'bike-1', persist: false, clock: () => t0);
      await hub.loadLearning(d);
      hub.onFalseAlarm(CrashScenario.stationaryDrop);
      expect(d.lowFallScale, closeTo(1.05, 1e-9));
      expect(d.slideScale, 1.0);
      hub.onFalseAlarm(CrashScenario.highImpactCollision); // severe: never
      expect(hub.learning.falseAlarms, 1);
      hub.featureOn = (id) => id != 'crashLearning';
      await hub.loadLearning(d);
      expect(d.lowFallScale, 1.0);
      hub.featureOn = null;
      await hub.resetLearning();
      expect(hub.learning.falseAlarms, 0);
    });

    test('learning is stored per bike and survives a restart', () async {
      final d = CrashDetector();
      final hub = SensorSafetyHub(bikeId: () => 'bike-2');
      await hub.loadLearning(d);
      hub.onFalseAlarm(CrashScenario.lowsideSlide);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final s = await CrashLearningStore.load('bike-2');
      expect(s.slidePct, 5);
      expect((await CrashLearningStore.load('default')).isEmpty, isTrue);
      final hub2 = SensorSafetyHub(bikeId: () => 'bike-2');
      final d2 = CrashDetector();
      await hub2.loadLearning(d2);
      expect(d2.slideScale, closeTo(1.05, 1e-9));
    });

    test('fatigueLevel is 0 with the switch off', () {
      final hub = SensorSafetyHub(persist: false, clock: () => t0);
      for (var m = 0; m <= 100; m++) {
        hub.onFix(TrackPoint(ts: t0 + m * 60000, lat: 12.9, lng: 77.5, speedKmh: 50), stretchStart: t0);
      }
      expect(hub.fatigueLevel > 0, isTrue);
      hub.featureOn = (id) => id != 'fatigueScore';
      expect(hub.fatigueLevel, 0);
      expect(hub.earlyFatigueDue(nowMs: t0 + 100 * 60000, stretchStart: t0), isFalse);
    });

    test('the rider-down check rests while the crash detector is busy', () {
      final hub = SensorSafetyHub(persist: false, clock: () => t0);
      hub.onFix(const TrackPoint(ts: t0, lat: 12.9, lng: 77.5, speedKmh: 1));
      for (var s = 0; s < 5; s++) {
        hub.onAccel(AccelBucket(tMs: t0 + s * 1000, peakG: 1, meanG: 1, stdG: 0.02, tiltDeg: 3), crashBusy: false, emergency: false);
      }
      hub.onAccel(const AccelBucket(tMs: t0 + 5000, peakG: 1.3, meanG: 1, stdG: 0.3, tiltDeg: 35, peakGyroRadS: 2), crashBusy: true, emergency: false);
      hub.onAccel(const AccelBucket(tMs: t0 + 6000, peakG: 2.2, meanG: 1, stdG: 0.3, tiltDeg: 80, peakGyroRadS: 1.5), crashBusy: true, emergency: false);
      expect(hub.wantsSensor, isFalse);
    });

    test('summary counts alarms and road hazards', () {
      final hub = SensorSafetyHub(persist: false, clock: () => t0);
      hub.onAlarmOpened(riderDownCheck: true);
      hub.onAlarmOpened(riderDownCheck: false);
      hub.onRoadHazard();
      final s = hub.buildSummary(hardBrakes: 3, breaks: 1);
      expect(s.bikeDownChecks, 1);
      expect(s.crashAlarms, 1);
      expect(s.roadHazards, 1);
      expect(s.hardBrakes, 3);
    });
  });

  group('RideStats safety summary', () {
    test('old entries load without a summary; new ones round-trip', () {
      final old = RideStats.fromJson('g', {'h': 2, 'e': 5});
      expect(old!.safety, isNull);
      final s = RideStats(groupId: 'g', hardStops: 2, endedAt: 5, safety: const RideSafetySummary(nightKm: 12.3, overLimitMin: 4));
      final back = RideStats.fromJson('g', s.toJson())!;
      expect(back.safety!.nightKm, closeTo(12.3, 1e-9));
      expect(back.safety!.overLimitMin, 4);
      expect(RideStats(groupId: 'g', hardStops: 0, endedAt: 1, safety: const RideSafetySummary()).toJson().containsKey('sf'), isFalse);
    });
  });

  testWidgets('Safety summary card lists the private numbers', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: RideSafetySummaryCard(summary: RideSafetySummary(hardBrakes: 2, overLimitMin: 3, bikeDownChecks: 1))),
    ));
    expect(find.text(RideSafetySummaryCard.title), findsOneWidget);
    expect(find.text('3 minutes'), findsOneWidget);
    expect(find.text('"Bike down?" checks'), findsOneWidget);
    expect(find.text(RideSafetySummaryCard.hint), findsOneWidget);
  });
}

extension on SosReserveInputs {
  SosReserveInputs copyNoPos() => SosReserveInputs(batteryPercent: batteryPercent, charging: charging, rideActive: rideActive, rideKey: rideKey);
}
