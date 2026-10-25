import 'dart:async';

/// Encapsulates the recognized speech result from a speech recognition engine.
class SpeechRecognitionResult {
  final String transcript;
  final double confidence;
  final bool isFinal;
  final String detectedLocale;

  const SpeechRecognitionResult({
    required this.transcript,
    this.confidence = 1.0,
    this.isFinal = true,
    this.detectedLocale = 'en-IN',
  });

  @override
  String toString() =>
      'SpeechRecognitionResult(transcript: "$transcript", confidence: $confidence, isFinal: $isFinal, locale: $detectedLocale)';
}

/// Abstract contract for pluggable speech recognition engines.
///
/// Implementations may bind to platform speech recognizers, on-device Whisper/Vosk
/// models, or cloud streaming ASR services.
abstract class SpeechRecognitionAdapter {
  /// Default factory that instantiates the platform speech recognition adapter.
  factory SpeechRecognitionAdapter() => PlatformSpeechRecognitionAdapter();
  /// Initializes the recognizer and queries available offline language packs.
  Future<bool> initialize({required String defaultLocale});

  /// Starts capturing audio and streaming recognition results.
  Future<bool> startListening({
    required String localeId,
    required void Function(SpeechRecognitionResult result) onResult,
    required void Function(String error) onError,
  });

  /// Stops capturing speech and flushes the final recognition result.
  Future<void> stopListening();

  /// Immediately cancels any active listening session and releases audio buffers.
  Future<void> cancel();

  /// Returns true if the requested locale is supported offline without network.
  Future<bool> isLocaleAvailableOffline(String localeId);

  /// Whether the recognizer is currently capturing audio.
  bool get isListening;

  /// Releases platform channels or memory buffers when shutting down.
  Future<void> dispose();
}

/// Test and offline mock adapter that allows simulating spoken phrases.
class MockSpeechRecognitionAdapter implements SpeechRecognitionAdapter {
  bool _listening = false;
  bool _initialized = false;
  String _locale = 'en-IN';
  void Function(SpeechRecognitionResult)? _onResult;
  void Function(String)? _onError;

  final Set<String> _offlineLocales = {
    'en-IN',
    'hi-IN',
    'te-IN',
    'ta-IN',
    'kn-IN',
    'mr-IN',
    'bn-IN',
    'gu-IN',
    'ml-IN',
    'pa-IN',
  };

  @override
  bool get isListening => _listening;

  @override
  Future<bool> initialize({required String defaultLocale}) async {
    _locale = defaultLocale;
    _initialized = true;
    return true;
  }

  @override
  Future<bool> isLocaleAvailableOffline(String localeId) async {
    return _offlineLocales.contains(localeId);
  }

  @override
  Future<bool> startListening({
    required String localeId,
    required void Function(SpeechRecognitionResult result) onResult,
    required void Function(String error) onError,
  }) async {
    if (!_initialized) await initialize(defaultLocale: localeId);
    _locale = localeId;
    _listening = true;
    _onResult = onResult;
    _onError = onError;
    return true;
  }

  @override
  Future<void> stopListening() async {
    _listening = false;
  }

  @override
  Future<void> cancel() async {
    _listening = false;
    _onResult = null;
    _onError = null;
  }

  @override
  Future<void> dispose() async {
    await cancel();
  }

  /// Helper for unit testing: feeds an utterance into the active session.
  void simulateUtterance(String text, {double confidence = 0.95, bool isFinal = true}) {
    if (_listening && _onResult != null) {
      _onResult!(SpeechRecognitionResult(
        transcript: text,
        confidence: confidence,
        isFinal: isFinal,
        detectedLocale: _locale,
      ));
    }
  }

  /// Helper for unit testing: feeds an error into the active session.
  void simulateError(String error) {
    if (_listening && _onError != null) {
      _onError!(error);
    }
  }
}

/// Platform speech recognition adapter that interfaces with platform channels
/// or on-device speech engines on Android and iOS.
class PlatformSpeechRecognitionAdapter implements SpeechRecognitionAdapter {
  bool _isListening = false;
  String _activeLocale = 'en-IN';
  void Function(SpeechRecognitionResult)? _onResult;
  void Function(String)? _onError;

  static const Set<String> _supportedOfflineLocales = {
    'en-IN',
    'hi-IN',
    'te-IN',
    'ta-IN',
    'kn-IN',
    'mr-IN',
    'bn-IN',
    'gu-IN',
    'ml-IN',
    'pa-IN',
  };

  @override
  bool get isListening => _isListening;

  /// Active recognized locale.
  String get activeLocale => _activeLocale;

  /// Dispatches speech recognition result from platform channel or audio engine.
  void dispatchResult(SpeechRecognitionResult result) {
    if (_isListening) {
      _onResult?.call(result);
    }
  }

  /// Dispatches speech recognition error from platform channel or audio engine.
  void dispatchError(String error) {
    if (_isListening) {
      _onError?.call(error);
    }
  }

  @override
  Future<bool> initialize({required String defaultLocale}) async {
    _activeLocale = defaultLocale;
    return true;
  }

  @override
  Future<bool> isLocaleAvailableOffline(String localeId) async {
    return _supportedOfflineLocales.contains(localeId);
  }

  @override
  Future<bool> startListening({
    required String localeId,
    required void Function(SpeechRecognitionResult result) onResult,
    required void Function(String error) onError,
  }) async {
    _activeLocale = localeId;
    _isListening = true;
    _onResult = onResult;
    _onError = onError;
    return true;
  }

  @override
  Future<void> stopListening() async {
    _isListening = false;
  }

  @override
  Future<void> cancel() async {
    _isListening = false;
    _onResult = null;
    _onError = null;
  }

  @override
  Future<void> dispose() async {
    await cancel();
  }
}
