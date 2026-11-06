import 'dart:convert';
import 'dart:math' as math;

/// Single recorded battery telemetry sample point.
class BatteryMeasurement {
  final int timestampMs;
  final int batteryLevel; // 0 - 100
  final bool isCharging;
  final bool isMoving;
  final double speedKmh;

  const BatteryMeasurement({
    required this.timestampMs,
    required this.batteryLevel,
    required this.isCharging,
    required this.isMoving,
    this.speedKmh = 0.0,
  });

  Map<String, dynamic> toJson() => {
        'timestampMs': timestampMs,
        'batteryLevel': batteryLevel,
        'isCharging': isCharging,
        'isMoving': isMoving,
        'speedKmh': speedKmh,
      };

  factory BatteryMeasurement.fromJson(Map<String, dynamic> json) => BatteryMeasurement(
        timestampMs: (json['timestampMs'] as num).toInt(),
        batteryLevel: (json['batteryLevel'] as num).toInt(),
        isCharging: json['isCharging'] == true,
        isMoving: json['isMoving'] == true,
        speedKmh: (json['speedKmh'] as num?)?.toDouble() ?? 0.0,
      );
}

/// Hourly aggregated battery metrics per riding hour.
class HourlyBatteryMetric {
  final int hourIndex; // 1, 2, 3...
  final int startBatteryLevel;
  final int endBatteryLevel;
  final int drainPercent;
  final int ridingDurationMs;
  final double averageSpeedKmh;

  const HourlyBatteryMetric({
    required this.hourIndex,
    required this.startBatteryLevel,
    required this.endBatteryLevel,
    required this.drainPercent,
    required this.ridingDurationMs,
    required this.averageSpeedKmh,
  });

  Map<String, dynamic> toJson() => {
        'hourIndex': hourIndex,
        'startBatteryLevel': startBatteryLevel,
        'endBatteryLevel': endBatteryLevel,
        'drainPercent': drainPercent,
        'ridingDurationMs': ridingDurationMs,
        'averageSpeedKmh': averageSpeedKmh,
      };

  factory HourlyBatteryMetric.fromJson(Map<String, dynamic> json) => HourlyBatteryMetric(
        hourIndex: (json['hourIndex'] as num).toInt(),
        startBatteryLevel: (json['startBatteryLevel'] as num).toInt(),
        endBatteryLevel: (json['endBatteryLevel'] as num).toInt(),
        drainPercent: (json['drainPercent'] as num).toInt(),
        ridingDurationMs: (json['ridingDurationMs'] as num).toInt(),
        averageSpeedKmh: (json['averageSpeedKmh'] as num?)?.toDouble() ?? 0.0,
      );
}

/// Performance monitor that tracks battery consumption per riding hour,
/// computes real-time battery drain rates, and projects remaining ride time.
class BatteryPerformanceMonitor {
  static const int minRidingMsForEstimate = 300000; // 5 minutes minimum for accurate rate calculation
  static const double defaultEstimatedDrainPerHour = 6.0; // 6% per hour baseline

  final List<BatteryMeasurement> _samples = [];
  final List<HourlyBatteryMetric> _hourlyMetrics = [];

  int _totalRidingDurationMs = 0;
  int _totalRidingDrainPct = 0;
  int? _lastRidingSampleTimeMs;
  int? _lastRidingBatteryLevel;
  int? _currentHourStartTimeMs;
  int? _currentHourStartLevel;
  int _currentHourRidingDurationMs = 0;
  double _currentHourSpeedSum = 0;
  int _currentHourSpeedCount = 0;

  List<BatteryMeasurement> get samples => List.unmodifiable(_samples);
  List<HourlyBatteryMetric> get hourlyMetrics => List.unmodifiable(_hourlyMetrics);
  int get totalRidingDurationMs => _totalRidingDurationMs;
  double get totalRidingHours => _totalRidingDurationMs / 3600000.0;
  int get totalRidingDrainPct => _totalRidingDrainPct;

  int get currentBatteryLevel => _samples.isNotEmpty ? _samples.last.batteryLevel : 100;
  bool get isCharging => _samples.isNotEmpty ? _samples.last.isCharging : false;

  /// Calculated battery drain percentage per 1 hour of riding.
  /// If riding time is less than 5 minutes, returns 0.0 or baseline if requested.
  double get drainPerHour {
    if (_totalRidingDurationMs < minRidingMsForEstimate || _totalRidingDrainPct <= 0) {
      return 0.0;
    }
    final hours = _totalRidingDurationMs / 3600000.0;
    return (_totalRidingDrainPct / hours).clamp(0.0, 100.0);
  }

  /// Estimated riding hours remaining on current battery level at current drain rate.
  /// Returns 0.0 if not draining or charging.
  double get estimatedHoursRemaining {
    if (isCharging) return double.infinity;
    final rate = drainPerHour;
    final effectiveRate = rate > 0 ? rate : defaultEstimatedDrainPerHour;
    return (currentBatteryLevel / effectiveRate).clamp(0.0, 999.0);
  }

  /// Records a new battery measurement sample.
  void recordSample({
    required int batteryLevel,
    required bool isCharging,
    required bool isMoving,
    double speedKmh = 0.0,
    int? timestampMs,
  }) {
    final now = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final sample = BatteryMeasurement(
      timestampMs: now,
      batteryLevel: batteryLevel.clamp(0, 100),
      isCharging: isCharging,
      isMoving: isMoving,
      speedKmh: math.max(0.0, speedKmh),
    );
    _samples.add(sample);
    if (_samples.length > 500) {
      _samples.removeAt(0); // Bounded memory window
    }

    if (isCharging) {
      // Charging pauses drain accrual
      _lastRidingSampleTimeMs = null;
      _lastRidingBatteryLevel = null;
      return;
    }

    // Only moving/riding time accrues toward riding hour calculations
    if (isMoving) {
      if (_lastRidingSampleTimeMs != null && _lastRidingBatteryLevel != null) {
        final deltaMs = now - _lastRidingSampleTimeMs!;
        if (deltaMs > 0 && deltaMs < 120000) {
          // Continuous ride window (under 2 minutes between samples)
          _totalRidingDurationMs += deltaMs;
          _currentHourRidingDurationMs += deltaMs;

          if (_lastRidingBatteryLevel! > batteryLevel) {
            final drop = _lastRidingBatteryLevel! - batteryLevel;
            _totalRidingDrainPct += drop;
          }
        }
      }

      _lastRidingSampleTimeMs = now;
      _lastRidingBatteryLevel = batteryLevel;

      _currentHourStartTimeMs ??= now;
      _currentHourStartLevel ??= batteryLevel;
      _currentHourSpeedSum += speedKmh;
      _currentHourSpeedCount++;

      // Check if an hour of active riding duration has completed
      if (_currentHourRidingDurationMs >= 3600000) {
        final hourIdx = _hourlyMetrics.length + 1;
        final startLvl = _currentHourStartLevel ?? batteryLevel;
        final drain = math.max(0, startLvl - batteryLevel);
        final avgSpd = _currentHourSpeedCount > 0 ? _currentHourSpeedSum / _currentHourSpeedCount : speedKmh;

        _hourlyMetrics.add(HourlyBatteryMetric(
          hourIndex: hourIdx,
          startBatteryLevel: startLvl,
          endBatteryLevel: batteryLevel,
          drainPercent: drain,
          ridingDurationMs: _currentHourRidingDurationMs,
          averageSpeedKmh: avgSpd,
        ));

        // Reset for next hour
        _currentHourStartTimeMs = now;
        _currentHourStartLevel = batteryLevel;
        _currentHourRidingDurationMs = 0;
        _currentHourSpeedSum = 0;
        _currentHourSpeedCount = 0;
      }
    } else {
      // Stopped/stationary: reset last riding sample timestamp so pause duration is not counted as riding
      _lastRidingSampleTimeMs = null;
    }
  }

  /// Serializes monitor state to JSON string for persistent storage.
  String toJsonString() {
    final recentSamples = _samples.length > 50 ? _samples.sublist(_samples.length - 50) : _samples;
    return jsonEncode({
      'totalRidingDurationMs': _totalRidingDurationMs,
      'totalRidingDrainPct': _totalRidingDrainPct,
      'hourlyMetrics': _hourlyMetrics.map((m) => m.toJson()).toList(),
      'samples': recentSamples.map((s) => s.toJson()).toList(),
    });
  }

  /// Restores monitor state from persisted JSON string.
  static BatteryPerformanceMonitor fromJsonString(String? raw) {
    final monitor = BatteryPerformanceMonitor();
    if (raw == null || raw.isEmpty) return monitor;
    try {
      final map = jsonDecode(raw);
      if (map is Map) {
        monitor._totalRidingDurationMs = (map['totalRidingDurationMs'] as num?)?.toInt() ?? 0;
        monitor._totalRidingDrainPct = (map['totalRidingDrainPct'] as num?)?.toInt() ?? 0;
        if (map['hourlyMetrics'] is List) {
          for (final item in map['hourlyMetrics']) {
            if (item is Map) {
              monitor._hourlyMetrics.add(HourlyBatteryMetric.fromJson(Map<String, dynamic>.from(item)));
            }
          }
        }
        if (map['samples'] is List) {
          for (final item in map['samples']) {
            if (item is Map) {
              monitor._samples.add(BatteryMeasurement.fromJson(Map<String, dynamic>.from(item)));
            }
          }
        }
      }
    } catch (_) {}
    return monitor;
  }

  /// Clears all measurements and resets metrics.
  void reset() {
    _samples.clear();
    _hourlyMetrics.clear();
    _totalRidingDurationMs = 0;
    _totalRidingDrainPct = 0;
    _lastRidingSampleTimeMs = null;
    _lastRidingBatteryLevel = null;
    _currentHourStartTimeMs = null;
    _currentHourStartLevel = null;
    _currentHourRidingDurationMs = 0;
    _currentHourSpeedSum = 0;
    _currentHourSpeedCount = 0;
  }
}

