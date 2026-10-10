import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/domain/safety/fuel_profile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('fuel profile and sharing belong to an account; sign-out clears immediately', () async {
    SharedPreferences.setMockInitialValues({'share_fuel_estimate_v1': true});
    final settings = SettingsService();
    await settings.load();
    await settings.selectFuelUser('a');
    expect(settings.shareFuelEstimate, false);
    await settings.setFuelProfile(const FuelProfile(fullRangeKm: 300));
    await settings.setShareFuelEstimate(true);
    await settings.selectFuelUser('b');
    expect(settings.shareFuelEstimate, false);
    expect(settings.fuelProfile.valid, false);
    await settings.setFuelProfile(const FuelProfile(fullRangeKm: 200));
    await settings.selectFuelUser('a');
    expect(settings.shareFuelEstimate, true);
    expect(settings.fuelProfile.fullRangeKm, 300);
    final signout = settings.selectFuelUser(null);
    expect(settings.shareFuelEstimate, false);
    expect(settings.fuelProfile.valid, false);
    await signout;
    settings.dispose();
  });
  test(
    'rapid account switching cannot load the prior account preference',
    () async {
      SharedPreferences.setMockInitialValues({
        'share_fuel_estimate_v1:user:a': true,
      });
      final settings = SettingsService();
      await Future.wait([
        settings.selectFuelUser('a'),
        settings.selectFuelUser('b'),
      ]);
      expect(settings.shareFuelEstimate, false);
      settings.dispose();
    },
  );
}
