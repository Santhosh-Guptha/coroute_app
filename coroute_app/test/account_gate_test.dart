import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/constants/app_constants.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Session-ending codes', () {
    test('hold and block end the session like a revoked token', () {
      expect(const ApiException(403, 'blocked', 'ACCOUNT_BLOCKED').endsSession, isTrue);
      expect(const ApiException(403, 'hold', 'ACCOUNT_ON_HOLD').endsSession, isTrue);
      expect(const ApiException(401, 'x', 'SESSION_INVALID').endsSession, isTrue);
      expect(const ApiException(404, 'x', 'ACCOUNT_GONE').endsSession, isTrue);
    });

    test('other errors never sign anyone out', () {
      expect(const ApiException(403, 'x', 'NOT_MEMBER').endsSession, isFalse);
      expect(const ApiException(401, 'Invalid credentials.').endsSession, isFalse);
      expect(const ApiException(0, 'offline').endsSession, isFalse);
    });
  });

  group('Admin role', () {
    test('only the server role makes an admin', () {
      expect(AuthService.roleIsAdmin(AppConstants.adminRole), isTrue);
      expect(AuthService.roleIsAdmin(AppConstants.riderRole), isFalse);
      expect(AuthService.roleIsAdmin(null), isFalse);
    });
  });

  group('Socket close codes', () {
    test('4403 stops reconnecting, 4401 asks the app to re-check, others just reconnect', () {
      final refused = RealtimeService.closeOutcome(4403);
      expect(refused.authRejected, isTrue);
      expect(refused.reconnect, isFalse);
      final signedOut = RealtimeService.closeOutcome(4401);
      expect(signedOut.authRejected, isTrue);
      expect(signedOut.reconnect, isTrue);
      final normal = RealtimeService.closeOutcome(1006);
      expect(normal.authRejected, isFalse);
      expect(normal.reconnect, isTrue);
      expect(RealtimeService.closeOutcome(null).reconnect, isTrue);
    });
  });

  group('AuthService with the account gate', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
    });

    Map<String, dynamic> user(String role) => {
          'userId': 'usr_gate',
          'name': 'Gate Rider',
          'email': 'gate@coroute.test',
          'role': role,
        };

    test('a password change keeps this phone signed in with the new token', () async {
      final client = MockClient((req) async {
        final path = req.url.path;
        if (path.endsWith('/auth/login')) {
          return http.Response(jsonEncode({'token': 'old-token', 'user': user('RIDER')}), 200);
        }
        if (path.endsWith('/me/password')) {
          return http.Response(jsonEncode({'ok': true, 'token': 'new-token'}), 200);
        }
        return http.Response(jsonEncode({'error': 'Not found'}), 404);
      });
      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      final auth = AuthService(api);
      await Future.delayed(const Duration(milliseconds: 50));
      await auth.loginRiderWithPassword(identifier: 'gate@coroute.test', password: 'Password#123');
      expect(api.token, 'old-token');

      final res = await auth.changePassword(currentPassword: 'Password#123', newPassword: 'Changed#Pass42');
      expect(res['success'], isTrue);
      expect(api.token, 'new-token');
      expect(auth.isAuthenticated, isTrue);
    });

    test('a blocked account is signed out and the reason is kept for the sign-in screen', () async {
      var blocked = false;
      final client = MockClient((req) async {
        final path = req.url.path;
        if (path.endsWith('/auth/login')) {
          return http.Response(jsonEncode({'token': 'jwt', 'user': user('RIDER')}), 200);
        }
        if (path.endsWith('/me') && blocked) {
          return http.Response(jsonEncode({'error': 'Your account has been blocked by the administrator.', 'code': 'ACCOUNT_BLOCKED'}), 403);
        }
        if (path.endsWith('/me')) return http.Response(jsonEncode(user('RIDER')), 200);
        return http.Response(jsonEncode({'error': 'Not found'}), 404);
      });
      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      final auth = AuthService(api);
      await Future.delayed(const Duration(milliseconds: 50));
      await auth.loginRiderWithPassword(identifier: 'gate@coroute.test', password: 'Password#123');
      expect(auth.isAuthenticated, isTrue);

      blocked = true;
      await auth.revalidate();
      await Future.delayed(const Duration(milliseconds: 50));
      expect(auth.isAuthenticated, isFalse);
      expect(api.hasToken, isFalse);
      expect(auth.lastSignOutReason, 'Your account has been blocked by the administrator.');
      auth.clearSignOutReason();
      expect(auth.lastSignOutReason, isNull);
    });
  });
}
