import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/config/app_config.dart';
import 'package:coroute_app/core/config/gateway_hosts.dart';

/// Domain move (docs/DOMAIN_MIGRATION_devmonks.md): try coroute.devmonks.space, fall back to
/// coroute.duckdns.org when it cannot be reached, keep the first host that answers.
void main() {
  const primary = 'https://coroute.devmonks.space';
  const legacy = 'https://coroute.duckdns.org';
  final dns = const SocketException('Failed host lookup: \'coroute.devmonks.space\'');

  group('AppConfig hosts', () {
    test('the default is the new domain with the legacy fallback; an override has no fallback', () {
      expect(AppConfig.defaultApiBaseUrl, primary);
      expect(AppConfig.legacyApiBaseUrl, legacy);
      expect(AppConfig.hostsFor(AppConfig.resolveApiBase('', release: true)), [primary, legacy]);
      expect(AppConfig.hostsFor(AppConfig.resolveApiBase('https://api.example.com/', release: true)), ['https://api.example.com']);
      expect(AppConfig.hostsFor(AppConfig.resolveApiBase('http://10.0.0.2', release: true)), [primary, legacy]);
      expect(AppConfig.apiBaseUrl, AppConfig.gatewayHosts.current);
    });
  });

  group('GatewayHosts', () {
    test('starts on the primary host', () {
      final h = GatewayHosts([primary, legacy]);
      expect(h.current, primary);
      expect(h.onFallback, isFalse);
      expect(h.locked, isFalse);
    });

    test('DNS failure on the primary: switch to legacy and retry once', () {
      final h = GatewayHosts([primary, legacy]);
      expect(h.reportFailure(primary, dns), isTrue);
      expect(h.current, legacy);
      expect(h.onFallback, isTrue);
    });

    test('TLS handshake failure and connection refused also switch and retry', () {
      final a = GatewayHosts([primary, legacy]);
      expect(a.reportFailure(primary, const HandshakeException('CERTIFICATE_VERIFY_FAILED')), isTrue);
      expect(a.current, legacy);
      final b = GatewayHosts([primary, legacy]);
      expect(b.reportFailure(primary, Exception('ClientException with SocketException: Connection refused')), isTrue);
      expect(b.current, legacy);
    });

    test('timeout or connection reset: switch for the next request, but never retry (no double POST)', () {
      final h = GatewayHosts([primary, legacy]);
      expect(h.reportFailure(primary, TimeoutException('slow')), isFalse);
      expect(h.current, legacy);
      final r = GatewayHosts([primary, legacy]);
      expect(r.reportFailure(primary, const SocketException('Connection reset by peer')), isFalse);
      expect(r.current, legacy);
    });

    test('an error that is not about the host never switches', () {
      final h = GatewayHosts([primary, legacy]);
      expect(h.reportFailure(primary, const FormatException('bad json')), isFalse);
      expect(h.current, primary);
    });

    test('the first host that answers is kept for the session', () {
      final h = GatewayHosts([primary, legacy]);
      h.reportFailure(primary, dns);
      h.reportSuccess(legacy);
      expect(h.locked, isTrue);
      expect(h.reportFailure(legacy, dns), isFalse, reason: 'locked: a later outage does not flip hosts');
      expect(h.current, legacy);
      final p = GatewayHosts([primary, legacy]);
      p.reportSuccess(primary);
      expect(p.reportFailure(primary, dns), isFalse);
      expect(p.current, primary);
    });

    test('both hosts down: alternates instead of getting stuck', () {
      final h = GatewayHosts([primary, legacy]);
      h.reportFailure(primary, dns);
      expect(h.reportFailure(legacy, dns), isTrue);
      expect(h.current, primary);
    });

    test('a stale failure report (another request already switched) is ignored', () {
      final h = GatewayHosts([primary, legacy]);
      h.reportFailure(primary, dns);
      expect(h.reportFailure(primary, dns), isFalse);
      expect(h.current, legacy);
    });

    test('a single host (COROUTE_API override) never switches; duplicates and trailing slashes collapse', () {
      final one = GatewayHosts(['https://api.example.com']);
      expect(one.reportFailure('https://api.example.com', dns), isFalse);
      expect(one.current, 'https://api.example.com');
      expect(GatewayHosts([primary, '$primary/', legacy]).hosts, [primary, legacy]);
      expect(GatewayHosts.classify(dns), HostFailure.unreachable);
    });
  });
}
