import 'dart:typed_data';

/// One second of accelerometer data, reduced on the phone's sensor thread.
/// Values are the size of the acceleration in g (1.0 = resting on a table).
class AccelBucket {
  /// Start of the second, epoch ms.
  final int tMs;
  final double peakG;
  final double meanG;

  /// Standard deviation within the second: near 0 when the phone lies still.
  final double stdG;

  const AccelBucket({required this.tMs, required this.peakG, required this.meanG, required this.stdG});

  /// Decodes the flat list the native side sends: `[tMs, peakG, meanG, stdG, ...]`.
  /// A trailing partial group and non-finite values are skipped.
  static List<AccelBucket> decode(Float64List flat) {
    final out = <AccelBucket>[];
    for (var i = 0; i + 3 < flat.length; i += 4) {
      final t = flat[i], peak = flat[i + 1], mean = flat[i + 2], std = flat[i + 3];
      if (!t.isFinite || !peak.isFinite || !mean.isFinite || !std.isFinite) continue;
      out.add(AccelBucket(tMs: t.round(), peakG: peak, meanG: mean, stdG: std));
    }
    return out;
  }

  @override
  String toString() => 'AccelBucket($tMs, peak ${peakG.toStringAsFixed(2)}, std ${stdG.toStringAsFixed(2)})';
}
