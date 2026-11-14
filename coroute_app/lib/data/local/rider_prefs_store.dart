import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// v3.58: riding interests and style (Profile "My preferences") and the Home nudge snoozes. Kept on this phone
/// only (no server field exists yet; proposal in docs/design/REDESIGN_v3.58.md). Every call is safe without
/// storage (widget tests): reads come back empty, writes do nothing.
class RiderPrefsStore {
  RiderPrefsStore._();

  static const String keyInterests = 'rider_interests_v1';
  static const String keyStyle = 'rider_style_v1';
  static const String keyNudges = 'home_nudge_dismissed_v1';

  static Future<SharedPreferences?> _p() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  static Future<List<String>> interests() async => (await _p())?.getStringList(keyInterests) ?? const [];
  static Future<void> setInterests(List<String> v) async => (await _p())?.setStringList(keyInterests, v.take(12).toList());

  static Future<String> style() async => (await _p())?.getString(keyStyle) ?? '';
  static Future<void> setStyle(String v) async => (await _p())?.setString(keyStyle, v);

  static Future<Map<String, int>> nudgeDismissals() async {
    try {
      final raw = (await _p())?.getString(keyNudges);
      final m = raw == null ? null : jsonDecode(raw);
      return m is Map ? {for (final e in m.entries) if (e.value is num) e.key.toString(): (e.value as num).toInt()} : {};
    } catch (_) {
      return {};
    }
  }

  static Future<void> setNudgeDismissals(Map<String, int> m) async => (await _p())?.setString(keyNudges, jsonEncode(m));
}
