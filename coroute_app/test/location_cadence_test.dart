import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/tracking/location_cadence.dart';

void main() {
  group('speed band selection', () {
    test('moves up after the dwell and down only well below the boundary', () {
      final t = SpeedBandTracker();
      expect(t.band, SpeedBand.stopped);
      expect(t.update(25, 0), isFalse);
      expect(t.update(25, 2000), isTrue);
      expect(t.band, SpeedBand.city);
      // 45 km/h for 2 s: open road.
      t.update(45, 3000);
      expect(t.update(45, 5000), isTrue);
      expect(t.band, SpeedBand.road);
      // Hovering at 38-41 never thrashes (down needs < 36 for 6 s).
      for (var ms = 6000; ms < 30000; ms += 500) {
        expect(t.update((ms ~/ 500).isEven ? 38 : 41, ms), isFalse);
      }
      expect(t.band, SpeedBand.road);
      t.update(30, 30000);
      expect(t.update(30, 35999), isFalse);
      expect(t.update(30, 36000), isTrue);
      expect(t.band, SpeedBand.city);
    });

    test('highway band from 81 km/h', () {
      final t = SpeedBandTracker(upDwellMs: 0);
      t.update(120, 0);
      expect(t.band, SpeedBand.highway);
      t.reset();
      expect(t.band, SpeedBand.stopped);
    });
  });

  group('cadence plans', () {
    test('faster bands report more often and more precisely', () {
      final stopped = LocationCadence.plan(SpeedBand.stopped, idle: false);
      final city = LocationCadence.plan(SpeedBand.city, idle: false);
      final road = LocationCadence.plan(SpeedBand.road, idle: false);
      final highway = LocationCadence.plan(SpeedBand.highway, idle: false);
      expect(stopped, const CadencePlan(2000, 0, GpsPrecision.high));
      expect(city, const CadencePlan(1000, 0, GpsPrecision.navigation));
      expect(road, const CadencePlan(1000, 0, GpsPrecision.navigation));
      expect(highway, const CadencePlan(500, 0, GpsPrecision.navigation));
    });

    test('low battery relaxes every band and parked wins over speed', () {
      for (final b in SpeedBand.values) {
        final n = LocationCadence.plan(b, idle: false);
        final l = LocationCadence.plan(b, idle: false, lowBattery: true);
        expect(l.intervalMs, greaterThan(n.intervalMs));
        // Riding never uses a distance filter (speed readout, overspeed check, stop -> 0).
        expect(l.distanceFilterM, 0);
        expect(n.distanceFilterM, 0);
        expect(l.precision, isNot(GpsPrecision.navigation));
        // Battery saver may slow the GPS, but never below a fix every 2 s once moving.
        if (b != SpeedBand.stopped) expect(l.intervalMs, lessThanOrEqualTo(2000));
      }
      expect(LocationCadence.plan(SpeedBand.highway, idle: true), LocationCadence.idle);
      expect(LocationCadence.plan(SpeedBand.highway, idle: true, lowBattery: true), LocationCadence.idleLowBattery);
    });
  });

  group('telemetry cadence', () {
    const base = Duration(milliseconds: 2500);
    test('follows speed but never under the 1 s floor (gateway allows 3/s)', () {
      expect(LocationCadence.telemetryInterval(SpeedBand.stopped, base: base, moving: true), base);
      expect(LocationCadence.telemetryInterval(SpeedBand.city, base: base, moving: true), const Duration(seconds: 2));
      expect(LocationCadence.telemetryInterval(SpeedBand.road, base: base, moving: true), const Duration(milliseconds: 1500));
      expect(LocationCadence.telemetryInterval(SpeedBand.highway, base: base, moving: true), const Duration(seconds: 1));
    });

    test('data saver, parked and big groups stay slow', () {
      expect(LocationCadence.telemetryInterval(SpeedBand.highway, base: const Duration(seconds: 5), moving: true, lowData: true),
          const Duration(seconds: 5));
      expect(LocationCadence.telemetryInterval(SpeedBand.highway, base: const Duration(seconds: 30), moving: false),
          const Duration(seconds: 30));
      expect(LocationCadence.telemetryInterval(SpeedBand.highway, base: base, moving: true, groupSize: 30),
          const Duration(seconds: 2));
      expect(LocationCadence.telemetryInterval(SpeedBand.highway, base: base, moving: true, groupSize: 60), base);
    });
  });
}
