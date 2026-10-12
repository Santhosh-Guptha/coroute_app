import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/dtn/dtn_bundle.dart';
import 'package:coroute_app/domain/dtn/dtn_router.dart';
import 'package:coroute_app/domain/dtn/dtn_gateway_uploader.dart';

void main() {
  const convoyKey = 'k_convoy_987654321_alpha_bravo_charlie';
  const wrongKey = 'k_attacker_unauthorized_relay_key_fake';

  group('RFC 9171 / RFC 9172 DtnBundle Core Invariants', () {
    test('bundle creation, age calculation, and remaining TTL evaluation', () {
      final t0 = DateTime(2026, 10, 12, 10, 0, 0);
      final payload = DtnEncryptedPayload.encrypt(
        plaintext: '{"type":"SOS","lat":12.9716,"lng":77.5946,"bloodGroup":"O+"}',
        secretKey: convoyKey,
        keyId: 'convoy-alpha',
      );

      final bundle = DtnBundle(
        bundleId: 'bundle-test-001',
        sourceRiderId: 'rider-alice',
        targetConvoyId: 'convoy-alpha',
        creationTimestamp: t0,
        lifetimeTtlSec: 1800,
        payloadType: DtnPayloadType.sosEmergency,
        encryptedPayload: payload,
        hopCount: 0,
        replicationBudget: 4,
        hopLimit: 8,
      );

      expect(bundle.isExpired(t0), isFalse);
      expect(bundle.age(t0).inSeconds, equals(0));
      expect(bundle.remainingTtlSec(t0), equals(1800));
      expect(bundle.canForward(t0), isTrue);

      // Check midway: 900 seconds later.
      final tMid = t0.add(const Duration(seconds: 900));
      expect(bundle.isExpired(tMid), isFalse);
      expect(bundle.age(tMid).inSeconds, equals(900));
      expect(bundle.remainingTtlSec(tMid), equals(900));
      expect(bundle.canForward(tMid), isTrue);
    });

    test('lifetime expiration boundaries: just under, exactly at, and just over boundary', () {
      final t0 = DateTime(2026, 10, 12, 10, 0, 0);
      final payload = DtnEncryptedPayload.encrypt(
        plaintext: '{"type":"CRASH_DETECTED","gForce":4.2}',
        secretKey: convoyKey,
      );

      final bundle = DtnBundle(
        bundleId: 'bundle-ttl-boundary',
        sourceRiderId: 'rider-bob',
        targetConvoyId: 'convoy-alpha',
        creationTimestamp: t0,
        lifetimeTtlSec: 600, // 10 minutes
        payloadType: DtnPayloadType.crashEscalation,
        encryptedPayload: payload,
        replicationBudget: 4,
      );

      // Just under boundary: 599 seconds.
      final tJustUnder = t0.add(const Duration(seconds: 599));
      expect(bundle.isExpired(tJustUnder), isFalse);
      expect(bundle.remainingTtlSec(tJustUnder), equals(1));
      expect(bundle.canForward(tJustUnder), isTrue);

      // Exactly at boundary: 600 seconds.
      final tExact = t0.add(const Duration(seconds: 600));
      expect(bundle.isExpired(tExact), isTrue);
      expect(bundle.remainingTtlSec(tExact), equals(0));
      expect(bundle.canForward(tExact), isFalse);

      // Just over boundary: 601 seconds.
      final tJustOver = t0.add(const Duration(seconds: 601));
      expect(bundle.isExpired(tJustOver), isTrue);
      expect(bundle.remainingTtlSec(tJustOver), equals(0));
      expect(bundle.canForward(tJustOver), isFalse);
    });

    test('untrusted courier isolation: intermediate courier cannot read payload', () {
      final secretData = '{"medical":"diabetic","contact":"+919999999999"}';
      final payload = DtnEncryptedPayload.encrypt(
        plaintext: secretData,
        secretKey: convoyKey,
        keyId: 'convoy-alpha',
      );

      // Intermediate courier only sees opaque ciphertext and public metadata.
      final courierView = payload.courierInspectionView();
      expect(courierView['isEncrypted'], isTrue);
      expect(courierView['ciphertextLength'], greaterThan(0));
      expect(payload.ciphertext.contains('diabetic'), isFalse);

      // Decryption with wrong/no key fails with security exception.
      expect(
        () => payload.decrypt(wrongKey),
        throwsA(isA<DtnSecurityException>()),
      );

      // Authorised decryption succeeds.
      final decrypted = payload.decrypt(convoyKey);
      expect(decrypted, equals(secretData));
    });

    test('untrusted courier isolation: tampering with ciphertext or authTag fails integrity check', () {
      final payload = DtnEncryptedPayload.encrypt(
        plaintext: '{"alert":"SOS","threat":"injury"}',
        secretKey: convoyKey,
      );

      // Verify legitimate tag passes.
      expect(payload.verifyIntegrity(convoyKey), isTrue);

      // Tampered ciphertext: single character modified by rogue courier.
      final tamperedCiphertext = payload.ciphertext.endsWith('A')
          ? '${payload.ciphertext.substring(0, payload.ciphertext.length - 1)}B'
          : '${payload.ciphertext.substring(0, payload.ciphertext.length - 1)}A';

      final tamperedPayload1 = DtnEncryptedPayload(
        ciphertext: tamperedCiphertext,
        authTag: payload.authTag,
        iv: payload.iv,
        keyId: payload.keyId,
        plaintextLength: payload.plaintextLength,
      );

      expect(tamperedPayload1.verifyIntegrity(convoyKey), isFalse);
      expect(
        () => tamperedPayload1.decrypt(convoyKey),
        throwsA(isA<DtnSecurityException>()),
      );

      // Tampered authTag.
      final tamperedPayload2 = DtnEncryptedPayload(
        ciphertext: payload.ciphertext,
        authTag: '00112233445566778899aabbccddeeff',
        iv: payload.iv,
        keyId: payload.keyId,
        plaintextLength: payload.plaintextLength,
      );

      expect(tamperedPayload2.verifyIntegrity(convoyKey), isFalse);
      expect(
        () => tamperedPayload2.decrypt(convoyKey),
        throwsA(isA<DtnSecurityException>()),
      );
    });

    test('serialization round-trip preserves RFC 9171 and RFC 9172 fields', () {
      final t0 = DateTime(2026, 10, 12, 10, 0, 0);
      final payload = DtnEncryptedPayload.encrypt(
        plaintext: '{"type":"HAZARD","obstacle":"landslide"}',
        secretKey: convoyKey,
      );

      final original = DtnBundle(
        bundleId: 'bundle-roundtrip-99',
        sourceRiderId: 'rider-lead',
        targetConvoyId: 'convoy-alpha',
        creationTimestamp: t0,
        lifetimeTtlSec: 1200,
        payloadType: DtnPayloadType.hazardWarning,
        encryptedPayload: payload,
        hopCount: 2,
        replicationBudget: 3,
        hopLimit: 6,
        priority: DtnBundlePriority.safety,
        routeHistory: const ['rider-lead', 'courier-1'],
      );

      final json = original.toJson();
      final reconstructed = DtnBundle.fromJson(json);

      expect(reconstructed.bundleId, equals(original.bundleId));
      expect(reconstructed.sourceRiderId, equals(original.sourceRiderId));
      expect(reconstructed.targetConvoyId, equals(original.targetConvoyId));
      expect(reconstructed.creationTimestamp, equals(original.creationTimestamp));
      expect(reconstructed.lifetimeTtlSec, equals(original.lifetimeTtlSec));
      expect(reconstructed.payloadType, equals(original.payloadType));
      expect(reconstructed.hopCount, equals(original.hopCount));
      expect(reconstructed.replicationBudget, equals(original.replicationBudget));
      expect(reconstructed.hopLimit, equals(original.hopLimit));
      expect(reconstructed.priority, equals(original.priority));
      expect(reconstructed.routeHistory, equals(original.routeHistory));
      expect(reconstructed.encryptedPayload.decrypt(convoyKey), equals('{"type":"HAZARD","obstacle":"landslide"}'));
    });
  });

  group('DtnRouter Store-Carry-Forward and Routing Policy', () {
    test('expired bundles are never ingested or forwarded', () {
      final t0 = DateTime(2026, 10, 12, 10, 0, 0);
      final nodeA = DtnRouter(riderId: 'node_a');
      final nodeB = DtnRouter(riderId: 'node_b');

      final payload = DtnEncryptedPayload.encrypt(
        plaintext: '{"msg":"expired_sos"}',
        secretKey: convoyKey,
      );

      final bundle = DtnBundle(
        bundleId: 'bundle-expired-test',
        sourceRiderId: 'node_a',
        targetConvoyId: 'convoy-alpha',
        creationTimestamp: t0,
        lifetimeTtlSec: 300, // 5 minutes
        payloadType: DtnPayloadType.sosEmergency,
        encryptedPayload: payload,
        replicationBudget: 4,
      );

      // Node A stores it at t0.
      expect(nodeA.storeLocalBundle(bundle, now: t0), isTrue);

      // Time jumps forward by 400 seconds (past 300s TTL).
      final tExpired = t0.add(const Duration(seconds: 400));

      // Node A attempts to forward to Node B after expiration.
      final forwardSuccess = nodeA.forwardToPeer(nodeB, bundle.bundleId, now: tExpired);
      expect(forwardSuccess, isFalse);

      // Node A local store purged the expired bundle.
      expect(nodeA.storedBundles.containsKey(bundle.bundleId), isFalse);

      // Node B never ingested the expired bundle.
      expect(nodeB.storedBundles.containsKey(bundle.bundleId), isFalse);

      // Direct offer of expired bundle is rejected by Node B.
      final directResult = nodeB.receiveBundle(bundle, fromNodeId: 'node_a', now: tExpired);
      expect(directResult.status, equals(DtnReceiveStatus.expired));
    });

    test('Spray-and-Wait replication budget decrement and forwarding limits', () {
      final t0 = DateTime(2026, 10, 12, 10, 0, 0);
      final nodeA = DtnRouter(riderId: 'node_a');
      final nodeB = DtnRouter(riderId: 'node_b');
      final nodeC = DtnRouter(riderId: 'node_c');
      final nodeD = DtnRouter(riderId: 'node_d');

      final payload = DtnEncryptedPayload.encrypt(
        plaintext: '{"type":"SOS"}',
        secretKey: convoyKey,
      );

      // Initial replication budget L = 4.
      final bundle = DtnBundle(
        bundleId: 'bundle-spray-wait-01',
        sourceRiderId: 'node_a',
        targetConvoyId: 'convoy-alpha',
        creationTimestamp: t0,
        lifetimeTtlSec: 1800,
        payloadType: DtnPayloadType.sosEmergency,
        encryptedPayload: payload,
        replicationBudget: 4,
      );

      nodeA.storeLocalBundle(bundle, now: t0);

      // Contact 1: Node A encounters Node B.
      // Binary Spray-and-Wait: A passes floor(4/2) = 2 to B, retains 4 - 2 = 2.
      final fwdB = nodeA.forwardToPeer(nodeB, bundle.bundleId, now: t0);
      expect(fwdB, isTrue);
      expect(nodeA.storedBundles[bundle.bundleId]!.replicationBudget, equals(2));
      expect(nodeB.storedBundles[bundle.bundleId]!.replicationBudget, equals(2));
      expect(nodeB.storedBundles[bundle.bundleId]!.hopCount, equals(1));

      // Contact 2: Node A encounters Node C.
      // A passes floor(2/2) = 1 to C, retains 2 - 1 = 1.
      final fwdC = nodeA.forwardToPeer(nodeC, bundle.bundleId, now: t0);
      expect(fwdC, isTrue);
      expect(nodeA.storedBundles[bundle.bundleId]!.replicationBudget, equals(1));
      expect(nodeC.storedBundles[bundle.bundleId]!.replicationBudget, equals(1));
      expect(nodeC.storedBundles[bundle.bundleId]!.hopCount, equals(1));

      // Contact 3: Node A encounters Node D (ordinary intermediate relay).
      // Node A is now in WAIT phase (budget == 1). It must NOT replicate to intermediate nodes.
      final fwdD = nodeA.forwardToPeer(nodeD, bundle.bundleId, isPeerGateway: false, now: t0);
      expect(fwdD, isFalse);
      expect(nodeA.storedBundles[bundle.bundleId]!.replicationBudget, equals(1));
      expect(nodeD.storedBundles.containsKey(bundle.bundleId), isFalse);

      // Verify replication budget never underflows below 0.
      expect(nodeA.storedBundles[bundle.bundleId]!.replicationBudget, greaterThanOrEqualTo(0));
    });

    test('Wait phase permits direct delivery to internet gateway or destination', () {
      final t0 = DateTime(2026, 10, 12, 10, 0, 0);
      final nodeA = DtnRouter(riderId: 'node_a');
      final gatewayNode = DtnRouter(riderId: 'gateway_e');

      final payload = DtnEncryptedPayload.encrypt(
        plaintext: '{"type":"SOS"}',
        secretKey: convoyKey,
      );

      // Bundle with budget = 1 (already in wait phase).
      final bundle = DtnBundle(
        bundleId: 'bundle-wait-phase-direct',
        sourceRiderId: 'node_a',
        targetConvoyId: 'convoy-alpha',
        creationTimestamp: t0,
        lifetimeTtlSec: 1800,
        payloadType: DtnPayloadType.sosEmergency,
        encryptedPayload: payload,
        replicationBudget: 1,
      );

      nodeA.storeLocalBundle(bundle, now: t0);

      // In Wait phase, forwarding to gateway node is permitted.
      final forwardedToGateway = nodeA.forwardToPeer(
        gatewayNode,
        bundle.bundleId,
        isPeerGateway: true,
        now: t0,
      );
      expect(forwardedToGateway, isTrue);
      expect(gatewayNode.storedBundles.containsKey(bundle.bundleId), isTrue);
      expect(nodeA.storedBundles[bundle.bundleId]!.replicationBudget, equals(0));
    });

    test('duplicate suppression prevents forwarding storms and redundant ingest', () {
      final t0 = DateTime(2026, 10, 12, 10, 0, 0);
      final nodeA = DtnRouter(riderId: 'node_a');
      final nodeB = DtnRouter(riderId: 'node_b');
      final nodeC = DtnRouter(riderId: 'node_c');

      final payload = DtnEncryptedPayload.encrypt(
        plaintext: '{"msg":"storm_prevention"}',
        secretKey: convoyKey,
      );

      final bundle = DtnBundle(
        bundleId: 'bundle-dedupe-01',
        sourceRiderId: 'node_a',
        targetConvoyId: 'convoy-alpha',
        creationTimestamp: t0,
        lifetimeTtlSec: 1800,
        payloadType: DtnPayloadType.sosEmergency,
        encryptedPayload: payload,
        replicationBudget: 4,
      );

      nodeA.storeLocalBundle(bundle, now: t0);

      // A forwards to B.
      expect(nodeA.forwardToPeer(nodeB, bundle.bundleId, now: t0), isTrue);

      // A tries to forward the same bundle to B again: rejected by sender tracking.
      expect(nodeA.forwardToPeer(nodeB, bundle.bundleId, now: t0), isFalse);

      // A forwards copy to C.
      expect(nodeA.forwardToPeer(nodeC, bundle.bundleId, now: t0), isTrue);

      // C later encounters B and offers the same bundle.
      // B already has this bundle in seenBundleIds; receive is rejected as duplicate.
      final duplicateReceive = nodeB.receiveBundle(
        nodeC.storedBundles[bundle.bundleId]!,
        fromNodeId: 'node_c',
        now: t0,
      );
      expect(duplicateReceive.status, equals(DtnReceiveStatus.duplicate));
    });

    test('loop detection prevents circular relaying A -> B -> C -> A', () {
      final t0 = DateTime(2026, 10, 12, 10, 0, 0);
      final nodeA = DtnRouter(riderId: 'node_a');
      final nodeB = DtnRouter(riderId: 'node_b');
      final nodeC = DtnRouter(riderId: 'node_c');

      final payload = DtnEncryptedPayload.encrypt(
        plaintext: '{"type":"SOS"}',
        secretKey: convoyKey,
      );

      final bundle = DtnBundle(
        bundleId: 'bundle-loop-01',
        sourceRiderId: 'node_a',
        targetConvoyId: 'convoy-alpha',
        creationTimestamp: t0,
        lifetimeTtlSec: 1800,
        payloadType: DtnPayloadType.sosEmergency,
        encryptedPayload: payload,
        replicationBudget: 4,
      );

      nodeA.storeLocalBundle(bundle, now: t0);

      // Hop 1: A -> B.
      expect(nodeA.forwardToPeer(nodeB, bundle.bundleId, now: t0), isTrue);

      // Hop 2: B -> C.
      expect(nodeB.forwardToPeer(nodeC, bundle.bundleId, now: t0), isTrue);

      // Check route history accumulated correctly.
      final bundleAtC = nodeC.storedBundles[bundle.bundleId]!;
      expect(bundleAtC.routeHistory, equals(['node_a', 'node_b']));

      // Attempt Hop 3: C tries to forward back to A.
      // Pre-forward check detects targetPeerId is sourceRiderId and in routeHistory.
      final forwardBackDecision = nodeC.prepareForward(
        bundleId: bundle.bundleId,
        targetPeerId: 'node_a',
        now: t0,
      );
      expect(forwardBackDecision.status, equals(DtnForwardStatus.loopDetected));

      // Direct receive call on Node A also catches loop detection.
      final receiveOnA = nodeA.receiveBundle(bundleAtC, fromNodeId: 'node_c', now: t0);
      expect(
        receiveOnA.status == DtnReceiveStatus.loopDetected ||
            receiveOnA.status == DtnReceiveStatus.duplicate,
        isTrue,
      );
    });

    test('hop limit prevents indefinite bundle circulation', () {
      final t0 = DateTime(2026, 10, 12, 10, 0, 0);
      final nodeA = DtnRouter(riderId: 'node_a');
      final nodeB = DtnRouter(riderId: 'node_b');

      final payload = DtnEncryptedPayload.encrypt(
        plaintext: '{"type":"SOS"}',
        secretKey: convoyKey,
      );

      // Bundle already at hop limit (hopCount 8, hopLimit 8).
      final maxHopBundle = DtnBundle(
        bundleId: 'bundle-hop-limit',
        sourceRiderId: 'origin_node',
        targetConvoyId: 'convoy-alpha',
        creationTimestamp: t0,
        lifetimeTtlSec: 1800,
        payloadType: DtnPayloadType.sosEmergency,
        encryptedPayload: payload,
        hopCount: 8,
        hopLimit: 8,
        replicationBudget: 2,
      );

      final receiveResult = nodeB.receiveBundle(maxHopBundle, fromNodeId: nodeA.riderId, now: t0);
      expect(receiveResult.status, equals(DtnReceiveStatus.hopLimitExceeded));
      expect(nodeB.storedBundles.containsKey(maxHopBundle.bundleId), isFalse);
    });

    test('relay disabled node rejects bundle forwarding and ingest', () {
      final t0 = DateTime(2026, 10, 12, 10, 0, 0);
      final optOutNode = DtnRouter(riderId: 'node_opt_out', isRelayEnabled: false);

      final payload = DtnEncryptedPayload.encrypt(
        plaintext: '{"type":"SOS"}',
        secretKey: convoyKey,
      );

      final bundle = DtnBundle(
        bundleId: 'bundle-opt-out',
        sourceRiderId: 'node_a',
        targetConvoyId: 'convoy-alpha',
        creationTimestamp: t0,
        lifetimeTtlSec: 1800,
        payloadType: DtnPayloadType.sosEmergency,
        encryptedPayload: payload,
      );

      final res = optOutNode.receiveBundle(bundle, fromNodeId: 'node_a', now: t0);
      expect(res.status, equals(DtnReceiveStatus.relayDisabled));
      expect(optOutNode.storedBundles.isEmpty, isTrue);
    });

    test('storage capacity eviction preserves emergency over normal telemetry', () {
      final t0 = DateTime(2026, 10, 12, 10, 0, 0);
      final node = DtnRouter(riderId: 'node_constrained', maxStorageCapacity: 2);

      final payload = DtnEncryptedPayload.encrypt(
        plaintext: '{"telemetry":1}',
        secretKey: convoyKey,
      );

      final normalBundle1 = DtnBundle(
        bundleId: 'bundle-normal-1',
        sourceRiderId: 'node_x',
        targetConvoyId: 'convoy-alpha',
        creationTimestamp: t0,
        lifetimeTtlSec: 1800,
        payloadType: DtnPayloadType.telemetry,
        encryptedPayload: payload,
        priority: DtnBundlePriority.normal,
      );

      final normalBundle2 = DtnBundle(
        bundleId: 'bundle-normal-2',
        sourceRiderId: 'node_y',
        targetConvoyId: 'convoy-alpha',
        creationTimestamp: t0,
        lifetimeTtlSec: 1800,
        payloadType: DtnPayloadType.telemetry,
        encryptedPayload: payload,
        priority: DtnBundlePriority.normal,
      );

      final emergencyBundle = DtnBundle(
        bundleId: 'bundle-emergency-p0',
        sourceRiderId: 'node_z',
        targetConvoyId: 'convoy-alpha',
        creationTimestamp: t0,
        lifetimeTtlSec: 1800,
        payloadType: DtnPayloadType.sosEmergency,
        encryptedPayload: payload,
        priority: DtnBundlePriority.emergency,
      );

      expect(node.receiveBundle(normalBundle1, fromNodeId: 'node_x', now: t0).isAccepted, isTrue);
      expect(node.receiveBundle(normalBundle2, fromNodeId: 'node_y', now: t0).isAccepted, isTrue);
      expect(node.storedBundles.length, equals(2));

      // Adding emergency bundle evicts one normal bundle to stay within capacity.
      final emergRes = node.receiveBundle(emergencyBundle, fromNodeId: 'node_z', now: t0);
      expect(emergRes.isAccepted, isTrue);
      expect(node.storedBundles.length, equals(2));
      expect(node.storedBundles.containsKey('bundle-emergency-p0'), isTrue);
    });
  });

  group('Gateway Rider Delivery, Cloud Ingestion, and Opportunistic ACKs', () {
    test('end-to-end multi-hop simulation: A -> Courier C -> Relay D -> Gateway E -> Cloud', () async {
      final t0 = DateTime(2026, 10, 12, 10, 0, 0);

      // Node Setup:
      // Rider A: Victim, no network.
      // Courier C: Unrelated rider, offline.
      // Relay D: Group relay, offline.
      // Gateway E: Rider who later hits highway cell tower (online).
      final riderA = DtnRouter(riderId: 'rider_a');
      final courierC = DtnRouter(riderId: 'courier_c');
      final relayD = DtnRouter(riderId: 'relay_d');
      final gatewayE = DtnRouter(riderId: 'gateway_e');

      final cloudGateway = InMemoryDtnCloudGateway(convoySecretKey: convoyKey);
      final uploaderE = DtnGatewayUploader(
        router: gatewayE,
        cloudGateway: cloudGateway,
        hasInternet: false, // Initially in no-network canyon
      );

      // Step 1: Rider A creates encrypted SOS bundle (t = 0s).
      const emergencyPlaintext = '{"incident":"CRASH","lat":13.0827,"lng":80.2707,"urgency":"P0"}';
      final emergencyPayload = DtnEncryptedPayload.encrypt(
        plaintext: emergencyPlaintext,
        secretKey: convoyKey,
        keyId: 'convoy-omega',
      );

      final sosBundle = DtnBundle(
        bundleId: 'bundle-emergency-multi-hop',
        sourceRiderId: 'rider_a',
        targetConvoyId: 'convoy-omega',
        creationTimestamp: t0,
        lifetimeTtlSec: 1800, // 30 minutes
        payloadType: DtnPayloadType.sosEmergency,
        encryptedPayload: emergencyPayload,
        replicationBudget: 4,
      );

      riderA.storeLocalBundle(sosBundle, now: t0);
      expect(riderA.storedBundles.containsKey(sosBundle.bundleId), isTrue);

      // Step 2: Contact opportunity 1 (t = 30s): Rider A encounters Courier C.
      final tContact1 = t0.add(const Duration(seconds: 30));
      final hop1 = riderA.forwardToPeer(courierC, sosBundle.bundleId, now: tContact1);
      expect(hop1, isTrue);
      expect(courierC.storedBundles.containsKey(sosBundle.bundleId), isTrue);

      // Verify Courier C cannot read emergency content.
      expect(
        () => courierC.storedBundles[sosBundle.bundleId]!.encryptedPayload.decrypt(wrongKey),
        throwsA(isA<DtnSecurityException>()),
      );

      // Step 3: Courier C travels, separates from A, meets Relay D (t = 4m).
      final tContact2 = t0.add(const Duration(minutes: 4));
      final hop2 = courierC.forwardToPeer(relayD, sosBundle.bundleId, now: tContact2);
      expect(hop2, isTrue);
      expect(relayD.storedBundles.containsKey(sosBundle.bundleId), isTrue);

      // Step 4: Relay D meets Gateway Rider E (t = 8m).
      final tContact3 = t0.add(const Duration(minutes: 8));
      final hop3 = relayD.forwardToPeer(
        gatewayE,
        sosBundle.bundleId,
        isPeerGateway: true,
        now: tContact3,
      );
      expect(hop3, isTrue);
      expect(gatewayE.storedBundles.containsKey(sosBundle.bundleId), isTrue);

      // Step 5: Gateway E is currently offline; upload queue yields zero.
      var acks = await uploaderE.uploadPendingQueue(now: tContact3);
      expect(acks.isEmpty, isTrue);
      expect(cloudGateway.deliveredBundles.isEmpty, isTrue);

      // Step 6: Gateway E exits tunnel into 4G cell coverage (t = 8m 15s).
      final tOnline = tContact3.add(const Duration(seconds: 15));
      uploaderE.setConnectivity(true);

      acks = await uploaderE.uploadPendingQueue(now: tOnline);
      expect(acks.length, equals(1));
      expect(acks.first.bundleId, equals(sosBundle.bundleId));
      expect(acks.first.status, equals(DtnDeliveryStatus.cloudAccepted));

      // Cloud verification invariants.
      expect(cloudGateway.deliveredBundles.containsKey(sosBundle.bundleId), isTrue);
      expect(cloudGateway.canonicalIncidentIds.length, equals(1));
      expect(uploaderE.syncedAcks.length, equals(1));

      // Step 7: Opportunistic ACK propagation back through the mesh.
      // Gateway E later encounters Relay D.
      uploaderE.propagateAcksToPeer(relayD);
      expect(relayD.ackStore.containsKey(sosBundle.bundleId), isTrue);
      expect(relayD.storedBundles[sosBundle.bundleId]!.isDelivered, isTrue);

      // Relay D encounters Courier C.
      for (final ack in relayD.ackStore.values) {
        courierC.processAck(ack);
      }
      expect(courierC.ackStore.containsKey(sosBundle.bundleId), isTrue);
      expect(courierC.storedBundles[sosBundle.bundleId]!.isDelivered, isTrue);

      // Courier C encounters original Rider A.
      for (final ack in courierC.ackStore.values) {
        riderA.processAck(ack);
      }
      expect(riderA.ackStore.containsKey(sosBundle.bundleId), isTrue);
      expect(riderA.storedBundles[sosBundle.bundleId]!.isDelivered, isTrue);
    });

    test('cloud gateway deduplication: multiple gateways deliver same bundle to one canonical incident', () async {
      final t0 = DateTime(2026, 10, 12, 10, 0, 0);
      final cloudGateway = InMemoryDtnCloudGateway(convoySecretKey: convoyKey);

      final payload = DtnEncryptedPayload.encrypt(
        plaintext: '{"type":"SOS","rider":"rider_alice"}',
        secretKey: convoyKey,
      );

      final bundle = DtnBundle(
        bundleId: 'bundle-duplicate-gateway-delivery',
        sourceRiderId: 'rider_alice',
        targetConvoyId: 'convoy-alpha',
        creationTimestamp: t0,
        lifetimeTtlSec: 1800,
        payloadType: DtnPayloadType.sosEmergency,
        encryptedPayload: payload,
      );

      // Gateway 1 uploads bundle.
      final res1 = await cloudGateway.uploadBundle(bundle, now: t0);
      expect(res1.status, equals(DtnUploadStatus.accepted));
      expect(cloudGateway.deliveredBundles.length, equals(1));
      expect(cloudGateway.canonicalIncidentIds.length, equals(1));

      // Gateway 2 carries duplicate copy and uploads at t = 2m.
      final tLater = t0.add(const Duration(minutes: 2));
      final res2 = await cloudGateway.uploadBundle(bundle, now: tLater);
      expect(res2.status, equals(DtnUploadStatus.duplicate));
      expect(res2.ack, isNotNull);
      expect(res2.ack!.bundleId, equals(bundle.bundleId));

      // Cloud still has exactly 1 canonical incident (no duplicate storms).
      expect(cloudGateway.deliveredBundles.length, equals(1));
      expect(cloudGateway.canonicalIncidentIds.length, equals(1));
    });

    test('cloud gateway rejects expired bundle upon upload', () async {
      final t0 = DateTime(2026, 10, 12, 10, 0, 0);
      final cloudGateway = InMemoryDtnCloudGateway(convoySecretKey: convoyKey);

      final payload = DtnEncryptedPayload.encrypt(
        plaintext: '{"type":"SOS"}',
        secretKey: convoyKey,
      );

      final bundle = DtnBundle(
        bundleId: 'bundle-late-gateway',
        sourceRiderId: 'rider_bob',
        targetConvoyId: 'convoy-alpha',
        creationTimestamp: t0,
        lifetimeTtlSec: 600, // 10 minutes
        payloadType: DtnPayloadType.sosEmergency,
        encryptedPayload: payload,
      );

      // Upload arrives at 10 minutes 1 second (expired).
      final tLate = t0.add(const Duration(seconds: 601));
      final res = await cloudGateway.uploadBundle(bundle, now: tLate);

      expect(res.status, equals(DtnUploadStatus.expired));
      expect(cloudGateway.deliveredBundles.isEmpty, isTrue);
      expect(cloudGateway.canonicalIncidentIds.isEmpty, isTrue);
      expect(cloudGateway.expiredBundleIds.contains(bundle.bundleId), isTrue);
    });

    test('cloud gateway rejects tampered bundle and records security alert', () async {
      final t0 = DateTime(2026, 10, 12, 10, 0, 0);
      final cloudGateway = InMemoryDtnCloudGateway(convoySecretKey: convoyKey);

      final payload = DtnEncryptedPayload.encrypt(
        plaintext: '{"type":"SOS","location":"Highway 44"}',
        secretKey: convoyKey,
      );

      // Rogue relay modifies the ciphertext before gateway upload.
      final rogueCiphertext = '${payload.ciphertext}00';
      final tamperedPayload = DtnEncryptedPayload(
        ciphertext: rogueCiphertext,
        authTag: payload.authTag,
        iv: payload.iv,
        keyId: payload.keyId,
        plaintextLength: payload.plaintextLength,
      );

      final tamperedBundle = DtnBundle(
        bundleId: 'bundle-tampered-alert',
        sourceRiderId: 'rider_charlie',
        targetConvoyId: 'convoy-alpha',
        creationTimestamp: t0,
        lifetimeTtlSec: 1800,
        payloadType: DtnPayloadType.sosEmergency,
        encryptedPayload: tamperedPayload,
      );

      final res = await cloudGateway.uploadBundle(tamperedBundle, now: t0);
      expect(res.status, equals(DtnUploadStatus.tamperDetected));
      expect(cloudGateway.deliveredBundles.isEmpty, isTrue);
      expect(cloudGateway.tamperedBundleIds.contains(tamperedBundle.bundleId), isTrue);
    });

    test('gateway uploader retries on network failure without dropping bundle', () async {
      final t0 = DateTime(2026, 10, 12, 10, 0, 0);
      final gatewayRouter = DtnRouter(riderId: 'gateway_retry_node');
      final cloudGateway = InMemoryDtnCloudGateway(convoySecretKey: convoyKey);

      final payload = DtnEncryptedPayload.encrypt(
        plaintext: '{"type":"SOS"}',
        secretKey: convoyKey,
      );

      final bundle = DtnBundle(
        bundleId: 'bundle-retry-test',
        sourceRiderId: 'rider_alice',
        targetConvoyId: 'convoy-alpha',
        creationTimestamp: t0,
        lifetimeTtlSec: 1800,
        payloadType: DtnPayloadType.sosEmergency,
        encryptedPayload: payload,
      );

      gatewayRouter.storeLocalBundle(bundle, now: t0);

      final uploader = DtnGatewayUploader(
        router: gatewayRouter,
        cloudGateway: cloudGateway,
        hasInternet: true,
      );

      // Simulate transient network fault (e.g. packet drop, DNS outage).
      cloudGateway.simulateNetworkFailure = true;
      final failedAcks = await uploader.uploadPendingQueue(now: t0);
      expect(failedAcks.isEmpty, isTrue);
      // Bundle remains safely in store for retry.
      expect(gatewayRouter.storedBundles.containsKey(bundle.bundleId), isTrue);

      // Connectivity heals.
      cloudGateway.simulateNetworkFailure = false;
      final retryAcks = await uploader.uploadPendingQueue(now: t0);
      expect(retryAcks.length, equals(1));
      expect(gatewayRouter.storedBundles[bundle.bundleId]!.isDelivered, isTrue);
    });
  });
}
