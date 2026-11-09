import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/config/app_config.dart';

/// 3.54 security: release builds never talk to the gateway over plain HTTP / WS.
void main() {
  group('AppConfig.resolveApiBase', () {
    test('release: https is kept (trailing slash trimmed)', () {
      expect(AppConfig.resolveApiBase('https://api.example.com/', release: true), 'https://api.example.com');
    });

    test('release: http, ws, a bare host or credentials in the URL fall back to the production HTTPS gateway', () {
      for (final bad in [
        'http://192.168.1.20:8080',
        'ws://api.example.com',
        'api.example.com',
        'https://',
        'https://user:secret@api.example.com',
        '   ',
      ]) {
        expect(AppConfig.resolveApiBase(bad, release: true), AppConfig.defaultApiBaseUrl, reason: bad);
      }
      expect(AppConfig.defaultApiBaseUrl, startsWith('https://'));
    });

    test('debug: a plain-HTTP LAN gateway is allowed for development', () {
      expect(AppConfig.resolveApiBase('http://192.168.1.20:8080', release: false), 'http://192.168.1.20:8080');
    });

    test('the WebSocket follows the scheme: https -> wss', () {
      expect(AppConfig.wsUrlFor('https://api.example.com'), 'wss://api.example.com/ws');
      expect(AppConfig.wsUrlFor(AppConfig.resolveApiBase('http://10.0.0.2', release: true)), 'wss://coroute.devmonks.space/ws');
    });

    test('tests run in debug: the default gateway is HTTPS', () {
      expect(AppConfig.apiBaseUrl, startsWith('https://'));
      expect(AppConfig.wsUrl, startsWith('wss://'));
    });
  });
}
