import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/config/feature_gates.dart';
import '../../domain/safety/sos_event.dart';
import '../../domain/safety/sos_packet_codec.dart';
import 'sos_transport_adapter.dart';

/// Central orchestrator for low-connectivity, satellite, and cellular emergency SOS.
class SatelliteSosService {
  static const String _prefsKey = 'coroute_satellite_sos_events_v1';
  static SatelliteSosService? _instance;

  static SatelliteSosService get instance => _instance ??= SatelliteSosService();

  @visibleForTesting
  static void setMockInstance(SatelliteSosService service) {
    _instance = service;
  }

  final List<SosTransportAdapter> transports;
  final SharedPreferences? prefs;
  final Duration ttl;
  final int maxRetries;
  final Duration baseRetryDelay;

  final Map<String, SosEvent> _events = {};
  final Map<String, Timer> _retryTimers = {};

  final ValueNotifier<List<SosEvent>> activeEventsNotifier =
      ValueNotifier<List<SosEvent>>([]);
  final ValueNotifier<SosEvent?> latestEventNotifier =
      ValueNotifier<SosEvent?>(null);

  bool _initialized = false;

  SatelliteSosService({
    List<SosTransportAdapter>? transports,
    this.prefs,
    this.ttl = const Duration(hours: 24),
    this.maxRetries = 5,
    this.baseRetryDelay = const Duration(seconds: 1),
  })  : transports = transports ??
            [
              CoRouteOnlineTransportAdapter(),
              NativeSatelliteHandoffAdapter(),
              CellularEmergencyHandoffAdapter(),
            ];

  /// Initialize service, load queued events from disk and prune expired ones.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    final p = prefs ?? await SharedPreferences.getInstance();
    final rawJson = p.getString(_prefsKey);
    if (rawJson != null && rawJson.isNotEmpty) {
      try {
        final List<dynamic> list = jsonDecode(rawJson) as List<dynamic>;
        final now = DateTime.now().toUtc();
        for (final item in list) {
          if (item is Map<String, dynamic>) {
            final event = SosEvent.fromJson(item);
            if (now.difference(event.timestamp) > ttl) {
              _events[event.id] =
                  event.copyWith(deliveryState: SosDeliveryState.expired);
            } else {
              _events[event.id] = event;
            }
          }
        }
      } catch (e) {
        debugPrint('[SatelliteSosService] Failed to parse cached queue: $e');
      }
    }
    _syncNotifiers();
  }

  /// Dispatch an emergency SOS through available transports according to policy.
  Future<SosEvent> dispatchSos({
    String? id,
    required double latitude,
    required double longitude,
    double? altitudeMeters,
    DateTime? timestamp,
    SosSeverity severity = SosSeverity.manual,
    String? bloodGroup,
    bool isSimulated = false,
    SubscriptionTier tier = SubscriptionTier.community,
  }) async {
    await init();

    final eventId = id ?? 'sos_${DateTime.now().millisecondsSinceEpoch}';

    // Deduplication check: do not recreate if already active or pending
    if (_events.containsKey(eventId)) {
      final existing = _events[eventId]!;
      if (existing.deliveryState.isPending || existing.deliveryState.isSuccessful) {
        return existing;
      }
    }

    final ts = timestamp ?? DateTime.now().toUtc();
    var event = SosEvent(
      id: eventId,
      latitude: latitude,
      longitude: longitude,
      altitudeMeters: altitudeMeters,
      timestamp: ts,
      severity: severity,
      bloodGroup: bloodGroup,
      deliveryState: SosDeliveryState.created,
      isSimulated: isSimulated,
    );

    // Transition to queued
    event = event.copyWith(deliveryState: SosDeliveryState.queued);
    await _saveEvent(event);

    // Feature gating check for automated satellite relay:
    // Core emergency 112 dialing is universally available to all tiers.
    // Automated satellite relay requires Pro Rider or Tour Operator.
    final hasSatelliteAccess = isSimulated ||
        FeatureGates.isUnlocked(Feature.satelliteSosRelay, tier);

    return await _executeTransmission(event, hasSatelliteAccess: hasSatelliteAccess);
  }

  /// Internal transmission executor across configured transport adapters.
  Future<SosEvent> _executeTransmission(
    SosEvent initialEvent, {
    required bool hasSatelliteAccess,
  }) async {
    var event = initialEvent.copyWith(
      deliveryState: SosDeliveryState.attempting,
      lastAttemptAt: DateTime.now().toUtc(),
      retryCount: initialEvent.retryCount + 1,
    );
    await _saveEvent(event);

    SosTransmissionResult? finalResult;

    for (final transport in transports) {
      // If transport is satellite/NTN and user lacks entitlement, skip to next transport
      if (!hasSatelliteAccess &&
          (transport.providerId == 'native_satellite_assistant' ||
              transport.providerId == 'bsnl_skylo_ntn')) {
        continue;
      }

      final isAvail = await transport.isAvailable();
      if (!isAvail) continue;

      final result = await transport.transmit(event);
      finalResult = result;

      if (result.success) {
        if (result.state == SosDeliveryState.providerAccepted) {
          event = event.copyWith(
            deliveryState: SosDeliveryState.providerAccepted,
            lastProviderId: result.providerId,
            isSimulated: result.isSimulated,
            failureReason: null,
          );
          await _saveEvent(event);
          return event;
        } else if (result.state == SosDeliveryState.handoffRequired) {
          event = event.copyWith(
            deliveryState: SosDeliveryState.handoffRequired,
            lastProviderId: result.providerId,
            isSimulated: result.isSimulated,
            failureReason: result.message,
          );
          await _saveEvent(event);
          return event;
        }
      }
    }

    // All transports failed or returned failure
    final failureReason = finalResult?.message ?? 'No transport adapter succeeded';
    event = event.copyWith(
      deliveryState: SosDeliveryState.failed,
      failureReason: failureReason,
      lastProviderId: finalResult?.providerId,
    );
    await _saveEvent(event);

    // Schedule bounded retry if attempts remain
    if (event.retryCount < maxRetries) {
      _scheduleRetry(event, hasSatelliteAccess: hasSatelliteAccess);
    }

    return event;
  }

  void _scheduleRetry(SosEvent event, {required bool hasSatelliteAccess}) {
    _retryTimers[event.id]?.cancel();

    final backoffMs = baseRetryDelay.inMilliseconds * (1 << (event.retryCount - 1));
    final delay = Duration(
        milliseconds:
            backoffMs > 60000 ? 60000 : (backoffMs < 1 ? 1 : backoffMs));

    _retryTimers[event.id] = Timer(delay, () async {
      final current = _events[event.id];
      if (current == null || current.deliveryState.isTerminal || current.deliveryState.isSuccessful) {
        return;
      }
      await _executeTransmission(current, hasSatelliteAccess: hasSatelliteAccess);
    });
  }

  /// User confirms delivery via external provider or dispatch echo.
  Future<void> confirmDelivered(String eventId) async {
    final event = _events[eventId];
    if (event == null) return;
    _retryTimers[eventId]?.cancel();
    final updated = event.copyWith(
      deliveryState: SosDeliveryState.deliveredIfConfirmedByProvider,
    );
    await _saveEvent(updated);
  }

  /// Rider cancels the SOS alert.
  Future<void> cancelSos(String eventId) async {
    final event = _events[eventId];
    if (event == null) return;
    _retryTimers[eventId]?.cancel();
    final updated = event.copyWith(
      deliveryState: SosDeliveryState.cancelled,
    );
    await _saveEvent(updated);
  }

  Future<void> _saveEvent(SosEvent event) async {
    _events[event.id] = event;
    _syncNotifiers();

    try {
      final p = prefs ?? await SharedPreferences.getInstance();
      final list = _events.values.map((e) => e.toJson()).toList();
      await p.setString(_prefsKey, jsonEncode(list));
    } catch (e) {
      debugPrint('[SatelliteSosService] Failed to persist queue: $e');
    }
  }

  void _syncNotifiers() {
    final list = _events.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    activeEventsNotifier.value = list;

    final unexpired = list.where((e) => !e.deliveryState.isTerminal).toList();
    latestEventNotifier.value = unexpired.isNotEmpty ? unexpired.first : (list.isNotEmpty ? list.first : null);
  }

  @visibleForTesting
  void resetForTesting() {
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    _events.clear();
    activeEventsNotifier.value = [];
    latestEventNotifier.value = null;
    _initialized = false;
  }

  void dispose() {
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    activeEventsNotifier.dispose();
    latestEventNotifier.dispose();
  }
}
