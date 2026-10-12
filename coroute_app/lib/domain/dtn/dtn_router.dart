import 'dtn_bundle.dart';

/// Result status when receiving a bundle from an encountering node.
enum DtnReceiveStatus {
  accepted,
  duplicate,
  expired,
  hopLimitExceeded,
  loopDetected,
  relayDisabled,
  storageFull,
  alreadyDelivered,
}

/// Detailed result of bundle ingestion.
class DtnReceiveResult {
  final DtnReceiveStatus status;
  final String bundleId;
  final String message;

  const DtnReceiveResult({
    required this.status,
    required this.bundleId,
    required this.message,
  });

  bool get isAccepted => status == DtnReceiveStatus.accepted;
}

/// Result status when attempting to forward a bundle to an encountering node.
enum DtnForwardStatus {
  allowed,
  expired,
  budgetExhausted,
  waitPhaseRestricted,
  alreadyTransferredToPeer,
  loopDetected,
  hopLimitExceeded,
  bundleNotFound,
  peerRejected,
}

/// Detailed result of forward preparation.
class DtnForwardResult {
  final DtnForwardStatus status;
  final String bundleId;
  final String targetPeerId;
  final DtnBundle? outgoingBundle;
  final String message;

  const DtnForwardResult({
    required this.status,
    required this.bundleId,
    required this.targetPeerId,
    this.outgoingBundle,
    required this.message,
  });

  bool get isAllowed => status == DtnForwardStatus.allowed;
}

/// Store-Carry-Forward router implementing Spray-and-Wait DTN routing policy
/// with bounded replication budget, duplicate suppression, and loop detection.
class DtnRouter {
  final String riderId;
  final bool isRelayEnabled;
  final int maxStorageCapacity;

  final Map<String, DtnBundle> _store = <String, DtnBundle>{};
  final Set<String> _seenBundleIds = <String>{};
  final Map<String, Set<String>> _forwardedPeers = <String, Set<String>>{};
  final Map<String, DtnAck> _ackStore = <String, DtnAck>{};

  DtnRouter({
    required this.riderId,
    this.isRelayEnabled = true,
    this.maxStorageCapacity = 100,
  });

  /// Read-only snapshot of current stored bundles.
  Map<String, DtnBundle> get storedBundles => Map.unmodifiable(_store);

  /// Read-only snapshot of seen bundle identifiers for deduplication auditing.
  Set<String> get seenBundleIds => Set.unmodifiable(_seenBundleIds);

  /// Read-only snapshot of processed delivery acknowledgements.
  Map<String, DtnAck> get ackStore => Map.unmodifiable(_ackStore);

  /// Stores a locally generated bundle (e.g. SOS from this rider).
  bool storeLocalBundle(DtnBundle bundle, {DateTime? now}) {
    if (bundle.isExpired(now)) {
      return false;
    }
    _seenBundleIds.add(bundle.bundleId);
    _store[bundle.bundleId] = bundle;
    return true;
  }

  /// Ingests a bundle offered by an encountering peer node.
  DtnReceiveResult receiveBundle(
    DtnBundle bundle, {
    required String fromNodeId,
    DateTime? now,
  }) {
    final bundleId = bundle.bundleId;

    if (!isRelayEnabled) {
      return DtnReceiveResult(
        status: DtnReceiveStatus.relayDisabled,
        bundleId: bundleId,
        message: 'Relay consent disabled on node $riderId',
      );
    }

    if (bundle.isExpired(now)) {
      return DtnReceiveResult(
        status: DtnReceiveStatus.expired,
        bundleId: bundleId,
        message: 'Bundle $bundleId expired; dropped immediately',
      );
    }

    // Duplicate suppression: reject bundles already seen.
    if (_seenBundleIds.contains(bundleId)) {
      return DtnReceiveResult(
        status: DtnReceiveStatus.duplicate,
        bundleId: bundleId,
        message: 'Duplicate bundle $bundleId rejected',
      );
    }

    // Delivery ACK already present: suppress redundant bundle.
    if (_ackStore.containsKey(bundleId)) {
      return DtnReceiveResult(
        status: DtnReceiveStatus.alreadyDelivered,
        bundleId: bundleId,
        message: 'Bundle $bundleId already delivered via ACK',
      );
    }

    // Loop detection: bundle originated here or has visited this node.
    if (bundle.sourceRiderId == riderId || bundle.routeHistory.contains(riderId)) {
      return DtnReceiveResult(
        status: DtnReceiveStatus.loopDetected,
        bundleId: bundleId,
        message: 'Routing loop detected for bundle $bundleId on node $riderId',
      );
    }

    // Hop limit enforcement (RFC 9171 Hop Count).
    if (bundle.hopCount >= bundle.hopLimit) {
      return DtnReceiveResult(
        status: DtnReceiveStatus.hopLimitExceeded,
        bundleId: bundleId,
        message: 'Hop limit (${bundle.hopLimit}) exceeded for bundle $bundleId',
      );
    }

    // Storage capacity check and eviction if full.
    if (_store.length >= maxStorageCapacity) {
      purgeExpired(now);
      if (_store.length >= maxStorageCapacity) {
        final evicted = _evictLowerPriority(bundle.priority);
        if (!evicted) {
          return DtnReceiveResult(
            status: DtnReceiveStatus.storageFull,
            bundleId: bundleId,
            message: 'Storage full on node $riderId; bundle rejected',
          );
        }
      }
    }

    _seenBundleIds.add(bundleId);
    _store[bundleId] = bundle;
    _forwardedPeers.putIfAbsent(bundleId, () => <String>{}).add(fromNodeId);

    return DtnReceiveResult(
      status: DtnReceiveStatus.accepted,
      bundleId: bundleId,
      message: 'Bundle $bundleId accepted on node $riderId',
    );
  }

  /// Prepares forward transmission under Spray-and-Wait replication rules.
  DtnForwardResult prepareForward({
    required String bundleId,
    required String targetPeerId,
    bool isTargetGateway = false,
    bool isTargetDestination = false,
    DateTime? now,
  }) {
    final bundle = _store[bundleId];
    if (bundle == null) {
      return DtnForwardResult(
        status: DtnForwardStatus.bundleNotFound,
        bundleId: bundleId,
        targetPeerId: targetPeerId,
        message: 'Bundle $bundleId not found in local store',
      );
    }

    // Lifetime expiration: purge expired bundles, never forward.
    if (bundle.isExpired(now)) {
      _store.remove(bundleId);
      return DtnForwardResult(
        status: DtnForwardStatus.expired,
        bundleId: bundleId,
        targetPeerId: targetPeerId,
        message: 'Bundle $bundleId expired; dropped and not forwarded',
      );
    }

    if (bundle.isDelivered) {
      return DtnForwardResult(
        status: DtnForwardStatus.alreadyTransferredToPeer,
        bundleId: bundleId,
        targetPeerId: targetPeerId,
        message: 'Bundle $bundleId already delivered; forwarding suppressed',
      );
    }

    // Loop detection: do not forward back to originator or nodes in route history.
    if (targetPeerId == bundle.sourceRiderId ||
        bundle.routeHistory.contains(targetPeerId)) {
      return DtnForwardResult(
        status: DtnForwardStatus.loopDetected,
        bundleId: bundleId,
        targetPeerId: targetPeerId,
        message: 'Loop detected: peer $targetPeerId already in route history',
      );
    }

    // Duplicate suppression: do not offer same bundle to same peer twice.
    if (_forwardedPeers[bundleId]?.contains(targetPeerId) == true) {
      return DtnForwardResult(
        status: DtnForwardStatus.alreadyTransferredToPeer,
        bundleId: bundleId,
        targetPeerId: targetPeerId,
        message: 'Bundle $bundleId already forwarded to peer $targetPeerId',
      );
    }

    // Hop count boundary check.
    if (bundle.hopCount >= bundle.hopLimit) {
      return DtnForwardResult(
        status: DtnForwardStatus.hopLimitExceeded,
        bundleId: bundleId,
        targetPeerId: targetPeerId,
        message: 'Hop limit reached; forwarding blocked',
      );
    }

    // Spray-and-Wait replication budget logic:
    // If budget <= 0: budget exhausted.
    // If budget == 1: WAIT phase. Node only forwards to destination or gateway!
    // If budget > 1: SPRAY phase. Partition budget using binary spray-and-wait.
    final budget = bundle.replicationBudget;
    if (budget <= 0) {
      return DtnForwardResult(
        status: DtnForwardStatus.budgetExhausted,
        bundleId: bundleId,
        targetPeerId: targetPeerId,
        message: 'Replication budget exhausted for bundle $bundleId',
      );
    }

    if (budget == 1) {
      // In Wait phase, intermediate opportunistic replication is suppressed.
      if (!isTargetGateway && !isTargetDestination) {
        return DtnForwardResult(
          status: DtnForwardStatus.waitPhaseRestricted,
          bundleId: bundleId,
          targetPeerId: targetPeerId,
          message:
              'Wait phase active (budget=1); forwarding restricted to gateway or destination',
        );
      }
    }

    final int transferredBudget;
    final int retainedBudget;

    if (budget > 1) {
      // Binary Spray-and-Wait: give half to peer, retain half locally.
      transferredBudget = budget ~/ 2;
      retainedBudget = budget - transferredBudget;
    } else {
      // Budget == 1: transfer custody to destination / gateway.
      transferredBudget = 1;
      retainedBudget = 0;
    }

    final outgoing = bundle.copyWith(
      hopCount: bundle.hopCount + 1,
      replicationBudget: transferredBudget,
      routeHistory: <String>[...bundle.routeHistory, riderId],
    );

    return DtnForwardResult(
      status: DtnForwardStatus.allowed,
      bundleId: bundleId,
      targetPeerId: targetPeerId,
      outgoingBundle: outgoing,
      message:
          'Forward allowed: transferredBudget=$transferredBudget, retainedBudget=$retainedBudget',
    );
  }

  /// Transfers a bundle to an encountering peer router deterministically.
  bool forwardToPeer(
    DtnRouter peerRouter,
    String bundleId, {
    bool isPeerGateway = false,
    bool isPeerDestination = false,
    DateTime? now,
  }) {
    final decision = prepareForward(
      bundleId: bundleId,
      targetPeerId: peerRouter.riderId,
      isTargetGateway: isPeerGateway,
      isTargetDestination: isPeerDestination,
      now: now,
    );

    if (!decision.isAllowed || decision.outgoingBundle == null) {
      return false;
    }

    final outgoing = decision.outgoingBundle!;
    final receiveResult = peerRouter.receiveBundle(
      outgoing,
      fromNodeId: riderId,
      now: now,
    );

    if (receiveResult.isAccepted) {
      final currentLocal = _store[bundleId]!;
      final newBudget = currentLocal.replicationBudget > 1
          ? (currentLocal.replicationBudget - outgoing.replicationBudget)
          : 0;

      _store[bundleId] = currentLocal.copyWith(
        replicationBudget: newBudget,
      );

      _forwardedPeers.putIfAbsent(bundleId, () => <String>{}).add(peerRouter.riderId);
      return true;
    }

    return false;
  }

  /// Ingests and processes a delivery acknowledgement.
  bool processAck(DtnAck ack) {
    if (_ackStore.containsKey(ack.bundleId)) {
      return false;
    }
    _ackStore[ack.bundleId] = ack;

    // Mark bundle as delivered and update status.
    final existing = _store[ack.bundleId];
    if (existing != null) {
      _store[ack.bundleId] = existing.copyWith(
        isDelivered: true,
      );
    }
    return true;
  }

  /// Retrieves list of pending unexpired bundles sorted by priority then timestamp.
  List<DtnBundle> getPendingBundles({DateTime? now}) {
    purgeExpired(now);
    final list = _store.values
        .where((b) => !b.isDelivered && !b.isExpired(now))
        .toList();

    list.sort((a, b) {
      final pCompare = b.priority.weight.compareTo(a.priority.weight);
      if (pCompare != 0) return pCompare;
      return a.creationTimestamp.compareTo(b.creationTimestamp);
    });
    return list;
  }

  /// Purges all bundles whose lifetime TTL has expired.
  int purgeExpired([DateTime? now]) {
    final expiredKeys = <String>[];
    for (final entry in _store.entries) {
      if (entry.value.isExpired(now)) {
        expiredKeys.add(entry.key);
      }
    }
    for (final key in expiredKeys) {
      _store.remove(key);
    }
    return expiredKeys.length;
  }

  /// Evicts lowest priority bundle if storage limit reached.
  bool _evictLowerPriority(DtnBundlePriority incomingPriority) {
    String? lowestKey;
    var lowestWeight = incomingPriority.weight;

    for (final entry in _store.entries) {
      if (entry.value.priority.weight < lowestWeight) {
        lowestWeight = entry.value.priority.weight;
        lowestKey = entry.key;
      }
    }

    if (lowestKey != null) {
      _store.remove(lowestKey);
      return true;
    }
    return false;
  }
}
