// 3.55 "Start a ride with this crew" (docs/features_355/crews_polls.md, "Crew rides"): the pure
// parts. Invite parsing (no join code, no coordinates), the app-open check (once per invite; one
// invite = its screen, several = the list), the member picker and the host's labels.
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/social/ride_invite_rules.dart';

const int t0 = 1800000000000;

Map<String, dynamic> invite(String id, {int created = t0, int expires = t0 + 12 * 3600000, String status = 'PENDING'}) => {
      'inviteId': id,
      'status': status,
      'createdAt': created,
      'expiresAt': expires,
      'host': {'username': 'SwiftFalcon482', 'displayName': 'Hari', 'avatarUrl': '/api/avatars/av_1'},
      'crew': {'crewId': 'cr_0123456789abcdef', 'name': 'Ghat Crew'},
      'ride': {'groupId': 'GRP-AB12', 'name': 'Sunrise Loop', 'startName': 'Cubbon Park Gate', 'destinationName': 'Nandi Hills', 'startedAt': t0, 'status': 'STARTED', 'riders': 3, 'capacity': 6},
    };

void main() {
  test('parses the invite: host, crew, ride names; lines for the screen', () {
    final i = RideInvite.fromJson(invite('ri_1'));
    expect(i.inviteId, 'ri_1');
    expect(i.hostUsername, 'SwiftFalcon482');
    expect(i.hostLine, 'Hari (@SwiftFalcon482)');
    expect(i.hostAvatarUrl, '/api/avatars/av_1');
    expect(i.crewName, 'Ghat Crew');
    expect(i.rideName, 'Sunrise Loop');
    expect(i.routeLine, 'Cubbon Park Gate → Nandi Hills');
    expect(i.ridersLine, '3 of 6 riders');
    expect(i.noticeLine, 'SwiftFalcon482 invited you to Sunrise Loop with Ghat Crew');
    expect(i.isOpen(t0 + 1000), isTrue);
    expect(i.isOpen(t0 + 13 * 3600000), isFalse);
    // Odd avatar URLs are dropped; missing parts are safe.
    final odd = RideInvite.fromJson({'inviteId': 'ri_2', 'host': {'avatarUrl': 'https://evil.example/x.png'}});
    expect(odd.hostAvatarUrl, isNull);
    expect(odd.routeLine, '');
    expect(odd.noticeLine, 'A rider invited you to a ride');
    expect(RideInvite.fromJson({'inviteId': 'x', 'ride': {'destinationName': 'Nandi Hills'}}).routeLine, 'To Nandi Hills');
  });

  test('app open: once per invite; one = its screen, several = the list; expired or answered never', () {
    final a = RideInvite.fromJson(invite('ri_a', created: t0));
    final b = RideInvite.fromJson(invite('ri_b', created: t0 + 5000));
    final old = RideInvite.fromJson(invite('ri_old', expires: t0 - 1));
    final done = RideInvite.fromJson(invite('ri_done', status: 'DECLINED'));
    expect(RideInviteRules.autoShow([a], {}, t0 + 10), RideInviteAutoShow.single);
    expect(RideInviteRules.autoShow([a, b], {}, t0 + 10), RideInviteAutoShow.list);
    expect(RideInviteRules.unseen([a, b], {}, t0 + 10).map((i) => i.inviteId), ['ri_b', 'ri_a'], reason: 'newest first');
    expect(RideInviteRules.autoShow([a, b], {'ri_a'}, t0 + 10), RideInviteAutoShow.single);
    expect(RideInviteRules.autoShow([a, b], {'ri_a', 'ri_b'}, t0 + 10), RideInviteAutoShow.none);
    expect(RideInviteRules.autoShow([old, done], {}, t0 + 10), RideInviteAutoShow.none);
  });

  test('member picker: everyone but me (case ignored) and riders already in the ride', () {
    final names = ['SwiftFalcon482', 'kiteRider7', 'Asha_Rides', ''];
    expect(RideInviteRules.pickable<String>(names, (s) => s, myUsername: 'swiftfalcon482'), ['kiteRider7', 'Asha_Rides']);
    expect(RideInviteRules.pickable<String>(names, (s) => s, myUsername: 'SwiftFalcon482', inRide: {'ASHA_RIDES'}), ['kiteRider7']);
  });

  test('host labels and the send summary', () {
    expect(RideInviteStatus.label('PENDING'), 'Waiting');
    expect(RideInviteStatus.label('ACCEPTED'), 'Joined');
    expect(RideInviteStatus.label('DECLINED'), 'Declined');
    expect(RideInviteStatus.label('EXPIRED'), 'Expired');
    expect(RideInviteRules.sendLabel(0), 'Pick riders');
    expect(RideInviteRules.sendLabel(1), 'Invite 1 rider');
    expect(RideInviteRules.sendLabel(4), 'Invite 4 riders');
    expect(RideInviteRules.summary(['INVITED', 'INVITED', 'RIDE_FULL']), '2 invited · 1 no seat left');
    expect(RideInviteRules.summary(['ALREADY_IN_RIDE']), '1 already in the ride');
    expect(RideInviteRules.summary([]), 'Nobody invited');
  });
}
