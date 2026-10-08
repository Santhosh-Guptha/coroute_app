import 'dart:typed_data';
import 'package:flutter/services.dart';
import '../../core/constants/safety_constants.dart';
import '../../domain/safety/accel_bucket.dart';

/// One-second accelerometer buckets. The sensor runs only while the stream is
/// listened to; cancelling the subscription unregisters it.
abstract class AccelSource {
  Stream<AccelBucket> buckets({
    int samplingUs = SafetyConstants.accelSamplingUs,
    int maxLatencyUs = SafetyConstants.accelMaxLatencyUs,
  });
}

/// Android accelerometer through the `coroute/accel` EventChannel (MainActivity,
/// AccelStream.kt). Hardware batched; reduced to 1 s buckets on a sensor thread.
/// The stream fails with a PlatformException `NO_SENSOR` on phones without one.
class NativeAccelSource implements AccelSource {
  static const EventChannel _channel = EventChannel('coroute/accel');

  @override
  Stream<AccelBucket> buckets({
    int samplingUs = SafetyConstants.accelSamplingUs,
    int maxLatencyUs = SafetyConstants.accelMaxLatencyUs,
  }) {
    return _channel
        .receiveBroadcastStream(<String, int>{'samplingUs': samplingUs, 'maxLatencyUs': maxLatencyUs})
        .expand<AccelBucket>((event) {
      if (event is Float64List) return AccelBucket.decode(event);
      if (event is List) {
        final values = <double>[for (final v in event) v is num ? v.toDouble() : double.nan];
        return AccelBucket.decode(Float64List.fromList(values));
      }
      return const <AccelBucket>[];
    });
  }
}
