import 'dart:async';
import 'dtn_bundle.dart';
import 'dtn_router.dart';

/// Status outcomes when attempting cloud upload from a gateway node.
enum DtnUploadStatus {
  accepted,
  duplicate,
  expired,
  tamperDetected,
  networkError,
}

/// Detailed result of cloud bundle upload.
class DtnUploadResult {
  final DtnUploadStatus status;
  final String bundleId;
  final DtnAck? ack;
  final String? errorMessage;
  final String? decryptedPayload;

  const DtnUploadResult({
    required this.status,
    required this.bundleId,
    this.ack,
    this.errorMessage,
    this.decryptedPayload,
  });

  bool get isSuccessful =>
      status == DtnUploadStatus.accepted || status == DtnUploadStatus.duplicate;

  factory DtnUploadResult.accepted({
    required String bundleId,
    required DtnAck ack,
    String? decryptedPayload,
  }) =>
      DtnUploadResult(
        status: DtnUploadStatus.accepted,
        bundleId: bundleId,
        ack: ack,
        decryptedPayload: decryptedPayload,
      );

  factory DtnUploadResult.duplicate({
    required String bundleId,
    required DtnAck existingAck,
  }) =>
      DtnUploadResult(
        status: DtnUploadStatus.duplicate,
        bundleId: bundleId,
        ack: existingAck,
        errorMessage: 'Bundle already ingested; duplicate transport attempt suppressed',
      );

  factory DtnUploadResult.expired(String bundleId) => DtnUploadResult(
        status: DtnUploadStatus.expired,
        bundleId: bundleId,
        errorMessage: 'Bundle expired prior to cloud arrival; dropped from active delivery',
      );

  factory DtnUploadResult.tamperDetected(String bundleId) => DtnUploadResult(
        status: DtnUploadStatus.tamperDetected,
        bundleId: bundleId,
        errorMessage:
            'RFC 9172 integrity verification failed; ciphertext or authTag modified in transit',
      );

  factory DtnUploadResult.networkError(String bundleId, String error) =>
      DtnUploadResult(
        status: DtnUploadStatus.networkError,
        bundleId: bundleId,
        errorMessage: error,
      );
}

/// Contract for DTN cloud gateway ingestion service.
abstract class DtnCloudGateway {
  Future<DtnUploadResult> uploadBundle(DtnBundle bundle, {DateTime? now});
}

/// In-memory reference implementation of cloud gateway verifying RFC 9171/9172
/// rules: duplicate suppression to single canonical incident, TTL expiration,
/// and authenticated payload integrity verification.
class InMemoryDtnCloudGateway implements DtnCloudGateway {
  final String convoySecretKey;
  final Map<String, DtnBundle> deliveredBundles = <String, DtnBundle>{};
  final Map<String, DtnAck> acks = <String, DtnAck>{};
  final List<String> canonicalIncidentIds = <String>[];
  final List<String> tamperedBundleIds = <String>[];
  final List<String> expiredBundleIds = <String>[];
  bool simulateNetworkFailure = false;

  InMemoryDtnCloudGateway({
    required this.convoySecretKey,
  });

  @override
  Future<DtnUploadResult> uploadBundle(DtnBundle bundle, {DateTime? now}) async {
    if (simulateNetworkFailure) {
      return DtnUploadResult.networkError(
        bundle.bundleId,
        'Simulated transient cellular connection timeout',
      );
    }

    final bundleId = bundle.bundleId;

    // RFC 9171 invariant: expired bundles are never delivered as active emergencies.
    if (bundle.isExpired(now)) {
      expiredBundleIds.add(bundleId);
      return DtnUploadResult.expired(bundleId);
    }

    // Deduplication: multiple transport paths yield one canonical incident.
    if (deliveredBundles.containsKey(bundleId)) {
      final existingAck = acks[bundleId]!;
      return DtnUploadResult.duplicate(
        bundleId: bundleId,
        existingAck: existingAck,
      );
    }

    // RFC 9172 Block Integrity Block check: untrusted couriers cannot tamper.
    final isValid = bundle.encryptedPayload.verifyIntegrity(convoySecretKey);
    if (!isValid) {
      tamperedBundleIds.add(bundleId);
      return DtnUploadResult.tamperDetected(bundleId);
    }

    // Decrypt emergency payload using authorised convoy key.
    final decrypted = bundle.encryptedPayload.decrypt(convoySecretKey);
    final incidentId = 'incident_${bundle.sourceRiderId}_${bundleId.substring(0, 8)}';
    canonicalIncidentIds.add(incidentId);
    deliveredBundles[bundleId] = bundle;

    final ack = DtnAck(
      bundleId: bundleId,
      sourceNodeId: 'cloud_gateway_central',
      acknowledgedAt: now ?? DateTime.now(),
      status: DtnDeliveryStatus.cloudAccepted,
      cloudIncidentId: incidentId,
    );
    acks[bundleId] = ack;

    return DtnUploadResult.accepted(
      bundleId: bundleId,
      ack: ack,
      decryptedPayload: decrypted,
    );
  }
}

/// Gateway manager running on an edge device (rider phone).
/// When network connectivity is established, drains pending bundles from the
/// local router store, uploads them in priority order, and handles ACK propagation.
class DtnGatewayUploader {
  final DtnRouter router;
  final DtnCloudGateway cloudGateway;
  bool hasInternet;

  final List<DtnAck> _syncedAcks = <DtnAck>[];

  DtnGatewayUploader({
    required this.router,
    required this.cloudGateway,
    this.hasInternet = false,
  });

  /// Read-only snapshot of delivery acknowledgements generated or received.
  List<DtnAck> get syncedAcks => List.unmodifiable(_syncedAcks);

  /// Updates current internet connectivity status of gateway rider.
  void setConnectivity(bool online) {
    hasInternet = online;
  }

  /// Drains pending unexpired bundles from router and uploads to cloud.
  Future<List<DtnAck>> uploadPendingQueue({DateTime? now}) async {
    if (!hasInternet) {
      return const <DtnAck>[];
    }

    final newlyReceivedAcks = <DtnAck>[];
    final pending = router.getPendingBundles(now: now);

    for (final bundle in pending) {
      final result = await cloudGateway.uploadBundle(bundle, now: now);

      if (result.isSuccessful && result.ack != null) {
        final ack = result.ack!;
        router.processAck(ack);
        if (!_syncedAcks.any((a) => a.bundleId == ack.bundleId)) {
          _syncedAcks.add(ack);
        }
        newlyReceivedAcks.add(ack);
      } else if (result.status == DtnUploadStatus.expired) {
        router.purgeExpired(now);
      } else if (result.status == DtnUploadStatus.tamperDetected) {
        // Drop tampered bundle from local store to prevent further circulation.
        router.purgeExpired(now);
      }
    }

    return newlyReceivedAcks;
  }

  /// Opportunistically propagates delivery acknowledgements to an encountering peer.
  /// Intermediate relays learn the bundle was delivered and stop active forwarding.
  void propagateAcksToPeer(DtnRouter peerRouter) {
    for (final ack in router.ackStore.values) {
      peerRouter.processAck(ack);
    }
    for (final ack in _syncedAcks) {
      peerRouter.processAck(ack);
    }
  }
}
