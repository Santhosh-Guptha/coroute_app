// Round 8: the native voice-cleanup stage (libcoroute_voice: RNNoise + 120 Hz high-pass + wind-gust ducker),
// as seen by the intercom. The FFI binding is voice_native_ffi.dart; voice_native_stub.dart is used where
// dart:ffi does not exist (web). See docs/features_355/voice_clarity.md.
import 'dart:typed_data';

abstract class VoiceDenoiser {
  /// [mode] is a NativeCleanupMode value (lib/domain/audio/voice_clarity.dart).
  void configure({required int mode, required bool windDuck});

  /// Cleans one block of 16 kHz PCM16 (a multiple of 160 samples, at most 960). Returns a new list of the
  /// same length, 12.5 ms later (200 samples of latency in NORMAL / STRONG).
  Int16List process(Int16List block);

  /// Highest RNNoise voice probability of the last [process] call (0..1).
  double get lastVad;

  /// Current wind-duck gain in dB (0 = none).
  double get windGainDb;

  /// New talk session (filters and delay lines; the learned noise is kept).
  void reset();

  void dispose();
}
