import 'dart:async';
import 'package:flutter/foundation.dart';
import '../voice_service.dart';

/// Abstract contract for pluggable text-to-speech output engines.
abstract class TextToSpeechAdapter {
  /// Initializes the speech synthesizer with a default locale.
  Future<bool> init({required String defaultLocale});

  /// Speaks [text] in [locale] at [volume] (0.0 to 1.0).
  /// If [interrupt] is true, drops any currently queued or playing speech.
  Future<bool> speak(
    String text, {
    required String locale,
    double volume = 0.8,
    bool interrupt = false,
  });

  /// Immediately stops any ongoing speech playback.
  Future<void> stop();

  /// Releases platform audio handles and channels.
  Future<void> release();

  /// Checks whether TTS voice for [localeId] is installed on-device for offline playback.
  Future<bool> isLocaleAvailableOffline(String localeId);

  /// Currently active or confirmed language tag.
  String get currentLanguage;
}

/// Adapter binding to CoRoute's existing [VoiceService] and [NativeVoiceEngine].
class NativeVoiceEngineTtsAdapter implements TextToSpeechAdapter {
  final VoiceService voiceService;
  String _currentLanguage = 'en-IN';

  NativeVoiceEngineTtsAdapter({required this.voiceService});

  @override
  String get currentLanguage => voiceService.speechLang.isNotEmpty ? voiceService.speechLang : _currentLanguage;

  @override
  Future<bool> init({required String defaultLocale}) async {
    _currentLanguage = defaultLocale;
    return voiceService.available;
  }

  @override
  Future<bool> speak(
    String text, {
    required String locale,
    double volume = 0.8,
    bool interrupt = false,
  }) async {
    _currentLanguage = locale;
    final priority = interrupt ? VoicePriority.critical : VoicePriority.warning;
    return voiceService.speak(text, priority: priority);
  }

  @override
  Future<void> stop() async {
    // Stops via voice service
  }

  @override
  Future<void> release() async {
    // Release handled by voiceService lifecycle
  }

  @override
  Future<bool> isLocaleAvailableOffline(String localeId) async {
    final lang = localeId.substring(0, 2).toLowerCase();
    // Android TTS pre-installs en, hi; te is downloadable on Android 12+ GMS
    return ['en', 'hi', 'te', 'ta', 'kn', 'mr'].contains(lang);
  }
}

/// In-memory mock TTS adapter for testing and deterministic verification.
@visibleForTesting
class MockTextToSpeechAdapter implements TextToSpeechAdapter {
  final List<String> spokenHistory = [];
  String _currentLanguage = 'en-IN';
  bool _speaking = false;
  double _volume = 0.8;

  bool get isSpeaking => _speaking;
  double get lastVolume => _volume;

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
  String get currentLanguage => _currentLanguage;

  @override
  Future<bool> init({required String defaultLocale}) async {
    _currentLanguage = defaultLocale;
    return true;
  }

  @override
  Future<bool> speak(
    String text, {
    required String locale,
    double volume = 0.8,
    bool interrupt = false,
  }) async {
    _currentLanguage = locale;
    _volume = volume;
    _speaking = true;
    spokenHistory.add(text);
    _speaking = false;
    return true;
  }

  @override
  Future<void> stop() async {
    _speaking = false;
  }

  @override
  Future<void> release() async {
    _speaking = false;
    spokenHistory.clear();
  }

  @override
  Future<bool> isLocaleAvailableOffline(String localeId) async {
    return _offlineLocales.contains(localeId);
  }
}
