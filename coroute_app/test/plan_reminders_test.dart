import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/config/feature_gates.dart';
import 'package:coroute_app/data/services/plan_subscription_service.dart';
import 'package:coroute_app/data/services/subscription_reminders.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records what the service asks to schedule instead of touching the plugin.
class _FakeScheduler extends PlanReminderScheduler {
  final List<List<PlanReminder>> scheduled = [];
  int cancels = 0;

  @override
  bool get supported => true;

  @override
  Future<void> schedule(List<PlanReminder> reminders, SubscriptionTier tier) async => scheduled.add(reminders);

  @override
  Future<void> cancelAll() async => cancels++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const day = Duration(days: 1);
  final now = DateTime(2026, 11, 1, 10);

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    FeatureGates.activeTier = SubscriptionTier.community;
    FeatureGates.forceAllUnlocked = false;
  });

  group('computePlanReminders', () {
    test('a plan 10 days out gets reminders 7, 3 and 1 day before and at the end', () {
      final end = now.add(const Duration(days: 10));
      final r = computePlanReminders(tier: SubscriptionTier.proRider, validUntilMs: end.millisecondsSinceEpoch, now: now);
      expect(r.map((e) => e.daysBefore), [7, 3, 1, 0]);
      expect(r[0].at, end.subtract(day * 7));
      expect(r[1].at, end.subtract(day * 3));
      expect(r[2].at, end.subtract(day));
      expect(r[3].at, end);
      expect(r.map((e) => e.id).toSet().length, 4, reason: 'one stable id per step');
      expect(r[0].title, 'Your CoRoute Pro ends in 7 days');
      expect(r[2].title, 'Your CoRoute Pro ends in 1 day');
      expect(r[3].title, 'Your CoRoute Pro has ended');
    });

    test('steps already in the past are skipped', () {
      final end = now.add(const Duration(days: 2, hours: 5));
      final r = computePlanReminders(tier: SubscriptionTier.roadCaptain, validUntilMs: end.millisecondsSinceEpoch, now: now);
      expect(r.map((e) => e.daysBefore), [1, 0]);
      expect(r.every((e) => e.at.isAfter(now)), isTrue);
    });

    test('a step exactly now is not scheduled', () {
      final end = now.add(const Duration(days: 3));
      final r = computePlanReminders(tier: SubscriptionTier.proRider, validUntilMs: end.millisecondsSinceEpoch, now: now);
      expect(r.map((e) => e.daysBefore), [1, 0]);
    });

    test('nothing for Community, no end date, or a plan that already ended', () {
      final future = now.add(const Duration(days: 30)).millisecondsSinceEpoch;
      expect(computePlanReminders(tier: SubscriptionTier.community, validUntilMs: future, now: now), isEmpty);
      expect(computePlanReminders(tier: SubscriptionTier.proRider, validUntilMs: 0, now: now), isEmpty);
      expect(
        computePlanReminders(tier: SubscriptionTier.proRider, validUntilMs: now.subtract(day).millisecondsSinceEpoch, now: now),
        isEmpty,
      );
    });

    test('ids stay inside the reminder id range', () {
      final end = now.add(const Duration(days: 40));
      final r = computePlanReminders(tier: SubscriptionTier.tourOperator, validUntilMs: end.millisecondsSinceEpoch, now: now);
      for (final x in r) {
        expect(planReminderIds, contains(x.id));
      }
    });

    test('payload names the tier and parses back', () {
      final p = planReminderPayload(SubscriptionTier.roadCaptain);
      expect(p, 'PLAN:roadCaptain');
      expect(tierFromPlanReminderPayload(p), SubscriptionTier.roadCaptain);
      expect(tierFromPlanReminderPayload('CRASH'), isNull);
      expect(tierFromPlanReminderPayload(null), isNull);
      expect(tierFromPlanReminderPayload('PLAN:nope'), isNull);
    });
  });

  group('PlanSubscriptionService reminders', () {
    test('a new paid plan schedules reminders; renewing reschedules; expiry cancels', () async {
      final fake = _FakeScheduler();
      final service = PlanSubscriptionService(null, fake);
      addTearDown(service.dispose);
      final until = DateTime.now().add(const Duration(days: 20)).millisecondsSinceEpoch;

      service.applyServerSubscription('proRider', until);
      expect(fake.scheduled, hasLength(1));
      expect(fake.scheduled.single.map((e) => e.daysBefore), [7, 3, 1, 0]);

      // Same plan, same date (a re-sync): nothing new.
      service.applyServerSubscription('proRider', until);
      expect(fake.scheduled, hasLength(1));

      // Renewed: new end date, rescheduled.
      service.applyServerSubscription('proRider', until + 30 * 86400000);
      expect(fake.scheduled, hasLength(2));

      final cancelsBefore = fake.cancels;
      service.handleExpiredEvent({'previousTier': 'proRider', 'expiredAt': DateTime.now().millisecondsSinceEpoch});
      expect(fake.cancels, cancelsBefore + 1);
    });

    test('revoke and sign-out cancel the reminders', () async {
      final fake = _FakeScheduler();
      final service = PlanSubscriptionService(null, fake);
      addTearDown(service.dispose);
      service.applyServerSubscription('roadCaptain', DateTime.now().add(const Duration(days: 9)).millisecondsSinceEpoch);
      expect(fake.scheduled, hasLength(1));

      service.handleRevokedEvent({'previousTier': 'roadCaptain', 'revokedAt': DateTime.now().millisecondsSinceEpoch, 'reason': 'chargeback'});
      expect(fake.cancels, 1);

      service.applyServerSubscription('roadCaptain', DateTime.now().add(const Duration(days: 9)).millisecondsSinceEpoch);
      await service.resetLocal();
      expect(fake.cancels, 2);
    });
  });
}
