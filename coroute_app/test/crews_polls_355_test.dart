// 3.55 Crews and crew polls: pure rules and result math (docs/features_355/crews_polls.md).
// Mirrors gateway/test/crews_polls_355.test.js where the rules overlap.
import 'package:coroute_app/data/services/crews_service.dart';
import 'package:coroute_app/domain/social/crew_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('crew name and description', () {
    test('length, cleaning, contact details', () {
      expect(CrewRules.clean('  Deccan   <b>Riders</b> '), 'Deccan bRiders/b');
      for (final ok in ['abc', 'Essex Riders', 'Ghats 2026', 'a' * 40]) {
        expect(CrewRules.checkName(ok), isNull, reason: ok);
      }
      for (final bad in ['ab', 'a' * 41, '   ', '!!!', 'Call 9876543210', 'me@mail.com crew', 'www.crew.in']) {
        expect(CrewRules.checkName(bad), isNotNull, reason: bad);
      }
      expect(CrewRules.checkDescription('x' * 200), isNull);
      expect(CrewRules.checkDescription('x' * 201), isNotNull);
      expect(CrewRules.checkDescription(''), isNull);
      expect(CrewRules.checkDescription('ping 98765 43210'), isNotNull);
    });
  });

  group('poll validation', () {
    final now = DateTime(2026, 11, 9, 10);
    String? check(String q, List<String> o, [DateTime? closes]) => CrewRules.checkPoll(question: q, options: o, closesAt: closes, now: now);

    test('question and options', () {
      expect(check('Where next?', ['Nandi Hills', 'Coorg']), isNull);
      expect(check('', ['a', 'b']), isNotNull);
      expect(check('q' * 121, ['a', 'b']), isNotNull);
      expect(check('q' * 120, ['a', 'b']), isNull);
      expect(check('q', ['a']), isNotNull);
      expect(check('q', ['1', '2', '3', '4', '5', '6']), isNull);
      expect(check('q', ['1', '2', '3', '4', '5', '6', '7']), isNotNull);
      expect(check('q', ['a', ' ']), isNotNull);
      expect(check('q', ['a', 'o' * 61]), isNotNull);
      expect(check('q', ['Coorg', ' coorg ']), 'Two options are the same.');
      expect(check('Call 9876543210?', ['a', 'b']), isNotNull);
    });

    test('deadline: 10 minutes to 30 days', () {
      expect(check('q', ['a', 'b'], now.add(const Duration(days: 30))), isNull);
      expect(check('q', ['a', 'b'], now.add(const Duration(days: 31))), isNotNull);
      expect(check('q', ['a', 'b'], now.add(const Duration(minutes: 5))), isNotNull);
      expect(CrewLimits.pollDefault, const Duration(days: 3));
    });

    test('votes: one answer or several distinct ones', () {
      const ids = ['o1', 'o2', 'o3'];
      expect(checkVote(multi: false, optionIds: ids, picked: ['o2']), isNull);
      expect(checkVote(multi: false, optionIds: ids, picked: ['o1', 'o2']), isNotNull);
      expect(checkVote(multi: false, optionIds: ids, picked: []), isNotNull);
      expect(checkVote(multi: true, optionIds: ids, picked: ['o1', 'o3']), isNull);
      expect(checkVote(multi: true, optionIds: ids, picked: ['o1', 'o1']), isNotNull);
      expect(checkVote(multi: true, optionIds: ids, picked: ['o9']), isNotNull);
    });
  });

  group('result math', () {
    test('counts, percent of voters, leaders, bar fill', () {
      final t = PollTally.of(['o1', 'o2', 'o3'], [
        ['o1', 'o3'],
        ['o1'],
        ['o2'],
        [],
        ['zz'],
      ]);
      expect(t.totalVoters, 3);
      expect(t.counts, {'o1': 2, 'o2': 1, 'o3': 1});
      expect(t.percents, {'o1': 67, 'o2': 33, 'o3': 33});
      expect(t.leaders, ['o1']);
      expect(t.fill('o1'), closeTo(2 / 3, 1e-9));
    });

    test('no votes and ties', () {
      final none = PollTally.of(['o1', 'o2'], const []);
      expect(none.totalVoters, 0);
      expect(none.percents.values, everyElement(0));
      expect(none.leaders, isEmpty);
      expect(none.fill('o1'), 0);
      final tie = PollTally.of(['o1', 'o2'], [
        ['o1'],
        ['o2'],
      ]);
      expect(tie.leaders, ['o1', 'o2']);
      expect(tie.percents, {'o1': 50, 'o2': 50});
    });

    test('a vote listing an option twice counts once', () {
      final t = PollTally.of(['o1'], [
        ['o1', 'o1'],
      ]);
      expect(t.counts['o1'], 1);
      expect(t.percents['o1'], 100);
    });
  });

  group('gateway payloads', () {
    test('poll with named votes', () {
      final p = CrewPoll.fromJson({
        'pollId': 'po_0123456789abcdef',
        'question': 'Where on Sunday?',
        'options': [
          {'id': 'o1', 'text': 'Nandi Hills', 'count': 0, 'percent': 0},
          {'id': 'o2', 'text': 'Coorg', 'count': 2, 'percent': 67},
          {'id': 'o3', 'text': 'Skandagiri', 'count': 1, 'percent': 33},
        ],
        'status': 'OPEN',
        'totalVoters': 3,
        'myVote': ['o2'],
        'leaders': ['o2'],
        'canClose': true,
        'voters': {
          'o1': [],
          'o2': [
            {'username': 'SwiftFalcon482', 'displayName': 'Asha'},
            {'username': 'ThrottleTiger907', 'displayName': 'Ravi'},
          ],
          'o3': [
            {'username': 'MistyRider11', 'displayName': 'Kiran'},
          ],
        },
      });
      expect(p.open, isTrue);
      expect(p.multi, isFalse);
      expect(p.myVote, ['o2']);
      expect(p.voters['o2'], ['SwiftFalcon482', 'ThrottleTiger907']);
      expect(p.fill('o2'), closeTo(2 / 3, 1e-9));
      expect(p.fill('o9'), 0);
    });

    test('anonymous closed poll has no names', () {
      final p = CrewPoll.fromJson({
        'pollId': 'po_1',
        'question': 'Snacks?',
        'options': [
          {'id': 'o1', 'text': 'Chai', 'count': 1, 'percent': 100},
          {'id': 'o2', 'text': 'Vada', 'count': 0, 'percent': 0},
        ],
        'status': 'CLOSED',
        'anonymous': true,
        'multi': true,
        'totalVoters': 1,
      });
      expect(p.open, isFalse);
      expect(p.voters, isEmpty);
      expect(p.canClose, isFalse);
    });

    test('crew detail: members carry username, first name, picture and role only', () {
      final d = CrewDetail.fromJson({
        'crew': {
          'crewId': 'cr_0123456789abcdef',
          'name': 'Sunday Riders',
          'myRole': 'ADMIN',
          'canInvite': true,
          'canCreatePoll': true,
          'settings': {'membersCanCreatePolls': false},
        },
        'members': [
          {'username': 'SwiftFalcon482', 'displayName': 'Asha', 'avatarUrl': '/api/avatars/av_x', 'role': 'ADMIN', 'joinedAt': 1},
          {'username': 'ThrottleTiger907', 'displayName': 'Ravi', 'avatarUrl': 'https://evil.example/x.png', 'role': 'CO_ADMIN', 'joinedAt': 2},
        ],
        'invites': [
          {'inviteId': 'ci_1', 'username': 'MistyRider11', 'expiresAt': 5},
        ],
      });
      expect(d.isAdmin, isTrue);
      expect(d.coAdmins, 1);
      expect(d.members.first.avatarUrl, '/api/avatars/av_x');
      expect(d.members.last.avatarUrl, isNull, reason: 'only gateway picture paths are loaded');
      expect(d.invites.single.username, 'MistyRider11');
      expect(CrewRoles.label('CO_ADMIN'), 'Co-admin');
    });
  });

  group('labels and template', () {
    test('ride date template: next four weekend days', () {
      final t = CrewRules.rideDateTemplate(DateTime(2026, 11, 9)); // a Monday
      expect(t.question, 'When shall we ride?');
      expect(t.options, ['Sat 14 Nov', 'Sun 15 Nov', 'Sat 21 Nov', 'Sun 22 Nov']);
      expect(CrewRules.checkPoll(question: t.question, options: t.options), isNull);
    });

    test('closes label', () {
      final now = DateTime(2026, 11, 9, 10);
      expect(CrewRules.closesLabel(now.add(const Duration(days: 3, hours: 1)), now: now), 'Closes in 3 days');
      expect(CrewRules.closesLabel(now.add(const Duration(days: 1, minutes: 5)), now: now), 'Closes in 1 day');
      expect(CrewRules.closesLabel(now.add(const Duration(hours: 5)), now: now), 'Closes in 5 h');
      expect(CrewRules.closesLabel(now.add(const Duration(minutes: 12)), now: now), 'Closes in 12 min');
      expect(CrewRules.closesLabel(now.subtract(const Duration(minutes: 1)), now: now), 'Closed');
      expect(CrewRules.closesLabel(now.add(const Duration(days: 2)), now: now, closed: true), 'Closed');
    });
  });
}
