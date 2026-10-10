import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/core/config/app_config.dart';
import 'package:coroute_app/domain/notify/alert_priority.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/safety/crash_detector.dart';
import 'package:coroute_app/domain/tracking/ride_power_policy.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

void main() {
  group('Scenario C: Low Battery Critical Throttle', () {
    test('10% battery triggers power conservation with hysteresis (enters at <=15%, clears at >=20%)', () {
      final policy = RidePowerPolicy();
      expect(policy.conserving, isFalse);

      // Riding with battery depleting: 80% -> 40% -> 20% -> 16%
      policy.updateBattery(80, charging: false);
      expect(policy.conserving, isFalse);
      policy.updateBattery(20, charging: false);
      expect(policy.conserving, isFalse);
      policy.updateBattery(16, charging: false);
      expect(policy.conserving, isFalse);

      // Battery drops to 15%: enters conserving mode
      policy.updateBattery(15, charging: false);
      expect(policy.conserving, isTrue);

      // Critical drop to 10% during active ride
      policy.updateBattery(10, charging: false);
      expect(policy.conserving, isTrue);

      // Battery level fluctuations under load (10% -> 12% -> 14% -> 18%):
      // Hysteresis prevents rapid flapping of background telemetry timers!
      for (final pct in [10, 12, 14, 18]) {
        policy.updateBattery(pct, charging: false);
        expect(policy.conserving, isTrue, reason: 'Hysteresis keeps conserving active below 20%');
      }

      // Reaches 20% (e.g. regenerative downhill or charger connected): clears
      policy.updateBattery(20, charging: false);
      expect(policy.conserving, isFalse);

      // Charging immediately overrides conservation even at 5% battery
      policy.updateBattery(5, charging: false);
      expect(policy.conserving, isTrue);
      policy.updateBattery(5, charging: true);
      expect(policy.conserving, isFalse, reason: 'Charging resets power saving immediately');

      // Out-of-range sensor readings (<0 or >100) ignored safely
      policy.updateBattery(-10, charging: false);
      expect(policy.conserving, isFalse);
      policy.updateBattery(150, charging: false);
      expect(policy.conserving, isFalse);
    });

    test('Telemetry frequency halving: moving rate throttles to 5s, stationary to 30s', () {
      final policy = RidePowerPolicy();

      // Normal conditions: moving is 2.5s
      expect(
        policy.telemetryInterval(moving: true, lowData: false, critical: false),
        AppConfig.telemetryMinInterval, // 2500ms
      );

      // Battery drops to 10%
      policy.updateBattery(10, charging: false);
      expect(policy.conserving, isTrue);

      // Moving telemetry interval throttled to 5.0s (saving GPS radio power by 50%)
      expect(
        policy.telemetryInterval(moving: true, lowData: false, critical: false),
        const Duration(seconds: 5),
      );

      // Stopped at roadside (speed < 3 km/h): throttles to 30s stationary heartbeat
      expect(
        policy.telemetryInterval(moving: false, lowData: false, critical: false),
        AppConfig.telemetryIdleInterval, // 30s
      );

      // Non-critical notification refresh cadence slows down from 10s to 20s
      expect(policy.notificationInterval(critical: false), const Duration(seconds: 20));
    });

    test('Non-essential social discovery shutoff under low battery & safety events', () {
      // Product rule: Social discovery is shut off whenever safety events are active
      expect(AlertArbiter.socialAllowed(anyEmergency: false, anyAssist: false, anyHazard: false), isTrue);
      expect(AlertArbiter.socialAllowed(anyEmergency: true, anyAssist: false, anyHazard: false), isFalse);
      expect(AlertArbiter.socialAllowed(anyEmergency: false, anyAssist: true, anyHazard: false), isFalse);
      expect(AlertArbiter.socialAllowed(anyEmergency: false, anyAssist: false, anyHazard: true), isFalse);

      // Alert priority hierarchy: Emergency > Assist > Hazard > Group Safety > Route > Social
      expect(priorityForKey('SOS:ALERT1'), AlertPriority.sos);
      expect(priorityForKey('ASSIST:REQ1'), AlertPriority.assistRequest);
      expect(priorityForKey('HAZARD:H1'), AlertPriority.hazard);
      expect(priorityForKey('BATTERY:USR1'), AlertPriority.groupSafety);
      expect(priorityForKey('MEET:GRP1'), AlertPriority.social);

      // Battery warning notification is prioritized over social discovery
      final items = ['MEET:GRP1', 'BATTERY:USR1', 'SOS:ALERT1'];
      final arranged = AlertArbiter.arrange(items, (k) => priorityForKey(k));
      expect(arranged, ['SOS:ALERT1', 'BATTERY:USR1', 'MEET:GRP1']);
    });

    test('Critical override preserves high-rate telemetry & crash alarm monitoring at 10% battery', () {
      final policy = RidePowerPolicy()..updateBattery(10, charging: false);
      expect(policy.conserving, isTrue);

      // While battery is 10%, an emergency SOS or crash occurs in the convoy:
      // Critical override forces telemetry back to 2.5s high-frequency rate!
      expect(
        policy.telemetryInterval(moving: true, lowData: false, critical: true),
        AppConfig.telemetryMinInterval, // 2500ms
        reason: 'Critical active ride emergency overrides battery throttle',
      );
      expect(
        policy.telemetryInterval(moving: false, lowData: true, critical: true),
        AppConfig.telemetryMinInterval,
        reason: 'Stationary critical incident sends updates at 2.5s',
      );

      // Critical notification interval stays at rapid 10s cadence
      expect(policy.notificationInterval(critical: true), const Duration(seconds: 10));

      // Accelerometer CrashDetector runs independently without sampling loss:
      final detector = CrashDetector();

      // 1. Rider travelling at 60 km/h from t = 0 to t = 30s
      for (int s = 0; s <= 30; s++) {
        detector.onFix(TrackPoint(ts: s * 1000, lat: 12.9716, lng: 77.5946, speedKmh: 60, accuracyM: 5));
        detector.onAccel(AccelBucket(tMs: s * 1000, peakG: 1.5, meanG: 1.0, stdG: 0.3));
      }
      expect(detector.armedAt(30000), isTrue, reason: 'Crash detector armed above 25 km/h');

      // 2. High impact deceleration at t = 30s: 6.5 g spike (> 4.0 g threshold)
      detector.onAccel(AccelBucket(tMs: 30000, peakG: 6.5, meanG: 2.0, stdG: 1.5));
      expect(detector.evaluating, isTrue, reason: 'Evaluating crash candidate');

      // 3. Deceleration and stop within 4s: speed drops to 0 km/h at t = 34s
      detector.onFix(TrackPoint(ts: 31000, lat: 12.9720, lng: 77.5946, speedKmh: 40, accuracyM: 5));
      detector.onFix(TrackPoint(ts: 32000, lat: 12.9722, lng: 77.5946, speedKmh: 20, accuracyM: 5));
      detector.onFix(TrackPoint(ts: 34000, lat: 12.9723, lng: 77.5946, speedKmh: 0, accuracyM: 5));

      // 4. Rider remains down and still for 20 seconds (from t = 34s to t = 55s)
      CrashEvent? crashEvent;
      for (int s = 34; s <= 56; s++) {
        if (s % 2 == 0) {
          final ev = detector.onFix(TrackPoint(ts: s * 1000, lat: 12.9723, lng: 77.5946, speedKmh: 0, accuracyM: 5));
          if (ev != null) crashEvent = ev;
        }
        final ev = detector.onAccel(AccelBucket(tMs: s * 1000, peakG: 1.02, meanG: 1.0, stdG: 0.02));
        if (ev != null) crashEvent = ev;
      }

      // Crash is reliably detected despite phone running in 10% low battery throttle!
      expect(crashEvent, isNotNull);
      expect(crashEvent!.impactG, 6.5);
      expect(crashEvent.speedBeforeKmh, 60.0);
      expect(crashEvent.impactAtMs, 30000);
    });
  });
}
