/// Generates natural localized voice response strings across supported Indian languages.
class LocalizedResponseService {
  /// Volume confirmation template.
  static String volumeResponse(int level, String locale) {
    return switch (locale.substring(0, 2)) {
      'te' => 'Voice volume $level percent ki set cheyabadindhi.',
      'hi' => 'Voice volume $level percent par set kar diya gaya hai.',
      'ta' => 'Voice volume $level percent aaka maattrappattathu.',
      'kn' => 'Voice volume $level percent ge set maadalagidhe.',
      'mr' => 'Voice volume $level percent var set kela ahe.',
      'bn' => 'Voice volume $level percent e set kora hoyeche.',
      'gu' => 'Voice volume $level percent par set thayu che.',
      'ml' => 'Voice volume $level percent aayi set cheythittund.',
      'pa' => 'Voice volume $level percent te set ho gaya hai.',
      'or' => 'Voice volume $level percent re set hela.',
      'as' => 'Voice volume $level percent t set kora hoise.',
      _ => 'Voice volume set to $level percent.',
    };
  }

  /// Language switch confirmation template.
  static String languageSwitched(String targetLanguageName, String locale) {
    return switch (locale.substring(0, 2)) {
      'te' => 'Language $targetLanguageName ku marchabadindhi.',
      'hi' => 'Bhasha $targetLanguageName par set kar di gayi hai.',
      'ta' => 'Mozhi $targetLanguageName ku maattrappattathu.',
      'kn' => 'Bhashe $targetLanguageName ge badalisalagidhe.',
      'mr' => 'Bhasha $targetLanguageName madhe badalli ahe.',
      'bn' => 'Bhasha $targetLanguageName e poriborton kora hoyeche.',
      'gu' => 'Bhasha $targetLanguageName ma badli che.',
      'ml' => 'Bhasha $targetLanguageName aayi maatti.',
      _ => 'Language switched to $targetLanguageName.',
    };
  }

  /// Confirmation prompt for external messaging or alert.
  static String confirmMessagePrompt({
    required String recipient,
    required String body,
    required String locale,
  }) {
    final preview = body.isEmpty ? 'Quick Check-in' : body;
    return switch (locale.substring(0, 2)) {
      'te' => '$recipient ki message: "$preview". Send cheyyala? Send leda Cancel cheppu.',
      'hi' => '$recipient ko message: "$preview". Bhejna hai? Haan ya Cancel bolo.',
      'ta' => '$recipient ku seithi: "$preview". Anuppattuma? Anupu allathu Cancel sollunga.',
      'kn' => '$recipient ge sandesha: "$preview". Kalisala? Send athava Cancel heli.',
      'mr' => '$recipient la sandesh: "$preview". Pathvaycha ka? Ho ki Cancel sanga.',
      'bn' => '$recipient ke barta: "$preview". Pathabo? Haan ba Cancel bolun.',
      _ => 'Send message to $recipient: "$preview". Say Send or Cancel.',
    };
  }

  /// General confirmation prompt for risk-bearing intents.
  static String confirmationPrompt(dynamic intent, String locale) {
    if (intent.type.toString().contains('sendMessage')) {
      final recipient = (intent.slots['recipient'] as String?) ?? 'rider';
      final body = (intent.slots['body'] as String?) ?? '';
      return confirmMessagePrompt(recipient: recipient, body: body, locale: locale);
    }
    if (intent.type.toString().contains('broadcastAlert')) {
      final body = (intent.slots['body'] as String?) ?? 'hazard warning';
      return switch (locale.substring(0, 2)) {
        'hi' => 'Sab riders ko alert bhejna hai: "$body"? Haan ya Cancel bolo.',
        'te' => 'Riders andhariki alert pampala: "$body"? Send leda Cancel cheppu.',
        _ => 'Broadcast alert to all riders: "$body"? Say Confirm or Cancel.',
      };
    }
    if (intent.type.toString().contains('proposeStop')) {
      final name = (intent.slots['name'] as String?) ?? 'stop point';
      return switch (locale.substring(0, 2)) {
        'hi' => 'Convoy ke liye $name pe stop propose karein? Haan ya Cancel bolo.',
        'te' => '$name daggara stop propose cheyyala? Confirm leda Cancel cheppu.',
        _ => 'Propose stop at $name to convoy? Say Confirm or Cancel.',
      };
    }
    if (intent.type.toString().contains('requestRegroup')) {
      return switch (locale.substring(0, 2)) {
        'hi' => 'Convoy ke liye wait request bhejna hai? Haan ya Cancel bolo.',
        'te' => 'Convoy wait cheyadaniki request pampala? Confirm leda Cancel cheppu.',
        _ => 'Request convoy to wait and regroup? Say Confirm or Cancel.',
      };
    }
    if (intent.type.toString().contains('requestIntercom')) {
      final recipient = (intent.slots['recipient'] as String?) ?? 'rider';
      return switch (locale.substring(0, 2)) {
        'hi' => '$recipient ke sath private intercom connect karein? Haan ya Cancel bolo.',
        'te' => '$recipient tho private intercom connect cheyyala? Confirm leda Cancel cheppu.',
        'ta' => '$recipient udan private intercom inaikattuma? Confirm allathu Cancel sollunga.',
        _ => 'Connect private intercom to $recipient? Say Confirm or Cancel.',
      };
    }
    return 'Confirm action? Say Confirm or Cancel.';
  }

  /// Recipient disambiguation prompt (VA-005: "Which Rohit?").
  static String disambiguatePrompt({
    required String name,
    required List<String> candidates,
    required String locale,
  }) {
    final options = candidates.join(' or ');
    return switch (locale.substring(0, 2)) {
      'te' => 'Ye $name? $options?',
      'hi' => 'Kaunsa $name? $options?',
      'ta' => 'Entha $name? $options?',
      'kn' => 'Yaava $name? $options?',
      'mr' => 'Konta $name? $options?',
      'bn' => 'Kon $name? $options?',
      _ => 'Which $name? $options?',
    };
  }

  /// Message transmitted feedback.
  static String messageSent(String recipient, String locale) {
    return switch (locale.substring(0, 2)) {
      'te' => '$recipient ki message send aipoindhi.',
      'hi' => '$recipient ko message bhej diya gaya.',
      'ta' => '$recipient ku seithi anuppappattathu.',
      'kn' => '$recipient ge sandesha kalisalagidhe.',
      _ => 'Message sent to $recipient.',
    };
  }

  /// Action cancelled feedback.
  static String actionCancelled(String locale) {
    return switch (locale.substring(0, 2)) {
      'te' => 'Action cancel cheyabadindhi.',
      'hi' => 'Action radd kar diya gaya.',
      'ta' => 'Seiyal rathu seiyyappattathu.',
      _ => 'Action cancelled.',
    };
  }

  /// Offline queue notice.
  static String queuedOfflineNotice(String locale) {
    return switch (locale.substring(0, 2)) {
      'te' => 'Offline: Network ledu. Message outbox lo queue cheyabadindhi.',
      'hi' => 'Offline: Signal nahi hai. Message queue me save kar diya gaya.',
      _ => 'Offline mode: Network unavailable. Message queued in outbox.',
    };
  }

  /// Offline unsupported language pack notice (VA-004).
  static String offlineLanguageUnavailable(String languageName, String fallback) {
    return 'Offline mode active. Speech pack for $languageName is not downloaded. Operating in $fallback.';
  }

  /// Emergency SOS triggered speech.
  static String sosTriggered(String locale) {
    return switch (locale.substring(0, 2)) {
      'te' => 'Emergency SOS trigger cheyabadindhi. Convoy mariyu emergency contacts ku alert pampisthunnam.',
      'hi' => 'Emergency SOS trigger ho gaya hai. Convoy aur emergency contacts ko alert bheja ja raha hai.',
      _ => 'Emergency SOS triggered. Alerting convoy and emergency contacts.',
    };
  }

  /// Emergency SOS cancelled / I'm OK speech.
  static String sosCancelled(String locale) {
    return switch (locale.substring(0, 2)) {
      'te' => 'Crash alarm cancel cheyabadindhi. Meeru safe ga unnandhuku santosham.',
      'hi' => 'Crash alarm cancel kar diya gaya. Aap surakshit hain, badiya.',
      _ => 'Crash alarm cancelled. Glad you are safe.',
    };
  }
}
