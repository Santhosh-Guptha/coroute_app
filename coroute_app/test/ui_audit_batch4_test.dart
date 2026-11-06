import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/data/models/membership_model.dart';
import 'package:coroute_app/presentation/safety/safety_settings_screen.dart';
import 'package:coroute_app/presentation/safety/safety_settings_sheet.dart';
import 'package:coroute_app/presentation/safety/sos_hold_screen.dart';
import 'package:coroute_app/presentation/safety/crash_alarm_screen.dart';
import 'package:coroute_app/presentation/diagnostics/pre_ride_phone_check_screen.dart';
import 'package:coroute_app/presentation/safety/oem_battery_guide.dart';
import 'package:coroute_app/presentation/widgets/emergency_sos_sheet.dart';
import 'package:coroute_app/presentation/garage/garage_screen.dart';
import 'package:coroute_app/presentation/subscription/membership_dashboard_screen.dart';
import 'package:coroute_app/presentation/subscription/plan_selector_screen.dart';
import 'package:coroute_app/presentation/subscription/payment_success_screen.dart';
import 'package:coroute_app/presentation/subscription/payment_history_screen.dart';
import 'package:coroute_app/presentation/subscription/subscription_expiry_banner.dart';
import 'package:coroute_app/presentation/trip_planner/trip_creation_payment_alert_sheet.dart';
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
    // SCR-043: Safety Settings Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const SafetySettingsScreen(),
      outputPath: '../docs/ui-audit/screenshots/09_safety_emergency/SCR-043_safety_settings_screen.png',
    );

    // SCR-044: Safety Settings Sheet
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const Scaffold(body: SafetySettingsSheet()),
      outputPath: '../docs/ui-audit/screenshots/09_safety_emergency/SCR-044_safety_settings_sheet.png',
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

    // SCR-056: Plan Selector Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const PlanSelectorScreen(),
      outputPath: '../docs/ui-audit/screenshots/11_membership_payments/SCR-056_plan_selector_screen.png',
    );

    // SCR-058: Payment Success Screen
    const membership = UserMembership(
      membershipId: 'mem_rc_01',
      ownerUserId: 'rider_dev_01',
      category: 'road_captain',
      categoryName: 'Road Captain Pass',
      capacity: 40,
      priceRupees: 599,
      status: 'ACTIVE',
      validUntil: 1772496000000,
    );
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const PaymentSuccessScreen(
        membership: membership,
        transactionReference: 'pay_RC_982401',
        amountPaidInRupees: 599,
      ),
      outputPath: '../docs/ui-audit/screenshots/11_membership_payments/SCR-058_payment_success_screen.png',
    );

    // SCR-059: Payment History Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const PaymentHistoryScreen(),
      outputPath: '../docs/ui-audit/screenshots/11_membership_payments/SCR-059_payment_history_screen.png',
    );

    // SCR-060: Subscription Expiry Banner
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: SubscriptionExpiryBanner(),
          ),
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/11_membership_payments/SCR-060_subscription_expiry_banner.png',
    );

    // SCR-061: Trip Creation Payment Alert Sheet
    const cat = MembershipCategory(
      id: 'road_captain',
      name: 'Road Captain Pass',
      priceRupees: 599,
      capacity: 40,
      description: 'Host up to 40 bikes in a single convoy',
    );
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const Scaffold(
        body: TripCreationPaymentAlertSheet(category: cat),
      ),
      outputPath: '../docs/ui-audit/screenshots/11_membership_payments/SCR-061_trip_creation_payment_alert_sheet.png',
    );

    debugPrint('BATCH_4_CAPTURED_SUCCESSFULLY');
  });
}
