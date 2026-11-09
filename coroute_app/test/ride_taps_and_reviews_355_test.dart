// 3.55 owner decisions: "speak while moving, act when stopped" (RideTapGate), the place review
// question after the ride (RideEndReviews, PlaceReviewService.afterRidePrompts), and the trip /
// riding role names on the manage-riders sheet.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/place_review_service.dart';
import 'package:coroute_app/domain/places/place_dwell.dart';
import 'package:coroute_app/domain/places/place_poi.dart';
import 'package:coroute_app/domain/places/poi_category.dart';
import 'package:coroute_app/domain/places/ride_end_reviews.dart';
import 'package:coroute_app/domain/ride/ride_tap_gate.dart';
import 'package:coroute_app/domain/ride/vehicle_swap.dart';
import 'package:coroute_app/domain/route/off_route_group.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';
import 'package:coroute_app/presentation/rider/widgets/rider_management_sheet.dart';

const _s = 1000;
const _min = 60000;
const dhaba = PlacePoi(id: 'n101', lat: 17.4000, lng: 78.5000, category: PoiCategory.food, tags: {'name': 'Sri Sai Dhaba', 'amenity': 'restaurant'});
const hotel = PlacePoi(id: 'w202', lat: 17.5000, lng: 78.6000, category: PoiCategory.stay, tags: {'name': 'Hill View Stay', 'tourism': 'hotel'});
const fuel = PlacePoi(id: 'n303', lat: 17.6000, lng: 78.7000, category: PoiCategory.fuel, tags: {'name': 'HP Fuel', 'amenity': 'fuel'});

PlaceReviewPrompt prompt(PlacePoi p, int mins, int at) => PlaceReviewPrompt(place: p, dwellMin: mins, atMs: at);

void main() {
  group('RideTapGate (speak while moving, act when stopped)', () {
    test('starts stopped: the buttons show before the ride gets going', () {
      final g = RideTapGate();
      expect(g.moving, isFalse);
      expect(g.canTap, isTrue);
    });

    test('moving at 8 km/h or more; stopped only after 5 s at 3 km/h or less', () {
      final g = RideTapGate();
      expect(g.update(speedKmh: 7.9, nowMs: 0), isFalse);
      expect(g.canTap, isTrue, reason: 'under 8 km/h does not count as moving');
      expect(g.update(speedKmh: 8, nowMs: 1 * _s), isTrue);
      expect(g.canTap, isFalse);
      g.update(speedKmh: 2, nowMs: 2 * _s);
      expect(g.canTap, isFalse, reason: 'just slowed down');
      expect(g.settleAtMs, 7 * _s);
      g.update(speedKmh: 1, nowMs: 6 * _s);
      expect(g.canTap, isFalse, reason: '4 s is not enough');
      expect(g.update(speedKmh: 0, nowMs: 7 * _s), isTrue);
      expect(g.canTap, isTrue);
      expect(g.settleAtMs, isNull);
    });

    test('hysteresis: 3..8 km/h keeps the state and restarts the stop wait', () {
      final g = RideTapGate();
      g.update(speedKmh: 30, nowMs: 0);
      g.update(speedKmh: 2, nowMs: 1 * _s);
      g.update(speedKmh: 5, nowMs: 4 * _s); // creeping in traffic
      expect(g.canTap, isFalse);
      expect(g.settleAtMs, isNull);
      g.update(speedKmh: 2, nowMs: 5 * _s);
      g.update(speedKmh: 2, nowMs: 9 * _s);
      expect(g.canTap, isFalse, reason: 'the 5 s started again at 5 s');
      g.update(speedKmh: 2, nowMs: 10 * _s);
      expect(g.canTap, isTrue);
      // Stopped, then 5 km/h (walking the bike, GPS drift): still stopped.
      g.update(speedKmh: 5, nowMs: 11 * _s);
      expect(g.canTap, isTrue);
    });

    test('tick: a parked phone with no new fix still counts as stopped after 5 s', () {
      final g = RideTapGate();
      g.update(speedKmh: 40, nowMs: 0);
      g.update(speedKmh: 0, nowMs: 1 * _s);
      expect(g.tick(3 * _s), isFalse);
      expect(g.tick(6 * _s), isTrue);
      expect(g.canTap, isTrue);
    });

    test('a pillion can always tap', () {
      final g = RideTapGate();
      g.update(speedKmh: 60, nowMs: 0, passenger: true);
      expect(g.moving, isTrue);
      expect(g.canTap, isTrue);
      expect(g.update(speedKmh: 60, nowMs: 1 * _s), isTrue, reason: 'no longer pillion');
      expect(g.canTap, isFalse);
    });

    test('a bad speed sample is ignored', () {
      final g = RideTapGate();
      g.update(speedKmh: 50, nowMs: 0);
      g.update(speedKmh: double.nan, nowMs: 10 * _s);
      g.update(speedKmh: -1, nowMs: 20 * _s);
      expect(g.canTap, isFalse);
    });

    test('reset: a new ride starts stopped', () {
      final g = RideTapGate()..update(speedKmh: 50, nowMs: 0, passenger: true);
      g.reset();
      expect(g.moving, isFalse);
      expect(g.passenger, isFalse);
    });

    test('MovingLineOnce says each card line once', () {
      final once = MovingLineOnce();
      expect(once.take('PLACE_REVIEW:n101'), isTrue);
      expect(once.take('PLACE_REVIEW:n101'), isFalse);
      expect(once.take('PLACE_REVIEW:w202'), isTrue);
      once.reset();
      expect(once.take('PLACE_REVIEW:n101'), isTrue);
    });

    test('lines: short, glove-friendly, no buttons asked for while moving', () {
      expect(OffRouteGroupMonitor.spoken, "You're off the route. Stop when safe to route to your group.");
      expect(OffRouteGroupMonitor.spokenStopped, "You left the group's route. Choose on the screen.");
      expect(MovingCardText.offRouteChip, contains('Stop to choose'));
      expect(MovingCardText.swapChip('Asha wants to swap bikes with you'), 'Asha wants to swap bikes with you · Stop to answer');
      expect(MovingCardText.heritageChip('Golconda Fort'), 'Historic place ahead: Golconda Fort');
      expect(MovingCardText.reviewSpoken('Sri Sai Dhaba'), 'Rate Sri Sai Dhaba when you stop.');
      const ask = SwapAsk(requestId: 'r1', fromUserId: 'u2', fromName: 'Asha', kind: SwapKind.bikes);
      expect(ask.speech, 'Asha wants to swap bikes with you. Stop when safe to accept or decline.');
      for (final line in [OffRouteGroupMonitor.spoken, MovingCardText.reviewSpoken('Sri Sai Dhaba')]) {
        expect(line.toLowerCase(), isNot(contains('tap')), reason: 'never ask a moving rider to tap');
      }
    });
  });

  group('RideEndReviews (place review question after the ride)', () {
    test('at most 2 places, longest stay first; answered ones are left out', () {
      final r = RideEndReviews();
      r.note(prompt(dhaba, 14, 1000));
      r.note(prompt(hotel, 45, 2000));
      r.note(prompt(fuel, 9, 3000));
      expect(r.pick(nowMs: 4000).map((p) => p.placeId), ['w202', 'n101']);
      r.answered('w202');
      expect(r.pick(nowMs: 4000).map((p) => p.placeId), ['n101', 'n303']);
      r.note(prompt(hotel, 50, 5000));
      expect(r.pick(nowMs: 6000).map((p) => p.placeId), isNot(contains('w202')), reason: 'answered in the cockpit');
    });

    test('the same place keeps the longest stay; skip clears; reset starts a new ride', () {
      final r = RideEndReviews();
      r.note(prompt(dhaba, 12, 1000));
      r.note(prompt(dhaba, 20, 1000));
      r.note(prompt(dhaba, 15, 1000));
      expect(r.pick(nowMs: 2000).single.dwellMin, 20);
      r.skipAll();
      expect(r.pick(nowMs: 2000), isEmpty);
      r.answered('n101');
      r.reset();
      r.note(prompt(dhaba, 12, 3000));
      expect(r.pick(nowMs: 4000), hasLength(1), reason: 'a new ride may ask again');
    });

    test('old dwells (a ride left open for a day) are dropped', () {
      final r = RideEndReviews()..note(prompt(dhaba, 12, 0));
      expect(r.pick(nowMs: RideEndReviews.keepFor.inMilliseconds + 1), isEmpty);
    });
  });

  group('PlaceReviewService after the ride', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    setUp(() => SharedPreferences.setMockInitialValues({}));

    late int now;
    late bool active;
    late PlaceReviewService svc;
    setUp(() {
      now = 10 * _min;
      active = true;
      svc = PlaceReviewService(ApiClient(), clock: () => now, loadPrefs: false)
        ..placesSource = (() => const [dhaba])
        ..rideActive = (() => active)
        ..emergencyOpen = (() => false);
    });

    void stayAt(PlacePoi p, int minutes) {
      for (var i = 0; i <= minutes; i++) {
        now += _min;
        svc.onFix(TrackPoint(ts: now, lat: p.lat + 0.0001, lng: p.lng, speedKmh: 0));
      }
    }

    test('rode off without answering the cockpit question: asked after the ride', () {
      stayAt(dhaba, 13);
      expect(svc.prompt?.placeId, 'n101', reason: 'the cockpit asks when stopped');
      now += _min;
      svc.onFix(TrackPoint(ts: now, lat: 17.45, lng: 78.55, speedKmh: 40));
      expect(svc.prompt, isNull, reason: 'riding off closes it unanswered');
      active = false;
      expect(svc.afterRidePrompts(enabled: true).single.placeId, 'n101');
      expect(svc.afterRidePrompts(enabled: false), isEmpty, reason: 'admin switch placeReviews / reviewPrompt off');
      svc.answerAfterRide('n101');
      expect(svc.afterRidePrompts(enabled: true), isEmpty);
    });

    test('answered in the cockpit ("Not now" or Rate): not asked again after the ride', () {
      stayAt(dhaba, 13);
      svc.dismissPrompt();
      active = false;
      expect(svc.afterRidePrompts(enabled: true), isEmpty);
    });

    test('skippable, and nothing while an SOS or crash alarm is open', () {
      stayAt(dhaba, 13);
      now += _min;
      svc.onFix(TrackPoint(ts: now, lat: 17.45, lng: 78.55, speedKmh: 40));
      active = false;
      svc.emergencyOpen = () => true;
      expect(svc.afterRidePrompts(enabled: true), isEmpty);
      svc.emergencyOpen = () => false;
      expect(svc.afterRidePrompts(enabled: true), hasLength(1));
      svc.skipAfterRide();
      expect(svc.afterRidePrompts(enabled: true), isEmpty);
    });

    test('onRideEnded closes a cockpit question still open; the summary asks instead', () {
      stayAt(dhaba, 13);
      expect(svc.prompt, isNotNull);
      active = false;
      svc.onRideEnded();
      expect(svc.prompt, isNull);
      expect(svc.afterRidePrompts(enabled: true).single.placeId, 'n101');
    });
  });

  group('Trip and riding role names (UX naming guide §4)', () {
    test('trip role first, then the riding role', () {
      expect(RiderManagementSheet.roleBadges(owner: true, head: false, ridingRole: 'LEAD'), ['TRIP OWNER', 'LEAD']);
      expect(RiderManagementSheet.roleBadges(owner: false, head: true, ridingRole: 'PACK'), ['TRIP HEAD', 'MIDDLE']);
      expect(RiderManagementSheet.roleBadges(owner: false, head: false, ridingRole: 'SWEEPER'), ['SWEEPER']);
      expect(RiderManagementSheet.roleBadges(owner: true, head: true, ridingRole: ''), ['TRIP OWNER', 'MIDDLE']);
    });

    test('one line per role; never "ride owner", "host" or "leader"', () {
      final text = RiderManagementSheet.roleExplanations.join(' ');
      expect(text, contains('Trip owner: created this trip.'));
      expect(text, contains('Trip head:'));
      // 3.55 owner decision: the trip head changes the settings only.
      expect(text, contains("Trip head: can change the trip's settings."));
      expect(text, isNot(contains('same rights')));
      expect(text, contains('Lead: rides first and guides the group.'));
      for (final banned in ['ride owner', 'host', 'leader']) {
        expect(text.toLowerCase(), isNot(contains(banned)));
      }
    });
  });
}
