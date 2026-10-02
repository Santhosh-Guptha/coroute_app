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
  const ApiException(this.statusCode, this.message);

  bool get isUnauthorized => statusCode == 401;
  bool get isOffline => statusCode == 0;

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

  /// Loads the persisted token. Safe to call repeatedly.
  Future<void> init() async {
    if (_loaded) return;
    try {
      _token = await _storage.read(key: _tokenKey);
    } catch (e) {
      debugPrint('Secure storage read note: $e');
    }
    _loaded = true;
  }

  Future<void> setToken(String? token) async {
    _token = token;
    try {
      if (token == null) {
        await _storage.delete(key: _tokenKey);
      } else {
        await _storage.write(key: _tokenKey, value: token);
      }
    } catch (e) {
      debugPrint('Secure storage write note: $e');
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
    if (res.body.isNotEmpty) {
      try {
        decoded = jsonDecode(res.body);
      } catch (_) {
        decoded = {'error': res.body};
      }
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return decoded;

    final message = (decoded is Map && decoded['error'] != null) ? decoded['error'].toString() : 'Request failed (${res.statusCode})';
    if (res.statusCode == 401 && hasToken) {
      // Session expired or revoked: drop the token so the app returns to login.
      await setToken(null);
    }
    throw ApiException(res.statusCode, message);
  }
}
