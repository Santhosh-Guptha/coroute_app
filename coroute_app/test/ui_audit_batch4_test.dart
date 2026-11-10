import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/presentation/settings/settings_screen.dart';
import 'package:coroute_app/presentation/safety/sos_hold_screen.dart';
import 'package:coroute_app/presentation/safety/crash_alarm_screen.dart';
import 'package:coroute_app/presentation/diagnostics/pre_ride_phone_check_screen.dart';
import 'package:coroute_app/presentation/safety/oem_battery_guide.dart';
import 'package:coroute_app/presentation/widgets/emergency_sos_sheet.dart';
import 'package:coroute_app/presentation/garage/garage_screen.dart';
import 'package:coroute_app/presentation/subscription/membership_dashboard_screen.dart';
import 'ui_audit_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AuditEnvironment env;

  setUp(() async {
    env = await AuditEnvironment.create();
  });

  tearDown(() {
    env.dispose();
  });

  testWidgets('Batch 4: Safety, Fuel, Vehicle, and Membership Payments', (tester) async {
    // SCR-043: Settings (the one rider settings screen; replaces the old safety
    // settings screen and the safety settings sheet, SCR-044).
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const SettingsScreen(),
      outputPath: '../docs/ui-audit/screenshots/09_safety_emergency/SCR-043_settings_screen.png',
    );

    // SCR-045: SOS Hold Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: SosHoldScreen(
        onSend: () {},
        onCancel: () {},
      ),
      outputPath: '../docs/ui-audit/screenshots/09_safety_emergency/SCR-045_sos_hold_screen.png',
    );

    // SCR-046: Crash Alarm Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const CrashAlarmScreen(),
      outputPath: '../docs/ui-audit/screenshots/09_safety_emergency/SCR-046_crash_alarm_screen.png',
    );

    // SCR-049: Pre-ride Phone Check Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const PreRidePhoneCheckScreen(autoRun: false),
      outputPath: '../docs/ui-audit/screenshots/09_safety_emergency/SCR-049_pre_ride_phone_check.png',
    );

    // SCR-050: OEM Battery Optimization Guide
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const Scaffold(
        body: OemBatteryGuide(brand: OemBrand.xiaomi),
      ),
      outputPath: '../docs/ui-audit/screenshots/09_safety_emergency/SCR-050_oem_battery_guide.png',
    );

    // SCR-051: Emergency SOS Sheet
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const Scaffold(
        body: EmergencySosSheet(
          lat: 12.9716,
          lng: 77.5946,
          alertId: 'alert_sos_01',
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/09_safety_emergency/SCR-051_emergency_sos_sheet.png',
    );

    // SCR-054: Garage Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const GarageScreen(),
      outputPath: '../docs/ui-audit/screenshots/10_fuel_vehicle/SCR-054_garage_screen.png',
    );

    // SCR-055: Membership Dashboard Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const MembershipDashboardScreen(),
      outputPath: '../docs/ui-audit/screenshots/11_membership_payments/SCR-055_membership_dashboard.png',
    );

    // SCR-056 (Plan Selector) retired: it was an alias of the membership dashboard (SCR-055).

    // SCR-058 (payment success) and SCR-059 (payment history) retired: the app sells nothing
    // (Play payments policy, docs/features_355/play_payments_policy.md).

    // SCR-060 (legacy tier expiry banner) retired with the legacy tiers.

    // SCR-061 (trip creation payment alert sheet) retired: the app never opened it.

    debugPrint('BATCH_4_CAPTURED_SUCCESSFULLY');
  });
}
