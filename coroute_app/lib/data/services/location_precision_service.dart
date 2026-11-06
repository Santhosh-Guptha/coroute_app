import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Precise ("fine") location for the riding map.
///
/// Android 12+ and iOS 14+ let the rider grant only an approximate location
/// (off by up to ~3 km), which makes the live map and the group's positions
/// useless. This checks for that and asks for precise location again:
/// * Android: a new permission request shows the system "Precise / Approximate"
///   dialog (ACCESS_FINE_LOCATION must be in the manifest); if Android no
///   longer shows it, [openSettings] sends the rider to the app's settings.
/// * iOS: a temporary full-accuracy request for this session, explained by the
///   [iosPurposeKey] entry of `NSLocationTemporaryUsageDescriptionDictionary`
///   in Info.plist.
class LocationPrecision {
  LocationPrecision._();

  /// Key in Info.plist's NSLocationTemporaryUsageDescriptionDictionary.
  static const String iosPurposeKey = 'RideNavigation';

  static bool get _mobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Whether location is precise; [LocationAccuracyStatus.unknown] when it
  /// cannot be told (desktop, web, tests, no permission yet).
  static Future<LocationAccuracyStatus> status() async {
    if (!_mobile) return LocationAccuracyStatus.unknown;
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        return LocationAccuracyStatus.unknown;
      }
      return await Geolocator.getLocationAccuracy();
    } catch (e) {
      debugPrint('Location accuracy check note: $e');
      return LocationAccuracyStatus.unknown;
    }
  }

  /// True only when the phone positively reports approximate location.
  static Future<bool> isApproximate() async => await status() == LocationAccuracyStatus.reduced;

  /// Asks the system for precise location; returns the status afterwards.
  static Future<LocationAccuracyStatus> requestPrecise() async {
    if (!_mobile) return LocationAccuracyStatus.unknown;
    try {
      if (Platform.isIOS) {
        return await Geolocator.requestTemporaryFullAccuracy(purposeKey: iosPurposeKey);
      }
      await Geolocator.requestPermission();
      return await Geolocator.getLocationAccuracy();
    } catch (e) {
      debugPrint('Precise location request note: $e');
      return status();
    }
  }

  /// The app's system settings page (Location > "Use precise location").
  static Future<bool> openSettings() async {
    try {
      return await Geolocator.openAppSettings();
    } catch (_) {
      return false;
    }
  }
}
