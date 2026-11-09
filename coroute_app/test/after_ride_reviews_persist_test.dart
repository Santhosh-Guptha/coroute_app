// 3.55 follow-up: the after-ride place questions survive an app restart (PendingPlaceReviews,
// kept 7 days, at most 2, with the ride id) and the trip report of that ride asks too.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/place_review_service.dart';
import 'package:coroute_app/domain/places/place_dwell.dart';
import 'package:coroute_app/domain/places/place_poi.dart';
import 'package:coroute_app/domain/places/poi_category.dart';
import 'package:coroute_app/domain/places/ride_end_reviews.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

const _min = 60000;
const _day = 24 * 60 * _min;
const dhaba = PlacePoi(id: 'n101', lat: 17.4000, lng: 78.5000, category: PoiCategory.food, tags: {'name': 'Sri Sai Dhaba', 'amenity': 'restaurant'});
const hotel = PlacePoi(id: 'w202', lat: 17.5000, lng: 78.6000, category: PoiCategory.stay, tags: {'name': 'Hill View Stay'});
const fuel = PlacePoi(id: 'n303', lat: 17.6000, lng: 78.7000, category: PoiCategory.fuel, tags: {'brand': 'HP'});

PendingPlaceReview pending(PlacePoi p, int mins, int at, {String ride = 'GRP-A'}) =>
    PendingPlaceReview.fromPrompt(PlaceReviewPrompt(place: p, dwellMin: mins, atMs: at), rideId: ride);

void main() {
  group('PendingPlaceReviews (pure)', () {
    test('JSON round trip keeps ride id, place, name, category, stay and a 7 day expiry', () {
      final p = pending(dhaba, 14, 1000);
      expect(p.expiresAtMs, 1000 + 7 * _day);
      final back = PendingPlaceReview.fromJson(p.toJson())!;
      expect(back.rideId, 'GRP-A');
      expect(back.placeId, 'n101');
      expect(back.name, 'Sri Sai Dhaba');
      expect(back.dwellMin, 14);
      final q = back.toPrompt();
      expect(q.place.category, PoiCategory.food);
      expect(q.place.displayName, 'Sri Sai Dhaba');
      expect(q.title, 'How was Sri Sai Dhaba?');
      expect(PendingPlaceReview.fromJson({'placeId': ''}), isNull);
      expect(PendingPlaceReview.fromJson('junk'), isNull);
    });

    test('at most 2, newest ride first, longest stay first within a ride', () {
      final l = PendingPlaceReviews();
      expect(l.add(pending(dhaba, 14, 1000, ride: 'GRP-OLD'), nowMs: 2000), isTrue);
      l.add(pending(hotel, 45, 5000), nowMs: 6000);
      l.add(pending(fuel, 9, 5500), nowMs: 6000);
      expect(l.items.map((e) => e.placeId), ['w202', 'n303'], reason: 'the newer ride wins; the older one is dropped');
      expect(l.add(pending(hotel, 30, 5000), nowMs: 6000), isFalse, reason: 'the same place keeps the longer stay');
      expect(l.items.first.dwellMin, 45);
    });

    test('expired after 7 days; remove, skip per ride and decode of junk', () {
      final l = PendingPlaceReviews()
        ..add(pending(dhaba, 14, 1), nowMs: 1)
        ..add(pending(hotel, 40, 10, ride: 'GRP-B'), nowMs: 10);
      expect(l.live(nowMs: 2, rideId: 'GRP-A').single.placeId, 'n101');
      expect(PendingPlaceReviews.decode(l.encode(), nowMs: 7 * _day + 11).isEmpty, isTrue);
      expect(PendingPlaceReviews.decode(l.encode(), nowMs: 100).items, hasLength(2));
      expect(l.skip(rideId: 'GRP-B'), isTrue);
      expect(l.items.single.placeId, 'n101');
      expect(l.remove('n101'), isTrue);
      expect(l.isEmpty, isTrue);
      expect(PendingPlaceReviews.decode('{not json', nowMs: 0).isEmpty, isTrue);
      expect(PendingPlaceReviews.decode(null, nowMs: 0).isEmpty, isTrue);
    });
  });

  group('PlaceReviewService keeps the after-ride list across a restart', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    setUp(() => SharedPreferences.setMockInitialValues({}));

    late int now;
    late bool active;
    PlaceReviewService make({bool loadPrefs = false}) => PlaceReviewService(ApiClient(), clock: () => now, loadPrefs: loadPrefs)
      ..placesSource = (() => const [dhaba])
      ..rideActive = (() => active)
      ..rideIdSource = (() => active ? 'GRP-A' : null)
      ..emergencyOpen = (() => false);

    Future<void> rideAndStay(PlaceReviewService svc) async {
      for (var i = 0; i <= 13; i++) {
        now += _min;
        svc.onFix(TrackPoint(ts: now, lat: dhaba.lat + 0.0001, lng: dhaba.lng, speedKmh: 0));
      }
      now += _min;
      svc.onFix(TrackPoint(ts: now, lat: 17.45, lng: 78.55, speedKmh: 40)); // rode off unanswered
      active = false;
      svc.onRideEnded(rideId: 'GRP-A');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    test('restored on the next start, asked once on app open, shown on that ride\'s report', () async {
      now = 10 * _min;
      active = true;
      final first = make();
      await rideAndStay(first);
      expect(first.afterRidePrompts(enabled: true, rideId: 'GRP-A').single.placeId, 'n101');
      final raw = (await SharedPreferences.getInstance()).getString(PlaceReviewService.pendingKey);
      expect(raw, contains('GRP-A'));
      first.dispose();

      // App restart.
      now += 3 * _day;
      final second = make(loadPrefs: true);
      await second.restored;
      expect(second.afterRidePrompts(enabled: true).single.place.displayName, 'Sri Sai Dhaba');
      expect(second.afterRidePrompts(enabled: true, rideId: 'GRP-A'), hasLength(1), reason: 'the trip report of that ride');
      expect(second.afterRidePrompts(enabled: true, rideId: 'GRP-OTHER'), isEmpty);
      expect(second.afterRidePrompts(enabled: false), isEmpty);
      expect(second.takeOpenPrompt(enabled: true), isTrue);
      expect(second.takeOpenPrompt(enabled: true), isFalse, reason: 'once per app open');

      second.answerAfterRide('n101');
      expect(second.afterRidePrompts(enabled: true), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((await SharedPreferences.getInstance()).getString(PlaceReviewService.pendingKey), isNull);
    });

    test('skip removes them; expired after 7 days; not offered during a ride', () async {
      now = 10 * _min;
      active = true;
      final first = make();
      await rideAndStay(first);
      first.dispose();

      final during = make(loadPrefs: true);
      active = true;
      await during.restored;
      expect(during.takeOpenPrompt(enabled: true), isFalse, reason: 'never during a ride');
      active = false;
      during.skipAfterRide(rideId: 'GRP-A');
      expect(during.afterRidePrompts(enabled: true), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final again = make(loadPrefs: true);
      await again.restored;
      expect(again.afterRidePrompts(enabled: true), isEmpty, reason: 'skipped stays skipped');
    });

    test('kept 7 days only', () async {
      now = 10 * _min;
      active = true;
      final first = make();
      await rideAndStay(first);
      now += 8 * _day;
      final later = make(loadPrefs: true);
      await later.restored;
      expect(later.afterRidePrompts(enabled: true), isEmpty);
      expect(later.takeOpenPrompt(enabled: true), isFalse);
    });

    test('answered in the cockpit: not stored', () async {
      now = 10 * _min;
      active = true;
      final svc = make();
      for (var i = 0; i <= 13; i++) {
        now += _min;
        svc.onFix(TrackPoint(ts: now, lat: dhaba.lat + 0.0001, lng: dhaba.lng, speedKmh: 0));
      }
      svc.dismissPrompt();
      active = false;
      svc.onRideEnded(rideId: 'GRP-A');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((await SharedPreferences.getInstance()).getString(PlaceReviewService.pendingKey), isNull);
    });
  });
}
