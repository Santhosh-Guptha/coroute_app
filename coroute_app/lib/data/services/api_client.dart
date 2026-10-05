import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../../core/config/app_config.dart';

/// Thrown for any non-2xx gateway response.
class ApiException implements Exception {
  final int statusCode;
  final String message;

  /// Machine-readable cause sent by the gateway (for example SESSION_INVALID, ACCOUNT_GONE, NOT_MEMBER).
  /// Null when the response did not come from the gateway (captive portal, proxy, outage page).
  final String? code;
  const ApiException(this.statusCode, this.message, [this.code]);

  bool get isUnauthorized => statusCode == 401;
  bool get isOffline => statusCode == 0;

  /// True only when the gateway itself says the session is over. Network trouble,
  /// timeouts, server restarts and Wi-Fi login pages never count.
  bool get endsSession => code == 'SESSION_INVALID' || code == 'ACCOUNT_GONE';

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Single HTTP client for the CoRoute gateway.
///
/// * Attaches the JWT (kept in the platform keystore via flutter_secure_storage).
/// * Normalises errors into [ApiException].
/// * Notifies listeners when the session expires so the UI can return to login.
class ApiClient extends ChangeNotifier {
  ApiClient({http.Client? httpClient, FlutterSecureStorage? storage})
      : _http = httpClient ?? http.Client(),
        _storage = storage ?? const FlutterSecureStorage();

  static const _tokenKey = 'coroute_jwt';
  final http.Client _http;
  final FlutterSecureStorage _storage;
  String? _token;
  bool _loaded = false;

  String? get token => _token;
  bool get hasToken => _token != null && _token!.isNotEmpty;

  static const _sessionHeader = 'x-coroute-token';

  /// Loads the persisted token. Safe to call repeatedly.
  ///
  /// The Android keystore can be briefly unavailable (right after boot, while
  /// the phone is busy): retry instead of treating a failed read as "signed out".
  Future<void> init() async {
    if (_loaded) return;
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        _token = await _storage.read(key: _tokenKey);
        break;
      } catch (e) {
        debugPrint('Secure storage read note (attempt ${attempt + 1}): $e');
        await Future.delayed(Duration(milliseconds: 250 * (attempt + 1)));
      }
    }
    _loaded = true;
  }

  Future<void> setToken(String? token) async {
    _token = token;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (token == null) {
          await _storage.delete(key: _tokenKey);
        } else {
          await _storage.write(key: _tokenKey, value: token);
        }
        break;
      } catch (e) {
        debugPrint('Secure storage write note (attempt ${attempt + 1}): $e');
        await Future.delayed(Duration(milliseconds: 250 * (attempt + 1)));
      }
    }
    notifyListeners();
  }

  Map<String, String> _headers({bool auth = true}) => {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        if (auth && hasToken) 'Authorization': 'Bearer $_token',
      };

  Future<dynamic> get(String path, {Duration timeout = const Duration(seconds: 10)}) =>
      _send(() => _http.get(Uri.parse('${AppConfig.apiUrl}$path'), headers: _headers()), timeout);

  /// GET for non-JSON bodies (for example a GPX file). Throws [ApiException] on failure.
  Future<String> getText(String path, {Duration timeout = const Duration(seconds: 20)}) async {
    http.Response res;
    try {
      res = await _http.get(Uri.parse('${AppConfig.apiUrl}$path'), headers: _headers()).timeout(timeout);
    } on TimeoutException {
      throw const ApiException(0, 'The server did not respond. Check your connection.');
    } catch (e) {
      throw ApiException(0, 'Network error: ${e.runtimeType}');
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return res.body;
    String? message;
    String? code;
    try {
      final d = jsonDecode(res.body);
      if (d is Map) {
        message = d['error']?.toString();
        code = d['code']?.toString();
      }
    } catch (_) {}
    throw ApiException(res.statusCode, message ?? 'Request failed (${res.statusCode})', code);
  }

  Future<dynamic> post(String path, [Object? body, Duration timeout = const Duration(seconds: 12), bool auth = true]) =>
      _send(() => _http.post(Uri.parse('${AppConfig.apiUrl}$path'), headers: _headers(auth: auth), body: jsonEncode(body ?? {})), timeout);

  Future<dynamic> patch(String path, Object? body) =>
      _send(() => _http.patch(Uri.parse('${AppConfig.apiUrl}$path'), headers: _headers(), body: jsonEncode(body ?? {})), const Duration(seconds: 12));

  Future<dynamic> delete(String path) =>
      _send(() => _http.delete(Uri.parse('${AppConfig.apiUrl}$path'), headers: _headers()), const Duration(seconds: 12));

  Future<dynamic> _send(Future<http.Response> Function() call, Duration timeout) async {
    http.Response res;
    try {
      res = await call().timeout(timeout);
    } on TimeoutException {
      throw const ApiException(0, 'The server did not respond. Check your connection.');
    } catch (e) {
      throw ApiException(0, 'Network error: ${e.runtimeType}');
    }

    dynamic decoded;
    var fromGateway = false;
    if (res.body.isNotEmpty) {
      try {
        decoded = jsonDecode(res.body);
        fromGateway = decoded is Map || decoded is List;
      } catch (_) {
        decoded = null; // HTML or text: a Wi-Fi login page, a proxy or an outage page, not our server
      }
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      // Sliding session: the server hands out a fresh token now and then.
      final fresh = res.headers[_sessionHeader];
      if (fresh != null && fresh.isNotEmpty && hasToken && fresh != _token) await setToken(fresh);
      return decoded;
    }

    final message = (fromGateway && decoded is Map && decoded['error'] != null)
        ? decoded['error'].toString()
        : (res.statusCode >= 500 || !fromGateway)
            ? 'The server is not reachable right now. Try again in a moment.'
            : 'Request failed (${res.statusCode})';
    final code = (fromGateway && decoded is Map && decoded['code'] != null) ? decoded['code'].toString() : null;
    final error = ApiException(res.statusCode, message, code);
    if (error.endsSession && hasToken) {
      // Only the gateway saying so ends the session; bad networks never sign anyone out.
      await setToken(null);
    }
    throw error;
  }
}
