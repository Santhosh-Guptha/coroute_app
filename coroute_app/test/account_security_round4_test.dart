// Round 4 account security (docs/features_355/sessions_and_security.md §9-§12): the login 423 ride lock dialog flow
// ("Send code to my e-mail", code entry, resend timer, Call 112), register -> "Check your inbox", the admin 2-step
// prompt on MFA_REQUIRED (step-up, call repeated once), the app lock rules (never during a ride / convoy / SOS / crash
// countdown, SOS / Call 112 / Medical ID without unlocking), FLAG_SECURE reference counting and the WebSocket
// first-message auth helpers.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/app_lock_service.dart';
import 'package:coroute_app/data/services/app_security_native.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/session_guard.dart';
import 'package:coroute_app/domain/auth/account_flows.dart';
import 'package:coroute_app/domain/auth/session_policy.dart';
import 'package:coroute_app/domain/security/app_lock_policy.dart';
import 'package:coroute_app/presentation/auth/check_inbox_screen.dart';
import 'package:coroute_app/presentation/auth/mfa_prompt_dialog.dart';
import 'package:coroute_app/presentation/auth/ride_lock_dialog.dart';

String jwt(Map<String, dynamic> claims) {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part(claims)}.c2ln';
}

Map<String, dynamic> user() => {'userId': 'usr_r4', 'name': 'R4 Rider', 'email': 'r4@coroute.test', 'role': 'RIDER', 'phone': '+919876543210', 'emergencyContact': '+919000000001', 'emergencyContactName': 'Family'};

const lockBody = {
  'error': "You're on a ride on Pixel 7. End the ride on that phone to sign in here.",
  'code': 'RIDE_ACTIVE_ELSEWHERE',
  'device': 'Pixel 7',
  'lockToken': 'lock-token-1',
  'codeLength': 6,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('ride lock (423 RIDE_ACTIVE_ELSEWHERE)', () {
    test('a refused sign-in becomes a challenge with the device label and the override token; nothing else is', () {
      final c = RideLockChallenge.fromResult({'success': false, 'error': lockBody['error'], 'code': 'RIDE_ACTIVE_ELSEWHERE', 'statusCode': 423, 'body': lockBody});
      expect(c, isNotNull);
      expect(c!.device, 'Pixel 7');
      expect(c.lockToken, 'lock-token-1');
      expect(c.title, "You're on a ride on Pixel 7");
      expect(c.message, lockBody['error']);
      expect(RideLockChallenge.fromResult({'success': false, 'error': 'Invalid credentials.', 'statusCode': 401}), isNull);
      expect(RideLockChallenge.fromResult({'success': false, 'code': 'RIDE_ACTIVE_ELSEWHERE'}), isNull, reason: 'no token: a plain message');
      final noLabel = RideLockChallenge.fromResult({'code': 'RIDE_ACTIVE_ELSEWHERE', 'body': {'lockToken': 't'}});
      expect(noLabel!.device, 'another phone');
    });

    test('resend timer: 60 s by default, the gateway wait wins', () {
      final t = ResendTimer();
      final t0 = DateTime(2026, 11, 12, 10);
      expect(t.canResend(t0), isTrue);
      t.sent(t0);
      expect(t.secondsLeft(t0.add(const Duration(seconds: 15))), 45);
      expect(t.label(t0.add(const Duration(seconds: 15))), 'Send again in 45 s');
      expect(t.canResend(t0.add(const Duration(seconds: 60))), isTrue);
      expect(t.label(t0.add(const Duration(seconds: 61))), 'Send code again');
      final g = ResendTimer()..sent(t0, serverWait: 120);
      expect(g.secondsLeft(t0.add(const Duration(seconds: 60))), 60);
    });

    test('e-mail codes: 6 digits, spaces and dashes allowed', () {
      expect(isValidEmailCode('123456'), isTrue);
      expect(isValidEmailCode('123 456'), isTrue);
      expect(isValidEmailCode('123-456'), isTrue);
      expect(cleanEmailCode('123 456'), '123456');
      expect(isValidEmailCode('12345'), isFalse);
      expect(isValidEmailCode('abcdef'), isFalse);
    });

    test('AuthService: 423 keeps the code and body; send code; the right code signs this phone in', () async {
      final calls = <String>[];
      final client = MockClient((req) async {
        calls.add('${req.method} ${req.url.path}');
        if (req.url.path.endsWith('/auth/login')) return http.Response(jsonEncode(lockBody), 423);
        if (req.url.path.endsWith('/auth/ride-lock/code')) {
          expect(jsonDecode(req.body)['lockToken'], 'lock-token-1');
          return http.Response(jsonEncode({'ok': true, 'resendAfterSec': 60, 'sentTo': 'r***@coroute.test'}), 202);
        }
        if (req.url.path.endsWith('/auth/ride-lock/verify')) {
          final b = jsonDecode(req.body);
          if (b['code'] != '123456') return http.Response(jsonEncode({'error': 'That code is not right. 4 tries left.', 'code': 'CODE_WRONG', 'triesLeft': 4}), 401);
          return http.Response(jsonEncode({'token': jwt({'sub': 'usr_r4', 'typ': 'at'}), 'refreshToken': 'rt-new', 'user': user(), 'handedOver': true}), 200);
        }
        return http.Response('{}', 200);
      });
      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      final auth = AuthService(api, guard: SessionGuard());
      await Future.delayed(const Duration(milliseconds: 30));
      final r = await auth.loginRiderWithPassword(identifier: 'r4@coroute.test', password: 'Password#123');
      expect(r['success'], isFalse);
      expect(r['code'], 'RIDE_ACTIVE_ELSEWHERE');
      expect(r['statusCode'], 423);
      final c = RideLockChallenge.fromResult(r)!;
      final sent = await auth.sendRideLockCode(c.lockToken);
      expect(sent['success'], isTrue);
      expect(sent['sentTo'], 'r***@coroute.test');
      final wrong = await auth.verifyRideLockCode(c.lockToken, '000000');
      expect(wrong['success'], isFalse);
      expect((wrong['body'] as Map)['triesLeft'], 4);
      final ok = await auth.verifyRideLockCode(c.lockToken, '123 456');
      expect(ok['success'], isTrue);
      expect(auth.isAuthenticated, isTrue);
      expect(calls.any((c) => c.startsWith('POST') && c.endsWith('/auth/ride-lock/verify')), isTrue);
    });

    testWidgets('dialog: message, Call 112 always visible, send code -> code entry with a resend countdown -> signed in', (tester) async {
      final c = RideLockChallenge.fromResult({'code': 'RIDE_ACTIVE_ELSEWHERE', 'error': lockBody['error'], 'body': lockBody})!;
      var sent = 0;
      String? entered;
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (ctx) => Scaffold(body: Center(child: TextButton(onPressed: () async {
          result = await RideLockDialog.show(ctx, challenge: c, sendCode: () async {
            sent++;
            return (error: null, resendAfterSec: 60, sentTo: 'r***@coroute.test');
          }, verifyCode: (code) async {
            entered = code;
            return code == '123456' ? null : 'That code is not right.';
          });
        }, child: const Text('open'))))),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text("You're on a ride on Pixel 7"), findsOneWidget);
      expect(find.byKey(const Key('ride_lock_call_112')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ride_lock_send')));
      await tester.pump();
      expect(sent, 1);
      expect(find.byKey(const Key('ride_lock_code')), findsOneWidget);
      expect(find.textContaining('Send again in'), findsOneWidget);
      expect(find.byKey(const Key('ride_lock_call_112')), findsOneWidget, reason: 'Call 112 stays visible');
      await tester.enterText(find.byKey(const Key('ride_lock_code')), '123456');
      await tester.tap(find.byKey(const Key('ride_lock_verify')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(entered, '123456');
      expect(result, isTrue);
    });
  });

  group('register -> check inbox', () {
    test('202 pending (round 4 gateway) and 400 EMAIL_VERIFICATION_SENT (old-build answer) both mean "Check your inbox"; a token signs in', () {
      expect(signUpOutcomeOf({'success': false, 'pending': true}), SignUpOutcome.checkInbox);
      expect(signUpOutcomeOf({'success': false, 'code': 'EMAIL_VERIFICATION_SENT'}), SignUpOutcome.checkInbox);
      expect(signUpOutcomeOf({'success': true}), SignUpOutcome.signedIn);
      expect(signUpOutcomeOf({'success': false, 'code': 'CALLSIGN_TAKEN'}), SignUpOutcome.failed);
      expect(needsEmailVerification({'code': 'EMAIL_NOT_VERIFIED'}), isTrue);
    });

    test('AuthService.registerRider: a 202 answer is pending (no token stored); resend posts the address', () async {
      final bodies = <String, dynamic>{};
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/register')) {
          expect(req.headers['X-CoRoute-Session'], '2');
          return http.Response(jsonEncode({'ok': true, 'pending': true, 'message': 'Check your e-mail to finish creating your account', 'resendAfterSec': 60}), 202);
        }
        if (req.url.path.endsWith('/auth/register/resend')) {
          bodies['resend'] = jsonDecode(req.body);
          return http.Response(jsonEncode({'ok': true, 'resendAfterSec': 60}), 202);
        }
        return http.Response('{}', 200);
      });
      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      final auth = AuthService(api, guard: SessionGuard());
      await Future.delayed(const Duration(milliseconds: 30));
      final r = await auth.registerRider(name: 'R4', email: 'r4@coroute.test ', password: 'Password#123', phone: '+919876543210');
      expect(r['pending'], isTrue);
      expect(r['email'], 'r4@coroute.test');
      expect(signUpOutcomeOf(r), SignUpOutcome.checkInbox);
      expect(api.hasToken, isFalse);
      expect(auth.isAuthenticated, isFalse);
      final again = await auth.resendVerification('r4@coroute.test');
      expect(again['success'], isTrue);
      expect(bodies['resend'], {'email': 'r4@coroute.test'});
    });

    testWidgets('Check your inbox: the address, a resend countdown, back to sign in', (tester) async {
      var resends = 0;
      await tester.pumpWidget(MaterialApp(home: CheckInboxScreen(email: 'r4@coroute.test', resendAfterSec: 1, resend: () async {
        resends++;
        return null;
      })));
      expect(find.text(CheckInboxScreen.title), findsOneWidget);
      expect(find.textContaining('r4@coroute.test'), findsOneWidget);
      expect(find.textContaining('Send again in'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(find.byKey(const Key('check_inbox_resend')));
      await tester.pump();
      expect(resends, 1);
      expect(find.byKey(const Key('check_inbox_signin')), findsOneWidget);
    });
  });

  group('admin 2-step prompt (403 MFA_REQUIRED)', () {
    test('the challenge: methods, setup needed, code kinds', () {
      final c = MfaChallenge.fromBody({'error': 'Enter your 2-step verification code to use admin tools.', 'code': 'MFA_REQUIRED', 'mfaEnrolled': true, 'methods': ['totp', 'recovery']});
      expect(c.enrolled, isTrue);
      expect(c.canUseTotp && c.canUseRecovery, isTrue);
      expect(c.canUseEmail, isFalse, reason: 'administrators never get e-mail codes');
      expect(MfaChallenge.fromBody({'methods': []}).needsSetup, isTrue);
      expect(mfaCodeKindOf('123456'), MfaCodeKind.totp);
      expect(mfaCodeKindOf('123 456', emailSent: true), MfaCodeKind.email);
      expect(mfaCodeKindOf('ABCDE-FGH23'), MfaCodeKind.recovery);
      expect(mfaCodeKindOf('12'), MfaCodeKind.invalid);
    });

    test('ApiClient asks for the code on MFA_REQUIRED, then repeats the admin call once', () async {
      var adminCalls = 0;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/admin/users')) {
          adminCalls++;
          return adminCalls == 1
              ? http.Response(jsonEncode({'error': 'Enter your 2-step verification code to use admin tools.', 'code': 'MFA_REQUIRED', 'mfaEnrolled': true, 'methods': ['totp', 'recovery']}), 403)
              : http.Response('{"users":[]}', 200);
        }
        return http.Response('{}', 200);
      });
      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      Map<String, dynamic>? asked;
      api.onMfaRequired = (body) async {
        asked = body;
        return true;
      };
      final res = await api.get('/admin/users');
      expect(asked?['code'], 'MFA_REQUIRED');
      expect(res, {'users': []});
      expect(adminCalls, 2);
      // Declined prompt: the 403 surfaces with its body, never a sign-out.
      adminCalls = 0;
      api.onMfaRequired = (_) async => false;
      try {
        await api.get('/admin/users');
        fail('expected 403');
      } on ApiException catch (e) {
        expect(e.statusCode, 403);
        expect(e.code, 'MFA_REQUIRED');
        expect(e.endsSession, isFalse);
        expect(e.body?['mfaEnrolled'], isTrue);
      }
    });

    testWidgets('the prompt sends a TOTP or a recovery code and closes on success', (tester) async {
      final sent = <String>[];
      bool? ok;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (ctx) => Scaffold(body: TextButton(onPressed: () async {
        ok = await MfaPromptDialog.show(ctx, challenge: MfaChallenge.fromBody({'mfaEnrolled': true, 'methods': ['totp', 'recovery']}),
            submit: ({code, recoveryCode, emailCode}) async {
          sent.add(code ?? recoveryCode ?? emailCode ?? '');
          return code == '654321' ? null : 'That code is not right.';
        });
      }, child: const Text('admin'))))));
      await tester.tap(find.text('admin'));
      await tester.pumpAndSettle();
      expect(find.text(MfaPromptDialog.title), findsOneWidget);
      await tester.enterText(find.byKey(const Key('mfa_code_field')), '111111');
      await tester.tap(find.byKey(const Key('mfa_submit')));
      await tester.pumpAndSettle();
      expect(find.text('That code is not right.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('mfa_code_field')), '654321');
      await tester.tap(find.byKey(const Key('mfa_submit')));
      await tester.pumpAndSettle();
      expect(sent, ['111111', '654321']);
      expect(ok, isTrue);
    });
  });

  group('app lock rules', () {
    const idle = RideSafetyState();
    test('never during a ride, a convoy, an SOS / crash countdown or pending emergency texts', () {
      for (final s in const [
        RideSafetyState(rideActive: true),
        RideSafetyState(inConvoy: true),
        RideSafetyState(sosOrCountdown: true),
        RideSafetyState(pendingEmergencyTexts: true),
      ]) {
        expect(AppLockPolicy.exempt(s), isTrue);
        expect(AppLockPolicy.lockOnColdStart(enabled: true, lockAvailable: true, signedIn: true, state: s), isFalse);
        expect(AppLockPolicy.stayLocked(locked: true, state: s), isFalse, reason: 'an existing lock drops at once');
      }
    });

    test('off by default, needs a screen lock and a signed-in rider; cold start and 5 min in the background', () {
      expect(AppLockPolicy.lockOnColdStart(enabled: false, lockAvailable: true, signedIn: true, state: idle), isFalse);
      expect(AppLockPolicy.lockOnColdStart(enabled: true, lockAvailable: false, signedIn: true, state: idle), isFalse);
      expect(AppLockPolicy.lockOnColdStart(enabled: true, lockAvailable: true, signedIn: false, state: idle), isFalse);
      expect(AppLockPolicy.lockOnColdStart(enabled: true, lockAvailable: true, signedIn: true, state: idle), isTrue);
      final t0 = DateTime(2026, 11, 12, 9);
      bool resume(Duration away, {Duration delay = AppLockPolicy.defaultDelay, RideSafetyState s = idle}) => AppLockPolicy.lockOnResume(
          enabled: true, lockAvailable: true, signedIn: true, state: s, backgroundedAt: t0, now: t0.add(away), delay: delay);
      expect(resume(const Duration(minutes: 4)), isFalse);
      expect(resume(const Duration(minutes: 5)), isTrue);
      expect(resume(const Duration(minutes: 5), s: const RideSafetyState(rideActive: true)), isFalse);
      expect(resume(const Duration(seconds: 1), delay: Duration.zero), isTrue, reason: '"every time" setting');
      expect(AppLockPolicy.delayOf(null), AppLockPolicy.defaultDelay);
      expect(AppLockPolicy.delayOf(90), const Duration(minutes: 30));
    });

    test('SOS, Call 112 and the Medical ID never need an unlock', () {
      expect(AppLockPolicy.allowedWhileLocked(LockedAction.sos), isTrue);
      expect(AppLockPolicy.allowedWhileLocked(LockedAction.call112), isTrue);
      expect(AppLockPolicy.allowedWhileLocked(LockedAction.medicalId), isTrue);
    });

    testWidgets('service: locks on a cold start, a ride that starts unlocks, SOS steps the lock aside', (tester) async {
      SharedPreferences.setMockInitialValues({AppLockService.keyEnabled: true});
      var state = idle;
      var unlocks = 0;
      final s = AppLockService(state: () => state, signedIn: () => true, lockAvailable: () async => true, unlock: () async {
        unlocks++;
        return UnlockResult.ok;
      });
      await s.start();
      expect(s.locked, isTrue);
      state = const RideSafetyState(sosOrCountdown: true);
      expect(s.locked, isFalse, reason: 'an SOS never waits for an unlock');
      state = idle;
      expect(s.locked, isTrue);
      s.bypassForSafety();
      expect(s.locked, isFalse, reason: 'SOS sheet opened from the lock screen');
      s.relock();
      expect(s.locked, isTrue);
      expect(await s.unlock(), isTrue);
      expect(unlocks, 1);
      expect(s.locked, isFalse);
      s.dispose();
    });

    testWidgets('turning it on needs a screen lock and one successful unlock', (tester) async {
      final s = AppLockService(state: () => idle, lockAvailable: () async => false, unlock: () async => UnlockResult.ok);
      expect(await s.setEnabled(true), contains('screen lock'));
      expect(s.enabled, isFalse);
      final t = AppLockService(state: () => idle, lockAvailable: () async => true, unlock: () async => UnlockResult.ok);
      expect(await t.setEnabled(true), isNull);
      expect(t.enabled, isTrue);
    });
  });

  group('certificate pins (release builds)', () {
    test('only the two gateway hosts, two CAs with backups, fails open within about a year', () {
      final xml = File('android/app/src/main/res/xml/network_security_config.xml').readAsStringSync();
      final domains = RegExp(r'<domain[^>]*>([^<]+)</domain>').allMatches(xml).map((m) => m.group(1)!.trim()).toSet();
      expect(domains, {'coroute.devmonks.space', 'coroute.duckdns.org'});
      final pins = RegExp(r'<pin digest="SHA-256">([A-Za-z0-9+/=]{44})</pin>').allMatches(xml).map((m) => m.group(1)).toSet();
      expect(pins, containsAll(<String>[
        'C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M=', // ISRG Root X1
        'diGVwiVYbubAI3RW4hB9xU8e/CH2GnkuvVFZE8zmgzI=', // ISRG Root X2
        'x4QzPSC810K5/cMjb05Qm4k3Bw5zBn4lTdO/nEW/Td4=', // USERTrust RSA
        'ICGRfpgmOUXIWcQ/HXPLQTkFPEFPoDyjvH7ohhQpjzs=', // USERTrust ECC
      ]));
      expect(pins.length, greaterThanOrEqualTo(6));
      final exp = DateTime.parse(RegExp(r'expiration="(\d{4}-\d{2}-\d{2})"').firstMatch(xml)!.group(1)!);
      expect(exp.difference(DateTime(2026, 11, 12)).inDays, lessThanOrEqualTo(400), reason: 'fails open within about 12 months of this release');
      expect(xml.contains('cleartextTrafficPermitted="true"'), isFalse);
      expect(RegExp(r'overridePins="true"').allMatches(xml).length, 1);
      expect(xml.indexOf('overridePins'), greaterThan(xml.indexOf('<debug-overrides>')), reason: 'pins are bypassed only by debuggable builds');
    });
  });

  group('FLAG_SECURE and socket auth', () {
    test('FLAG_SECURE is reference counted (a dialog over the sign-in screen keeps it)', () {
      final before = SecureWindow.holders;
      SecureWindow.acquire();
      SecureWindow.acquire();
      SecureWindow.release();
      expect(SecureWindow.holders, before + 1);
      SecureWindow.release();
      expect(SecureWindow.holders, before);
      SecureWindow.release();
      expect(SecureWindow.holders, 0, reason: 'never negative');
    });

    test('WebSocket: no token in the URL (first message AUTH); an old gateway refusing it gets ?token= once', () {
      expect(RealtimeService.wsAuthInUrl('wss://h/ws', null), 'wss://h/ws');
      expect(RealtimeService.wsAuthInUrl('wss://h/ws', 'a.b.c'), 'wss://h/ws?token=a.b.c');
      expect(RealtimeService.wsAuthMessage('a.b.c'), {'type': 'AUTH', 'token': 'a.b.c'});
      expect(RealtimeService.shouldRetryAuthInUrl(4401, 'Unauthorized'), isTrue);
      expect(RealtimeService.shouldRetryAuthInUrl(4401, 'SESSION_INVALID'), isFalse);
      expect(RealtimeService.shouldRetryAuthInUrl(4401, 'AUTH_TIMEOUT'), isFalse);
      expect(RealtimeService.shouldRetryAuthInUrl(1006, null), isFalse);
    });
  });
}
