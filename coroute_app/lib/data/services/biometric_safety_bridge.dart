import 'package:flutter/foundation.dart';
import '../../core/config/feature_gates.dart';

/// Trauma urgency level derived from smartwatch heart rate & pulse telemetry.
enum BiometricTraumaLevel {
  /// Pulse verified in stable range (50-119 BPM).
  stableTrauma,

  /// Acute physiological stress or moderate tachycardia (120-159 BPM).
  elevatedTrauma,

  /// Critical Trauma Level 1: Pulselessness / Asystole (0 BPM) OR Severe Tachycardia (>=160 BPM / Baseline + 60).
  criticalTraumaLevel1,

  /// Watch not worn, disconnected, or sensor unavailable. Standard crash fallback.
  unverified,
}

extension BiometricTraumaLevelExt on BiometricTraumaLevel {
  String get wire {
    switch (this) {
      case BiometricTraumaLevel.stableTrauma:
        return 'STABLE_TRAUMA';
      case BiometricTraumaLevel.elevatedTrauma:
        return 'ELEVATED_TRAUMA';
      case BiometricTraumaLevel.criticalTraumaLevel1:
        return 'CRITICAL_TRAUMA_L1';
      case BiometricTraumaLevel.unverified:
        return 'UNVERIFIED';
    }
  }

  String get label {
    switch (this) {
      case BiometricTraumaLevel.stableTrauma:
        return 'Stable Vitals';
      case BiometricTraumaLevel.elevatedTrauma:
        return 'Elevated Stress';
      case BiometricTraumaLevel.criticalTraumaLevel1:
        return 'Critical Trauma Level 1';
      case BiometricTraumaLevel.unverified:
        return 'Vitals Unverified';
    }
  }
}

/// Underlying wearable sensor platform.
enum BiometricSensorSource {
  appleHealthKit,
  googleHealthConnect,
  bleHeartRateGatt,
  mock,
  none,
}

extension BiometricSensorSourceExt on BiometricSensorSource {
  String get wire {
    switch (this) {
      case BiometricSensorSource.appleHealthKit:
        return 'APPLE_HEALTHKIT';
      case BiometricSensorSource.googleHealthConnect:
        return 'GOOGLE_HEALTH_CONNECT';
      case BiometricSensorSource.bleHeartRateGatt:
        return 'BLE_HEART_RATE_GATT';
      case BiometricSensorSource.mock:
        return 'MOCK';
      case BiometricSensorSource.none:
        return 'NONE';
    }
  }
}

/// Single point in time heart rate measurement.
class BiometricSample {
  final int timestampMs;
  final int bpm;

  const BiometricSample({required this.timestampMs, required this.bpm});

  Map<String, dynamic> toJson() => {
        'ts': timestampMs ~/ 1000,
        'bpm': bpm,
      };

  @override
  String toString() => 'BiometricSample(ts: $timestampMs, bpm: $bpm)';
}

/// Instantaneous biometric telemetry snapshot.
class BiometricSnapshot {
  final int currentBpm;
  final int baselineBpm;
  final BiometricTraumaLevel traumaLevel;
  final BiometricSensorSource source;
  final bool isWatchOnWrist;
  final bool isConnected;
  final List<BiometricSample> history;

  const BiometricSnapshot({
    required this.currentBpm,
    required this.baselineBpm,
    required this.traumaLevel,
    required this.source,
    required this.isWatchOnWrist,
    required this.isConnected,
    this.history = const [],
  });

  factory BiometricSnapshot.initial() => const BiometricSnapshot(
        currentBpm: 0,
        baselineBpm: 0,
        traumaLevel: BiometricTraumaLevel.unverified,
        source: BiometricSensorSource.none,
        isWatchOnWrist: false,
        isConnected: false,
      );

  bool get isCritical => traumaLevel == BiometricTraumaLevel.criticalTraumaLevel1;

  String get traumaDescription {
    switch (traumaLevel) {
      case BiometricTraumaLevel.criticalTraumaLevel1:
        if (currentBpm == 0) {
          return 'Cardiac Arrest / Pulselessness Alert (0 BPM) - Critical Trauma Level 1';
        }
        return 'Severe Post-Impact Tachycardia ($currentBpm BPM) - Critical Trauma Level 1';
      case BiometricTraumaLevel.elevatedTrauma:
        return 'Acute Stress Tachycardia ($currentBpm BPM) - Elevated Trauma';
      case BiometricTraumaLevel.stableTrauma:
        return 'Stable Sinus Rhythm ($currentBpm BPM)';
      case BiometricTraumaLevel.unverified:
        return 'Sensor Unlinked / Disconnected - Standard Dispatch';
    }
  }

  BiometricSnapshot copyWith({
    int? currentBpm,
    int? baselineBpm,
    BiometricTraumaLevel? traumaLevel,
    BiometricSensorSource? source,
    bool? isWatchOnWrist,
    bool? isConnected,
    List<BiometricSample>? history,
  }) =>
      BiometricSnapshot(
        currentBpm: currentBpm ?? this.currentBpm,
        baselineBpm: baselineBpm ?? this.baselineBpm,
        traumaLevel: traumaLevel ?? this.traumaLevel,
        source: source ?? this.source,
        isWatchOnWrist: isWatchOnWrist ?? this.isWatchOnWrist,
        isConnected: isConnected ?? this.isConnected,
        history: history ?? this.history,
      );
}

/// Service bridging smartwatches and BLE pulse sensors into CoRoute's emergency pipeline.
///
/// Collects rolling 5-minute heart rate telemetry, establishes dynamic resting baseline,
/// evaluates cardiac trauma during 15-second crash alarms, and constructs paramedic
/// biometric payloads.
class BiometricSafetyBridge {
  static final BiometricSafetyBridge _instance = BiometricSafetyBridge._internal();
  factory BiometricSafetyBridge() => _instance;

  BiometricSafetyBridge._internal() {
    snapshotNotifier = ValueNotifier<BiometricSnapshot>(BiometricSnapshot.initial());
  }

  /// Rolling buffer configuration.
  static const int maxHistoryWindowMs = 5 * 60 * 1000; // 5 minutes
  static const int maxSamples = 60; // 1 sample every 5s = 60 max

  /// Cardiac threshold constants.
  static const int criticalTachycardiaBpm = 160;
  static const int elevatedStressBpm = 120;
  static const int normalLowBpm = 50;
  static const int asystoleBpm = 0;
  static const int relativeSpikeDeltaBpm = 60;

  late final ValueNotifier<BiometricSnapshot> snapshotNotifier;
  final List<BiometricSample> _samples = [];

  bool _isActive = false;
  bool _isDisposed = false;
  BiometricSensorSource _activeSource = BiometricSensorSource.none;

  bool get isActive => _isActive;
  bool get isDisposed => _isDisposed;
  BiometricSnapshot get snapshot => snapshotNotifier.value;
  List<BiometricSample> get samples => List.unmodifiable(_samples);

  /// Starts monitoring biometrics during an active ride.
  ///
  /// Checks tier entitlement (`Feature.biometricTraumaPulse`).
  void start({BiometricSensorSource source = BiometricSensorSource.bleHeartRateGatt}) {
    if (_isDisposed) return;
    if (!FeatureGates.isUnlocked(Feature.biometricTraumaPulse)) {
      debugPrint('[BiometricSafetyBridge] Skipped start: Plan locked.');
      return;
    }
    _isActive = true;
    _activeSource = source;
    snapshotNotifier.value = snapshotNotifier.value.copyWith(
      source: source,
      isConnected: true,
      isWatchOnWrist: true,
    );
  }

  /// Stops monitoring and clears connection state.
  void stop() {
    if (_isDisposed) return;
    _isActive = false;
    _activeSource = BiometricSensorSource.none;
    snapshotNotifier.value = snapshotNotifier.value.copyWith(
      isConnected: false,
      isWatchOnWrist: false,
    );
  }

  /// Records a real-time heart rate sample.
  void recordSample(int bpm, {int? timestampMs, bool onWrist = true}) {
    if (_isDisposed || !_isActive) return;

    final now = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final clampedBpm = bpm.clamp(0, 250);

    // Append sample
    _samples.add(BiometricSample(timestampMs: now, bpm: clampedBpm));

    // Prune history older than 5 minutes (300,000 ms)
    _pruneOldSamples(now);

    // Compute dynamic baseline
    final baseline = computeBaselineBpm();

    // Determine trauma level
    final trauma = classifyTrauma(clampedBpm, baselineBpm: baseline, watchOnWrist: onWrist);

    snapshotNotifier.value = BiometricSnapshot(
      currentBpm: clampedBpm,
      baselineBpm: baseline,
      traumaLevel: trauma,
      source: _activeSource,
      isWatchOnWrist: onWrist,
      isConnected: true,
      history: List.unmodifiable(_samples),
    );
  }

  /// Computes average baseline BPM over pre-impact history.
  int computeBaselineBpm() {
    if (_samples.isEmpty) return 75; // Nominal human resting baseline
    // Take average of samples excluding 0s
    final validSamples = _samples.where((s) => s.bpm > 30).toList();
    if (validSamples.isEmpty) return 75;
    final sum = validSamples.fold<int>(0, (prev, s) => prev + s.bpm);
    return (sum / validSamples.length).round();
  }

  /// Classifies cardiac trauma level based on impact vitals.
  BiometricTraumaLevel classifyTrauma(
    int bpm, {
    int? baselineBpm,
    double? impactG,
    bool watchOnWrist = true,
  }) {
    if (!watchOnWrist || !_isActive) {
      return BiometricTraumaLevel.unverified;
    }

    final baseline = baselineBpm ?? computeBaselineBpm();

    // Asystole / Pulselessness: BPM is 0 post impact
    if (bpm <= asystoleBpm) {
      return BiometricTraumaLevel.criticalTraumaLevel1;
    }

    // Critical Tachycardia / Acute Hemorrhagic Shock Spike
    if (bpm >= criticalTachycardiaBpm || (bpm >= baseline + relativeSpikeDeltaBpm && bpm >= 140)) {
      return BiometricTraumaLevel.criticalTraumaLevel1;
    }

    // Elevated stress / moderate tachycardia
    if (bpm >= elevatedStressBpm) {
      return BiometricTraumaLevel.elevatedTrauma;
    }

    // Normal sinus range
    if (bpm >= normalLowBpm) {
      return BiometricTraumaLevel.stableTrauma;
    }

    // Extreme bradycardia post trauma (< 50 BPM) is also severe
    return BiometricTraumaLevel.criticalTraumaLevel1;
  }

  /// Prunes samples older than 5 minutes and clamps maximum capacity.
  void _pruneOldSamples(int currentMs) {
    final cutoff = currentMs - maxHistoryWindowMs;
    _samples.removeWhere((s) => s.timestampMs < cutoff);
    if (_samples.length > maxSamples) {
      _samples.removeRange(0, _samples.length - maxSamples);
    }
  }

  /// Packages structured biometric payload for paramedic SOS dispatch.
  Map<String, dynamic> toBiometricPayload({String? bloodGroup}) {
    final snap = snapshot;
    final historyJson = _samples.map((s) => s.toJson()).toList();

    return {
      'traumaLevel': snap.traumaLevel.wire,
      'traumaDescription': snap.traumaDescription,
      'currentBpm': snap.currentBpm,
      'baselineBpm': snap.baselineBpm,
      'sensorSource': snap.source.wire,
      'watchOnWrist': snap.isWatchOnWrist,
      'isConnected': snap.isConnected,
      if (bloodGroup != null && bloodGroup.isNotEmpty) 'bloodGroup': bloodGroup,
      'heartRateHistory': historyJson,
    };
  }

  /// Test hook to simulate incoming wearable pulse.
  @visibleForTesting
  void simulateHeartRate(int bpm, {int? timestampMs, bool onWrist = true, BiometricSensorSource? source}) {
    if (source != null) _activeSource = source;
    _isActive = true;
    recordSample(bpm, timestampMs: timestampMs, onWrist: onWrist);
  }

  /// Clears internal state and resets history.
  @visibleForTesting
  void reset() {
    _samples.clear();
    _isActive = false;
    _activeSource = BiometricSensorSource.none;
    snapshotNotifier.value = BiometricSnapshot.initial();
  }

  /// Disposes notifiers cleanly.
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _isActive = false;
    snapshotNotifier.dispose();
  }
}
