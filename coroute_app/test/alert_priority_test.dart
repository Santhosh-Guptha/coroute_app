import 'package:coroute_app/core/ui/ride_alert.dart';
import 'package:coroute_app/data/models/network_models.dart';
import 'package:coroute_app/data/models/network_wire.dart';
import 'package:coroute_app/data/models/sos_alert_model.dart';
import 'package:coroute_app/data/models/timeline_event_model.dart';
import 'package:coroute_app/domain/notify/alert_policy.dart';
import 'package:coroute_app/domain/notify/alert_priority.dart';
import 'package:coroute_app/domain/notify/relation.dart';
import 'package:coroute_app/presentation/alerts/alert_tiers.dart';
import 'package:flutter_test/flutter_test.dart';

const t0 = 1800000000000;
const min = 60000;

// A straight highway along lng 78.0 from lat 17.40 to 17.70 (northbound).
final List<(double, double)> highway = [for (var i = 0; i <= 30; i++) (17.40 + i * 0.01, 78.0)];

TimelineEventModel sosEvent({String alertId = 'A1', String type = 'CRASH', bool auto = true, String user = 'u_r', String name = 'Rahul'}) => TimelineEventModel(
      eventId: 'ev_$alertId',
      groupId: 'G',
      userId: user,
      userName: name,
      type: 'SOS',
      startedAt: t0 - min,
      open: true,
      lat: 17.4568,
      lng: 78.0,
      data: {'alertId': alertId, 'alertType': type, 'auto': auto},
    );

SosAlertModel liveAlert({String type = 'CRASH', EmergencySource source = EmergencySource.crashAuto, EmergencyNetwork? network, OwnNearest? own}) => SosAlertModel(
      alertId: 'A1',
      userId: 'u_r',
      userName: 'Rahul',
      lat: 17.4568,
      lng: 78.0,
      alertType: type,
      timestamp: t0 - min,
      auto: source == EmergencySource.crashAuto,
      source: source,
      status: EmergencyStatus.confirmedAccident,
      lastUpdateAt: t0 - 8000,
      network: network,
      ownNearest: own,
    );

void main() {
  final policy = AlertPolicy();
  // I ride northbound at lat 17.50 on the highway.
  final me = AlertViewer(userId: 'u_me', isLead: true, lat: 17.50, lng: 78.0, route: highway);

  group('Priority', () {
    test('order 1 to 6, lower index wins', () {
      expect(AlertPriority.values, [
        AlertPriority.sos,
        AlertPriority.assistRequest,
        AlertPriority.hazard,
        AlertPriority.groupSafety,
        AlertPriority.routeInfo,
        AlertPriority.social,
      ]);
      expect(priorityForKey('SOS:A1'), AlertPriority.sos);
      expect(priorityForKey('ASSIST:NET-0123456789AB'), AlertPriority.assistRequest);
      expect(priorityForKey('ASSIST_TAKEN:NET-0123456789AB'), AlertPriority.routeInfo);
      expect(priorityForKey('HAZARD:NET-0123456789AB'), AlertPriority.hazard);
      for (final k in ['INCIDENT:u', 'NO_SIGNAL:u', 'OFFLINE:u', 'SEPARATED:u', 'STOPPED:u', 'CLOSED:u', 'NO_REPLY:u', AlertPolicy.localCheckInKey]) {
        expect(priorityForKey(k), AlertPriority.groupSafety, reason: k);
      }
      expect(priorityForKey('OFF_ROUTE:u'), AlertPriority.routeInfo);
      expect(priorityForKey(AlertPolicy.meetingKey), AlertPriority.routeInfo);
      expect(priorityForKey('MEET:ENC-0123456789AB'), AlertPriority.social);
      expect(priorityForKey('EV:overspeed', channel: AlertChannel.alerts), AlertPriority.groupSafety);
      expect(priorityForKey('EV:joined', channel: AlertChannel.activity), AlertPriority.routeInfo);
      expect(priorityForKey('X', channel: AlertChannel.social), AlertPriority.social);
      expect(priorityForKey('X'), AlertPriority.routeInfo);
    });

    test('arrange: by priority, then newest, otherwise stable', () {
      final items = [
        ('MEET:e', 5),
        ('STOPPED:a', 1),
        ('HAZARD:h', 2),
        ('SOS:s', 0),
        ('STOPPED:b', 9),
        ('ASSIST:x', 3),
        ('OFF_ROUTE:o', 4),
      ];
      final out = AlertArbiter.arrange(items, (i) => priorityForKey(i.$1), newest: (i) => i.$2);
      expect(out.map((i) => i.$1).toList(), ['SOS:s', 'ASSIST:x', 'HAZARD:h', 'STOPPED:b', 'STOPPED:a', 'OFF_ROUTE:o', 'MEET:e']);
      final stable = AlertArbiter.arrange(items, (i) => priorityForKey(i.$1));
      expect(stable.map((i) => i.$1).toList().sublist(3, 5), ['STOPPED:a', 'STOPPED:b']);
    });

    test('social never over an emergency, a request or a hazard', () {
      expect(AlertArbiter.socialAllowed(anyEmergency: false, anyAssist: false, anyHazard: false), isTrue);
      expect(AlertArbiter.socialAllowed(anyEmergency: true, anyAssist: false, anyHazard: false), isFalse);
      expect(AlertArbiter.socialAllowed(anyEmergency: false, anyAssist: true, anyHazard: false), isFalse);
      expect(AlertArbiter.socialAllowed(anyEmergency: false, anyAssist: false, anyHazard: true), isFalse);
    });
  });

  group('Relation', () {
    test('along the route: behind your location / ahead on your route', () {
      expect(Relation.text(myLat: 17.50, myLng: 78.0, lat: 17.4568, lng: 78.0, route: highway), '4.8 km behind your location');
      expect(Relation.text(myLat: 17.50, myLng: 78.0, lat: 17.5144, lng: 78.0, route: highway), '1.6 km ahead on your route');
      expect(Relation.spoken(myLat: 17.50, myLng: 78.0, lat: 17.4568, lng: 78.0, route: highway), '4.8 kilometers behind you');
    });

    test('off the route or no route: as the crow flies with a compass word', () {
      expect(Relation.text(myLat: 12.9, myLng: 77.5, lat: 12.9115, lng: 77.5115), '1.8 km north-east of you');
      // A point 2 km east of the highway is not on it.
      expect(Relation.text(myLat: 17.50, myLng: 78.0, lat: 17.50, lng: 78.02, route: highway), endsWith('east of you'));
      expect(Relation.text(myLat: 0, myLng: 0, lat: 17.5, lng: 78.0), '');
    });

    test('rounded distances', () {
      expect(Relation.distanceText(2001), '2 km');
      expect(Relation.distanceText(4803), '4.8 km');
      expect(Relation.distanceText(512), '500 m');
      expect(Relation.distanceText(44), '40 m');
      expect(Relation.distanceText(23400), '23 km');
      expect(Relation.spokenDistance(1001), '1 kilometer');
      expect(Relation.spokenDistance(2001), '2 kilometers');
      expect(Relation.spokenDistance(498), '500 meters');
    });

    test('last location update', () {
      expect(Relation.lastUpdate(t0 - 8000, t0), 'Last location update: 8 seconds ago');
      expect(Relation.lastUpdate(t0 - 2 * min - 5000, t0), 'Last location update: 2 min ago');
      final at = DateTime.fromMillisecondsSinceEpoch(t0 - 90 * min);
      expect(Relation.lastUpdate(t0 - 90 * min, t0), 'Last location update: at ${at.hour}:${at.minute.toString().padLeft(2, '0')}');
    });
  });

  group('Own group EMERGENCY', () {
    test('crash with the live alert: distance along the route, automatic, last update, speech', () {
      final a = policy.standing([sosEvent()], me, nowMs: t0, alerts: [liveAlert()]).single;
      expect(a.key, 'SOS:A1');
      expect(a.channel, AlertChannel.sos);
      expect(a.title, 'EMERGENCY');
      expect(a.body, 'Rahul may have met with an accident. Automatic alert. 4.8 km behind your location. Last location update: 8 seconds ago.');
      expect(a.speech, 'Emergency. Rahul may have met with an accident 4.8 kilometers behind you.');
      expect(tierFor(a), AlertTier.critical);
    });

    test('manual SOS: needs help', () {
      final a = policy
          .standing([sosEvent(type: 'EMERGENCY', auto: false)], me, nowMs: t0, alerts: [liveAlert(type: 'EMERGENCY', source: EmergencySource.manual)])
          .single;
      expect(a.title, 'EMERGENCY');
      expect(a.body, 'Rahul needs help. 4.8 km behind your location. Last location update: 8 seconds ago.');
      expect(a.speech, 'Emergency. Rahul needs help, 4.8 kilometers behind you.');
    });

    test('nearby assistance accepted replaces the body (same key)', () {
      const net = EmergencyNetwork(state: NetworkState.assigned, stage: 1, notified: 2, responders: [
        NetResponder(rid: 'abc123abc123', name: 'Arjun', status: ResponderStatus.enRoute, etaS: 180, distanceM: 1500),
      ]);
      const own = OwnNearest(userId: 'u_k', name: 'Kiran', etaS: 600, distanceM: 9000, routeBased: true);
      final a = policy.standing([sosEvent()], me, nowMs: t0, alerts: [liveAlert(network: net, own: own)]).single;
      expect(a.key, 'SOS:A1');
      expect(a.body, 'Nearby assistance accepted. A nearby rider is responding. Responder ETA 3 min. Your nearest group rider ETA 10 min.');
      expect(a.body, isNot(contains('u_k')));
    });

    test('a 3.14 timeline entry without live data keeps the 3.14 text', () {
      final old = sosEvent(type: 'MECHANICAL', auto: false);
      expect(policy.standing([old], me, nowMs: t0).single.title, 'SOS from Rahul');
    });
  });

  group('Safety network and discovery specs', () {
    const req = AssistRequest(incidentId: 'NET-0123456789AB', lat: 17.5144, lng: 78.0, distanceM: 1600, aheadOnRoute: true, etaS: 180, receivedAt: t0);

    test('request before acceptance: no names, critical, speech', () {
      final a = policy.network(assists: [req], me: me, nowMs: t0).single;
      expect(a.key, 'ASSIST:NET-0123456789AB');
      expect(a.channel, AlertChannel.sos);
      expect(a.title, 'Rider emergency nearby');
      expect(a.body,
          'A rider from another group may have met with an accident. 1.6 km ahead on your route. Your group may be able to reach them before their own group.');
      expect(a.speech, 'Emergency alert. A rider may have had an accident 1.6 kilometers ahead. Your group may be the closest riders.');
      expect(tierFor(a), AlertTier.critical);
      // My position unknown: the server's distance.
      final blind = policy.network(assists: [req], me: const AlertViewer(userId: 'u_me'), nowMs: t0).single;
      expect(blind.body, contains('1.6 km ahead on your route'));
    });

    test('accepted: You are responding, ETA; declined: gone', () {
      final a = policy.network(assists: [req.copyWith(myStatus: ResponderStatus.enRoute)], me: me, nowMs: t0).single;
      expect(a.title, 'You are responding');
      expect(a.body, 'Rider emergency 1.6 km ahead on your route. ETA 3 min.');
      expect(a.speech, isNull);
      expect(policy.network(assists: [req.copyWith(myStatus: ResponderStatus.declined)], me: me, nowMs: t0), isEmpty);
    });

    test('taken notice: normal, for 2 min', () {
      const n = AssistNotice(incidentId: 'NET-0123456789AB', reason: AssistClosedReason.taken, at: t0);
      final a = policy.network(assists: const [], notices: [n], me: me, nowMs: t0 + 1000).single;
      expect(a.key, 'ASSIST_TAKEN:NET-0123456789AB');
      expect(a.title, 'Another nearby rider is responding');
      expect(a.body, 'No assistance is currently required.');
      expect(tierFor(a), AlertTier.normal);
      expect(policy.network(assists: const [], notices: [n], me: me, nowMs: t0 + 3 * min), isEmpty);
    });

    test('hazard: amber, distance along my route, speech once text', () {
      const h = HazardWarning(hazardId: 'NET-AAAAAAAAAAAA', lat: 17.518, lng: 78.0, aheadM: 2500, onRoute: true, receivedAt: t0);
      final a = policy.network(assists: const [], hazards: [h], me: me, nowMs: t0).single;
      expect(a.key, 'HAZARD:NET-AAAAAAAAAAAA');
      expect(a.channel, AlertChannel.hazard);
      expect(a.title, 'Caution');
      expect(a.body, 'Rider accident reported 2 km ahead on your route. Reduce speed and stay alert.');
      expect(a.speech, 'Caution. Rider accident reported 2 kilometers ahead.');
      expect(tierFor(a), AlertTier.important);
    });

    test('hazard for the accident I am asked to help with: one alert, one voice (the request)', () {
      const same = HazardWarning(hazardId: 'NET-0123456789AB', lat: 17.5144, lng: 78.0, aheadM: 1600, onRoute: true, receivedAt: t0);
      final specs = policy.network(assists: [req], hazards: [same], me: me, nowMs: t0);
      expect(specs.map((s) => s.key).toList(), ['ASSIST:NET-0123456789AB']);
      // After "Can't assist" the warning shows again.
      final declined = policy.network(assists: [req.copyWith(myStatus: ResponderStatus.declined)], hazards: [same], me: me, nowMs: t0);
      expect(declined.map((s) => s.key).toList(), ['HAZARD:NET-0123456789AB']);
    });

    const enc = Encounter(encounterId: 'ENC-0123456789AB', type: EncounterType.sameDirection, groupName: 'Weekend Riders', riders: 6, distanceM: 4700, sameRoute: true, at: t0);

    test('encounter: neutral, no speech, suppressed by any safety item', () {
      final a = policy.network(assists: const [], encounters: [enc], me: me, nowMs: t0).single;
      expect(a.key, 'MEET:ENC-0123456789AB');
      expect(a.channel, AlertChannel.social);
      expect(a.title, 'Weekend Riders nearby');
      expect(a.body, '6 riders, about 4.7 km. Travelling on the same route.');
      expect(a.speech, isNull);
      expect(tierFor(a), AlertTier.normal);
      const opp = Encounter(encounterId: 'ENC-0123456789AC', type: EncounterType.oppositeDirection, groupName: 'Royal Riders', riders: 4, distanceM: 3100, at: t0);
      expect(policy.network(assists: const [], encounters: [opp], me: me, nowMs: t0).single.body,
          'Another riding group is approaching from the opposite direction. 3.1 km away.');

      const h = HazardWarning(hazardId: 'NET-AAAAAAAAAAAA', lat: 17.518, lng: 78.0, receivedAt: t0);
      expect(policy.network(assists: const [], hazards: [h], encounters: [enc], me: me, nowMs: t0).where((s) => s.key.startsWith('MEET:')), isEmpty);
      expect(policy.network(assists: [req], encounters: [enc], me: me, nowMs: t0).where((s) => s.key.startsWith('MEET:')), isEmpty);
      expect(policy.network(assists: const [], encounters: [enc], me: me, nowMs: t0, anyEmergency: true), isEmpty);
    });

    test('waved', () {
      final waved = enc.copyWith(theyWavedAt: t0);
      final specs = policy.network(assists: const [], encounters: [waved], me: me, nowMs: t0 + 1000);
      expect(specs.map((s) => s.key), contains('MEET:ENC-0123456789AB:WAVE'));
      expect(specs.firstWhere((s) => s.key.endsWith(':WAVE')).title, 'Weekend Riders waved');
    });

    test('in-app list: priority first, extra specs merged once', () {
      const h = HazardWarning(hazardId: 'NET-AAAAAAAAAAAA', lat: 17.518, lng: 78.0, receivedAt: t0);
      final stop = TimelineEventModel(eventId: 'st', groupId: 'G', userId: 'u_c', userName: 'Chitra', type: 'STOPPED', startedAt: t0 - 25 * min, open: true);
      final extra = policy.network(assists: [req], hazards: [h], me: me, nowMs: t0);
      final list = inAppAlerts([stop, sosEvent()], me, nowMs: t0, extra: [...extra, ...extra], alerts: [liveAlert()]);
      expect(list.map((a) => a.key).toList(), ['SOS:A1', 'ASSIST:NET-0123456789AB', 'HAZARD:NET-AAAAAAAAAAAA', 'STOPPED:u_c']);
      expect(list.first.spec.title, 'EMERGENCY');
    });
  });
}
