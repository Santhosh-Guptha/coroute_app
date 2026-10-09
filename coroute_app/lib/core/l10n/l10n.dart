import 'package:flutter/foundation.dart';
import 'strings_core.dart';
import 'strings_safety.dart';
import 'strings_screens.dart';

/// The rider's language choice for the safety screens and spoken alerts (3.16).
/// Every other screen stays English this round.
enum AppLanguage {
  system,
  en,
  hi,
  te;

  /// Stored value: 'system', 'en', 'hi', 'te'.
  String get code => switch (this) {
        AppLanguage.system => 'system',
        AppLanguage.en => 'en',
        AppLanguage.hi => 'hi',
        AppLanguage.te => 'te',
      };

  /// Shown as is (native names).
  String get label => switch (this) {
        AppLanguage.system => 'System language',
        AppLanguage.en => 'English',
        AppLanguage.hi => 'हिन्दी',
        AppLanguage.te => 'తెలుగు',
      };

  /// Text-to-speech tag; '' for the system choice (resolved through [L10n.ttsTag]).
  String get ttsTag => switch (this) {
        AppLanguage.system => '',
        AppLanguage.en => 'en-IN',
        AppLanguage.hi => 'hi-IN',
        AppLanguage.te => 'te-IN',
      };

  static AppLanguage fromCode(String? c) {
    final s = c?.trim().toLowerCase() ?? '';
    for (final v in values) {
      if (v.code == s) return v;
    }
    return AppLanguage.system;
  }
}

/// Minimal localisation: Map-based tables (en, hi, te), no package.
///
/// `L10n.t('alert.battery.title', {'name': 'Kiran', 'n': 14})` looks the key up in the
/// current language, then English, then returns the key itself; `{name}`-style
/// placeholders are replaced from the arguments. Missing translations never crash:
/// a key present in English only is shown in English.
class L10n {
  L10n._();

  static const List<String> supported = ['en', 'hi', 'te'];

  /// The rider's setting (SettingsService.load / setLanguage).
  static AppLanguage setting = AppLanguage.system;

  /// The phone's language code, set once by main.dart from the platform locale.
  static String systemLanguage = 'en';

  /// The language in use: the setting, or the phone's language when supported, else English.
  static String get current {
    if (setting == AppLanguage.system) return supported.contains(systemLanguage) ? systemLanguage : 'en';
    return setting.code;
  }

  /// Text-to-speech tag for [current]: 'hi-IN', 'te-IN' or 'en-IN'.
  static String get ttsTag => switch (current) {
        'hi' => AppLanguage.hi.ttsTag,
        'te' => AppLanguage.te.ttsTag,
        _ => AppLanguage.en.ttsTag,
      };

  /// Value = [current]; fires when the language in use changes.
  static final ValueNotifier<String> changes = ValueNotifier<String>('en');

  static void setLanguage(AppLanguage l) {
    setting = l;
    changes.value = current;
  }

  /// All tables, in lookup order (the first table that has the key wins).
  static const List<Map<String, Map<String, String>>> tables = [coreStrings, safetyStrings, screenStrings];

  static final RegExp _placeholder = RegExp(r'\{([A-Za-z0-9_]+)\}');

  static String? _lookup(String key, String lang) {
    for (final table in tables) {
      final v = table[lang]?[key];
      if (v != null) return v;
    }
    return null;
  }

  /// The text for [key] in [lang] (default: [current]), falling back to English and
  /// then to the key itself, with `{name}` placeholders replaced from [args].
  static String t(String key, [Map<String, Object?> args = const {}, String? lang]) {
    final l = lang ?? current;
    final raw = _lookup(key, l) ?? (l == 'en' ? null : _lookup(key, 'en')) ?? key;
    if (args.isEmpty || !raw.contains('{')) return raw;
    return raw.replaceAllMapped(_placeholder, (m) {
      final name = m.group(1)!;
      return args.containsKey(name) ? (args[name]?.toString() ?? '') : m.group(0)!;
    });
  }

  /// True when [key] exists in [lang] (default: [current]) in any table.
  static bool has(String key, [String? lang]) => _lookup(key, lang ?? current) != null;
}
