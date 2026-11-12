import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 3.57: the rider's phone number, emergency contact and e-mail kept on the phone in the Android Keystore
/// (flutter_secure_storage) instead of plain SharedPreferences (docs/features_355/sessions_and_security.md).
///
/// * Reads come from secure storage first; a value still in SharedPreferences (builds before 3.57) is moved
///   over once and removed from SharedPreferences (silent migration, nothing is lost).
/// * When the keystore is briefly unavailable (right after boot) or missing (tests), SharedPreferences is used,
///   so an offline SOS never loses the emergency contact.
class SensitivePrefs {
  SensitivePrefs({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const String _prefix = 'coroute_secure_';

  Future<String?> read(SharedPreferences prefs, String key) async {
    String? v;
    var secureOk = true;
    try {
      v = await _storage.read(key: '$_prefix$key');
    } catch (e) {
      secureOk = false;
      debugPrint('Secure storage read note: ${e.runtimeType}');
    }
    final legacy = prefs.getString(key);
    if ((v == null || v.isEmpty) && legacy != null && legacy.isNotEmpty) {
      if (secureOk && await _write(key, legacy)) await prefs.remove(key);
      return legacy;
    }
    if (v != null && legacy != null && secureOk) await prefs.remove(key); // an older copy left behind
    return v;
  }

  Future<void> write(SharedPreferences prefs, String key, String value) async {
    if (await _write(key, value)) {
      if (prefs.containsKey(key)) await prefs.remove(key);
    } else {
      await prefs.setString(key, value); // keystore unavailable: never lose an emergency contact
    }
  }

  Future<void> remove(SharedPreferences prefs, String key) async {
    try {
      await _storage.delete(key: '$_prefix$key');
    } catch (_) {}
    await prefs.remove(key);
  }

  Future<bool> _write(String key, String value) async {
    try {
      await _storage.write(key: '$_prefix$key', value: value);
      return true;
    } catch (e) {
      debugPrint('Secure storage write note: ${e.runtimeType}');
      return false;
    }
  }
}
