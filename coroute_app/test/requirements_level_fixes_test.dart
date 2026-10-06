import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/constants/app_constants.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/presentation/account/edit_profile_screen.dart';
import 'package:coroute_app/presentation/widgets/emergency_sos_sheet.dart';
import 'package:coroute_app/presentation/widgets/rider_status_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Master Admin Elevation Invariant (Rule 3)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('Auto-elevates santhoshbukka5@gmail.com to MASTER_ADMIN even if server sends RIDER role', () async {
      final client = MockClient((request) async {
        if (request.url.path.contains('/auth/login')) {
          return http.Response(
            jsonEncode({
              'token': 'jwt-master-admin-token',
              'user': {
                'userId': 'usr_admin_1',
                'email': 'santhoshbukka5@gmail.com',
                'name': 'Santhosh Bukka',
                'role': 'RIDER', // Server returns RIDER, but invariant must elevate to MASTER_ADMIN
                'phone': '+91 99999 88888',
                'vehicleType': 'Motorcycle (Adv)',
              },
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'error': 'Not found'}), 404);
      });

      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      final auth = AuthService(api);

      final result = await auth.loginRiderWithPassword(
        identifier: 'santhoshbukka5@gmail.com',
        password: 'password123',
      );

      expect(result['success'], true);
      expect(result['isAdmin'], true);
      expect(auth.isMasterAdmin, true);
      expect(auth.currentUserRole, AppConstants.adminRole);
    });

    test('Regular rider does not get elevated to MASTER_ADMIN', () async {
      final client = MockClient((request) async {
        if (request.url.path.contains('/auth/login')) {
          return http.Response(
            jsonEncode({
              'token': 'jwt-regular-token',
              'user': {
                'userId': 'usr_regular_2',
                'email': 'regular_rider@example.com',
                'name': 'Regular Rider',
                'role': 'RIDER',
              },
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'error': 'Not found'}), 404);
      });

      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      final auth = AuthService(api);

      final result = await auth.loginRiderWithPassword(
        identifier: 'regular_rider@example.com',
        password: 'password123',
      );

      expect(result['success'], true);
      expect(result['isAdmin'], false);
      expect(auth.isMasterAdmin, false);
      expect(auth.currentUserRole, AppConstants.riderRole);
    });
  });

  group('Rider Status Sheet Specification Tests (Section 5.5)', () {
    test('Resolves all 10 stop category emojis and labels accurately', () {
      final testCases = {
        'FUELING': {'emoji': '⛽', 'label': 'Fueling'},
        'REST_BREAK': {'emoji': '☕', 'label': 'Rest Break'},
        'MECHANICAL': {'emoji': '🔧', 'label': 'Mechanical Issue'},
        'FLAT_TIRE': {'emoji': '🛞', 'label': 'Flat Tire'},
        'TRAFFIC': {'emoji': '🚦', 'label': 'Traffic Delay'},
        'RAIN_DELAY': {'emoji': '🌧️', 'label': 'Weather Delay'},
        'PHOTO_STOP': {'emoji': '📸', 'label': 'Photo Stop'},
        'MEDICAL': {'emoji': '🏥', 'label': 'Medical Emergency'},
        'REGROUP': {'emoji': '🛑', 'label': 'Regroup Wait'},
        'CUSTOM': {'emoji': '💬', 'label': 'Custom Reason'},
      };

      for (final entry in testCases.entries) {
        expect(RiderStatusSheet.getStatusEmoji(entry.key), entry.value['emoji']);
        expect(RiderStatusSheet.getStatusLabel(entry.key), entry.value['label']);
      }
    });
  });

  group('Emergency SOS Sheet Widget Tests (Section 5.4)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyUserId: 'user_test',
        AppConstants.keyUserEmail: 'test@example.com',
        AppConstants.keyUserName: 'Test Rider',
        AppConstants.keyPhone: '+91 99999 11111',
        AppConstants.keyEmergencyContact: '+91 88888 22222',
        AppConstants.keyEmergencyName: 'Brother',
      });
    });

    testWidgets('Renders SOS distress beacon banner, coordinates, ICE actions and 112 button', (tester) async {
      final client = MockClient((request) async {
        if (request.url.path.contains('/auth/login')) {
          return http.Response(
            jsonEncode({
              'token': 'mock-sos-token',
              'user': {
                'userId': 'usr_test_1',
                'email': 'test@example.com',
                'name': 'Test Rider',
                'role': 'RIDER',
                'phone': '+91 99999 11111',
                'emergencyContact': '+91 88888 22222',
                'emergencyContactName': 'Brother',
              },
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      });
      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      final auth = AuthService(api);
      await tester.runAsync(() async {
        await auth.loginRiderWithPassword(identifier: 'test@example.com', password: 'password');
      });

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: auth,
          child: const MaterialApp(
            home: Scaffold(
              body: EmergencySosSheet(
                lat: 12.971598,
                lng: 77.594562,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));

      // Verify Distress Beacon header
      expect(find.textContaining('SOS DISTRESS BEACON ACTIVE'), findsOneWidget);

      // Verify Coordinate display
      expect(find.textContaining('12.97160, 77.59456'), findsOneWidget);

      // Verify ICE Contact Actions
      expect(find.textContaining('Call Brother'), findsOneWidget);
      expect(find.textContaining('Send SMS with Location'), findsOneWidget);

      // Verify 112 National Emergency button
      expect(find.textContaining('Dial 112 National Emergency Services'), findsOneWidget);
    });
  });

  group('Edit Profile Screen Widget Tests', () {
    testWidgets('Pre-populates existing user profile and ICE contacts', (tester) async {
      final client = MockClient((request) async {
        if (request.url.path.contains('/auth/login')) {
          return http.Response(
            jsonEncode({
              'token': 'mock-profile-token',
              'user': {
                'userId': 'usr_profile_1',
                'email': 'santhosh@example.com',
                'name': 'Santhosh Rider',
                'role': 'RIDER',
                'phone': '+91 98765 43210',
                'vehicleType': 'Motorcycle (Adv)',
                'vehicleNo': 'KA 01 AB 1234',
                'emergencyContact': '+91 99887 76655',
                'emergencyContactName': 'Spouse',
              },
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      });
      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      final auth = AuthService(api);
      await tester.runAsync(() async {
        await auth.loginRiderWithPassword(identifier: 'santhosh@example.com', password: 'password');
      });

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: auth,
          child: const MaterialApp(
            home: EditProfileScreen(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));

      expect(find.text('Rider Profile & ICE'), findsOneWidget);

      final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fields.any((f) => f.controller?.text == '+91 98765 43210'), true);
      expect(fields.any((f) => f.controller?.text == 'KA 01 AB 1234'), true);
      expect(fields.any((f) => f.controller?.text == 'Spouse'), true);
      expect(fields.any((f) => f.controller?.text == '+91 99887 76655'), true);

      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pump();
      expect(find.text('SAVE PROFILE & CONTACTS'), findsOneWidget);
    });
  });
}
