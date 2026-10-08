import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/constants/ride_notification_constants.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/network_models.dart';
import 'package:coroute_app/data/models/network_wire.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/data/models/safety_wire.dart';
import 'package:coroute_app/data/models/sos_alert_model.dart';
import 'package:coroute_app/data/models/timeline_event_model.dart';
import 'package:coroute_app/domain/notify/notification_snapshot.dart';
import 'package:coroute_app/domain/notify/status_text.dart';
import 'package:coroute_app/domain/ride/ride_facts.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';

// A straight route north along lng 77.6 from 12.90 to 13.30; I am at 13.00.
const double lng0 = 77.6;
const double myLat = 13.0;
const double mPerDegLat = 111194.9;
const int now = 1700000040000; // a whole minute

double north(double metres) => myLat + metres / mPerDegLat;

final List<(double, double)> line = [for (var i = 0; i <= 40; i++) (12.90 + i * 0.01, lng0)];
final RouteModel route = RouteModel(
  distanceM: 44478,
  durationS: 4448, // 10 m per second
  polyline: GeoMath.encodePolyline(line),
);

RiderModel rider(String id, String name, double lat, {double lng = lng0, int seenAgoMs = 5000, double speed = 40, double heading = 0, int stoppedSince = 0}) =>
    RiderModel(
      userId: id,
      name: name,
      lat: lat,
      lng: lng,
      speedKmh: speed,
      heading: heading,
      lastSeenEpochMs: now - seenAgoMs,
      stoppedSince: stoppedSince,
      phone: '+91 98765 43210',
      emergencyContact: '+91 91234 56780',
      emergencyContactName: 'Brother',
      vehicleNo: 'KA01AB1234',
    );

Map<String, RiderModel> sampleRiders({double meShift = 0, double othersShift = 0}) => {
      'me': rider('me', 'Kiran Rao', north(meShift)),
      'a': rider('a', 'Arjun Mehta', north(1200 + othersShift)),
      'b': rider('b', 'Bala', north(3300 + othersShift), seenAgoMs: 3 * 60000),
      'c': rider('c', 'Chetan', north(5500 + othersShift)),
      'd': rider('d', 'Rahul Sharma', north(-2200 + othersShift), speed: 0, stoppedSince: now - 5 * 60000),
      'e': rider('e', 'Esha', north(-3400 + othersShift)),
      'f': rider('f', 'Farhan', north(-6000 + othersShift)),
    };

ConvoyModel convoy({Map<String, RiderModel>? riders, List<SosAlertModel> alerts = const [], bool withRoute = true, Map<String, int> waits = const {}}) => ConvoyModel(
      groupId: 'G1',
      name: 'Weekend Ride',
      joinCode: '123456',
      createdByUserId: 'a',
      createdByUserName: 'Arjun',
      createdAtEpochMs: now - 3600000,
      destinationName: 'Goa, India',
      destinationLat: 13.30,
      destinationLng: lng0,
      riders: riders ?? sampleRiders(),
      activeAlerts: alerts,
      route: withRoute ? route : null,
      waitRequests: waits,
    );

String clock(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  return '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
}

NotificationSnapshot build(ConvoyModel c, {List<TimelineEventModel> events = const [], List<AssistRequest> assists = const [], List<HazardWarning> hazards = const [], bool lock = true}) =>
    NotificationSnapshotBuilder.build(
      convoy: c,
      myUserId: 'me',
      timelineEvents: events,
      assists: assists,
      hazards: hazards,
      nowMs: now,
      lockScreenPublic: lock,
      clockText: clock,
    );

SosAlertModel crashOf(String uid, String name, double lat, {EmergencyNetwork? network, OwnNearest? nearest, String type = SosTypes.crash, int? lastUpdateAt}) => SosAlertModel(
      alertId: 'AL1',
      userId: uid,
      userName: name,
      lat: lat,
      lng: lng0,
      alertType: type,
      timestamp: now - 60000,
      lastUpdateAt: lastUpdateAt,
      network: network,
      ownNearest: nearest,
    );

AssistRequest assistAt(double metres, {ResponderStatus status = ResponderStatus.requested, int? etaS}) => AssistRequest(
      incidentId: 'NET-ABCDEF123456',
      lat: north(metres),
      lng: lng0,
      distanceM: metres,
      aheadOnRoute: true,
      etaS: etaS,
      receivedAt: now - 1000,
      myStatus: status,
    );

HazardWarning hazardAt(double metres, {HazardLevel level = HazardLevel.active}) =>
    HazardWarning(hazardId: 'HZ1', lat: north(metres), lng: lng0, level: level, onRoute: true, receivedAt: now);

void main() {
  group('ride mode', () {
    test('two riders ahead and two behind, nearest first, with flags', () {
      final s = build(convoy());
      expect(s.mode, NotifMode.ride);
      expect(s.tone, NotifTone.normal);
      expect(s.ahead.map((r) => r.name), ['Arjun', 'Bala']);
      expect(s.behind.map((r) => r.name), ['Rahul', 'Esha']);
      expect(s.ahead.length, NotifConstants.ladderPerSide);
      expect(s.behind.length, NotifConstants.ladderPerSide);
      expect(s.ahead.first.detail, '1.2 km ahead');
      expect(s.behind.last.detail, '3.4 km behind');
      expect(s.ahead[1].flag, 'No signal', reason: 'no update for 3 min');
      expect(s.behind.first.flag, 'Stopped 5 min');
      expect(s.ahead.first.flag, isNull);
      expect(s.subtitle, 'Arjun 1.2 km ahead, Rahul 2.2 km behind');
      expect(s.header, 'Weekend Ride, 7 riders');
      expect(s.statusLine, 'All 7 riders together');
      expect(s.showSos, isTrue);
      expect(s.showWait, isTrue);
      expect(s.contextAction, NotifContextAction.none);
    });

    test('header: destination, remaining km along the route and ETA as a clock time', () {
      final s = build(convoy());
      final remaining = RideFacts.remainingM(lat: myLat, lng: lng0, line: convoy().routeLine, destLat: 13.30, destLng: lng0)!;
      expect(remaining, closeTo(33358, 30));
      final eta = RideFacts.etaFor(remaining, route)!;
      // Rounded down to the minute, so the text does not change with every fix.
      final at = DateTime.fromMillisecondsSinceEpoch(((now + eta.inMilliseconds) ~/ 60000) * 60000, isUtc: true);
      expect(s.title, 'Goa, 33 km, ETA ${at.hour}:${at.minute.toString().padLeft(2, '0')}');
    });

    test('no destination: the convoy name; no route: crow-flies remaining, no ETA', () {
      final noDest = ConvoyModel(
        groupId: 'G1',
        name: 'Weekend Ride',
        joinCode: '1',
        createdByUserId: 'a',
        createdByUserName: 'A',
        createdAtEpochMs: now,
        riders: sampleRiders(),
      );
      expect(build(noDest).title, 'Weekend Ride');
      final s = build(convoy(withRoute: false));
      expect(s.title, 'Goa, 33 km');
    });

    test('rounding keeps the text stable across small moves (same dedupeKey)', () {
      final a = build(convoy());
      final b = build(convoy(riders: sampleRiders(meShift: 5, othersShift: 4)));
      expect(b.dedupeKey, a.dedupeKey);
      final c = build(convoy(riders: sampleRiders(othersShift: 400)));
      expect(c.dedupeKey, isNot(a.dedupeKey), reason: '400 m is a visible change');
    });

    test('dedupeKey is equal for equal input and covers the lock-screen choice', () {
      expect(build(convoy()).dedupeKey, build(convoy()).dedupeKey);
      expect(build(convoy(), lock: false).dedupeKey, isNot(build(convoy()).dedupeKey));
    });

    test('without a route my heading decides the side; unknown side is listed as away', () {
      final riders = {
        'me': rider('me', 'Kiran', myLat, speed: 30, heading: 0),
        'n': rider('n', 'Nikhil', north(800)),
        's': rider('s', 'Suresh', north(-1500)),
        'e': rider('e', 'Ebin', myLat, lng: lng0 + 0.01), // due east
      };
      final s = build(convoy(riders: riders, withRoute: false));
      expect(s.ahead.map((r) => r.name), ['Nikhil']);
      expect(s.behind.map((r) => r.name).toSet(), {'Suresh', 'Ebin'});
      final east = s.behind.firstWhere((r) => r.name == 'Ebin');
      expect(east.sideKnown, isFalse);
      expect(east.detail, endsWith('away'));
    });

    test('status line: the worst open group warning', () {
      final events = [
        TimelineEventModel(eventId: 'x1', groupId: 'G1', userId: 'd', userName: 'Rahul Sharma', type: 'STOPPED', startedAt: now - 8 * 60000, open: true),
        TimelineEventModel(
            eventId: 'x2', groupId: 'G1', userId: 'e', userName: 'Esha', type: 'SEPARATED', startedAt: now - 120000, open: true, data: const {'distanceM': 3400}),
      ];
      final s = build(convoy(), events: events);
      expect(s.statusLine, 'Esha is 3.4 km from the group');
      final stopped = build(convoy(), events: [events.first]);
      expect(stopped.statusLine, 'Rahul stopped 8 min');
      expect(stopped.behind.first.flag, 'Stopped 8 min', reason: 'the open stop wins over the local estimate');
    });

    test('my own Wait for me shows as confirmation', () {
      final s = build(convoy(waits: {'Kiran Rao': now - 5000}));
      expect(s.statusLine, 'You asked the group to wait');
      final other = build(convoy(waits: {'Esha': now - 5000}));
      expect(other.statusLine, 'Esha asked the group to wait');
    });

    test('alone: waiting for the group, no Wait for me button', () {
      final s = build(convoy(riders: {'me': rider('me', 'Kiran', myLat)}));
      expect(s.ahead, isEmpty);
      expect(s.behind, isEmpty);
      expect(s.statusLine, 'Waiting for your group to join');
      expect(s.showWait, isFalse);
    });
  });

  group('emergency modes and priority', () {
    test('group emergency: red, distance and update time, Navigate to the rider', () {
      final s = build(convoy(alerts: [crashOf('d', 'Rahul Sharma', north(-4800), lastUpdateAt: now - 8000)]));
      expect(s.mode, NotifMode.groupEmergency);
      expect(s.tone, NotifTone.critical);
      expect(s.title, 'EMERGENCY: Rahul may have met with an accident');
      expect(s.subtitle, startsWith('4.8 km behind you, updated '));
      expect(s.contextAction, NotifContextAction.navigateEmergency);
      expect(s.contextLabel, 'Navigate to Rahul');
      expect(s.contextRef, 'AL1');
      expect(s.toChannelArgs()['context'], NotifConstants.actionNavEmergency);
    });

    test('manual SOS says needs help; responder line is positive', () {
      final net = EmergencyNetwork(
        state: NetworkState.assigned,
        responders: const [NetResponder(rid: 'r1', name: 'Arjun', status: ResponderStatus.enRoute, etaS: 180)],
      );
      final s = build(convoy(alerts: [crashOf('d', 'Rahul', north(-4800), type: SosTypes.emergency, network: net)]));
      expect(s.title, 'EMERGENCY: Rahul needs help');
      expect(s.statusLine, 'Nearby rider Arjun is responding, ETA 3 min');
      expect(s.statusPositive, isTrue);
      expect(s.tone, NotifTone.critical, reason: 'stays red while open');
    });

    test('nearest member line when nobody is responding yet', () {
      final s = build(convoy(alerts: [
        crashOf('d', 'Rahul', north(-4800), nearest: const OwnNearest(userId: 'e', name: 'Esha', etaS: 540, distanceM: 1400)),
      ]));
      expect(s.statusLine, 'Nearest member: Esha, ETA 9 min');
      expect(s.statusPositive, isFalse);
    });

    test('my own SOS: no SOS button, no Navigate', () {
      final s = build(convoy(alerts: [crashOf('me', 'Kiran', myLat)]));
      expect(s.title, 'Your SOS is active');
      expect(s.showSos, isFalse);
      expect(s.contextAction, NotifContextAction.none);
    });

    test('assist request before accepting: distance only, I Can Help, never a name', () {
      final s = build(convoy(), assists: [assistAt(1600)]);
      expect(s.mode, NotifMode.assist);
      expect(s.tone, NotifTone.critical);
      expect(s.title, 'Rider emergency 1.6 km ahead');
      expect(s.contextAction, NotifContextAction.iCanHelp);
      expect(s.contextLabel, 'I Can Help');
      expect(s.contextRef, 'NET-ABCDEF123456');
      expect(s.toChannelArgs()['context'], NotifConstants.actionAssistAccept);
    });

    test('assist accepted: responding, ETA, Navigate', () {
      final s = build(convoy(), assists: [assistAt(1200, status: ResponderStatus.enRoute, etaS: 180)]);
      expect(s.title, 'You are responding: rider emergency 1.2 km ahead');
      expect(s.subtitle, 'ETA 3 min. Ride with care.');
      expect(s.contextAction, NotifContextAction.navigateEmergency);
      expect(s.contextLabel, 'Navigate');
      expect(s.contextRef, 'NET-ABCDEF123456');
    });

    test('declined requests are not shown', () {
      final s = build(convoy(), assists: [assistAt(1600, status: ResponderStatus.declined)]);
      expect(s.mode, NotifMode.ride);
    });

    test('hazard: amber caution with the distance', () {
      final s = build(convoy(), hazards: [hazardAt(2000)]);
      expect(s.mode, NotifMode.hazard);
      expect(s.tone, NotifTone.warning);
      expect(s.title, 'Caution: accident reported 2.0 km ahead');
      expect(s.subtitle, 'Reduce speed and stay alert.');
      expect(s.contextAction, NotifContextAction.none);
    });

    test('priority: group emergency > assist > hazard > ride', () {
      final sos = crashOf('d', 'Rahul', north(-4800));
      expect(build(convoy(alerts: [sos]), assists: [assistAt(1600)], hazards: [hazardAt(2000)]).mode, NotifMode.groupEmergency);
      expect(build(convoy(), assists: [assistAt(1600)], hazards: [hazardAt(2000)]).mode, NotifMode.assist);
      expect(build(convoy(), hazards: [hazardAt(2000)]).mode, NotifMode.hazard);
      final resolved = SosAlertModel(alertId: 'old', userId: 'd', userName: 'Rahul', lat: 0, lng: 0, timestamp: now, resolved: true);
      expect(build(convoy(alerts: [resolved])).mode, NotifMode.ride);
    });

    test('quick state matches the built mode and changes with the emergency state', () {
      final c = convoy(alerts: [crashOf('d', 'Rahul', north(-4800))]);
      final q = NotificationSnapshotBuilder.quickState(convoy: c, myUserId: 'me');
      expect(q.mode, NotifMode.groupEmergency);
      final net = EmergencyNetwork(state: NetworkState.assigned, responders: const [NetResponder(rid: 'r1', name: 'Arjun', status: ResponderStatus.accepted)]);
      final q2 = NotificationSnapshotBuilder.quickState(convoy: convoy(alerts: [crashOf('d', 'Rahul', north(-4800), network: net)]), myUserId: 'me');
      expect(q2.key, isNot(q.key));
      expect(NotificationSnapshotBuilder.quickState(convoy: convoy(), myUserId: 'me').mode, NotifMode.ride);
    });
  });

  group('lock screen and privacy', () {
    test('public version is minimal; emergency adds a line without names', () {
      final ride = build(convoy(), lock: false);
      expect(ride.toChannelArgs()['lockScreenPublic'], isFalse);
      expect(ride.publicTitle, 'CoRoute ride active');
      expect(ride.publicText, '');
      final sos = build(convoy(alerts: [crashOf('d', 'Rahul Sharma', north(-4800))]));
      expect(sos.publicText, 'Rider emergency nearby, open CoRoute');
      final assist = build(convoy(), assists: [assistAt(1600)]);
      expect(assist.publicText, 'Rider emergency nearby, open CoRoute');
      for (final s in [ride, sos, assist]) {
        expect('${s.publicTitle} ${s.publicText}', isNot(contains('Rahul')));
        expect('${s.publicTitle} ${s.publicText}', isNot(matches(RegExp(r'\d'))));
      }
    });

    test('no phone numbers, contacts or plates anywhere in the channel arguments', () {
      final net = EmergencyNetwork(state: NetworkState.assigned, responders: const [NetResponder(rid: 'r1', name: 'Arjun', status: ResponderStatus.enRoute, etaS: 120)]);
      final all = [
        build(convoy()),
        build(convoy(alerts: [crashOf('d', 'Rahul', north(-4800), network: net)])),
        build(convoy(), assists: [assistAt(1600)]),
        build(convoy(), assists: [assistAt(1600, status: ResponderStatus.accepted)]),
        build(convoy(), hazards: [hazardAt(2000)]),
      ];
      for (final s in all) {
        final text = jsonEncode(s.toChannelArgs());
        for (final bad in ['98765', '43210', '91234', '56780', 'Brother', 'KA01AB1234', '+91']) {
          expect(text, isNot(contains(bad)), reason: '${s.mode}: $bad');
        }
      }
    });

    test('channel arguments carry the service notification id and channel', () {
      final args = build(convoy()).toChannelArgs();
      expect(args['notificationId'], NotifConstants.serviceNotificationId);
      expect(args['channelId'], NotifConstants.channelId);
      expect((args['rows'] as List).length, 4);
      expect(args['sosLabel'], 'SOS');
      expect(args['waitLabel'], 'Wait for me');
      expect(args['mapLabel'], 'Open map');
    });
  });

  test('StatusText.flagFor', () {
    expect(StatusText.flagFor(const StatusMember(name: 'A', distanceM: 1, sinceUpdate: Duration(minutes: 3))), 'No signal');
    expect(StatusText.flagFor(const StatusMember(name: 'A', distanceM: 1, stoppedFor: Duration(minutes: 5))), 'Stopped 5 min');
    expect(StatusText.flagFor(const StatusMember(name: 'A', distanceM: 1, stoppedFor: Duration(seconds: 30))), '');
    expect(StatusText.flagFor(const StatusMember(name: 'A', distanceM: 1)), '');
  });
}
