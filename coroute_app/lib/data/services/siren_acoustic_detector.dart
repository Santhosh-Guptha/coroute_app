import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, AppLifecycleState;
import 'package:record/record.dart';
import '../../core/config/feature_gates.dart';
import '../../domain/audio/dsp_core.dart';
import '../../domain/audio/sound_alert_policy.dart';
import '../../domain/audio/sound_awareness_engine.dart';
import '../../domain/diag/diag_log.dart'; // 3.55 diagnostics log (numbers only, never audio)
import 'feature_flags_service.dart';
import 'intercom_service.dart';
import 'ride_mic_hub.dart';

/// Identified siren modulation pattern.
enum SirenPatternType {
  /// Sinusoidal frequency modulation between ~700 Hz and ~1500 Hz (3.5s - 6.0s period).
  wail,

  /// Rapid saw/triangular frequency modulation between ~700 Hz and ~1500 Hz (0.2s - 0.5s period).
  yelp,

  /// Alternating high/low discrete tones (~700 Hz <-> ~950 Hz, 0.5s - 1.0s dwell).
  twoTone,

  /// Generic or unclassified periodic siren signature.
  unknown,
}

/// Operational state of the siren acoustic detector.
enum SirenDetectorState {
  /// Listening, no siren detected.
  inactive,

  /// Potential modulation signature accumulating confidence across frames.
  candidate,

  /// Confirmed emergency siren detected; alert and audio ducking active.
  detected,

  /// Siren ceased; maintaining alert and ducking for a hysteresis cooldown window.
  cooldown,

  /// Microphone unavailable, permission denied, or audio session interrupted.
  unavailable,
}

/// Data payload emitted upon emergency siren detection.
class SirenDetectionEvent {
  final DateTime timestamp;
  final double confidence; // 0.0 .. 1.0
  final SirenPatternType pattern;
  final double dominantFrequencyHz;
  final bool directionKnown;
  final bool approachingFromBehind;

  /// 3.55 sound awareness (ride mic hub path; null / unknown on the legacy path).
  final EmergencyVehicleKind kind;
  final bool kindConfident;
  final SirenTrend trend;
  final SoundNearness? nearness;

  const SirenDetectionEvent({
    required this.timestamp,
    required this.confidence,
    required this.pattern,
    required this.dominantFrequencyHz,
    this.directionKnown = false,
    this.approachingFromBehind = false,
    this.kind = EmergencyVehicleKind.unknown,
    this.kindConfident = false,
    this.trend = SirenTrend.unknown,
    this.nearness,
  });

  /// From the 3.55 engine's observation. "Approaching" is a loudness / Doppler trend, not a
  /// direction: one phone microphone cannot tell behind from ahead, so directionKnown stays false.
  factory SirenDetectionEvent.fromObservation(SirenObservation o) => SirenDetectionEvent(
        timestamp: DateTime.now(),
        confidence: o.confidence,
        pattern: switch (o.pattern) {
          SirenPattern.wail => SirenPatternType.wail,
          SirenPattern.yelp => SirenPatternType.yelp,
          SirenPattern.hiLo => SirenPatternType.twoTone,
          SirenPattern.unknown => SirenPatternType.unknown,
        },
        dominantFrequencyHz: o.centreHz,
        kind: o.kind,
        kindConfident: o.kindConfident,
        trend: o.trend,
        nearness: o.nearness,
      );

  /// 3.55: short trend / nearness / kind words for the cockpit card ('' on the legacy path).
  String get detailText {
    final parts = <String>[
      if (trend == SirenTrend.approaching) 'Approaching',
      if (trend == SirenTrend.movingAway) 'Moving away',
      if (nearness == SoundNearness.veryNear) 'Very close',
      if (nearness == SoundNearness.near) 'Close',
      if (nearness == SoundNearness.far) 'Far',
    ];
    return parts.join(' · ');
  }

  /// Displays the required alert text based on directional verification.
  // 3.55 naming: never "behind" (one mic cannot tell direction); "give way" instead of "yield".
  // 3.55: the kind when the engine is confident ("AMBULANCE SIREN"), else "EMERGENCY VEHICLE".
  String get alertText => switch (kindConfident ? kind : EmergencyVehicleKind.unknown) {
        EmergencyVehicleKind.ambulance => '🚨 AMBULANCE SIREN · GIVE WAY',
        EmergencyVehicleKind.police => '🚨 POLICE SIREN · GIVE WAY',
        EmergencyVehicleKind.fire => '🚨 FIRE ENGINE SIREN · GIVE WAY',
        EmergencyVehicleKind.unknown => '🚨 EMERGENCY VEHICLE SIREN · GIVE WAY',
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SirenDetectionEvent &&
          runtimeType == other.runtimeType &&
          confidence == other.confidence &&
          pattern == other.pattern &&
          dominantFrequencyHz == other.dominantFrequencyHz &&
          directionKnown == other.directionKnown &&
          approachingFromBehind == other.approachingFromBehind &&
          kind == other.kind &&
          trend == other.trend &&
          nearness == other.nearness;

  @override
  int get hashCode => Object.hash(
        confidence,
        pattern,
        dominantFrequencyHz,
        directionKnown,
        approachingFromBehind,
        kind,
        trend,
        nearness,
      );

  @override
  String toString() =>
      'SirenDetectionEvent($pattern, conf: ${(confidence * 100).toStringAsFixed(1)}%, freq: ${dominantFrequencyHz.round()}Hz, behind: $approachingFromBehind)';
}

/// A frame observation capturing instantaneous frequency and energy.
class _AcousticFrame {
  final double timeSec;
  final double peakFreqHz;
  final double peakToAvgRatio;
  final double inBandRatio;
  final double rms;
  final bool isTonal;

  const _AcousticFrame({
    required this.timeSec,
    required this.peakFreqHz,
    required this.peakToAvgRatio,
    required this.inBandRatio,
    required this.rms,
    required this.isTonal,
  });
}

/// Real-time streaming acoustic classifier using Goertzel spectral analysis.
///
/// Pure Dart DSP with zero native library dependencies.
/// Processes 16 kHz 16-bit mono PCM streams in 512-sample (32 ms) analysis windows.
class SirenClassifierEngine {
  static const int sampleRate = 16000;
  static const int windowSize = 512; // 32 ms at 16 kHz
  static const double minSirenFreq = 600.0;
  static const double maxSirenFreq = 1600.0;
  static const double binResolution = sampleRate / windowSize; // 31.25 Hz

  // Precomputed Goertzel coefficients for 33 bins from ~600 Hz (bin 19) to ~1600 Hz (bin 51).
  static final int minBin = (minSirenFreq / binResolution).round(); // 19
  static final int maxBin = (maxSirenFreq / binResolution).round(); // 51
  static final int numBins = maxBin - minBin + 1; // 33 bins

  static final Float64List _goertzelCoeffs = _precomputeCoeffs();
  static final Float64List _hanningWindow = _precomputeHanning();

  static Float64List _precomputeCoeffs() {
    final coeffs = Float64List(numBins);
    for (var i = 0; i < numBins; i++) {
      final bin = minBin + i;
      final omega = (2.0 * math.pi * bin) / windowSize;
      coeffs[i] = 2.0 * math.cos(omega);
    }
    return coeffs;
  }

  static Float64List _precomputeHanning() {
    final win = Float64List(windowSize);
    for (var n = 0; n < windowSize; n++) {
      win[n] = 0.5 * (1.0 - math.cos((2.0 * math.pi * n) / (windowSize - 1)));
    }
    return win;
  }

  // Sliding frame history over the past 4.0 seconds (approx 125 frames at 32 ms).
  final List<_AcousticFrame> _history = [];
  static const int maxHistoryFrames = 130;

  // Running noise floor tracker
  double _noiseFloorRms = 150.0;

  // State machine variables
  SirenDetectorState _state = SirenDetectorState.inactive;
  double _currentConfidence = 0.0;
  SirenPatternType _currentPattern = SirenPatternType.unknown;
  double _lastDominantFreq = 1000.0;
  int _consecutiveDetections = 0;
  DateTime? _lastDetectedTime;
  double? _lastDetectedSec;

  // Configuration thresholds
  final double detectionThreshold;
  final double cooldownSeconds;
  final bool enableDirectionDetection;

  SirenClassifierEngine({
    this.detectionThreshold = 0.65,
    this.cooldownSeconds = 3.0,
    this.enableDirectionDetection = false,
  });

  SirenDetectorState get state => _state;
  double get confidence => _currentConfidence;
  SirenPatternType get currentPattern => _currentPattern;
  double get lastDominantFreq => _lastDominantFreq;

  /// Analyzes a 512-sample (1024 bytes) PCM16 mono chunk.
  SirenDetectionEvent? processFrame(Int16List pcm16, double currentTimeSec) {
    if (pcm16.length < windowSize) return null;

    // 1. Windowing and RMS Energy calculation
    var sumSq = 0.0;
    final windowed = Float64List(windowSize);
    for (var n = 0; n < windowSize; n++) {
      final sample = pcm16[n].toDouble();
      sumSq += sample * sample;
      windowed[n] = sample * _hanningWindow[n];
    }
    final frameRms = math.sqrt(sumSq / windowSize);

    // Adaptive noise floor update when energy is low
    if (frameRms < _noiseFloorRms * 1.5) {
      _noiseFloorRms = (_noiseFloorRms * 0.95) + (frameRms * 0.05);
    }

    // Silence gate
    if (frameRms < 100.0) {
      _advanceStateMachine(currentTimeSec, 0.0, SirenPatternType.unknown, 1000.0);
      return _buildEvent(currentTimeSec);
    }

    // 2. Goertzel Filter Bank analysis across 600 Hz .. 1600 Hz
    final powers = Float64List(numBins);
    var maxPower = 0.0;
    var maxIndex = 0;
    var bandPower = 0.0;

    for (var i = 0; i < numBins; i++) {
      final coeff = _goertzelCoeffs[i];
      var s0 = 0.0;
      var s1 = 0.0;
      var s2 = 0.0;

      for (var n = 0; n < windowSize; n++) {
        s0 = windowed[n] + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
      }
      final power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
      powers[i] = power;
      bandPower += power;
      if (power > maxPower) {
        maxPower = power;
        maxIndex = i;
      }
    }

    final peakFreq = (minBin + maxIndex) * binResolution;
    final meanPower = bandPower / numBins;
    final peakToAvgRatio = meanPower > 0.001 ? (maxPower / meanPower) : 0.0;
    final inBandRatio = sumSq > 0.001 ? (bandPower / (sumSq * 0.5 + 0.001)) : 0.0;

    // A tone has high peak-to-average ratio and significant in-band power
    final isTonal = peakToAvgRatio >= 3.6 && inBandRatio >= 0.18;

    // 3. Append to history buffer
    final frame = _AcousticFrame(
      timeSec: currentTimeSec,
      peakFreqHz: peakFreq,
      peakToAvgRatio: peakToAvgRatio,
      inBandRatio: inBandRatio,
      rms: frameRms,
      isTonal: isTonal,
    );

    _history.add(frame);
    if (_history.length > maxHistoryFrames) {
      _history.removeAt(0);
    }

    // 4. Modulation & False-Positive Evaluation across sliding window
    final classification = _evaluateHistory();

    // 5. Update State Machine & Hysteresis
    _advanceStateMachine(
      currentTimeSec,
      classification.confidence,
      classification.pattern,
      peakFreq,
    );

    return _buildEvent(currentTimeSec);
  }

  /// Evaluates frequency modulation, periodicity, and false-positive criteria across history.
  _ClassificationResult _evaluateHistory() {
    if (_history.length < 15) {
      return const _ClassificationResult(0.0, SirenPatternType.unknown);
    }

    // Extract valid tonal samples from the last ~3.5 seconds
    final tonalFrames = _history.where((f) => f.isTonal).toList();
    if (tonalFrames.length < 8) {
      return const _ClassificationResult(0.0, SirenPatternType.unknown);
    }

    var minF = double.infinity;
    var maxF = double.negativeInfinity;
    final freqs = <double>[];

    for (final f in tonalFrames) {
      freqs.add(f.peakFreqHz);
      if (f.peakFreqHz < minF) minF = f.peakFreqHz;
      if (f.peakFreqHz > maxF) maxF = f.peakFreqHz;
    }

    final freqDeviation = maxF - minF;

    // --- False Positive Rejection 1: Monolithic static horns ---
    // Horns produce static frequencies without periodic modulation (< 60 Hz excursion)
    if (freqDeviation < 60.0) {
      return const _ClassificationResult(0.05, SirenPatternType.unknown);
    }

    // --- False Positive Rejection 2: Erratic jumps from random noise / turbulence ---
    var totalStepDiff = 0.0;
    for (var i = 1; i < freqs.length; i++) {
      totalStepDiff += (freqs[i] - freqs[i - 1]).abs();
    }
    final avgStepDiff = totalStepDiff / (freqs.length - 1);
    if (avgStepDiff > 220.0) {
      return const _ClassificationResult(0.05, SirenPatternType.unknown);
    }

    // --- False Positive Rejection 3: Linear engine acceleration sweeps ---
    // Engine RPM sweeps monotonically in one direction without reversing
    var directionChanges = 0;
    var lastSlope = 0; // -1 for falling, +1 for rising
    for (var i = 1; i < freqs.length; i++) {
      final diff = freqs[i] - freqs[i - 1];
      if (diff.abs() >= 25.0) {
        final slope = diff > 0 ? 1 : -1;
        if (lastSlope != 0 && slope != lastSlope) {
          directionChanges++;
        }
        lastSlope = slope;
      }
    }

    final durationSec = tonalFrames.last.timeSec - tonalFrames.first.timeSec;
    if (durationSec <= 0.0) return const _ClassificationResult(0.0, SirenPatternType.unknown);

    final modulationRateHz = (directionChanges / 2.0) / durationSec;

    // --- False Positive Rejection 4: Wideband wind noise ---
    // Average PAR must be well above white/pink noise floor
    final avgPar = tonalFrames.map((f) => f.peakToAvgRatio).reduce((a, b) => a + b) / tonalFrames.length;
    if (avgPar < 3.2) {
      return const _ClassificationResult(0.10, SirenPatternType.unknown);
    }

    // --- Classification Mode 1: Yelp (Fast frequency modulation) ---
    // 1.5 Hz to 6.0 Hz modulation rate, excursion >= 300 Hz
    if (freqDeviation >= 320.0 && modulationRateHz >= 1.2 && modulationRateHz <= 6.5) {
      final conf = math.min(1.0, 0.70 + (freqDeviation / 1000.0) * 0.20 + (avgPar / 10.0) * 0.10);
      return _ClassificationResult(conf, SirenPatternType.yelp);
    }

    // --- Classification Mode 2: Wail (Slow sweeping sinusoidal modulation) ---
    // 0.10 Hz to 0.50 Hz modulation rate, excursion >= 400 Hz
    if (freqDeviation >= 380.0 && (directionChanges >= 1 || durationSec >= 1.2)) {
      if (modulationRateHz >= 0.08 && modulationRateHz <= 0.8) {
        final conf = math.min(1.0, 0.75 + (freqDeviation / 1000.0) * 0.15 + (avgPar / 10.0) * 0.10);
        return _ClassificationResult(conf, SirenPatternType.wail);
      }
    }

    // --- Classification Mode 3: Two-Tone (Hi-Lo alternating discrete plateaus) ---
    // Distinct peaks clustering around ~700 Hz and ~950 Hz (+- 100 Hz), excursion >= 180 Hz
    final lowPlateau = freqs.where((f) => f >= 650.0 && f <= 800.0).length;
    final highPlateau = freqs.where((f) => f >= 880.0 && f <= 1050.0).length;
    if (lowPlateau >= 3 && highPlateau >= 3 && freqDeviation >= 180.0 && freqDeviation <= 380.0) {
      final conf = math.min(1.0, 0.70 + ((lowPlateau + highPlateau) / freqs.length) * 0.25);
      return _ClassificationResult(conf, SirenPatternType.twoTone);
    }

    return const _ClassificationResult(0.10, SirenPatternType.unknown);
  }

  /// Advances the hysteresis state machine.
  void _advanceStateMachine(
    double currentTimeSec,
    double rawConfidence,
    SirenPatternType pattern,
    double dominantFreq,
  ) {
    _currentConfidence = rawConfidence;
    _currentPattern = pattern;
    _lastDominantFreq = dominantFreq;

    final now = DateTime.now();

    switch (_state) {
      case SirenDetectorState.inactive:
        if (rawConfidence >= 0.35) {
          _state = SirenDetectorState.candidate;
          _consecutiveDetections = 1;
        }
        break;

      case SirenDetectorState.candidate:
        if (rawConfidence >= detectionThreshold) {
          _consecutiveDetections++;
          if (_consecutiveDetections >= 2) {
            _state = SirenDetectorState.detected;
            _lastDetectedTime = now;
            _lastDetectedSec = currentTimeSec;
          }
        } else if (rawConfidence < 0.25) {
          _consecutiveDetections = 0;
          _state = SirenDetectorState.inactive;
        }
        break;

      case SirenDetectorState.detected:
        if (rawConfidence >= 0.40) {
          _lastDetectedTime = now;
          _lastDetectedSec = currentTimeSec;
        } else {
          // Siren dropped below threshold; enter cooldown
          _state = SirenDetectorState.cooldown;
        }
        break;

      case SirenDetectorState.cooldown:
        if (rawConfidence >= detectionThreshold) {
          // Re-emerged before cooldown expired
          _state = SirenDetectorState.detected;
          _lastDetectedTime = now;
          _lastDetectedSec = currentTimeSec;
        } else {
          final elapsedWall = _lastDetectedTime != null
              ? now.difference(_lastDetectedTime!).inMilliseconds / 1000.0
              : cooldownSeconds;
          final elapsedStream = _lastDetectedSec != null
              ? (currentTimeSec - _lastDetectedSec!)
              : cooldownSeconds;
          final elapsed = math.max(elapsedWall, elapsedStream);
          if (elapsed >= cooldownSeconds) {
            _state = SirenDetectorState.inactive;
            _consecutiveDetections = 0;
          }
        }
        break;

      case SirenDetectorState.unavailable:
        // Maintained externally on permission/hardware status
        break;
    }
  }

  SirenDetectionEvent? _buildEvent(double currentTimeSec) {
    if (_state == SirenDetectorState.detected || _state == SirenDetectorState.cooldown) {
      return SirenDetectionEvent(
        timestamp: DateTime.now(),
        confidence: _currentConfidence,
        pattern: _currentPattern,
        dominantFrequencyHz: _lastDominantFreq,
        directionKnown: enableDirectionDetection,
        approachingFromBehind: enableDirectionDetection,
      );
    }
    return null;
  }

  /// Resets internal history and state machine.
  void reset() {
    _history.clear();
    _state = SirenDetectorState.inactive;
    _currentConfidence = 0.0;
    _currentPattern = SirenPatternType.unknown;
    _consecutiveDetections = 0;
    _lastDetectedTime = null;
    _lastDetectedSec = null;
  }
}

class _ClassificationResult {
  final double confidence;
  final SirenPatternType pattern;
  const _ClassificationResult(this.confidence, this.pattern);
}

/// Service managing microphone capture, streaming analysis, and audio ducking.
///
/// Fully unlocked on the Community (Free) tier.
/// Integrates with IntercomService for in-app chatter attenuation (-20 dB / 0.10 factor)
/// and Android AudioManager transient duck focus for external media.
class SirenAcousticDetector extends ChangeNotifier {
  static const MethodChannel _audioChannel = MethodChannel('coroute/audio_watchdog');

  final IntercomService? intercomService;
  final SirenClassifierEngine engine;

  AudioRecorder? _recorderInstance;
  AudioRecorder get _recorder => _recorderInstance ??= AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;

  final ValueNotifier<SirenDetectorState> stateNotifier =
      ValueNotifier<SirenDetectorState>(SirenDetectorState.inactive);
  final ValueNotifier<SirenDetectionEvent?> activeSirenNotifier =
      ValueNotifier<SirenDetectionEvent?>(null);
  final ValueNotifier<bool> isAudioDuckedNotifier = ValueNotifier<bool>(false);

  bool _isRunning = false;
  bool _isDucked = false;
  bool _isDisposed = false;
  double _streamTimeSec = 0.0;

  SirenAcousticDetector({
    this.intercomService,
    SirenClassifierEngine? customEngine,
  }) : engine = customEngine ?? SirenClassifierEngine();

  bool get isRunning => _isRunning;
  bool get isDucked => _isDucked;
  SirenDetectorState get currentState => stateNotifier.value;

  // ===================================================================== 3.55 ride mic hub path
  //
  // Since 3.55 the detector is fed by the RideMicHub (one shared microphone during a ride) and
  // runs the SoundAwarenessEngine (lib/domain/audio/sound_awareness_engine.dart: sirens only,
  // pure Dart, on the phone only; audio is never recorded or sent). Horn alerts were removed
  // (owner's decision). The legacy SirenClassifierEngine / processPcmChunk path above stays for
  // compatibility.
  //
  // Purpose: the rider may not hear outside sound (noise-cancelling earbuds, a helmet set, music),
  // but the phone's own microphone does. The rider is warned; the group is not told.
  // How loud an alert is comes from lib/domain/audio/sound_alert_policy.dart, using
  // [listening] (polled from native without the mic: headset / music / call / our own speech;
  // plus the intercom):
  //  * siren, rider isolated: close / approaching / closer = P1 (music paused), e.g. "Ambulance
  //    siren close by. Keep left and give way." (the kind only when the engine is confident, else
  //    "Emergency vehicle siren ..."), strong vibration, cockpit card, heads-up when the app is not
  //    in front; far = P2 "... siren in the distance.";
  //  * siren, rider not isolated (phone speaker, no music): card + vibration + a short tone;
  //  * intercom playback ducked -20 dB while a siren episode lasts (both cases);
  //  * the phone's own sound on its loudspeaker (music, intercom, our own line) is ignored by the
  //    engine ([SoundAwarenessEngine.suppress]), so the phone never alerts on itself.
  // Admin switch: 'sirenDetector'. Unknown = on.

  /// The 3.55 engine (sirens).
  final SoundAwarenessEngine awareness = SoundAwarenessEngine();

  RideMicHub? _hub;
  RideMicHub? get hub => _hub;

  /// Speaks an alert. [urgent] = P1 (pause music, never muted); else P2 hazard tier.
  /// Wired in main.dart to VoiceService.priorityManager.submit. Null in tests.
  Future<bool> Function(String text, {required bool urgent, required String key})? speak;

  /// A short alert tone (siren close by while the rider is not isolated). Null in tests.
  void Function()? tone;

  /// Rider setting: siren alerts on (default on). Admin switch 'sirenDetector' applies on top.
  bool Function() sirenSettingOn = () => true;

  /// 'left' or 'right': the side to keep to when giving way (India and the UK: left).
  String Function() giveWaySide = () => 'left';

  /// The intercom is playing a rider's voice (counts as "cannot hear outside").
  bool Function() intercomPlaying = () => false;

  /// CoRoute is speaking a line right now (Dart side, before the next native poll sees it).
  bool Function() ownSpeechActive = () => false;

  /// Reads the phone's audio state (headset / music / call) without the microphone. Wired in
  /// main.dart to NativeVoiceEngine.readListeningState; null = [ListeningState.open] (tests).
  Future<ListeningState?> Function()? readListening;

  /// Last native audio state (the intercom part is read live in [listening]).
  ListeningState _native = ListeningState.open;
  Timer? _listenPoll;
  bool _polling = false;

  /// How often the audio state is read during a ride (a cheap AudioManager query, no mic). Short,
  /// so music started on the phone speaker is ignored by detection before it could add up to the
  /// 2.5 s a siren needs.
  static const Duration listeningPollEvery = Duration(seconds: 1);

  /// The rider's hearing situation right now.
  ListeningState get listening => _native.withIntercom(intercomPlaying()).withOwnSpeech(_native.ownSpeech || ownSpeechActive());

  /// The rider likely cannot hear outside sound (earphones / helmet set, music, intercom, call).
  bool get listeningIsolated => listening.isolated;

  /// Test hook / native push: a new audio state.
  @visibleForTesting
  void setNativeListening(ListeningState s) {
    final changed = s != _native;
    _native = s;
    if (changed && !_isDisposed) notifyListeners();
  }

  /// Starts / stops reading the audio state (main.dart: on ride start and end). Runs only during a
  /// ride and never needs the microphone.
  void setRideActive(bool riding) {
    if (riding) {
      _listenPoll ??= Timer.periodic(listeningPollEvery, (_) => _pollListening());
      _pollListening();
    } else {
      _listenPoll?.cancel();
      _listenPoll = null;
      setNativeListening(ListeningState.open);
    }
  }

  Future<void> _pollListening() async {
    final read = readListening;
    if (read == null || _polling || _isDisposed) return;
    _polling = true;
    try {
      final s = await read();
      if (s != null && !_isDisposed) setNativeListening(s);
    } catch (_) {
    } finally {
      _polling = false;
    }
  }

  /// 3.55: posts a heads-up with vibration (ride notification path, AlarmNotifier) for the lock
  /// screen / background, where HapticFeedback may not vibrate. Set in main.dart; null = haptics only.
  Future<void> Function(String title, String body, {required bool strong})? backgroundAlert;

  /// The app is in front (screen on, app visible). Then only HapticFeedback is used, so the rider
  /// never gets the in-app vibration AND a notification for the same alert.
  bool Function() appInFront = _defaultAppInFront;

  static bool _defaultAppInFront() {
    try {
      final s = WidgetsBinding.instance.lifecycleState;
      return s == null || s == AppLifecycleState.resumed;
    } catch (_) {
      return true;
    }
  }

  /// In front: app vibration. Background / locked: the notification's vibration instead.
  void _feel(String title, String body, {required bool strong}) {
    final bg = backgroundAlert;
    if (bg == null || appInFront()) {
      _vibrate(strong: strong);
    } else {
      bg(title, body, strong: strong).ignore();
    }
  }

  /// Siren alerts wanted now (setting + admin switch).
  bool get sirenAlertsOn => sirenSettingOn() && FeatureFlagsService.on('sirenDetector');

  /// The hub's analysis frames are needed (the hub asks this through detectionEnabled).
  bool get detectionWanted => sirenAlertsOn;

  /// Connects to the ride mic hub (main.dart). The hub decides when the mic is open.
  void attachHub(RideMicHub hub) {
    if (identical(_hub, hub)) return;
    _hub?.removeAnalysisListener(onHubFrame);
    _hub = hub;
    hub.detectionEnabled = () => detectionWanted;
    hub.addAnalysisListener(onHubFrame);
    hub.reevaluate();
  }

  void detachHub() {
    _hub?.removeAnalysisListener(onHubFrame);
    _hub = null;
    _endSirenEpisode();
  }

  /// Settings / admin switches / ride changed: lets the hub open or release the mic at once.
  void settingsChanged() {
    if (!sirenAlertsOn) _endSirenEpisode();
    _hub?.reevaluate();
  }

  /// A new ride: forget the last ride's sound history.
  void resetForRide() {
    awareness.reset();
    _endSirenEpisode();
  }

  /// One 20 ms frame from the hub (raw PCM16, 16 kHz). Also used by tests.
  void onHubFrame(Int16List frame, MicFrameInfo info) {
    if (_isDisposed) return;
    if (!sirenAlertsOn) {
      _endSirenEpisode();
      return;
    }
    // A headset mic (push-to-talk on a helmet set) hears the rider, not the road: those frames are
    // skipped so they never disturb the road noise floor (detection resumes on the phone mic).
    if (info.processed && info.headset) return;
    awareness.suppress = listening.ownSoundOnSpeaker;
    // 3.55 diagnostics: with detailed logs on, why sound candidates were not sirens (sampled).
    final why = DiagLog.detailed;
    awareness.debug = why;
    _onSirenUpdate(awareness.process(int16ToFloat(frame)));
    if (why) {
      final c = awareness.debugClass;
      if (c.isNotEmpty && !c.startsWith('no run') && DiagLog.sampler.take('siren_reject', DateTime.now().millisecondsSinceEpoch)) {
        DiagLog.debug(DiagCat.siren, 'candidate_rejected', {'why': c});
      }
    }
  }

  void _onSirenUpdate(SoundAwarenessUpdate u) {
    final obs = u.siren;
    if (obs != null) {
      if (activeSirenNotifier.value == null) {
        // First observation of an episode: what was heard and how long it took to be sure.
        DiagLog.info(DiagCat.siren, 'detected', {
          'pattern': obs.pattern, 'kind': obs.kind, 'kindSure': obs.kindConfident, 'conf': obs.confidence, 'kindConf': obs.kindConfidence,
          'snrDb': obs.snrDb, 'hz': obs.centreHz, 'heardS': obs.continuousSec, 'trend': obs.trend, 'near': obs.nearness,
          'music': listening.musicActive, 'call': listening.inCall,
        });
      }
      activeSirenNotifier.value = SirenDetectionEvent.fromObservation(obs);
      if (stateNotifier.value != SirenDetectorState.detected) stateNotifier.value = SirenDetectorState.detected;
      _applyDucking(true);
    } else if (u.sirenEpisodeEnded || (activeSirenNotifier.value != null && !awareness.sirenEpisodeActive)) {
      _endSirenEpisode();
    }
    final alert = u.sirenAlert;
    if (alert == null) return;
    final o = alert.observation;
    final style = SoundAlertPolicy.sirenStyle(close: SoundAlertPolicy.sirenClose(alert), isolated: listeningIsolated);
    final line = sirenAlertText(alert, keepSide: giveWaySide());
    DiagLog.info(DiagCat.siren, 'alert', {'reason': alert.reason, 'speak': style.speak, 'tone': style.tone, 'urgent': style.urgent, 'close': SoundAlertPolicy.sirenClose(alert), 'isolated': listeningIsolated, 'heardS': o.continuousSec});
    if (style.speak) {
      speak?.call(line, urgent: style.urgent, key: 'siren_${alert.reason.name}_${o.timeSec.round()}').ignore();
    } else if (style.tone) {
      tone?.call();
    }
    _feel(sirenTitle(o), line, strong: style.strongVibration);
  }

  /// 3.55: counts finished siren episodes, so the cockpit can key a dismissed siren card per
  /// episode (dismissing one siren must not hide the next one for the rest of the ride).
  int sirenEpisode = 0;

  void _endSirenEpisode() {
    if (activeSirenNotifier.value != null) DiagLog.info(DiagCat.siren, 'episode_end');
    sirenEpisode++;
    if (activeSirenNotifier.value != null && !_isDisposed) activeSirenNotifier.value = null;
    if (!_isDisposed && stateNotifier.value == SirenDetectorState.detected) stateNotifier.value = SirenDetectorState.inactive;
    _applyDucking(false);
  }

  void _vibrate({required bool strong}) {
    try {
      if (strong) {
        HapticFeedback.heavyImpact();
        Future.delayed(const Duration(milliseconds: 220), HapticFeedback.heavyImpact);
        Future.delayed(const Duration(milliseconds: 440), HapticFeedback.heavyImpact);
      } else {
        HapticFeedback.mediumImpact();
        Future.delayed(const Duration(milliseconds: 200), HapticFeedback.mediumImpact);
      }
    } catch (_) {}
  }

  /// 'left' for countries that drive on the left (India first), else 'right'. Unknown = left.
  static String keepSideForCountry(String? countryCode) {
    const leftHand = {
      'IN', 'GB', 'IE', 'AU', 'NZ', 'JP', 'ZA', 'MY', 'SG', 'TH', 'ID', 'PK', 'BD', 'LK', 'NP', 'BT', 'KE', 'UG', 'TZ', //
      'HK', 'MO', 'MT', 'CY', 'JM', 'TT', 'BS', 'BB', 'MU', 'ZW', 'ZM', 'BW', 'NA', 'MZ', 'MW', 'LS', 'SZ', 'BN', 'MV', 'FJ', 'PG',
    };
    final cc = countryCode?.toUpperCase();
    if (cc == null || cc.isEmpty) return 'left';
    return leftHand.contains(cc) ? 'left' : 'right';
  }

  /// The kind said in the line: only when the engine is confident ([SirenObservation.kindConfident]).
  static EmergencyVehicleKind spokenKind(SirenObservation o) => o.kindConfident ? o.kind : EmergencyVehicleKind.unknown;

  /// Heads-up / notification title.
  static String sirenTitle(SirenObservation o) => switch (spokenKind(o)) {
        EmergencyVehicleKind.ambulance => 'Ambulance',
        EmergencyVehicleKind.police => 'Police',
        EmergencyVehicleKind.fire => 'Fire engine',
        EmergencyVehicleKind.unknown => 'Emergency vehicle',
      };

  /// What the rider hears: "Ambulance siren close by. Keep left and give way.", "Police
  /// approaching. ...", "Emergency vehicle siren in the distance." The kind is said only when the
  /// engine is confident; otherwise "Emergency vehicle".
  static String sirenAlertText(SirenAlert a, {String keepSide = 'left'}) {
    final o = a.observation;
    final who = sirenTitle(o);
    final giveWay = 'Keep $keepSide and give way.';
    if (a.reason == SirenAlertReason.closer) return '$who getting closer. $giveWay';
    if (o.trend == SirenTrend.approaching) return '$who approaching. $giveWay';
    if (o.nearness == SoundNearness.far) return '$who siren in the distance.';
    return '$who siren close by. $giveWay';
  }

  /// Every line [sirenAlertText] can produce for [keepSide] (pre-synthesised at ride start, so the
  /// alert starts at once: see VoiceService.warmUp).
  static List<String> allSirenLines({String keepSide = 'left'}) {
    final giveWay = 'Keep $keepSide and give way.';
    return [
      for (final who in const ['Emergency vehicle', 'Ambulance', 'Police', 'Fire engine']) ...[
        '$who siren close by. $giveWay',
        '$who approaching. $giveWay',
        '$who getting closer. $giveWay',
        '$who siren in the distance.',
      ],
    ];
  }

  /// Starts listening to microphone and processing acoustic frames.
  /// If [injectedStream] is provided (e.g. in tests), uses it instead of hardware mic.
  Future<bool> start({Stream<Uint8List>? injectedStream}) async {
    if (_isRunning) return true;

    // Feature gate check: Community tier is fully entitled
    if (!FeatureGates.isUnlocked(Feature.sirenAcousticDetector)) {
      stateNotifier.value = SirenDetectorState.unavailable;
      return false;
    }

    if (injectedStream != null) {
      _isRunning = true;
      _micSub = injectedStream.listen(
        _onPcmData,
        onError: (e) => _onMicError(e),
        onDone: () => stop(),
      );
      stateNotifier.value = SirenDetectorState.inactive;
      notifyListeners();
      return true;
    }

    // FEAT-MIC-01: Microphone privacy compliance:
    // Continuous background microphone capture is eliminated.
    // Microphone must remain OFF by default at all times and is never activated
    // merely because a cockpit, trip, or background service is active.
    // In normal operation, acoustic frames are ingested via processPcmChunk
    // exclusively when the rider legitimately activates microphone (PTT or VOX).
    _isRunning = true;
    if (intercomService != null) {
      intercomService!.onMicChunk = processPcmChunk;
    }
    stateNotifier.value = SirenDetectorState.inactive;
    notifyListeners();
    return true;
  }

  /// Processes raw 16-bit PCM mono bytes from the microphone.
  void processPcmChunk(Uint8List pcmBytes) {
    _onPcmData(pcmBytes);
  }

  void _onPcmData(Uint8List bytes) {
    if (!FeatureFlagsService.on('sirenDetector')) {
      // 3.55 admin feature switch. 3.55 fix: switched off while a siren had the audio ducked, the
      // duck used to stay on for the rest of the ride; it is lifted now.
      _applyDucking(false);
      return;
    }
    if (bytes.length < 1024) return; // 512 samples * 2 bytes = 1024 bytes

    final int16List = Int16List.view(bytes.buffer, bytes.offsetInBytes, bytes.length ~/ 2);
    _streamTimeSec += (int16List.length / 16000.0);

    final event = engine.processFrame(int16List, _streamTimeSec);

    stateNotifier.value = engine.state;
    activeSirenNotifier.value = event;

    final shouldDuck = engine.state == SirenDetectorState.detected ||
        engine.state == SirenDetectorState.cooldown;

    _applyDucking(shouldDuck);
  }

  void _applyDucking(bool enable) {
    if (_isDucked == enable) return;
    _isDucked = enable;
    if (!_isDisposed) {
      isAudioDuckedNotifier.value = enable;
    }

    // 1. Duck in-app intercom chatter by -20 dB (0.10 factor)
    intercomService?.setSirenDucking(enable);

    // 2. Request Android/iOS native audio focus ducking for external music
    try {
      _audioChannel.invokeMethod('setSirenDucking', {'ducked': enable}).ignore();
    } catch (_) {}

    if (!_isDisposed) {
      notifyListeners();
    }
  }

  void _onMicError(Object error) {
    debugPrint('SirenAcousticDetector audio stream error: $error');
    DiagLog.warn(DiagCat.siren, 'mic_error', {'type': error.runtimeType.toString()});
    if (!_isDisposed) {
      stateNotifier.value = SirenDetectorState.unavailable;
      _applyDucking(false);
      notifyListeners();
    }
  }

  /// Stops detection, releases microphone, and restores ducked audio.
  Future<void> stop() async {
    _isRunning = false;
    if (intercomService?.onMicChunk == processPcmChunk) {
      intercomService?.onMicChunk = null;
    }
    await _micSub?.cancel();
    _micSub = null;

    try {
      if (_recorderInstance != null && await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {}

    _applyDucking(false);
    engine.reset();
    if (!_isDisposed) {
      stateNotifier.value = SirenDetectorState.inactive;
      activeSirenNotifier.value = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _hub?.removeAnalysisListener(onHubFrame);
    _hub = null;
    _listenPoll?.cancel();
    _listenPoll = null;
    _isDisposed = true;
    _isRunning = false;
    if (intercomService?.onMicChunk == processPcmChunk) {
      intercomService?.onMicChunk = null;
    }
    _micSub?.cancel();
    _micSub = null;
    try {
      _recorderInstance?.dispose();
    } catch (_) {}
    _recorderInstance = null;
    _applyDucking(false);
    stateNotifier.dispose();
    activeSirenNotifier.dispose();
    isAudioDuckedNotifier.dispose();
    super.dispose();
  }
}
