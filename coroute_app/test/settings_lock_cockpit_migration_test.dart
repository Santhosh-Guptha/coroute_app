// "Show cockpit on lock screen while riding" keeps the 3.54 key ("Show ride on lock screen"), so the rider's
// choice stays; the Ride screen choices (when idle, keep screen on) are saved and read back.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/constants/network_constants.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/domain/tracking/screen_awake_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the key is the one of 3.54', () {
    expect(NetworkConstants.keyRideOnLockScreen, 'coroute_ride_lock_screen');
  });

  test('default on (new install)', () async {
    SharedPreferences.setMockInitialValues({});
    final s = SettingsService();
    await s.load();
    expect(s.rideOnLockScreen, isTrue);
    expect(s.rideIdleMode, RideIdleMode.aod);
    expect(s.keepScreenOnMode, KeepScreenOnMode.whileMoving);
  });

  test('a 3.54 "off" stays off through the 3.55 migrations (never forced on)', () async {
    SharedPreferences.setMockInitialValues({NetworkConstants.keyRideOnLockScreen: false});
    final s = SettingsService();
    await s.load();
    expect(s.rideOnLockScreen, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(NetworkConstants.keyRideOnLockScreen), isFalse);
    expect(prefs.getInt(SettingsService.keySafetyDefaultsVersion), SettingsService.safetyDefaultsVersion, reason: 'migrations ran');
    expect(SettingsService.alwaysOnKeys, isNot(contains(NetworkConstants.keyRideOnLockScreen)));
    expect(SettingsService.safetyDefaultsV1Keys, isNot(contains(NetworkConstants.keyRideOnLockScreen)));

    // And on the next start.
    final again = SettingsService();
    await again.load();
    expect(again.rideOnLockScreen, isFalse);
  });

  test('a stored "on" stays on; an already migrated phone keeps its choice', () async {
    SharedPreferences.setMockInitialValues({
      NetworkConstants.keyRideOnLockScreen: true,
      SettingsService.keySafetyDefaultsVersion: SettingsService.safetyDefaultsVersion,
    });
    final s = SettingsService();
    await s.load();
    expect(s.rideOnLockScreen, isTrue);
    await s.setRideOnLockScreen(false);
    final t = SettingsService();
    await t.load();
    expect(t.rideOnLockScreen, isFalse);
    await t.setRideOnLockScreen(true);
    final u = SettingsService();
    await u.load();
    expect(u.rideOnLockScreen, isTrue);
  });

  test('the switch notifies listeners (the lock-screen service turns the window off at once)', () async {
    SharedPreferences.setMockInitialValues({});
    final s = SettingsService();
    await s.load();
    var n = 0;
    s.addListener(() => n++);
    await s.setRideOnLockScreen(false);
    await s.setRideOnLockScreen(false); // no change
    expect(n, 1);
  });

  test('when idle and keep screen on are saved and read back', () async {
    SharedPreferences.setMockInitialValues({});
    final s = SettingsService();
    await s.load();
    await s.setRideIdleMode(RideIdleMode.sleep);
    await s.setKeepScreenOnMode(KeepScreenOnMode.always);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(SettingsService.keyRideIdleMode), 'sleep');
    expect(prefs.getString(SettingsService.keyKeepScreenOnMode), 'always');
    final t = SettingsService();
    await t.load();
    expect(t.rideIdleMode, RideIdleMode.sleep);
    expect(t.keepScreenOnMode, KeepScreenOnMode.always);
  });
}
