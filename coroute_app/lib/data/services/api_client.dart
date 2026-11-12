import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../../core/config/app_config.dart';
import '../../domain/diag/diag_log.dart'; // 3.55 diagnostics log (no personal data)
import '../../domain/diag/diag_redact.dart';
import '../../domain/membership/plan_gate_messages.dart'; // Play payments policy: neutral plan refusals
import '../../domain/auth/session_policy.dart'; // 3.57 sessions: refresh once, end only on gateway codes

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

  /// Round 4: the gateway's whole error body (for example `device` and `lockToken` of a 423 RIDE_ACTIVE_ELSEWHERE,
  /// `methods` of a 403 MFA_REQUIRED, `triesLeft` of a wrong code). Null when not from the gateway.
  final Map<String, dynamic>? body;
  const ApiException(this.statusCode, this.message, [this.code, this.reason, this.body]);

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
/// * 3.57 sessions: asks for a short access token + rotating refresh token at sign-in (`X-CoRoute-Session: 2`);
///   a 401 `TOKEN_EXPIRED` is refreshed once (one refresh at a time) and the call repeated once. Only the
///   gateway's own session codes end the session; a failed refresh because of the network never does.
///   Builds before 10025 keep the long sliding token; a stored one keeps working (the gateway migrates it).
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
  static const _refreshKey = 'coroute_refresh';
  final http.Client _http;
  final FlutterSecureStorage _storage;
  String? _token;
  String? _refreshToken;
  bool _loaded = false;

  String? get token => _token;
  bool get hasToken => _token != null && _token!.isNotEmpty;

  /// True when this phone holds a refresh token (signed in with a 3.57+ build).
  bool get hasRefreshToken => _refreshToken != null && _refreshToken!.isNotEmpty;

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
        _refreshToken = await _storage.read(key: _refreshKey);
        break;
      } catch (e) {
        debugPrint('Secure storage read note (attempt ${attempt + 1}): $e');
        await Future.delayed(Duration(milliseconds: 250 * (attempt + 1)));
      }
    }
    _loaded = true;
    // A saved session counts as "signed in" for the services listening here (friends, crews,
    // feature switches, push token...). Without this, services created before the token was read
    // never loaded anything at a cold start (3.55: incoming friend requests stayed invisible).
    if (hasToken) notifyListeners();
  }

  Future<void> setToken(String? token) async {
    _token = token;
    if (token == null) _refreshToken = null; // the session is over: its refresh token goes too
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (token == null) {
          await _storage.delete(key: _tokenKey);
          await _storage.delete(key: _refreshKey);
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

  /// 3.57: stores a new session (sign-in or refresh). [refreshToken] null keeps the stored one.
  Future<void> setSession(String token, {String? refreshToken}) async {
    if (refreshToken != null && refreshToken.isNotEmpty) {
      _refreshToken = refreshToken;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          await _storage.write(key: _refreshKey, value: refreshToken);
          break;
        } catch (e) {
          debugPrint('Secure storage write note (attempt ${attempt + 1}): $e');
          await Future.delayed(Duration(milliseconds: 250 * (attempt + 1)));
        }
      }
    }
    await setToken(token);
  }

  Future<bool>? _refreshing;

  /// Refreshes the access token once (concurrent callers share one request). True when a new token is stored.
  /// A refused refresh (the gateway says the session is over) ends the session; a network failure keeps it.
  Future<bool> refreshSession() {
    final inFlight = _refreshing;
    if (inFlight != null) return inFlight;
    final f = _doRefresh().whenComplete(() => _refreshing = null);
    _refreshing = f;
    return f;
  }

  Future<bool> _doRefresh() async {
    final rt = _refreshToken;
    if (rt == null || rt.isEmpty) return false;
    http.Response res;
    try {
      res = await _http
          .post(Uri.parse('${AppConfig.apiUrl}/auth/refresh'), headers: _headers(auth: false), body: jsonEncode({'refreshToken': rt}))
          .timeout(const Duration(seconds: 12));
    } catch (e) {
      DiagLog.warn(DiagCat.network, 'refresh_offline', {'type': e.runtimeType.toString()});
      return false; // offline: keep the session, try again on the next call
    }
    Map? body;
    try {
      final d = jsonDecode(res.body);
      if (d is Map) body = d;
    } catch (_) {}
    if (res.statusCode == 200 && body != null && body['token'] is String) {
      await setSession(body['token'] as String, refreshToken: body['refreshToken'] as String?);
      return true;
    }
    final code = body?['code']?.toString();
    if (body != null && SessionPolicy.actionFor(res.statusCode, code, canRefresh: false) == SessionAction.end && hasToken) {
      lastSessionEndMessage = body['error']?.toString() ?? 'You were signed out. Please sign in again.';
      await setToken(null);
    }
    return false;
  }

  /// Refreshes first when the access token has less than [minSeconds] left (before a socket reconnect).
  Future<void> ensureFreshToken({int minSeconds = 60}) async {
    if (!hasRefreshToken) return;
    final left = SessionPolicy.secondsLeft(_token);
    if (left != null && left < minSeconds) await refreshSession();
  }

  /// 3.57: ends this session on the gateway (best effort, short timeout; the phone forgets it either way).
  Future<void> revokeSession() async {
    if (!hasToken && !hasRefreshToken) return;
    try {
      await _http
          .post(Uri.parse('${AppConfig.apiUrl}/auth/logout'), headers: _headers(), body: jsonEncode({if (hasRefreshToken) 'refreshToken': _refreshToken}))
          .timeout(const Duration(seconds: 6));
    } catch (_) {
      // Offline: the session ends on the server after 30 days without use, and this phone forgets it now.
    }
  }

  /// 3.57: "Sign out of all devices": every session and token of the account ends on the gateway.
  /// Throws [ApiException] when the gateway could not be reached (nothing was signed out anywhere).
  Future<void> revokeAllSessions() async {
    await post('/auth/logout-all', const {}, const Duration(seconds: 12));
  }

  Map<String, String> _headers({bool auth = true}) => {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        if (auth && hasToken) 'Authorization': 'Bearer $_token',
        if (appBuild > 0) 'X-CoRoute-Build': '$appBuild',
        // 3.57: this build refreshes short access tokens (read by the gateway at sign-in).
        'X-CoRoute-Session': '2',
        'X-CoRoute-Client': 'app',
      };

  Future<dynamic> get(String path, {Duration timeout = const Duration(seconds: 10)}) =>
      _send(() => _http.get(Uri.parse('${AppConfig.apiUrl}$path'), headers: _headers()), timeout, method: 'GET', path: path);

  /// GET for non-JSON bodies (for example a GPX file). Throws [ApiException] on failure.
  Future<String> getText(String path, {Duration timeout = const Duration(seconds: 20)}) async {
    await ensureFreshToken();
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
    final error = ApiException(res.statusCode, PlanGateMessages.neutral(code, reason, message ?? 'Request failed (${res.statusCode})'), code, reason);
    if (error.endsSession && hasToken) {
      // Same rule as JSON calls: only the gateway saying so ends the session.
      lastSessionEndMessage = error.message;
      await setToken(null);
    }
    throw error;
  }

  /// 3.55: GET for binary bodies (an admin downloading a diagnostics log bundle). Throws
  /// [ApiException] on failure (the body is not read as JSON).
  Future<Uint8List> getBytes(String path, {Duration timeout = const Duration(seconds: 60)}) async {
    await ensureFreshToken();
    http.Response res;
    try {
      res = await _http.get(Uri.parse('${AppConfig.apiUrl}$path'), headers: _headers()).timeout(timeout);
    } on TimeoutException {
      throw const ApiException(0, 'The server did not respond. Check your connection.');
    } catch (e) {
      throw ApiException(0, 'Network error: ${e.runtimeType}');
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return res.bodyBytes;
    String? message;
    try {
      final d = jsonDecode(res.body);
      if (d is Map) message = d['error']?.toString();
    } catch (_) {}
    throw ApiException(res.statusCode, message ?? 'Request failed (${res.statusCode})');
  }

  Future<dynamic> post(String path, [Object? body, Duration timeout = const Duration(seconds: 12), bool auth = true]) =>
      _send(() => _http.post(Uri.parse('${AppConfig.apiUrl}$path'), headers: _headers(auth: auth), body: jsonEncode(body ?? {})), timeout, method: 'POST', path: path);

  Future<dynamic> put(String path, [Object? body, Duration timeout = const Duration(seconds: 12)]) =>
      _send(() => _http.put(Uri.parse('${AppConfig.apiUrl}$path'), headers: _headers(), body: jsonEncode(body ?? {})), timeout, method: 'PUT', path: path);

  Future<dynamic> patch(String path, Object? body) =>
      _send(() => _http.patch(Uri.parse('${AppConfig.apiUrl}$path'), headers: _headers(), body: jsonEncode(body ?? {})), const Duration(seconds: 12), method: 'PATCH', path: path);

  Future<dynamic> delete(String path) =>
      _send(() => _http.delete(Uri.parse('${AppConfig.apiUrl}$path'), headers: _headers()), const Duration(seconds: 12), method: 'DELETE', path: path);

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
        method: 'POST',
        path: path,
      );

  /// Full address of a gateway path such as `/admin/reviews/<id>/photos/<photoId>`.
  String apiUrlOf(String path) => '${AppConfig.apiUrl}$path';

  /// Headers for an image the gateway only shows to the signed-in rider or an admin (Image.network).
  Map<String, String> get authHeaders => {if (hasToken) 'Authorization': 'Bearer $_token'};

  /// Round 4: shows the 2-step prompt when an admin call answers 403 MFA_REQUIRED (set in main.dart); resolves true
  /// when the session passed the step-up (POST /auth/mfa/step-up), so the call is repeated once.
  Future<bool> Function(Map<String, dynamic> challenge)? onMfaRequired;

  Future<dynamic> _send(Future<http.Response> Function() call, Duration timeout, {bool retried = false, bool refreshed = false, bool mfaRetried = false, String method = '?', String path = ''}) async {
    http.Response res;
    // Domain move: the base this attempt used (call() reads AppConfig.apiUrl when it runs).
    final base = AppConfig.apiBaseUrl;
    final sw = Stopwatch()..start();
    try {
      res = await call().timeout(timeout);
    } on TimeoutException catch (e) {
      AppConfig.gatewayHosts.reportFailure(base, e);
      DiagLog.warn(DiagCat.network, 'api_timeout', {'method': method, 'path': DiagRedact.pathTemplate(path), 'ms': sw.elapsedMilliseconds});
      throw const ApiException(0, 'The server did not respond. Check your connection.');
    } catch (e) {
      // The host could not be reached at all (DNS / TLS): try the other gateway host once.
      if (AppConfig.gatewayHosts.reportFailure(base, e) && !retried) return _send(call, timeout, retried: true, refreshed: refreshed, mfaRetried: mfaRetried, method: method, path: path);
      DiagLog.warn(DiagCat.network, 'api_offline', {'method': method, 'path': DiagRedact.pathTemplate(path), 'type': e.runtimeType.toString(), 'ms': sw.elapsedMilliseconds});
      throw ApiException(0, 'Network error: ${e.runtimeType}');
    }
    final ms = sw.elapsedMilliseconds;
    if (res.statusCode >= 400) {
      // Method, path template (no ids, no query), status and time only: never bodies.
      DiagLog.log(res.statusCode >= 500 ? DiagLevel.error : DiagLevel.warn, DiagCat.network, 'api_error',
          {'method': method, 'path': DiagRedact.pathTemplate(path), 'status': res.statusCode, 'ms': ms, 'reqId': res.headers['x-request-id']});
    } else if (ms > 5000) {
      DiagLog.info(DiagCat.network, 'api_slow', {'method': method, 'path': DiagRedact.pathTemplate(path), 'status': res.statusCode, 'ms': ms});
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
    if (fromGateway) {
      AppConfig.gatewayHosts.reportSuccess(base);
      onServerReached?.call();
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
    final reason = (fromGateway && decoded is Map && decoded['reason'] != null) ? decoded['reason'].toString() : null;
    // 3.57: a short access token ran out: one refresh (shared), then this call once more. Never a loop.
    if (fromGateway && SessionPolicy.actionFor(res.statusCode, code, canRefresh: !refreshed && hasRefreshToken) == SessionAction.refresh) {
      if (await refreshSession()) return _send(call, timeout, retried: retried, refreshed: true, mfaRetried: mfaRetried, method: method, path: path);
    }
    // Round 4: an admin call answered MFA_REQUIRED: the app asks for the 2-step code (step-up), then repeats once.
    final mfa = onMfaRequired;
    if (fromGateway && res.statusCode == 403 && code == 'MFA_REQUIRED' && mfa != null && !mfaRetried) {
      bool ok = false;
      try {
        ok = await mfa(decoded is Map ? Map<String, dynamic>.from(decoded) : const <String, dynamic>{});
      } catch (_) {
        ok = false;
      }
      if (ok) return _send(call, timeout, retried: retried, refreshed: refreshed, mfaRetried: true, method: method, path: path);
    }
    final error = ApiException(res.statusCode, PlanGateMessages.neutral(code, reason, message), code, reason,
        fromGateway && decoded is Map ? Map<String, dynamic>.from(decoded) : null);
    if (error.endsSession && hasToken) {
      // Only the gateway saying so ends the session; bad networks never sign anyone out.
      lastSessionEndMessage = message;
      await setToken(null);
    }
    throw error;
  }
}
