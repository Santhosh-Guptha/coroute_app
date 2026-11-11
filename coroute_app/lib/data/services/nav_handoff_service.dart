import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/navigation/nav_handoff.dart';

/// The rider's navigation app choice (kept on the phone) and the Android bridge that checks which
/// navigation apps are installed and opens a link in one app (`coroute/nav_handoff`,
/// NavHandoffChannel.kt). Without the bridge (tests, iOS) links go through url_launcher.
class NavHandoffService {
  NavHandoffService._();

  static const String prefKey = 'nav_app_choice_v1';
  static const MethodChannel _channel = MethodChannel('coroute/nav_handoff');

  static NavApp _choice = NavApp.auto;
  static bool _loaded = false;

  /// The current choice (Automatic until [load] read the saved one).
  static NavApp get choice => _choice;

  /// Reads the saved choice once (never throws).
  static Future<NavApp> load() async {
    if (_loaded) return _choice;
    try {
      final p = await SharedPreferences.getInstance();
      _choice = NavApp.parse(p.getString(prefKey));
      _loaded = true;
    } catch (_) {
      // No storage (tests without mocks): Automatic.
    }
    return _choice;
  }

  static Future<void> setChoice(NavApp app) async {
    _choice = app;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(prefKey, app.wire);
    } catch (e) {
      debugPrint('nav app save note: $e');
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    _choice = NavApp.auto;
    _loaded = false;
  }

  /// Which navigation apps are installed ({google, mappls}); nulls when the phone cannot tell.
  static Future<({bool? google, bool? mappls})> installed() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return (google: null, mappls: null);
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>('installed', {
        'packages': [NavHandoff.googlePackage, NavHandoff.mapplsPackage],
      });
      if (r == null) return (google: null, mappls: null);
      return (google: r[NavHandoff.googlePackage] as bool?, mappls: r[NavHandoff.mapplsPackage] as bool?);
    } catch (_) {
      return (google: null, mappls: null);
    }
  }

  /// Opens [uri] in [package] (Android). Null when the bridge is missing (caller falls back).
  static Future<bool?> openInPackage(Uri uri, String package) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      return await _channel.invokeMethod<bool>('open', {'uri': uri.toString(), 'package': package});
    } on MissingPluginException {
      return null;
    } catch (_) {
      return false;
    }
  }
}
