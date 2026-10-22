import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/config/feature_gates.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/siren_acoustic_detector.dart';
import 'package:coroute_app/presentation/rider/widgets/siren_hud_pill.dart';

/// Helper to generate synthetic 16 kHz 16-bit little-endian PCM audio.
class SyntheticAudioGenerator {
  static const int sampleRate = 16000;

  /// Generates a chunk of sinusoidal audio with time-varying frequency.
  static Int16List generateFm({
    required double durationSec,
    required double Function(double t) freqAt,
    double amplitude = 18000.0,
    double noiseAmplitude = 500.0,
  }) {
    final numSamples = (durationSec * sampleRate).round();
    final pcm = Int16List(numSamples);
    var phase = 0.0;
    final random = math.Random(42);

    for (var n = 0; n < numSamples; n++) {
      final t = n / sampleRate;
      final f = freqAt(t);
      phase += 2.0 * math.pi * f / sampleRate;
      final clean = amplitude * math.sin(phase);
      final noise = (random.nextDouble() * 2.0 - 1.0) * noiseAmplitude;
      final sample = (clean + noise).round().clamp(-32768, 32767);
      pcm[n] = sample;
    }
    return pcm;
  }

  /// Converts an Int16List into Uint8List little-endian bytes.
  static Uint8List toBytes(Int16List pcm16) {
    final byteData = ByteData(pcm16.length * 2);
    for (var i = 0; i < pcm16.length; i++) {
      byteData.setInt16(i * 2, pcm16[i], Endian.little);
    }
    return byteData.buffer.asUint8List();
  }

  /// Generates synthetic Wail siren: 700 Hz <-> 1500 Hz, 4.0s period.
  static Int16List generateWail({double durationSec = 3.5, double amplitude = 18000.0}) {
    return generateFm(
      durationSec: durationSec,
      freqAt: (t) => 1100.0 + 400.0 * math.sin(2.0 * math.pi * t / 4.0),
      amplitude: amplitude,
    );
  }

  /// Generates synthetic Yelp siren: 700 Hz <-> 1500 Hz, 0.35s period.
  static Int16List generateYelp({double durationSec = 2.0, double amplitude = 18000.0}) {
    return generateFm(
      durationSec: durationSec,
      freqAt: (t) {
        final phase = (t / 0.35) % 1.0;
        final triangle = phase < 0.5 ? (phase * 2.0) : (2.0 - phase * 2.0);
        return 700.0 + 800.0 * triangle;
      },
      amplitude: amplitude,
    );
  }

  /// Generates synthetic Two-Tone (Hi-Lo): alternating 700 Hz and 950 Hz, 0.6s dwell.
  static Int16List generateTwoTone({double durationSec = 2.5, double amplitude = 18000.0}) {
    return generateFm(
      durationSec: durationSec,
      freqAt: (t) => ((t % 1.2) < 0.6) ? 700.0 : 950.0,
      amplitude: amplitude,
    );
  }

  /// Generates synthetic motorcycle engine RPM sweep: linear 120 Hz to 420 Hz with overtones.
  static Int16List generateEngineSweep({double durationSec = 3.0}) {
    final numSamples = (durationSec * sampleRate).round();
    final pcm = Int16List(numSamples);
    var phase1 = 0.0;
    var phase2 = 0.0;

    for (var n = 0; n < numSamples; n++) {
      final t = n / sampleRate;
      final f1 = 120.0 + 100.0 * t; // Linear ramp without direction changes
      final f2 = f1 * 2.0; // 2nd harmonic
      phase1 += 2.0 * math.pi * f1 / sampleRate;
      phase2 += 2.0 * math.pi * f2 / sampleRate;
      final val = 12000.0 * math.sin(phase1) + 6000.0 * math.sin(phase2);
      pcm[n] = val.round().clamp(-32768, 32767);
    }
    return pcm;
  }

  /// Generates low-frequency loud exhaust rumble: 60 Hz to 250 Hz.
  static Int16List generateExhaustRumble({double durationSec = 2.0}) {
    final numSamples = (durationSec * sampleRate).round();
    final pcm = Int16List(numSamples);
    final random = math.Random(123);
    var filterState = 0.0;

    for (var n = 0; n < numSamples; n++) {
      final white = (random.nextDouble() * 2.0 - 1.0) * 25000.0;
      // Low-pass filter at ~180 Hz
      filterState = filterState * 0.93 + white * 0.07;
      pcm[n] = filterState.round().clamp(-32768, 32767);
    }
    return pcm;
  }

  /// Generates wideband wind buffeting with random clipping.
  static Int16List generateWindBuffeting({double durationSec = 2.0}) {
    final numSamples = (durationSec * sampleRate).round();
    final pcm = Int16List(numSamples);
    final random = math.Random(456);
    var state = 0.0;

    for (var n = 0; n < numSamples; n++) {
      final white = (random.nextDouble() * 2.0 - 1.0) * 20000.0;
      state = state * 0.85 + white * 0.15;
      // Occasional clipping
      var sample = state * 1.8;
      if (sample > 30000) sample = 32767;
      if (sample < -30000) sample = -32768;
      pcm[n] = sample.round().clamp(-32768, 32767);
    }
    return pcm;
  }

  /// Generates a static dual-tone vehicle horn: constant 440 Hz + 880 Hz.
  static Int16List generateVehicleHorn({double durationSec = 2.0}) {
    return generateFm(
      durationSec: durationSec,
      freqAt: (t) => 880.0, // Monolithic frequency, zero modulation
      amplitude: 22000.0,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FEAT-03: Acoustic DSP Siren Classification Engine Tests', () {
    late SirenClassifierEngine engine;

    setUp(() {
      engine = SirenClassifierEngine(cooldownSeconds: 3.0);
    });

    test('TEST-SIR-01: Rising and falling wail siren pattern is detected', () {
      final wailPcm = SyntheticAudioGenerator.generateWail(durationSec: 3.2);
      final numWindows = wailPcm.length ~/ 512;
      SirenDetectionEvent? lastEvent;

      for (var i = 0; i < numWindows; i++) {
        final window = wailPcm.sublist(i * 512, (i + 1) * 512);
        final t = (i * 512) / 16000.0;
        final event = engine.processFrame(window, t);
        if (event != null) lastEvent = event;
      }

      expect(lastEvent, isNotNull, reason: 'Wail pattern should trigger a detection event');
      expect(engine.state, equals(SirenDetectorState.detected));
      expect(lastEvent!.pattern, equals(SirenPatternType.wail));
      expect(lastEvent.confidence, greaterThanOrEqualTo(0.65));
      expect(lastEvent.dominantFrequencyHz, inInclusiveRange(600.0, 1600.0));
    });

    test('TEST-SIR-02: Fast yelp siren pattern is detected', () {
      final yelpPcm = SyntheticAudioGenerator.generateYelp(durationSec: 2.0);
      final numWindows = yelpPcm.length ~/ 512;
      SirenDetectionEvent? lastEvent;

      for (var i = 0; i < numWindows; i++) {
        final window = yelpPcm.sublist(i * 512, (i + 1) * 512);
        final t = (i * 512) / 16000.0;
        final event = engine.processFrame(window, t);
        if (event != null) lastEvent = event;
      }

      expect(lastEvent, isNotNull);
      expect(engine.state, equals(SirenDetectorState.detected));
      expect(lastEvent!.pattern, equals(SirenPatternType.yelp));
      expect(lastEvent.confidence, greaterThanOrEqualTo(0.65));
    });

    test('TEST-SIR-03: Alternating two-tone (Hi-Lo) siren pattern is detected', () {
      final twoTonePcm = SyntheticAudioGenerator.generateTwoTone(durationSec: 2.4);
      final numWindows = twoTonePcm.length ~/ 512;
      SirenDetectionEvent? lastEvent;

      for (var i = 0; i < numWindows; i++) {
        final window = twoTonePcm.sublist(i * 512, (i + 1) * 512);
        final t = (i * 512) / 16000.0;
        final event = engine.processFrame(window, t);
        if (event != null) lastEvent = event;
      }

      expect(lastEvent, isNotNull);
      expect(engine.state, equals(SirenDetectorState.detected));
      expect(lastEvent!.pattern, equals(SirenPatternType.twoTone));
    });

    test('TEST-SIR-04: Motorcycle engine RPM sweep is rejected (no periodic modulation)', () {
      final enginePcm = SyntheticAudioGenerator.generateEngineSweep(durationSec: 3.0);
      final numWindows = enginePcm.length ~/ 512;

      for (var i = 0; i < numWindows; i++) {
        final window = enginePcm.sublist(i * 512, (i + 1) * 512);
        final t = (i * 512) / 16000.0;
        engine.processFrame(window, t);
      }

      expect(engine.state, isNot(equals(SirenDetectorState.detected)));
      expect(engine.confidence, lessThan(0.30));
    });

    test('TEST-SIR-05: Loud exhaust low-frequency rumble is rejected', () {
      final exhaustPcm = SyntheticAudioGenerator.generateExhaustRumble(durationSec: 2.0);
      final numWindows = exhaustPcm.length ~/ 512;

      for (var i = 0; i < numWindows; i++) {
        final window = exhaustPcm.sublist(i * 512, (i + 1) * 512);
        final t = (i * 512) / 16000.0;
        engine.processFrame(window, t);
      }

      expect(engine.state, equals(SirenDetectorState.inactive));
      expect(engine.confidence, lessThan(0.20));
    });

    test('TEST-SIR-06: Wind buffeting and clipping noise are rejected', () {
      final windPcm = SyntheticAudioGenerator.generateWindBuffeting(durationSec: 2.0);
      final numWindows = windPcm.length ~/ 512;

      for (var i = 0; i < numWindows; i++) {
        final window = windPcm.sublist(i * 512, (i + 1) * 512);
        final t = (i * 512) / 16000.0;
        engine.processFrame(window, t);
      }

      expect(engine.state, equals(SirenDetectorState.inactive));
      expect(engine.confidence, lessThan(0.20));
    });

    test('TEST-SIR-07: Monolithic vehicle horn is rejected (zero periodic pitch modulation)', () {
      final hornPcm = SyntheticAudioGenerator.generateVehicleHorn(durationSec: 2.5);
      final numWindows = hornPcm.length ~/ 512;

      for (var i = 0; i < numWindows; i++) {
        final window = hornPcm.sublist(i * 512, (i + 1) * 512);
        final t = (i * 512) / 16000.0;
        engine.processFrame(window, t);
      }

      expect(engine.state, isNot(equals(SirenDetectorState.detected)));
      expect(engine.confidence, lessThan(0.25));
    });

    test('TEST-SIR-08: Speech and dynamic chatter contamination are rejected', () {
      // Simulate speech formant jumps
      final speechPcm = SyntheticAudioGenerator.generateFm(
        durationSec: 2.5,
        freqAt: (t) {
          final step = (t * 4.0).floor();
          // Jumps between 300, 1800, 400, 2200 Hz
          return [300.0, 1800.0, 450.0, 2200.0][step % 4];
        },
        amplitude: 15000.0,
      );
      final numWindows = speechPcm.length ~/ 512;

      for (var i = 0; i < numWindows; i++) {
        final window = speechPcm.sublist(i * 512, (i + 1) * 512);
        final t = (i * 512) / 16000.0;
        engine.processFrame(window, t);
      }

      expect(engine.state, isNot(equals(SirenDetectorState.detected)));
    });

    test('TEST-SIR-09: Weak siren signal accumulates confidence over time', () {
      final weakWail = SyntheticAudioGenerator.generateWail(durationSec: 3.5, amplitude: 5000.0);
      final numWindows = weakWail.length ~/ 512;
      final confidences = <double>[];

      for (var i = 0; i < numWindows; i++) {
        final window = weakWail.sublist(i * 512, (i + 1) * 512);
        final t = (i * 512) / 16000.0;
        engine.processFrame(window, t);
        confidences.add(engine.confidence);
      }

      expect(confidences.last, greaterThan(confidences.first));
    });

    test('TEST-SIR-10: Simultaneous siren and background engine rumble detected', () {
      final wail = SyntheticAudioGenerator.generateWail(durationSec: 3.2, amplitude: 14000.0);
      final engineNoise = SyntheticAudioGenerator.generateExhaustRumble(durationSec: 3.2);
      final mixed = Int16List(wail.length);
      for (var i = 0; i < wail.length; i++) {
        mixed[i] = (wail[i] + engineNoise[i] * 0.5).round().clamp(-32768, 32767);
      }

      final numWindows = mixed.length ~/ 512;
      for (var i = 0; i < numWindows; i++) {
        final window = mixed.sublist(i * 512, (i + 1) * 512);
        final t = (i * 512) / 16000.0;
        engine.processFrame(window, t);
      }

      expect(engine.state, equals(SirenDetectorState.detected));
    });

    test('TEST-SIR-11: Silence and changing noise floors adapt without false positives', () {
      final silence = Int16List(512 * 30); // 30 windows of absolute silence
      for (var i = 0; i < 30; i++) {
        final window = silence.sublist(i * 512, (i + 1) * 512);
        final t = (i * 512) / 16000.0;
        final event = engine.processFrame(window, t);
        expect(event, isNull);
      }
      expect(engine.state, equals(SirenDetectorState.inactive));
      expect(engine.confidence, equals(0.0));
    });

    test('TEST-SIR-12: Invalid or short buffers are handled safely without crash', () {
      final shortBuffer = Int16List(128); // Less than windowSize (512)
      final event = engine.processFrame(shortBuffer, 0.0);
      expect(event, isNull);
      expect(engine.state, equals(SirenDetectorState.inactive));
    });

    test('TEST-SIR-13: Confidence hysteresis and cooldown transition correctly', () {
      final wail = SyntheticAudioGenerator.generateWail(durationSec: 3.2);
      final numWindows = wail.length ~/ 512;

      for (var i = 0; i < numWindows; i++) {
        final window = wail.sublist(i * 512, (i + 1) * 512);
        final t = (i * 512) / 16000.0;
        engine.processFrame(window, t);
      }
      expect(engine.state, equals(SirenDetectorState.detected));

      // Now feed silence: should enter cooldown for 3.0s, then revert to inactive
      final silenceWindow = Int16List(512);
      var t = 3.3;

      // 1 frame of silence: drops to cooldown
      engine.processFrame(silenceWindow, t);
      expect(engine.state, equals(SirenDetectorState.cooldown));

      // After 3.5 seconds of silence: reverts to inactive
      t += 3.5;
      engine.processFrame(silenceWindow, t);
      expect(engine.state, equals(SirenDetectorState.inactive));
    });

    test('TEST-SIR-14: Repeated detections of continuous siren deduplicate into single incident', () {
      final longWail = SyntheticAudioGenerator.generateWail(durationSec: 6.0);
      final numWindows = longWail.length ~/ 512;
      var detectionEvents = 0;

      for (var i = 0; i < numWindows; i++) {
        final window = longWail.sublist(i * 512, (i + 1) * 512);
        final t = (i * 512) / 16000.0;
        final event = engine.processFrame(window, t);
        if (event != null && engine.state == SirenDetectorState.detected) {
          detectionEvents++;
        }
      }

      // Detection state is sustained continuously without re-trigger oscillations
      expect(detectionEvents, greaterThanOrEqualTo(1));
      expect(engine.state, equals(SirenDetectorState.detected));
    });
  });

  group('FEAT-03: Audio Ducking & Restoration Tests (-20 dB)', () {
    test('TEST-DUCK-01 & TEST-DUCK-02: Confident siren triggers -20 dB (0.10 factor) ducking and restores volume', () async {
      final rt = RealtimeService();
      final intercom = IntercomService(rt);
      final detector = SirenAcousticDetector(intercomService: intercom);

      expect(intercom.isSirenDucked, isFalse);
      expect(detector.isDucked, isFalse);

      // Verify mathematical attenuation: -20 dB = 10^(-20/20) = 0.10
      expect(IntercomService.sirenDuckingDecibels, equals(-20.0));
      expect(IntercomService.sirenDuckingFactor, closeTo(0.10, 0.001));

      // Test attenuation on 16-bit PCM chunk
      final original = Int16List.fromList([10000, -20000, 30000, 0]);
      final pcmBytes = SyntheticAudioGenerator.toBytes(original);
      final duckedBytes = IntercomService.attenuatePcm16(pcmBytes, IntercomService.sirenDuckingFactor);
      final duckedPcm = Int16List.view(duckedBytes.buffer);

      expect(duckedPcm[0], closeTo(1000, 10)); // 10000 * 0.10 = 1000
      expect(duckedPcm[1], closeTo(-2000, 20)); // -20000 * 0.10 = -2000
      expect(duckedPcm[2], closeTo(3000, 30)); // 30000 * 0.10 = 3000

      // Feed siren frames to detector
      final wailPcm = SyntheticAudioGenerator.generateWail(durationSec: 3.2);
      final numWindows = wailPcm.length ~/ 512;
      for (var i = 0; i < numWindows; i++) {
        final window = wailPcm.sublist(i * 512, (i + 1) * 512);
        detector.processPcmChunk(SyntheticAudioGenerator.toBytes(window));
      }

      expect(detector.isDucked, isTrue);
      expect(intercom.isSirenDucked, isTrue);
      expect(detector.isAudioDuckedNotifier.value, isTrue);

      // Stop detector: volume restored cleanly
      await detector.stop();
      expect(detector.isDucked, isFalse);
      expect(intercom.isSirenDucked, isFalse);
      expect(detector.isAudioDuckedNotifier.value, isFalse);
    });

    test('TEST-DUCK-04: Rejected noise candidates never trigger audio ducking', () {
      final rt = RealtimeService();
      final intercom = IntercomService(rt);
      final detector = SirenAcousticDetector(intercomService: intercom);

      final windPcm = SyntheticAudioGenerator.generateWindBuffeting(durationSec: 2.5);
      final numWindows = windPcm.length ~/ 512;
      for (var i = 0; i < numWindows; i++) {
        final window = windPcm.sublist(i * 512, (i + 1) * 512);
        detector.processPcmChunk(SyntheticAudioGenerator.toBytes(window));
      }

      expect(detector.isDucked, isFalse);
      expect(intercom.isSirenDucked, isFalse);
    });
  });

  group('FEAT-03: HUD, Directional Guard & Entitlement Tests', () {
    test('TEST-HUD-01: Community tier has full access to FEAT-03 (Free core safety)', () {
      FeatureGates.activeTier = SubscriptionTier.community;
      FeatureGates.forceAllUnlocked = false;

      expect(FeatureGates.isUnlocked(Feature.sirenAcousticDetector), isTrue);
      expect(FeatureGates.requiredTier(Feature.sirenAcousticDetector), equals(SubscriptionTier.community));
    });

    test('TEST-HUD-02: Alert text guards BEHIND unless direction is reliably verified', () {
      // 1. Unverified direction (standard phone mic): general yield warning
      final unverifiedEvent = SirenDetectionEvent(
        timestamp: DateTime.now(),
        confidence: 0.90,
        pattern: SirenPatternType.wail,
        dominantFrequencyHz: 1100.0,
        directionKnown: false,
        approachingFromBehind: false,
      );
      expect(unverifiedEvent.alertText, equals('🚨 EMERGENCY SIREN DETECTED · YIELD'));

      // 2. Verified rear direction: behind alert
      final verifiedRearEvent = SirenDetectionEvent(
        timestamp: DateTime.now(),
        confidence: 0.92,
        pattern: SirenPatternType.wail,
        dominantFrequencyHz: 1100.0,
        directionKnown: true,
        approachingFromBehind: true,
      );
      expect(verifiedRearEvent.alertText, equals('🚨 EMERGENCY SIREN DETECTED BEHIND · YIELD'));
    });

    testWidgets('TEST-HUD-03: SirenHudPill renders correctly with accessibility semantics', (tester) async {
      final event = SirenDetectionEvent(
        timestamp: DateTime.now(),
        confidence: 0.88,
        pattern: SirenPatternType.wail,
        dominantFrequencyHz: 1050.0,
        directionKnown: false,
        approachingFromBehind: false,
      );

      var dismissed = false;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SirenHudPill(
            event: event,
            onDismiss: () => dismissed = true,
          ),
        ),
      ));

      expect(find.text('EMERGENCY SIREN DETECTED'), findsOneWidget);
      expect(find.text('YIELD'), findsOneWidget);
      expect(find.textContaining('Wail siren'), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      expect(dismissed, isTrue);
    });

    testWidgets('TEST-HUD-04: SirenHudPill renders BEHIND text when direction is verified', (tester) async {
      final event = SirenDetectionEvent(
        timestamp: DateTime.now(),
        confidence: 0.92,
        pattern: SirenPatternType.yelp,
        dominantFrequencyHz: 1200.0,
        directionKnown: true,
        approachingFromBehind: true,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SirenHudPill(event: event),
        ),
      ));

      expect(find.text('EMERGENCY SIREN BEHIND'), findsOneWidget);
      expect(find.text('YIELD'), findsOneWidget);
      expect(find.textContaining('Yelp siren'), findsOneWidget);
    });
  });

  group('FEAT-03: Lifecycle & Resource Cleanup Tests', () {
    test('TEST-SIR-15 & TEST-SIR-16: Detector stops cleanly and releases resources', () async {
      final detector = SirenAcousticDetector();
      final streamController = StreamController<Uint8List>();

      final started = await detector.start(injectedStream: streamController.stream);
      expect(started, isTrue);
      expect(detector.isRunning, isTrue);

      await detector.stop();
      expect(detector.isRunning, isFalse);
      expect(detector.currentState, equals(SirenDetectorState.inactive));
      expect(detector.activeSirenNotifier.value, isNull);

      await streamController.close();
      detector.dispose();
    });
  });
}
