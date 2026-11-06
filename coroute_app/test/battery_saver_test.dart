import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/tracking/battery_saver.dart';
import 'package:coroute_app/domain/tracking/location_cadence.dart';

void main() {
  group('BatterySaverPolicy (automatic at <= 20 %, or the rider switch)', () {
    test('turns on at 20 % and off again only at 25 % (hysteresis)', () {
      final p = BatterySaverPolicy();
      expect(p.update(percent: 80, charging: false, userOn: false), BatterySaverState.off);
      expect(p.update(percent: 21, charging: false, userOn: false).active, isFalse);
      final low = p.update(percent: 20, charging: false, userOn: false);
      expect(low.active, isTrue);
      expect(low.reason, BatterySaverReason.lowBattery);
      expect(low.label, 'Battery saver on (low battery)');
      expect(p.update(percent: 22, charging: false, userOn: false).active, isTrue, reason: 'no flapping around 20 %');
      expect(p.update(percent: 24, charging: false, userOn: false).active, isTrue);
      expect(p.update(percent: 25, charging: false, userOn: false).active, isFalse);
    });

    test('charging switches the automatic mode off at once', () {
      final p = BatterySaverPolicy();
      expect(p.update(percent: 10, charging: false, userOn: false).active, isTrue);
      expect(p.update(percent: 10, charging: true, userOn: false).active, isFalse);
      expect(p.autoEngaged, isFalse);
    });

    test('the rider switch wins at any level, even charging', () {
      final p = BatterySaverPolicy();
      final s = p.update(percent: 95, charging: true, userOn: true);
      expect(s.active, isTrue);
      expect(s.reason, BatterySaverReason.user);
      expect(s.label, 'Battery saver on');
    });

    test('an unknown level keeps the previous automatic state', () {
      final p = BatterySaverPolicy();
      p.update(percent: 15, charging: false, userOn: false);
      expect(p.update(percent: -1, charging: false, userOn: false).active, isTrue);
      p.reset();
      expect(p.update(percent: -1, charging: false, userOn: false).active, isFalse);
    });
  });

  group('BatterySaverProfile', () {
    const on = BatterySaverState(true, BatterySaverReason.user);
    const off = BatterySaverState.off;

    test('camera: 30 fps riding, 15 fps in battery saver, 0 when settled / background / screen off', () {
      expect(BatterySaverProfile.cameraFps(saver: false, foreground: true, screenOn: true, settled: false), 30);
      expect(BatterySaverProfile.cameraFps(saver: true, foreground: true, screenOn: true, settled: false), 15);
      expect(BatterySaverProfile.cameraFrame(saver: false, foreground: true, screenOn: true, settled: true), isNull);
      expect(BatterySaverProfile.cameraFrame(saver: false, foreground: false, screenOn: true, settled: false), isNull);
      expect(BatterySaverProfile.cameraFrame(saver: false, foreground: true, screenOn: false, settled: false), isNull);
    });

    test('GPS: the gentler low battery cadence, never navigation grade', () {
      expect(BatterySaverProfile.gpsLowBattery(on), isTrue);
      expect(BatterySaverProfile.gpsLowBattery(off), isFalse);
      final plan = LocationCadence.plan(SpeedBand.highway, idle: false, lowBattery: BatterySaverProfile.gpsLowBattery(on));
      expect(plan.precision, isNot(GpsPrecision.navigation));
      expect(plan.intervalMs, greaterThan(LocationCadence.normal[SpeedBand.highway]!.intervalMs));
    });

    test('telemetry slows down, but never during an emergency', () {
      expect(BatterySaverProfile.slowTelemetry(on, critical: false), isTrue);
      expect(BatterySaverProfile.slowTelemetry(on, critical: true), isFalse);
      expect(BatterySaverProfile.slowTelemetry(off, critical: false), isFalse);
      const base = Duration(seconds: 5); // data-saver base cadence
      expect(
        LocationCadence.telemetryInterval(SpeedBand.highway, base: base, moving: true, lowData: true),
        base,
        reason: 'battery saver uses the data-saver cadence: 5 s instead of 1 s on the highway',
      );
    });

    test('dark map and slower ride notification in battery saver', () {
      expect(BatterySaverProfile.forceDarkMap(on), isTrue);
      expect(BatterySaverProfile.forceDarkMap(off), isFalse);
      expect(BatterySaverProfile.notificationInterval(off), const Duration(seconds: 10));
      expect(BatterySaverProfile.notificationInterval(on), const Duration(seconds: 20));
    });
  });
}
