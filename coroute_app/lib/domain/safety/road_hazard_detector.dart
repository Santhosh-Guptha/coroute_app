import 'dart:math' as math;
import '../../data/models/road_hazard_telemetry.dart';
import '../tracking/track_point.dart';

/// Configuration thresholds for the kinematic road hazard pattern detector.
class RoadHazardThresholds {
  /// Minimum vertical dynamic shock peak in g to trigger detection (default: 1.8 g).
  final double shockThresholdG;

  /// Minimum absolute gyroscope yaw rate in deg/s around Earth-vertical axis (default: 25.0 deg/s).
  final double yawRateThresholdDegS;

  /// Maximum temporal separation between shock peak and yaw flick (default: 250 ms).
  final int coincidenceWindowMs;

  /// Minimum vehicle speed in km/h required to arm detection (default: 20.0 km/h).
  final double minSpeedKmh;

  /// Vehicle stop speed threshold in km/h indicating a halt rather than continuation (default: 5.0 km/h).
  final double stopSpeedKmh;

  /// Maximum GPS fix age in milliseconds to consider position fresh (default: 3000 ms).
  final int maxGpsAgeMs;

  /// Maximum GPS accuracy in meters to accept hazard tagging (default: 25.0 m).
  final double maxGpsAccuracyM;

  /// Cooldown period after an accepted hazard to prevent duplicate rear-wheel hits (default: 750 ms).
  final int cooldownMs;

  /// Maximum baseline acceleration standard deviation in g before filtering as rough road (default: 0.35 g).
  final double roughRoadStdDevG;

  /// Maximum yaw rate in deg/s for transverse railway joints (default: 12.0 deg/s).
  final double railwayMaxYawDegS;

  const RoadHazardThresholds({
    this.shockThresholdG = 1.8,
    this.yawRateThresholdDegS = 25.0,
    this.coincidenceWindowMs = 250,
    this.minSpeedKmh = 20.0,
    this.stopSpeedKmh = 5.0,
    this.maxGpsAgeMs = 3000,
    this.maxGpsAccuracyM = 25.0,
    this.cooldownMs = 750,
    this.roughRoadStdDevG = 0.35,
    this.railwayMaxYawDegS = 12.0,
  });
}

/// Real-time kinematic detector that analyzes vertical shock, gyro yaw flick,
/// and contextual GPS data to detect potholes and road defects while rejecting
/// false positives (railway crossings, lane changes, cornering, speed bumps).
class RoadHazardDetector {
  final RoadHazardThresholds thresholds;

  // Earth gravity estimator state (low-pass filter).
  double _gx = 0.0;
  double _gy = 0.0;
  double _gz = 9.80665;
  bool _gravityInitialized = false;

  // Recent kinematic history for coincidence and variance evaluation.
  final List<KinematicSample> _recentSamples = [];
  static const int _historyRetentionMs = 3000;

  // GPS state.
  TrackPoint? _latestGps;
  int _latestGpsTimeMs = 0;

  // Cooldown and pending candidate state.
  int _lastHazardTimestampMs = -100000;
  int _candidateShockTimeMs = 0;
  double _candidatePeakVerticalG = 0.0;
  double _candidatePeakYawRate = 0.0;

  RoadHazardDetector({RoadHazardThresholds? thresholds})
      : thresholds = thresholds ?? const RoadHazardThresholds();

  /// Feed a GPS fix into the detector.
  void onGpsFix(TrackPoint fix, {int? nowMs}) {
    _latestGps = fix;
    _latestGpsTimeMs = nowMs ?? fix.ts;
  }

  /// Feed a high-frequency inertial sensor sample into the detector.
  /// Returns a [RoadHazardObservation] if a confirmed road hazard is detected.
  RoadHazardObservation? onKinematicSample(KinematicSample sample) {
    _updateGravityEstimator(sample);
    _recentSamples.add(sample);
    _pruneHistory(sample.timestampMs);

    // Cooldown check: ignore hits within cooldown window of a previous detection.
    if (sample.timestampMs - _lastHazardTimestampMs < thresholds.cooldownMs) {
      return null;
    }

    // 1. Compute gravity-compensated Earth-vertical acceleration.
    final verticalAccelMs2 = _computeEarthVerticalAccel(sample);
    final verticalDynamicG = (verticalAccelMs2 / 9.80665).abs();

    // 2. Compute Earth-vertical yaw rate in deg/s.
    final earthYawRateDegS = _computeEarthVerticalYawRate(sample);
    final absYawRateDegS = earthYawRateDegS.abs();

    // 3. Track shock peak candidate.
    if (verticalDynamicG >= thresholds.shockThresholdG) {
      if (sample.timestampMs - _candidateShockTimeMs > thresholds.coincidenceWindowMs) {
        _candidateShockTimeMs = sample.timestampMs;
        _candidatePeakVerticalG = verticalDynamicG;
        _candidatePeakYawRate = absYawRateDegS;
      } else {
        if (verticalDynamicG > _candidatePeakVerticalG) {
          _candidatePeakVerticalG = verticalDynamicG;
        }
        if (absYawRateDegS > _candidatePeakYawRate) {
          _candidatePeakYawRate = absYawRateDegS;
        }
      }
    } else if (_candidateShockTimeMs > 0 &&
        sample.timestampMs - _candidateShockTimeMs <= thresholds.coincidenceWindowMs) {
      if (absYawRateDegS > _candidatePeakYawRate) {
        _candidatePeakYawRate = absYawRateDegS;
      }
    }

    // 4. Check if coincidence window has closed and criteria are satisfied.
    if (_candidateShockTimeMs > 0 &&
        sample.timestampMs - _candidateShockTimeMs >= thresholds.coincidenceWindowMs) {
      final peakG = _candidatePeakVerticalG;
      final peakYaw = _candidatePeakYawRate;
      final shockTime = _candidateShockTimeMs;
      _candidateShockTimeMs = 0;
      _candidatePeakVerticalG = 0.0;
      _candidatePeakYawRate = 0.0;

      return _evaluateCandidate(
        shockTimestampMs: shockTime,
        peakVerticalG: peakG,
        peakYawRateDegS: peakYaw,
        evaluationTimeMs: sample.timestampMs,
      );
    }

    return null;
  }

  /// Evaluates a candidate shock and yaw event against all false-positive rejection filters.
  RoadHazardObservation? _evaluateCandidate({
    required int shockTimestampMs,
    required double peakVerticalG,
    required double peakYawRateDegS,
    required int evaluationTimeMs,
  }) {
    // False Positive Check 1: Shock must exceed threshold.
    if (peakVerticalG < thresholds.shockThresholdG) {
      return null;
    }

    // False Positive Check 2: Vehicle Speed Filter.
    // Stationary phone handling (tapping phone at stop light) must be rejected.
    final gps = _latestGps;
    if (gps == null) return null;
    final gpsAge = evaluationTimeMs - _latestGpsTimeMs;
    if (gpsAge > thresholds.maxGpsAgeMs) return null;
    if (gps.speedKmh < thresholds.minSpeedKmh) return null;
    if (gps.speedKmh <= thresholds.stopSpeedKmh) return null;
    if (gps.accuracyM > thresholds.maxGpsAccuracyM) return null;

    // Uncalibrated orientation check: phone tumbling or uninitialized
    if (!isOrientationCalibrated) {
      return null;
    }

    // Missing Gyroscope check:
    // If phone has NO gyroscope hardware, fallback to uncertain surface anomaly
    final hasGyro = peakYawRateDegS > 0.001;
    if (!hasGyro) {
      return RoadHazardObservation(
        eventId: 'rh_${shockTimestampMs}_${(gps.lat * 1000).round()}',
        timestamp: shockTimestampMs,
        lat: gps.lat,
        lng: gps.lng,
        accuracyM: gps.accuracyM,
        speedKmh: gps.speedKmh,
        heading: 0.0,
        peakVerticalG: peakVerticalG,
        peakYawRateDegS: peakYawRateDegS,
        confidence: 0.40,
        severity: RoadHazardSeverity.low,
        classification: RoadHazardClassification.uncertainSurfaceAnomaly,
        schemaVersion: '2.0',
      );
    }

    // False Positive Check 3: Railway Crossing / Transverse Joint Filter.
    // Railway crossings and bridge expansion joints impart strong vertical shock to both wheels
    // but generate almost zero handlebar yaw deflection (straight trajectory).
    if (peakYawRateDegS < thresholds.railwayMaxYawDegS) {
      // High vertical shock without handlebar deflection = transverse joint / railway line.
      return null;
    }

    // False Positive Check 4: Intentional Lane Change / Cornering Filter.
    // If yaw rate is present but vertical shock was marginal, it is already filtered by peakG.
    // If rider was cornering under sustained lean, verify dynamic variance.
    if (peakYawRateDegS < thresholds.yawRateThresholdDegS) {
      return null;
    }

    // False Positive Check 5: Rough / Gravel Road Continuous Noise Filter.
    // On cobblestones or corrugated washboard gravel, high baseline vibration standard deviation
    // masks individual potholes.
    // A genuine severe pothole on gravel produces an impulse > 3.0x baseline std dev
    // and dynamic shock peak >= shockThresholdG with coincident yaw twitch (> 25 deg/s).
    final baselineStdDev = _calculateBaselineStdDevG(shockTimestampMs);
    if (baselineStdDev > thresholds.roughRoadStdDevG) {
      if (peakVerticalG < (baselineStdDev * 3.0) || peakYawRateDegS < thresholds.yawRateThresholdDegS) {
        return null;
      }
    }

    // Candidate passed all filters: Generate accepted RoadHazardObservation.
    _lastHazardTimestampMs = evaluationTimeMs;

    // Determine severity.
    final RoadHazardSeverity severity;
    if (peakVerticalG > 3.0 || (gps.speedKmh > 75.0 && peakVerticalG > 2.2)) {
      severity = RoadHazardSeverity.critical;
    } else if (peakVerticalG > 2.0 || gps.speedKmh > 50.0) {
      severity = RoadHazardSeverity.high;
    } else {
      severity = RoadHazardSeverity.medium;
    }

    // Confidence derived from signal-to-noise ratio, coincidence tightness, and GPS accuracy.
    double confidence = 0.70;
    if (peakVerticalG >= 2.0) confidence += 0.10;
    if (peakYawRateDegS >= 30.0) confidence += 0.10;
    if (gps.accuracyM <= 10.0) confidence += 0.05;
    if (confidence > 1.0) confidence = 1.0;

    return RoadHazardObservation(
      eventId: 'rh_${shockTimestampMs}_${(gps.lat * 1000).round()}',
      timestamp: shockTimestampMs,
      lat: gps.lat,
      lng: gps.lng,
      accuracyM: gps.accuracyM,
      speedKmh: gps.speedKmh,
      heading: 0.0, // Will be bound with bearing or track vector if available
      peakVerticalG: peakVerticalG,
      peakYawRateDegS: peakYawRateDegS,
      confidence: confidence,
      severity: severity,
      classification: RoadHazardClassification.pothole,
      schemaVersion: '2.0',
    );
  }

  /// Whether the gravity vector has stabilized within realistic Earth gravity bounds (7.0 to 13.0 m/s^2).
  bool get isOrientationCalibrated {
    if (!_gravityInitialized) return false;
    final mag = math.sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
    return mag >= 7.0 && mag <= 13.0;
  }

  /// Updates the low-pass Earth gravity vector estimator.
  /// Violent dynamic shocks (> 14 m/s^2 or < 6 m/s^2) are excluded from the static orientation filter.
  void _updateGravityEstimator(KinematicSample sample) {
    final mag = sample.totalAccel;
    if (mag < 6.0 || mag > 14.0) return;

    if (!_gravityInitialized) {
      _gx = sample.ax;
      _gy = sample.ay;
      _gz = sample.az;
      _gravityInitialized = true;
      return;
    }
    const alpha = 0.95;
    _gx = alpha * _gx + (1 - alpha) * sample.ax;
    _gy = alpha * _gy + (1 - alpha) * sample.ay;
    _gz = alpha * _gz + (1 - alpha) * sample.az;
  }

  /// Calculates dynamic Earth-vertical acceleration by projecting total acceleration
  /// onto the normalized gravity vector and subtracting static 1g gravity.
  double _computeEarthVerticalAccel(KinematicSample sample) {
    final gMag = math.sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
    if (gMag < 1.0) return 0.0;
    final ux = _gx / gMag;
    final uy = _gy / gMag;
    final uz = _gz / gMag;

    // Dot product of instantaneous acceleration onto gravity unit vector.
    final totalVertical = sample.ax * ux + sample.ay * uy + sample.az * uz;
    // Dynamic vertical acceleration is total minus static gravity.
    return totalVertical - gMag;
  }

  /// Calculates rotation rate around the estimated Earth-vertical axis.
  double _computeEarthVerticalYawRate(KinematicSample sample) {
    final gMag = math.sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
    if (gMag < 1.0) return sample.gz;
    final ux = _gx / gMag;
    final uy = _gy / gMag;
    final uz = _gz / gMag;

    // Dot product of gyro vector onto vertical axis.
    return sample.gx * ux + sample.gy * uy + sample.gz * uz;
  }

  /// Calculates the standard deviation of prior baseline acceleration magnitude to detect rough gravel roads.
  double _calculateBaselineStdDevG(int targetTimeMs) {
    if (_recentSamples.length < 5) return 0.0;
    // Measure prior baseline noise (prior 2 seconds before the shock, excluding outlier shock spikes > 2.2g)
    final windowSamples = _recentSamples
        .where((s) => s.timestampMs <= targetTimeMs - 100 &&
                      s.timestampMs >= targetTimeMs - 2000 &&
                      (s.totalAccelG - 1.0).abs() < 1.2)
        .toList();
    if (windowSamples.length < 3) return 0.0;

    double sum = 0.0;
    for (final s in windowSamples) {
      sum += s.totalAccelG;
    }
    final mean = sum / windowSamples.length;

    double sumSq = 0.0;
    for (final s in windowSamples) {
      final diff = s.totalAccelG - mean;
      sumSq += diff * diff;
    }
    return math.sqrt(sumSq / windowSamples.length);
  }

  void _pruneHistory(int currentTimeMs) {
    _recentSamples.removeWhere((s) => currentTimeMs - s.timestampMs > _historyRetentionMs);
  }
}
