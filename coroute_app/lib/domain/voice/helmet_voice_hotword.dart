enum HelmetVoiceHotword {
  imOk,
  emergency,
  fuel,
  regroup,
  intercom,
}

class HotwordMatch {
  final HelmetVoiceHotword hotword;
  final String matchedPhrase;
  final double confidence;
  final String confirmationSpeech;

  const HotwordMatch({
    required this.hotword,
    required this.matchedPhrase,
    required this.confidence,
    required this.confirmationSpeech,
  });

  @override
  String toString() => 'HotwordMatch($hotword, "$matchedPhrase", ${(confidence * 100).round()}%)';
}

/// Hands-free voice recognition parser optimized for full-face motorcycle helmet intercoms
/// (Sena, Cardo, FreedConn) operating in noisy riding environments (wind & exhaust noise).
class HelmetVoiceMatcher {
  static const List<String> _imOkPhrases = [
    'coroute im ok',
    'coroute i am ok',
    'coroute im okay',
    'im ok',
    'i am ok',
    'im okay',
    'i am okay',
    'all good',
    'all clear',
    'cancel sos',
    'cancel alarm',
    'false alarm',
  ];

  static const List<String> _sosPhrases = [
    'coroute sos',
    'coroute emergency',
    'emergency',
    'mayday',
    'distress',
    'crash sos',
    'need help',
    'help me',
    'send help',
  ];

  static const List<String> _fuelPhrases = [
    'coroute fuel',
    'need fuel',
    'low fuel',
    'petrol stop',
    'gas station',
    'fuel stop',
    'refuel',
    'petrol bunk',
  ];

  static const List<String> _regroupPhrases = [
    'coroute regroup',
    'regroup convoy',
    'wait for me',
    'please wait',
    'wait wait',
    'hold on',
    'stop convoy',
    'regroup',
  ];

  static const List<String> _intercomPhrases = [
    'coroute intercom',
    'mute mic',
    'unmute mic',
    'toggle mic',
    'open mic',
    'close mic',
  ];

  /// Cleans and normalizes incoming speech transcript for robust keyword spotting.
  static String normalize(String text) {
    return text
        .toLowerCase()
        .replaceAll("'", "")
        .replaceAll(RegExp(r"[^\w\s]"), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Evaluates speech input against helmet hotwords.
  static HotwordMatch? match(String transcript) {
    final clean = normalize(transcript);
    if (clean.isEmpty) return null;

    // 1. Emergency / SOS (Highest Priority)
    for (final p in _sosPhrases) {
      if (clean == p || clean.contains(p)) {
        return HotwordMatch(
          hotword: HelmetVoiceHotword.emergency,
          matchedPhrase: p,
          confidence: clean == p ? 1.0 : 0.85,
          confirmationSpeech: 'Emergency SOS distress beacon activated.',
        );
      }
    }

    // 2. I'm OK / Cancel Alarm (Safety check confirmation)
    for (final p in _imOkPhrases) {
      if (clean == p || clean.contains(p)) {
        return HotwordMatch(
          hotword: HelmetVoiceHotword.imOk,
          matchedPhrase: p,
          confidence: clean == p ? 1.0 : 0.85,
          confirmationSpeech: 'Check-in confirmed. Glad you are safe.',
        );
      }
    }

    // 3. Fuel Stop Request
    for (final p in _fuelPhrases) {
      if (clean == p || clean.contains(p)) {
        return HotwordMatch(
          hotword: HelmetVoiceHotword.fuel,
          matchedPhrase: p,
          confidence: clean == p ? 1.0 : 0.85,
          confirmationSpeech: 'Fuel stop requested to convoy lead.',
        );
      }
    }

    // 4. Regroup / Wait
    for (final p in _regroupPhrases) {
      if (clean == p || clean.contains(p)) {
        return HotwordMatch(
          hotword: HelmetVoiceHotword.regroup,
          matchedPhrase: p,
          confidence: clean == p ? 1.0 : 0.85,
          confirmationSpeech: 'Regroup wait request sent to convoy.',
        );
      }
    }

    // 5. Intercom Mute Toggle
    for (final p in _intercomPhrases) {
      if (clean == p || clean.contains(p)) {
        return HotwordMatch(
          hotword: HelmetVoiceHotword.intercom,
          matchedPhrase: p,
          confidence: clean == p ? 1.0 : 0.85,
          confirmationSpeech: 'Intercom microphone toggled.',
        );
      }
    }

    return null;
  }
}
