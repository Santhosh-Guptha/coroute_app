import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// What this phone can do for emergency texts (no READ_PHONE_STATE needed).
class SmsCapability {
  final bool hasTelephony;
  final bool permission;
  final bool simReady;
  const SmsCapability({required this.hasTelephony, required this.permission, required this.simReady});

  static const SmsCapability none = SmsCapability(hasTelephony: false, permission: false, simReady: false);

  /// Texts can be sent right now.
  bool get ready => hasTelephony && permission && simReady;
}

enum SmsStatus { sent, failed, noService, noPermission, timeout }

abstract class SmsSender {
  Future<SmsCapability> capability();
  Future<SmsStatus> send(String to, String body);

  /// Launches the system SMS composer using intent/URL without runtime permissions.
  static Future<bool> launchSmsIntent({required String to, required String body}) async {
    final clean = to.replaceAll(RegExp(r'[^0-9+]'), '');
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
      try {
        final ok = await const MethodChannel('coroute/sms').invokeMethod<bool>(
          'launchSmsIntent',
          <String, dynamic>{'to': clean, 'body': body},
        );
        if (ok == true) return true;
      } catch (_) {}
    }
    final uri = Uri(
      scheme: 'sms',
      path: clean,
      queryParameters: body.isEmpty ? null : {'body': body},
    );
    try {
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}

/// The phone's messages app, opened with the SOS text and every recipient filled in.
/// Play builds have no SEND_SMS permission, so this is how emergency texts go out without
/// internet: the rider (or a bystander) presses Send. Never throws.
class SmsComposer {
  SmsComposer._();

  /// Opens the composer for [to] (one or more numbers). False when no messages app opened.
  static Future<bool> open({required List<String> to, required String body}) async {
    final numbers = <String>[
      for (final n in to)
        if (n.replaceAll(RegExp(r'[^0-9+]'), '').isNotEmpty) n.replaceAll(RegExp(r'[^0-9+]'), ''),
    ];
    if (numbers.isEmpty) return false;
    if (numbers.length == 1) return SmsSender.launchSmsIntent(to: numbers.first, body: body);
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
      try {
        final ok = await const MethodChannel('coroute/sms').invokeMethod<bool>(
          'launchSmsIntent',
          <String, dynamic>{'toList': numbers, 'body': body},
        );
        return ok == true;
      } catch (_) {
        return false;
      }
    }
    // iOS: sms:/open?addresses=a,b opens Messages with several recipients (falls back to the first).
    final uri = Uri.parse('sms:/open?addresses=${numbers.join(',')}&body=${Uri.encodeComponent(body)}');
    try {
      if (await canLaunchUrl(uri)) return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
    return SmsSender.launchSmsIntent(to: numbers.first, body: body);
  }

  /// True when this phone has a messages app to open (Android: telephony feature; iOS: sms: URL or capability).
  static Future<bool> available() async {
    if (kIsWeb) return false;
    try {
      if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
        final res = await const MethodChannel('coroute/sms').invokeMethod<Object?>('capability');
        if (res is Map) return res['hasTelephony'] == true;
        return true;
      }
    } catch (_) {}
    return false;
  }
}

/// Android SmsManager through the `coroute/sms` MethodChannel (SmsChannel.kt):
/// default SMS SIM, multipart, result after the last part or 20 s.
class NativeSmsSender implements SmsSender {
  static const MethodChannel _channel = MethodChannel('coroute/sms');

  bool get _supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Future<SmsCapability> capability() async {
    if (!_supported) return SmsCapability.none;
    try {
      final res = await _channel.invokeMethod<Object?>('capability');
      if (res is! Map) return SmsCapability.none;
      return SmsCapability(
        hasTelephony: res['hasTelephony'] == true,
        permission: res['permission'] == true,
        simReady: res['simReady'] == true,
      );
    } catch (_) {
      return SmsCapability.none;
    }
  }

  @override
  Future<SmsStatus> send(String to, String body) async {
    if (!_supported) return SmsStatus.failed;
    try {
      final res = await _channel.invokeMethod<Object?>('send', <String, String>{'to': to, 'body': body});
      if (res is! Map) return SmsStatus.failed;
      return statusFromWire(res['status']?.toString());
    } catch (_) {
      return SmsStatus.failed;
    }
  }

  @visibleForTesting
  static SmsStatus statusFromWire(String? s) {
    switch (s) {
      case 'SENT':
        return SmsStatus.sent;
      case 'NO_SERVICE':
        return SmsStatus.noService;
      case 'NO_PERMISSION':
        return SmsStatus.noPermission;
      case 'TIMEOUT':
        return SmsStatus.timeout;
      default:
        return SmsStatus.failed;
    }
  }
}
