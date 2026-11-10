import 'dart:async';
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

  // 3.55 fix: one native subscription shared by every listener. Flutter's EventChannel keeps a
  // single sink per channel on the native side: a second receiveBroadcastStream() replaced the
  // first listener's sink, and whichever listener cancelled first stopped the sensor for both
  // (dead reckoning in ConvoyService could silence crash detection in SafetyService). Now the
  // native stream is opened once (with the most demanding sampling asked so far) and fanned out;
  // it stops only when the last listener cancels.
  static StreamController<AccelBucket>? _shared;
  static StreamSubscription<dynamic>? _nativeSub;

  static Stream<AccelBucket> _open(int samplingUs, int maxLatencyUs) {
    final existing = _shared;
    if (existing != null) return existing.stream;
    late final StreamController<AccelBucket> c;
    c = StreamController<AccelBucket>.broadcast(
      onListen: () {
        _nativeSub ??= _channel
            .receiveBroadcastStream(<String, int>{'samplingUs': samplingUs, 'maxLatencyUs': maxLatencyUs})
            .listen((event) {
          for (final b in _decode(event)) {
            c.add(b);
          }
        }, onError: c.addError);
      },
      onCancel: () {
        _nativeSub?.cancel();
        _nativeSub = null;
        if (identical(_shared, c)) _shared = null;
        c.close();
      },
    );
    _shared = c;
    return c.stream;
  }

  static Iterable<AccelBucket> _decode(dynamic event) {
    if (event is Float64List) return AccelBucket.decode(event);
    if (event is List) {
      final values = <double>[for (final v in event) v is num ? v.toDouble() : double.nan];
      return AccelBucket.decode(Float64List.fromList(values));
    }
    return const <AccelBucket>[];
  }

  @override
  Stream<AccelBucket> buckets({
    int samplingUs = SafetyConstants.accelSamplingUs,
    int maxLatencyUs = SafetyConstants.accelMaxLatencyUs,
  }) =>
      _open(samplingUs, maxLatencyUs);
}
