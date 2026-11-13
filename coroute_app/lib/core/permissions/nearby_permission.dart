// The one place that reads and asks for Android 12+ "Nearby devices" (BLUETOOTH_SCAN, BLUETOOTH_ADVERTISE,
// BLUETOOTH_CONNECT). Shared by the pre-ride phone check, the offline long-range mesh and the rescue finder, so the
// rider is not asked again by one after answering another. The crash rescue beacon needs it granted BEFORE a
// ride: a crashed rider cannot answer a prompt.
library;

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'nearby_access.dart';

export 'nearby_access.dart';

class NearbyPermission {
  NearbyPermission._();

  /// Set once the prompt was shown (by any feature). Kept under the offline link's original key, so riders it
  /// already asked are not asked again automatically.
  static const String askedKey = 'offline_link_bt_asked_v1';

  static const List<Permission> _perms = [
    Permission.bluetoothScan,
    Permission.bluetoothAdvertise,
    Permission.bluetoothConnect,
  ];

  static bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool applies(int sdk) => NearbyPolicy.applies(android: _android, sdk: sdk);

  /// Current state, without any prompt. [sdk]: Android API level (0 when unknown: treated as not needed).
  static Future<NearbyAccess> status({required int sdk}) async {
    if (!applies(sdk)) return NearbyAccess.notNeeded;
    try {
      final s = [for (final p in _perms) await p.status];
      return _combine(sdk, s);
    } catch (_) {
      return NearbyAccess.denied;
    }
  }

  /// The prompt was already shown once (by the phone check, the mesh or the rescue finder).
  static Future<bool> wasAsked() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(askedKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _markAsked() async {
    try {
      await (await SharedPreferences.getInstance()).setBool(askedKey, true);
    } catch (_) {}
  }

  /// Rider tapped a button (phone check "Allow", rescue finder): shows the system prompt for the three
  /// permissions; when Android will not ask any more, opens CoRoute's app settings instead
  /// ([openSettingsIfBlocked]). Returns the state afterwards, read again from the OS.
  static Future<NearbyAccess> request({required int sdk, bool openSettingsIfBlocked = true}) async {
    if (!applies(sdk)) return NearbyAccess.notNeeded;
    final before = await status(sdk: sdk);
    if (before == NearbyAccess.granted) return before;
    if (before == NearbyAccess.permanentlyDenied) {
      if (openSettingsIfBlocked) await _openSettings();
      return status(sdk: sdk);
    }
    await _markAsked();
    try {
      final r = await _perms.request();
      final after = _combine(sdk, [for (final p in _perms) r[p] ?? PermissionStatus.denied]);
      if (after == NearbyAccess.permanentlyDenied && openSettingsIfBlocked) await _openSettings();
    } catch (_) {}
    return status(sdk: sdk);
  }

  /// Automatic ask (the offline link at a group ride): at most once ever across the app, and never when it is
  /// already granted or only settings could change it. Returns the state afterwards.
  static Future<NearbyAccess> requestOnce({required int sdk}) async {
    final now = await status(sdk: sdk);
    if (!NearbyPolicy.mayAutoPrompt(now, askedBefore: await wasAsked())) return now;
    return request(sdk: sdk, openSettingsIfBlocked: false);
  }

  static NearbyAccess _combine(int sdk, List<PermissionStatus> s) => NearbyPolicy.combine(
        android: _android,
        sdk: sdk,
        scan: s[0].isGranted,
        advertise: s[1].isGranted,
        connect: s[2].isGranted,
        anyPermanentlyDenied: s.any((x) => x.isPermanentlyDenied),
      );

  static Future<void> _openSettings() async {
    try {
      await openAppSettings();
    } catch (_) {}
  }
}
