// Round 10 rescue beacon: the `coroute/rescue` MethodChannel (RescueBeaconChannel.kt).
//
// Every call is safe off Android (returns false / null) and never throws. Kotlin side:
//  * audio: AudioTrack on USAGE_ALARM (plays in silent mode and through Do Not Disturb wherever
//    alarms are allowed, which is Android's default), alarm stream at max while the beacon plays,
//    the rider's volume restored afterwards;
//  * vibration, the camera torch (CameraManager.setTorchMode, no CAMERA permission), a one-shot
//    read of the light / proximity / accelerometer sensors;
//  * BLE locator advertising (legacy + extended / LE Coded where supported) and scanning;
//  * a partial wake lock with a timeout while the beacon runs.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One BLE sighting of a rescue advertisement.
class RescueBleSighting {
  final int rescueId;
  final int rssi;
  final int atMs;

  /// 'coded', '1m' or '2m' (Android 8+ only), '' when unknown.
  final String phy;

  const RescueBleSighting({required this.rescueId, required this.rssi, required this.atMs, this.phy = ''});
}

/// The light / proximity / tilt reading of one moment (nulls when the sensor is missing).
class RescueSensors {
  final double? lux;
  final bool? proximityNear;
  final bool? faceDown;

  const RescueSensors({this.lux, this.proximityNear, this.faceDown});

  static const RescueSensors unknown = RescueSensors();

  bool get covered => proximityNear == true;
}

/// What the BLE advertiser managed to start.
class RescueBleAdvState {
  final bool legacy;
  final bool extended;
  final bool coded;
  final String error;

  const RescueBleAdvState({this.legacy = false, this.extended = false, this.coded = false, this.error = ''});

  bool get any => legacy || extended;
  static const RescueBleAdvState off = RescueBleAdvState();
}

/// The narrow native port the services use (a fake in tests).
abstract class RescueNativePort {
  Future<bool> playPcm(Int16List pcm, {required int sampleRate, bool alarm = true, bool maxVolume = true});
  Future<void> stopAudio();

  /// The beacon ended: silence, alarm volume and Do Not Disturb back as the rider had them.
  Future<void> endSession();
  Future<void> vibrate(List<int> pattern);
  Future<String> strobe(bool on, {List<int> pattern = const []});
  Future<RescueSensors> sensors();
  Future<RescueBleAdvState> bleAdvertise({required bool on, int rescueId = 0, int flags = 0, bool lowPower = false});
  Future<bool> bleScan({required bool on, bool lowLatency = true});
  Stream<RescueBleSighting> get sightings;
  Future<void> wakeLock(bool on, {int timeoutMs = 120000});
  Future<Map<String, dynamic>> audioState();
}

class RescueNative implements RescueNativePort {
  RescueNative._() {
    if (_supported) {
      try {
        _channel.setMethodCallHandler(_onCall);
      } catch (_) {}
    }
  }

  static final RescueNative instance = RescueNative._();

  static const MethodChannel _channel = MethodChannel('coroute/rescue');

  static bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  final StreamController<RescueBleSighting> _sightings = StreamController<RescueBleSighting>.broadcast();

  @override
  Stream<RescueBleSighting> get sightings => _sightings.stream;

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'onBleResult' && call.arguments is Map) {
      final m = Map<String, dynamic>.from(call.arguments as Map);
      final id = (m['rescueId'] as num?)?.toInt() ?? 0;
      final rssi = (m['rssi'] as num?)?.toInt() ?? -127;
      if (id > 0 && rssi > -127 && rssi < 20) {
        _sightings.add(RescueBleSighting(rescueId: id, rssi: rssi, atMs: DateTime.now().millisecondsSinceEpoch, phy: m['phy']?.toString() ?? ''));
      }
    }
    return null;
  }

  Future<T?> _call<T>(String method, [Map<String, dynamic>? args]) async {
    if (!_supported) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } catch (e) {
      debugPrint('rescue native $method note: $e');
      return null;
    }
  }

  @override
  Future<bool> playPcm(Int16List pcm, {required int sampleRate, bool alarm = true, bool maxVolume = true}) async {
    final bytes = pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes);
    return await _call<bool>('playPcm', {'pcm': bytes, 'sampleRate': sampleRate, 'alarm': alarm, 'maxVolume': maxVolume}) ?? false;
  }

  @override
  Future<void> stopAudio() async => _call<void>('stopAudio');

  @override
  Future<void> endSession() async => _call<void>('endSession');

  @override
  Future<void> vibrate(List<int> pattern) async => _call<void>('vibrate', {'pattern': pattern});

  @override
  Future<String> strobe(bool on, {List<int> pattern = const []}) async =>
      await _call<String>('strobe', {'on': on, 'pattern': pattern}) ?? 'none';

  @override
  Future<RescueSensors> sensors() async {
    final m = await _call<Map<dynamic, dynamic>>('sensors');
    if (m == null) return RescueSensors.unknown;
    return RescueSensors(
      lux: (m['lux'] as num?)?.toDouble(),
      proximityNear: m['proximityNear'] as bool?,
      faceDown: m['faceDown'] as bool?,
    );
  }

  @override
  Future<RescueBleAdvState> bleAdvertise({required bool on, int rescueId = 0, int flags = 0, bool lowPower = false}) async {
    final m = await _call<Map<dynamic, dynamic>>('bleAdvertise', {'on': on, 'rescueId': rescueId, 'flags': flags, 'lowPower': lowPower});
    if (m == null) return RescueBleAdvState.off;
    return RescueBleAdvState(
      legacy: m['legacy'] == true,
      extended: m['extended'] == true,
      coded: m['coded'] == true,
      error: m['error']?.toString() ?? '',
    );
  }

  @override
  Future<bool> bleScan({required bool on, bool lowLatency = true}) async =>
      await _call<bool>('bleScan', {'on': on, 'lowLatency': lowLatency}) ?? false;

  @override
  Future<void> wakeLock(bool on, {int timeoutMs = 120000}) async => _call<void>('wakeLock', {'on': on, 'timeoutMs': timeoutMs});

  /// Alarm volume, ringer mode, Do Not Disturb state, torch / BLE capabilities (diagnostics only).
  @override
  Future<Map<String, dynamic>> audioState() async {
    final m = await _call<Map<dynamic, dynamic>>('audioState');
    return m == null ? const {} : Map<String, dynamic>.from(m);
  }
}
