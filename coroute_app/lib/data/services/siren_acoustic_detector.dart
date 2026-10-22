import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import '../../core/config/feature_gates.dart';
import 'intercom_service.dart';

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

  const SirenDetectionEvent({
    required this.timestamp,
    required this.confidence,
    required this.pattern,
    required this.dominantFrequencyHz,
    this.directionKnown = false,
    this.approachingFromBehind = false,
  });

  /// Displays the required alert text based on directional verification.
  String get alertText => approachingFromBehind
      ? '🚨 EMERGENCY SIREN DETECTED BEHIND · YIELD'
      : '🚨 EMERGENCY SIREN DETECTED · YIELD';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SirenDetectionEvent &&
          runtimeType == other.runtimeType &&
          confidence == other.confidence &&
          pattern == other.pattern &&
          dominantFrequencyHz == other.dominantFrequencyHz &&
          directionKnown == other.directionKnown &&
          approachingFromBehind == other.approachingFromBehind;

  @override
  int get hashCode => Object.hash(
        confidence,
        pattern,
        dominantFrequencyHz,
        directionKnown,
        approachingFromBehind,
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

    // Hardware microphone permission verification
    try {
      final hasPerm = await _recorder.hasPermission();
      if (!hasPerm) {
        stateNotifier.value = SirenDetectorState.unavailable;
        notifyListeners();
        return false;
      }

      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        echoCancel: false,
        noiseSuppress: false,
        autoGain: false,
      ));

      _isRunning = true;
      _micSub = stream.listen(
        _onPcmData,
        onError: (e) => _onMicError(e),
        onDone: () => stop(),
      );

      stateNotifier.value = SirenDetectorState.inactive;
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('SirenAcousticDetector start note: $e');
      stateNotifier.value = SirenDetectorState.unavailable;
      notifyListeners();
      return false;
    }
  }

  /// Processes raw 16-bit PCM mono bytes from the microphone.
  void processPcmChunk(Uint8List pcmBytes) {
    _onPcmData(pcmBytes);
  }

  void _onPcmData(Uint8List bytes) {
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
    if (!_isDisposed) {
      stateNotifier.value = SirenDetectorState.unavailable;
      _applyDucking(false);
      notifyListeners();
    }
  }

  /// Stops detection, releases microphone, and restores ducked audio.
  Future<void> stop() async {
    _isRunning = false;
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
    _isDisposed = true;
    _isRunning = false;
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
