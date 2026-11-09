import 'package:coroute_app/data/services/friends_service.dart';
import 'package:coroute_app/domain/social/username_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UsernameRules.check (same codes as gateway/src/usernames.js)', () {
    test('accepts valid names', () {
      for (final ok in ['SwiftFalcon482', 'abc', 'Rider_One', 'a' * 20, 'ThrottleTiger907', 'Moto_2024']) {
        expect(UsernameRules.check(ok).ok, isTrue, reason: ok);
      }
    });

    test('rejects bad names with the gateway codes', () {
      const bad = {
        'USERNAME_FORMAT': ['ab', 'aaaaaaaaaaaaaaaaaaaaa', '1rider', '_rider', 'has space', 'dash-name', 'mail@x', ''],
        'USERNAME_RESERVED': ['admin', 'Admin', 'CoRoute', 'support', 'official', 'Real_Admin7', 'c0route', 'Supp0rtTeam'],
        'USERNAME_NOT_ALLOWED': ['fuckrider', 'Sh1tHead', 'bitch99'],
        'USERNAME_CONTACT': ['r9876543210', 'call9876543', 'mygmailbox', 'rider_yahoo'],
      };
      bad.forEach((code, list) {
        for (final u in list) {
          final c = UsernameRules.check(u);
          expect(c.ok, isFalse, reason: u);
          expect(c.code, code, reason: u);
          expect(c.message, isNotEmpty);
        }
      });
    });

    test('cooldown: next change 30 days after the last one', () {
      final now = DateTime(2026, 11, 9);
      expect(UsernameRules.nextChangeAt(0, now: now), isNull);
      final changed = now.subtract(const Duration(days: 10)).millisecondsSinceEpoch;
      expect(UsernameRules.nextChangeAt(changed, now: now), DateTime.fromMillisecondsSinceEpoch(changed).add(const Duration(days: 30)));
      final old = now.subtract(const Duration(days: 31)).millisecondsSinceEpoch;
      expect(UsernameRules.nextChangeAt(old, now: now), isNull);
      expect(UsernameRules.sameIgnoringCase('SwiftFalcon482', 'swiftfalcon482 '), isTrue);
      expect(UsernameRules.sameIgnoringCase('SwiftFalcon482', 'SwiftFalcon483'), isFalse);
    });
  });

  group('InviteCodes', () {
    test('normalise', () {
      expect(InviteCodes.normalise(' 5tlb-m452 '), '5TLBM452');
      expect(InviteCodes.normalise('ABCDEFGO'), isNull, reason: 'no O');
      expect(InviteCodes.normalise('ABC'), isNull);
    });

    test('fromUri: website and app links, nothing else', () {
      expect(InviteCodes.fromUri(Uri.parse('https://coroute.duckdns.org/join/friend/5TLBM452')), '5TLBM452');
      expect(InviteCodes.fromUri(Uri.parse('coroute://join/friend/5tlbm452')), '5TLBM452');
      expect(InviteCodes.fromUri(Uri.parse('https://coroute.duckdns.org/join/ABC123')), isNull, reason: 'a ride join code');
      expect(InviteCodes.fromUri(Uri.parse('coroute://join/ABC123')), isNull);
      expect(InviteCodes.fromUri(Uri.parse('coroute://join/friend/bad!')), isNull);
    });
  });

  test('avatar initials and km format', () {
    expect(avatarInitials('SwiftFalcon482'), 'SF');
    expect(avatarInitials('Priya Raman'), 'PR');
    expect(avatarInitials('rider_one'), 'RO');
    expect(avatarInitials('kiran'), 'K');
    expect(avatarInitials('  '), '?');
    expect(formatKm(12.5), '12.5 km');
    expect(formatKm(30), '30 km');
    expect(formatKm(12345.4), '12,345 km');
  });

  group('profile models', () {
    test('RiderProfile keeps only what it knows; stats only when sent', () {
      final stranger = RiderProfile.fromJson({'username': 'SwiftFalcon482', 'avatarUrl': null, 'relation': 'NONE', 'phone': '+91999'});
      expect(stranger.hasStats, isFalse);
      expect(stranger.displayName, isNull);
      final friend = RiderProfile.fromJson({
        'username': 'SwiftFalcon482',
        'avatarUrl': '/api/avatars/av_0123456789abcdef01234567',
        'relation': 'FRIENDS',
        'displayName': 'Kiran',
        'stats': {'trips': 4, 'totalKm': 512.5, 'ridingHours': 11.2, 'score': 81.6, 'level': 'Skilled'},
      });
      expect(friend.hasStats, isTrue);
      expect(friend.score, 82);
      expect(friend.totalKm, 512.5);
      expect(friend.avatarUrl, '/api/avatars/av_0123456789abcdef01234567');
    });

    test('picture URLs other than gateway avatars are ignored', () {
      final p = MyProfile.fromJson({'username': 'X_rider', 'avatarUrl': 'https://evil.example/x.png', 'usernameChangedAt': 0});
      expect(p.avatarUrl, isNull);
      expect(p.nextUsernameChange, isNull);
      expect(p.publicLeaderboard, isTrue);
      final t = RideTotals.fromJson({'trips': 3, 'totalKm': 150.5, 'ridingHours': 3, 'longestTripKm': 120.5, 'largestGroup': 4});
      expect(t.trips, 3);
      expect(t.largestGroup, 4);
      expect(RideTotals.fromJson(null).trips, 0);
    });
  });
}
