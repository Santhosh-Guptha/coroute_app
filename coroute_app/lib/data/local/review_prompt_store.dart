import 'package:shared_preferences/shared_preferences.dart';

/// What the store-rating prompt remembers, on the phone only: when this install
/// was first seen, when the prompt was last shown and "Don't ask again".
/// Every call is safe and never throws.
class ReviewPromptStore {
  ReviewPromptStore._();

  static const String keyFirstSeen = 'coroute_first_seen_at';
  static const String keyLastShown = 'coroute_rate_prompt_shown_at';
  static const String keyNever = 'coroute_rate_prompt_never';

  /// Called at start-up: keeps the first time this install ran.
  static Future<void> markFirstSeen({int? nowMs}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if ((prefs.getInt(keyFirstSeen) ?? 0) > 0) return;
      await prefs.setInt(keyFirstSeen, nowMs ?? DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  static Future<({int firstSeen, int lastShown, bool never})> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (
        firstSeen: prefs.getInt(keyFirstSeen) ?? 0,
        lastShown: prefs.getInt(keyLastShown) ?? 0,
        never: prefs.getBool(keyNever) ?? false,
      );
    } catch (_) {
      // Unreadable: behave as "asked just now", so nothing is shown.
      return (firstSeen: 0, lastShown: DateTime.now().millisecondsSinceEpoch, never: false);
    }
  }

  static Future<bool> markShown({int? nowMs}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.setInt(keyLastShown, nowMs ?? DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      return false;
    }
  }

  static Future<void> neverAskAgain() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(keyNever, true);
    } catch (_) {}
  }
}
