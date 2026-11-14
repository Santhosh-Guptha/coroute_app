import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/home/home_feed.dart';
import 'package:coroute_app/domain/home/safety_nudges.dart';

void main() {
  const now = 1800000000000;
  const day = 86400000;

  group('nudge rotation', () {
    test('the most important missing item is shown', () {
      const s = SafetySetup(hasEmergencyContact: false, hasMedicalId: false, nearbyDevicesOk: false);
      expect(NudgeRotation.pick(s, dismissedAt: const {}, nowMs: now), SafetyNudge.emergencyContact);
      const s2 = SafetySetup(crashDetectionOn: false, hasMedicalId: false);
      expect(NudgeRotation.pick(s2, dismissedAt: const {}, nowMs: now), SafetyNudge.crashDetection);
    });

    test('nothing when everything is set up, or during a ride', () {
      expect(NudgeRotation.pick(const SafetySetup(), dismissedAt: const {}, nowMs: now), isNull);
      expect(NudgeRotation.pick(const SafetySetup(hasEmergencyContact: false), dismissedAt: const {}, nowMs: now, riding: true), isNull);
    });

    test('dismissing rotates to the next missing one', () {
      const s = SafetySetup(hasEmergencyContact: false, hasMedicalId: false);
      final d = NudgeRotation.dismiss(const {}, SafetyNudge.emergencyContact, now, s);
      expect(NudgeRotation.pick(s, dismissedAt: d, nowMs: now + 1000), SafetyNudge.medicalId);
      final d2 = NudgeRotation.dismiss(d, SafetyNudge.medicalId, now + 2000, s);
      expect(NudgeRotation.pick(s, dismissedAt: d2, nowMs: now + 3000), isNull);
    });

    test('a dismissed item comes back after the snooze while still missing', () {
      const s = SafetySetup(nearbyDevicesOk: false);
      final d = NudgeRotation.dismiss(const {}, SafetyNudge.nearbyDevices, now, s);
      expect(NudgeRotation.pick(s, dismissedAt: d, nowMs: now + 2 * day), isNull);
      expect(NudgeRotation.pick(s, dismissedAt: d, nowMs: now + 3 * day), SafetyNudge.nearbyDevices);
      // A clock moved backwards does not hide it for ever.
      expect(NudgeRotation.pick(s, dismissedAt: d, nowMs: now - day), SafetyNudge.nearbyDevices);
    });

    test('fixed items are forgotten, so they show at once if they go missing again', () {
      const before = SafetySetup(hasEmergencyContact: false, hasMedicalId: false);
      var d = NudgeRotation.dismiss(const {}, SafetyNudge.emergencyContact, now, before);
      const after = SafetySetup(hasMedicalId: false); // contact added
      d = NudgeRotation.dismiss(d, SafetyNudge.medicalId, now + 1, after);
      expect(d.containsKey(SafetyNudge.emergencyContact.key), isFalse);
      expect(NudgeRotation.pick(const SafetySetup(hasEmergencyContact: false, hasMedicalId: false), dismissedAt: d, nowMs: now + 2), SafetyNudge.emergencyContact);
    });

    test('every nudge has a line and an action in our own words', () {
      for (final n in SafetyNudge.values) {
        expect(n.line, isNotEmpty);
        expect(n.action.length, lessThanOrEqualTo(8));
      }
    });
  });

  group('home feed', () {
    test('safety check leads when it is due', () {
      expect(HomeFeed.heroCards(hasLastRide: true, safetyCheckDue: true).first, HeroCard.safetyCheck);
      expect(HomeFeed.heroCards(hasLastRide: false, safetyCheckDue: false),
          [HeroCard.ridesNearYou, HeroCard.groupRide, HeroCard.safetyCheck]);
    });

    test('carousel auto-advance respects reduced motion and touch', () {
      expect(CarouselPolicy.autoAdvance(reducedMotion: true, cards: 4, userHolding: false), isFalse);
      expect(CarouselPolicy.autoAdvance(reducedMotion: false, cards: 1, userHolding: false), isFalse);
      expect(CarouselPolicy.autoAdvance(reducedMotion: false, cards: 4, userHolding: true), isFalse);
      expect(CarouselPolicy.autoAdvance(reducedMotion: false, cards: 4, userHolding: false), isTrue);
      expect(CarouselPolicy.next(3, 4), 0);
    });

    test('upcoming: invites first, then by time, old ones dropped, five at most', () {
      final items = [
        const UpcomingItem(kind: UpcomingKind.clubRide, id: 'c1', title: 'Club', atMs: now + 2 * day),
        const UpcomingItem(kind: UpcomingKind.crewPoll, id: 'p1', title: 'Poll', atMs: now + day),
        const UpcomingItem(kind: UpcomingKind.rideInvite, id: 'r1', title: 'Invite', atMs: now + 3 * day),
        const UpcomingItem(kind: UpcomingKind.clubRide, id: 'old', title: 'Old', atMs: now - day),
        for (var i = 0; i < 4; i++) UpcomingItem(kind: UpcomingKind.crewPoll, id: 'x$i', title: 'X'),
      ];
      final m = UpcomingFeed.merge(items, nowMs: now);
      expect(m.map((i) => i.id).take(3).toList(), ['r1', 'p1', 'c1']);
      expect(m.length, UpcomingFeed.max);
      expect(m.any((i) => i.id == 'old'), isFalse);
    });

    test('when labels', () {
      final n = DateTime(2026, 11, 14, 9);
      expect(UpcomingFeed.whenLabel(DateTime(2026, 11, 14, 6, 30).millisecondsSinceEpoch, now: n), 'Today 06:30');
      expect(UpcomingFeed.whenLabel(DateTime(2026, 11, 15, 5, 45).millisecondsSinceEpoch, now: n), 'Tomorrow 05:45');
      expect(UpcomingFeed.whenLabel(DateTime(2026, 11, 21, 6).millisecondsSinceEpoch, now: n), 'Sat 21 Nov');
      expect(UpcomingFeed.whenLabel(0, now: n), '');
    });
  });
}
