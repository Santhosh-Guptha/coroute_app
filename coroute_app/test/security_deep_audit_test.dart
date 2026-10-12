import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/data/models/network_wire.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/safety_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/safety/fuel_profile.dart';
import 'package:coroute_app/domain/safety/fuel_range.dart';
import 'package:coroute_app/domain/tracking/dead_reckoning_engine.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

import 'safety_service_test.dart' show FakePort, FakeAccel, FakeSms, convoyWith, t0;

TrackPoint _pt(int sec, double lat, double lng, {double kmh = 60, double accM = 5}) =>
    TrackPoint(ts: t0 + sec * 1000, lat: lat, lng: lng, speedKmh: kmh, accuracyM: accM);

void main() {
  group('Security & Safety Invariants Audit: Fuel Properties', () {
    test('Safety Invariant: Usable fuel range is strictly bounded by theoretical range', () {
      const profile = FuelProfile(
        capacityL: 14.0,
        mileageKmL: 35.0,
        fullRangeKm: 490.0,
        reserveL: 2.0,
        bufferKm: 20.0,
      );
      expect(profile.valid, isTrue);

      final tracker = FuelRangeTracker();
      tracker.filledUp(t0);
      tracker.refuel(profile, t0, full: true);

      // Usable km must never exceed baseline - margin
      final usable = tracker.usableKm(profile);
      expect(usable, isNotNull);
      expect(usable!, lessThanOrEqualTo(profile.rangeKm));
      expect(usable, greaterThanOrEqualTo(0.0));

      // As distance increases, usableKm decays monotonically
      double prevUsable = usable;
      for (var i = 1; i <= 20; i++) {
        tracker.onFix(_pt(i * 30, 17.0 + i * 0.002, 78.0, kmh: 50));
        final nextUsable = tracker.usableKm(profile);
        expect(nextUsable, isNotNull);
        expect(nextUsable!, lessThanOrEqualTo(prevUsable));
        prevUsable = nextUsable;
      }
    });

    test('Numerical Robustness: Outlier and degenerate inputs do not compromise bounds', () {
      const profile = FuelProfile(
        capacityL: 15.0,
        mileageKmL: 30.0,
        fullRangeKm: 450.0,
        reserveL: 2.0,
        bufferKm: 20.0,
      );

      final tracker = FuelRangeTracker();
      tracker.refuel(profile, t0, full: true);

      // Extreme teleport fix (> 500m in short time) is rejected and marks tracker uncertain
      tracker.onFix(_pt(0, 17.0, 78.0));
      tracker.onFix(_pt(10, 17.05, 78.0)); // ~5.5 km in 10s: GPS glitch
      expect(tracker.uncertain, isTrue);

      // Fuel advice never produces optimistic recommendation when usableKm is degenerate
      expect(fuelAdvice(usableKm: -5, nextKm: 20, reliable: true), FuelAdvice.unknown);
      expect(fuelAdvice(usableKm: double.nan, nextKm: 20, reliable: true), FuelAdvice.unknown);
      expect(fuelAdvice(usableKm: double.infinity, nextKm: 20, reliable: true), FuelAdvice.unknown);
      expect(fuelAdvice(usableKm: 15, nextKm: 30, reliable: true), FuelAdvice.rangeRisk);
    });
  });

  group('Security & Safety Invariants Audit: Dead-Reckoning Tunnel & Crash', () {
    test('Tunnel Coasting: Decays velocity smoothly and halts on accelerometer impact', () {
      final engine = DeadReckoningEngine();
      final atal = DeadReckoningEngine.knownTunnels.firstWhere(
        (t) => t.name.contains('Atal'),
      );

      engine.setPlannedRoute([
        (atal.entryLat, atal.entryLng),
        (atal.exitLat, atal.exitLng),
      ]);

      // Enter Atal tunnel portal at 60 km/h
      engine.startCoasting(
        lat: atal.entryLat,
        lng: atal.entryLng,
        speedKmh: 60.0,
        heading: 0.0,
        timestampMs: t0,
      );

      expect(engine.isCoasting, isTrue);

      // 30 seconds into tunnel: coasting fix is calculated with degraded confidence
      final fix30 = engine.computeFix(t0 + 30000);
      expect(fix30.isCoasting, isTrue);
      expect(fix30.confidence, TrackingConfidence.tunnelCoasting);
      expect(fix30.speedKmh, lessThan(60.0));
      expect(fix30.speedKmh, greaterThan(0.0));

      // Sudden severe deceleration impact inside tunnel
      engine.checkAccelerometer(
        const AccelBucket(
          tMs: t0 + 35000,
          peakG: 4.8,
          meanG: 1.2,
          stdG: 0.05,
        ),
      );

      expect(engine.crashDetectedInTunnel, isTrue);

      // Compute fix after impact: must report crash stop
      final fixCrash = engine.computeFix(t0 + 40000);
      expect(fixCrash.isCrashStop, isTrue);
      expect(fixCrash.statusDescription, contains('Impact'));
    });
  });

  group('Security & Safety Invariants Audit: Emergency Monotonicity', () {
    test('EmergencyStatus: Strict terminal vs open partition', () {
      for (final st in EmergencyStatus.values) {
        if (st == EmergencyStatus.resolved ||
            st == EmergencyStatus.falseAlarm ||
            st == EmergencyStatus.cancelled ||
            st == EmergencyStatus.expired) {
          expect(st.isTerminal, isTrue, reason: '$st must be terminal');
          expect(st.isOpen, isFalse);
        } else {
          expect(st.isTerminal, isFalse, reason: '$st must be open');
          expect(st.isOpen, isTrue);
        }
      }
    });

    test('Crash Alarm: Countdown determinism and cancellation non-reversion', () async {
      SharedPreferences.setMockInitialValues({});
      var nowMs = t0;
      final port = FakePort(() => nowMs);
      final accel = FakeAccel();
      final sms = FakeSms();
      final settings = SettingsService();
      await settings.load();

      port.convoy = convoyWith({'me': RiderModel(userId: 'me', name: 'Kiran', lat: 17.0, lng: 78.0, lastSeenEpochMs: t0)});

      final service = SafetyService.forTest(
        port,
        settings,
        accel: accel,
        sms: sms,
        clock: () => nowMs,
      );

      // Trigger impact
      service.externalImpact(atMs: nowMs, g: 5.2, source: ExternalImpactSource.wearable);
      expect(service.alarm, isNotNull);
      expect(service.alarm!.sent, isFalse);

      // Calling alarmImOk before countdown dispatches suppresses SOS
      service.alarmImOk();
      expect(service.alarm, isNull);
      expect(port.raised, isEmpty);

      // Trigger second impact after safety cooldown (2 min) has expired
      nowMs += const Duration(minutes: 3).inMilliseconds;
      service.externalImpact(atMs: nowMs, g: 5.0, source: ExternalImpactSource.wearable);
      expect(service.alarm, isNotNull);

      service.alarmSendNow();
      expect(port.raised.length, 1);
      expect(service.alarm!.sent, isTrue);

      // User presses "I'm OK" after SOS was sent: closes UI alarm without revoking dispatched SOS
      service.alarmImOk();
      expect(service.alarm, isNull);
      expect(port.raised.length, 1, reason: 'Dispatched SOS cannot be silently cancelled');

      service.dispose();
      await port.fixes.close();
      port.dispose();
    });
  });
}
