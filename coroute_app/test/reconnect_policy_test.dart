import 'dart:convert';
import 'dart:math' as math;

import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/domain/sync/reconnect_policy.dart';
import 'package:coroute_app/presentation/widgets/connection_banner.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Always the smallest (or the largest) value nextInt can give: the bounds of every wait.
class _EdgeRandom implements math.Random {
  _EdgeRandom(this.high);
  final bool high;
  @override
  int nextInt(int max) => high ? max - 1 : 0;
  @override
  double nextDouble() => high ? 0.999999 : 0;
  @override
  bool nextBool() => high;
}

/// A realtime service whose "socket" is only counted (no network in unit tests).
class _Harness {
  _Harness() {
    rt.debugOnOpen = () => opens++;
    rt.debugSink = (j) => sent.add(Map<String, dynamic>.from(jsonDecode(j) as Map));
  }
  final rt = RealtimeService();
  int opens = 0;
  final List<Map<String, dynamic>> sent = [];

  void hello() => rt.debugReceive(jsonEncode({'type': 'HELLO', 'features': <String>[]}));
  void snapshot(String gid) => rt.debugReceive(jsonEncode({'type': 'SNAPSHOT', 'convoy': {'groupId': gid}}));
  List<Map<String, dynamic>> joins() => sent.where((m) => m['type'] == 'JOIN').toList();
}

void main() {
  group('ReconnectPolicy (pure)', () {
    test('first retry is quick: 300-1000 ms', () {
      expect(ReconnectPolicy(random: _EdgeRandom(false)).nextAfterFailure(), const Duration(milliseconds: 300));
      expect(ReconnectPolicy(random: _EdgeRandom(true)).nextAfterFailure(), const Duration(milliseconds: 1000));
      final p = ReconnectPolicy(random: math.Random(7));
      for (var i = 0; i < 200; i++) {
        p.reset();
        final d = p.nextAfterFailure().inMilliseconds;
        expect(d, inInclusiveRange(300, 1000));
      }
    });

    test('then exponential backoff with full jitter, capped at 10 s', () {
      final hi = ReconnectPolicy(random: _EdgeRandom(true));
      final ceilings = [for (var i = 0; i < 8; i++) hi.nextAfterFailure().inMilliseconds];
      expect(ceilings, [1000, 2000, 4000, 8000, 10000, 10000, 10000, 10000]);
      final lo = ReconnectPolicy(random: _EdgeRandom(false));
      final floors = [for (var i = 0; i < 8; i++) lo.nextAfterFailure().inMilliseconds];
      expect(floors.every((d) => d == 300), isTrue, reason: 'never a zero wait (no reconnect storm)');
      final p = ReconnectPolicy(random: math.Random(1));
      for (var i = 0; i < 500; i++) {
        expect(p.nextAfterFailure().inMilliseconds, inInclusiveRange(300, 10000));
      }
      expect(p.failures, 500);
    });

    test('reset starts with the quick retry again', () {
      final p = ReconnectPolicy(random: _EdgeRandom(true));
      for (var i = 0; i < 6; i++) {
        p.nextAfterFailure();
      }
      p.reset();
      expect(p.failures, 0);
      expect(p.nextAfterFailure(), const Duration(milliseconds: 1000));
    });

    test('a server move waits its delay plus at most 500 ms and is not a failure', () {
      final p = ReconnectPolicy(random: _EdgeRandom(true));
      p.nextAfterFailure();
      p.nextAfterFailure();
      expect(p.afterServerRequest(3000), const Duration(milliseconds: 3500));
      expect(ReconnectPolicy(random: _EdgeRandom(false)).afterServerRequest(3000), const Duration(milliseconds: 3000));
      expect(p.afterServerRequest(null).inMilliseconds, inInclusiveRange(0, 500));
      expect(p.afterServerRequest(-5).inMilliseconds, inInclusiveRange(0, 500));
      expect(p.afterServerRequest(99999999).inMilliseconds, lessThanOrEqualTo(ReconnectPolicy.serverDelayMax.inMilliseconds + 500));
      expect(p.failures, 2, reason: 'the backoff stays where it was');
    });
  });

  group('RealtimeService reconnects', () {
    testWidgets('a drop retries quickly, then backs off; one socket at a time; reset by the SNAPSHOT', (tester) async {
      final h = _Harness();
      final rt = h.rt;
      rt.connect('tok');
      expect(h.opens, 1);
      h.hello();
      expect(rt.isConnected, isTrue);
      rt.joinRoom('G1');
      h.snapshot('G1');
      expect(rt.debugFailures, 0);

      // The gateway died: quick first retry.
      rt.debugConnectionLost();
      expect(rt.state, RealtimeState.disconnected);
      expect(rt.debugLastReconnectDelay!.inMilliseconds, inInclusiveRange(300, 1000));
      // A second close signal for the same drop does not schedule a second socket.
      rt.debugConnectionLost();
      expect(rt.debugFailures, 1);
      await tester.pump(const Duration(milliseconds: 1001));
      expect(h.opens, 2);

      // That connect failed too: backoff (up to 2 s).
      rt.debugConnectionLost();
      expect(rt.debugFailures, 2);
      expect(rt.debugLastReconnectDelay!.inMilliseconds, inInclusiveRange(300, 2000));
      await tester.pump(const Duration(milliseconds: 2001));
      expect(h.opens, 3);

      // Connected to the backup: the same room is joined again; HELLO alone does not reset in a ride.
      h.sent.clear();
      h.hello();
      expect(h.joins().single['groupId'], 'G1');
      expect(rt.debugFailures, 2);
      h.snapshot('G1');
      expect(rt.debugFailures, 0);

      rt.dispose();
    });

    testWidgets('RECONNECT: no error, no failure counted, same room, back after delay + jitter', (tester) async {
      final h = _Harness();
      final rt = h.rt;
      rt.connect('tok');
      h.hello();
      rt.joinRoom('G1');
      h.snapshot('G1');
      // One earlier failure, to see that the move leaves the backoff alone.
      rt.debugConnectionLost();
      await tester.pump(const Duration(milliseconds: 1001));
      h.hello();
      expect(rt.debugFailures, 1);
      final opensBefore = h.opens;

      rt.debugReceive(jsonEncode({'type': 'RECONNECT', 'delayMs': 3000, 'reason': 'handback'}));
      expect(rt.state, RealtimeState.connecting, reason: 'the subtle "Reconnecting", never "Offline"');
      expect(rt.linkProblem, LinkProblem.none);
      expect(rt.groupId, 'G1');
      expect(rt.debugFailures, 1);
      expect(rt.debugLastReconnectDelay!.inMilliseconds, inInclusiveRange(3000, 3500));
      expect(
        ConnectionBanner.status(state: rt.state, nowMs: 0),
        'Reconnecting',
      );

      await tester.pump(const Duration(milliseconds: 2900));
      expect(h.opens, opensBefore, reason: 'waits the server delay');
      rt.retryNow(); // "network back" does not cut a server move short
      expect(h.opens, opensBefore);
      await tester.pump(const Duration(milliseconds: 601));
      expect(h.opens, opensBefore + 1);

      h.sent.clear();
      h.hello();
      expect(h.joins().single['groupId'], 'G1');
      expect(rt.debugFailures, 1);
      rt.dispose();
    });

    testWidgets('RECONNECT shutdown is handled the same way (delay as text too)', (tester) async {
      final h = _Harness();
      final rt = h.rt;
      rt.connect('tok');
      h.hello();
      rt.joinRoom('G2');
      h.snapshot('G2');
      rt.debugReceive(jsonEncode({'type': 'RECONNECT', 'delayMs': '200', 'reason': 'shutdown'}));
      expect(rt.state, RealtimeState.connecting);
      expect(rt.debugFailures, 0);
      expect(rt.debugLastReconnectDelay!.inMilliseconds, inInclusiveRange(200, 700));
      await tester.pump(const Duration(milliseconds: 701));
      expect(h.opens, 2);
      rt.dispose();
    });

    testWidgets('network back: a socket waiting in backoff opens at once, never a second one', (tester) async {
      final h = _Harness();
      final rt = h.rt;
      rt.connect('tok');
      h.hello();
      rt.debugConnectionLost();
      expect(rt.debugReconnectScheduled, isTrue);
      rt.retryNow();
      expect(h.opens, 2);
      expect(rt.state, RealtimeState.connecting);
      expect(rt.debugReconnectScheduled, isFalse);
      rt.retryNow(); // already connecting: nothing
      expect(h.opens, 2);
      await tester.pump(const Duration(seconds: 15));
      expect(h.opens, 2, reason: 'the backoff timer was replaced, not doubled');
      rt.dispose();
    });
  });

  group('SERVER_BUSY', () {
    test('HTTP 503 SERVER_BUSY becomes a plain message; the gateway counts as reached', () async {
      var reached = 0;
      final api = ApiClient(
        httpClient: MockClient((req) async => http.Response(
              jsonEncode({'code': 'SERVER_BUSY', 'error': 'Server busy, try in a few minutes'}),
              503,
            )),
        storage: const FlutterSecureStorage(),
      )..onServerReached = () => reached++;
      FlutterSecureStorage.setMockInitialValues({});
      try {
        await api.post('/convoys/join', {'code': 'ABC'});
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.statusCode, 503);
        expect(e.code, ApiException.serverBusyCode);
        expect(e.isServerBusy, isTrue);
        expect(e.endsSession, isFalse);
      }
      expect(reached, 1);
      expect(ApiException.serverBusyMessage, 'Server busy. Try again in a few minutes.');
    });

    test('a proxy 503 page is not "server busy" and not the gateway', () async {
      var reached = 0;
      final api = ApiClient(
        httpClient: MockClient((req) async => http.Response('<html>503</html>', 503)),
        storage: const FlutterSecureStorage(),
      )..onServerReached = () => reached++;
      try {
        await api.post('/convoys', {});
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.isServerBusy, isFalse);
      }
      expect(reached, 0);
    });

    test('ride top bar: connected but busy shows the plain message', () {
      expect(ConnectionBanner.status(state: RealtimeState.connected, nowMs: 0, serverBusy: true), ApiException.serverBusyMessage);
      expect(ConnectionBanner.status(state: RealtimeState.connected, nowMs: 0), isNull);
    });
  });
}
