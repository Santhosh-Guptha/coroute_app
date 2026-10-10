import 'dart:math' as math;

/// Speed bin categories reflecting motorcycle aerodynamic and engine efficiency regimes.
enum SpeedBinCategory {
  city, // < 45 km/h: Stop-and-go, lower gear ratios, frequent acceleration
  cruise, // 45 to 85 km/h: Optimal top gear cruising, peak efficiency
  highway, // >= 85 km/h: Elevated aerodynamic drag, higher RPM, reduced efficiency
}

/// Statistics collected within a single speed bin.
class SpeedBinStats {
  final double totalDistanceM;
  final double totalDurationS;
  final int sampleCount;

  const SpeedBinStats({
    this.totalDistanceM = 0.0,
    this.totalDurationS = 0.0,
    this.sampleCount = 0,
  });

  double get averageSpeedKmh =>
      totalDurationS > 0 ? (totalDistanceM / totalDurationS) * 3.6 : 0.0;

  SpeedBinStats add({
    required double distanceM,
    required double durationS,
  }) {
    return SpeedBinStats(
      totalDistanceM: totalDistanceM + (distanceM > 0 ? distanceM : 0.0),
      totalDurationS: totalDurationS + (durationS > 0 ? durationS : 0.0),
      sampleCount: sampleCount + 1,
    );
  }

  Map<String, dynamic> toJson() => {
        'distanceM': totalDistanceM,
        'durationS': totalDurationS,
        'samples': sampleCount,
      };

  static SpeedBinStats fromJson(Map<String, dynamic>? json) {
    if (json == null) return const SpeedBinStats();
    final d = json['distanceM'];
    final s = json['durationS'];
    final c = json['samples'];
    return SpeedBinStats(
      totalDistanceM: d is num && d.isFinite && d >= 0 ? d.toDouble() : 0.0,
      totalDurationS: s is num && s.isFinite && s >= 0 ? s.toDouble() : 0.0,
      sampleCount: c is num && c >= 0 ? c.toInt() : 0,
    );
  }
}

/// Learns real-world fuel consumption variations across different speed regimes.
class SpeedBinConsumptionLearner {
  SpeedBinConsumptionLearner({
    Map<SpeedBinCategory, SpeedBinStats>? initialStats,
  }) {
    if (initialStats != null) {
      _stats.addAll(initialStats);
    } else {
      for (final bin in SpeedBinCategory.values) {
        _stats[bin] = const SpeedBinStats();
      }
    }
  }

  final Map<SpeedBinCategory, SpeedBinStats> _stats = {};

  Map<SpeedBinCategory, SpeedBinStats> get stats => Map.unmodifiable(_stats);

  /// Default baseline multiplier factors for motorcycle engines.
  /// City: ~82% of baseline efficiency (traffic, idling, lower gears).
  /// Cruise: ~115% of baseline efficiency (optimal constant speed in top gear).
  /// Highway: ~88% of baseline efficiency (aerodynamic drag scales quadratically).
  static double defaultMultiplier(SpeedBinCategory bin) {
    switch (bin) {
      case SpeedBinCategory.city:
        return 0.82;
      case SpeedBinCategory.cruise:
        return 1.15;
      case SpeedBinCategory.highway:
        return 0.88;
    }
  }

  /// Maps an instantaneous or segment speed to its corresponding speed bin.
  static SpeedBinCategory binForSpeed(double speedKmh) {
    if (speedKmh < 45.0) return SpeedBinCategory.city;
    if (speedKmh < 85.0) return SpeedBinCategory.cruise;
    return SpeedBinCategory.highway;
  }

  /// Records a telemetry segment into the appropriate speed bin.
  void recordSegment({
    required double speedKmh,
    required double distanceM,
    required double durationS,
  }) {
    if (!speedKmh.isFinite || speedKmh < 0) return;
    if (!distanceM.isFinite || distanceM < 0) return;
    if (!durationS.isFinite || durationS < 0) return;

    final bin = binForSpeed(speedKmh);
    final current = _stats[bin] ?? const SpeedBinStats();
    _stats[bin] = current.add(distanceM: distanceM, durationS: durationS);
  }

  /// Computes the effective composite fuel mileage based on riding history across speed bins.
  double effectiveMileageKmL({required double baselineKmL}) {
    if (!baselineKmL.isFinite || baselineKmL <= 0) return 0.0;

    double totalDist = 0.0;
    double weightedDist = 0.0;

    for (final entry in _stats.entries) {
      final dist = entry.value.totalDistanceM;
      if (dist > 0) {
        totalDist += dist;
        weightedDist += dist * defaultMultiplier(entry.key);
      }
    }

    if (totalDist == 0) return baselineKmL;
    final factor = weightedDist / totalDist;
    return (baselineKmL * factor).clamp(5.0, 150.0);
  }

  /// Calculates speed-adjusted usable range given current speed and remaining fuel.
  double dynamicUsableKm({
    required double remainingLiters,
    required double currentSpeedKmh,
    required double baselineKmL,
    double reserveL = 0.0,
    double bufferKm = 20.0,
  }) {
    if (!remainingLiters.isFinite || remainingLiters <= 0) return 0.0;
    if (!baselineKmL.isFinite || baselineKmL <= 0) return 0.0;

    final usableLiters = math.max(0.0, remainingLiters - reserveL);
    if (usableLiters <= 0) return 0.0;

    final bin = binForSpeed(currentSpeedKmh);
    final speedMultiplier = defaultMultiplier(bin);
    final adjustedKmL = baselineKmL * speedMultiplier;

    final rawRangeKm = usableLiters * adjustedKmL;
    return math.max(0.0, rawRangeKm - bufferKm);
  }

  Map<String, dynamic> toJson() => {
        for (final entry in _stats.entries) entry.key.name: entry.value.toJson(),
      };

  static SpeedBinConsumptionLearner fromJson(Map<String, dynamic>? json) {
    final learner = SpeedBinConsumptionLearner();
    if (json == null) return learner;

    for (final bin in SpeedBinCategory.values) {
      if (json[bin.name] is Map<String, dynamic>) {
        learner._stats[bin] =
            SpeedBinStats.fromJson(json[bin.name] as Map<String, dynamic>);
      }
    }
    return learner;
  }
}

/// A verified refuel log entry.
class RefuelLogEntry {
  final int timestamp;
  final double distanceKm;
  final double litersFilled;
  final double observedKmL;

  const RefuelLogEntry({
    required this.timestamp,
    required this.distanceKm,
    required this.litersFilled,
    required this.observedKmL,
  });

  Map<String, dynamic> toJson() => {
        'ts': timestamp,
        'km': distanceKm,
        'liters': litersFilled,
        'observedKmL': observedKmL,
      };

  static RefuelLogEntry? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final ts = json['ts'];
    final km = json['km'];
    final l = json['liters'];
    final obs = json['observedKmL'];
    if (ts is! num || km is! num || l is! num || obs is! num) return null;
    return RefuelLogEntry(
      timestamp: ts.toInt(),
      distanceKm: km.toDouble(),
      litersFilled: l.toDouble(),
      observedKmL: obs.toDouble(),
    );
  }
}

/// Exponential Moving Average (EMA) calibrator for motorcycle fuel consumption.
/// Refuels calibrate the baseline mileage smoothly, filtering out fill variance.
class RefuelEmaCalibrator {
  RefuelEmaCalibrator({
    required double initialBaselineKmL,
    this.alpha = 0.25,
  })  : _calibratedMileageKmL = initialBaselineKmL.clamp(5.0, 120.0),
        _initialBaselineKmL = initialBaselineKmL.clamp(5.0, 120.0);

  final double alpha;
  final double _initialBaselineKmL;
  double _calibratedMileageKmL;
  final List<RefuelLogEntry> _logs = [];

  double get calibratedMileageKmL => _calibratedMileageKmL;
  double get initialBaselineKmL => _initialBaselineKmL;
  List<RefuelLogEntry> get logs => List.unmodifiable(_logs);
  int get refuelCount => _logs.length;

  /// Confidence score from 0.5 (initial uncalibrated baseline) to ~0.98+ as logs accumulate.
  double get confidence {
    if (_logs.isEmpty) return 0.5;
    return 1.0 - (0.5 * math.pow(1.0 - alpha, _logs.length));
  }

  /// Logs a refuel event, computes observed km/L, and updates the EMA calibrated mileage.
  bool logRefuel({
    required int timestamp,
    required double distanceKm,
    required double litersFilled,
  }) {
    if (timestamp <= 0) return false;
    if (!distanceKm.isFinite || distanceKm <= 0) return false;
    if (!litersFilled.isFinite || litersFilled <= 0) return false;

    final observedKmL = distanceKm / litersFilled;

    // Outlier rejection: Physical reality bounds for motorcycles (5 km/L to 120 km/L)
    if (!observedKmL.isFinite || observedKmL < 5.0 || observedKmL > 120.0) {
      return false;
    }

    // Apply Exponential Moving Average formula:
    // new_ema = (alpha * observed) + ((1 - alpha) * previous_ema)
    _calibratedMileageKmL =
        (alpha * observedKmL) + ((1.0 - alpha) * _calibratedMileageKmL);
    _calibratedMileageKmL = _calibratedMileageKmL.clamp(5.0, 120.0);

    _logs.add(RefuelLogEntry(
      timestamp: timestamp,
      distanceKm: distanceKm,
      litersFilled: litersFilled,
      observedKmL: observedKmL,
    ));

    return true;
  }

  Map<String, dynamic> toJson() => {
        'initialKmL': _initialBaselineKmL,
        'calibratedKmL': _calibratedMileageKmL,
        'alpha': alpha,
        'logs': _logs.map((l) => l.toJson()).toList(),
      };

  static RefuelEmaCalibrator? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final init = json['initialKmL'];
    final cal = json['calibratedKmL'];
    final a = json['alpha'];
    if (init is! num || cal is! num) return null;

    final calibrator = RefuelEmaCalibrator(
      initialBaselineKmL: init.toDouble(),
      alpha: a is num ? a.toDouble() : 0.25,
    );
    calibrator._calibratedMileageKmL = cal.toDouble();

    if (json['logs'] is List) {
      for (final raw in json['logs'] as List) {
        if (raw is Map<String, dynamic>) {
          final entry = RefuelLogEntry.fromJson(raw);
          if (entry != null) calibrator._logs.add(entry);
        }
      }
    }

    return calibrator;
  }
}
