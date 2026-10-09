import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the phone reports about itself (for the brand battery guide and the
/// lock-screen alarm check). Off Android everything is empty / false.
class DeviceSafetyInfo {
  final String manufacturer;
  final String model;
  final int sdkInt;

  /// Accelerometer hardware queue size (0 = no batching, events come directly).
  final int accelFifo;
  final bool hasAccel;

  const DeviceSafetyInfo({
    required this.manufacturer,
    required this.model,
    required this.sdkInt,
    required this.accelFifo,
    required this.hasAccel,
  });

  static const DeviceSafetyInfo unknown = DeviceSafetyInfo(manufacturer: '', model: '', sdkInt: 0, accelFifo: 0, hasAccel: false);

  static DeviceSafetyInfo fromMap(Map<String, dynamic>? m) {
    if (m == null) return unknown;
    return DeviceSafetyInfo(
      manufacturer: m['manufacturer']?.toString() ?? '',
      model: m['model']?.toString() ?? '',
      sdkInt: (m['sdkInt'] as num?)?.toInt() ?? 0,
      accelFifo: (m['accelFifo'] as num?)?.toInt() ?? 0,
      hasAccel: m['hasAccel'] == true,
    );
  }
}

/// Small Android helpers on the `coroute/safety` MethodChannel (SafetyChannel.kt).
/// Every call is safe off Android and never throws.
class SafetyNative {
  SafetyNative._();

  static const MethodChannel _channel = MethodChannel('coroute/safety');
  static DeviceSafetyInfo? _info;

  static bool get _android => !kIsWeb && Platform.isAndroid;

  static Future<DeviceSafetyInfo> deviceInfo() async {
    final cached = _info;
    if (cached != null) return cached;
    if (!_android) return DeviceSafetyInfo.unknown;
    try {
      final info = DeviceSafetyInfo.fromMap(await _channel.invokeMapMethod<String, dynamic>('deviceInfo'));
      _info = info;
      return info;
    } catch (_) {
      return DeviceSafetyInfo.unknown;
    }
  }

  /// Android 14+ can deny full-screen alarms; below that it is always allowed.
  static Future<bool> canUseFullScreenIntent() async {
    if (!_android) return false;
    try {
      return await _channel.invokeMethod<bool>('canUseFullScreenIntent') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Opens the system page "Allow full-screen notifications" for CoRoute (Android 14+).
  static Future<bool> openFullScreenIntentSettings() => _bool('openFullScreenIntentSettings');

  /// Opens the brand's autostart / battery page, or the app's settings page.
  static Future<bool> openOemBatterySettings() => _bool('openOemBatterySettings');

  /// Shows CoRoute over the lock screen and turns the screen on, only while a crash alarm is open.
  static Future<void> alarmWindow(bool on) async {
    if (!_android) return;
    try {
      await _channel.invokeMethod<void>('alarmWindow', <String, bool>{'on': on});
    } catch (_) {}
  }

  /// The app's own cache folder (`context.cacheDir`), for the map tile cache. Null off Android.
  static Future<String?> cacheDir() async {
    if (!_android) return null;
    try {
      final d = await _channel.invokeMethod<String>('cacheDir');
      return d == null || d.isEmpty ? null : d;
    } catch (_) {
      return null;
    }
  }

  /// 'wifi', 'mobile' or 'none' (ConnectivityManager; no new permission). 'none' off Android.
  static Future<String> networkKind() async {
    if (!_android) return 'none';
    try {
      return await _channel.invokeMethod<String>('networkKind') ?? 'none';
    } catch (_) {
      return 'none';
    }
  }

  static Future<bool> _bool(String method) async {
    if (!_android) return false;
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } catch (_) {
      return false;
    }
  }
}
