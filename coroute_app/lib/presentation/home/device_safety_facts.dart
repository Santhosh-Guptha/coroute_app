import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../core/permissions/nearby_permission.dart';
import '../../data/services/device_diagnostic_service.dart';
import '../../data/services/safety_native.dart';

/// v3.58: the phone-side safety facts the Home nudge and the Profile checklist need (both read without prompts).
@immutable
class DeviceSafetyFacts {
  /// Granted, or not a runtime permission on this phone.
  final bool nearbyOk;

  /// The pre-ride phone check is due (first ride, new phone, permissions changed).
  final bool preRideDue;

  const DeviceSafetyFacts({this.nearbyOk = true, this.preRideDue = false});

  static DeviceSafetyFacts? _last;

  /// The last answer (instant first frame), or null.
  static DeviceSafetyFacts? get last => _last;

  /// Reads both facts; never throws, never shows a system prompt.
  static Future<DeviceSafetyFacts> load(BuildContext context) async {
    final diag = Provider.of<DeviceDiagnosticService?>(context, listen: false);
    var nearbyOk = true;
    var due = false;
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final sdk = (await SafetyNative.deviceInfo()).sdkInt;
        final s = await NearbyPermission.status(sdk: sdk);
        nearbyOk = s == NearbyAccess.granted || s == NearbyAccess.notNeeded;
      }
    } catch (_) {}
    try {
      if (diag != null) due = (await diag.checkShouldRunDiagnostic()).shouldRun;
    } catch (_) {}
    return _last = DeviceSafetyFacts(nearbyOk: nearbyOk, preRideDue: due);
  }

  /// Asks for Nearby devices (the rider tapped "Allow"). Opens app settings when Android will not ask again.
  static Future<bool> requestNearby() async {
    try {
      if (kIsWeb || !Platform.isAndroid) return true;
      final sdk = (await SafetyNative.deviceInfo()).sdkInt;
      final s = await NearbyPermission.request(sdk: sdk);
      return s == NearbyAccess.granted || s == NearbyAccess.notNeeded;
    } catch (_) {
      return false;
    }
  }
}
