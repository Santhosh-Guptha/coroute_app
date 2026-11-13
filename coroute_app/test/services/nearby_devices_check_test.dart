import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/core/permissions/nearby_access.dart';
import 'package:coroute_app/data/models/device_diagnostic_report.dart';

/// Pure logic of the pre-ride "Nearby devices" item (Android 12+ BLUETOOTH_SCAN / ADVERTISE / CONNECT).
void main() {
  group('SDK gating', () {
    test('only Android 12 (API 31) and newer', () {
      expect(NearbyPolicy.applies(android: true, sdk: 31), isTrue);
      expect(NearbyPolicy.applies(android: true, sdk: 35), isTrue);
      expect(NearbyPolicy.applies(android: true, sdk: 30), isFalse);
      expect(NearbyPolicy.applies(android: true, sdk: 0), isFalse, reason: 'unknown SDK: not shown');
      expect(NearbyPolicy.applies(android: false, sdk: 34), isFalse, reason: 'iOS / desktop');
    });

    test('older Android or iOS: not needed, whatever the permission reads', () {
      for (final (android, sdk) in [(true, 30), (true, 0), (false, 34)]) {
        final a = NearbyPolicy.combine(android: android, sdk: sdk, scan: false, advertise: false, connect: false);
        expect(a, NearbyAccess.notNeeded);
        expect(NearbyDevicesCheck.item(a), isNull, reason: 'hidden on $android/$sdk');
      }
    });
  });

  group('status mapping', () {
    test('OK only when all three are granted', () {
      expect(NearbyPolicy.combine(android: true, sdk: 33, scan: true, advertise: true, connect: true), NearbyAccess.granted);
      for (final (s, a, c) in [(false, true, true), (true, false, true), (true, true, false), (false, false, false)]) {
        expect(NearbyPolicy.combine(android: true, sdk: 33, scan: s, advertise: a, connect: c), NearbyAccess.denied);
      }
      expect(
        NearbyPolicy.combine(android: true, sdk: 33, scan: true, advertise: false, connect: true, anyPermanentlyDenied: true),
        NearbyAccess.permanentlyDenied,
      );
    });

    test('granted: a pass with no fix', () {
      final item = NearbyDevicesCheck.item(NearbyAccess.granted)!;
      expect(item.key, 'nearby_devices');
      expect(item.name, 'Nearby devices');
      expect(item.verdict, CheckVerdict.pass);
      expect(item.fix, isNull);
    });

    test('missing: a warning (never a blocker) with the plain line and the request fix', () {
      final item = NearbyDevicesCheck.item(NearbyAccess.denied)!;
      expect(item.verdict, CheckVerdict.warn);
      expect(item.isCritical, isFalse);
      expect(item.status, DiagnosticStatus.limited);
      expect(
        item.detail,
        'Nearby devices: lets your phone talk to the group with no signal and lets riders find you after a crash.',
      );
      expect(item.fix, PhoneCheckFix.nearbyDevices);
    });

    test('permanently denied: still a warning; the button opens app settings', () {
      final item = NearbyDevicesCheck.item(NearbyAccess.permanentlyDenied)!;
      expect(item.verdict, CheckVerdict.warn);
      expect(item.isCritical, isFalse);
      expect(item.fix, PhoneCheckFix.appSettings);
    });

    test('a missing Nearby devices alone never makes the phone "not ready"', () {
      final report = DeviceDiagnosticReport(
        diagnosticId: 'x',
        timestamp: 0,
        deviceInfo: const DiagnosticDeviceInfo(
          manufacturer: 'm',
          model: 'm',
          osVersion: 'Android 14',
          apiLevel: 34,
          appVersion: '1',
          buildNumber: '1',
          cpuArch: 'arm64',
          batteryOptimizationStatus: '',
        ),
        overallResult: DiagnosticOverallResult.supportedWithLimitations,
        overallSummary: '',
        categories: {
          'nearby_devices': DiagnosticCategoryResult(
            categoryKey: 'nearby_devices',
            title: 'Nearby devices',
            status: DiagnosticStatus.limited,
            summary: '',
            checks: [NearbyDevicesCheck.item(NearbyAccess.permanentlyDenied)!],
          ),
        },
      );
      expect(report.readiness, RideReadiness.readyWithWarnings);
      final back = DeviceDiagnosticReport.fromJson(report.toJson());
      expect(back.allChecks.single.fix, PhoneCheckFix.appSettings);
    });
  });

  group('shared prompt (mesh / rescue finder / phone check)', () {
    test('an automatic prompt shows at most once, and only when it can change something', () {
      expect(NearbyPolicy.mayAutoPrompt(NearbyAccess.denied, askedBefore: false), isTrue);
      expect(NearbyPolicy.mayAutoPrompt(NearbyAccess.denied, askedBefore: true), isFalse);
      expect(NearbyPolicy.mayAutoPrompt(NearbyAccess.granted, askedBefore: false), isFalse);
      expect(NearbyPolicy.mayAutoPrompt(NearbyAccess.notNeeded, askedBefore: false), isFalse);
      expect(NearbyPolicy.mayAutoPrompt(NearbyAccess.permanentlyDenied, askedBefore: false), isFalse);
    });

    test('satisfied when granted or not a runtime permission', () {
      expect(NearbyPolicy.satisfied(NearbyAccess.granted), isTrue);
      expect(NearbyPolicy.satisfied(NearbyAccess.notNeeded), isTrue);
      expect(NearbyPolicy.satisfied(NearbyAccess.denied), isFalse);
      expect(NearbyPolicy.satisfied(NearbyAccess.permanentlyDenied), isFalse);
    });
  });
}
