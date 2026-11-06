import 'dart:async';

import 'package:coroute_app/data/models/public_ride_models.dart';
import 'package:coroute_app/data/services/public_ride_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A realtime link without a network: records what is sent.
class _Rt extends RealtimeService {
  _Rt(this.features);
  Set<String> features;
  final List<Map<String, dynamic>> sent = [];
  final StreamController<Map<String, dynamic>> _ctrl = StreamController<Map<String, dynamic>>.broadcast(sync: true);

  @override
  Stream<Map<String, dynamic>> get events => _ctrl.stream;
  @override
  bool get isConnected => true;
  @override
  bool supports(String feature) => features.contains(feature);
  @override
  bool send(Map<String, dynamic> message) {
    sent.add(message);
    return true;
  }

  @override
  void connect(String token, {bool adminMode = false}) {}
  @override
  void disconnect() {}

  void emit(Map<String, dynamic> m) => _ctrl.add(m);
}

Map<String, dynamic> _ride(String id, int km, {int riders = 4}) =>
    {'rideId': id, 'label': riders == 1 ? 'Rider' : 'Group of $riders', 'riders': riders, 'distanceKm': km, 'lat': 12.9, 'lng': 77.6, 'heading': 'NE'};

void main() {
  group('settings model', () {
    test('off by default; radius only from 5/10/25/50', () {
      expect(PublicRideSettings.fromJson(null), PublicRideSettings.off);
      final s = PublicRideSettings.fromJson({'on': true, 'radiusKm': 25, 'showName': true});
      expect(s.on, isTrue);
      expect(s.radiusKm, 25);
      expect(PublicRideSettings.fromJson({'on': true, 'radiusKm': 7}).radiusKm, 10);
      expect(s.copyWith(radiusKm: 3).radiusKm, 25, reason: 'not a choice: unchanged');
      expect(s.copyWith(radiusKm: 50).radiusKm, 50);
      expect(s.toJson(), {'on': true, 'radiusKm': 25, 'showName': true, 'showDestRegion': false});
    });

    test('prefs round trip', () {
      const p = PublicRidePrefs(showNearby: true, radiusKm: 5, roadWarnings: true);
      final back = PublicRidePrefs.fromJson(p.toJson());
      expect([back.showNearby, back.radiusKm, back.roadWarnings], [true, 5, true]);
      expect(const PublicRidePrefs().showNearby, isFalse);
    });
  });

  group('markers and radius filter', () {
    test('label "Public ride · 4 riders · 8 km"', () {
      final m = PublicRideMarker.fromJson(_ride('PR-1', 8))!;
      expect(m.markerLabel, 'Public ride · 4 riders · 8 km');
      expect(PublicRideMarker.fromJson(_ride('PR-2', 3, riders: 1))!.markerLabel, 'Public ride · 1 rider · 3 km');
      expect(m.detail, 'Group of 4, heading NE');
      expect(PublicRideMarker.fromJson({'rideId': 'x'}), isNull, reason: 'no position');
    });

    test('within my radius only, nearest first', () {
      final list = [for (final (id, km) in [('a', 12), ('b', 4), ('c', 10), ('d', 26)]) PublicRideMarker.fromJson(_ride(id, km))!];
      expect(PublicRideFilter.withinRadius(list, 10).map((r) => r.rideId), ['b', 'c']);
      expect(PublicRideFilter.withinRadius(list, 5).map((r) => r.rideId), ['b']);
      expect(PublicRideFilter.withinRadius(list, 50).length, 4);
    });
  });

  group('contact text', () {
    test('links, phone numbers and handles are refused before sending', () {
      expect(ContactText.problem('Out of petrol near the bridge'), isNull);
      expect(ContactText.problem('call 98765 43210'), isNotNull);
      expect(ContactText.problem('see www.example.com'), isNotNull);
      expect(ContactText.problem('insta @rider_kid'), isNotNull);
      expect(ContactText.problem('x' * 81), isNotNull);
    });
  });

  group('road warning display', () {
    RoadWarning w({String id = 'RW-1', String kind = 'ACCIDENT', int ahead = 6, bool confirmed = false, String by = 'ONCOMING', int exp = 100000}) =>
        RoadWarning.fromJson({'warnId': id, 'kind': kind, 'aheadKm': ahead, 'lat': 1, 'lng': 2, 'confirmed': confirmed, 'confirmations': confirmed ? 2 : 1, 'by': by, 'expiresAt': exp}, now: 0)!;

    test('wording', () {
      expect(w().bannerText, 'Accident reported 6 km ahead by an oncoming rider');
      expect(w(by: 'AHEAD', kind: 'ANIMALS', ahead: 2).bannerText, 'Animals on road reported 2 km ahead by a rider ahead');
      expect(w(kind: 'BLOCKED').speech, 'Road blocked, 6 kilometres ahead.');
      expect(w().confirmText, 'Not confirmed yet');
      expect(w(confirmed: true).confirmText, 'Confirmed by 2 riders');
    });

    test('expired ones hidden, nearest first', () {
      final list = [w(id: 'a', ahead: 9), w(id: 'b', ahead: 3), w(id: 'c', ahead: 1, exp: 50)];
      expect(RoadWarningPolicy.visible(list, 60).map((x) => x.warnId), ['b', 'a']);
    });

    test('spoken once, again when confirmed, never during my emergency', () {
      final spoken = <String>{};
      final k1 = RoadWarningPolicy.speechKey(w(), spoken: spoken, emergencyActive: false, now: 0);
      expect(k1, 'RW:RW-1:U');
      spoken.add(k1!);
      expect(RoadWarningPolicy.speechKey(w(), spoken: spoken, emergencyActive: false, now: 0), isNull);
      expect(RoadWarningPolicy.speechKey(w(confirmed: true), spoken: spoken, emergencyActive: false, now: 0), 'RW:RW-1:C');
      expect(RoadWarningPolicy.speechKey(w(id: 'RW-2'), spoken: spoken, emergencyActive: true, now: 0), isNull);
      expect(RoadWarningPolicy.speechKey(w(id: 'RW-3', exp: 10), spoken: spoken, emergencyActive: false, now: 20), isNull);
    });
  });

  group('service', () {
    late _Rt rt;
    late PublicRideService s;
    late List<String> said;
    var now = 1000000;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      rt = _Rt({PublicRideWire.feature});
      s = PublicRideService(rt, clock: () => now, prefs: prefs);
      said = [];
      s.speaker = (line, key) => said.add(line);
    });

    test('nothing without the gateway feature', () {
      rt.features = {};
      rt.emit({'type': 'SNAPSHOT', 'convoy': {'groupId': 'G1', 'publicRide': {'on': true, 'radiusKm': 10}}});
      rt.emit({'type': 'PUBLIC_RIDES', 'rides': [_ride('PR-1', 3)]});
      expect(s.rides, isEmpty);
      expect(rt.sent.where((m) => m['type'] == 'PR_PREFS'), isEmpty);
    });

    test('JOIN sends my prefs; my public ride radius filters the list; it goes stale without updates', () async {
      rt.emit({'type': 'SNAPSHOT', 'convoy': {'groupId': 'G1', 'publicRide': {'on': true, 'radiusKm': 10}}});
      expect(rt.sent.last['type'], 'PR_PREFS');
      expect(s.settings.on, isTrue);
      rt.emit({'type': 'PUBLIC_RIDES', 'rides': [_ride('PR-1', 3), _ride('PR-2', 12)]});
      expect(s.rides.map((r) => r.rideId), ['PR-1']);
      rt.emit({'type': 'CONFIG', 'publicRide': {'on': true, 'radiusKm': 25}});
      expect(s.rides.length, 2);
      now += 4 * 60000;
      expect(s.rides, isEmpty);
      // Not public, nothing near me shown until I ask for it.
      rt.emit({'type': 'CONFIG', 'publicRide': {'on': false}});
      rt.emit({'type': 'PUBLIC_RIDES', 'rides': [_ride('PR-1', 3)]});
      expect(s.rides, isEmpty);
      await s.setPrefs(const PublicRidePrefs(showNearby: true, radiusKm: 5));
      expect(s.rides.length, 1);
      expect(rt.sent.last, {'type': 'PR_PREFS', 'showNearby': true, 'radiusKm': 5, 'roadWarnings': false});
    });

    test('host settings and contact go out as protocol messages', () {
      rt.emit({'type': 'SNAPSHOT', 'convoy': {'groupId': 'G1'}});
      expect(s.setRideSettings(const PublicRideSettings(on: true, radiusKm: 50)), isTrue);
      expect(rt.sent.last, {'type': 'CONFIG', 'publicRide': {'on': true, 'radiusKm': 50, 'showName': false, 'showDestRegion': false}});
      final ride = PublicRideMarker.fromJson(_ride('PR-9', 4))!;
      expect(s.contact(ride, ContactKind.help, 'FUEL', text: 'call 98765 43210'), isFalse);
      expect(s.contact(ride, ContactKind.help, 'FUEL', text: 'near the bridge'), isTrue);
      expect(rt.sent.last, {'type': 'PR_CONTACT', 'rideId': 'PR-9', 'kind': 'HELP', 'quick': 'FUEL', 'text': 'near the bridge'});
      rt.emit({'type': 'PR_SENT', 'requestId': 'PRQ-1'});
      expect(s.outgoing.single.stateText, 'Waiting for a reply');
      rt.emit({'type': 'PR_MESSAGE', 'ref': 'PRQ-1', 'quickText': 'On my way', 'text': ''});
      expect(s.outgoing.single.replies.single.display, 'On my way');
      rt.emit({'type': 'PR_UPDATE', 'requestId': 'PRQ-1', 'state': 'CLOSED'});
      expect(s.outgoing.single.stateText, 'No reply');
    });

    test('incoming request: accept opens a chat; say and share location', () {
      rt.emit({'type': 'SNAPSHOT', 'convoy': {'groupId': 'G1', 'publicRide': {'on': true}}});
      rt.emit({'type': 'PR_REQUEST', 'requestId': 'PRQ-2', 'kind': 'HELP', 'quick': 'PUNCTURE', 'quickText': 'Puncture, need help', 'text': '', 'from': {'label': 'Rider'}, 'distanceKm': 3, 'expiresAt': now + 600000});
      expect(s.incoming.single.headline, 'Rider · 3 km: Puncture, need help');
      expect(s.reply('PRQ-2', 'ACCEPT'), isTrue);
      expect(s.incoming, isEmpty);
      rt.emit({'type': 'PR_CHANNEL', 'channelId': 'PRC-1', 'state': 'OPEN', 'expiresAt': now + 30 * 60000, 'with': {'label': 'Rider'}, 'requestId': 'PRQ-2'});
      final c = s.channels.single;
      expect(c.minutesLeft(now), 30);
      expect(s.say('PRC-1', quick: 'ON_MY_WAY'), isTrue);
      expect(s.channel('PRC-1')!.lines.last.display, 'On my way');
      expect(s.shareLocation('PRC-1', true), isTrue);
      expect(rt.sent.last, {'type': 'PR_SHARE_LOC', 'channelId': 'PRC-1', 'on': true});
      rt.emit({'type': 'PR_LOCATION', 'channelId': 'PRC-1', 'lat': 12.5, 'lng': 77.1, 'at': now});
      expect(s.channel('PRC-1')!.theirLat, 12.5);
      rt.emit({'type': 'PR_CHANNEL', 'channelId': 'PRC-1', 'state': 'CLOSED'});
      expect(s.channels, isEmpty);
      // Leaving the ride clears everything of it.
      rt.emit({'type': 'LEFT'});
      expect(s.channel('PRC-1'), isNull);
      expect(s.settings.on, isFalse);
    });

    test('road warnings: shown and spoken once (again when confirmed), silent in my emergency, cleared', () {
      var emergency = false;
      s.emergencyActive = () => emergency;
      rt.emit({'type': 'SNAPSHOT', 'convoy': {'groupId': 'G1', 'publicRide': {'on': true}}});
      Map<String, dynamic> warn(String id, {bool confirmed = false}) =>
          {'type': 'ROAD_WARNING', 'warnId': id, 'kind': 'ACCIDENT', 'aheadKm': 6, 'lat': 1.0, 'lng': 2.0, 'confirmed': confirmed, 'confirmations': confirmed ? 2 : 1, 'by': 'ONCOMING', 'expiresAt': now + 3600000};
      rt.emit(warn('RW-1'));
      expect(s.warnings.single.bannerText, 'Accident reported 6 km ahead by an oncoming rider');
      expect(said, ['Accident, 6 kilometres ahead.']);
      rt.emit(warn('RW-1'));
      expect(said.length, 1);
      rt.emit(warn('RW-1', confirmed: true));
      expect(said.length, 2);
      emergency = true;
      rt.emit(warn('RW-2'));
      expect(said.length, 2);
      expect(s.warnings.length, 2);
      rt.emit({'type': 'ROAD_WARNING_CLEAR', 'warnId': 'RW-1'});
      expect(s.warnings.map((w) => w.warnId), ['RW-2']);
      expect(s.vote('RW-2', stillThere: false), isTrue);
      expect(s.warnings, isEmpty);
      expect(s.vote('RW-2', stillThere: true), isFalse, reason: 'one vote');
      // Road warnings need Public ride or the setting.
      rt.emit({'type': 'CONFIG', 'publicRide': {'on': false}});
      expect(s.roadWarningsOn, isFalse);
      expect(s.sendRoadWarning(RoadWarningKind.police), isFalse);
    });

    test('refusals from the gateway become a notice', () {
      rt.emit({'type': 'ERROR', 'code': 403, 'reason': 'GUEST', 'message': 'Sign in with an account to contact other riders.'});
      expect(s.notice, 'Sign in with an account to contact other riders.');
      final seq = s.noticeSeq;
      rt.emit({'type': 'ERROR', 'code': 403, 'reason': 'NOT_MEMBER', 'message': 'x'});
      expect(s.noticeSeq, seq, reason: 'not ours');
    });
  });
}
