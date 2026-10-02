import 'package:flutter/foundation.dart';
import 'api_client.dart';

/// Server-provided app metadata: minimum supported build, links and support contact.
class AppMeta {
  final int minBuild;
  final int latestBuild;
  final String downloadUrl;
  final String privacyUrl;
  final String termsUrl;
  final String supportEmail;
  final bool googleSignIn;
  const AppMeta({
    required this.minBuild,
    required this.latestBuild,
    required this.downloadUrl,
    required this.privacyUrl,
    required this.termsUrl,
    required this.supportEmail,
    required this.googleSignIn,
  });

  factory AppMeta.fromJson(Map<String, dynamic> j) => AppMeta(
        minBuild: (j['minBuild'] as num?)?.toInt() ?? 0,
        latestBuild: (j['latestBuild'] as num?)?.toInt() ?? 0,
        downloadUrl: j['downloadUrl']?.toString() ?? '',
        privacyUrl: j['privacyUrl']?.toString() ?? '',
        termsUrl: j['termsUrl']?.toString() ?? '',
        supportEmail: j['supportEmail']?.toString() ?? '',
        googleSignIn: j['googleSignIn'] == true,
      );
}

class MetaService extends ChangeNotifier {
  MetaService(this._api);
  final ApiClient _api;

  /// Build number of this binary. Keep in sync with pubspec `version: x.y.z+N`.
  static const int currentBuild = 60;
  static const String currentVersion = '3.0.0';

  AppMeta? _meta;
  bool _loaded = false;

  AppMeta? get meta => _meta;
  bool get loaded => _loaded;
  bool get updateRequired => _meta != null && _meta!.minBuild > currentBuild;
  bool get updateAvailable => _meta != null && _meta!.latestBuild > currentBuild;

  Future<void> load() async {
    try {
      final res = await _api.get('/meta', timeout: const Duration(seconds: 6));
      if (res is Map) _meta = AppMeta.fromJson(Map<String, dynamic>.from(res));
    } catch (e) {
      debugPrint('meta note: $e'); // offline: never block the app on this
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }
}
