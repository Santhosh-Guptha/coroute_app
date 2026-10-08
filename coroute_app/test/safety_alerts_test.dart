import 'package:coroute_app/core/ui/ride_alert.dart';
import 'package:coroute_app/data/models/timeline_event_model.dart';
import 'package:coroute_app/domain/notify/alert_policy.dart';
import 'package:coroute_app/domain/timeline/timeline_text.dart';
import 'package:coroute_app/domain/tracking/bearing.dart';
import 'package:coroute_app/presentation/alerts/alert_tiers.dart';
import 'package:flutter_test/flutter_test.dart';

const t0 = 1700000000000;
const min = 60000;

TimelineEventModel ev(
  String id,
  String type, {
  String? user,
  String name = '',
  bool open = false,
  Map<String, dynamic> data = const {},
  String place = '',
  double? lat,
  double? lng,
  int startedAt = t0,
  int durationMs = 0,
}) =>
    TimelineEventModel(
      eventId: id,
      groupId: 'GRP-1',
      userId: user,
      userName: name,
      type: type,
      startedAt: startedAt,
      endedAt: open ? null : startedAt + durationMs,
      durationMs: durationMs,
      open: open,
      data: data,
      placeName: place,
      lat: lat,
      lng: lng,
    );

void main() {
  final policy = AlertPolicy();
  // Viewer positions: the subject is about 1.8 km north-east of the lead.
  const lead = AlertViewer(userId: 'lead', isLead: true, lat: 12.9000, lng: 77.5000);
  const sweeper = AlertViewer(userId: 'sw', isSweeper: true);
  const pack = AlertViewer(userId: 'pack');
  const near = AlertViewer(userId: 'near');
  const kiran = AlertViewer(userId: 'k');

  group('Bearing', () {
    test('compass words and the distance text', () {
      expect(Bearing.compassWord(0), 'north');
      expect(Bearing.compassWord(44), 'north-east');
      expect(Bearing.compassWord(90), 'east');
      expect(Bearing.compassWord(181), 'south');
      expect(Bearing.compassWord(359), 'north');
      expect(Bearing.fromMe(1800, 45), '1.8 km north-east of you');
      expect(Bearing.fromMe(450, 180), '450 m south of you');
      final d = Bearing.degrees(12.9, 77.5, 12.91, 77.51);
      expect(d, greaterThan(40));
      expect(d, lessThan(50));
      expect(Bearing.degrees(12.9, 77.5, 12.8, 77.5).round(), 180);
    });
  });

  group('Crash and SOS', () {
    final crash = ev('e1', 'SOS', user: 'k', name: 'Kiran', open: true, lat: 12.9115, lng: 77.5115, data: {'alertId': 'A1', 'alertType': 'CRASH', 'auto': true});

    // 3.15: an automatic crash is shown in the EMERGENCY form (was "Crash detected: Kiran").
    test('automatic crash: everyone but the rider, critical, EMERGENCY with automatic, distance, direction and last update', () {
      final a = policy.standing([crash], lead, nowMs: t0 + min).single;
      expect(a.key, 'SOS:A1');
      expect(a.key.startsWith(AlertPolicy.sosPrefix), isTrue);
      expect(a.channel, AlertChannel.sos);
      expect(a.title, 'EMERGENCY');
      expect(a.body, 'Kiran may have met with an accident. Automatic alert. 1.8 km north-east of you. Last location update: 1 min ago.');
      expect(a.speech, 'Emergency. Kiran may have met with an accident 1.8 kilometers north-east of you.');
      expect(tierFor(a), AlertTier.critical);
      expect(policy.standing([crash], kiran, nowMs: t0 + min), isEmpty);
      // Position of the viewer unknown: no distance.
      expect(policy.standing([crash], pack, nowMs: t0 + min).single.body,
          'Kiran may have met with an accident. Automatic alert. Last location update: 1 min ago.');
    });

    test('manual SOS: as before, plus distance and direction', () {
      final sos = ev('e2', 'SOS', user: 'k', name: 'Kiran', open: true, place: 'NH44', lat: 12.9115, lng: 77.5115, data: {'alertId': 'A2', 'alertType': 'MEDICAL'});
      final a = policy.standing([sos], lead, nowMs: t0 + min).single;
      expect(a.title, 'SOS from Kiran');
      expect(a.body, 'medical near NH44. 1.8 km north-east of you. Open CoRoute to see where.');
      expect(tierFor(a), AlertTier.critical);
    });
  });

  group('Possible incident', () {
    final inc = ev('e3', 'POSSIBLE_INCIDENT', user: 'k', name: 'Kiran', open: true, place: 'Hosur',
        data: {'fromKmh': 62, 'reason': 'HARD_STOP', 'notify': ['lead', 'near'], 'auto': true});

    test('the riders asked to check, the lead and the sweeper see it as critical', () {
      for (final v in [lead, near, sweeper]) {
        final a = policy.standing([inc], v, nowMs: t0 + 3 * min).single;
        expect(a.key, 'INCIDENT:k');
        expect(a.title, 'Possible incident: check on Kiran');
        expect(a.body, 'Automatic alert. Stopped suddenly from 62 km/h near Hosur.');
        expect(a.channel, AlertChannel.alerts);
        expect(tierFor(a), AlertTier.critical);
      }
      expect(policy.standing([inc], pack, nowMs: t0 + 3 * min), isEmpty);
    });

    test('the rider is told the group was asked (important, not critical)', () {
      final a = policy.standing([inc], kiran, nowMs: t0 + 3 * min).single;
      expect(a.key, 'INCIDENT:k');
      expect(a.title, 'Your group was asked to check on you');
      expect(a.body, "You stopped suddenly. Tap I'm OK if you are fine.");
      expect(tierFor(a), AlertTier.important);
    });

    test('closed: gone', () {
      final closed = ev('e3', 'POSSIBLE_INCIDENT', user: 'k', name: 'Kiran', durationMs: 4 * min, data: {'fromKmh': 62, 'result': 'OK'});
      expect(policy.standing([closed], lead, nowMs: t0 + 5 * min), isEmpty);
    });
  });

  group('Offline causes', () {
    test('escalated no signal replaces the plain offline alert, for lead and sweeper', () {
      final off = ev('e4', 'OFFLINE', user: 'r', name: 'Ravi', open: true, place: 'Krishnagiri', data: {'cause': 'NO_SIGNAL', 'escalated': true, 'lastKmh': 62});
      for (final v in [lead, sweeper]) {
        final a = policy.standing([off], v, nowMs: t0 + 10 * min).single;
        expect(a.key, 'NO_SIGNAL:r');
        expect(a.title, 'No signal from Ravi for 10 min');
        expect(a.body, 'Last seen near Krishnagiri at 62 km/h. Automatic alert.');
        expect(tierFor(a), AlertTier.critical);
      }
      expect(policy.standing([off], pack, nowMs: t0 + 10 * min), isEmpty);
      expect(policy.standing([off], lead, nowMs: t0 + 10 * min).where((a) => a.key.startsWith('OFFLINE:')), isEmpty);
    });

    test('plain no signal: lead only, after 5 min, as before; killed adds the reason', () {
      final off = ev('e5', 'OFFLINE', user: 'r', name: 'Ravi', open: true, data: {'cause': 'NO_SIGNAL'});
      expect(policy.standing([off], lead, nowMs: t0 + 4 * min), isEmpty);
      final a = policy.standing([off], lead, nowMs: t0 + 6 * min).single;
      expect(a.key, 'OFFLINE:r');
      expect(a.title, 'No signal from Ravi for 6 min');
      expect(tierFor(a), AlertTier.critical);
      final killed = ev('e6', 'OFFLINE', user: 'r', name: 'Ravi', open: true, data: {'cause': 'KILLED'});
      expect(policy.standing([killed], lead, nowMs: t0 + 6 * min).single.body, contains('The phone closed CoRoute.'));
    });

    test('app closed: the lead at once, important', () {
      final closed = ev('e7', 'OFFLINE', user: 'r', name: 'Ravi', open: true, data: {'cause': 'APP_CLOSED'});
      final a = policy.standing([closed], lead, nowMs: t0 + 10000).single;
      expect(a.key, 'CLOSED:r');
      expect(a.title, "CoRoute was closed on Ravi's phone");
      expect(a.body, 'Their position stops until they open it again.');
      expect(tierFor(a), AlertTier.important);
      expect(policy.standing([closed], pack, nowMs: t0 + 10000), isEmpty);
    });
  });

  test('no reply: lead and sweeper, important, automatic', () {
    final nr = ev('e8', 'NO_REPLY', user: 'r', name: 'Ravi', open: true, data: {'awayM': 2400});
    for (final v in [lead, sweeper]) {
      final a = policy.standing([nr], v, nowMs: t0 + min).single;
      expect(a.key, 'NO_REPLY:r');
      expect(a.title, 'No reply from Ravi');
      expect(a.body, 'Far from the group for 15 min and did not answer Are you OK. Automatic check.');
      expect(tierFor(a), AlertTier.important);
    }
    expect(policy.standing([nr], pack, nowMs: t0 + min), isEmpty);
    expect(policy.standing([nr], const AlertViewer(userId: 'r', isLead: true), nowMs: t0 + min), isEmpty);
  });

  test('SOS responses: the rider in trouble and the lead, normal tier', () {
    final going = ev('e9', 'SOS_RESPONSE', user: 'a', name: 'Arjun', data: {'alertId': 'A1', 'kind': 'GOING', 'forUserId': 'k', 'forUserName': 'Kiran'});
    final forKiran = policy.oneShot(going, kiran)!;
    expect(forKiran.title, 'Arjun is on the way to you');
    expect(forKiran.key, 'EV:e9');
    expect(forKiran.channel, AlertChannel.updates);
    expect(tierFor(forKiran), AlertTier.normal);
    expect(policy.oneShot(going, lead)!.title, 'Arjun is going to Kiran');
    expect(policy.oneShot(going, pack), isNull);
    expect(policy.oneShot(going, const AlertViewer(userId: 'a', isLead: true)), isNull);
    final withThem = ev('e10', 'SOS_RESPONSE', user: 'a', name: 'Arjun', data: {'alertId': 'A1', 'kind': 'WITH_THEM', 'forUserId': 'k', 'forUserName': 'Kiran'});
    expect(policy.oneShot(withThem, lead)!.title, 'Arjun is with Kiran');
    final cancel = ev('e11', 'SOS_RESPONSE', user: 'a', name: 'Arjun', data: {'alertId': 'A1', 'kind': 'CANCEL', 'forUserId': 'k'});
    expect(policy.oneShot(cancel, kiran), isNull);
  });

  test('in-app list: incidents first, every automatic alert says so', () {
    final events = [
      ev('e1', 'SOS', user: 'k', name: 'Kiran', open: true, data: {'alertId': 'A1', 'alertType': 'CRASH', 'auto': true}),
      ev('e3', 'POSSIBLE_INCIDENT', user: 'p', name: 'Priya', open: true, data: {'fromKmh': 50, 'notify': ['lead']}),
      ev('e8', 'NO_REPLY', user: 'r', name: 'Ravi', open: true),
    ];
    final list = inAppAlerts(events, lead, nowMs: t0 + min);
    expect(list.map((a) => a.tier).toList(), [AlertTier.critical, AlertTier.critical, AlertTier.important]);
    for (final a in list) {
      expect(a.spec.body.toLowerCase(), contains('automatic'));
    }
  });

  group('Timeline text', () {
    test('new entry types', () {
      final inc = ev('e3', 'POSSIBLE_INCIDENT', user: 'k', name: 'Kiran', open: true, data: {'fromKmh': 62});
      expect(TimelineText.title(inc, nowMs: t0), 'Possible incident: Kiran');
      expect(TimelineText.detail(inc, nowMs: t0), 'stopped suddenly from 62 km/h, automatic');
      final incOk = ev('e3', 'POSSIBLE_INCIDENT', user: 'k', name: 'Kiran', durationMs: 4 * min, data: {'fromKmh': 62, 'result': 'OK'});
      expect(TimelineText.detail(incOk, nowMs: t0), 'OK after 4 min');

      expect(TimelineText.title(ev('a', 'SOS_RESPONSE', user: 'a', name: 'Arjun', data: {'kind': 'GOING', 'forUserName': 'Kiran'}), nowMs: t0), 'Arjun is going to Kiran');
      expect(TimelineText.title(ev('b', 'SOS_RESPONSE', user: 'a', name: 'Arjun', data: {'kind': 'WITH_THEM', 'forUserName': 'Kiran'}), nowMs: t0), 'Arjun is with Kiran');
      expect(TimelineText.title(ev('c', 'SOS_RESPONSE', user: 'a', name: 'Arjun', data: {'kind': 'CANCEL', 'forUserName': 'Kiran'}), nowMs: t0), 'Arjun is no longer going');
      expect(TimelineText.title(ev('d', 'CHECK_IN', user: 'r', name: 'Ravi', data: {'result': 'OK'}), nowMs: t0), 'Ravi said they are OK');
      expect(TimelineText.title(ev('e', 'NO_REPLY', user: 'r', name: 'Ravi', open: true), nowMs: t0), 'No reply from Ravi');
      expect(TimelineText.title(ev('f', 'SOS', user: 'k', name: 'Kiran', data: {'alertType': 'CRASH', 'auto': true}), nowMs: t0), 'Kiran: crash detected (automatic alert)');
      expect(TimelineText.title(ev('g', 'SOS', user: 'k', name: 'Kiran', data: {'alertType': 'CRASH'}), nowMs: t0), 'Kiran raised an SOS (crash)');
      expect(TimelineText.title(ev('h', 'OFFLINE', user: 'r', name: 'Ravi', durationMs: 12 * min, data: {'cause': 'APP_CLOSED'}), nowMs: t0),
          "CoRoute was closed on Ravi's phone for 12 min");
      expect(TimelineText.title(ev('i', 'OFFLINE', user: 'r', name: 'Ravi', durationMs: 3 * min, data: {'cause': 'KILLED'}), nowMs: t0),
          "The phone closed CoRoute on Ravi's phone for 3 min");
      expect(TimelineText.title(ev('j', 'OFFLINE', user: 'r', name: 'Ravi', durationMs: 3 * min), nowMs: t0), 'Ravi had no signal for 3 min');
      expect(TimelineText.reason('CRASH'), 'crash');
    });
  });
}
