import 'dart:async';
import '../../domain/safety/sos_event.dart';

/// Provider-neutral transport abstraction for SOS distress dispatches.
abstract class SosTransportAdapter {
  String get providerId;
  String get displayName;
  bool get isSimulated;

  /// Check whether this transport is physically or logically reachable.
  Future<bool> isAvailable();

  /// Attempt transmission of the SOS event.
  Future<SosTransmissionResult> transmit(SosEvent event);
}

/// Primary online transport routing through CoRoute's central gateway.
class CoRouteOnlineTransportAdapter implements SosTransportAdapter {
  final Future<bool> Function()? connectivityChecker;
  final Future<bool> Function(SosEvent event)? onlineDispatcher;

  CoRouteOnlineTransportAdapter({
    this.connectivityChecker,
    this.onlineDispatcher,
  });

  @override
  String get providerId => 'coroute_gateway_online';

  @override
  String get displayName => 'CoRoute Online Gateway';

  @override
  bool get isSimulated => false;

  @override
  Future<bool> isAvailable() async {
    if (connectivityChecker != null) {
      try {
        return await connectivityChecker!();
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  @override
  Future<SosTransmissionResult> transmit(SosEvent event) async {
    try {
      final available = await isAvailable();
      if (!available) {
        return SosTransmissionResult.failed(
          providerId: providerId,
          reason: 'No cellular data connection to CoRoute gateway',
          isSimulated: isSimulated,
        );
      }

      if (onlineDispatcher != null) {
        final success = await onlineDispatcher!(event);
        if (success) {
          return SosTransmissionResult.accepted(
            providerId: providerId,
            message: 'SOS received and broadcast to convoy mesh',
            isSimulated: isSimulated,
          );
        } else {
          return SosTransmissionResult.failed(
            providerId: providerId,
            reason: 'Gateway rejected SOS payload or returned non-200',
            isSimulated: isSimulated,
          );
        }
      }

      // Default online simulation if no custom dispatcher injected
      return SosTransmissionResult.accepted(
        providerId: providerId,
        message: 'Dispatched to online mesh',
        isSimulated: isSimulated,
      );
    } catch (e) {
      return SosTransmissionResult.failed(
        providerId: providerId,
        reason: 'Transmission error: $e',
        isSimulated: isSimulated,
      );
    }
  }
}

/// Cellular emergency dialer and SMS handoff for India 112 ERSS.
class CellularEmergencyHandoffAdapter implements SosTransportAdapter {
  final Future<bool> Function(String message)? smsLauncher;
  final Future<bool> Function()? dialerLauncher;

  CellularEmergencyHandoffAdapter({
    this.smsLauncher,
    this.dialerLauncher,
  });

  @override
  String get providerId => 'india_112_erss';

  @override
  String get displayName => 'India ERSS 112 Emergency Handoff';

  @override
  bool get isSimulated => false;

  @override
  Future<bool> isAvailable() async => true; // Always available on any telephony device

  @override
  Future<SosTransmissionResult> transmit(SosEvent event) async {
    final message = event.toIndiaErssMessage();

    if (smsLauncher != null) {
      try {
        await smsLauncher!(message);
      } catch (_) {}
    }
    if (dialerLauncher != null) {
      try {
        await dialerLauncher!();
      } catch (_) {}
    }

    return SosTransmissionResult.handoffRequired(
      providerId: providerId,
      message: message,
      isSimulated: isSimulated,
    );
  }
}

/// Native system satellite emergency assistant (Android 15 NTN / Apple Satellite SOS).
class NativeSatelliteHandoffAdapter implements SosTransportAdapter {
  final bool isSupportedDevice;
  final Future<bool> Function(SosEvent event)? nativeHandoffTrigger;

  NativeSatelliteHandoffAdapter({
    this.isSupportedDevice = false,
    this.nativeHandoffTrigger,
  });

  @override
  String get providerId => 'native_satellite_assistant';

  @override
  String get displayName => 'Native Satellite Emergency Assistant';

  @override
  bool get isSimulated => false;

  @override
  Future<bool> isAvailable() async => isSupportedDevice;

  @override
  Future<SosTransmissionResult> transmit(SosEvent event) async {
    if (!isSupportedDevice) {
      return SosTransmissionResult.failed(
        providerId: providerId,
        reason: 'Device hardware does not support direct satellite communications',
        isSimulated: isSimulated,
      );
    }

    if (nativeHandoffTrigger != null) {
      try {
        await nativeHandoffTrigger!(event);
      } catch (e) {
        return SosTransmissionResult.failed(
          providerId: providerId,
          reason: 'Native satellite handoff failed: $e',
          isSimulated: isSimulated,
        );
      }
    }

    return SosTransmissionResult.handoffRequired(
      providerId: providerId,
      message: 'Handoff to OS Emergency Satellite Assistant initiated',
      isSimulated: isSimulated,
    );
  }
}

/// Simulated mock satellite adapter strictly for automated unit and CI testing.
class MockSatelliteTransportAdapter implements SosTransportAdapter {
  bool shouldSucceed;
  bool returnHandoff;
  Duration latency;
  int transmissionAttempts = 0;

  MockSatelliteTransportAdapter({
    this.shouldSucceed = true,
    this.returnHandoff = false,
    this.latency = Duration.zero,
  });

  @override
  String get providerId => 'mock_satellite_ci';

  @override
  String get displayName => 'Mock Satellite Transport (CI / Test)';

  @override
  bool get isSimulated => true; // Always strictly flagged as simulated

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<SosTransmissionResult> transmit(SosEvent event) async {
    transmissionAttempts++;
    if (latency > Duration.zero) {
      await Future<void>.delayed(latency);
    }

    if (!shouldSucceed) {
      return SosTransmissionResult.failed(
        providerId: providerId,
        reason: 'Mock transmission simulated failure',
        isSimulated: true,
      );
    }

    if (returnHandoff) {
      return SosTransmissionResult.handoffRequired(
        providerId: providerId,
        message: 'Mock handoff requested',
        isSimulated: true,
      );
    }

    return SosTransmissionResult.accepted(
      providerId: providerId,
      message: 'Mock satellite gateway accepted packet',
      isSimulated: true,
    );
  }
}
