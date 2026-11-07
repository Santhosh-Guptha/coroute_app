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

  /// Why the gateway refused a request it understood (for example COUPON_EXPIRED,
  /// PER_USER_LIMIT_REACHED, TIER_MISMATCH): the `reason` field of its error body.
  final String? reason;
  const ApiException(this.statusCode, this.message, [this.code, this.reason]);

  bool get isUnauthorized => statusCode == 401;
  bool get isOffline => statusCode == 0;

  /// The gateway is full for new rides or new riders right now (HTTP 503, or a socket ERROR
  /// on JOIN, with this code). Not the rider's fault and never a removal from a ride.
  static const String serverBusyCode = 'SERVER_BUSY';

  /// What the app says for [serverBusyCode] (with a retry).
  static const String serverBusyMessage = 'Server busy. Try again in a few minutes.';

  bool get isServerBusy => code == serverBusyCode;

  /// Gateway codes that end the session on this phone.
  static const sessionEndingCodes = {'SESSION_INVALID', 'ACCOUNT_GONE', 'ACCOUNT_ON_HOLD', 'ACCOUNT_BLOCKED'};

  /// True only when the gateway itself says the session is over (signed out elsewhere,
  /// account deleted, on hold or blocked). Network trouble, timeouts, server restarts
  /// and Wi-Fi login pages never count.
  bool get endsSession => code != null && sessionEndingCodes.contains(code);

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Single HTTP client for the CoRoute gateway.
///
/// * Attaches the JWT (kept in the platform keystore via flutter_secure_storage).
/// * Normalises errors into [ApiException].
/// * Notifies listeners when the session expires so the UI can return to login.
class ApiClient extends ChangeNotifier {
  /// This app's build number, sent with every request so the server knows
  /// which builds are still in use (set at start-up; 0 = unknown, not sent).
  static int appBuild = 0;

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

  /// The gateway's message when it last ended the session (for example "Your account has
  /// been blocked by the administrator."), so the sign-in screen can say why.
  String? lastSessionEndMessage;

  /// Called whenever the gateway itself answered (any status): the network is back, so the
  /// realtime socket can stop waiting out its backoff (see RealtimeService.retryNow).
  VoidCallback? onServerReached;

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
        if (appBuild > 0) 'X-CoRoute-Build': '$appBuild',
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
    String? reason;
    try {
      final d = jsonDecode(res.body);
      if (d is Map) {
        message = d['error']?.toString();
        code = d['code']?.toString();
        reason = d['reason']?.toString();
      }
    } catch (_) {}
    final error = ApiException(res.statusCode, message ?? 'Request failed (${res.statusCode})', code, reason);
    if (error.endsSession && hasToken) {
      // Same rule as JSON calls: only the gateway saying so ends the session.
      lastSessionEndMessage = error.message;
      await setToken(null);
    }
    throw error;
  }

  Future<dynamic> post(String path, [Object? body, Duration timeout = const Duration(seconds: 12), bool auth = true]) =>
      _send(() => _http.post(Uri.parse('${AppConfig.apiUrl}$path'), headers: _headers(auth: auth), body: jsonEncode(body ?? {})), timeout);

  Future<dynamic> put(String path, [Object? body, Duration timeout = const Duration(seconds: 12)]) =>
      _send(() => _http.put(Uri.parse('${AppConfig.apiUrl}$path'), headers: _headers(), body: jsonEncode(body ?? {})), timeout);

  Future<dynamic> patch(String path, Object? body) =>
      _send(() => _http.patch(Uri.parse('${AppConfig.apiUrl}$path'), headers: _headers(), body: jsonEncode(body ?? {})), const Duration(seconds: 12));

  Future<dynamic> delete(String path) =>
      _send(() => _http.delete(Uri.parse('${AppConfig.apiUrl}$path'), headers: _headers()), const Duration(seconds: 12));

  // ---------- post-trip reviews ----------

  static Map<String, dynamic> _asMap(Object? res) => res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};

  /// The signed-in rider's review of [tripId] (a trip id or a convoy groupId) and whether they
  /// may review it: `{ok, canReview, code, feedback}`; `feedback` is null when there is none.
  Future<Map<String, dynamic>> getTripReview(String tripId) async =>
      _asMap(await get('/trips/${Uri.encodeComponent(tripId)}/feedback'));

  /// Creates or updates the rider's review (one per rider per trip). It stays pending until an
  /// admin approves it: `{ok, updated, feedback}`.
  Future<Map<String, dynamic>> submitTripReview(String tripId, Map<String, dynamic> review) async =>
      _asMap(await post('/trips/${Uri.encodeComponent(tripId)}/feedback', review, const Duration(seconds: 20)));

  /// Takes the rider's review down (it leaves the website at once).
  Future<Map<String, dynamic>> withdrawTripReview(String tripId) async =>
      _asMap(await delete('/trips/${Uri.encodeComponent(tripId)}/feedback'));

  /// Admin: trip reviews, optionally of one status (PENDING_REVIEW, APPROVED, REJECTED,
  /// CHANGES_REQUESTED, WITHDRAWN): `{ok, summary, reviews}`.
  Future<Map<String, dynamic>> adminListReviews({String? status}) async {
    final q = status == null || status.isEmpty ? '' : '?status=${Uri.encodeQueryComponent(status)}';
    return _asMap(await get('/admin/reviews$q', timeout: const Duration(seconds: 15)));
  }

  /// Admin: APPROVE, REJECT (needs `reason`), REQUEST_CHANGES (needs `reason`), WITHDRAW or EDIT,
  /// with an optional `formattedText` (public excerpt) and `selectedPhotos`: `{ok, feedback}`.
  Future<Map<String, dynamic>> adminModerateReview(String feedbackId, Map<String, dynamic> body) async =>
      _asMap(await put('/admin/reviews/${Uri.encodeComponent(feedbackId)}', body));

  /// Adds one photo (raw JPEG, PNG or WebP bytes, at most 2 MB) to the rider's review of [tripId].
  /// The review must already be sent with the photo consent ticked: `{ok, photo, feedback}`.
  Future<Map<String, dynamic>> uploadTripReviewPhoto(String tripId, Uint8List bytes, String contentType) async =>
      _asMap(await _send(
        () => _http.post(
          Uri.parse('${AppConfig.apiUrl}/trips/${Uri.encodeComponent(tripId)}/feedback/photos'),
          headers: {..._headers(), 'Content-Type': contentType},
          body: bytes,
        ),
        const Duration(seconds: 60),
      ));

  /// 3.55: POSTs raw bytes (a photo) to a gateway path, e.g. a place review photo. Throws
  /// [ApiException] like the JSON calls.
  Future<dynamic> postBytes(String path, Uint8List bytes, String contentType, {Duration timeout = const Duration(seconds: 60)}) =>
      _send(
        () => _http.post(Uri.parse('${AppConfig.apiUrl}$path'), headers: {..._headers(), 'Content-Type': contentType}, body: bytes),
        timeout,
      );

  /// Full address of a gateway path such as `/admin/reviews/<id>/photos/<photoId>`.
  String apiUrlOf(String path) => '${AppConfig.apiUrl}$path';

  /// Headers for an image the gateway only shows to the signed-in rider or an admin (Image.network).
  Map<String, String> get authHeaders => {if (hasToken) 'Authorization': 'Bearer $_token'};

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
    if (fromGateway) onServerReached?.call();
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
    final reason = (fromGateway && decoded is Map && decoded['reason'] != null) ? decoded['reason'].toString() : null;
    final error = ApiException(res.statusCode, message, code, reason);
    if (error.endsSession && hasToken) {
      // Only the gateway saying so ends the session; bad networks never sign anyone out.
      lastSessionEndMessage = message;
      await setToken(null);
    }
    throw error;
  }
}
