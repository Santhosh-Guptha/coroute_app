import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'background_service.dart';
import 'safety_native.dart';
import 'sms_sender.dart';

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

  static Future<void> markIntroShown() async => (await SharedPreferences.getInstance()).setBool(_doneKey, true);

  static Future<List<PermissionItem>> status() async {
    if (!_mobile) return const [];
    final loc = await Permission.locationWhenInUse.status;
    final always = await Permission.locationAlways.status;
    final mic = await Permission.microphone.status;
    final notif = await Permission.notification.status;
    final bt = await Permission.bluetooth.status;
    final battery = await BackgroundService.isIgnoringBatteryOptimizations();
    final android = Platform.isAndroid;
    // Full-screen alarms can be denied only on Android 14 (SDK 34) and newer.
    final sdk = android ? (await SafetyNative.deviceInfo()).sdkInt : 0;
    final fullScreen = sdk >= 34 ? await SafetyNative.canUseFullScreenIntent() : true;
    final sms = android ? await isSmsGranted() : false;
    final canText = android && await SmsComposer.available();
    return [
      PermissionItem(key: 'location', title: 'Location while using the app', reason: 'We need your location so your riding group can see your position during an active ride.', required: true, granted: loc.isGranted),
      // Google Play prominent disclosure: what is collected, that it happens when the app is closed
      // or not in use, and why. Shown on the permissions screen before the system prompt.
      PermissionItem(key: 'locationAlways', title: 'Location in the background', reason: 'CoRoute collects your location to share your live position with your riding group and to send it with an SOS or crash alert, even when the app is closed or not in use. Only during an active ride. Choose "Allow all the time".', required: true, granted: always.isGranted),
      PermissionItem(key: 'microphone', title: 'Microphone', reason: 'Used only while you hold Talk or turn on hands-free talk.', required: false, granted: mic.isGranted),
      PermissionItem(key: 'bluetooth', title: 'Bluetooth', reason: 'Connects to handlebar remotes and smart airbag vests for hands-free control and crash protection.', required: false, granted: bt.isGranted),
      PermissionItem(key: 'notification', title: 'Notifications', reason: 'Enable ride alerts to receive group separation and emergency updates.', required: false, granted: notif.isGranted),
      if (Platform.isAndroid)
        PermissionItem(key: 'battery', title: 'Unrestricted battery use', reason: 'Stops the phone from closing CoRoute during long rides.', required: false, granted: battery),
      // 3.57 phone-first emergency texts. The reason is the prominent disclosure (the permissions
      // screen also opens the one-screen disclosure before the system prompt).
      if (canText)
        PermissionItem(key: 'sms', title: 'Emergency texts', reason: emergencyTextsDisclosure, required: false, granted: sms),
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
        // Immediately re-check actual status from the OS; never assume granted just because settings was opened
        return (await Permission.locationAlways.status).isGranted;
      case 'microphone':
        final r = await Permission.microphone.request();
        if (r.isPermanentlyDenied) await openAppSettings();
        return (await Permission.microphone.status).isGranted;
      case 'notification':
        final r = await Permission.notification.request();
        // Blocked for good: CoRoute's own notification page (Android), not the app settings root.
        if (r.isPermanentlyDenied && !(Platform.isAndroid && await SafetyNative.openNotificationSettings())) {
          await openAppSettings();
        }
        return (await Permission.notification.status).isGranted;
      case 'bluetooth':
        if (Platform.isAndroid) {
          try {
            // Only BLUETOOTH_CONNECT is declared (headset routing; remotes pair as HID keyboards).
            // BLUETOOTH_SCAN is not in the manifest, so asking for it always failed.
            final connect = await Permission.bluetoothConnect.request();
            if (connect.isPermanentlyDenied) await openAppSettings();
            return await isBluetoothGranted();
          } catch (_) {
            final r = await Permission.bluetooth.request();
            if (r.isPermanentlyDenied) await openAppSettings();
            return (await Permission.bluetooth.status).isGranted;
          }
        }
        final r = await Permission.bluetooth.request();
        if (r.isPermanentlyDenied) await openAppSettings();
        return (await Permission.bluetooth.status).isGranted;
      case 'battery':
        await BackgroundService.requestIgnoreBatteryOptimizations();
        return BackgroundService.isIgnoringBatteryOptimizations();
      case 'sms':
        // 3.57: SEND_SMS, asked only after the in-app disclosure ([emergencyTextsDisclosure],
        // EmergencyTextsDisclosure). Denied: the SOS text opens in the messages app instead.
        if (!Platform.isAndroid) return false;
        final r = await Permission.sms.request();
        if (r.isPermanentlyDenied) await openAppSettings();
        return isSmsGranted();
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

  static Future<bool> isLocationGranted() async {
    if (!_mobile) return true;
    return (await Permission.locationWhenInUse.status).isGranted;
  }

  static Future<bool> isLocationAlwaysGranted() async {
    if (!_mobile) return true;
    return (await Permission.locationAlways.status).isGranted;
  }

  static Future<bool> isMicrophoneGranted() async {
    if (!_mobile) return true;
    return (await Permission.microphone.status).isGranted;
  }

  static Future<bool> isBluetoothGranted() async {
    if (!_mobile) return true;
    if (Platform.isAndroid) {
      try {
        return (await Permission.bluetoothConnect.status).isGranted;
      } catch (_) {
        return (await Permission.bluetooth.status).isGranted;
      }
    }
    return (await Permission.bluetooth.status).isGranted;
  }

  /// 3.57 prominent disclosure for SEND_SMS (Google Play): what, when, and the carrier charges.
  static const String emergencyTextsDisclosure =
      'CoRoute sends a text from your phone to your emergency contacts when you raise an SOS or after a crash alarm, '
      "even if you can't touch the phone. Normal SMS charges from your carrier apply.";

  /// SEND_SMS is granted (Android only; the manifest declares no other SMS permission, so
  /// permission_handler's SMS group asks for SEND_SMS alone).
  static Future<bool> isSmsGranted() async {
    if (!_mobile || !Platform.isAndroid) return false;
    try {
      return (await Permission.sms.status).isGranted;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isNotificationGranted() async {
    if (!_mobile) return true;
    return (await Permission.notification.status).isGranted;
  }

  /// Immediately checks actual permission state from the OS for a specific key.
  /// Never assumes granted just because settings or a system dialog was opened.
  static Future<bool> isPermissionGranted(String key) async {
    if (!_mobile) return true;
    switch (key) {
      case 'location':
        return isLocationGranted();
      case 'locationAlways':
        return isLocationAlwaysGranted();
      case 'microphone':
        return isMicrophoneGranted();
      case 'bluetooth':
        return isBluetoothGranted();
      case 'notification':
        return isNotificationGranted();
      case 'battery':
        return BackgroundService.isIgnoringBatteryOptimizations();
      case 'sms':
        return isSmsGranted();
      case 'fullScreen':
        return Platform.isAndroid ? await SafetyNative.canUseFullScreenIntent() : true;
      default:
        return false;
    }
  }
}
