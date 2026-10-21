import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'meta_service.dart';

/// Service managing app version checks, release metadata, and mandatory update enforcement.
class AppVersionService extends ChangeNotifier {
  final MetaService _metaService;

  static const String defaultStoreUrl =
      'https://play.google.com/store/apps/details?id=space.devmonks.coroute_app';

  bool _checking = false;

  AppVersionService(this._metaService) {
    _metaService.addListener(_onMetaChanged);
  }

  void _onMetaChanged() {
    notifyListeners();
  }

  @override
  void dispose() {
    _metaService.removeListener(_onMetaChanged);
    super.dispose();
  }

  bool get checking => _checking;

  /// Whether a mandatory update is required to continue using the application.
  bool get isMandatoryUpdateRequired => _metaService.updateRequired;

  /// Whether an optional newer build is available.
  bool get isUpdateAvailable => _metaService.updateAvailable;

  int get currentBuild => MetaService.currentBuild;
  String get currentVersion => MetaService.currentVersion;

  int get minRequiredBuild => _metaService.meta?.minBuild ?? 0;

  int get latestBuild => _metaService.meta?.latestBuild ?? 0;

  String get downloadUrl {
    final serverUrl = _metaService.meta?.downloadUrl;
    if (serverUrl != null && serverUrl.isNotEmpty) {
      return serverUrl;
    }
    return defaultStoreUrl;
  }

  String get releaseNotes =>
      'Critical Convoy Protocol & Emergency Telemetry Safety Update. '
      'Update is mandatory to maintain real-time convoy audio synchronization, '
      'crash detection telemetry, and emergency outbox escalation.';

  /// Refreshes app metadata from the server.
  Future<void> checkForUpdates() async {
    _checking = true;
    notifyListeners();
    try {
      await _metaService.load();
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  /// Launches the app update URL in the external store / browser.
  Future<bool> launchUpdate() async {
    final uri = Uri.parse(downloadUrl);
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
