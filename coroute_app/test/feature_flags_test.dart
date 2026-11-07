import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/feature_flags_service.dart';
import 'package:coroute_app/presentation/admin/admin_features_screen.dart';

/// 3.55 admin feature switches: the pure parts of the app side (parse, merge, defaults) and the
/// admin console's parsing. Anything unknown is ON; only an explicit false switches a feature off;
/// core safety is never gated.
void main() {
  group('FeatureFlagsService helpers', () {
    test('parseFlags keeps only bool values with sane ids', () {
      final f = FeatureFlagsService.parseFlags({
        'rideRoles': false,
        'weather': true,
        'intercom': 'false',
        'essentials': 0,
        '': false,
        'x' * 41: false,
      });
      expect(f, {'rideRoles': false, 'weather': true});
      expect(FeatureFlagsService.parseFlags(null), isEmpty);
      expect(FeatureFlagsService.parseFlags(['rideRoles']), isEmpty);
    });

    test('unknown or missing ids are on; locked safety ids are always on', () {
      final f = FeatureFlagsService.parseFlags({'rideRoles': false, 'sos': false, 'crashDetection': false});
      expect(FeatureFlagsService.isOnIn(f, 'rideRoles'), isFalse);
      expect(FeatureFlagsService.isOnIn(f, 'weather'), isTrue, reason: 'missing = on');
      expect(FeatureFlagsService.isOnIn(f, 'someFutureFeature'), isTrue, reason: 'unknown = on');
      for (final id in FeatureFlagsService.lockedIds) {
        expect(FeatureFlagsService.isOnIn(f, id), isTrue, reason: '$id is never gated');
      }
      expect(FeatureFlagsService.lockedIds, containsAll(['sos', 'crashDetection', 'emergencySms', 'medicalId']));
    });

    test('parseUpdatedAt and isNewer', () {
      expect(FeatureFlagsService.parseUpdatedAt(1700000000000), 1700000000000);
      expect(FeatureFlagsService.parseUpdatedAt('42'), 42);
      expect(FeatureFlagsService.parseUpdatedAt(null), 0);
      expect(FeatureFlagsService.isNewer(10, 5), isTrue);
      expect(FeatureFlagsService.isNewer(5, 10), isFalse, reason: 'an older copy never overrides');
      expect(FeatureFlagsService.isNewer(10, 10), isTrue);
      expect(FeatureFlagsService.isNewer(0, 10), isFalse, reason: 'an undated copy never overrides a dated one');
      expect(FeatureFlagsService.isNewer(0, 0), isTrue);
    });

    test('applyPayload merges newest-wins and notifies only on a change', () {
      final s = FeatureFlagsService(ApiClient(), autoStart: false);
      addTearDown(s.dispose);
      var notified = 0;
      s.addListener(() => notified++);
      expect(s.isOn('rideRoles'), isTrue, reason: 'everything on before any answer');

      expect(s.applyPayload({'flags': {'rideRoles': false}, 'updatedAt': 100}, persist: false), isTrue);
      expect(s.isOn('rideRoles'), isFalse);
      expect(notified, 1);
      expect(FeatureFlagsService.on('rideRoles'), isFalse, reason: 'static accessor follows the instance');

      // An older copy (a slow GET after a fresh push) is ignored.
      expect(s.applyPayload({'flags': {'rideRoles': true}, 'updatedAt': 50}, persist: false), isFalse);
      expect(s.isOn('rideRoles'), isFalse);

      // Same state again: no notification.
      expect(s.applyPayload({'flags': {'rideRoles': false}, 'updatedAt': 100}, persist: false), isFalse);
      expect(notified, 1);

      // Switched back on (missing from the map = on).
      expect(s.applyPayload({'flags': <String, bool>{}, 'updatedAt': 200}, persist: false), isTrue);
      expect(s.isOn('rideRoles'), isTrue);
      expect(notified, 2);

      // Garbage never switches anything off.
      expect(s.applyPayload('nope', persist: false), isFalse);
      expect(s.applyPayload({'flags': 'x', 'updatedAt': 0}, persist: false), isFalse);
      expect(s.isOn('rideRoles'), isTrue);
    });

    test('no instance: everything is on', () {
      FeatureFlagsService.instance = null;
      expect(FeatureFlagsService.on('rideRoles'), isTrue);
    });
  });

  group('Admin features parsing', () {
    test('AdminFeature.fromJson defaults and last change line', () {
      final f = AdminFeature.fromJson({
        'id': 'placeReviews',
        'label': 'Place reviews',
        'description': 'Rider reviews',
        'group': 'Places',
        'locked': false,
        'enabled': false,
        'lastChange': {'id': 'placeReviews', 'enabled': false, 'by': 'a@b.c', 'reason': 'Bug', 'at': 1700000000000},
      })!;
      expect(f.enabled, isFalse);
      expect(f.lastChangeLine, startsWith('Turned off by a@b.c, '));
      expect(f.lastChangeLine, endsWith(': Bug'));
      final locked = AdminFeature.fromJson({'id': 'sos', 'locked': true, 'enabled': false})!;
      expect(locked.enabled, isTrue, reason: 'a locked feature always shows on');
      expect(AdminFeature.fromJson({'id': 'weather'})!.enabled, isTrue);
      expect(AdminFeature.fromJson({'label': 'no id'}), isNull);
      expect(AdminFeature.fromJson('x'), isNull);
    });

    test('adminGroupFeatures keeps the server order and drops empty groups', () {
      final list = [
        AdminFeature.fromJson({'id': 'a', 'group': 'Places'})!,
        AdminFeature.fromJson({'id': 'b', 'group': 'Safety'})!,
        AdminFeature.fromJson({'id': 'c', 'group': 'Other'})!,
      ];
      final g = adminGroupFeatures(list, ['Safety', 'Riding', 'Places']);
      expect(g.keys.toList(), ['Safety', 'Places', 'Other']);
    });
  });
}
