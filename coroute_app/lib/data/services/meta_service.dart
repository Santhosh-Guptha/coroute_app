import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
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

  /// Version and build number of this binary, read from the installed
  /// package (pubspec `version: x.y.z+N`) by [readPackageInfo] before the
  /// app starts. 0 means unknown, and an unknown build is never blocked.
  static int currentBuild = 0;
  static String currentVersion = '';

  static Future<void> readPackageInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      currentVersion = info.version;
      currentBuild = int.tryParse(info.buildNumber) ?? 0;
      ApiClient.appBuild = currentBuild;
    } catch (_) {
      // Leave unknown.
    }
  }

  AppMeta? _meta;
  bool _loaded = false;

  AppMeta? get meta => _meta;
  bool get loaded => _loaded;
  bool get updateRequired => currentBuild > 0 && _meta != null && _meta!.minBuild > currentBuild;
  bool get updateAvailable => currentBuild > 0 && _meta != null && _meta!.latestBuild > currentBuild;

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
