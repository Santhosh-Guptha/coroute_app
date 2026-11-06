import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/presentation/splash/splash_screen.dart';
import 'package:coroute_app/presentation/onboarding/onboarding_screen.dart';
import 'package:coroute_app/presentation/onboarding/permissions_screen.dart';
import 'package:coroute_app/presentation/auth/login_screen.dart';
import 'package:coroute_app/presentation/auth/complete_profile_screen.dart';
import 'package:coroute_app/presentation/auth/access_gate_screen.dart';
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

  testWidgets('Batch 1: App Entry and Authentication Screens', (tester) async {
    // SCR-001: Splash Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const SplashScreen(),
      outputPath: '../docs/ui-audit/screenshots/01_app_entry/SCR-001_splash_initial.png',
    );

    // SCR-002: Onboarding Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const OnboardingScreen(),
      outputPath: '../docs/ui-audit/screenshots/01_app_entry/SCR-002_onboarding_slide_1.png',
    );

    // SCR-005: Permissions Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const PermissionsScreen(),
      outputPath: '../docs/ui-audit/screenshots/01_app_entry/SCR-005_permissions_screen.png',
    );

    // SCR-006: Login Default Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const LoginScreen(),
      outputPath: '../docs/ui-audit/screenshots/02_authentication/SCR-006_login_default.png',
    );

    // SCR-007: Login Validation Errors
    // Pump LoginScreen and tap "Continue" to trigger field validation
    await tester.pumpWidget(
      MaterialApp(
        home: const Scaffold(body: LoginScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final continueBtn = find.text('Continue');
    if (continueBtn.evaluate().isNotEmpty) {
      await tester.tap(continueBtn);
      await tester.pump(const Duration(milliseconds: 100));
    }
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const LoginScreen(),
      outputPath: '../docs/ui-audit/screenshots/02_authentication/SCR-007_login_validation_errors.png',
    );

    // SCR-009: Registration / Complete Profile Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const CompleteProfileScreen(),
      outputPath: '../docs/ui-audit/screenshots/02_authentication/SCR-009_register_default.png',
    );

    // SCR-011: Access Gate Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const AccessGateScreen(),
      outputPath: '../docs/ui-audit/screenshots/02_authentication/SCR-011_access_gate_screen.png',
    );

    debugPrint('BATCH_1_CAPTURED_SUCCESSFULLY');
  });
}

