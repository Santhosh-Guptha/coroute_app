import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/notify/notification_snapshot.dart';
import 'package:coroute_app/domain/notify/ride_notification_content.dart';

void main() {
  group('RideNotificationContent (title, body, buttons)', () {
    test('group ride: "Riding with <group>", speed • distance • next stop / ETA, SOS + Talk + Leave', () {
      final c = RideNotificationContent.build(
        groupName: 'Western Ghats Riders',
        solo: false,
        speedKmh: 42.4,
        distanceM: 12300,
        targetName: 'Kolar fuel stop, NH 75',
        etaClock: '4:35 PM',
      );
      expect(c.title, 'Riding with Western Ghats Riders');
      expect(c.body, '42 km/h • 12 km • Kolar fuel stop, ETA 4:35 PM');
      expect(c.showTalk, isTrue, reason: 'no plan information yet: shown for group rides');
      expect(c.endLabel, 'Leave');
    });

    test('solo ride: "Solo ride", no Talk, "End ride"', () {
      final c = RideNotificationContent.build(groupName: 'Morning loop', solo: true, speedKmh: 61, distanceM: 800, targetName: 'Home');
      expect(c.title, 'Solo ride');
      expect(c.body, '61 km/h • 800 m • Home');
      expect(c.showTalk, isFalse);
      expect(c.endLabel, 'End ride');
    });

    test('Talk follows the plan gate when it is known', () {
      expect(RideNotificationContent.build(groupName: 'G', solo: false, talkAllowed: false).showTalk, isFalse);
      expect(RideNotificationContent.build(groupName: 'G', solo: false, talkAllowed: true).showTalk, isTrue);
      expect(RideNotificationContent.build(groupName: 'G', solo: true, talkAllowed: true).showTalk, isFalse);
    });

    test('stopped, no position, no target, unknown distance', () {
      expect(RideNotificationContent.build(groupName: 'G', solo: false, speedKmh: 2.9).body, 'Stopped');
      expect(RideNotificationContent.build(groupName: 'G', solo: false).body, '');
      expect(RideNotificationContent.build(groupName: 'G', solo: false, speedKmh: 30, etaClock: '5:10 PM').body, '30 km/h • ETA 5:10 PM');
      expect(RideNotificationContent.build(groupName: 'G', solo: false, speedKmh: double.nan, distanceM: double.infinity).body, '');
    });

    test('long names are shortened; an empty group name reads as solo', () {
      final c = RideNotificationContent.build(groupName: 'A' * 60, solo: false, targetName: 'B' * 60, speedKmh: 10);
      expect(c.title.length, lessThanOrEqualTo('Riding with '.length + 32));
      expect(c.body, endsWith('.'));
      expect(RideNotificationContent.build(groupName: '  ', solo: false).title, 'Solo ride');
    });

    test('rounding keeps the text stable between close fixes', () {
      String body(double kmh, double m) => RideNotificationContent.build(groupName: 'G', solo: false, speedKmh: kmh, distanceM: m, targetName: 'Goa').body;
      expect(body(42.2, 33358), body(41.6, 33320));
    });
  });

  group('RideNotificationThrottle (at most one update per 5-10 s, not per fix)', () {
    test('routine updates wait 10 s; identical content is never pushed again', () {
      final t = RideNotificationThrottle();
      expect(t.shouldPush(nowMs: 0, key: 'a'), isTrue);
      t.pushed(nowMs: 0, key: 'a');
      expect(t.shouldPush(nowMs: 1000, key: 'b'), isFalse);
      expect(t.shouldPush(nowMs: 9999, key: 'b'), isFalse);
      expect(t.shouldPush(nowMs: 10000, key: 'b'), isTrue);
      expect(t.shouldPush(nowMs: 60000, key: 'a'), isFalse, reason: 'same content');
      expect(t.nextAllowedMs(saverOn: false), 10000);
    });

    test('battery saver: 20 s; an open emergency: 5 s; an emergency change: at once', () {
      final t = RideNotificationThrottle();
      t.pushed(nowMs: 0, key: 'a');
      expect(t.shouldPush(nowMs: 15000, key: 'b', saverOn: true), isFalse);
      expect(t.shouldPush(nowMs: 20000, key: 'b', saverOn: true), isTrue);
      expect(t.shouldPush(nowMs: 4999, key: 'b', critical: true), isFalse);
      expect(t.shouldPush(nowMs: 5000, key: 'b', critical: true), isTrue);
      expect(t.shouldPush(nowMs: 1, key: 'a', emergencyChanged: true), isTrue);
      t.reset();
      expect(t.shouldPush(nowMs: 1, key: 'a'), isTrue);
    });
  });

  group('Medical ID badge (always on, only what the rider entered)', () {
    test('name, blood group, allergies and emergency contact; blanks left out', () {
      const full = MedicalId(name: 'Kiran', bloodGroup: 'O+', allergies: 'penicillin', contactName: 'Asha', contactPhone: '98765 43210');
      expect(full.badge(), 'Medical ID: Kiran · Blood O+ · Allergies: penicillin · ICE: Asha 98765 43210');
      expect(const MedicalId(bloodGroup: 'B+').badge(), 'Medical ID: Blood B+');
      expect(const MedicalId(name: 'Kiran').badge(), isNull, reason: 'a name alone is not a medical ID');
      expect(const MedicalId().badge(), isNull);
    });

    test('the ride snapshot carries the badge to the lock screen and the buttons to Android', () {
      const snap = NotificationSnapshot(
        mode: NotifMode.ride,
        tone: NotifTone.normal,
        title: 'Riding with G',
        subtitle: '40 km/h',
        showTalk: true,
        endLabel: 'Leave',
        medicalBadge: 'Medical ID: Blood O+',
      );
      expect(snap.publicText, 'Medical ID: Blood O+');
      final args = snap.toChannelArgs();
      expect(args['showTalk'], isTrue);
      expect(args['talkLabel'], 'Talk');
      expect(args['showEnd'], isTrue);
      expect(args['endLabel'], 'Leave');
      expect(args['medicalBadge'], 'Medical ID: Blood O+');
      const other = NotificationSnapshot(mode: NotifMode.ride, tone: NotifTone.normal, title: 'Riding with G', subtitle: '40 km/h');
      expect(other.dedupeKey, isNot(snap.dedupeKey));
      expect(other.publicText, '');
      expect(other.toChannelArgs()['showEnd'], isFalse);
    });
  });
}
