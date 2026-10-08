import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/network_models.dart';
import 'package:coroute_app/data/models/network_wire.dart';
import 'package:coroute_app/data/models/pending_sos.dart';
import 'package:coroute_app/data/models/safety_wire.dart';
import 'package:coroute_app/data/models/sos_alert_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Enums round-trip through their wire names', () {
    test('every value', () {
      for (final v in EmergencyStatus.values) {
        expect(EmergencyStatus.fromWire(v.wire), v);
      }
      for (final v in EmergencySource.values) {
        expect(EmergencySource.fromWire(v.wire), v);
      }
      for (final v in EmergencySeverity.values) {
        expect(EmergencySeverity.fromWire(v.wire), v);
      }
      for (final v in ResolveReason.values) {
        expect(ResolveReason.fromWire(v.wire), v);
      }
      for (final v in ResponderStatus.values) {
        expect(ResponderStatus.fromWire(v.wire), v);
      }
      for (final v in AssistAnswer.values) {
        expect(AssistAnswer.fromWire(v.wire), v);
      }
      for (final v in NetworkState.values) {
        expect(NetworkState.fromWire(v.wire), v);
      }
      for (final v in HazardLevel.values) {
        expect(HazardLevel.fromWire(v.wire), v);
      }
      for (final v in EncounterType.values) {
        expect(EncounterType.fromWire(v.wire), v);
      }
      for (final v in AssistClosedReason.values) {
        expect(AssistClosedReason.fromWire(v.wire), v);
      }
      for (final v in GroupVisibility.values) {
        expect(GroupVisibility.fromWire(v.wire), v);
      }
    });

    test('exact wire names of the contract', () {
      expect(EmergencyStatus.confirmedAccident.wire, 'CONFIRMED_ACCIDENT');
      expect(EmergencyStatus.assistanceArrived.wire, 'ASSISTANCE_ARRIVED');
      expect(EmergencySource.crashAuto.wire, 'CRASH_AUTO');
      expect(EmergencySource.nearbyReport.wire, 'NEARBY_REPORT');
      expect(ResponderStatus.unableToReach.wire, 'UNABLE_TO_REACH');
      expect(ResponderStatus.enRoute.wire, 'EN_ROUTE');
      expect(AssistAnswer.notFound.wire, 'NOT_FOUND');
      expect(NetworkState.noneFound.wire, 'NONE_FOUND');
      expect(HazardLevel.responderArriving.wire, 'RESPONDER_ARRIVING');
      expect(EncounterType.oppositeDirection.wire, 'OPPOSITE_DIRECTION');
      expect(GroupVisibility.public.wire, 'PUBLIC');
      expect(ProtocolFeatures.safetyNet, 'net1');
      expect(ProtocolFeatures.discovery, 'discovery1');
      expect(SosTypes.riderDown, 'RIDER_DOWN');
    });

    test('unknown values: null, visibility private', () {
      expect(EmergencyStatus.fromWire('POSSIBLE_ACCIDENT'), isNull, reason: 'phone-only, never on the wire');
      expect(ResponderStatus.fromWire(null), isNull);
      expect(EmergencySource.fromWire('crash_auto'), EmergencySource.crashAuto);
      expect(GroupVisibility.fromWire(null), GroupVisibility.private);
      expect(GroupVisibility.fromWire('SECRET'), GroupVisibility.private);
    });

    test('open and terminal statuses', () {
      expect(EmergencyStatus.values.where((s) => s.isOpen).toList(), [
        EmergencyStatus.confirmedAccident,
        EmergencyStatus.assistanceRequested,
        EmergencyStatus.responderAssigned,
        EmergencyStatus.assistanceArrived,
      ]);
      for (final s in EmergencyStatus.values) {
        expect(s.isOpen, !s.isTerminal);
      }
      expect(AssistAnswer.accept.resultingStatus, ResponderStatus.accepted);
      expect(AssistAnswer.notFound.resultingStatus, ResponderStatus.unableToReach);
    });
  });

  group('SOS alert (EmergencyEvent)', () {
    test('a 3.14 alert decodes with a derived status and source', () {
      final open = SosAlertModel.fromJson({'alertId': 'SOS-1', 'userId': 'u', 'timestamp': 7});
      expect(open.status, isNull);
      expect(open.effectiveStatus, EmergencyStatus.assistanceRequested);
      expect(open.effectiveSource, EmergencySource.manual);
      expect(open.lastKnownAt, 7);
      expect(open.network, isNull);
      final crash = SosAlertModel.fromJson({'alertId': 'SOS-2', 'userId': 'u', 'timestamp': 7, 'auto': true, 'alertType': 'CRASH', 'resolved': true});
      expect(crash.effectiveStatus, EmergencyStatus.resolved);
      expect(crash.effectiveSource, EmergencySource.crashAuto);
      expect(crash.isAccident, isTrue);
    });

    test('3.15 fields, network and own nearest round-trip; bad fields are ignored', () {
      final a = SosAlertModel.fromJson({
        'alertId': 'SOS-3',
        'userId': 'u_r',
        'userName': 'Rahul',
        'timestamp': 100,
        'alertType': 'RIDER_DOWN',
        'status': 'RESPONDER_ASSIGNED',
        'source': 'MEMBER_REPORT',
        'severity': 'HIGH',
        'heading': 182,
        'speedKmh': 0,
        'accuracyM': 12,
        'lastUpdateAt': 150,
        'reportedBy': 'u_k',
        'reportedByName': 'Kiran',
        'routeIndex': 12,
        'network': {
          'state': 'ASSIGNED',
          'stage': 1,
          'notified': 2,
          'onScene': false,
          'responders': [
            {'rid': 'abcdefabcdef', 'name': 'Arjun', 'status': 'EN_ROUTE', 'etaS': 180, 'distanceM': 1500, 'lat': 17.5, 'lng': 78.0, 'acceptedAt': 120, 'arrivedAt': 0},
            {'name': 'no rid'},
            'junk',
          ],
        },
        'ownNearest': {'userId': 'u_k', 'name': 'Kiran', 'etaS': 600, 'distanceM': 9000, 'routeBased': true},
      });
      expect(a.status, EmergencyStatus.responderAssigned);
      expect(a.source, EmergencySource.memberReport);
      expect(a.severity, EmergencySeverity.high);
      expect(a.heading, 182);
      expect(a.lastKnownAt, 150);
      expect(a.reportedByName, 'Kiran');
      expect(a.isAccident, isTrue);
      expect(a.network!.state, NetworkState.assigned);
      expect(a.network!.responders.length, 1);
      expect(a.network!.activeResponder!.name, 'Arjun');
      expect(a.ownNearest!.etaS, 600);
      final back = SosAlertModel.fromJson(a.toJson());
      expect(back.status, EmergencyStatus.responderAssigned);
      expect(back.network!.activeResponder!.etaS, 180);
      expect(back.ownNearest!.routeBased, isTrue);
      expect(back.reportedBy, 'u_k');

      final bad = SosAlertModel.fromJson({'alertId': 'SOS-4', 'userId': 'u', 'timestamp': 1, 'status': 42, 'network': 'x', 'ownNearest': {'userId': 'u'}, 'heading': 'north'});
      expect(bad.status, isNull);
      expect(bad.network, isNull);
      expect(bad.ownNearest, isNull);
      expect(bad.heading, isNull);
    });
  });

  group('Network models are tolerant', () {
    test('assist request: required id and position, defaults otherwise', () {
      expect(AssistRequest.fromJson({'incidentId': 'NET-0123456789AB'}, receivedAt: 5), isNull);
      expect(AssistRequest.fromJson('x', receivedAt: 5), isNull);
      final r = AssistRequest.fromJson({'incidentId': 'NET-0123456789AB', 'lat': 17.5, 'lng': 78.0, 'distanceM': 1600, 'aheadOnRoute': true, 'severity': 'CRITICAL', 'reportedAt': 3}, receivedAt: 5)!;
      expect(r.myStatus, ResponderStatus.requested);
      expect(r.accepted, isFalse);
      expect(r.severity, EmergencySeverity.critical);
      expect(r.kind, 'ACCIDENT');
      expect(r.lastUpdateAt, 3);
      expect(r.subject, isNull);
      final u = r.merge({
        'incidentId': 'NET-0123456789AB',
        'myStatus': 'ARRIVING',
        'lat': 17.51,
        'lng': 78.0,
        'subject': {'firstName': 'Rahul', 'vehicleType': 'Motorcycle', 'vehicleColor': 'Red'},
        'medical': {'bloodGroup': 'O+'},
        'arrivalCheck': true,
      });
      expect(u.myStatus, ResponderStatus.arriving);
      expect(u.accepted, isTrue);
      expect(u.lat, 17.51);
      expect(u.subject!.firstName, 'Rahul');
      expect(u.medical!.bloodGroup, 'O+');
      expect(u.arrivalCheck, isTrue);
      expect(u.distanceM, 1600, reason: 'fields not in the update stay');
    });

    test('hazard and encounter', () {
      expect(HazardWarning.fromJson({'hazardId': 'NET-1', 'lat': 'a', 'lng': 1}, receivedAt: 1), isNull);
      final h = HazardWarning.fromJson({'hazardId': 'NET-1', 'lat': 17.5, 'lng': 78.0, 'level': 'ON_SCENE', 'aheadM': 2000, 'onRoute': true}, receivedAt: 9)!;
      expect(h.level, HazardLevel.onScene);
      expect(h.reportedAt, 9);
      expect(Encounter.fromJson({'encounterId': 'ENC-1', 'type': 'SIDEWAYS'}, at: 1), isNull);
      final e = Encounter.fromJson({'encounterId': 'ENC-1', 'type': 'CONVERGING', 'groupName': 'Royal Riders', 'riders': 4, 'distanceM': 3000, 'meetingS': 180}, at: 1)!;
      expect(e.type, EncounterType.converging);
      expect(e.iWaved, isFalse);
      expect(e.copyWith(iWaved: true).groupName, 'Royal Riders');
    });
  });

  group('Convoy and pending SOS', () {
    test('group visibility defaults: private, discovery off, assist default on', () {
      final c = ConvoyModel.fromJson({'groupId': 'G', 'name': 'n', 'joinCode': '1', 'createdByUserId': 'u', 'createdByUserName': 'U', 'createdAtEpochMs': 1});
      expect(c.visibility, GroupVisibility.private);
      expect(c.discovery, isFalse);
      expect(c.assistDefault, isTrue);
      final p = ConvoyModel.fromJson({...c.toJson(), 'visibility': 'PUBLIC', 'discovery': true, 'assistDefault': false});
      expect(p.visibility, GroupVisibility.public);
      expect(ConvoyModel.fromJson(p.toJson()).discovery, isTrue);
      expect(p.copyWith(visibility: GroupVisibility.private).assistDefault, isFalse);
    });

    test('pending SOS keeps its source and sends the last fix', () {
      const s = PendingSos(
        clientId: 'c-1',
        groupId: 'G',
        lat: 1,
        lng: 2,
        type: SosTypes.crash,
        createdAt: 5,
        auto: true,
        source: EmergencySource.needHelp,
        heading: 361.4,
        speedKmh: 42.04,
        accuracyM: 8.6,
      );
      final back = PendingSos.decode(s.encode())!;
      expect(back.source, EmergencySource.needHelp);
      final m = back.toMessage();
      expect(m['source'], 'NEED_HELP');
      expect(m['heading'], 1);
      expect(m['speedKmh'], 42.0);
      expect(m['accuracyM'], 9);
      final old = PendingSos.decode('{"clientId":"usr_a-1","groupId":"GRP-1","lat":1.5,"lng":2.5,"type":"EMERGENCY","createdAt":5}')!;
      expect(old.source, EmergencySource.manual);
      expect(old.toMessage()['source'], 'MANUAL');
      expect(old.toMessage().containsKey('heading'), isFalse);
    });
  });
}
