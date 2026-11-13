import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/domain/intel/falling_behind.dart';
import 'package:coroute_app/domain/intel/hazard_ahead.dart';
import 'package:coroute_app/domain/places/place_poi.dart';
import 'package:coroute_app/domain/places/poi_category.dart';

/// Round 4 falling-behind predictor (feature 12) and regroup suggestion (feature 11).
void main() {
  // A straight route north, 0.0001 deg lat = ~11 m.
  final route = [for (var i = 0; i <= 300; i++) (12.9 + i * 0.001, 77.5)];

  group('falling behind', () {
    /// Feeds 5 s ticks: the group moves at [groupKmh], Ravi at [raviKmh]; returns the first alert and its time.
    (FallingBehind?, int) run(FallingBehindPredictor p, {double groupKmh = 60, double raviKmh = 45, int seconds = 300, bool raviStoppedAtRegroup = false}) {
      var lead = 3000.0, mid = 2800.0, ravi = 2500.0;
      for (var t = 0; t <= seconds * 1000; t += 5000) {
        final hit = p.update(
          nowMs: t,
          along: {'lead': lead, 'mid': mid, 'ravi': ravi},
          speedKmh: {'lead': groupKmh, 'mid': groupKmh, 'ravi': raviStoppedAtRegroup ? 0 : raviKmh},
          names: {'lead': 'Asha', 'mid': 'Kiran', 'ravi': 'Ravi'},
          pos: {'ravi': (12.9 + ravi / 111000, 77.5)},
          regroupPoints: raviStoppedAtRegroup ? [(12.9 + 2500 / 111000, 77.5)] : const [],
          selfId: 'lead',
        );
        if (hit != null) return (hit, t);
        lead += groupKmh / 3.6 * 5;
        mid += groupKmh / 3.6 * 5;
        if (!raviStoppedAtRegroup) ravi += raviKmh / 3.6 * 5;
      }
      return (null, -1);
    }

    test('a rider 15 km/h slower than the group is flagged after about 2 minutes', () {
      final (hit, t) = run(FallingBehindPredictor());
      expect(hit, isNotNull);
      expect(hit!.userId, 'ravi');
      expect(t, inInclusiveRange(95000, 130000));
      expect(hit.rateMPerMin, closeTo(250, 30));
      expect(hit.text, startsWith('Ravi is falling behind ('));
      expect(hit.text, endsWith(', growing)'));
    });

    test('same speed: nothing; a small slowdown under 150 m/min: nothing', () {
      expect(run(FallingBehindPredictor(), raviKmh: 60).$1, isNull);
      expect(run(FallingBehindPredictor(), raviKmh: 55).$1, isNull, reason: '5 km/h slower is 83 m/min');
    });

    test('never for a rider stopped at a known regroup point', () {
      expect(run(FallingBehindPredictor(), raviStoppedAtRegroup: true).$1, isNull);
    });

    test('rate limited: one alert per rider per 10 minutes', () {
      final p = FallingBehindPredictor();
      var lead = 3000.0, ravi = 2500.0;
      var alerts = 0;
      for (var t = 0; t <= 900000; t += 5000) {
        if (p.update(nowMs: t, along: {'lead': lead, 'mid': lead - 100, 'ravi': ravi}, speedKmh: {'ravi': 40}, names: {'ravi': 'Ravi'}) != null) alerts++;
        lead += 60 / 3.6 * 5;
        ravi += 40 / 3.6 * 5;
      }
      expect(alerts, 2, reason: 'at about 2 min and again after 10 min');
    });

    test('slope is a least-squares fit in metres per minute', () {
      final s = [for (var i = 0; i < 7; i++) GapSample(i * 20000, 100.0 + i * 100)]; // +100 m every 20 s
      expect(FallingBehindPredictor.slopePerMin(s), closeTo(300, 0.001));
      expect(FallingBehindPredictor.slopePerMin([const GapSample(0, 1)]), isNull);
    });
  });

  group('regroup suggestion', () {
    final fuel = PlacePoi(id: 'p1', lat: 12.9 + 6000 / 111000, lng: 77.5, category: PoiCategory.fuel, tags: const {'name': 'Indian Oil'});

    test('a learned rider stop matched to a fuel station comes first', () {
      final stop = IntelCell(id: 'st:1', lat: 12.9 + 5000 / 111000, lng: 77.5005, fuel: true, name: 'HP Dhaba Stop');
      final s = RegroupAdvisor.pick(route: route, places: [fuel], learnedStops: [stop], lastAlongM: 1000, leadAlongM: 2500);
      expect(s, isNotNull);
      expect(s!.name, 'HP Dhaba Stop');
      expect(s.text, startsWith('Regroup at HP Dhaba Stop'));
    });

    test('without learned stops: the existing places picker (fuel first)', () {
      final s = RegroupAdvisor.pick(route: route, places: [fuel], lastAlongM: 1000, leadAlongM: 2500);
      expect(s!.name, 'Indian Oil');
    });

    test('a learned stop with no place match is not offered (room unknown); behind the lead never', () {
      final plain = IntelCell(id: 'st:2', lat: 12.9 + 5000 / 111000, lng: 77.5);
      expect(RegroupAdvisor.pick(route: route, places: const [], learnedStops: [plain], lastAlongM: 1000, leadAlongM: 2500), isNull);
      final behind = IntelCell(id: 'st:3', lat: 12.9 + 2000 / 111000, lng: 77.5, fuel: true, name: 'Old pump');
      expect(RegroupAdvisor.pick(route: route, places: const [], learnedStops: [behind], lastAlongM: 1000, leadAlongM: 2500), isNull);
    });
  });
}
