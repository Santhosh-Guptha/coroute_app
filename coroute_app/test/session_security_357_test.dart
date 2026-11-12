// 3.57 sessions & security (docs/features_355/sessions_and_security.md): the app's session manager
// (refresh once on TOKEN_EXPIRED, single flight, end only on gateway codes), sign-out (server revoke, tokens and
// cached data wiped, emergency info kept by default, welcome screen with the stack cleared) and the rule that a
// sign-out never happens during a ride, an SOS, a crash countdown, a convoy or pending emergency texts.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/session_guard.dart';
import 'package:coroute_app/domain/auth/session_policy.dart';
import 'package:coroute_app/presentation/account/sign_out_flow.dart';

String jwt(Map<String, dynamic> claims) {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part(claims)}.c2ln';
}

Map<String, dynamic> user() => {'userId': 'usr_sess', 'name': 'Sess Rider', 'email': 'sess@coroute.test', 'role': 'RIDER', 'phone': '+919876543210', 'emergencyContact': '+919000000001', 'emergencyContactName': 'Family'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SessionPolicy', () {
    test('TOKEN_EXPIRED refreshes once; only gateway session codes end the session', () {
      expect(SessionPolicy.actionFor(401, 'TOKEN_EXPIRED', canRefresh: true), SessionAction.refresh);
      expect(SessionPolicy.actionFor(401, 'TOKEN_EXPIRED', canRefresh: false), SessionAction.none, reason: 'already retried: no loop');
      expect(SessionPolicy.actionFor(401, 'SESSION_INVALID', canRefresh: true), SessionAction.end);
      expect(SessionPolicy.actionFor(403, 'ACCOUNT_BLOCKED', canRefresh: true), SessionAction.end);
      expect(SessionPolicy.actionFor(401, null, canRefresh: true), SessionAction.none, reason: 'not the gateway (captive portal)');
      expect(SessionPolicy.actionFor(403, 'REAUTH_REQUIRED', canRefresh: true), SessionAction.none);
      expect(SessionPolicy.actionFor(401, 'REAUTH_FAILED', canRefresh: true), SessionAction.none);
      expect(SessionPolicy.actionFor(0, null, canRefresh: true), SessionAction.none, reason: 'offline never signs out');
    });

    test('seconds left on a JWT', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      expect(SessionPolicy.secondsLeft(jwt({'exp': 1700000000 + 90}), now: now), 90);
      expect(SessionPolicy.secondsLeft('not-a-jwt'), isNull);
      expect(SessionPolicy.secondsLeft(null), isNull);
      expect(SessionPolicy.secondsLeft(jwt({'sub': 'x'})), isNull);
    });
  });

  group('Never signed out mid-ride', () {
    test('busy while a ride, convoy, SOS / crash countdown or emergency texts run', () {
      expect(SignOutPolicy.mustDefer(RideSafetyState.idle), isFalse);
      for (final s in const [
        RideSafetyState(rideActive: true),
        RideSafetyState(inConvoy: true),
        RideSafetyState(sosOrCountdown: true),
        RideSafetyState(pendingEmergencyTexts: true),
      ]) {
        expect(SignOutPolicy.mustDefer(s), isTrue);
        expect(SignOutPolicy.deferredMessage(s, SignOutCause.sessionEnded), contains('when the ride is over'));
      }
      expect(const RideSafetyState(sosOrCountdown: true, rideActive: true).reason, 'an emergency is open');
    });

    test('the guard keeps a sign-out until the ride is over, then runs it once', () async {
      var state = const RideSafetyState(inConvoy: true);
      final guard = SessionGuard(probe: () => state, recheck: const Duration(hours: 1));
      var runs = 0;
      expect(await guard.runWhenSafe(SignOutCause.sessionEnded, () async => runs++), isFalse);
      expect(guard.pending, isTrue);
      expect(guard.pendingMessage, contains('ride'));
      await guard.check();
      expect(runs, 0, reason: 'still riding');
      state = const RideSafetyState(sosOrCountdown: true);
      await guard.check();
      expect(runs, 0, reason: 'an SOS opened: still waiting');
      state = RideSafetyState.idle;
      await guard.check();
      expect(runs, 1);
      expect(guard.pending, isFalse);
      await guard.check();
      expect(runs, 1, reason: 'once');
      guard.dispose();
    });

    test('"all devices" replaces a waiting sign-out; a probe that fails counts as riding', () async {
      var state = const RideSafetyState(rideActive: true);
      final guard = SessionGuard(probe: () => state, recheck: const Duration(hours: 1));
      final ran = <String>[];
      await guard.runWhenSafe(SignOutCause.user, () async => ran.add('phone'));
      await guard.runWhenSafe(SignOutCause.userEverywhere, () async => ran.add('everywhere'));
      state = RideSafetyState.idle;
      await guard.check();
      expect(ran, ['everywhere']);
      final broken = SessionGuard(probe: () => throw StateError('x'));
      expect(broken.busy, isTrue);
      expect(SessionGuard().busy, isFalse, reason: 'no probe yet: nothing runs');
      guard.dispose();
      broken.dispose();
    });
  });

  group('ApiClient session manager', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('401 TOKEN_EXPIRED -> one refresh -> the call is repeated with the new token', () async {
      final seen = <String>[];
      var refreshes = 0;
      final client = MockClient((req) async {
        seen.add('${req.method} ${req.url.path} ${req.headers['authorization'] ?? ''}');
        if (req.url.path.endsWith('/auth/refresh')) {
          refreshes++;
          expect(jsonDecode(req.body)['refreshToken'], 'rt-1');
          return http.Response(jsonEncode({'token': 'access-2', 'refreshToken': 'rt-2'}), 200);
        }
        if (req.headers['authorization'] == 'Bearer access-1') return http.Response(jsonEncode({'error': 'x', 'code': 'TOKEN_EXPIRED'}), 401);
        return http.Response(jsonEncode({'ok': true}), 200);
      });
      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      await api.init();
      await api.setSession('access-1', refreshToken: 'rt-1');
      // Three calls at once: one refresh for all of them.
      final out = await Future.wait([api.get('/me'), api.get('/trips'), api.get('/friends')]);
      expect(out.every((r) => r['ok'] == true), isTrue);
      expect(refreshes, 1);
      expect(api.token, 'access-2');
      expect(api.hasRefreshToken, isTrue);
      expect(await const FlutterSecureStorage().read(key: 'coroute_refresh'), 'rt-2', reason: 'stored in the keystore');
      expect(seen.where((s) => s.startsWith('GET') && s.endsWith('Bearer access-2')).length, 3);
    });

    test('a refused refresh ends the session; a refresh that cannot reach the server never does', () async {
      var offline = true;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/refresh')) {
          if (offline) throw const SocketExceptionLike();
          return http.Response(jsonEncode({'error': 'You were signed out. Please sign in again.', 'code': 'SESSION_INVALID'}), 401);
        }
        return http.Response(jsonEncode({'error': 'x', 'code': 'TOKEN_EXPIRED'}), 401);
      });
      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      await api.init();
      await api.setSession('access-1', refreshToken: 'rt-1');
      await expectLater(api.get('/me'), throwsA(isA<ApiException>().having((e) => e.endsSession, 'endsSession', isFalse)));
      expect(api.hasToken, isTrue, reason: 'offline: still signed in');
      offline = false;
      await expectLater(api.get('/me'), throwsA(isA<ApiException>()));
      expect(api.hasToken, isFalse, reason: 'the gateway refused the refresh: session over');
      expect(api.hasRefreshToken, isFalse);
      expect(api.lastSessionEndMessage, contains('signed out'));
    });

    test('older sessions (no refresh token) keep the sliding token and never call refresh', () async {
      var refreshCalls = 0;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/refresh')) refreshCalls++;
        return http.Response(jsonEncode({'ok': true}), 200, headers: {'x-coroute-token': 'slid-2'});
      });
      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      await api.init();
      await api.setToken('legacy-1');
      await api.get('/me');
      expect(api.token, 'slid-2');
      expect(refreshCalls, 0);
    });

    test('every request says this build refreshes (X-CoRoute-Session: 2)', () async {
      final headers = <Map<String, String>>[];
      final api = ApiClient(httpClient: MockClient((req) async { headers.add(req.headers); return http.Response('{}', 200); }), storage: const FlutterSecureStorage());
      await api.init();
      await api.post('/auth/login', {'identifier': 'x', 'password': 'y'}, const Duration(seconds: 5), false);
      expect(headers.single['X-CoRoute-Session'] ?? headers.single['x-coroute-session'], '2');
    });
  });

  group('AuthService sign-out', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
    });

    Future<(AuthService, ApiClient, List<String>)> signedIn({SessionGuard? guard, Map<String, dynamic>? sessionEnd}) async {
      final calls = <String>[];
      final client = MockClient((req) async {
        calls.add('${req.method} ${req.url.path}');
        if (req.url.path.endsWith('/auth/login')) {
          return http.Response(jsonEncode({'token': jwt({'sub': 'usr_sess', 'typ': 'at'}), 'refreshToken': 'rt-login', 'user': user()}), 200);
        }
        if (req.url.path.endsWith('/auth/logout')) {
          expect(jsonDecode(req.body)['refreshToken'], 'rt-login');
          return http.Response('{"ok":true}', 200);
        }
        if (sessionEnd != null) return http.Response(jsonEncode(sessionEnd), 401);
        return http.Response('{}', 200);
      });
      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      final auth = AuthService(api, guard: guard);
      await Future.delayed(const Duration(milliseconds: 30));
      final r = await auth.loginRiderWithPassword(identifier: 'sess@coroute.test', password: 'Password#123');
      expect(r['success'], isTrue);
      return (auth, api, calls);
    }

    test('sign-out revokes on the server, wipes tokens and the profile, keeps emergency info by default', () async {
      final (auth, api, calls) = await signedIn(guard: SessionGuard());
      final order = <String>[];
      auth.beforeSignOut.add(() async => order.add('push removed'));
      auth.afterSignOut.add(() async => order.add('caches wiped'));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('ride_chat_archive_v1', '{"g":[]}');
      final res = await auth.signOut();
      expect(res['success'], isTrue);
      expect(calls, contains('POST /api/auth/logout'));
      expect(order, ['push removed', 'caches wiped']);
      expect(api.hasToken, isFalse);
      expect(api.hasRefreshToken, isFalse);
      expect(await const FlutterSecureStorage().read(key: 'coroute_jwt'), isNull);
      expect(await const FlutterSecureStorage().read(key: 'coroute_refresh'), isNull);
      expect(auth.isAuthenticated, isFalse);
      expect(auth.emergencyContact, isNull);
      expect(prefs.getString('ride_chat_archive_v1'), isNull, reason: 'ride chats leave the phone');
      expect(auth.keepEmergencyInfo, isTrue);
      expect(prefs.getBool(AuthService.keyKeepEmergencyInfo), isTrue);
    });

    test('"remove emergency info" is remembered', () async {
      final (auth, _, _) = await signedIn(guard: SessionGuard());
      await auth.signOut(keepEmergencyInfo: false);
      expect(auth.keepEmergencyInfo, isFalse);
    });

    test('the profile (phone, emergency contact) is kept in the keystore, not in SharedPreferences', () async {
      await signedIn(guard: SessionGuard());
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('coroute_emergency_contact'), isNull);
      expect(await const FlutterSecureStorage().read(key: 'coroute_secure_coroute_emergency_contact'), '+919000000001');
    });

    test('a sign-out tapped during a ride waits, and happens when the ride is over', () async {
      var state = const RideSafetyState(rideActive: true, inConvoy: true);
      final guard = SessionGuard(probe: () => state, recheck: const Duration(hours: 1));
      final (auth, api, calls) = await signedIn(guard: guard);
      final res = await auth.signOut();
      expect(res['deferred'], isTrue);
      expect(res['error'], contains('after the ride'));
      expect(auth.isAuthenticated, isTrue);
      expect(api.hasToken, isTrue);
      expect(calls, isNot(contains('POST /api/auth/logout')));
      state = RideSafetyState.idle;
      await guard.check();
      expect(auth.isAuthenticated, isFalse);
      expect(calls, contains('POST /api/auth/logout'));
      guard.dispose();
    });

    test('the gateway ending the session mid-ride keeps the rider\'s screen and emergency contact until the ride is over', () async {
      var state = const RideSafetyState(sosOrCountdown: true);
      final guard = SessionGuard(probe: () => state, recheck: const Duration(hours: 1));
      final (auth, api, _) = await signedIn(guard: guard, sessionEnd: {'error': 'You were signed out. Please sign in again.', 'code': 'SESSION_INVALID'});
      await expectLater(api.get('/me'), throwsA(isA<ApiException>()));
      await Future.delayed(Duration.zero);
      expect(api.hasToken, isFalse, reason: 'the token is dead on the server');
      expect(auth.sessionEndedDuringRide, isTrue);
      expect(auth.isAuthenticated, isTrue, reason: 'never signed out during an SOS');
      expect(auth.emergencyContact, '+919000000001', reason: 'SOS texts still know the contact');
      expect(guard.pending, isTrue);
      state = RideSafetyState.idle;
      await guard.check();
      expect(auth.isAuthenticated, isFalse);
      expect(auth.lastSignOutReason, contains('signed out'));
      guard.dispose();
    });
  });

  testWidgets('after sign-out the welcome screen replaces the whole stack: Back cannot return', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: const Scaffold(body: Text('home'))));
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('profile'))));
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('settings'))));
    await tester.pumpAndSettle();
    expect(nav.currentState!.canPop(), isTrue);
    SignOutFlow.goToWelcome(nav.currentState!, welcome: (_) => const Scaffold(body: Text('welcome')));
    await tester.pumpAndSettle();
    expect(find.text('welcome'), findsOneWidget);
    expect(find.text('settings'), findsNothing);
    expect(nav.currentState!.canPop(), isFalse, reason: 'Back cannot return to private screens');
    expect(await nav.currentState!.maybePop(), isFalse);
  });

  testWidgets('the sign-out dialog keeps emergency info by default and offers every device', (tester) async {
    SignOutChoice? choice;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (ctx) => TextButton(onPressed: () async => choice = await SignOutFlow.ask(ctx), child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(SignOutFlow.keepLabel), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.byKey(const Key('signout_keep_emergency'))).value, isTrue);
    await tester.tap(find.byKey(const Key('signout_everywhere')));
    await tester.pumpAndSettle();
    expect(choice!.everywhere, isTrue);
    expect(choice!.keepEmergencyInfo, isTrue);
  });
}

/// A network failure without dart:io in the test (the client only needs "something was thrown").
class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}
