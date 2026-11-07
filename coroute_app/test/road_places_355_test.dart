// 3.55: road warnings (pothole / speed breaker / rough road felt at the front, spoken to the
// riders behind and saved for later rides) and CoRoute rider place reviews (a polite "How was
// it?" after a while at a place).
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/data/models/road_hazard_telemetry.dart';
import 'package:coroute_app/data/services/place_review_service.dart';
import 'package:coroute_app/domain/places/place_dwell.dart';
import 'package:coroute_app/domain/places/place_poi.dart';
import 'package:coroute_app/domain/places/poi_category.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/safety/road_surface_detector.dart';
import 'package:coroute_app/presentation/ride/emergency_guidance.dart';
import 'package:coroute_app/presentation/rider/widgets/road_hazard_hud_pill.dart';

const _min = 60000;
const dhaba = PlacePoi(id: 'n101', lat: 17.4000, lng: 78.5000, category: PoiCategory.food, tags: {'name': 'Sri Sai Dhaba', 'amenity': 'restaurant'});
const hotel = PlacePoi(id: 'w202', lat: 17.5000, lng: 78.6000, category: PoiCategory.stay, tags: {'name': 'Hill View Stay', 'tourism': 'hotel'});
const fuel = PlacePoi(id: 'n303', lat: 17.6000, lng: 78.7000, category: PoiCategory.fuel, tags: {'name': 'HP Fuel', 'amenity': 'fuel'});
const hospital = PlacePoi(id: 'n404', lat: 17.7000, lng: 78.8000, category: PoiCategory.hospital, tags: {'name': 'City Hospital', 'amenity': 'hospital'});

/// One fix a minute at [p] (a few metres off) for [minutes] minutes from [t0].
int stay(PlaceDwellTracker t, PlacePoi p, int t0, int minutes, {List<PlacePoi>? nearby}) {
  var tm = t0;
  for (var i = 0; i <= minutes; i++) {
    tm = t0 + i * _min;
    t.onFix(lat: p.lat + 0.0001, lng: p.lng, tMs: tm, nearby: nearby ?? [p]);
  }
  return tm;
}

AccelBucket bucket(int t, {double dyn = 0.1, double std = 0.05, double gyro = 0.1}) =>
    AccelBucket(tMs: t, peakG: 1 + dyn, meanG: 1, stdG: std, peakDynG: dyn, peakGyroRadS: gyro);

void main() {
  group('PlaceDwellTracker', () {
    test('food: asked after 12 min within 80 m, only when stopped, with the minutes spent', () {
      final t = PlaceDwellTracker();
      final end = stay(t, dhaba, 0, 11);
      expect(t.due(speedKmh: 0, rideEnded: false, emergencyOpen: false, nowMs: end), isNull, reason: '11 min is not enough');
      final end2 = stay(t, dhaba, 0, 25);
      final p = t.due(speedKmh: 0, rideEnded: false, emergencyOpen: false, nowMs: end2);
      expect(p, isNotNull);
      expect(p!.placeId, 'n101');
      expect(p.title, 'How was Sri Sai Dhaba?');
      expect(p.dwellMin, 25);
      expect(p.message, 'You spent 25 min there. A quick rating helps the riders coming after you.');
    });

    test('never while riding; never while an SOS or crash alarm is open; after the ride ends it is fine', () {
      final t = PlaceDwellTracker();
      final end = stay(t, dhaba, 0, 15);
      expect(t.due(speedKmh: 40, rideEnded: false, emergencyOpen: false, nowMs: end), isNull);
      expect(t.due(speedKmh: 0, rideEnded: false, emergencyOpen: true, nowMs: end), isNull);
      expect(t.due(speedKmh: 40, rideEnded: true, emergencyOpen: false, nowMs: end), isNotNull);
    });

    test('thresholds per kind: stay 30 min, fuel 8 min, others 10 min; hospitals never asked', () {
      expect(PlaceDwellTracker.minDwellFor(PoiCategory.food), const Duration(minutes: 12));
      expect(PlaceDwellTracker.minDwellFor(PoiCategory.stay), const Duration(minutes: 30));
      expect(PlaceDwellTracker.minDwellFor(PoiCategory.fuel), const Duration(minutes: 8));
      expect(PlaceDwellTracker.minDwellFor(PoiCategory.viewpoint), const Duration(minutes: 10));

      final s = PlaceDwellTracker();
      var end = stay(s, hotel, 0, 29);
      expect(s.due(speedKmh: 0, rideEnded: false, emergencyOpen: false, nowMs: end), isNull);
      end = stay(s, hotel, 0, 31);
      expect(s.due(speedKmh: 0, rideEnded: false, emergencyOpen: false, nowMs: end)?.placeId, 'w202');

      final f = PlaceDwellTracker();
      end = stay(f, fuel, 0, 8);
      expect(f.due(speedKmh: 0, rideEnded: false, emergencyOpen: false, nowMs: end)?.placeId, 'n303');

      final h = PlaceDwellTracker();
      end = stay(h, hospital, 0, 120);
      expect(h.due(speedKmh: 0, rideEnded: true, emergencyOpen: false, nowMs: end), isNull);
    });

    test('at most once per place per 24 h (persisted map), then again the next day', () {
      final t = PlaceDwellTracker();
      var end = stay(t, dhaba, 0, 15);
      final p = t.due(speedKmh: 0, rideEnded: false, emergencyOpen: false, nowMs: end)!;
      t.markAsked(p.placeId, end);
      expect(t.asked.keys, ['n101']);
      expect(t.due(speedKmh: 0, rideEnded: false, emergencyOpen: false, nowMs: end), isNull);
      end = stay(t, dhaba, end + 60 * _min, 30);
      expect(t.due(speedKmh: 0, rideEnded: false, emergencyOpen: false, nowMs: end), isNull, reason: 'same day');

      // A restart: the service hands back the saved times.
      final again = PlaceDwellTracker(asked: {'n101': 0});
      end = stay(again, dhaba, 25 * 60 * _min, 15);
      expect(again.due(speedKmh: 0, rideEnded: false, emergencyOpen: false, nowMs: end), isNotNull, reason: 'next day');
    });

    test('outside 80 m is not a dwell; a short GPS jump does not reset it; leaving long does', () {
      final t = PlaceDwellTracker();
      // 150 m away the whole time.
      for (var i = 0; i <= 30; i++) {
        t.onFix(lat: dhaba.lat + 0.00135, lng: dhaba.lng, tMs: i * _min, nearby: [dhaba]);
      }
      expect(t.due(speedKmh: 0, rideEnded: true, emergencyOpen: false, nowMs: 30 * _min), isNull);

      final j = PlaceDwellTracker();
      stay(j, dhaba, 0, 6);
      j.onFix(lat: dhaba.lat + 0.002, lng: dhaba.lng, tMs: 6 * _min + 30000, nearby: [dhaba]); // 220 m jump for 30 s
      final end = stay(j, dhaba, 7 * _min, 6);
      expect(j.due(speedKmh: 0, rideEnded: false, emergencyOpen: false, nowMs: end)?.dwellMin, 13);

      final l = PlaceDwellTracker();
      stay(l, dhaba, 0, 6);
      for (var i = 0; i < 5; i++) {
        l.onFix(lat: 17.45, lng: 78.55, tMs: 7 * _min + i * _min, nearby: const []);
      }
      expect(l.currentPlace, isNull);
      final end2 = stay(l, dhaba, 12 * _min, 8);
      expect(l.due(speedKmh: 0, rideEnded: false, emergencyOpen: false, nowMs: end2), isNull, reason: 'the clock started again');
    });

    test('a qualified dwell is offered at the next stop shortly after, but not hours later', () {
      final t = PlaceDwellTracker();
      stay(t, dhaba, 0, 20);
      // Rode off (never asked while riding), stopped at a signal 10 min later: asked then.
      for (var i = 1; i <= 10; i++) {
        t.onFix(lat: 17.40 + i * 0.01, lng: 78.5, tMs: 20 * _min + i * _min, nearby: const []);
      }
      expect(t.due(speedKmh: 0, rideEnded: false, emergencyOpen: false, nowMs: 30 * _min)?.placeId, 'n101');

      final late = PlaceDwellTracker();
      stay(late, dhaba, 0, 20);
      for (var i = 1; i <= 40; i++) {
        late.onFix(lat: 17.40 + i * 0.01, lng: 78.5, tMs: 20 * _min + i * _min, nearby: const []);
      }
      expect(late.due(speedKmh: 0, rideEnded: false, emergencyOpen: false, nowMs: 60 * _min), isNull);
    });

    test('the nearer of two places is the one; it stays the place while I am inside its circle', () {
      const tea = PlacePoi(id: 'n555', lat: 17.40030, lng: 78.5, category: PoiCategory.food, tags: {'name': 'Chai Point'});
      final t = PlaceDwellTracker();
      for (var i = 0; i <= 14; i++) {
        // 11 m from the dhaba, 22 m from the tea stall.
        t.onFix(lat: 17.4001, lng: 78.5, tMs: i * _min, nearby: [tea, dhaba]);
      }
      expect(t.currentPlace?.id, 'n101');
      expect(t.due(speedKmh: 1, rideEnded: false, emergencyOpen: false, nowMs: 14 * _min)?.placeId, 'n101');
    });
  });

  group('PlaceReviewService parsing', () {
    test('photo paths become relative to the API base; first name only', () {
      expect(PlaceReviewService.relativePath('/api/places/reviews/pr_1/photo/rp_2'), '/places/reviews/pr_1/photo/rp_2');
      final page = PlaceReviewsPage.fromJson({
        'summary': {'avg': 4.5, 'count': 2},
        'reviews': [
          {'reviewId': 'pr_a', 'firstName': 'Shanmuk', 'rating': 5, 'text': 'Great parking', 'createdAt': 1, 'photos': ['/api/places/reviews/pr_a/photo/rp_x']},
          {'reviewId': 'pr_b', 'rating': 9},
        ],
        'mine': null,
      });
      expect(page.summary!.avg, 4.5);
      expect(page.summary!.count, 2);
      expect(page.reviews.length, 1, reason: 'a bad rating is skipped');
      expect(page.reviews.first.firstName, 'Shanmuk');
      expect(page.reviews.first.photos.single, '/places/reviews/pr_a/photo/rp_x');
      expect(PlaceRatingSummary.fromJson({'avg': null, 'count': 0}), isNull);
    });
  });

  group('RoadSurfaceDetector', () {
    test('a sharp jolt at a steady speed is a pothole; a crash-like second never is', () {
      final d = RoadSurfaceDetector();
      for (var i = 0; i < 5; i++) {
        expect(d.onBucket(bucket(i * 1000), speedKmh: 50, lat: 17.4, lng: 78.5), isNull);
      }
      final e = d.onBucket(bucket(5000, dyn: 1.4), speedKmh: 50, lat: 17.4, lng: 78.5);
      expect(e?.kind, RoadSurfaceKind.pothole);
      expect(e!.severity, 'MEDIUM');
      expect(e.kind.wire, 'POTHOLE');

      final c = RoadSurfaceDetector();
      final crash = AccelBucket(tMs: 1000, peakG: 6, meanG: 2, stdG: 1.5, peakDynG: 5, impactDurationMs: 200);
      expect(c.onBucket(crash, speedKmh: 50, lat: 17.4, lng: 78.5), isNull);
    });

    test('3.55 safety review: a lowside slide second (the crash detector\'s fall rule) is never a pothole', () {
      // 2.4 g dynamic, 1.9 rad/s (109 deg/s) of rotation, 30 deg tilt, short impact: under every
      // old fixed limit (3.5 g, 120 ms, 50 deg, 120 deg/s) but a crash candidate for CrashDetector.
      final d = RoadSurfaceDetector();
      for (var i = 0; i < 5; i++) {
        d.onBucket(bucket(i * 1000), speedKmh: 50, lat: 17.4, lng: 78.5);
      }
      const slide = AccelBucket(tMs: 5000, peakG: 3.0, meanG: 1.2, stdG: 0.6, peakDynG: 2.4, peakGyroRadS: 1.9, tiltDeg: 30, impactDurationMs: 60);
      expect(RoadSurfaceDetector.isCrashLike(slide), isTrue);
      expect(d.onBucket(slide, speedKmh: 50, lat: 17.4, lng: 78.5), isNull);
      // A real pothole (sharp, little rotation, no tilt) still is one.
      expect(RoadSurfaceDetector.isCrashLike(bucket(6000, dyn: 1.4)), isFalse);
      expect(d.onBucket(bucket(6000, dyn: 1.4), speedKmh: 50, lat: 17.41, lng: 78.5)?.kind, RoadSurfaceKind.pothole);
    });

    test('slowing then a bump is a speed breaker; slow riding reports nothing; spacing holds', () {
      final d = RoadSurfaceDetector();
      d.onBucket(bucket(0), speedKmh: 50, lat: 17.4, lng: 78.5);
      d.onBucket(bucket(1000), speedKmh: 40, lat: 17.4001, lng: 78.5);
      final e = d.onBucket(bucket(2000, dyn: 0.8), speedKmh: 25, lat: 17.4002, lng: 78.5);
      expect(e?.kind, RoadSurfaceKind.speedBreaker);
      // Another jolt 30 s later but 20 m away: too close to the last report.
      expect(d.onBucket(bucket(32000, dyn: 1.5), speedKmh: 50, lat: 17.4004, lng: 78.5), isNull);

      final slow = RoadSurfaceDetector();
      expect(slow.onBucket(bucket(0, dyn: 1.5), speedKmh: 10, lat: 17.4, lng: 78.5), isNull);
    });

    test('sustained shaking at speed is rough road', () {
      final d = RoadSurfaceDetector();
      RoadSurfaceEvent? e;
      for (var i = 0; i < 10 && e == null; i++) {
        e = d.onBucket(bucket(i * 1000, dyn: 0.5, std: 0.5), speedKmh: 40, lat: 17.4 + i * 0.0001, lng: 78.5);
      }
      expect(e?.kind, RoadSurfaceKind.roughRoad);
      expect(RoadHazardClassification.fromWire(e!.kind.wire), RoadHazardClassification.roughRoad);
    });
  });

  group('Road warning text', () {
    RoadHazardObservation obs(RoadHazardClassification c, RoadHazardSeverity s, {bool history = false}) => RoadHazardObservation(
          eventId: 'rh_1',
          timestamp: 0,
          lat: 17.4,
          lng: 78.5,
          accuracyM: 5,
          speedKmh: 50,
          heading: 90,
          peakVerticalG: 1.5,
          peakYawRateDegS: 10,
          confidence: 0.8,
          severity: s,
          classification: c,
          fromHistory: history,
        );

    test('spoken: the FEAT-02 line for a live severe pothole, else by kind; saved ones say so', () {
      expect(EmergencyGuidance.roadHazardSpeech(obs(RoadHazardClassification.pothole, RoadHazardSeverity.critical), 300),
          'Caution: severe road hazard 300 meters ahead');
      expect(EmergencyGuidance.roadHazardSpeech(obs(RoadHazardClassification.speedBreaker, RoadHazardSeverity.medium), 290),
          'Caution. Speed breaker ahead in 300 metres. Slow down.');
      expect(EmergencyGuidance.roadHazardSpeech(obs(RoadHazardClassification.pothole, RoadHazardSeverity.high, history: true), 320),
          'Caution. Pothole ahead in 300 metres, reported by CoRoute riders. Slow down.');
      expect(RoadSurfaceText.spoken(RoadSurfaceKind.roughRoad, 1250), 'Caution. Rough road ahead in 1.3 kilometres. Slow down.');
      expect(RoadSurfaceText.title(RoadSurfaceKind.pothole, 310), 'Pothole ahead · 300 m');
    });

    test('pill titles by kind', () {
      expect(RoadHazardHudPill.titleFor(obs(RoadHazardClassification.pothole, RoadHazardSeverity.high)), 'Pothole ahead');
      expect(RoadHazardHudPill.titleFor(obs(RoadHazardClassification.speedBreaker, RoadHazardSeverity.medium)), 'Speed breaker ahead');
      expect(RoadHazardHudPill.titleFor(obs(RoadHazardClassification.roughRoad, RoadHazardSeverity.low)), 'Rough road ahead');
    });

    test('saved reports parse as history with their report count', () {
      final h = RoadHazardObservation.fromJson({
        'hazardId': 'rh_saved',
        'lat': 17.4,
        'lng': 78.5,
        'severity': 'HIGH',
        'classification': 'ROUGH_ROAD',
        'corroborationCount': 3,
        'fromHistory': true,
      });
      expect(h.fromHistory, isTrue);
      expect(h.reports, 3);
      expect(h.classification.label, 'Rough road');
    });
  });
}
