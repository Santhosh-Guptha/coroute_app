import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/tracking/adaptive_position_rate.dart';

// Round 8 adaptive position rate (pure Dart: tool/pure_dart_test/run.sh test/rt8_adaptive_position_rate_test.dart).
void main() {
  PositionContext ctx(double kmh,
          {bool parked = false,
          bool lowData = false,
          bool critical = false,
          bool sos = false,
          bool lead = false,
          int group = 6,
          double heading = 0}) =>
      PositionContext(
        speedKmh: kmh,
        headingDeg: heading,
        moving: kmh >= 3,
        parked: parked,
        lowData: lowData,
        critical: critical,
        ownSos: sos,
        leadOrSweep: lead,
        groupSize: group,
      );
  int ms(PositionContext c) => AdaptivePositionRate.interval(c).inMilliseconds;

  group('cadence by speed', () {
    test('about 1 s above 60 km/h, 2.5 s in town, 5 s slow, 10 s stopped, 30 s parked', () {
      expect(ms(ctx(95)), 1000);
      expect(ms(ctx(61)), 1000);
      expect(ms(ctx(45)), 2500);
      expect(ms(ctx(15)), 2500);
      expect(ms(ctx(8)), 5000);
      expect(ms(ctx(0)), 10000);
      expect(ms(ctx(0, parked: true)), 30000);
    });
    test('data saver / battery doubles it (at most 10 s moving, 30 s stopped), never below 1 s', () {
      expect(ms(ctx(95, lowData: true)), 2000);
      expect(ms(ctx(45, lowData: true)), 5000);
      expect(ms(ctx(8, lowData: true)), 10000);
      expect(ms(ctx(0, lowData: true)), 20000);
      expect(ms(ctx(0, parked: true, lowData: true)), 30000);
    });
    test('own SOS: 1 s always, even in data saver, parked or in a big group', () {
      expect(ms(ctx(0, sos: true)), 1000);
      expect(ms(ctx(0, parked: true, lowData: true, sos: true, group: 80)), 1000);
    });
    test('lead / sweeper: at most 2.5 s moving and 5 s stopped', () {
      expect(ms(ctx(8, lead: true)), 2500);
      expect(ms(ctx(0, lead: true)), 5000);
      expect(ms(ctx(95, lead: true)), 1000);
      expect(ms(ctx(8, lead: true, lowData: true)), 2500);
    });
    test('group alert keeps normal cadence: data saver never slows it', () {
      expect(ms(ctx(8, critical: true, lowData: true)), 2500);
      expect(ms(ctx(0, critical: true, parked: true)), 5000);
    });
    test('big groups are held back (fan-out)', () {
      expect(ms(ctx(95, group: 30)), 2000);
      expect(ms(ctx(95, group: 60)), 2500);
      expect(ms(ctx(0, group: 60)), 10000);
    });
  });

  group('send decisions', () {
    test('first fix at once, then by interval; never closer than the 1 s floor', () {
      final r = AdaptivePositionRate();
      var t = 0;
      expect(r.shouldSend(ctx(45), t), isTrue);
      r.noteSent(t, speedKmh: 45, headingDeg: 0);
      expect(r.shouldSend(ctx(45), t + 2000), isFalse);
      expect(r.shouldSend(ctx(45), t + 2500), isTrue);
      t = 2500;
      r.noteSent(t, speedKmh: 45, headingDeg: 0);
      expect(r.shouldSend(ctx(45, heading: 90), t + 500), isFalse, reason: 'a sharp turn still waits for the floor');
      expect(r.shouldSend(ctx(45, heading: 90), t + 1000), isTrue, reason: 'sharp turn at once');
    });
    test('sharp turn only when moving fast enough; heading wraps around north', () {
      final r = AdaptivePositionRate()..noteSent(0, speedKmh: 40, headingDeg: 350);
      expect(r.immediateReason(ctx(40, heading: 15)), isNull, reason: '25 degrees');
      expect(r.immediateReason(ctx(40, heading: 25)), 'turn');
      expect(r.immediateReason(ctx(10, heading: 90)), isNull, reason: 'walking pace');
    });
    test('sharp stop, moving off, SOS and becoming lead go out at once', () {
      final r = AdaptivePositionRate()..noteSent(0, speedKmh: 50, headingDeg: 0);
      expect(r.immediateReason(ctx(0)), 'stop');
      expect(r.shouldSend(ctx(0), 1200), isTrue);
      r.noteSent(1200, speedKmh: 0, headingDeg: 0);
      expect(r.immediateReason(ctx(12)), 'start');
      r.noteSent(2400, speedKmh: 12, headingDeg: 0);
      expect(r.immediateReason(ctx(12, lead: true)), 'role');
      expect(r.immediateReason(ctx(12, sos: true)), 'sos');
      expect(r.shouldSend(ctx(12, sos: true), 2500), isTrue, reason: 'an SOS opening skips even the floor');
      r.noteSent(2500, speedKmh: 12, headingDeg: 0, ownSos: true, leadOrSweep: true);
      expect(r.immediateReason(ctx(12, sos: true, lead: true)), isNull, reason: 'only on the change');
    });
    test('stopped rider: one fix every 10 s instead of a constant stream', () {
      final r = AdaptivePositionRate();
      var sent = 0;
      for (var t = 0; t <= 60000; t += 1000) {
        if (r.shouldSend(ctx(0), t)) {
          sent++;
          r.noteSent(t, speedKmh: 0, headingDeg: 0);
        }
      }
      expect(sent, 7);
    });
    test('message budget for a typical ride mix is lower than a fixed 2.5 s', () {
      // 10 min: 3 highway, 4 town, 1 slow, 2 stopped (one fix a second from the GPS).
      final r = AdaptivePositionRate();
      var sent = 0;
      var t = 0;
      void ride(double kmh, int minutes) {
        for (var i = 0; i < minutes * 60; i++, t += 1000) {
          if (r.shouldSend(ctx(kmh), t)) {
            sent++;
            r.noteSent(t, speedKmh: kmh, headingDeg: 0);
          }
        }
      }
      ride(90, 3);
      ride(40, 4);
      ride(8, 1);
      ride(0, 2);
      expect(sent, lessThan(10 * 60 * 1000 ~/ 2500 + 200)); // fixed 2.5 s = 240 + highway at 1 s
      expect(sent, greaterThan(250)); // highway keeps 1 s
    });
  });
}
