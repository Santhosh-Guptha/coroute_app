import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/data/models/emergency_roster.dart';
import 'package:coroute_app/domain/safety/sms_plan.dart';

void main() {
  const me = (12.9716, 77.5946);
  // Roughly 1 km per 0.009 degrees of latitude.
  (double, double) north(double km) => (me.$1 + km * 0.009, me.$2);

  EmergencyRoster roster(List<RosterMember> members, {RosterContact? contact, int cap = 10}) => EmergencyRoster(
        groupId: 'GRP-1',
        fetchedAt: 0,
        validUntil: 1 << 50,
        cap: cap,
        members: members,
        emergencyContact: contact,
      );

  RosterMember rider(int i, {String role = 'PACK'}) => RosterMember(userId: 'u$i', role: role, phone: '+91 90000 000${i.toString().padLeft(2, '0')}');

  group('who gets the text', () {
    test('order: emergency contact, lead, sweeper, then the nearest riders', () {
      final r = roster([
        rider(1),
        rider(2),
        rider(3, role: 'SWEEPER'),
        rider(4, role: 'LEAD'),
        rider(5),
      ]);
      final plan = SmsPlanner.plan(
        roster: r,
        contact: const RosterContact(name: 'Brother', phone: '+91 91234 56780'),
        lastPositions: {'u1': north(5), 'u2': north(0.5), 'u5': north(2)},
        me: me,
      );
      expect([for (final x in plan.recipients) x.label], ['contact', 'lead', 'sweeper', 'rider', 'rider', 'rider']);
      expect(plan.recipients[0].phone, '+919123456780');
      expect(plan.recipients[1].phone, SmsPlanner.dialable(rider(4).phone));
      expect(plan.recipients[2].phone, SmsPlanner.dialable(rider(3).phone));
      // Nearest first: u2 (0.5 km), u5 (2 km), u1 (5 km).
      expect(plan.recipients.sublist(3).map((x) => x.phone).toList(),
          [SmsPlanner.dialable(rider(2).phone), SmsPlanner.dialable(rider(5).phone), SmsPlanner.dialable(rider(1).phone)]);
      expect(plan.eligible, 6);
      expect(plan.capped, 0);
    });

    test('riders without a known position come last, in roster order', () {
      final plan = SmsPlanner.plan(
        roster: roster([rider(1), rider(2), rider(3)]),
        lastPositions: {'u3': north(1)},
        me: me,
      );
      expect(plan.recipients.map((x) => x.phone).toList(),
          [SmsPlanner.dialable(rider(3).phone), SmsPlanner.dialable(rider(1).phone), SmsPlanner.dialable(rider(2).phone)]);
    });

    test('cap 10: the nearest are kept and the rest counted as capped', () {
      final members = [for (var i = 1; i <= 14; i++) rider(i)];
      final plan = SmsPlanner.plan(
        roster: roster(members),
        contact: const RosterContact(name: 'Mum', phone: '+91 91234 56780'),
        lastPositions: {for (var i = 1; i <= 14; i++) 'u$i': north(i.toDouble())},
        me: me,
      );
      expect(plan.recipients, hasLength(SafetyConstants.smsMaxRecipients));
      expect(plan.eligible, 15);
      expect(plan.capped, 5);
      expect(plan.recipients.first.label, 'contact');
      expect(plan.recipients.last.phone, SmsPlanner.dialable(rider(9).phone), reason: 'contact + the 9 nearest');
    });

    test('opted-out riders are not in the roster, so they are never texted', () {
      // The server leaves out riders with smsOptOut; the planner only texts what it is given.
      final plan = SmsPlanner.plan(roster: roster([rider(1)]), lastPositions: const {}, me: me);
      expect(plan.recipients.map((x) => x.phone), [SmsPlanner.dialable(rider(1).phone)]);
    });

    test('no duplicate phones (same number written differently, contact who is also a rider)', () {
      final plan = SmsPlanner.plan(
        roster: roster([
          const RosterMember(userId: 'a', role: 'LEAD', phone: '+91 98765 43210'),
          const RosterMember(userId: 'b', role: 'PACK', phone: '098765-43210'),
          const RosterMember(userId: 'c', role: 'PACK', phone: '+91 91234 56780'),
        ]),
        contact: const RosterContact(name: 'Friend', phone: '91234 56780'),
        lastPositions: const {},
        me: me,
      );
      expect(plan.recipients.map((x) => x.label).toList(), ['contact', 'lead']);
      expect(plan.eligible, 2);
    });

    test('the sender is never texted (by user id or by phone)', () {
      final plan = SmsPlanner.plan(
        roster: roster([
          const RosterMember(userId: 'me', role: 'LEAD', phone: '+91 90000 11111'),
          const RosterMember(userId: 'x', role: 'PACK', phone: '+91 90000 22222'),
          const RosterMember(userId: 'y', role: 'PACK', phone: '+91 90000 33333'),
        ]),
        lastPositions: const {},
        me: me,
        selfUserId: 'me',
        selfPhone: '9000033333',
      );
      expect(plan.recipients.map((x) => x.phone).toList(), ['+919000022222']);
    });

    test('the text budget limits how many people get it', () {
      final members = [for (var i = 1; i <= 8; i++) rider(i)];
      final two = SmsPlanner.plan(roster: roster(members), lastPositions: const {}, me: me, partsLeft: 7, partsPerMessage: 2);
      expect(two.recipients, hasLength(3), reason: '7 parts left, 2 parts each');
      expect(two.capped, 5);
      final none = SmsPlanner.plan(roster: roster(members), lastPositions: const {}, me: me, partsLeft: 0);
      expect(none.recipients, isEmpty);
      expect(none.capped, 8);
    });

    test('without a roster (offline before it was fetched) the emergency contact still gets it', () {
      final plan = SmsPlanner.plan(
        contact: const RosterContact(name: 'Wife', phone: '+91 91234 56780'),
        lastPositions: const {},
        me: me,
      );
      expect(plan.recipients.single.label, 'contact');
    });

    test('the roster contact is used when the phone has none', () {
      final plan = SmsPlanner.plan(
        roster: roster(const [], contact: const RosterContact(name: 'Dad', phone: '+91 91234 56780')),
        lastPositions: const {},
        me: me,
      );
      expect(plan.recipients.single.label, 'contact');
    });

    test('printing a plan or recipient shows no phone number', () {
      final plan = SmsPlanner.plan(roster: roster([rider(1)]), lastPositions: const {}, me: me);
      expect(plan.toString(), isNot(contains('9000')));
      expect(plan.recipients.single.toString(), isNot(contains('9000')));
    });
  });

  group('the text', () {
    final at = DateTime(2026, 10, 8, 10, 42);

    test('map link with 5 decimals, time, ride name', () {
      final body = SmsText.sos(name: 'Kiran', auto: false, lat: 12.971598, lng: 77.594562, at: at, convoyName: 'Nandi Hills');
      expect(body, contains('https://maps.google.com/?q=12.97160,77.59456'));
      expect(body, contains('Kiran'));
      expect(body, contains('10:42'));
      expect(body, contains('Nandi Hills'));
      expect(body.toLowerCase(), isNot(contains('automatic')));
    });

    test('a crash SOS says it is automatic', () {
      final body = SmsText.sos(name: 'Kiran', auto: true, lat: 12.97, lng: 77.59, at: at);
      expect(body.toLowerCase(), contains('automatic'));
      expect(body, contains('crash'));
    });

    test('no phone numbers in the text', () {
      final body = SmsText.sos(name: 'Kiran', auto: true, lat: 12.97, lng: 77.59, at: at, convoyName: 'Ride 1');
      final withoutLink = body.replaceAll(RegExp(r'https://\S+'), '');
      expect(RegExp(r'\d{6,}').hasMatch(withoutLink), isFalse);
      expect(body, isNot(contains('+')));
    });

    test('part counting: GSM 7-bit and Unicode', () {
      expect(SmsText.parts('a' * 160), 1);
      expect(SmsText.parts('a' * 161), 2);
      expect(SmsText.parts('a' * 306), 2);
      expect(SmsText.parts('a' * 307), 3);
      expect(SmsText.parts('{' * 80), 1, reason: 'extension characters count twice');
      expect(SmsText.parts('{' * 81), 2);
      expect(SmsText.parts('क' * 70), 1, reason: 'Devanagari: Unicode, 70 per part');
      expect(SmsText.parts('क' * 71), 2);
      final body = SmsText.sos(name: 'Kiran', auto: true, lat: 12.97, lng: 77.59, at: at, convoyName: 'Nandi Hills');
      expect(SmsText.parts(body), 1, reason: 'a normal crash text fits one part');
    });
  });
}
