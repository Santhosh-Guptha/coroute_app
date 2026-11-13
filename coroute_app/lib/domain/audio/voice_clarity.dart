// Round 8 voice clarity (docs/features_355/voice_clarity.md): the rider's noise-reduction choice and how it
// maps onto the processing chain. Pure Dart: unit tested with tool/pure_dart_test.
//
// Chain per 20 ms frame of the ride mic (16 kHz):
//   native stage (libcoroute_voice, RNNoise + 120 Hz high-pass + wind-gust ducker; dart:ffi)
//   -> Dart post-stage (VoiceCleanup: voice gate for hands-free, breath cut, AGC, limiter)
// When the native library is missing (not built for the ABI, or failed to load) the 3.55 pure-Dart chain
// (high-pass + Wiener noise suppression + breath / wind classes + gate + AGC) is used, as before.

/// Settings > Intercom options > Noise reduction.
enum NoiseReduction {
  /// Default: full RNNoise suppression (helmet wind, engine drone, road roar, traffic).
  strong,

  /// RNNoise with the original mixed back at -12 dB: a more natural sound, suppression capped near 12 dB.
  normal,

  /// No noise reduction (the voice gate, level control and limiter still run).
  off;

  /// Stored value (SharedPreferences `noise_reduction_v1`).
  String get storage => name;

  String get label => switch (this) {
        NoiseReduction.strong => 'Strong',
        NoiseReduction.normal => 'Normal',
        NoiseReduction.off => 'Off',
      };

  String get hint => switch (this) {
        NoiseReduction.strong => 'Takes out wind, engine and road noise. Best on the move.',
        NoiseReduction.normal => 'Lighter cleanup that keeps more of the natural sound.',
        NoiseReduction.off => 'Your voice is sent as the mic hears it.',
      };

  /// Unknown or missing values mean the default ([strong]).
  static NoiseReduction parse(String? v) {
    for (final m in NoiseReduction.values) {
      if (m.name == v) return m;
    }
    return NoiseReduction.strong;
  }
}

/// Native stage modes (must match CV_MODE_* in android/app/src/main/cpp/coroute_voice.h).
class NativeCleanupMode {
  static const int off = 0;
  static const int normal = 1;
  static const int strong = 2;
}

/// What runs for one talk session.
class VoiceChainPlan {
  /// CV_MODE_* for the native stage, or null when the native stage does not run.
  final int? nativeMode;

  /// Native wind-gust ducker (Wind-noise mode).
  final bool nativeWindDuck;

  /// Dart VoiceCleanup: noise / breath processing at all (false = gate, AGC and limiter only).
  final bool dartSuppressNoise;

  /// Dart VoiceCleanup: the STFT Wiener stage (only without the native stage).
  final bool dartSpectral;

  /// Dart VoiceCleanup: the 20 ms wind class (only without the native stage).
  final bool dartWind;

  const VoiceChainPlan({
    required this.nativeMode,
    required this.nativeWindDuck,
    required this.dartSuppressNoise,
    required this.dartSpectral,
    required this.dartWind,
  });

  /// Added latency of the cleanup in 16 kHz samples (native 200 + Dart STFT 192).
  int get latencySamples => (nativeMode != null ? 200 : 0) + 192;

  /// [choice] the rider's setting, [windNoiseMode] the rider's Wind-noise mode switch, [adminOn] the admin
  /// switch 'voiceCleanup' (off = no noise processing at all), [nativeAvailable] libcoroute_voice loaded.
  static VoiceChainPlan forChoice(NoiseReduction choice, {required bool windNoiseMode, required bool adminOn, required bool nativeAvailable}) {
    if (!adminOn || choice == NoiseReduction.off) {
      return const VoiceChainPlan(nativeMode: null, nativeWindDuck: false, dartSuppressNoise: false, dartSpectral: false, dartWind: false);
    }
    if (nativeAvailable) {
      return VoiceChainPlan(
        nativeMode: choice == NoiseReduction.strong ? NativeCleanupMode.strong : NativeCleanupMode.normal,
        nativeWindDuck: windNoiseMode,
        dartSuppressNoise: true, // breath cut stays
        dartSpectral: false,
        dartWind: false,
      );
    }
    // 3.55 pure-Dart chain (fallback). Wind-noise mode maps onto its wind-gust class.
    return VoiceChainPlan(nativeMode: null, nativeWindDuck: false, dartSuppressNoise: true, dartSpectral: true, dartWind: windNoiseMode);
  }

  @override
  bool operator ==(Object other) =>
      other is VoiceChainPlan &&
      other.nativeMode == nativeMode &&
      other.nativeWindDuck == nativeWindDuck &&
      other.dartSuppressNoise == dartSuppressNoise &&
      other.dartSpectral == dartSpectral &&
      other.dartWind == dartWind;

  @override
  int get hashCode => Object.hash(nativeMode, nativeWindDuck, dartSuppressNoise, dartSpectral, dartWind);

  @override
  String toString() =>
      'VoiceChainPlan(native: $nativeMode, windDuck: $nativeWindDuck, suppress: $dartSuppressNoise, spectral: $dartSpectral, wind: $dartWind)';
}
