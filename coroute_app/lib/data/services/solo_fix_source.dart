import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import '../../domain/tracking/track_point.dart';

/// GPS fixes for an offline solo ride (3.54): no convoy and no internet, so ConvoyService is
/// not tracking. The GPS works without a data connection; the app's foreground service
/// (started by SafetyService) keeps the stream alive with the screen off.
Stream<TrackPoint> nativeSoloFixes() {
  final LocationSettings settings;
  if (!kIsWeb && Platform.isAndroid) {
    settings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
      intervalDuration: const Duration(seconds: 1),
    );
  } else if (!kIsWeb && Platform.isIOS) {
    settings = AppleSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
      activityType: ActivityType.automotiveNavigation,
      pauseLocationUpdatesAutomatically: false,
    );
  } else {
    settings = const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5);
  }
  return Geolocator.getPositionStream(locationSettings: settings).map((p) => soloFixFrom(p));
}

/// One [Position] as a [TrackPoint] (speed in km/h; an unknown or negative speed reads 0).
/// Stamped with the phone clock like ConvoyService's fixes (the accelerometer buckets use it
/// too; the GPS time of a fix can be off by seconds).
TrackPoint soloFixFrom(Position p, {int? nowMs}) {
  final mps = p.speed.isFinite && p.speed > 0 ? p.speed : 0.0;
  return TrackPoint(
    ts: nowMs ?? DateTime.now().millisecondsSinceEpoch,
    lat: p.latitude,
    lng: p.longitude,
    speedKmh: mps * 3.6,
    accuracyM: p.accuracy.isFinite ? p.accuracy : 0,
  );
}
