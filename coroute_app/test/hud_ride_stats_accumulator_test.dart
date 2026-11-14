// Round 11 ride HUD: "Ride so far" and "Distance by speed" (lib/domain/ride/ride_stats_accumulator.dart).
//   DART=/opt/dartpkg/bin/dart tool/pure_dart_test/run.sh test/hud_ride_stats_accumulator_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/ride/ride_stats_accumulator.dart';

/// Metres per degree of latitude (haversine with R = 6371 km).
const double mPerDegLat = 111194.93;

/// Feeds a straight run north at [kmh] for [seconds], one fix a second, from [startLat].
/// Returns the latitude reached.
double ride(RideStatsAccumulator a, {required int startTs, required double startLat, required double kmh, required int seconds, int limitKmh = 0, double accuracyM = 5}) {
  var lat = startLat;
  final stepM = kmh / 3.6;
  for (var i = 1; i <= seconds; i++) {
    lat += stepM / mPerDegLat;
    a.onFix(ts: startTs + i * 1000, lat: lat, lng: 77.0, speedKmh: kmh, accuracyM: accuracyM, limitKmh: limitKmh);
  }
  return lat;
}

void main() {
  group('distance and bands', () {
    test('steady 50 km/h for 72 s: 1 km, all in the 40-60 band, avg 50, peak 50', () {
      final a = RideStatsAccumulator();
      a.onFix(ts: 0, lat: 12.0, lng: 77.0, speedKmh: 50, accuracyM: 5);
      ride(a, startTs: 0, startLat: 12.0, kmh: 50, seconds: 72);
      expect(a.distanceM, closeTo(1000, 5));
      expect(a.movingMs, 72000);
      expect(a.avgMovingKmh, closeTo(50, 0.5));
      expect(a.peakKmh, closeTo(50, 0.01));
      final b = a.bands(SpeedBandProfile.motorcycle);
      expect(b.map((x) => x.label).toList(), ['< 40', '40-60', '60-80', '80-100', '100+']);
      expect(b[1].distanceM, closeTo(1000, 5));
      expect(b[1].shareOf(a.distanceM), closeTo(1.0, 0.001));
      expect(b[0].distanceM + b[2].distanceM + b[3].distanceM + b[4].distanceM, 0);
    });

    test('mixed speeds land in their bands; shares add up to 1', () {
      final a = RideStatsAccumulator();
      a.onFix(ts: 0, lat: 12.0, lng: 77.0, speedKmh: 30, accuracyM: 5);
      var lat = ride(a, startTs: 0, startLat: 12.0, kmh: 30, seconds: 60);
      lat = ride(a, startTs: 60000, startLat: lat, kmh: 70, seconds: 60);
      ride(a, startTs: 120000, startLat: lat, kmh: 110, seconds: 60);
      final b = a.bands(SpeedBandProfile.motorcycle);
      // Transitions are averaged (30/70 -> 50) for one second each: small spill into 40-60 / 80-100.
      expect(b[0].distanceM, closeTo(30 / 3.6 * 59, 30));
      expect(b[2].distanceM, closeTo(70 / 3.6 * 59, 30));
      expect(b[4].distanceM, closeTo(110 / 3.6 * 59, 30));
      final total = b.fold<double>(0, (s, x) => s + x.shareOf(a.distanceM));
      expect(total, closeTo(1.0, 0.0001));
    });

    test('band edges follow the vehicle profile without losing distance', () {
      expect(SpeedBandProfile.forVehicle('scooter'), SpeedBandProfile.scooter);
      expect(SpeedBandProfile.forVehicle('electric'), SpeedBandProfile.scooter);
      expect(SpeedBandProfile.forVehicle('sport'), SpeedBandProfile.touring);
      expect(SpeedBandProfile.forVehicle(''), SpeedBandProfile.motorcycle);
      expect(SpeedBandProfile.forVehicle('cruiser'), SpeedBandProfile.motorcycle);
      final a = RideStatsAccumulator();
      a.onFix(ts: 0, lat: 12.0, lng: 77.0, speedKmh: 25, accuracyM: 5);
      ride(a, startTs: 0, startLat: 12.0, kmh: 25, seconds: 100);
      final scooter = a.bands(SpeedBandProfile.scooter);
      expect(scooter.first.label, '< 20');
      expect(scooter[1].label, '20-40');
      expect(scooter[1].distanceM, closeTo(a.distanceM, 0.01));
      expect(a.bands(SpeedBandProfile.touring).last.label, '120+');
      expect(a.bands(SpeedBandProfile.touring).fold<double>(0, (s, x) => s + x.distanceM), closeTo(a.distanceM, 0.01));
    });
  });

  group('GPS jitter (round 6 rules)', () {
    test('parked with jitter: no distance, no moving time, one stop only after moving', () {
      final a = RideStatsAccumulator();
      a.onFix(ts: 0, lat: 12.0, lng: 77.0, speedKmh: 0, accuracyM: 12);
      for (var i = 1; i <= 300; i++) {
        final j = (i.isEven ? 8 : -8) / mPerDegLat; // 8 m back and forth
        a.onFix(ts: i * 1000, lat: 12.0 + j, lng: 77.0, speedKmh: 0, accuracyM: 12);
      }
      expect(a.distanceM, 0);
      expect(a.movingMs, 0);
      expect(a.stops, 0, reason: 'standing before the first metre is not a stop');
    });

    test('inaccurate fixes and teleports are ignored', () {
      final a = RideStatsAccumulator();
      a.onFix(ts: 0, lat: 12.0, lng: 77.0, speedKmh: 40, accuracyM: 5);
      final lat = ride(a, startTs: 0, startLat: 12.0, kmh: 40, seconds: 30);
      final before = a.distanceM;
      expect(a.onFix(ts: 31000, lat: lat + 0.01, lng: 77.0, speedKmh: 40, accuracyM: 300), isFalse); // 1.1 km, bad accuracy
      expect(a.onFix(ts: 31500, lat: lat + 0.02, lng: 77.0, speedKmh: 40, accuracyM: 5), isFalse); // 2.2 km in 1.5 s
      expect(a.distanceM, before);
      ride(a, startTs: 31000, startLat: lat, kmh: 40, seconds: 10);
      expect(a.distanceM, closeTo(before + 40 / 3.6 * 10, 2));
    });

    test('a signal gap while moving adds neither distance nor time', () {
      final a = RideStatsAccumulator();
      a.onFix(ts: 0, lat: 12.0, lng: 77.0, speedKmh: 60, accuracyM: 5);
      final lat = ride(a, startTs: 0, startLat: 12.0, kmh: 60, seconds: 60);
      final d = a.distanceM, ms = a.movingMs;
      a.onFix(ts: 60000 + 5 * 60000, lat: lat + 5000 / mPerDegLat, lng: 77.0, speedKmh: 60, accuracyM: 5);
      expect(a.distanceM, d);
      expect(a.movingMs, ms);
    });

    test('a stop of a minute or more counts once; short traffic halts do not', () {
      final a = RideStatsAccumulator();
      a.onFix(ts: 0, lat: 12.0, lng: 77.0, speedKmh: 40, accuracyM: 5);
      var lat = ride(a, startTs: 0, startLat: 12.0, kmh: 40, seconds: 30);
      for (var i = 1; i <= 30; i++) {
        a.onFix(ts: 30000 + i * 1000, lat: lat, lng: 77.0, speedKmh: 0, accuracyM: 5);
      }
      expect(a.stops, 0, reason: '30 s at a light');
      lat = ride(a, startTs: 60000, startLat: lat, kmh: 40, seconds: 30);
      for (var i = 1; i <= 120; i++) {
        a.onFix(ts: 90000 + i * 1000, lat: lat, lng: 77.0, speedKmh: 0, accuracyM: 5);
      }
      expect(a.stops, 1);
      expect(a.stoppedMs, greaterThanOrEqualTo(150000));
    });
  });

  group('peak with spike rejection', () {
    test('a single wild speed reading never becomes the peak', () {
      final a = RideStatsAccumulator();
      a.onFix(ts: 0, lat: 12.0, lng: 77.0, speedKmh: 60, accuracyM: 5);
      final lat = ride(a, startTs: 0, startLat: 12.0, kmh: 60, seconds: 20);
      a.onFix(ts: 21000, lat: lat + 17 / mPerDegLat, lng: 77.0, speedKmh: 180, accuracyM: 5); // spike
      ride(a, startTs: 21000, startLat: lat + 17 / mPerDegLat, kmh: 60, seconds: 10);
      expect(a.peakKmh, closeTo(60, 0.01));
    });

    test('a real build-up to 112 km/h is the peak (lower of the pair)', () {
      final a = RideStatsAccumulator();
      a.onFix(ts: 0, lat: 12.0, lng: 77.0, speedKmh: 60, accuracyM: 5);
      var lat = 12.0;
      var ts = 0;
      for (var v = 64; v <= 112; v += 4) {
        ts += 1000;
        lat += v / 3.6 / mPerDegLat;
        a.onFix(ts: ts, lat: lat, lng: 77.0, speedKmh: v.toDouble(), accuracyM: 5);
      }
      expect(a.peakKmh, closeTo(108, 0.01), reason: 'the 112 reading has no confirming neighbour yet');
      ts += 1000;
      lat += 112 / 3.6 / mPerDegLat;
      a.onFix(ts: ts, lat: lat, lng: 77.0, speedKmh: 112, accuracyM: 5);
      expect(a.peakKmh, closeTo(112, 0.01));
    });
  });

  group('over the limit', () {
    test('time and distance over the effective limit (with the 2 km/h GPS allowance)', () {
      final a = RideStatsAccumulator();
      a.onFix(ts: 0, lat: 12.0, lng: 77.0, speedKmh: 50, accuracyM: 5);
      var lat = ride(a, startTs: 0, startLat: 12.0, kmh: 50, seconds: 60, limitKmh: 60);
      lat = ride(a, startTs: 60000, startLat: lat, kmh: 61, seconds: 60, limitKmh: 60); // within allowance
      expect(a.overLimitMs, 0);
      ride(a, startTs: 120000, startLat: lat, kmh: 75, seconds: 60, limitKmh: 60);
      expect(a.overLimitMs, inInclusiveRange(59000, 60000));
      expect(a.overLimitM, closeTo(75 / 3.6 * 60, 25));
      expect(a.overLimitShare, greaterThan(0.3));
    });

    test('no limit known: nothing counts as over', () {
      final a = RideStatsAccumulator();
      a.onFix(ts: 0, lat: 12.0, lng: 77.0, speedKmh: 120, accuracyM: 5);
      ride(a, startTs: 0, startLat: 12.0, kmh: 120, seconds: 30);
      expect(a.overLimitMs, 0);
    });
  });

  group('persistence and trace', () {
    test('survives a save and restore, and continues counting', () {
      final a = RideStatsAccumulator();
      a.onFix(ts: 0, lat: 12.0, lng: 77.0, speedKmh: 45, accuracyM: 5);
      final lat = ride(a, startTs: 0, startLat: 12.0, kmh: 45, seconds: 120, limitKmh: 40);
      final b = RideStatsAccumulator.fromJson(a.toJson())!;
      expect(b.distanceM, a.distanceM);
      expect(b.movingMs, a.movingMs);
      expect(b.peakKmh, a.peakKmh);
      expect(b.overLimitMs, a.overLimitMs);
      expect(b.bands(SpeedBandProfile.motorcycle)[1].distanceM, a.bands(SpeedBandProfile.motorcycle)[1].distanceM);
      expect(b.speedTrace, a.speedTrace);
      ride(b, startTs: 120000, startLat: lat, kmh: 45, seconds: 10);
      expect(b.distanceM, closeTo(a.distanceM + 125, 2));
    });

    test('bad or old JSON gives null', () {
      expect(RideStatsAccumulator.fromJson(null), isNull);
      expect(RideStatsAccumulator.fromJson({'v': 0}), isNull);
      expect(RideStatsAccumulator.fromJson({'v': 1, 'd': 'x'}), isNull);
    });

    test('speed trace: one point per 30 s, halved past 240 points', () {
      final a = RideStatsAccumulator();
      a.onFix(ts: 0, lat: 12.0, lng: 77.0, speedKmh: 36, accuracyM: 5);
      ride(a, startTs: 0, startLat: 12.0, kmh: 36, seconds: 300);
      expect(a.speedTrace.length, 10);
      expect(a.speedTrace.every((v) => (v - 36).abs() <= 1), isTrue);
      final long = RideStatsAccumulator();
      long.onFix(ts: 0, lat: 12.0, lng: 77.0, speedKmh: 20, accuracyM: 5);
      ride(long, startTs: 0, startLat: 12.0, kmh: 20, seconds: 2 * 60 * 60 + 60);
      expect(long.speedTrace.length, lessThanOrEqualTo(RideStatsAccumulator.traceMax));
      expect(long.traceStep, 60000);
    });
  });
}
