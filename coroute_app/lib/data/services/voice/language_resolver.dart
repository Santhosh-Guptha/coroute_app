/// Metadata and language resolution utilities for 12 Indian locales and code-switching.
class VoiceLocaleInfo {
  final String code;
  final String name;
  final String nativeName;
  final String script;
  final bool hasOfflineSupport;

  const VoiceLocaleInfo({
    required this.code,
    required this.name,
    required this.nativeName,
    required this.script,
    this.hasOfflineSupport = true,
  });
}

class LanguageResolver {
  static const Map<String, VoiceLocaleInfo> supportedLocales = {
    'en-IN': VoiceLocaleInfo(code: 'en-IN', name: 'Indian English', nativeName: 'English (India)', script: 'Latn', hasOfflineSupport: true),
    'te-IN': VoiceLocaleInfo(code: 'te-IN', name: 'Telugu', nativeName: 'తెలుగు', script: 'Telu', hasOfflineSupport: true),
    'hi-IN': VoiceLocaleInfo(code: 'hi-IN', name: 'Hindi', nativeName: 'हिन्दी', script: 'Deva', hasOfflineSupport: true),
    'ta-IN': VoiceLocaleInfo(code: 'ta-IN', name: 'Tamil', nativeName: 'தமிழ்', script: 'Taml', hasOfflineSupport: true),
    'kn-IN': VoiceLocaleInfo(code: 'kn-IN', name: 'Kannada', nativeName: 'ಕನ್ನಡ', script: 'Knda', hasOfflineSupport: true),
    'mr-IN': VoiceLocaleInfo(code: 'mr-IN', name: 'Marathi', nativeName: 'मराठी', script: 'Deva', hasOfflineSupport: true),
    'ml-IN': VoiceLocaleInfo(code: 'ml-IN', name: 'Malayalam', nativeName: 'മലയാളം', script: 'Mlym', hasOfflineSupport: true),
    'bn-IN': VoiceLocaleInfo(code: 'bn-IN', name: 'Bengali', nativeName: 'বাংলা', script: 'Beng', hasOfflineSupport: true),
    'gu-IN': VoiceLocaleInfo(code: 'gu-IN', name: 'Gujarati', nativeName: 'ગુજરાતી', script: 'Gujr', hasOfflineSupport: true),
    'pa-IN': VoiceLocaleInfo(code: 'pa-IN', name: 'Punjabi', nativeName: 'ਪੰਜਾਬੀ', script: 'Guru', hasOfflineSupport: true),
    'or-IN': VoiceLocaleInfo(code: 'or-IN', name: 'Odia', nativeName: 'ଓଡ଼ିଆ', script: 'Orya', hasOfflineSupport: false),
    'as-IN': VoiceLocaleInfo(code: 'as-IN', name: 'Assamese', nativeName: 'অসমীয়া', script: 'Beng', hasOfflineSupport: false),
  };

  /// Normalizes spoken text by cleaning noise punctuation and casing.
  static String normalize(String text) {
    var cleaned = text.trim().toLowerCase();
    cleaned = cleaned.replaceAll(RegExp(r'[,.!?":;]'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ');
    return cleaned.trim();
  }

  /// Maps verbal number representations across Indian languages to integer digits.
  static String normalizeNumberWords(String text) {
    var out = text;
    final map = {
      'one': '1', 'two': '2', 'three': '3', 'four': '4', 'five': '5',
      'six': '6', 'seven': '7', 'eight': '8', 'nine': '9', 'ten': '10',
      'ek': '1', 'do': '2', 'teen': '3', 'char': '4', 'paanch': '5', 'panch': '5',
      'okati': '1', 'rendu': '2', 'moodu': '3', 'nalugu': '4', 'aidu': '5',
      'onnu': '1', 'rendu_ta': '2', 'moonu': '3', 'naalu': '4', 'anju': '5',
      'ondhu': '1', 'eradu': '2', 'mooru': '3', 'naalku': '4', 'aidhu': '5',
    };

    map.forEach((word, digit) {
      out = out.replaceAll(RegExp('\\b$word\\b', caseSensitive: false), digit);
    });
    return out;
  }

  /// Strips regional grammatical postpositions and dative suffixes from a recipient name.
  /// Example: "Rohit-ki" -> "Rohit", "Rohit ko" -> "Rohit", "Rohit-nu" -> "Rohit".
  static String extractBaseRecipient(String token) {
    var t = token.trim();
    if (t.contains('-')) {
      final parts = t.split('-');
      if (parts.length == 2) {
        final suffix = parts[1].toLowerCase();
        if (['ki', 'ko', 'ku', 'kku', 'ge', 'ke', 'nu', 'inu', 'la', 'ne', 'k'].contains(suffix)) {
          final base = parts[0];
          return base.isNotEmpty ? base[0].toUpperCase() + base.substring(1) : base;
        }
      }
    }

    // Trailing word suffixes
    final suffixes = [
      RegExp(r'(\w+)(?:ki|ko|ku|kku|ge|ke|inu|nu|la|ne|k)$', caseSensitive: false),
    ];
    for (final r in suffixes) {
      final match = r.firstMatch(t);
      if (match != null && match.group(1) != null && match.group(1)!.length >= 3) {
        final base = match.group(1)!;
        return base.isNotEmpty ? base[0].toUpperCase() + base.substring(1) : base;
      }
    }
    return t.isNotEmpty ? t[0].toUpperCase() + t.substring(1) : t;
  }

  /// Evaluates phonetic or Levenshtein similarity between two names [0.0 .. 1.0].
  static double calculateSimilarity(String a, String b) {
    final s1 = a.trim().toLowerCase();
    final s2 = b.trim().toLowerCase();
    if (s1 == s2) return 1.0;
    if (s1.isEmpty || s2.isEmpty) return 0.0;
    if (s1.contains(s2) || s2.contains(s1)) return 0.85;

    final dist = _levenshtein(s1, s2);
    final maxLen = s1.length > s2.length ? s1.length : s2.length;
    return (1.0 - (dist / maxLen)).clamp(0.0, 1.0);
  }

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    List<int> v0 = List<int>.filled(b.length + 1, 0);
    List<int> v1 = List<int>.filled(b.length + 1, 0);

    for (int i = 0; i < v0.length; i++) {
      v0[i] = i;
    }

    for (int i = 0; i < a.length; i++) {
      v1[0] = i + 1;
      for (int j = 0; j < b.length; j++) {
        int cost = (a[i] == b[j]) ? 0 : 1;
        v1[j + 1] = [v1[j] + 1, v0[j + 1] + 1, v0[j] + cost].reduce((curr, next) => curr < next ? curr : next);
      }
      for (int j = 0; j < v0.length; j++) {
        v0[j] = v1[j];
      }
    }
    return v1[b.length];
  }
}
