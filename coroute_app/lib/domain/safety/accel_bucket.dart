import 'dart:typed_data';

/// One second of accelerometer and motorcycle telemetry data, reduced on the phone's sensor thread.
/// Values are in g units (1.0 = resting on a table), angular velocity in rad/s, tilt in degrees.
class AccelBucket {
  /// Start of the second, epoch ms.
  final int tMs;

  /// Peak total acceleration norm in g (includes static gravity).
  final double peakG;

  /// Mean acceleration norm in g.
  final double meanG;

  /// Standard deviation within the second: near 0 when the phone lies still.
  final double stdG;

  /// Peak dynamic linear acceleration in g (gravity vector isolated).
  final double peakDynG;

  /// Peak angular velocity magnitude in rad/s within the second.
  final double peakGyroRadS;

  /// Maximum orientation tilt relative to steady riding baseline in degrees.
  final double tiltDeg;

  /// Duration of continuous elevated impact acceleration in ms.
  final double impactDurationMs;

  /// Peak rate of change of dynamic acceleration (jerk) in g/s.
  final double peakJerkGPerS;

  /// Sensor health and sampling confidence score (0.0 to 1.0).
  final double sensorConfidence;

  const AccelBucket({
    required this.tMs,
    required this.peakG,
    required this.meanG,
    required this.stdG,
    this.peakDynG = 0.0,
    this.peakGyroRadS = 0.0,
    this.tiltDeg = 0.0,
    this.impactDurationMs = 0.0,
    this.peakJerkGPerS = 0.0,
    this.sensorConfidence = 1.0,
  });

  /// True dynamic peak acceleration: uses [peakDynG] if available, otherwise falls back to [peakG].
  double get effectiveDynG => peakDynG > 0.0 ? peakDynG : peakG;

  /// Decodes the flat list the native side sends:
  /// - Extended format (10 doubles): `[tMs, peakRaw, meanRaw, stdRaw, peakDyn, gyro, tilt, dur, jerk, conf, ...]`
  /// - Extended format (8 doubles): `[tMs, peakRaw, meanRaw, stdRaw, peakDyn, gyro, tilt, dur, ...]`
  /// - Legacy format (4 doubles): `[tMs, peakRaw, meanRaw, stdRaw, ...]`
  /// A trailing partial group and non-finite values are skipped.
  static List<AccelBucket> decode(Float64List flat) {
    final out = <AccelBucket>[];
    if (flat.length < 4) return out;

    final int stride;
    if (flat.length >= 8 && flat[4].isFinite && flat[0].isFinite && flat[4] >= 100.0 && flat[4] >= flat[0]) {
      // flat[4] is the timestamp of the second bucket, so this is 4-double stride
      stride = 4;
    } else if (flat.length >= 10 && flat.length % 10 == 0) {
      stride = 10;
    } else if (flat.length >= 8 && flat.length % 8 == 0) {
      stride = 8;
    } else {
      stride = 4;
    }

    for (var i = 0; i + stride - 1 < flat.length; i += stride) {
      final t = flat[i], peak = flat[i + 1], mean = flat[i + 2], std = flat[i + 3];
      if (!t.isFinite || !peak.isFinite || !mean.isFinite || !std.isFinite) continue;

      if (stride == 10) {
        final dyn = flat[i + 4], gyro = flat[i + 5], tilt = flat[i + 6], dur = flat[i + 7];
        final jerk = flat[i + 8], conf = flat[i + 9];
        out.add(AccelBucket(
          tMs: t.round(),
          peakG: peak,
          meanG: mean,
          stdG: std,
          peakDynG: dyn.isFinite ? dyn : 0.0,
          peakGyroRadS: gyro.isFinite ? gyro : 0.0,
          tiltDeg: tilt.isFinite ? tilt : 0.0,
          impactDurationMs: dur.isFinite ? dur : 0.0,
          peakJerkGPerS: jerk.isFinite ? jerk : 0.0,
          sensorConfidence: conf.isFinite ? conf : 1.0,
        ));
      } else if (stride == 8) {
        final dyn = flat[i + 4], gyro = flat[i + 5], tilt = flat[i + 6], dur = flat[i + 7];
        out.add(AccelBucket(
          tMs: t.round(),
          peakG: peak,
          meanG: mean,
          stdG: std,
          peakDynG: dyn.isFinite ? dyn : 0.0,
          peakGyroRadS: gyro.isFinite ? gyro : 0.0,
          tiltDeg: tilt.isFinite ? tilt : 0.0,
          impactDurationMs: dur.isFinite ? dur : 0.0,
        ));
      } else {
        out.add(AccelBucket(
          tMs: t.round(),
          peakG: peak,
          meanG: mean,
          stdG: std,
        ));
      }
    }
    return out;
  }

  @override
  String toString() =>
      'AccelBucket($tMs, peak ${peakG.toStringAsFixed(2)}g, dyn ${effectiveDynG.toStringAsFixed(2)}g, gyro ${peakGyroRadS.toStringAsFixed(2)}r/s, tilt ${tiltDeg.toStringAsFixed(1)}°, std ${stdG.toStringAsFixed(2)})';
}
