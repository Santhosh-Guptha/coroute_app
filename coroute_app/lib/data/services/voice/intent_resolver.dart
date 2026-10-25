import 'language_resolver.dart';
import 'voice_command_intent.dart';

/// Resolves raw spoken utterances into typed, normalized `VoiceCommandIntent`s.
class IntentResolver {
  /// Resolves an utterance into a typed intent using language-independent canonicalization.
  static VoiceCommandIntent resolve(String rawText, {String currentLocale = 'en-IN'}) {
    final normalized = LanguageResolver.normalize(rawText);
    if (normalized.isEmpty) {
      return VoiceCommandIntent.unknown(
        rawTranscript: rawText,
        sourceLocale: currentLocale,
        confidenceScore: 0.0,
      );
    }

    final normalizedNumbers = LanguageResolver.normalizeNumberWords(normalized);

    // 1. Fast-Path Safety: Emergency SOS (Tier 4)
    if (_matchesAny(normalized, _sosPhrases) &&
        !normalized.contains('hospital') &&
        !normalized.contains('clinic')) {
      return VoiceCommandIntent(
        type: VoiceIntentType.triggerSos,
        sourceLocale: currentLocale,
        confidenceScore: 0.98,
        requiresConfirmation: false,
        rawTranscript: rawText,
        riskTier: 4,
      );
    }

    // 2. Fast-Path Safety: Cancel SOS / I'm OK (Tier 4)
    if (_matchesAny(normalized, _imOkPhrases)) {
      return VoiceCommandIntent(
        type: VoiceIntentType.cancelSos,
        sourceLocale: currentLocale,
        confidenceScore: 0.98,
        requiresConfirmation: false,
        rawTranscript: rawText,
        riskTier: 4,
      );
    }

    // 3. Fast-Path Safety: Silence Siren
    if (_matchesAny(normalized, _silenceSirenPhrases)) {
      return VoiceCommandIntent(
        type: VoiceIntentType.silenceSiren,
        sourceLocale: currentLocale,
        confidenceScore: 0.95,
        requiresConfirmation: false,
        rawTranscript: rawText,
        riskTier: 4,
      );
    }

    // 4. Conversational Affirmation / Confirmation (short phrases only: "yes", "send", "ok")
    if (_isExactOrShortMatch(normalized, _affirmationPhrases)) {
      return VoiceCommandIntent(
        type: VoiceIntentType.confirmAction,
        sourceLocale: currentLocale,
        confidenceScore: 0.95,
        requiresConfirmation: false,
        rawTranscript: rawText,
        riskTier: 1,
      );
    }

    // 5. Conversational Rejection / Cancellation (short phrases only: "cancel", "no", "stop")
    if (_isExactOrShortMatch(normalized, _cancellationPhrases)) {
      return VoiceCommandIntent(
        type: VoiceIntentType.cancelAction,
        sourceLocale: currentLocale,
        confidenceScore: 0.95,
        requiresConfirmation: false,
        rawTranscript: rawText,
        riskTier: 1,
      );
    }

    // 6. Voice Volume Adjustment
    final volumeIntent = _tryParseVolume(normalized, normalizedNumbers, currentLocale, rawText);
    if (volumeIntent != null) return volumeIntent;

    // 7. Language Switch
    final langIntent = _tryParseLanguageSwitch(normalized, currentLocale, rawText);
    if (langIntent != null) return langIntent;

    // 8. Navigation & Essentials (Petrol / Hospital / Puncture)
    final essentialsIntent = _tryParseEssentials(normalized, normalizedNumbers, currentLocale, rawText);
    if (essentialsIntent != null) return essentialsIntent;

    // 9. Trip & Navigation Status Queries
    final statusIntent = _tryParseTripStatus(normalized, currentLocale, rawText);
    if (statusIntent != null) return statusIntent;

    // 10. Repeat Directions
    if (_matchesAny(normalized, _repeatDirectionPhrases)) {
      return VoiceCommandIntent(
        type: VoiceIntentType.repeatDirections,
        sourceLocale: currentLocale,
        confidenceScore: 0.90,
        requiresConfirmation: false,
        rawTranscript: rawText,
        riskTier: 1,
      );
    }

    // 11. Messaging (P2P directed message)
    final messageIntent = _tryParseSendMessage(normalized, currentLocale, rawText);
    if (messageIntent != null) return messageIntent;

    // 12. Broadcast Group Alert
    final alertIntent = _tryParseBroadcastAlert(normalized, currentLocale, rawText);
    if (alertIntent != null) return alertIntent;

    // 13. Intercom Calls & Disconnect
    final intercomIntent = _tryParseIntercom(normalized, currentLocale, rawText);
    if (intercomIntent != null) return intercomIntent;

    // 14. Regroup / Wait Requests
    if (_matchesAny(normalized, _regroupPhrases)) {
      return VoiceCommandIntent(
        type: VoiceIntentType.requestRegroup,
        sourceLocale: currentLocale,
        confidenceScore: 0.90,
        requiresConfirmation: true,
        rawTranscript: rawText,
        riskTier: 2,
      );
    }

    // 15. Propose Stop / Meeting Point
    final stopIntent = _tryParseProposeStop(normalized, currentLocale, rawText);
    if (stopIntent != null) return stopIntent;

    // Fallback: Unknown intent
    return VoiceCommandIntent.unknown(
      rawTranscript: rawText,
      sourceLocale: currentLocale,
      confidenceScore: 0.20,
    );
  }

  // --------------------------------------------------------------------------
  // PARSING SUBROUTINES
  // --------------------------------------------------------------------------

  static VoiceCommandIntent? _tryParseVolume(
    String norm,
    String numNorm,
    String locale,
    String raw,
  ) {
    if (!norm.contains('volume') &&
        !norm.contains('awaaz') &&
        !norm.contains('sabdham') &&
        !norm.contains('dhwani') &&
        !norm.contains('awaj')) {
      return null;
    }

    // Down / reduce / decrease
    if (norm.contains('kammi') ||
        norm.contains('reduce') ||
        norm.contains('decrease') ||
        norm.contains('down') ||
        norm.contains('kam') ||
        norm.contains('ghatao') ||
        norm.contains('kamti') ||
        norm.contains('ochi')) {
      return VoiceCommandIntent(
        type: VoiceIntentType.setVoiceVolume,
        slots: {'delta': -0.2, 'action': 'decrease'},
        sourceLocale: locale,
        confidenceScore: 0.92,
        requiresConfirmation: false,
        rawTranscript: raw,
        riskTier: 1,
      );
    }

    // Up / increase / raise
    if (norm.contains('increase') ||
        norm.contains('badhao') ||
        norm.contains('up') ||
        norm.contains('raise') ||
        norm.contains('athikamaaku') ||
        norm.contains('jasthi') ||
        norm.contains('vadho')) {
      return VoiceCommandIntent(
        type: VoiceIntentType.setVoiceVolume,
        slots: {'delta': 0.2, 'action': 'increase'},
        sourceLocale: locale,
        confidenceScore: 0.92,
        requiresConfirmation: false,
        rawTranscript: raw,
        riskTier: 1,
      );
    }

    // Explicit percent or number
    final match = RegExp(r'(\d+)\s*(?:percent|%|)').firstMatch(numNorm);
    if (match != null) {
      final level = int.tryParse(match.group(1)!);
      if (level != null && level >= 0 && level <= 100) {
        return VoiceCommandIntent(
          type: VoiceIntentType.setVoiceVolume,
          slots: {'level': level, 'action': 'set'},
          sourceLocale: locale,
          confidenceScore: 0.95,
          requiresConfirmation: false,
          rawTranscript: raw,
          riskTier: 1,
        );
      }
    }

    return null;
  }

  static VoiceCommandIntent? _tryParseLanguageSwitch(
    String norm,
    String locale,
    String raw,
  ) {
    if (!norm.contains('language') &&
        !norm.contains('matladu') &&
        !norm.contains('mathu') &&
        !norm.contains('bolo')) {
      return null;
    }

    for (final entry in LanguageResolver.supportedLocales.entries) {
      final code = entry.key;
      final info = entry.value;
      if (norm.contains(info.name.toLowerCase()) ||
          norm.contains(code.substring(0, 2))) {
        return VoiceCommandIntent(
          type: VoiceIntentType.switchLanguage,
          slots: {'targetLocale': code, 'languageName': info.name},
          sourceLocale: locale,
          confidenceScore: 0.94,
          requiresConfirmation: false,
          rawTranscript: raw,
          riskTier: 1,
        );
      }
    }
    return null;
  }

  static VoiceCommandIntent? _tryParseEssentials(
    String norm,
    String numNorm,
    String locale,
    String raw,
  ) {
    if (norm.contains('message') || norm.contains('msg')) return null;
    if (norm.contains('propose stop') ||
        norm.contains('suggest stop') ||
        norm.contains('add stop') ||
        norm.contains('change route') ||
        norm.contains('official stop')) {
      return null;
    }

    String? category;
    if (norm.contains('petrol') ||
        norm.contains('fuel') ||
        norm.contains('gas') ||
        norm.contains('diesel') ||
        norm.contains('bunk') ||
        norm.contains('pump')) {
      category = 'FUEL';
    } else if (norm.contains('puncture') ||
        norm.contains('tyre') ||
        norm.contains('tire') ||
        norm.contains('flat')) {
      category = 'PUNCTURE';
    } else if (norm.contains('hospital') ||
        norm.contains('doctor') ||
        norm.contains('clinic') ||
        norm.contains('medical')) {
      category = 'HOSPITAL';
    } else if (norm.contains('food') ||
        norm.contains('restaurant') ||
        norm.contains('dhaba') ||
        norm.contains('hotel') ||
        norm.contains('chai') ||
        norm.contains('rest stop') ||
        RegExp(r'\brest\b').hasMatch(norm) ||
        norm.contains('coffee')) {
      category = 'FOOD';
    }

    if (category == null) return null;

    double radiusKm = 10.0;
    final distMatch = RegExp(r'(\d+)\s*(?:km|kilometre|kilometer|kilo)').firstMatch(numNorm);
    if (distMatch != null) {
      radiusKm = double.tryParse(distMatch.group(1)!) ?? 10.0;
    }

    return VoiceCommandIntent(
      type: VoiceIntentType.findEssentials,
      slots: {'category': category, 'radiusKm': radiusKm},
      sourceLocale: locale,
      confidenceScore: 0.90,
      requiresConfirmation: false,
      rawTranscript: raw,
      riskTier: 2,
    );
  }

  static VoiceCommandIntent? _tryParseTripStatus(
    String norm,
    String locale,
    String raw,
  ) {
    if (norm.contains('speed') ||
        norm.contains('kiti') ||
        norm.contains('lamb ahe') ||
        norm.contains('pudhil') ||
        norm.contains('kete dur') ||
        norm.contains('beshi') ||
        norm.contains('eta') ||
        norm.contains('trip summary') ||
        norm.contains('next stop') ||
        norm.contains('agla stop') ||
        norm.contains('distance') ||
        norm.contains('status')) {
      String metric = 'summary';
      if (norm.contains('speed') || norm.contains('beshi')) metric = 'speed';
      if (norm.contains('eta')) metric = 'eta';
      if (norm.contains('next stop') || norm.contains('agla stop') || norm.contains('pudhil')) metric = 'next_stop';
      if (norm.contains('distance') || norm.contains('kete dur') || norm.contains('lamb ahe')) metric = 'distance';

      return VoiceCommandIntent(
        type: VoiceIntentType.queryTripStatus,
        slots: {'metric': metric},
        sourceLocale: locale,
        confidenceScore: 0.91,
        requiresConfirmation: false,
        rawTranscript: raw,
        riskTier: 1,
      );
    }
    return null;
  }

  static VoiceCommandIntent? _tryParseSendMessage(
    String norm,
    String locale,
    String raw,
  ) {
    if (!norm.contains('message') && !norm.contains('msg')) return null;
    if (norm.contains('group') || norm.contains('all riders') || norm.contains('sab riders')) {
      return null; // Routed to broadcast
    }

    // Pattern: [Recipient] (ki|ko|ku|ge|inu|ne|la)? message (send chey|bhejo|anupu|maadi|ayakkuka|send)? (:| )? [Body]
    // Example: "Rohit ki message send chey five minutes lo reach avtha"
    // Example: "message Rohit I will be late"
    // Example: "Send message to Rohit five minutes"

    String recipient = '';
    String body = '';

    // Regex 1: "message to [Name] [Body]" or "message [Name] [Body]"
    final regTo = RegExp(r'^(?:send\s+)?message\s+(?:to\s+)?(\w+)(?:[\s:]+(.*))?$', caseSensitive: false);
    final matchTo = regTo.firstMatch(norm);
    if (matchTo != null) {
      recipient = matchTo.group(1) ?? '';
      body = matchTo.group(2) ?? '';
    } else {
      // Regex 2: Indian syntax "[Name] (ki|ko|ku|ge|inu|la|ne|k) message (send chey|bhejo|send|anupu|maadi|pathao|ayakkuka|pothua|moko)? (.*)"
      final regIndian = RegExp(
        r'(\w+)(?:-(?:ki|ko|ku|kku|ge|ke|inu|nu|la|ne|k)|\s+(?:ki|ko|ku|kku|ge|ke|inu|nu|la|ne|k))\s+message(?:\s+(?:send\s+chey|bhejo|send|anupu|maadi|pathao|ayakkuka|pothua|moko))?[\s:]*(.*)',
        caseSensitive: false,
      );
      final matchIndian = regIndian.firstMatch(norm);
      if (matchIndian != null) {
        recipient = matchIndian.group(1) ?? '';
        body = matchIndian.group(2) ?? '';
      }
    }

    if (recipient.isNotEmpty) {
      recipient = LanguageResolver.extractBaseRecipient(recipient);
      return VoiceCommandIntent(
        type: VoiceIntentType.sendMessage,
        slots: {
          'recipient': recipient,
          'body': body.trim(),
        },
        sourceLocale: locale,
        confidenceScore: 0.93,
        requiresConfirmation: true,
        rawTranscript: raw,
        riskTier: 2,
      );
    }

    return null;
  }

  static VoiceCommandIntent? _tryParseBroadcastAlert(
    String norm,
    String locale,
    String raw,
  ) {
    if (!norm.contains('alert') && !norm.contains('broadcast')) return null;

    // "sab riders ko alert bhejo [Body]"
    // "sab riders ko alert bhejo [Body]"
    // "group alert pathao [Body]"
    // "broadcast alert [Body]"
    final reg = RegExp(
      r'(?:sab\s+riders\s+ko\s+alert\s+bhejo|riders\s+ki\s+alert\s+(?:send\s+chey|pampu)?|andhariki\s+alert\s+pampu|group\s+alert\s+(?:pathao|bhejo|send|anupu|kalsi)?|group\s+alert|broadcast\s+alert|all\s+riders\s+alert|alert\s+convoy|alert\s+all\s+riders|alert\s+riders)[\s:]*(.*)',
      caseSensitive: false,
    );
    final match = reg.firstMatch(norm);
    if (match != null) {
      final body = match.group(1)?.trim() ?? '';
      return VoiceCommandIntent(
        type: VoiceIntentType.broadcastAlert,
        slots: {'body': body},
        sourceLocale: locale,
        confidenceScore: 0.94,
        requiresConfirmation: true,
        rawTranscript: raw,
        riskTier: 3,
      );
    }
    return null;
  }

  static VoiceCommandIntent? _tryParseProposeStop(
    String norm,
    String locale,
    String raw,
  ) {
    if (!norm.contains('stop') &&
        !norm.contains('meeting point') &&
        !norm.contains('waypoint') &&
        !norm.contains('change route')) {
      return null;
    }

    if (norm.contains('propose stop') ||
        norm.contains('suggest stop') ||
        norm.contains('meeting point') ||
        norm.contains('add stop') ||
        norm.contains('change route') ||
        norm.contains('ruko') ||
        norm.contains('padav')) {
      final isForce = norm.contains('change route') ||
          norm.contains('official stop') ||
          norm.contains('force waypoint');
      String name = 'Proposed Stop';
      final match = RegExp(r'(?:at|near|pe)\s+([a-zA-Z0-9\s]+)$', caseSensitive: false).firstMatch(norm);
      if (match != null) {
        name = match.group(1)?.trim() ?? name;
      }
      return VoiceCommandIntent(
        type: VoiceIntentType.proposeStop,
        slots: {
          'name': name,
          'forceWaypoint': isForce,
        },
        sourceLocale: locale,
        confidenceScore: 0.90,
        requiresConfirmation: true,
        rawTranscript: raw,
        riskTier: 3,
      );
    }
    return null;
  }

  static VoiceCommandIntent? _tryParseIntercom(
    String norm,
    String locale,
    String raw,
  ) {
    if (!norm.contains('intercom') && !norm.contains('mic')) return null;

    if (norm.contains('disconnect') || norm.contains('end call') || norm.contains('cut')) {
      return VoiceCommandIntent(
        type: VoiceIntentType.disconnectIntercom,
        sourceLocale: locale,
        confidenceScore: 0.95,
        requiresConfirmation: false,
        rawTranscript: raw,
        riskTier: 1,
      );
    }

    if (norm.contains('mute') || norm.contains('unmute') || norm.contains('toggle')) {
      return VoiceCommandIntent(
        type: VoiceIntentType.muteMicrophone,
        sourceLocale: locale,
        confidenceScore: 0.95,
        requiresConfirmation: false,
        rawTranscript: raw,
        riskTier: 1,
      );
    }

    // Connect private intercom:
    // Prefix: "connect (private) intercom to [Name]" / "call [Name] on intercom" / "intercom to [Name]"
    // Postfix: "[Name] (tho|se|ki|ko|ku|ge|inu|la|ne|ke|k|nu|jode)? (private)? intercom (connect|request|karo|chey|pannu|ayakkuka)?"
    String recipient = '';
    final regPrefix = RegExp(
      r'(?:connect\s+(?:private\s+)?intercom\s+(?:to\s+|with\s+)|call\s+(\w+)\s+on\s+(?:private\s+)?intercom|intercom\s+(?:to\s+|with\s+))(\w+)?',
      caseSensitive: false,
    );
    final matchPrefix = regPrefix.firstMatch(norm);
    if (matchPrefix != null) {
      recipient = matchPrefix.group(2) ?? matchPrefix.group(1) ?? '';
    } else {
      final regPostfix = RegExp(
        r'(\w+)(?:-(?:ki|ko|ku|kku|ge|ke|inu|nu|la|ne|k)|\s+(?:ki|ko|ku|kku|ge|ke|inu|nu|la|ne|k|tho|se|jode|saath))\s*(?:private\s+)?intercom(?:\s+(?:connect\s+chey|request\s+ayakkuka|connect|pannunga|karo|bhejo|maadi))?',
        caseSensitive: false,
      );
      final matchPostfix = regPostfix.firstMatch(norm);
      if (matchPostfix != null) {
        recipient = matchPostfix.group(1) ?? '';
      }
    }

    if (recipient.isNotEmpty) {
      recipient = LanguageResolver.extractBaseRecipient(recipient);
      if (recipient.toLowerCase() != 'private' && recipient.toLowerCase() != 'connect') {
        return VoiceCommandIntent(
          type: VoiceIntentType.requestIntercom,
          slots: {'recipient': recipient},
          sourceLocale: locale,
          confidenceScore: 0.92,
          requiresConfirmation: true,
          rawTranscript: raw,
          riskTier: 2,
        );
      }
    }
    return null;
  }

  static bool _isExactOrShortMatch(String text, List<String> phrases) {
    final t = text.trim();
    final words = t.split(RegExp(r'\s+'));
    if (words.length > 3) return false;
    for (final p in phrases) {
      if (t == p || t == '$p please' || t == 'please $p' || t == 'coroute $p') {
        return true;
      }
    }
    return false;
  }

  static bool _matchesAny(String text, List<String> phrases) {
    for (final p in phrases) {
      if (text == p || text.startsWith('$p ') || text.contains(' $p ') || text.endsWith(' $p')) {
        return true;
      }
    }
    return false;
  }

  // --------------------------------------------------------------------------
  // CANONICAL PHRASES
  // --------------------------------------------------------------------------

  static const List<String> _sosPhrases = [
    'coroute emergency', 'coroute sos', 'emergency', 'mayday',
    'distress', 'crash sos', 'need help', 'help me', 'send help',
    'sos sos',
  ];

  static const List<String> _imOkPhrases = [
    'coroute im ok', 'coroute i am ok', 'coroute im okay', 'im ok',
    'i am ok', 'im okay', 'i am okay', 'all good', 'all clear',
    'cancel sos', 'cancel alarm', 'false alarm', 'theek hu',
    'nenu bagunnanu', 'naan nallaa irukken',
  ];

  static const List<String> _silenceSirenPhrases = [
    'coroute silence', 'silence siren', 'silence', 'quiet',
    'stop siren', 'turn off siren', 'mute siren', 'im conscious',
    'i am conscious',
  ];

  static const List<String> _affirmationPhrases = [
    'yes', 'confirm', 'send', 'send it', 'proceed', 'haan', 'ha',
    'avunu', 'aam', 'sari', 'theek hai', 'sahi hai', 'ho', 'hye', 'ok',
  ];

  static const List<String> _cancellationPhrases = [
    'cancel', 'no', 'dont send', 'stop', 'voddhu', 'vodhu', 'nahi',
    'mat bhejo', 'illa', 'vendam', 'beda', 'nako', 'na',
  ];

  static const List<String> _repeatDirectionPhrases = [
    'repeat directions', 'repeat direction', 'turn ekkado cheppu',
    'raste batao', 'repeat turn', 'what is next turn', 'next turn',
  ];

  static const List<String> _regroupPhrases = [
    'coroute regroup', 'regroup convoy', 'wait for me', 'please wait',
    'wait wait', 'hold on', 'stop convoy', 'regroup', 'slow down',
    'wait karo', 'ruk jao', 'aagandi', 'koncham aagandi', 'nillunga', 'thamba', 'swalpa nilli',
  ];
}
