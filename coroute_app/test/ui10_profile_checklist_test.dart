import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/profile/riding_checklist.dart';

void main() {
  group('riding profile checklist', () {
    test('a new rider sees seven steps, safety first', () {
      final r = RidingChecklist.of(const ProfileFacts());
      expect(r.total, 7);
      expect(r.doneCount, 0);
      expect(r.progress, 0);
      expect(r.next, ChecklistItem.emergencyContact);
      expect(r.items.first.$1.safety, isTrue);
      expect(r.summary, '0 of 7 done');
    });

    test('progress counts done steps and next skips them', () {
      final r = RidingChecklist.of(const ProfileFacts(hasEmergencyContact: true, hasMedicalId: true, hasBike: true));
      expect(r.doneCount, 3);
      expect(r.progress, closeTo(3 / 7, 1e-9));
      expect(r.next, ChecklistItem.nearbyDevices);
    });

    test('pillion: no bike step; photos off: no avatar step', () {
      final r = RidingChecklist.of(const ProfileFacts(pillion: true, photosOn: false));
      expect(r.items.map((i) => i.$1), isNot(contains(ChecklistItem.bike)));
      expect(r.items.map((i) => i.$1), isNot(contains(ChecklistItem.avatar)));
      expect(r.total, 5);
    });

    test('complete when everything is done', () {
      final r = RidingChecklist.of(const ProfileFacts(
        hasEmergencyContact: true,
        hasMedicalId: true,
        hasBike: true,
        nearbyDevicesOk: true,
        preRideCheckDone: true,
        hasAvatar: true,
        hasInterests: true,
      ));
      expect(r.complete, isTrue);
      expect(r.next, isNull);
      expect(r.progress, 1);
    });

    test('riding since', () {
      expect(RidingChecklist.ridingSince(0), '');
      expect(RidingChecklist.ridingSince(DateTime(2026, 11, 3).millisecondsSinceEpoch), 'Riding since Nov 2026');
    });

    test('labels are short and unique', () {
      final labels = ChecklistItem.values.map((i) => i.label).toSet();
      expect(labels.length, ChecklistItem.values.length);
      expect(RidingChecklist.interestChoices, contains('Ghats'));
    });
  });
}
