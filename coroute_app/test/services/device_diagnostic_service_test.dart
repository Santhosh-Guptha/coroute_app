import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/data/models/device_diagnostic_report.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/device_diagnostic_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter.baseflow.com/permissions/methods'), (call) async {
      if (call.method == 'checkPermissionStatus') {
        return 1; // PermissionStatus.granted
      }
      return null;
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('coroute/safety'), (call) async {
      if (call.method == 'deviceInfo') {
        return {
          'manufacturer': 'Google',
          'model': 'Pixel 8 Pro',
          'sdkInt': 34,
          'release': '14',
          'cpuAbi': 'arm64-v8a',
          'hasAccel': true,
          'accelFifo': 0,
          'hasGyro': true,
          'gyroFifo': 0,
        };
      }
      if (call.method == 'canUseFullScreenIntent') return true;
      if (call.method == 'cacheDir') return '/data/user/0/space.devmonks.coroute_app/cache';
      if (call.method == 'networkKind') return 'wifi';
      return null;
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_foreground_task/methods'), (call) async {
      if (call.method == 'isIgnoringBatteryOptimizations') return true;
      return true;
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter.baseflow.com/geolocator'), (call) async {
      if (call.method == 'isLocationServiceEnabled') return true;
      return true;
    });
  });

  group('FEAT-DIAG-01: Pre-Ride Phone Check Timing & Diagnostics', () {
    test('checkShouldRunDiagnostic recommends diagnostic before first ride', () async {
      SharedPreferences.setMockInitialValues({});
      final service = DeviceDiagnosticService();

      final check = await service.checkShouldRunDiagnostic();
      expect(check.shouldRun, isTrue);
      expect(check.reason, equals(DiagnosticTriggerReason.firstRide));
    });

    test('runFullDiagnostic produces valid report with all 11 categories and zero prohibited keys', () async {
      SharedPreferences.setMockInitialValues({});
      final service = DeviceDiagnosticService();

      final report = await service.runFullDiagnostic(
        riderId: 'rider-test-123',
        riderEmail: 'test@coroute.com',
      );

      expect(report.diagnosticId, isNotEmpty);
      expect(report.riderId, equals('rider-test-123'));
      expect(report.riderEmail, equals('test@coroute.com'));
      expect(report.deviceInfo.manufacturer, isNotEmpty);
      expect(report.deviceInfo.model, isNotEmpty);

      // Verify all 11 categories are present
      final expectedCategories = [
        'device',
        'gps',
        'accelerometer',
        'gyroscope',
        'crash_detection',
        'sos',
        'bluetooth',
        'microphone',
        'notifications',
        'background_execution',
        'offline_storage',
      ];

      for (final cat in expectedCategories) {
        expect(report.categories.containsKey(cat), isTrue, reason: 'Category $cat must be present');
        expect(report.categories[cat]!.checks, isNotEmpty);
      }

      // Verify overall result is one of the valid deterministic statuses (no fake percentages)
      expect(DiagnosticOverallResult.isValid(report.overallResult), isTrue);

      // Verify strict privacy safety
      final jsonMap = report.toJson();
      expect(DeviceDiagnosticReport.validatePrivacySafety(jsonMap), isTrue);
    });

    test('does NOT force lengthy diagnostic before every ride once first ride is done and setup unchanged', () async {
      SharedPreferences.setMockInitialValues({});
      final service = DeviceDiagnosticService();

      // Run and mark completed
      final report = await service.runFullDiagnostic();
      expect(report.lifecycleStatus, equals(DiagnosticLifecycleStatus.completed));

      // Immediate subsequent check should return false
      final subsequentCheck = await service.checkShouldRunDiagnostic();
      expect(subsequentCheck.shouldRun, isFalse);
      expect(subsequentCheck.reason, equals(DiagnosticTriggerReason.none));
    });

    test('re-triggers diagnostic when device characteristics or permissions change', () async {
      SharedPreferences.setMockInitialValues({
        'coroute_diag_first_ride_done': true,
        'coroute_diag_device_fingerprint': 'old_device_spec',
        'coroute_diag_permissions_fingerprint': 'old_permissions_spec',
      });
      final service = DeviceDiagnosticService();

      final check = await service.checkShouldRunDiagnostic();
      expect(check.shouldRun, isTrue);
      expect(
        check.reason == DiagnosticTriggerReason.deviceChanged ||
            check.reason == DiagnosticTriggerReason.permissionsChanged,
        isTrue,
      );
    });
  });

  group('FEAT-DIAG-02: Diagnostic Report Submission & Privacy Safety', () {
    test('submitReport requires explicit rider consent', () async {
      final service = DeviceDiagnosticService();
      final report = await service.runFullDiagnostic();

      expect(
        () => service.submitReport(report, consentGiven: false),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('submitReport successfully sends report to /diagnostics/submit and marks submitted', () async {
      var submittedPath = '';
      Map<String, dynamic>? submittedBody;

      final mockClient = MockClient((request) async {
        submittedPath = request.url.path;
        submittedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'ok': true, 'diagnosticId': submittedBody?['diagnosticId'], 'status': 'Submitted'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final apiClient = ApiClient(httpClient: mockClient, storage: const FlutterSecureStorage());
      final service = DeviceDiagnosticService(apiClient: apiClient);

      final report = await service.runFullDiagnostic();
      final result = await service.submitReport(report, consentGiven: true);

      expect(result['ok'], isTrue);
      expect(result['status'], equals('Submitted'));
      expect(submittedPath, endsWith('/diagnostics/submit'));
      expect(submittedBody?['consentGiven'], isTrue);
      expect(submittedBody?['diagnosticId'], equals(report.diagnosticId));
    });

    test('DeviceDiagnosticReport.validatePrivacySafety catches prohibited keys', () {
      final safeMap = {
        'diagnosticId': 'id-1',
        'deviceInfo': {'model': 'Pixel 8', 'manufacturer': 'Google'},
        'categories': {},
      };
      expect(DeviceDiagnosticReport.validatePrivacySafety(safeMap), isTrue);

      final imeiMap = {
        ...safeMap,
        'deviceInfo': {'model': 'Pixel 8', 'imei': '123456789012345'},
      };
      expect(DeviceDiagnosticReport.validatePrivacySafety(imeiMap), isFalse);

      final audioMap = {
        ...safeMap,
        'metadata': {'recordedAudio': 'base64bytes'},
      };
      expect(DeviceDiagnosticReport.validatePrivacySafety(audioMap), isFalse);

      final contactsMap = {
        ...safeMap,
        'contacts': [{'name': 'Emergency Contact'}],
      };
      expect(DeviceDiagnosticReport.validatePrivacySafety(contactsMap), isFalse);

      final gpsHistoryMap = {
        ...safeMap,
        'continuousGps': [{'lat': 12.34, 'lng': 56.78}],
      };
      expect(DeviceDiagnosticReport.validatePrivacySafety(gpsHistoryMap), isFalse);
    });

    test('DeviceDiagnosticReport round-trip serialization maintains data integrity', () async {
      final service = DeviceDiagnosticService();
      final original = await service.runFullDiagnostic(riderId: 'rider-001', riderEmail: 'rider@coroute.com');

      final jsonMap = original.toJson();
      final restored = DeviceDiagnosticReport.fromJson(jsonMap);

      expect(restored.diagnosticId, equals(original.diagnosticId));
      expect(restored.riderId, equals(original.riderId));
      expect(restored.overallResult, equals(original.overallResult));
      expect(restored.categories.length, equals(original.categories.length));
    });
  });
}
