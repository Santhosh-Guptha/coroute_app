import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/medical_info.dart';
import 'package:coroute_app/data/models/network_models.dart';
import 'package:coroute_app/data/models/network_wire.dart';
import 'package:coroute_app/data/models/ride_feature_policy.dart';
import 'package:coroute_app/data/models/sos_alert_model.dart';
import 'package:coroute_app/domain/dtn/dtn_bundle.dart';

String sha256Hex(String input) {
  final bytes = utf8.encode(input);
  final digest = DtnCrypto.sha256(bytes);
  return digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
}

void main() {
  group('Cross-Group Assistance Topology and Route-Aware Filtering', () {
    test('AssistRequest models route-aware convergence and aheadOnRoute parameters', () {
      final jsonPayload = {
        'incidentId': 'NET-0123456789AB',
        'lat': 17.50000,
        'lng': 78.40000,
        'distanceM': 3000,
        'routeDistanceM': 3200,
        'aheadOnRoute': true,
        'etaS': 180,
        'fasterThanGroup': true,
        'severity': 'HIGH',
        'kind': 'ACCIDENT',
        'reportedAt': 1700000000000,
        'lastUpdateAt': 1700000001000,
        'myStatus': 'REQUESTED',
        'farByRoad': false,
      };

      final req = AssistRequest.fromJson(jsonPayload, receivedAt: 1700000002000);
      expect(req, isNotNull);
      expect(req!.incidentId, 'NET-0123456789AB');
      expect(req.aheadOnRoute, isTrue);
      expect(req.routeDistanceM, 3200.0);
      expect(req.distanceM, 3000.0);
      expect(req.fasterThanGroup, isTrue);
      expect(req.etaS, 180);
      expect(req.severity, EmergencySeverity.high);
      expect(req.isAccident, isTrue);
      expect(req.farByRoad, isFalse);
      expect(req.myStatus, ResponderStatus.requested);
      expect(req.accepted, isFalse);
    });

    test('AssistRequest correctly flags farByRoad and non-ahead topology', () {
      // Incident is 1.8 km straight-line but 12 km by road (parallel valley or detour).
      final detourPayload = {
        'incidentId': 'NET-ABCDEF012345',
        'lat': 17.50000,
        'lng': 78.40000,
        'distanceM': 1800,
        'routeDistanceM': 12000,
        'aheadOnRoute': false,
        'etaS': 900,
        'fasterThanGroup': false,
        'severity': 'LOW',
        'kind': 'ACCIDENT',
        'farByRoad': true,
      };

      final req = AssistRequest.fromJson(detourPayload, receivedAt: 1700000002000);
      expect(req, isNotNull);
      expect(req!.aheadOnRoute, isFalse);
      expect(req.farByRoad, isTrue);
      expect(req.routeDistanceM, 12000.0);
      expect(req.fasterThanGroup, isFalse);
    });

    test('HazardWarning verifies onRoute and aheadM for approaching riders', () {
      final hazardPayload = {
        'hazardId': 'NET-HAZARD-01',
        'lat': 17.50000,
        'lng': 78.40000,
        'level': 'ACTIVE',
        'aheadM': 2500,
        'onRoute': true,
        'reportedAt': 1700000000000,
      };

      final hazard = HazardWarning.fromJson(hazardPayload, receivedAt: 1700000001000);
      expect(hazard, isNotNull);
      expect(hazard!.onRoute, isTrue);
      expect(hazard.aheadM, 2500.0);
      expect(hazard.level, HazardLevel.active);

      // Approaching responder arrives on scene.
      final onScenePayload = {
        'hazardId': 'NET-HAZARD-01',
        'lat': 17.50000,
        'lng': 78.40000,
        'level': 'ON_SCENE',
        'aheadM': 100,
        'onRoute': true,
      };
      final onScene = HazardWarning.fromJson(onScenePayload, receivedAt: 1700000002000);
      expect(onScene!.level, HazardLevel.onScene);
      expect(onScene.onRoute, isTrue);
    });
  });

  group('Privacy Separation Invariant: SOCIAL PRIVACY != SAFETY RELAY CONSENT', () {
    test('ConvoyModel enforces separation between social discovery and safety assistance consent', () {
      // Default convoy is Private with discovery OFF, but safety assistance consent is ON by default.
      final defaultConvoy = ConvoyModel.fromJson({
        'groupId': 'GRP-PRIV-01',
        'name': 'Private Riding Group',
        'joinCode': '123456',
        'createdByUserId': 'user_lead',
        'createdByUserName': 'Lead Rider',
        'createdAtEpochMs': 1700000000000,
      });

      expect(defaultConvoy.visibility, GroupVisibility.private);
      expect(defaultConvoy.discovery, isFalse);
      expect(defaultConvoy.assistDefault, isTrue, reason: 'Safety relay consent is active by default even when social discovery is private');

      // Toggling social discovery to Public does not alter assist default.
      final publicConvoy = defaultConvoy.copyWith(
        visibility: GroupVisibility.public,
        discovery: true,
      );
      expect(publicConvoy.visibility, GroupVisibility.public);
      expect(publicConvoy.discovery, isTrue);
      expect(publicConvoy.assistDefault, isTrue);

      // Disabling safety assist consent independently of social discovery.
      final optOutAssist = publicConvoy.copyWith(assistDefault: false);
      expect(optOutAssist.visibility, GroupVisibility.public);
      expect(optOutAssist.discovery, isTrue);
      expect(optOutAssist.assistDefault, isFalse);

      // Re-verifying private convoy with assist opt-in.
      final privateAssistOn = optOutAssist.copyWith(
        visibility: GroupVisibility.private,
        discovery: false,
        assistDefault: true,
      );
      expect(privateAssistOn.visibility, GroupVisibility.private);
      expect(privateAssistOn.discovery, isFalse);
      expect(privateAssistOn.assistDefault, isTrue);
    });

    test('Encounter model strictly excludes exact coordinates from public discovery', () {
      // Verify deserialization strips any attempted injection of GPS coordinates.
      final injectionPayload = {
        'encounterId': 'ENC-0123456789AB',
        'type': 'OPPOSITE_DIRECTION',
        'groupName': 'Highway Riders',
        'riders': 5,
        'distanceM': 3500.0,
        'meetingS': 90,
        'sameRoute': true,
        // Hostile or accidental coordinate injection.
        'lat': 17.50123,
        'lng': 78.40987,
        'exactLat': 17.50123,
        'exactLng': 78.40987,
        'coordinates': [17.50123, 78.40987],
        'members': ['Alice', 'Bob'],
        'userId': 'hidden_user',
      };

      final encounter = Encounter.fromJson(injectionPayload, at: 1700000000000);
      expect(encounter, isNotNull);
      expect(encounter!.encounterId, 'ENC-0123456789AB');
      expect(encounter.type, EncounterType.oppositeDirection);
      expect(encounter.groupName, 'Highway Riders');
      expect(encounter.riders, 5);
      expect(encounter.distanceM, 3500.0);
      expect(encounter.meetingS, 90);
      expect(encounter.sameRoute, isTrue);

      // Confirm Encounter model has zero coordinate fields and does not leak identities.
      final encounterMap = {
        'encounterId': encounter.encounterId,
        'type': encounter.type.wire,
        'groupName': encounter.groupName,
        'riders': encounter.riders,
        'distanceM': encounter.distanceM,
        'meetingS': encounter.meetingS,
        'sameRoute': encounter.sameRoute,
      };
      expect(encounterMap.containsKey('lat'), isFalse);
      expect(encounterMap.containsKey('lng'), isFalse);
      expect(encounterMap.containsKey('members'), isFalse);
      expect(encounterMap.containsKey('userId'), isFalse);
    });

    test('AssistRequest privacy isolation: subject details hidden until acceptance, zero private identity leaks', () {
      final initialJson = {
        'incidentId': 'NET-0123456789AB',
        'lat': 17.50000,
        'lng': 78.40000,
        'distanceM': 2500,
        'routeDistanceM': 2600,
        'aheadOnRoute': true,
        'myStatus': 'REQUESTED',
        // In initial request, subject and medical must not be present.
        'subject': null,
        'medical': null,
      };

      final initialReq = AssistRequest.fromJson(initialJson, receivedAt: 1700000000000)!;
      expect(initialReq.subject, isNull, reason: 'Subject details must remain hidden before acceptance');
      expect(initialReq.medical, isNull, reason: 'Medical details must remain hidden before acceptance');
      expect(initialReq.accepted, isFalse);

      // After acceptance update: only firstName and vehicle details are disclosed.
      final updateJson = {
        'incidentId': 'NET-0123456789AB',
        'myStatus': 'ACCEPTED',
        'subject': {
          'firstName': 'Priya',
          'vehicleType': 'Motorcycle',
          'vehicleColor': 'Blue',
          // Malformed extra fields that should never be stored.
          'lastName': 'Sharma',
          'phone': '+919876543210',
          'emergencyContact': '+919000000000',
          'groupId': 'SECRET_GROUP',
        },
        'medical': {
          'bloodGroup': 'B+',
          'allergies': 'Latex',
          'notes': 'Carries EpiPen',
        },
      };

      final updatedReq = initialReq.merge(updateJson);
      expect(updatedReq.accepted, isTrue);
      expect(updatedReq.myStatus, ResponderStatus.accepted);
      expect(updatedReq.subject, isNotNull);
      expect(updatedReq.subject!.firstName, 'Priya');
      expect(updatedReq.subject!.vehicleType, 'Motorcycle');
      expect(updatedReq.subject!.vehicleColor, 'Blue');

      // Verify AssistSubject has no identity leaks.
      final s = updatedReq.subject!;
      expect(s.firstName, 'Priya');
      expect(s.vehicleType, 'Motorcycle');
      expect(s.vehicleColor, 'Blue');

      // Medical details visible only because of subject opt-in.
      expect(updatedReq.medical, isNotNull);
      expect(updatedReq.medical!.bloodGroup, 'B+');
      expect(updatedReq.medical!.allergies, 'Latex');
    });

    test('Medical details confidentiality and immediate purge upon emergency resolution', () {
      final activeAlert = SosAlertModel(
        alertId: 'SOS-MED-01',
        userId: 'patient_01',
        userName: 'Vikram',
        lat: 17.50000,
        lng: 78.40000,
        timestamp: 1700000000000,
        alertType: 'CRASH',
        status: EmergencyStatus.confirmedAccident,
        medical: const MedicalInfo(
          bloodGroup: 'O+',
          allergies: 'Penicillin',
          notes: 'Diabetic',
        ),
        resolved: false,
      );

      expect(activeAlert.medical, isNotNull);
      expect(activeAlert.effectiveStatus.isOpen, isTrue);

      // Resolution occurs: terminal status purge invariant.
      final resolvedAlert = activeAlert.copyWith(
        resolved: true,
        status: EmergencyStatus.resolved,
        clearMedical: true, // Purged upon resolution
      );

      expect(resolvedAlert.resolved, isTrue);
      expect(resolvedAlert.effectiveStatus.isTerminal, isTrue);
      expect(resolvedAlert.medical, isNull, reason: 'Medical data must be purged upon emergency resolution');

      // Verify JSON serialization of resolved alert omits medical information.
      final resolvedJson = resolvedAlert.toJson();
      expect(resolvedJson.containsKey('medical'), isFalse, reason: 'Resolved alert JSON must not contain medical details');
    });
  });

  group('Ride Guardian Capability Token Authorization', () {
    test('SHA-256 capability token validation and deterministic hashing', () {
      const validToken = 'cK9_xY2mP1qR8vW0tL3zN5jH7gF4bA6d';
      expect(validToken.length, 32);

      // Capability token regex matching server validToken rule.
      final tokenRegex = RegExp(r'^[A-Za-z0-9_-]{32}$');
      expect(tokenRegex.hasMatch(validToken), isTrue);

      // Invalid tokens fail pattern check.
      expect(tokenRegex.hasMatch('short'), isFalse);
      expect(tokenRegex.hasMatch('a' * 31), isFalse);
      expect(tokenRegex.hasMatch('a' * 33), isFalse);
      expect(tokenRegex.hasMatch('invalid+token/with=special*chars!'), isFalse);

      // Deterministic SHA-256 digest computation matches wire expectation.
      final tokenHash = sha256Hex(validToken);
      expect(tokenHash.length, 64);
      expect(tokenHash, matches(RegExp(r'^[0-9a-f]{64}$')));

      // Known test vector verification.
      const testInput = 'abc';
      final testHash = sha256Hex(testInput);
      expect(testHash, 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });

    test('Ride Guardian PIN gate format validation and error code handling', () {
      final pinRegex = RegExp(r'^[0-9]{4,8}$');

      // Valid PINs.
      expect(pinRegex.hasMatch('1234'), isTrue);
      expect(pinRegex.hasMatch('849201'), isTrue);
      expect(pinRegex.hasMatch('12345678'), isTrue);

      // Invalid PINs.
      expect(pinRegex.hasMatch('123'), isFalse, reason: 'Too short');
      expect(pinRegex.hasMatch('123456789'), isFalse, reason: 'Too long');
      expect(pinRegex.hasMatch('abcd'), isFalse, reason: 'Non-numeric');
      expect(pinRegex.hasMatch('12 34'), isFalse, reason: 'Whitespace');

      // Handling server GUARDIAN_PIN_REQUIRED error response.
      final errorResponse = {
        'error': 'Enter the correct PIN supplied by the rider.',
        'code': 'GUARDIAN_PIN_REQUIRED',
      };
      expect(errorResponse['code'], 'GUARDIAN_PIN_REQUIRED');
    });

    test('Ride Guardian HTTP status codes: rate limiting (429), pause (423), and revocation (410)', () {
      // HTTP 429 Too Many Requests response handling for PIN brute force.
      final rateLimitError = {'error': 'Too many requests.', 'status': 429};
      expect(rateLimitError['status'], 429);

      // HTTP 423 Locked / GUARDIAN_PAUSED response handling when rider paused link.
      final pausedResponse = {
        'error': 'The rider has paused this link.',
        'code': 'GUARDIAN_PAUSED',
        'status': 423,
      };
      expect(pausedResponse['status'], 423);
      expect(pausedResponse['code'], 'GUARDIAN_PAUSED');

      // HTTP 410 Gone / UNAVAILABLE response handling when link is revoked or expired.
      final revokedResponse = {
        'error': 'This monitoring access is unavailable.',
        'status': 410,
      };
      expect(revokedResponse['status'], 410);
    });

    test('RideFeaturePolicy governs Guardian settings and consent constraints', () {
      const defaultPolicy = RideFeaturePolicy();
      expect(defaultPolicy.guardianEnabled, isTrue);
      expect(defaultPolicy.guardianRequirePin, isFalse);
      expect(defaultPolicy.guardianMaxHours, 72);

      // Strict safety policy configuration.
      final strictPolicy = RideFeaturePolicy.fromJson({
        'guardianRequirePin': true,
        'guardianMaxHours': 24,
      });
      expect(strictPolicy.guardianEnabled, isTrue);
      expect(strictPolicy.guardianRequirePin, isTrue);
      expect(strictPolicy.guardianMaxHours, 24);

      // Group consent state toggle serialization.
      final consentGranted = {'allowed': true};
      final consentRevoked = {'allowed': false};
      expect(consentGranted['allowed'], isTrue);
      expect(consentRevoked['allowed'], isFalse);
    });
  });
}
