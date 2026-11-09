import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import '../../domain/tracking/speed_estimator.dart';
import '../../domain/tracking/track_point.dart';

/// GPS fixes for an offline solo ride (3.54): no convoy and no internet, so ConvoyService is
/// not tracking. The GPS works without a data connection; the app's foreground service
/// (started by SafetyService) keeps the stream alive with the screen off.
Stream<TrackPoint> nativeSoloFixes() {
  final LocationSettings settings;
  if (!kIsWeb && Platform.isAndroid) {
    settings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
      intervalDuration: const Duration(seconds: 1),
    );
  } else if (!kIsWeb && Platform.isIOS) {
    settings = AppleSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
      activityType: ActivityType.automotiveNavigation,
      pauseLocationUpdatesAutomatically: false,
    );
  } else {
    settings = const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 0);
  }
  // Every fix (distance filter 0, so the speed falls to 0 when stopped instead of freezing at the
  // last reading) goes through the same speed estimator as a group ride.
  final estimator = SpeedEstimator();
  return Geolocator.getPositionStream(locationSettings: settings).map((p) => soloFixFrom(p, estimator: estimator));
}

/// One [Position] for [SpeedEstimator]: the GNSS Doppler speed only when the platform reported
/// one ([Position.hasSpeed], or a positive value: Android's placeholder without a speed is 0.0,
/// iOS's is -1), its accuracy only when known.
SpeedFix speedFixOf(Position p) => SpeedFix(
      tMs: p.timestamp.millisecondsSinceEpoch,
      lat: p.latitude,
      lng: p.longitude,
      dopplerMps: (p.hasSpeed || p.speed > 0) && p.speed.isFinite && p.speed >= 0 ? p.speed : null,
      speedAccuracyMps: p.hasSpeedAccuracy && p.speedAccuracy.isFinite && p.speedAccuracy > 0 ? p.speedAccuracy : null,
      accuracyM: p.accuracy.isFinite && p.accuracy > 0 ? p.accuracy : null,
    );

/// One [Position] as a [TrackPoint] (speed in km/h; an unknown or negative speed reads 0).
/// Stamped with the phone clock like ConvoyService's fixes (the accelerometer buckets use it
/// too; the GPS time of a fix can be off by seconds). With an [estimator], the speed is its
/// filtered estimate (outliers rejected, no-Doppler fallback, 0 when stopped).
TrackPoint soloFixFrom(Position p, {int? nowMs, SpeedEstimator? estimator}) {
  final mps = p.speed.isFinite && p.speed > 0 ? p.speed : 0.0;
  final kmh = estimator != null ? estimator.update(speedFixOf(p)).kmh : mps * 3.6;
  return TrackPoint(
    ts: nowMs ?? DateTime.now().millisecondsSinceEpoch,
    lat: p.latitude,
    lng: p.longitude,
    speedKmh: kmh,
    accuracyM: p.accuracy.isFinite ? p.accuracy : 0,
    // 3.55 high-altitude care: 0 is what phones report without an altitude.
    altM: p.altitude.isFinite && p.altitude != 0 ? p.altitude : null,
  );
}
