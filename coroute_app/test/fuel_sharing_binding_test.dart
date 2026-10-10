import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/safety_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/fuel_sharing_binding.dart';

class SharingConvoy extends ChangeNotifier implements ConvoyService {
  @override
  Map<String, dynamic>? Function()? fuelEstimate;
  int refreshes = 0;
  @override
  void refreshFuelSharing() {
    refreshes++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class SharingSafety extends ChangeNotifier implements SafetyService {
  double? range = 83.7;
  bool uncertain = false;
  int confirmed = 1700000000000;
  @override
  double? get estimatedUsableKm => range;
  @override
  bool get fuelEstimateUncertain => uncertain;
  @override
  int get fuelConfirmedAt => confirmed;
  void changed() => notifyListeners();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('sharing is opt-in, minimal, withdrawn immediately and detached on disposal', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    await settings.load();
    final convoy = SharingConvoy(), safety = SharingSafety();
    final binding = FuelSharingBinding(convoy, settings, safety);
    expect(convoy.fuelEstimate!(), isNull);
    await settings.setShareFuelEstimate(true);
    expect(convoy.fuelEstimate!(), {
      'usableKm': 83,
      'confirmedAt': 1700000000000,
    });
    expect(convoy.refreshes, 1);
    safety.changed();
    expect(convoy.refreshes, 1, reason: 'unchanged estimate is quiet');
    safety.uncertain = true;
    safety.changed();
    expect(convoy.fuelEstimate!(), isNull);
    expect(convoy.refreshes, 2);
    safety.uncertain = false;
    safety.changed();
    await settings.setShareFuelEstimate(false);
    expect(convoy.fuelEstimate!(), isNull);
    binding.dispose();
    final count = convoy.refreshes;
    await settings.setShareFuelEstimate(true);
    safety.changed();
    expect(convoy.fuelEstimate, isNull);
    expect(convoy.refreshes, count);
    settings.dispose();
    safety.dispose();
    convoy.dispose();
  });
  test(
    'unknown nonfinite and unconfirmed fuel never leaves the phone',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService();
      await settings.load();
      await settings.setShareFuelEstimate(true);
      final convoy = SharingConvoy(), safety = SharingSafety();
      final binding = FuelSharingBinding(convoy, settings, safety);
      for (final range in [null, double.nan, double.infinity]) {
        safety.range = range;
        safety.changed();
        expect(convoy.fuelEstimate!(), isNull);
      }
      safety.range = 80;
      safety.confirmed = 0;
      safety.changed();
      expect(convoy.fuelEstimate!(), isNull);
      binding.dispose();
      settings.dispose();
      safety.dispose();
      convoy.dispose();
    },
  );
}
