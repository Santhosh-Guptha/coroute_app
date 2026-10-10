import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/tracking/ride_power_policy.dart';

void main() {
  test('low battery enters at 15 and recovers at 20 without flapping', () {
    final p = RidePowerPolicy();
    p.updateBattery(16, charging: false); expect(p.conserving, false);
    p.updateBattery(15, charging: false); expect(p.conserving, true);
    for (final value in [16, 14, 17, 19]) {
      p.updateBattery(value, charging: false); expect(p.conserving, true);
    }
    p.updateBattery(20, charging: false); expect(p.conserving, false);
  });
  test('charging restores normal cadence and invalid readings do not change it', () {
    final p = RidePowerPolicy()..updateBattery(5, charging: false);
    p.updateBattery(200, charging: false); expect(p.conserving, true);
    p.updateBattery(5, charging: true); expect(p.conserving, false);
    p.updateBattery(-1, charging: false); expect(p.conserving, false);
  });
  test('stationary telemetry remains present with a thirty second heartbeat', () {
    final p = RidePowerPolicy();
    for (final lowData in [false, true]) {
      expect(p.telemetryInterval(moving: false, lowData: lowData, critical: false), const Duration(seconds: 30));
    }
  });
  test('moving cadence follows low data or low battery, critical activity overrides both', () {
    final p = RidePowerPolicy();
    expect(p.telemetryInterval(moving: true, lowData: false, critical: false), const Duration(milliseconds: 2500));
    expect(p.telemetryInterval(moving: true, lowData: true, critical: false), const Duration(seconds: 5));
    p.updateBattery(15, charging: false);
    expect(p.telemetryInterval(moving: true, lowData: false, critical: false), const Duration(seconds: 5));
    for (final moving in [false, true]) {
      expect(p.telemetryInterval(moving: moving, lowData: true, critical: true), const Duration(milliseconds: 2500));
    }
  });
  test('only noncritical notification refreshes slow down on low battery', () {
    final p = RidePowerPolicy();
    expect(p.notificationInterval(critical: false), const Duration(seconds: 10));
    p.updateBattery(10, charging: false);
    expect(p.notificationInterval(critical: false), const Duration(seconds: 20));
    expect(p.notificationInterval(critical: true), const Duration(seconds: 10));
  });
}
