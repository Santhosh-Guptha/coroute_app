import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/models/pending_sos.dart';
import 'package:coroute_app/domain/notify/push_routing.dart';
import 'package:coroute_app/domain/safety/sms_plan.dart';

/// 3.56 SOS SMS from the rider's phone: the live link (`<site>/e/<token>`), the coordinates as text,
/// the time, one SMS part for a normal text; the link code travels with the SOS (`smsLinkToken`) so
/// the gateway can register it; admin "News and updates" pushes open only the fixed target screens.
void main() {
  final at = DateTime(2026, 11, 10, 14, 5);
  const token = 'Ab3dEf6hIj9lMn0pQr2tUv';

  group('live link', () {
    test('https origin and a 22-character code only', () {
      expect(SmsText.liveLinkFor('https://coroute.devmonks.space', token), 'https://coroute.devmonks.space/e/$token');
      expect(SmsText.liveLinkFor('https://coroute.devmonks.space/', token), 'https://coroute.devmonks.space/e/$token');
      expect(SmsText.liveLinkFor('http://coroute.devmonks.space', token), isNull, reason: 'never a plain-http link');
      expect(SmsText.liveLinkFor('https://coroute.devmonks.space', 'short'), isNull);
      expect(SmsText.liveLinkFor('https://coroute.devmonks.space', ''), isNull, reason: 'an SOS stored by an older version');
      expect(SmsText.liveLinkFor('https://user:pw@coroute.devmonks.space', token), isNull);
    });
  });

  group('the SOS text with a live link', () {
    final link = SmsText.liveLinkFor('https://coroute.devmonks.space', token)!;

    test('name, time, live link and coordinates as text', () {
      final body = SmsText.sos(name: 'Kiran', auto: false, lat: 12.971598, lng: 77.594562, at: at, liveLink: link);
      expect(body, startsWith('CoRoute SOS: Kiran needs help at 14:05.'));
      expect(body, contains('Live: $link'));
      expect(body, contains('Lat 12.97160 Lng 77.59456'));
      expect(SmsText.parts(body), 1, reason: 'a normal SOS text fits one SMS part');
    });

    test('a crash says so; the map link and ride name only while it still fits one part', () {
      final body = SmsText.sos(name: 'Kiran', auto: true, lat: 12.97, lng: 77.59, at: at, liveLink: link, convoyName: 'Nandi Hills');
      expect(body, contains('may have crashed at 14:05'));
      expect(body, contains(link));
      expect(SmsText.parts(body), 1);
      final long = SmsText.sos(name: 'Kiran', auto: false, lat: 12.97, lng: 77.59, at: at, liveLink: link, convoyName: 'A very long ride name for the whole weekend trip');
      expect(SmsText.parts(long), 1);
      expect(long, contains('Lat 12.97000 Lng 77.59000'), reason: 'the coordinates are never dropped');
    });

    test('no phone numbers in the text', () {
      final body = SmsText.sos(name: 'Kiran', auto: true, lat: 12.97, lng: 77.59, at: at, liveLink: link);
      final withoutLinks = body.replaceAll(RegExp(r'https://\S+'), '');
      expect(RegExp(r'\d{6,}').hasMatch(withoutLinks), isFalse);
      expect(body, isNot(contains('+')));
    });

    test('without a link the text is as before (map link)', () {
      final body = SmsText.sos(name: 'Kiran', auto: false, lat: 12.971598, lng: 77.594562, at: at);
      expect(body, contains('https://maps.google.com/?q=12.97160,77.59456'));
      expect(body, isNot(contains('/e/')));
    });

    test('the highway corridor text carries the live link too', () {
      final body = SmsText.indianEmergencySos(name: 'Kiran', auto: true, lat: 12.97, lng: 77.59, at: at);
      expect(body, contains('NHAI'));
      final withLink = SmsText.sos(name: 'Kiran', auto: true, lat: 12.97, lng: 77.59, at: at, indianCorridor: true, liveLink: link);
      expect(withLink, contains('Live: $link'));
    });
  });

  group('the link code travels with the SOS', () {
    test('22 random URL-safe characters, different each time', () {
      final a = PendingSos.newLinkToken();
      final b = PendingSos.newLinkToken();
      expect(a, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
      expect(a, isNot(b));
    });

    test('sent as smsLinkToken, kept on disk and through copyWith', () {
      final p = PendingSos(clientId: 'u1-1', groupId: 'g1', lat: 1, lng: 2, type: 'EMERGENCY', createdAt: 1, linkToken: token);
      expect(p.toMessage()['smsLinkToken'], token);
      expect(PendingSos.decode(p.encode())!.linkToken, token);
      expect(p.copyWith(lat: 3).linkToken, token);
      const old = PendingSos(clientId: 'u1-2', groupId: 'g1', lat: 1, lng: 2, type: 'EMERGENCY', createdAt: 1);
      expect(old.toMessage().containsKey('smsLinkToken'), isFalse);
      expect(PendingSos.fromJson({'clientId': 'x', 'groupId': 'g', 'linkToken': 'bad token'})!.linkToken, '');
    });
  });

  group('admin pushes (NEWS)', () {
    test('open only the fixed targets; anything else opens Home', () {
      expect(PushRouting.routeFor('NEWS', {'target': 'friends'}).destination, PushDestination.friends);
      expect(PushRouting.routeFor('NEWS', {'target': 'crews'}).destination, PushDestination.crewInvites);
      expect(PushRouting.routeFor('NEWS', {'target': 'rides'}).destination, PushDestination.rideHistory);
      expect(PushRouting.routeFor('NEWS', {'target': 'settings'}).destination, PushDestination.settings);
      expect(PushRouting.routeFor('NEWS', {'target': 'plans'}).destination, PushDestination.home);
      expect(PushRouting.routeFor('NEWS', const {}).destination, PushDestination.home);
    });
  });
}
