import 'package:coroute_app/core/l10n/l10n.dart';
import 'package:coroute_app/core/ui/ride_alert.dart';
import 'package:coroute_app/data/models/network_models.dart';
import 'package:coroute_app/data/models/network_wire.dart';
import 'package:coroute_app/data/models/sos_alert_model.dart';
import 'package:coroute_app/data/models/timeline_event_model.dart';
import 'package:coroute_app/data/services/alert_service.dart';
import 'package:coroute_app/data/services/voice_service.dart';
import 'package:coroute_app/domain/notify/alert_policy.dart';
import 'package:coroute_app/domain/notify/alert_priority.dart';
import 'package:coroute_app/domain/timeline/timeline_text.dart';
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
  // The subject is about 1.8 km north-east of the lead.
  const lead = AlertViewer(userId: 'lead', isLead: true, lat: 12.9000, lng: 77.5000);
  const sweeper = AlertViewer(userId: 'sw', isSweeper: true, lat: 12.9000, lng: 77.5000);
  const pack = AlertViewer(userId: 'pack');
  const kiran = AlertViewer(userId: 'k');
  const arjun = AlertViewer(userId: 'a');

  setUp(() => L10n.setLanguage(AppLanguage.en));

  group('Rider down reports (item 1): never "accident"', () {
    final memberReport = ev('r1', 'SOS', user: 'k', name: 'Kiran', open: true, place: 'Shamshabad', lat: 12.9115, lng: 77.5115,
        data: {'alertId': 'A1', 'alertType': 'RIDER_DOWN', 'source': 'MEMBER_REPORT', 'reportedBy': 'a', 'reportedByName': 'Arjun'});
    final nearbyReport = ev('r2', 'SOS', user: 'a', name: 'Arjun', open: true, lat: 12.9115, lng: 77.5115,
        data: {'alertId': 'A2', 'alertType': 'RIDER_DOWN', 'source': 'NEARBY_REPORT', 'reportedBy': 'a', 'reportedByName': 'Arjun'});

    test('member report: the group sees the reporter and the place, critical, spoken', () {
      for (final v in [lead, sweeper, pack]) {
        final a = policy.standing([memberReport], v, nowMs: t0 + min).single;
        expect(a.key, 'SOS:A1');
        expect(a.channel, AlertChannel.sos);
        expect(a.title, 'Rider down reported');
        expect(a.body, 'Arjun reported a rider down near Shamshabad.');
        expect(a.body.toLowerCase(), isNot(contains('accident')));
        expect(a.title.toLowerCase(), isNot(contains('accident')));
        expect(tierFor(a), AlertTier.critical);
        expect(priorityForKey(a.key), AlertPriority.sos);
      }
      final a = policy.standing([memberReport], lead, nowMs: t0 + min).single;
      expect(a.speech, 'Arjun reported a rider down 1.8 kilometers north-east of you.');
      expect(policy.standing([memberReport], pack, nowMs: t0 + min).single.speech, 'Arjun reported a rider down.');
    });

    test('the subject is told, the reporter is not', () {
      final mine = policy.standing([memberReport], kiran, nowMs: t0 + min).single;
      expect(mine.title, 'Rider down reported');
      expect(mine.body, "Arjun reported that you are down. Tap I'm OK if you are fine.");
      expect(mine.aboutMe, isTrue);
      expect(mine.speech, isNull);
      expect(policy.standing([memberReport], arjun, nowMs: t0 + min), isEmpty);
    });

    test('nearby report (reporter at the scene): no place -> distance; never "may have met with an accident"', () {
      final a = policy.standing([nearbyReport], lead, nowMs: t0 + min).single;
      expect(a.key, 'SOS:A2');
      expect(a.body, 'Arjun reported a rider down 1.8 km north-east of you.');
      expect(policy.standing([nearbyReport], pack, nowMs: t0 + min).single.body, 'Arjun reported a rider down.');
      expect(policy.standing([nearbyReport], arjun, nowMs: t0 + min), isEmpty, reason: 'the reporter raised it');
    });

    test('the live alert alone marks a report (3.15 entry without source)', () {
      final plain = ev('r3', 'SOS', user: 'k', name: 'Kiran', open: true, lat: 12.9115, lng: 77.5115, data: {'alertId': 'A3', 'alertType': 'RIDER_DOWN'});
      final live = SosAlertModel(
        alertId: 'A3',
        userId: 'k',
        userName: 'Kiran',
        lat: 12.9115,
        lng: 77.5115,
        alertType: 'RIDER_DOWN',
        timestamp: t0,
        source: EmergencySource.memberReport,
        reportedBy: 'a',
        reportedByName: 'Arjun',
        nearestHospital: const NearbyPlace(name: 'Apollo Hospital', lat: 12.96, lng: 77.56, distanceM: 4200),
      );
      expect(live.isReport, isTrue);
      final a = policy.standing([plain], pack, nowMs: t0 + min, alerts: [live]).single;
      expect(a.body, 'Arjun reported a rider down. Nearest hospital: Apollo Hospital, 4.2 km.');
      expect(a.body, isNot(contains('accident')));
      // Without the live alert a RIDER_DOWN without report fields stays an emergency (3.15 behaviour).
      expect(policy.standing([plain], pack, nowMs: t0 + min).single.body, startsWith('Kiran may have met with an accident.'));
    });

    test('timeline text names the reporter', () {
      expect(TimelineText.title(memberReport, nowMs: t0), 'Arjun reported Kiran down');
      expect(TimelineText.title(nearbyReport, nowMs: t0), 'Arjun reported a rider down');
      final old = ev('r4', 'SOS', user: 'k', name: 'Kiran', open: true, data: {'alertId': 'A4', 'alertType': 'MEDICAL'});
      expect(TimelineText.title(old, nowMs: t0), 'Kiran raised an SOS (medical)');
    });
  });

  group('Stale rider (item 10)', () {
    final stale = ev('s1', 'STALE_UPDATE', user: 'k', name: 'Kiran', open: true, startedAt: t0 - 6 * min, data: {'gapS': 360, 'typicalS': 20, 'notify': ['lead', 'sw']});

    test('lead and sweeper: important, spoken; not the rider, not the pack', () {
      for (final v in [lead, sweeper]) {
        final a = policy.standing([stale], v, nowMs: t0).single;
        expect(a.key, 'STALE:k');
        expect(a.key.startsWith(AlertPolicy.stalePrefix), isTrue);
        expect(a.channel, AlertChannel.alerts);
        expect(a.title, "Kiran's last update was 6 min");
        expect(a.body, 'Usually every 20 s. Their phone may have lost signal or closed CoRoute.');
        expect(a.speech, 'No update from Kiran for 6 min.');
        expect(tierFor(a), AlertTier.important);
        expect(priorityForKey(a.key), AlertPriority.groupSafety);
      }
      expect(policy.standing([stale], kiran, nowMs: t0), isEmpty);
      expect(policy.standing([stale], pack, nowMs: t0), isEmpty);
      final closed = ev('s1', 'STALE_UPDATE', user: 'k', name: 'Kiran', startedAt: t0 - 8 * min, durationMs: 8 * min, data: {'result': 'RESUMED'});
      expect(policy.standing([closed], lead, nowMs: t0), isEmpty);
      expect(TimelineText.title(stale, nowMs: t0), 'No update from Kiran for 6 min');
      expect(TimelineText.title(closed, nowMs: t0), 'Kiran: updates resumed after 8 min');
      expect(TimelineText.detail(stale, nowMs: t0), 'usually every 20 s');
    });
  });

  group('Low battery (item 12)', () {
    final low = ev('b1', 'LOW_BATTERY', user: 'k', name: 'Kiran', open: true, data: {'level': 14, 'notify': ['lead']});

    test('lead and sweeper see it; the rider is reminded without speech', () {
      for (final v in [lead, sweeper]) {
        final a = policy.standing([low], v, nowMs: t0).single;
        expect(a.key, 'BATTERY:k');
        expect(a.title, 'Kiran 14% battery');
        expect(a.body, 'Their phone may switch off soon.');
        expect(a.speech, "Kiran's battery is low.");
        expect(a.channel, AlertChannel.alerts);
        expect(tierFor(a), AlertTier.important);
        expect(priorityForKey(a.key), AlertPriority.groupSafety);
      }
      final mine = policy.standing([low], kiran, nowMs: t0).single;
      expect(mine.key, 'BATTERY:k');
      expect(mine.title, 'Your battery is at 14%');
      expect(mine.body, 'Plug in at the next stop. Your group can see this.');
      expect(mine.speech, isNull);
      expect(mine.aboutMe, isTrue);
      expect(tierFor(mine), AlertTier.important);
      expect(policy.standing([low], pack, nowMs: t0), isEmpty);
      expect(TimelineText.title(low, nowMs: t0), 'Kiran: battery 14%');
      final charging = ev('b1', 'LOW_BATTERY', user: 'k', name: 'Kiran', durationMs: min, data: {'level': 14, 'result': 'CHARGING'});
      expect(TimelineText.title(charging, nowMs: t0), 'Kiran: battery charging');
      final ok = ev('b1', 'LOW_BATTERY', user: 'k', name: 'Kiran', durationMs: min, data: {'level': 26, 'result': 'RECOVERED'});
      expect(TimelineText.title(ok, nowMs: t0), 'Kiran: battery recovered');
    });
  });

  group('Behind the sweeper (item 11)', () {
    final behind = ev('w1', 'BEHIND_SWEEPER', user: 'k', name: 'Kiran', open: true, startedAt: t0 - 2 * min,
        data: {'distanceM': 600, 'maxDistanceM': 650, 'sweeperId': 'sw', 'sweeperName': 'Sam', 'notify': ['sw', 'lead']});

    test('sweeper and lead: important, spoken; the rider: normal note; the pack: nothing', () {
      for (final v in [sweeper, lead]) {
        final a = policy.standing([behind], v, nowMs: t0).single;
        expect(a.key, 'BEHIND:k');
        expect(a.title, 'Kiran is behind you');
        expect(a.body, '600 m behind the sweeper for 2 min.');
        expect(a.speech, 'Kiran is behind you.');
        expect(a.channel, AlertChannel.alerts);
        expect(tierFor(a), AlertTier.important);
        expect(priorityForKey(a.key), AlertPriority.groupSafety);
      }
      final mine = policy.standing([behind], kiran, nowMs: t0).single;
      expect(mine.key, 'BEHIND:k');
      expect(mine.channel, AlertChannel.updates);
      expect(mine.title, 'You are behind the sweeper');
      expect(mine.body, 'Stay with the group.');
      expect(mine.speech, isNull);
      expect(tierFor(mine), AlertTier.normal);
      expect(policy.standing([behind], pack, nowMs: t0), isEmpty);
      expect(TimelineText.title(behind, nowMs: t0), 'Kiran is behind the sweeper (600 m)');
      expect(TimelineText.detail(behind, nowMs: t0), 'sweeper Sam');
      final closed = ev('w1', 'BEHIND_SWEEPER', user: 'k', name: 'Kiran', durationMs: 3 * min, data: {'distanceM': 80, 'maxDistanceM': 650});
      expect(TimelineText.title(closed, nowMs: t0), 'Kiran fell behind the sweeper (650 m)');
    });

    test('role change and follow-up timeline lines', () {
      expect(TimelineText.title(ev('x1', 'ROLE_CHANGED', user: 'k', name: 'Kiran', data: {'role': 'SWEEPER', 'byUserId': 'lead'}), nowMs: t0), 'Kiran is now the sweeper');
      expect(TimelineText.title(ev('x2', 'ROLE_CHANGED', user: 'k', name: 'Kiran', data: {'role': 'PACK'}), nowMs: t0), 'Kiran is no longer the sweeper');
      expect(TimelineText.title(ev('x3', 'FOLLOW_UP', user: 'k', name: 'Kiran', data: {'result': 'OK'}), nowMs: t0), 'Kiran said they are still OK');
    });
  });

  group('Overspeed by context (item 13)', () {
    test('town context names the town limit; group context unchanged', () {
      final town = ev('o1', 'OVERSPEED', user: 'k', name: 'Kiran', open: true, data: {'limitKmh': 40, 'maxKmh': 58, 'context': 'TOWN'});
      final a = policy.oneShot(town, lead)!;
      expect(a.title, 'Kiran is over the limit of 40 km/h near a stop or in town');
      expect(a.body, 'Reached 58 km/h');
      expect(policy.oneShot(town, kiran)!.title, 'You are over the limit of 40 km/h near a stop or in town');
      expect(TimelineText.title(town, nowMs: t0), 'Kiran is over the town limit of 40 km/h');
      final group = ev('o2', 'OVERSPEED', user: 'k', name: 'Kiran', open: true, data: {'limitKmh': 80, 'maxKmh': 95, 'context': 'GROUP'});
      expect(policy.oneShot(group, lead)!.title, 'Kiran is over the group limit of 80 km/h');
      expect(TimelineText.title(group, nowMs: t0), 'Kiran is over the 80 km/h limit');
    });
  });

  group('Far by road (item 5) and the hospital line (item 18)', () {
    const req = AssistRequest(incidentId: 'NET-0123456789AB', lat: 12.9115, lng: 77.5115, distanceM: 1800, routeDistanceM: 9600, etaS: 720, receivedAt: t0, farByRoad: true);

    test('far by road: the body says so with the road distance and ETA', () {
      final a = policy.network(assists: [req], me: lead, nowMs: t0).single;
      expect(a.key, 'ASSIST:NET-0123456789AB');
      expect(a.title, 'Rider emergency nearby');
      expect(a.body, 'Far by road: 9.6 km by road, about 12 min. Your group may still be the closest riders.');
      expect(a.channel, AlertChannel.sos);
      expect(tierFor(a), AlertTier.critical);
      expect(a.speech, isNotNull);
      // Parsed from the wire; absent means false.
      expect(AssistRequest.fromJson({'incidentId': 'NET-1', 'lat': 1.0, 'lng': 2.0, 'farByRoad': true}, receivedAt: t0)!.farByRoad, isTrue);
      expect(AssistRequest.fromJson({'incidentId': 'NET-1', 'lat': 1.0, 'lng': 2.0}, receivedAt: t0)!.farByRoad, isFalse);
      expect(NetResponder.fromJson({'rid': 'r1', 'status': 'ACCEPTED', 'farByRoad': true})!.farByRoad, isTrue);
      expect(NetResponder.fromJson({'rid': 'r1', 'status': 'ACCEPTED'})!.farByRoad, isFalse);
      // An ordinary request keeps the 3.15 text.
      final near = policy.network(assists: [AssistRequest.fromJson({'incidentId': 'NET-2', 'lat': 12.9115, 'lng': 77.5115, 'distanceM': 1800}, receivedAt: t0)!], me: lead, nowMs: t0).single;
      expect(near.body, startsWith('A rider from another group may have met with an accident.'));
    });

    test('hospital known: appended to the emergency body, no new speech', () {
      final crash = ev('e1', 'SOS', user: 'k', name: 'Kiran', open: true, lat: 12.9115, lng: 77.5115, data: {'alertId': 'A1', 'alertType': 'CRASH', 'auto': true});
      final live = SosAlertModel(
        alertId: 'A1',
        userId: 'k',
        userName: 'Kiran',
        lat: 12.9115,
        lng: 77.5115,
        alertType: 'CRASH',
        timestamp: t0,
        auto: true,
        source: EmergencySource.crashAuto,
        lastUpdateAt: t0,
        nearestHospital: const NearbyPlace(name: 'Apollo Hospital', lat: 12.96, lng: 77.56, distanceM: 4200),
      );
      final a = policy.standing([crash], pack, nowMs: t0 + min, alerts: [live]).single;
      expect(a.title, 'EMERGENCY');
      expect(a.body, 'Kiran may have met with an accident. Automatic alert. Last location update: 1 min ago. Nearest hospital: Apollo Hospital, 4.2 km.');
      expect(a.speech, 'Emergency. Kiran may have met with an accident.');
      expect(AlertPolicy.hospitalLine(live.copyWith()), 'Nearest hospital: Apollo Hospital, 4.2 km.');
      expect(AlertPolicy.hospitalLine(null), '');
    });
  });

  group('Stopped and separated now have speech (night voice, item 15)', () {
    test('spoken lines and the important voice priority', () {
      final stopped = ev('st', 'STOPPED', user: 'k', name: 'Kiran', open: true, startedAt: t0 - 21 * min, data: {'reason': 'FUELING'});
      final a = policy.standing([stopped], lead, nowMs: t0).single;
      expect(a.title, 'Kiran has been stopped for 21 min');
      expect(a.speech, 'Kiran has been stopped for 21 min.');
      expect(AlertService.speechPriority(a), VoicePriority.important);
      final sep = ev('se', 'SEPARATED', user: 'k', name: 'Kiran', open: true, startedAt: t0 - 3 * min, data: {'maxDistanceM': 2400});
      expect(policy.standing([sep], lead, nowMs: t0).single.speech, 'Kiran is 2.4 km from the group.');
      expect(policy.standing([sep], kiran, nowMs: t0).single.speech, 'You are 2.4 km from your group.');
      final sos = policy.standing([ev('e1', 'SOS', user: 'k', name: 'Kiran', open: true, data: {'alertId': 'A1', 'alertType': 'CRASH', 'auto': true})], lead, nowMs: t0).single;
      expect(AlertService.speechPriority(sos), VoicePriority.critical);
      expect(AlertService.speechPriority(const AlertSpec('MEET:1', AlertChannel.social, 't', 'b')), VoicePriority.warning);
      expect(AlertService.speechPriority(const AlertSpec('HAZARD:1', AlertChannel.hazard, 't', 'b')), VoicePriority.important);
    });

    test('spoken lines follow the voice language, the screen the app language', () {
      final sep = ev('se', 'SEPARATED', user: 'k', name: 'Kiran', open: true, startedAt: t0 - 3 * min, data: {'maxDistanceM': 2400});
      final a = policy.standing([sep], lead, nowMs: t0, speechLang: 'hi').single;
      expect(a.title, 'Kiran is 2.4 km from the group', reason: 'other screens stay English');
      expect(a.speech, 'Kiran ग्रुप से 2.4 km दूर है।');
      final te = policy.standing([sep], kiran, nowMs: t0, speechLang: 'te').single;
      expect(te.speech, 'మీరు మీ గ్రూప్ కి 2.4 km దూరంలో ఉన్నారు.');
      L10n.setLanguage(AppLanguage.te);
      final low = ev('b1', 'LOW_BATTERY', user: 'k', name: 'Kiran', open: true, data: {'level': 14});
      final b = policy.standing([low], kiran, nowMs: t0).single;
      expect(b.title, 'మీ బ్యాటరీ 14% ఉంది');
      L10n.setLanguage(AppLanguage.en);
    });
  });

  group('Priority and tiers of the new keys', () {
    test('arbiter order: new keys are group safety, local prompts important', () {
      expect(priorityForKey('STALE:k'), AlertPriority.groupSafety);
      expect(priorityForKey('BATTERY:k'), AlertPriority.groupSafety);
      expect(priorityForKey('BEHIND:k'), AlertPriority.groupSafety);
      expect(priorityForKey(AlertPolicy.fuelKey), AlertPriority.groupSafety);
      expect(priorityForKey(AlertPolicy.followUpKey), AlertPriority.groupSafety);
      expect(tierFor(const AlertSpec(AlertPolicy.fuelKey, AlertChannel.alerts, 'Fuel soon', '')), AlertTier.important);
      expect(tierFor(const AlertSpec(AlertPolicy.followUpKey, AlertChannel.alerts, 'Still okay?', '')), AlertTier.important);
      expect(AlertPolicy.fuelKey, 'LOCAL:FUEL');
      expect(AlertPolicy.followUpKey, 'LOCAL:FOLLOW_UP');
      final order = AlertArbiter.arrange(
        ['BEHIND:k', 'SOS:1', 'HAZARD:1', 'ASSIST:1', 'MEET:1', 'OFF_ROUTE:k'],
        (k) => priorityForKey(k),
      );
      expect(order, ['SOS:1', 'ASSIST:1', 'HAZARD:1', 'BEHIND:k', 'OFF_ROUTE:k', 'MEET:1']);
    });

    test('inAppAlerts keeps one row per key and the badge counts the important ones', () {
      final stale = ev('s1', 'STALE_UPDATE', user: 'k', name: 'Kiran', open: true, startedAt: t0 - 6 * min, data: {'typicalS': 20});
      final behindMe = ev('w1', 'BEHIND_SWEEPER', user: 'lead', name: 'Lead', open: true, startedAt: t0 - 2 * min, data: {'distanceM': 600});
      final rows = inAppAlerts([stale, behindMe], lead, nowMs: t0);
      expect(rows.map((r) => r.key), ['STALE:k', 'BEHIND:lead']);
      expect(rows.first.tier, AlertTier.important);
      expect(rows.last.tier, AlertTier.normal);
      expect(alertBadgeCount(rows), 1);
    });
  });
}
