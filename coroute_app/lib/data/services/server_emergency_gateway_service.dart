import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import '../../domain/safety/sos_event.dart';
import 'api_client.dart';
import 'sms_sender.dart';

/// Contact model for external emergency dispatch.
class EmergencyContactInfo {
  final String phone;
  final String name;

  const EmergencyContactInfo({
    required this.phone,
    required this.name,
  });

  Map<String, dynamic> toJson() => {
        'phone': phone,
        'name': name,
      };

  factory EmergencyContactInfo.fromJson(Map<String, dynamic> json) =>
      EmergencyContactInfo(
        phone: json['phone']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
      );
}

/// Delivery outcome for an individual contact channel.
class ServerDispatchItemResult {
  final String contact;
  final String name;
  final String channel;
  final bool success;
  final String provider;
  final String? messageId;
  final String? error;

  const ServerDispatchItemResult({
    required this.contact,
    required this.name,
    required this.channel,
    required this.success,
    required this.provider,
    this.messageId,
    this.error,
  });

  factory ServerDispatchItemResult.fromJson(Map<String, dynamic> json) =>
      ServerDispatchItemResult(
        contact: json['contact']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        channel: json['channel']?.toString() ?? 'sms',
        success: json['success'] == true,
        provider: json['provider']?.toString() ?? '',
        messageId: json['messageId']?.toString(),
        error: json['error']?.toString(),
      );
}

/// Structured response from POST /api/v1/sos/dispatch-external.
class ServerEmergencyDispatchResult {
  final bool dispatched;
  final String provider;
  final int sentCount;
  final List<ServerDispatchItemResult> results;
  final String? trackingUrl;

  const ServerEmergencyDispatchResult({
    required this.dispatched,
    required this.provider,
    required this.sentCount,
    required this.results,
    this.trackingUrl,
  });

  factory ServerEmergencyDispatchResult.fromJson(Map<String, dynamic> json) =>
      ServerEmergencyDispatchResult(
        dispatched: json['dispatched'] == true,
        provider: json['provider']?.toString() ?? 'unknown',
        sentCount: (json['sentCount'] as num?)?.toInt() ?? 0,
        results: (json['results'] as List<dynamic>? ?? const [])
            .map((item) =>
                ServerDispatchItemResult.fromJson(item as Map<String, dynamic>))
            .toList(),
        trackingUrl: json['trackingUrl']?.toString(),
      );
}

/// Client-side service interacting with CoRoute's Server Emergency SMS & WhatsApp Gateway.
/// Guarantees emergency dispatch for iOS devices, data-only SIM cards, and depleted balances.
class ServerEmergencyGatewayService {
  final ApiClient apiClient;
  final SmsSender nativeSender;
  final bool Function()? isAppleDeviceOverride;

  ServerEmergencyGatewayService({
    required this.apiClient,
    SmsSender? nativeSender,
    this.isAppleDeviceOverride,
  }) : nativeSender = nativeSender ?? NativeSmsSender();

  /// Automatically active on iOS, iPadOS, macOS, and whenever native SMS capability
  /// reports hasTelephony: false or simReady: false.
  bool isServerFallbackNeeded(SmsCapability nativeCap) {
    if (isAppleDeviceOverride != null) {
      if (isAppleDeviceOverride!()) return true;
    } else {
      if (kIsWeb) return true;
      if (!kIsWeb && (Platform.isIOS || Platform.isMacOS)) return true;
    }
    return !nativeCap.hasTelephony || !nativeCap.simReady;
  }

  /// Dispatches emergency SMS and WhatsApp notifications to contacts via REST endpoint.
  Future<ServerEmergencyDispatchResult> dispatchExternal({
    required String tripId,
    required String riderId,
    required String riderName,
    required double lat,
    required double lng,
    double? speedKmh,
    required List<EmergencyContactInfo> contacts,
    String? severity,
    String? bloodGroup,
    String? trackingUrl,
  }) async {
    final payload = <String, dynamic>{
      'tripId': tripId,
      'riderId': riderId,
      'riderName': riderName,
      'lat': lat,
      'lng': lng,
      'contacts': contacts.map((c) => c.toJson()).toList(),
    };
    if (speedKmh != null) payload['speedKmh'] = speedKmh;
    if (severity != null) payload['severity'] = severity;
    if (bloodGroup != null) payload['bloodGroup'] = bloodGroup;
    if (trackingUrl != null) payload['trackingUrl'] = trackingUrl;

    final dynamic res =
        await apiClient.post('/v1/sos/dispatch-external', payload);
    if (res is Map<String, dynamic>) {
      return ServerEmergencyDispatchResult.fromJson(res);
    }
    throw const ApiException(500, 'Invalid server emergency gateway response');
  }

  /// Dispatches an [SosEvent] through the server emergency gateway.
  Future<SosTransmissionResult> dispatchFromSosEvent(
    SosEvent event, {
    String? tripId,
    String? riderId,
    String? riderName,
    List<EmergencyContactInfo>? contacts,
  }) async {
    try {
      final res = await dispatchExternal(
        tripId: tripId ?? event.id,
        riderId: riderId ?? 'rider',
        riderName: riderName ?? 'CoRoute Rider',
        lat: event.latitude,
        lng: event.longitude,
        contacts: contacts ?? const [],
        severity: event.severity.label,
        bloodGroup: event.bloodGroup,
      );

      if (res.dispatched) {
        return SosTransmissionResult.accepted(
          providerId: 'server_emergency_gateway_${res.provider}',
          message:
              'Server gateway dispatched SMS/WhatsApp to ${res.sentCount} channels',
          isSimulated: false,
        );
      }

      return SosTransmissionResult.failed(
        providerId: 'server_emergency_gateway',
        reason: 'Gateway reported no dispatched contacts',
        isSimulated: false,
      );
    } catch (e) {
      return SosTransmissionResult.failed(
        providerId: 'server_emergency_gateway',
        reason: 'Server emergency gateway dispatch error: $e',
        isSimulated: false,
      );
    }
  }

  /// Creates a transparent [SmsSender] that routes through native telephony when possible,
  /// and automatically falls back to server dispatch when on Apple platforms or data-only SIMs.
  SmsSender createFallbackSmsSender({
    String Function()? currentTripId,
    String Function()? currentRiderId,
    String Function()? currentRiderName,
    (double, double)? Function()? currentPosition,
  }) {
    return ServerFallbackSmsSender(
      nativeSender: nativeSender,
      gatewayService: this,
      currentTripId: currentTripId,
      currentRiderId: currentRiderId,
      currentRiderName: currentRiderName,
      currentPosition: currentPosition,
    );
  }
}

/// Composite [SmsSender] that delegates to native Android telephony first, and transparently
/// falls back to [ServerEmergencyGatewayService] if native capability or dispatch fails.
class ServerFallbackSmsSender implements SmsSender {
  final SmsSender nativeSender;
  final ServerEmergencyGatewayService gatewayService;
  final String Function()? currentTripId;
  final String Function()? currentRiderId;
  final String Function()? currentRiderName;
  final (double, double)? Function()? currentPosition;

  ServerFallbackSmsSender({
    required this.nativeSender,
    required this.gatewayService,
    this.currentTripId,
    this.currentRiderId,
    this.currentRiderName,
    this.currentPosition,
  });

  @override
  Future<SmsCapability> capability() async {
    final nativeCap = await nativeSender.capability();
    if (gatewayService.isServerFallbackNeeded(nativeCap)) {
      // Cloud gateway guarantees SMS capability regardless of device hardware or OS sandbox
      return const SmsCapability(
        hasTelephony: true,
        permission: true,
        simReady: true,
      );
    }
    return nativeCap;
  }

  @override
  Future<SmsStatus> send(String to, String body) async {
    final cap = await nativeSender.capability();
    final needsServer = gatewayService.isServerFallbackNeeded(cap);

    if (!needsServer) {
      final nativeStatus = await nativeSender.send(to, body);
      if (nativeStatus == SmsStatus.sent) {
        return SmsStatus.sent;
      }
    }

    // Transparent cloud gateway fallback
    try {
      final pos = currentPosition?.call();
      final res = await gatewayService.dispatchExternal(
        tripId: currentTripId?.call() ??
            'SOS-${DateTime.now().millisecondsSinceEpoch}',
        riderId: currentRiderId?.call() ?? 'rider',
        riderName: currentRiderName?.call() ?? 'CoRoute Rider',
        lat: pos?.$1 ?? 0.0,
        lng: pos?.$2 ?? 0.0,
        contacts: [EmergencyContactInfo(phone: to, name: 'Emergency Contact')],
      );

      return res.dispatched ? SmsStatus.sent : SmsStatus.failed;
    } catch (_) {
      return SmsStatus.failed;
    }
  }
}
