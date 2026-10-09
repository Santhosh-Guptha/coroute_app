import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'background_service.dart';
import 'safety_native.dart';

/// One place for every runtime permission the app needs, with the reason for each.
class PermissionItem {
  final String key;
  final String title;
  final String reason;
  final bool required;
  final bool granted;
  const PermissionItem({required this.key, required this.title, required this.reason, required this.required, required this.granted});
}

class PermissionsService {
  PermissionsService._();
  static const _doneKey = 'coroute_permissions_intro_done';

  static bool get _mobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static Future<bool> introShown() async => (await SharedPreferences.getInstance()).getBool(_doneKey) ?? false;
  static Future<void> markIntroShown() async => (await SharedPreferences.getInstance()).setBool(_doneKey, true);

  static Future<List<PermissionItem>> status() async {
    if (!_mobile) return const [];
    final loc = await Permission.locationWhenInUse.status;
    final always = await Permission.locationAlways.status;
    final mic = await Permission.microphone.status;
    final notif = await Permission.notification.status;
    final battery = await BackgroundService.isIgnoringBatteryOptimizations();
    final android = Platform.isAndroid;
    // Full-screen alarms can be denied only on Android 14 (SDK 34) and newer.
    final sdk = android ? (await SafetyNative.deviceInfo()).sdkInt : 0;
    final fullScreen = sdk >= 34 ? await SafetyNative.canUseFullScreenIntent() : true;
    return [
      PermissionItem(key: 'location', title: 'Location while using the app', reason: 'We need your location so your riding group can see your position during an active ride.', required: true, granted: loc.isGranted),
      PermissionItem(key: 'locationAlways', title: 'Location in the background', reason: 'Keeps your group updated while the phone is in your pocket or the screen is locked, only during an active ride. Choose "Allow all the time".', required: true, granted: always.isGranted),
      PermissionItem(key: 'microphone', title: 'Microphone', reason: 'Used only while you hold Talk or turn on hands-free talk.', required: false, granted: mic.isGranted),
      PermissionItem(key: 'notification', title: 'Notifications', reason: 'Enable ride alerts to receive group separation and emergency updates.', required: false, granted: notif.isGranted),
      if (Platform.isAndroid)
        PermissionItem(key: 'battery', title: 'Unrestricted battery use', reason: 'Stops the phone from closing CoRoute during long rides.', required: false, granted: battery),
      if (sdk >= 34)
        PermissionItem(key: 'fullScreen', title: 'Alarm on the lock screen', reason: 'Shows the crash alarm over the lock screen, so you can cancel it without unlocking.', required: false, granted: fullScreen),
    ];
  }

  /// Requests one permission. Returns true when granted.
  static Future<bool> request(String key) async {
    if (!_mobile) return true;
    switch (key) {
      case 'location':
        return (await Permission.locationWhenInUse.request()).isGranted;
      case 'locationAlways':
        // Android needs "while in use" first; the second request shows the "all the time" option.
        if (!(await Permission.locationWhenInUse.status).isGranted) await Permission.locationWhenInUse.request();
        final r = await Permission.locationAlways.request();
        if (r.isPermanentlyDenied) await openAppSettings();
        return r.isGranted;
      case 'microphone':
        return (await Permission.microphone.request()).isGranted;
      case 'notification':
        return (await Permission.notification.request()).isGranted;
      case 'battery':
        return BackgroundService.requestIgnoreBatteryOptimizations();
      case 'sms':
        if (!Platform.isAndroid) return false;
        final r = await Permission.sms.request();
        if (r.isPermanentlyDenied) await openAppSettings();
        return r.isGranted;
      case 'fullScreen':
        // A system page: the result is read again when the rider comes back.
        if (await SafetyNative.canUseFullScreenIntent()) return true;
        await SafetyNative.openFullScreenIntentSettings();
        return SafetyNative.canUseFullScreenIntent();
    }
    return false;
  }

  /// True when everything the app needs for a convoy is granted.
  static Future<bool> coreGranted() async {
    if (!_mobile) return true;
    final items = await status();
    return items.where((p) => p.required).every((p) => p.granted);
  }
}
