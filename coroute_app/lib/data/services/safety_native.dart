import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the phone reports about itself (for the brand battery guide and the
/// lock-screen alarm check). Off Android everything is empty / false.
class DeviceSafetyInfo {
  final String manufacturer;
  final String model;
  final int sdkInt;
  final String release;
  final String cpuAbi;

  /// Accelerometer hardware queue size (0 = no batching, events come directly).
  final int accelFifo;
  final bool hasAccel;
  final bool hasGyro;
  final int gyroFifo;

  const DeviceSafetyInfo({
    required this.manufacturer,
    required this.model,
    required this.sdkInt,
    this.release = '',
    this.cpuAbi = '',
    required this.accelFifo,
    required this.hasAccel,
    this.hasGyro = false,
    this.gyroFifo = 0,
  });

  static const DeviceSafetyInfo unknown = DeviceSafetyInfo(
    manufacturer: '',
    model: '',
    sdkInt: 0,
    release: '',
    cpuAbi: '',
    accelFifo: 0,
    hasAccel: false,
    hasGyro: false,
    gyroFifo: 0,
  );

  static DeviceSafetyInfo fromMap(Map<String, dynamic>? m) {
    if (m == null) return unknown;
    return DeviceSafetyInfo(
      manufacturer: m['manufacturer']?.toString() ?? '',
      model: m['model']?.toString() ?? '',
      sdkInt: (m['sdkInt'] as num?)?.toInt() ?? 0,
      release: m['release']?.toString() ?? '',
      cpuAbi: m['cpuAbi']?.toString() ?? '',
      accelFifo: (m['accelFifo'] as num?)?.toInt() ?? 0,
      hasAccel: m['hasAccel'] == true,
      hasGyro: m['hasGyro'] == true,
      gyroFifo: (m['gyroFifo'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Small device helpers on the `coroute/safety` MethodChannel (SafetyChannel.kt / AppDelegate.swift).
/// Every call is safe on mobile and never throws.
class SafetyNative {
  SafetyNative._();

  static const MethodChannel _channel = MethodChannel('coroute/safety');
  static DeviceSafetyInfo? _info;

  static bool get _supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  static Future<DeviceSafetyInfo> deviceInfo() async {
    final cached = _info;
    if (cached != null) return cached;
    if (!_supported) return DeviceSafetyInfo.unknown;
    try {
      final info = DeviceSafetyInfo.fromMap(await _channel.invokeMapMethod<String, dynamic>('deviceInfo'));
      _info = info;
      return info;
    } catch (_) {
      return DeviceSafetyInfo.unknown;
    }
  }

  /// Android 14+ can deny full-screen alarms; below that (and on iOS) it is always allowed.
  static Future<bool> canUseFullScreenIntent() async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('canUseFullScreenIntent') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Opens the system page "Allow full-screen notifications" for CoRoute (Android 14+) or app settings.
  static Future<bool> openFullScreenIntentSettings() => _bool('openFullScreenIntentSettings');

  /// Opens the brand's autostart / battery page, or the app's settings page.
  static Future<bool> openOemBatterySettings() => _bool('openOemBatterySettings');

  /// Shows CoRoute over the lock screen and turns the screen on, only while a crash alarm is open.
  static Future<void> alarmWindow(bool on) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('alarmWindow', <String, bool>{'on': on});
    } catch (_) {}
  }

  /// Always-on ride screen: dims only CoRoute's window ([value] 0..1 of the panel range), or
  /// gives the brightness back to the system with null. Never changes the system setting.
  static Future<void> windowBrightness(double? value) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('windowBrightness', <String, double>{'value': value ?? -1.0});
    } catch (_) {}
  }

  /// The app's own cache folder (`context.cacheDir` / `Caches`), for the map tile cache. Null off mobile.
  static Future<String?> cacheDir() async {
    if (!_supported) return null;
    try {
      final d = await _channel.invokeMethod<String>('cacheDir');
      return d == null || d.isEmpty ? null : d;
    } catch (_) {
      return null;
    }
  }

  /// 3.55: the app's private files folder (`context.filesDir`), kept until uninstall; the
  /// diagnostics log lives in `<filesDir>/diag`. Null off mobile or on an older native side.
  static Future<String?> filesDir() async {
    if (!_supported) return null;
    try {
      final d = await _channel.invokeMethod<String>('filesDir');
      return d == null || d.isEmpty ? null : d;
    } catch (_) {
      return null;
    }
  }

  /// 'wifi', 'mobile' or 'none' (Network monitor; no new permission). 'none' off mobile.
  static Future<String> networkKind() async {
    if (!_supported) return 'none';
    try {
      return await _channel.invokeMethod<String>('networkKind') ?? 'none';
    } catch (_) {
      return 'none';
    }
  }

  /// Pre-ride phone check (SafetyChannel.phoneProbe): ~1.5 s of motion-sensor event counts
  /// (`accelHz`, `gyroHz`, `magHz`, `...Present`, `...Events`) and the phone state for a ride
  /// (`bgRestricted`, `powerSave`, `dndFilter`, volumes, `btOut`, `btMic`, `wiredOut`,
  /// `freeBytes`, `hasTelephony`, `canCompose`, `canDial`). Empty map off mobile or on error.
  static Future<Map<String, dynamic>> phoneProbe() async {
    if (!_supported) return const <String, dynamic>{};
    try {
      final m = await _channel
          .invokeMapMethod<String, dynamic>('phoneProbe')
          .timeout(const Duration(seconds: 5));
      return m ?? const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  /// Opens the system sound settings (volume, Do Not Disturb).
  static Future<bool> openSoundSettings() => _bool('openSoundSettings');

  static Future<bool> _bool(String method) async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } catch (_) {
      return false;
    }
  }
}
