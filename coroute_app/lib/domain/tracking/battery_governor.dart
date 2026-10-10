import '../../core/config/app_config.dart';

/// Multi-stage battery governor operating tiers.
enum BatteryGovernorStage {
  /// Battery > 15%: full telemetry cadence, full social and media capabilities.
  normal,

  /// Battery <= 15%: initial power conservation with hysteresis (clears at >= 20%).
  conserve,

  /// Battery <= 10%: aggressive power conservation, halts non-essential sync.
  extreme,

  /// Battery <= 5%: critical power tier, radio shutoff except emergency beacon.
  lastGasp,
}

/// Last-gasp beacon payload dispatched before potential system power exhaustion.
class LastGaspBeacon {
  final String type;
  final String userId;
  final int batteryLevel;
  final double lat;
  final double lng;
  final double speedKmh;
  final double accuracyM;
  final int timestampMs;
  final BatteryGovernorStage stage;
  final String reason;

  const LastGaspBeacon({
    this.type = 'LAST_GASP_BEACON',
    required this.userId,
    required this.batteryLevel,
    required this.lat,
    required this.lng,
    this.speedKmh = 0.0,
    this.accuracyM = 0.0,
    required this.timestampMs,
    this.stage = BatteryGovernorStage.lastGasp,
    this.reason = 'Battery critical (<= 5%), phone entering last-gasp survival mode',
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type,
        'userId': userId,
        'batteryLevel': batteryLevel,
        'lat': lat,
        'lng': lng,
        'speedKmh': speedKmh,
        'accuracyM': accuracyM,
        'timestampMs': timestampMs,
        'stage': stage.name,
        'reason': reason,
      };
}

/// Governor managing multi-stage power throttling and distress beacon dispatch.
class BatteryGovernor {
  BatteryGovernorStage _stage = BatteryGovernorStage.normal;
  bool _lastGaspBeaconDispatched = false;
  int _lastReportedLevel = 100;
  bool _isCharging = false;

  void Function(LastGaspBeacon beacon)? onLastGaspBeacon;

  BatteryGovernorStage get stage => _stage;
  bool get isConserving => _stage != BatteryGovernorStage.normal;
  bool get isExtreme => _stage == BatteryGovernorStage.extreme || _stage == BatteryGovernorStage.lastGasp;
  bool get isLastGasp => _stage == BatteryGovernorStage.lastGasp;
  bool get lastGaspBeaconDispatched => _lastGaspBeaconDispatched;
  int get lastReportedLevel => _lastReportedLevel;
  bool get isCharging => _isCharging;

  /// Updates battery status and executes tiered governor transitions.
  BatteryGovernorStage updateBattery(
    int percent, {
    required bool charging,
    String? userId,
    double? lat,
    double? lng,
    double speedKmh = 0.0,
    double accuracyM = 0.0,
    int? timestampMs,
  }) {
    if (percent < 0 || percent > 100) {
      return _stage;
    }

    _lastReportedLevel = percent;
    _isCharging = charging;

    if (charging) {
      _stage = BatteryGovernorStage.normal;
      _lastGaspBeaconDispatched = false;
      return _stage;
    }

    if (percent <= 5) {
      _stage = BatteryGovernorStage.lastGasp;
      if (!_lastGaspBeaconDispatched) {
        _lastGaspBeaconDispatched = true;
        if (userId != null && lat != null && lng != null) {
          final beacon = LastGaspBeacon(
            userId: userId,
            batteryLevel: percent,
            lat: lat,
            lng: lng,
            speedKmh: speedKmh,
            accuracyM: accuracyM,
            timestampMs: timestampMs ?? DateTime.now().millisecondsSinceEpoch,
          );
          onLastGaspBeacon?.call(beacon);
        }
      }
      return _stage;
    }

    if (percent > 5 && _lastGaspBeaconDispatched) {
      _lastGaspBeaconDispatched = false;
    }

    if (percent <= 10) {
      _stage = BatteryGovernorStage.extreme;
      return _stage;
    }

    if (percent <= 15) {
      if (_stage == BatteryGovernorStage.extreme) {
        // Hysteresis holds extreme mode until above 15%
        _stage = BatteryGovernorStage.extreme;
      } else {
        _stage = BatteryGovernorStage.conserve;
      }
      return _stage;
    }

    // Above 15%
    if (_stage == BatteryGovernorStage.extreme) {
      // Exiting extreme mode moves to conserve up to 20%
      _stage = BatteryGovernorStage.conserve;
      return _stage;
    }

    if (_stage == BatteryGovernorStage.conserve) {
      // Hysteresis keeps conserve mode active below 20%
      if (percent >= 20) {
        _stage = BatteryGovernorStage.normal;
      }
      return _stage;
    }

    _stage = BatteryGovernorStage.normal;
    return _stage;
  }

  /// Calculates telemetry reporting interval according to stage and emergency state.
  Duration telemetryInterval({required bool moving, required bool critical}) {
    if (critical) {
      return AppConfig.telemetryMinInterval;
    }

    switch (_stage) {
      case BatteryGovernorStage.normal:
        return moving ? AppConfig.telemetryMinInterval : AppConfig.telemetryIdleInterval;
      case BatteryGovernorStage.conserve:
        return moving ? const Duration(seconds: 5) : AppConfig.telemetryIdleInterval;
      case BatteryGovernorStage.extreme:
        return moving ? const Duration(seconds: 10) : const Duration(seconds: 60);
      case BatteryGovernorStage.lastGasp:
        return moving ? const Duration(seconds: 30) : const Duration(seconds: 120);
    }
  }

  /// Notification update interval according to current governor stage.
  Duration notificationInterval({required bool critical}) {
    if (critical) {
      return const Duration(seconds: 10);
    }

    switch (_stage) {
      case BatteryGovernorStage.normal:
        return const Duration(seconds: 10);
      case BatteryGovernorStage.conserve:
        return const Duration(seconds: 20);
      case BatteryGovernorStage.extreme:
        return const Duration(seconds: 30);
      case BatteryGovernorStage.lastGasp:
        return const Duration(seconds: 60);
    }
  }

  /// Determines whether non-essential background tile prefetching is allowed.
  bool get isTilePrefetchAllowed => _stage == BatteryGovernorStage.normal || _stage == BatteryGovernorStage.conserve;

  /// Determines whether background social discovery scans are permitted.
  bool isSocialDiscoveryAllowed({required bool hasActiveSafetyAlert}) {
    if (hasActiveSafetyAlert) return false;
    return _stage == BatteryGovernorStage.normal;
  }

  /// Explicitly dispatches a last-gasp beacon if in the last-gasp stage.
  LastGaspBeacon? dispatchLastGaspBeacon({
    required String userId,
    required double lat,
    required double lng,
    double speedKmh = 0.0,
    double accuracyM = 0.0,
    int? timestampMs,
  }) {
    if (_stage != BatteryGovernorStage.lastGasp) {
      return null;
    }
    final beacon = LastGaspBeacon(
      userId: userId,
      batteryLevel: _lastReportedLevel,
      lat: lat,
      lng: lng,
      speedKmh: speedKmh,
      accuracyM: accuracyM,
      timestampMs: timestampMs ?? DateTime.now().millisecondsSinceEpoch,
    );
    _lastGaspBeaconDispatched = true;
    onLastGaspBeacon?.call(beacon);
    return beacon;
  }
}
