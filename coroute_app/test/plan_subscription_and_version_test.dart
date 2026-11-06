import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/app_version_service.dart';
import 'package:coroute_app/data/services/meta_service.dart';

class _TestMetaService extends MetaService {
  _TestMetaService() : super(ApiClient());

  AppMeta? _testMeta;

  void updateMeta(AppMeta? meta) {
    _testMeta = meta;
    notifyListeners();
  }

  @override
  AppMeta? get meta => _testMeta;

  @override
  bool get updateRequired {
    if (MetaService.currentBuild <= 0 || _testMeta == null) return false;
    return _testMeta!.minBuild > MetaService.currentBuild;
  }

  @override
  bool get updateAvailable {
    if (MetaService.currentBuild <= 0 || _testMeta == null) return false;
    return _testMeta!.latestBuild > MetaService.currentBuild;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The PlanSubscriptionService / tier group was retired with the legacy tiers: plans are the
  // membership plans now (see membership_plan_access_test.dart).
  group('AppVersionService & Force Update Tests', () {
    tearDown(() {
      MetaService.currentBuild = 0;
    });

    test('MetaService version metadata drives isMandatoryUpdateRequired accurately', () {
      final metaService = _TestMetaService();
      final versionService = AppVersionService(metaService);

      // Initially no update required
      expect(versionService.isMandatoryUpdateRequired, isFalse);
      expect(versionService.isUpdateAvailable, isFalse);

      // Client build is 100, server requires minBuild 105
      MetaService.currentBuild = 100;
      metaService.updateMeta(const AppMeta(
        minBuild: 105,
        latestBuild: 110,
        downloadUrl: 'https://coroute.space/downloads/latest.apk',
        privacyUrl: '',
        termsUrl: '',
        supportEmail: '',
        googleSignIn: false,
      ));

      expect(versionService.isMandatoryUpdateRequired, isTrue);
      expect(versionService.isUpdateAvailable, isTrue);
      expect(versionService.minRequiredBuild, 105);
      expect(versionService.latestBuild, 110);
      expect(versionService.downloadUrl, 'https://coroute.space/downloads/latest.apk');

      // Client updates to 105: mandatory barrier clears, but optional update available
      MetaService.currentBuild = 105;
      metaService.updateMeta(const AppMeta(
        minBuild: 105,
        latestBuild: 110,
        downloadUrl: 'https://coroute.space/downloads/latest.apk',
        privacyUrl: '',
        termsUrl: '',
        supportEmail: '',
        googleSignIn: false,
      ));

      expect(versionService.isMandatoryUpdateRequired, isFalse);
      expect(versionService.isUpdateAvailable, isTrue);

      // Client is at latest build 110: fully up to date
      MetaService.currentBuild = 110;
      metaService.updateMeta(const AppMeta(
        minBuild: 105,
        latestBuild: 110,
        downloadUrl: '',
        privacyUrl: '',
        termsUrl: '',
        supportEmail: '',
        googleSignIn: false,
      ));

      expect(versionService.isMandatoryUpdateRequired, isFalse);
      expect(versionService.isUpdateAvailable, isFalse);
      expect(versionService.downloadUrl, AppVersionService.defaultStoreUrl);

      versionService.dispose();
    });
  });
}
