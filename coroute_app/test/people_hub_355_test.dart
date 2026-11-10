// 3.55 People hub (owner: "friends, crews and requests are too complex to search and open"):
// the pure parts — search key and debounce, relationship chips, one Requests list, shared badges,
// crew hints and the friend picker. lib/domain/social/people_models.dart.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/domain/social/friends_models.dart';
import 'package:coroute_app/domain/social/people_models.dart';
import 'package:coroute_app/domain/social/ride_invite_rules.dart';

void main() {
  group('search key', () {
    test('2-20 username characters, "@" and capitals ignored', () {
      expect(peopleSearchKey('Sw'), 'sw');
      expect(peopleSearchKey('  @SwiftFal '), 'swiftfal');
      expect(peopleSearchKey('@@ab'), 'ab');
    });
    test('too short, e-mails and phone numbers never search', () {
      for (final bad in ['', 'a', '@a', ' s ', 'mail@example.com', '+919876543210', 'two words', 'x' * 21]) {
        expect(peopleSearchKey(bad), isNull, reason: bad);
      }
    });
  });

  group('PeopleSearch debounce', () {
    const wait = Duration(milliseconds: 20);
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));

    test('one request per pause, for the last text typed', () async {
      final asked = <String>[];
      final states = <PeopleSearchState>[];
      final s = PeopleSearch(
        debounce: wait,
        fetch: (k) async {
          asked.add(k);
          return [PersonCard(username: '${k}_rider')];
        },
        onState: states.add,
      );
      s.input('s');
      expect(s.state.phase, PeopleSearchPhase.tooShort);
      s.input('sw');
      s.input('swi');
      s.input('@Swif');
      expect(s.state.phase, PeopleSearchPhase.loading);
      await settle();
      expect(asked, ['swif']);
      expect(s.requests, 1);
      expect(s.state.phase, PeopleSearchPhase.results);
      expect(s.state.results.single.username, 'swif_rider');
      // The same key again sends nothing.
      s.input('swif ');
      await settle();
      expect(asked, ['swif']);
      s.dispose();
    });

    test('default debounce is 300 ms and 2 characters', () {
      expect(peopleSearchDebounce, const Duration(milliseconds: 300));
      expect(peopleSearchMinChars, 2);
    });

    test('a slow answer for an older query is dropped', () async {
      final slow = Completer<List<PersonCard>>();
      final s = PeopleSearch(
        debounce: wait,
        fetch: (k) => k == 'ab' ? slow.future : Future.value([PersonCard(username: 'abcRider')]),
        onState: (_) {},
      );
      s.input('ab');
      await settle(); // 'ab' is in flight
      s.input('abc');
      await settle();
      expect(s.state.results.single.username, 'abcRider');
      slow.complete([const PersonCard(username: 'abOld')]);
      await settle();
      expect(s.state.results.single.username, 'abcRider', reason: 'newest query wins');
      s.dispose();
    });

    test('clearing goes back to the hub, empty and error states, retry', () async {
      var fail = true;
      final s = PeopleSearch(
        debounce: wait,
        fetch: (k) async {
          if (fail) throw Exception('offline');
          return const [];
        },
        onState: (_) {},
      );
      s.input('zz');
      await settle();
      expect(s.state.phase, PeopleSearchPhase.error);
      fail = false;
      s.retry();
      await settle();
      expect(s.state.phase, PeopleSearchPhase.empty);
      s.input('  ');
      expect(s.state.phase, PeopleSearchPhase.idle);
      expect(s.state.active, isFalse);
      s.input('@');
      expect(s.state.phase, PeopleSearchPhase.idle);
      s.dispose();
    });

    test('markRelation updates the row after a one-tap Add', () async {
      final s = PeopleSearch(debounce: wait, fetch: (_) async => [const PersonCard(username: 'KiloOne'), const PersonCard(username: 'KiloTwo')], onState: (_) {});
      s.input('kilo');
      await settle();
      s.markRelation('kiloone', PeopleRelation.pendingOut);
      expect(s.state.results.map((p) => p.relation), [PeopleRelation.pendingOut, PeopleRelation.none]);
      s.dispose();
    });
  });

  group('relationship chip', () {
    test('labels and one-tap actions', () {
      expect(RelationChip.of('FRIENDS').label, 'Friend');
      expect(RelationChip.of('PENDING_OUT').label, 'Requested');
      expect(RelationChip.of('PENDING_IN').action, PeopleAction.accept);
      expect(RelationChip.of('NONE').action, PeopleAction.add);
      expect(RelationChip.of('NONE').label, 'Add');
      expect(RelationChip.of('FRIENDS').actionable, isFalse);
      expect(RelationChip.of('anything').label, 'Add');
    });

    test('live relation: the friends lists win, case-insensitive', () {
      String rel(String u, String server, {bool loaded = true}) =>
          liveRelation(u, server, friends: ['KiloFriend'], incoming: ['KiloAsker'], outgoing: ['KiloAsked'], listsLoaded: loaded);
      expect(rel('kilofriend', 'NONE'), 'FRIENDS');
      expect(rel('KILOASKED', 'NONE'), 'PENDING_OUT');
      expect(rel('KiloAsker', 'NONE'), 'PENDING_IN');
      expect(rel('Gone', 'FRIENDS'), 'NONE', reason: 'removed since the search');
      expect(rel('Gone', 'FRIENDS', loaded: false), 'FRIENDS', reason: 'lists not read yet');
      expect(rel('Other', 'NONE'), 'NONE');
    });

    test('parses search and suggestion answers (username, picture, relation only)', () {
      final rows = PersonCard.parseSearch({
        'results': [
          for (var i = 0; i < 12; i++) {'username': 'R$i', 'avatarUrl': i == 0 ? '/api/avatars/a1' : 'https://evil/x.png', 'relation': 'NONE'},
          {'username': ''},
        ],
      });
      expect(rows.length, 10);
      expect(rows.first.avatarUrl, '/api/avatars/a1');
      expect(rows[1].avatarUrl, isNull);
      final sug = PersonCard.parseSuggestions({
        'suggestions': [
          {'username': 'RideOften', 'relation': 'NONE', 'rides': 2},
        ],
      });
      expect(sug.single.rides, 2);
      expect(PersonCard.parseSearch(null), isEmpty);
    });
  });

  group('one Requests list', () {
    const now = 1000000;
    test('incoming first (ride invites on top, then newest), then sent; no duplicates', () {
      final list = mergeRequests(
        nowMs: now,
        friendIncoming: const [
          FriendRequestEntry(requestId: 'fr_a', username: 'Asker', at: 10),
          FriendRequestEntry(requestId: 'fr_b', username: 'Newer', at: 30),
          FriendRequestEntry(requestId: 'fr_b', username: 'Newer', at: 30),
          FriendRequestEntry(requestId: '', username: 'Broken'),
        ],
        friendSent: const [
          FriendRequestEntry(requestId: 'fr_s1', username: 'Old', at: 5),
          FriendRequestEntry(requestId: 'fr_s2', username: 'Fresh', at: 50),
        ],
        crewInvites: [RequestItem.crewInvite(inviteId: 'ci_1', crewId: 'crw_1', crewName: 'Sunday Riders', invitedBy: 'Host', memberCount: 4, at: 20)],
        rideInvites: const [
          RideInvite(inviteId: 'ri_1', hostUsername: 'Leader', crewName: 'Sunday Riders', rideName: 'Hills', createdAt: 1, expiresAt: now + 60000),
          RideInvite(inviteId: 'ri_old', hostUsername: 'Late', createdAt: 2, expiresAt: now - 1),
          RideInvite(inviteId: 'ri_done', status: RideInviteStatus.declined, createdAt: 3),
        ],
      );
      expect(list.map((r) => r.key), ['ride:ri_1', 'friend:fr_b', 'crew:ci_1', 'friend:fr_a', 'friend:fr_s2', 'friend:fr_s1']);
      expect(list.where((r) => r.incoming).length, 4);
      final crew = list.firstWhere((r) => r.kind == RequestKind.crew);
      expect(crew.title, 'Sunday Riders');
      expect(crew.subtitle, 'Crew invite · 4 riders');
      final ride = list.first;
      expect(ride.title, 'Hills');
      expect(ride.username, 'Leader');
      expect(list.last.subtitle, 'Requested');
    });

    test('empty input, empty list', () {
      expect(mergeRequests(), isEmpty);
    });
  });

  group('badges', () {
    test('requests = friend requests + crew invites + ride invites; crews = votes; total = both', () {
      final b = PeopleBadges.of(friendRequests: 2, crewInvites: 1, rideInvites: 1, pendingVotes: 3);
      expect(b.requests, 4);
      expect(b.crews, 3);
      expect(b.total, 7);
      expect(PeopleBadges.label(12), '9+');
      expect(PeopleBadges.label(3), '3');
    });

    test('switched-off features count nothing', () {
      expect(PeopleBadges.of(friendRequests: 2, crewInvites: 1, rideInvites: 1, pendingVotes: 3, crewsOn: false).total, 2);
      expect(PeopleBadges.of(friendRequests: 2, pendingVotes: 3, pollsOn: false).total, 2);
      expect(PeopleBadges.of(friendRequests: 2, rideInvites: 1, crewRidesOn: false).requests, 2);
      expect(PeopleBadges.of(friendRequests: 2, friendsOn: false).total, 0);
    });

    test('the Requests segment and the bottom bar agree with the merged list', () {
      final list = mergeRequests(
        friendIncoming: const [FriendRequestEntry(requestId: 'fr_1', username: 'A')],
        crewInvites: [RequestItem.crewInvite(inviteId: 'ci', crewId: 'c', crewName: 'C', invitedBy: 'B')],
      );
      final b = PeopleBadges.of(friendRequests: 1, crewInvites: 1);
      expect(list.where((r) => r.incoming).length, b.requests);
    });
  });

  group('crew hint', () {
    const now = 1000000000;
    test('ride invite, votes, next poll closing, open polls', () {
      expect(crewHint(rideInvite: true, pendingVotes: 2), 'Ride invite waiting');
      expect(crewHint(pendingVotes: 1), '1 poll to vote');
      expect(crewHint(pendingVotes: 2), '2 polls to vote');
      expect(crewHint(openPolls: 1, nextPollClosesAt: now + 5 * 3600000 + 1000, nowMs: now), 'Poll closes in 5 h');
      expect(crewHint(openPolls: 1, nextPollClosesAt: now + 10 * 60000, nowMs: now), 'Poll closes within the hour');
      expect(crewHint(openPolls: 1, nextPollClosesAt: now + 72 * 3600000, nowMs: now), 'Poll closes in 3 days');
      expect(crewHint(openPolls: 2), '2 open polls');
      expect(crewHint(), isNull);
    });
  });

  group('friend picker', () {
    test('filter by username, any capitals, "@" ignored', () {
      expect(filterUsernames(['KiloOne', 'Alpha', 'kilotwo'], '@KILO'), ['KiloOne', 'kilotwo']);
      expect(filterUsernames(['A', 'B'], ' '), ['A', 'B']);
    });
    test('select all picks the visible names (capped), again clears them', () {
      final all = toggleAllPicked({'X'}, ['A', 'B', 'C'], cap: 3);
      expect(all, {'X', 'A', 'B'});
      final full = toggleAllPicked({}, ['A', 'B']);
      expect(full, {'A', 'B'});
      expect(toggleAllPicked(full, ['A', 'B']), isEmpty);
      expect(toggleAllPicked({'Hidden', 'A'}, ['A']), {'Hidden'}, reason: 'filtered-out picks stay');
    });
  });
}
