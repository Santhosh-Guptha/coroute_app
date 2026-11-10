// 3.55 ratings & reviews (docs/features_355/ratings_reviews.md). Pure Dart: the "Rate CoRoute" ask
// scheduler, the engagement config / chip parsing (with the Play-policy safety net) and the order
// of the after-ride wrap-up cards.
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/engagement/engagement_config.dart';
import 'package:coroute_app/domain/engagement/rating_ask_scheduler.dart';
import 'package:coroute_app/domain/engagement/ride_wrapup_flow.dart';

const int day = 86400000;
final int now = DateTime.utc(2026, 11, 10, 12).millisecondsSinceEpoch;

/// The 3rd clean ride ended 5 minutes ago; installed 60 days ago; never asked.
RatingAskInput input({
  RatingPromptRules rules = RatingPromptRules.defaults,
  RatingAskMoment moment = RatingAskMoment.rideSummaryClosed,
  List<int> asked = const [],
  int cleanRides = 3,
  int? pendingSinceMs,
  int? lastRideEndMs,
  bool lastRideHadProblem = false,
  int lastProblemMs = 0,
  int sessionErrors = 0,
  bool rideActive = false,
  bool emergencyActive = false,
  bool storeAvailable = true,
  int? firstSeenMs,
}) =>
    RatingAskInput(
      nowMs: now,
      rules: rules,
      moment: moment,
      askedAtMs: asked,
      cleanRides: cleanRides,
      pendingSinceMs: pendingSinceMs ?? now - 5 * 60000,
      lastRideEndMs: lastRideEndMs ?? now - 5 * 60000,
      lastRideHadProblem: lastRideHadProblem,
      lastProblemMs: lastProblemMs,
      sessionErrors: sessionErrors,
      rideActive: rideActive,
      emergencyActive: emergencyActive,
      storeAvailable: storeAvailable,
      firstSeenMs: firstSeenMs ?? now - 60 * day,
    );

RatingAskVerdict eval(RatingAskInput i) => RatingAskScheduler.evaluate(i);

WrapUpPlace place(String id, String cat, int dwell, {int at = 0}) => WrapUpPlace(placeId: id, name: id, category: cat, dwellMin: dwell, atMs: at);

void main() {
  group('rating ask scheduler', () {
    test('asks after the 3rd clean ride, on the summary or at the next app open', () {
      expect(eval(input(cleanRides: 2)), RatingAskVerdict.notEnoughRides);
      expect(eval(input()), RatingAskVerdict.ask);
      expect(eval(input(moment: RatingAskMoment.appOpen)), RatingAskVerdict.ask);
      expect(RatingAskScheduler.shouldAsk(input(cleanRides: 9)), isTrue);
    });

    test('admin rules: N rides, cooldown, yearly cap, off', () {
      expect(eval(input(rules: const RatingPromptRules(afterRides: 5), cleanRides: 4)), RatingAskVerdict.notEnoughRides);
      expect(eval(input(rules: const RatingPromptRules(enabled: false))), RatingAskVerdict.disabled);
      expect(eval(input(asked: [now - 29 * day])), RatingAskVerdict.cooldown);
      expect(eval(input(asked: [now - 30 * day])), RatingAskVerdict.ask);
      expect(eval(input(rules: const RatingPromptRules(cooldownDays: 60), asked: [now - 45 * day])), RatingAskVerdict.cooldown);
      // 3 asks in the last year: no more, even with the cooldown over.
      expect(eval(input(asked: [now - 300 * day, now - 200 * day, now - 100 * day])), RatingAskVerdict.yearlyCap);
      expect(eval(input(asked: [now - 400 * day, now - 200 * day, now - 100 * day])), RatingAskVerdict.ask);
      expect(eval(input(rules: const RatingPromptRules(maxPerYear: 1), asked: [now - 100 * day])), RatingAskVerdict.yearlyCap);
    });

    test('hard limits hold whatever the server sends', () {
      final r = RatingPromptRules.parse({'enabled': true, 'afterRides': 0, 'cooldownDays': 1, 'maxPerYear': 50});
      expect(r.afterRides, 1);
      expect(r.cooldownDays, RatingPromptRules.minCooldownDays);
      expect(r.maxPerYear, 3);
      // Even a rules object built by hand cannot go past the caps.
      const loose = RatingPromptRules(cooldownDays: 1, maxPerYear: 9);
      expect(eval(input(rules: loose, asked: [now - 10 * day])), RatingAskVerdict.cooldown);
      expect(eval(input(rules: loose, asked: [now - 300 * day, now - 200 * day, now - 100 * day])), RatingAskVerdict.yearlyCap);
    });

    test('never during a ride, an emergency, or right after the ride ends', () {
      expect(eval(input(rideActive: true)), RatingAskVerdict.rideActive);
      expect(eval(input(emergencyActive: true)), RatingAskVerdict.emergencyActive);
      expect(eval(input(lastRideEndMs: now - 10 * 1000)), RatingAskVerdict.tooSoonAfterRide);
      expect(eval(input(lastRideEndMs: now - 25 * 1000)), RatingAskVerdict.ask);
    });

    test('never after a problem: SOS / crash ride, recent problem, error-heavy session', () {
      expect(eval(input(lastRideHadProblem: true)), RatingAskVerdict.problemRide);
      expect(eval(input(lastProblemMs: now - 6 * day)), RatingAskVerdict.recentProblem);
      expect(eval(input(lastProblemMs: now - 8 * day)), RatingAskVerdict.ask);
      expect(eval(input(sessionErrors: RatingAskScheduler.errorHeavy)), RatingAskVerdict.errorHeavySession);
      expect(eval(input(sessionErrors: RatingAskScheduler.errorHeavy - 1)), RatingAskVerdict.ask);
      // A problem ride leaves nothing pending.
      expect(RatingAskScheduler.pendingAfterRide(hadProblem: true, endedAtMs: now), 0);
      expect(RatingAskScheduler.pendingAfterRide(hadProblem: false, endedAtMs: now), now);
    });

    test('needs a finished ride waiting (expires after 3 days); no store, new install', () {
      expect(eval(input(pendingSinceMs: 0)), RatingAskVerdict.nothingPending);
      expect(eval(input(pendingSinceMs: now - 4 * day, lastRideEndMs: now - 4 * day)), RatingAskVerdict.nothingPending);
      expect(eval(input(pendingSinceMs: now - 2 * day, lastRideEndMs: now - 2 * day, moment: RatingAskMoment.appOpen)), RatingAskVerdict.ask);
      expect(eval(input(storeAvailable: false)), RatingAskVerdict.noStore);
      expect(eval(input(firstSeenMs: now - day)), RatingAskVerdict.tooSoonAfterInstall);
      expect(eval(input(firstSeenMs: 0)), RatingAskVerdict.tooSoonAfterInstall, reason: 'unknown install time counts as now');
    });

    test('prune keeps only the last year, at most 10, oldest first', () {
      final asks = [now - 400 * day, now - 10 * day, now - 100 * day, 0, for (var i = 0; i < 12; i++) now - (20 + i) * day];
      final p = RatingAskScheduler.prune(asks, now);
      expect(p.length, 10);
      expect(p.every((a) => now - a < 365 * day), isTrue);
      expect(p, [...p]..sort());
      expect(p.last, now - 10 * day);
    });
  });

  group('engagement config and chips', () {
    test('defaults: texts in en/hi/te, trip chips, place chips per group, owner rules', () {
      final d = EngagementConfig.defaults;
      expect(d.text('tripTitle', 'en'), 'How was the ride?');
      expect(d.text('tripTitle', 'te'), isNotEmpty);
      expect(d.tripChips.map((c) => c.id), ['great_route', 'good_pace', 'too_fast', 'long_breaks', 'bad_roads', 'safe_group']);
      expect(d.chipsForPlace('stay').map((c) => c.id), ['clean', 'bike_parking', 'safe', 'good_value']);
      expect(d.chipsForPlace('food').map((c) => c.id), contains('hygienic'));
      expect(d.ratingPrompt.afterRides, 3);
      expect(d.ratingPrompt.cooldownDays, 30);
      expect(d.ratingPrompt.maxPerYear, 3);
      expect(d.reviews.reportDays, 7);
      for (final t in d.texts.values) {
        for (final v in t.byLang.values) {
          expect(EngagementConfig.policyProblem(v), isFalse, reason: v);
        }
      }
    });

    test('category -> chip group (same table as the gateway)', () {
      expect(EngagementConfig.groupOf('stay'), ChipGroup.stay);
      expect(EngagementConfig.groupOf('food'), ChipGroup.food);
      expect(EngagementConfig.groupOf('ev'), ChipGroup.fuel);
      expect(EngagementConfig.groupOf('fuel'), ChipGroup.fuel);
      expect(EngagementConfig.groupOf('heritage'), ChipGroup.viewpoint);
      expect(EngagementConfig.groupOf('hospital'), ChipGroup.other);
      expect(EngagementConfig.groupOf('anything'), ChipGroup.other);
    });

    test('parses the server config; bad parts keep their defaults; never throws', () {
      final c = EngagementConfig.parse({
        'version': 4,
        'config': {
          'texts': {
            'tripTitle': {'en': 'Ride done! How was it?', 'hi': 'राइड कैसी थी?'},
            'placesTitle': {'hi': 'only hindi'}, // no English: default kept
            'rateSubtitle': {'en': 'Rate us to get a free month'}, // policy: default kept
            'thanks': '<b>Saved</b>',
          },
          'tripChips': [
            {'id': 'scenic', 'label': {'en': 'Scenic', 'te': 'అందమైన'}},
            {'id': 'scenic', 'label': {'en': 'Dup'}},
            {'id': 'Bad Id', 'label': {'en': 'x'}},
            {'id': 'cash', 'label': {'en': 'Cashback'}},
            {'id': 'nolabel'},
          ],
          'placeChips': {'stay': 'nope', 'food': []},
          'ratingPrompt': {'enabled': false, 'afterRides': 5, 'cooldownDays': 'x', 'maxPerYear': 2},
          'reviews': {'maxPlaces': 9, 'reportDays': -3, 'placesEnabled': false},
        },
      });
      expect(c.version, 4);
      expect(c.text('tripTitle', 'en'), 'Ride done! How was it?');
      expect(c.text('tripTitle', 'hi'), 'राइड कैसी थी?');
      expect(c.text('tripTitle', 'te'), 'Ride done! How was it?', reason: 'English fallback');
      expect(c.text('placesTitle', 'en'), 'Places you stopped at');
      expect(c.text('rateSubtitle', 'en'), 'Share your opinion on Google Play');
      expect(c.text('thanks', 'en'), 'Saved');
      expect(c.tripChips.map((x) => x.id), ['scenic']);
      expect(c.tripChips.first.label.pick('te'), 'అందమైన');
      expect(c.tripChips.first.label.pick('hi'), 'Scenic');
      expect(c.chipsForPlace('stay').length, 4, reason: 'not a list: default');
      expect(c.chipsForPlace('food'), isEmpty, reason: 'an empty list hides the chips');
      expect(c.ratingPrompt.enabled, isFalse);
      expect(c.ratingPrompt.afterRides, 5);
      expect(c.ratingPrompt.cooldownDays, 30);
      expect(c.ratingPrompt.maxPerYear, 2);
      expect(c.reviews.maxPlaces, 2);
      expect(c.reviews.reportDays, 0);
      expect(c.reviews.placesEnabled, isFalse);

      expect(EngagementConfig.parse(null).version, 0);
      expect(EngagementConfig.parse('not json').tripChips.length, 6);
      expect(EngagementConfig.parse([1, 2]).text('tripTitle', 'en'), 'How was the ride?');
    });

    test('cache round trip keeps everything', () {
      final c = EngagementConfig.parse({
        'version': 2,
        'config': {
          'tripChips': [
            {'id': 'a', 'label': {'en': 'A'}}
          ],
          'ratingPrompt': {'afterRides': 7},
        },
      });
      final back = EngagementConfig.parse(c.toJson());
      expect(back.version, 2);
      expect(back.tripChips.single.id, 'a');
      expect(back.ratingPrompt.afterRides, 7);
      expect(back.chipsForPlace('viewpoint').map((x) => x.id), c.chipsForPlace('viewpoint').map((x) => x.id));
    });

    test('policy safety net', () {
      for (final bad in ['Only ₹99', 'Use coupon RIDE10', 'Win a helmet', 'Enjoying CoRoute? Rate us', 'Not happy? Send feedback instead', 'कूपन', 'ఉచిత']) {
        expect(EngagementConfig.policyProblem(bad), isTrue, reason: bad);
      }
      for (final ok in ['Great view', 'Good value', 'Rate CoRoute', 'Viewpoints']) {
        expect(EngagementConfig.policyProblem(ok), isFalse, reason: ok);
      }
    });
  });

  group('after-ride wrap-up order', () {
    const rules = ReviewRules.defaults;

    test('trip first, then places by longest stay, at most 3 cards', () {
      final items = RideWrapUpFlow.build(
        rules: rules,
        tripId: 'GRP-1',
        tripName: 'Coast run',
        canReviewTrip: true,
        tripReviewed: false,
        places: [place('fuel1', 'fuel', 12, at: 1), place('stay1', 'stay', 600, at: 3), place('food1', 'food', 40, at: 2), place('view1', 'viewpoint', 25, at: 4)],
      );
      expect(items.map((e) => e.kind), [WrapUpKind.trip, WrapUpKind.place, WrapUpKind.place]);
      expect(items.map((e) => e.id), ['GRP-1', 'stay1', 'food1']);
      expect(items.length, lessThanOrEqualTo(RideWrapUpFlow.maxItems));
    });

    test('no trip card when reviewed, not allowed or switched off; places dedupe and tie order', () {
      List<String> ids({bool can = true, bool reviewed = false, ReviewRules r = rules, List<WrapUpPlace>? ps}) => RideWrapUpFlow.build(
            rules: r,
            tripId: 'GRP-1',
            tripName: '',
            canReviewTrip: can,
            tripReviewed: reviewed,
            places: ps ?? [place('a', 'food', 30, at: 5), place('b', 'stay', 30, at: 2), place('a', 'food', 45, at: 9), place('c', 'fuel', 5)],
          ).map((e) => e.id).toList();
      expect(ids(reviewed: true), ['a', 'b'], reason: 'longest stay first; a counted once with its longer stay');
      expect(ids(can: false), ['a', 'b']);
      expect(ids(r: const ReviewRules(tripEnabled: false)), ['a', 'b']);
      expect(ids(r: const ReviewRules(placesEnabled: false)), ['GRP-1']);
      expect(ids(r: const ReviewRules(maxPlaces: 1)), ['GRP-1', 'a']);
      expect(ids(r: const ReviewRules(maxPlaces: 0)), ['GRP-1']);
      expect(ids(ps: [place('x', 'food', 30, at: 9), place('y', 'food', 30, at: 1)], reviewed: true), ['y', 'x'], reason: 'tie: earlier first');
      expect(ids(ps: const [], can: false), isEmpty);
    });

    test('chips per card and the trip body (private, chips offered only, note capped)', () {
      final cfg = EngagementConfig.defaults;
      final items = RideWrapUpFlow.build(rules: rules, tripId: 'T', tripName: '', canReviewTrip: true, tripReviewed: false, places: [place('s', 'stay', 90)]);
      expect(RideWrapUpFlow.chipsFor(items[0], cfg).map((c) => c.id), contains('safe_group'));
      expect(RideWrapUpFlow.chipsFor(items[1], cfg).map((c) => c.id), ['clean', 'bike_parking', 'safe', 'good_value']);
      final body = RideWrapUpFlow.tripBody(rating: 9, chips: {'too_fast', 'great_route', 'clean'}, note: '  ${'x' * 400}  ', offered: cfg.tripChips);
      expect(body['rating'], 5);
      expect(body['chips'], ['great_route', 'too_fast'], reason: 'offered order, unknown dropped');
      expect((body['writtenFeedback'] as String).length, EngagementConfig.noteMax);
      expect(body['consentPublish'], isFalse);
      expect(body['consentPhoto'], isFalse);
    });

    test('trip report offers the quick review for up to 7 days after the ride', () {
      bool offer({int ageDays = 1, bool reviewed = false, bool can = true, bool dismissed = false, ReviewRules r = rules}) => RideWrapUpFlow.offerOnReport(
            rules: r,
            endedAtMs: now - ageDays * day,
            nowMs: now,
            canReview: can,
            reviewed: reviewed,
            dismissedOnReport: dismissed,
          );
      expect(offer(), isTrue);
      expect(offer(ageDays: 7), isTrue);
      expect(offer(ageDays: 8), isFalse);
      expect(offer(reviewed: true), isFalse);
      expect(offer(can: false), isFalse);
      expect(offer(dismissed: true), isFalse);
      expect(offer(r: const ReviewRules(reportDays: 2), ageDays: 3), isFalse);
      expect(offer(r: const ReviewRules(tripEnabled: false)), isFalse);
    });
  });
}
