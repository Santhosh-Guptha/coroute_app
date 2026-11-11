import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config/app_config.dart';
import '../../domain/diag/diag_log.dart'; // 3.55 diagnostics log (no personal data)
import '../../domain/notify/push_routing.dart';
import '../../domain/notify/push_kinds.dart';
import 'api_client.dart';
import 'meta_service.dart';
import 'permissions_service.dart';

/// One push: tapped in the notification shade ([PushService.opened]) or received while the app was
/// in front ([PushService.messages]).
class PushMessage {
  final String type;
  final Map<String, String> payload;
  final String title;
  final String body;
  const PushMessage(this.type, this.payload, {this.title = '', this.body = ''});

  PushRoute get route => PushRouting.routeFor(type, payload);
}

/// 3.55 push notifications (Firebase Cloud Messaging; docs/features_355/push_notifications.md).
///
/// Talks to the native MethodChannel `coroute/push` (PushChannel.kt). No Dart Firebase package:
/// Android owns the FCM client and shows the notification while the app is closed.
///  * After sign-in (and on every token refresh) the FCM token is sent to the gateway:
///    POST /api/me/push-tokens {token, platform:'android', appVersion}.
///  * On sign-out the token is removed (DELETE with the last session) and deleted at FCM, so the
///    phone stops receiving pushes for that account.
///  * The rider's "Push notifications" switch (default on) is kept here (SharedPreferences) and
///    mirrored to Android.
///  * [opened] / [takePendingOpen]: notifications the rider tapped (a cold start is read from the
///    launch intent). [messages]: pushes received while the app was in front.
/// Without the Firebase build values (or off Android) [available] is false and nothing happens.
class PushService extends ChangeNotifier {
  PushService(this._api, {MethodChannel? channel, http.Client? client, bool? android})
      : _channel = channel ?? const MethodChannel('coroute/push'),
        _http = client ?? http.Client(),
        _android = android ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static const String prefKey = 'push_notifications_enabled';

  /// 3.56: the rider's "News and updates" category switch (admin pushes). Safety, ride and social
  /// pushes are not part of it and cannot be turned off here.
  static const String newsPrefKey = 'push_news_enabled';

  final ApiClient _api;
  final MethodChannel _channel;
  final http.Client _http;
  final bool _android;

  bool _started = false;
  bool _disposed = false;
  bool _available = false;
  bool _enabled = true;
  bool _newsEnabled = true;

  /// 3.56 the other push kinds' switches (events, safety tips, community, partner perks), by kind id.
  final Map<String, bool> _kinds = {for (final k in PushKinds.all) if (k != PushKinds.update) k.id: k.defaultOn};
  bool _hadToken = false;
  String? _lastBearer;
  String? _registeredToken;
  bool _registering = false;
  PushMessage? _pendingOpen;

  final StreamController<PushMessage> _opened = StreamController<PushMessage>.broadcast();
  final StreamController<PushMessage> _messages = StreamController<PushMessage>.broadcast();

  /// The build has the Firebase values and Android initialised it.
  bool get available => _available;

  /// The rider's switch (default on).
  bool get enabled => _enabled;

  /// The "News and updates" switch (default on). Kept on the gateway (PUT /api/me/push-prefs), so
  /// the server never sends admin pushes to a rider who turned it off; also mirrored to Android,
  /// which drops a NEWS push while it is off.
  bool get newsEnabled => _newsEnabled;

  /// 3.56: the switch of one push kind ([PushKinds]); "News and updates" is [newsEnabled].
  bool kindEnabled(PushKind kind) => kind == PushKinds.update ? _newsEnabled : (_kinds[kind.id] ?? kind.defaultOn);

  /// The token the gateway has for this phone (null until registered).
  String? get registeredToken => _registeredToken;

  Stream<PushMessage> get opened => _opened.stream;
  Stream<PushMessage> get messages => _messages.stream;

  /// The last tapped notification nobody handled yet (cold start); taken once.
  PushMessage? takePendingOpen() {
    final p = _pendingOpen;
    _pendingOpen = null;
    return p;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<T?> _invoke<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } catch (e) {
      debugPrint('push: $method note: $e');
      return null;
    }
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _hadToken = _api.hasToken;
    _lastBearer = _api.token;
    _api.addListener(_onApiChanged);
    if (!_android) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(prefKey) ?? true;
      _newsEnabled = prefs.getBool(newsPrefKey) ?? true;
      for (final k in PushKinds.all) {
        if (k != PushKinds.update) _kinds[k.id] = prefs.getBool(k.localKey) ?? k.defaultOn;
      }
    } catch (_) {}
    _channel.setMethodCallHandler(_onNative);
    _available = await _invoke<bool>('isAvailable') ?? false;
    await _invoke<void>('setEnabled', {'on': _enabled});
    await _invoke<void>('setNewsEnabled', {'on': _newsEnabled});
    for (final e in _kinds.entries) {
      await _invoke<void>('setKindEnabled', {'kind': e.key, 'on': e.value});
    }
    final launch = await _invoke<Map<dynamic, dynamic>>('takeLaunchMessage');
    if (launch != null) _emitOpened(launch);
    _notify();
    if (_api.hasToken) await register();
  }

  void _onApiChanged() {
    final has = _api.hasToken;
    if (has && !_hadToken) {
      _hadToken = true;
      _lastBearer = _api.token;
      register().ignore();
      return;
    }
    if (!has && _hadToken) {
      _hadToken = false;
      final bearer = _lastBearer;
      _lastBearer = null;
      _signedOut(bearer).ignore();
      return;
    }
    if (has) _lastBearer = _api.token; // sliding session refresh
  }

  /// Sends the current FCM token to the gateway (once per token and session).
  Future<void> register() async {
    if (!_android || !_available || !_enabled || !_api.hasToken || _registering) return;
    _registering = true;
    try {
      final token = await _invoke<String>('getToken');
      if (token == null || token.isEmpty || token == _registeredToken) return;
      await _api.post('/me/push-tokens', {
        'token': token,
        'platform': 'android',
        'appVersion': appVersionOf(MetaService.currentVersion),
      });
      _registeredToken = token;
      DiagLog.info(DiagCat.push, 'token_registered');
      // "News and updates" turned off on this phone: make sure the gateway knows (new account / reinstall).
      if (!_newsEnabled) _syncNews().ignore();
      // A kind switched away from its default on this phone: the gateway learns it too.
      if (PushKinds.all.any((k) => k != PushKinds.update && kindEnabled(k) != k.defaultOn)) _syncKinds().ignore();
      _notify();
    } catch (e) {
      debugPrint('push: register note: $e');
      DiagLog.warn(DiagCat.push, 'token_register_failed', {'type': e.runtimeType.toString(), 'status': e is ApiException ? e.statusCode : null});
    } finally {
      _registering = false;
    }
  }

  /// The app version as the gateway accepts it (letters, digits, . + _ -; up to 32).
  @visibleForTesting
  static String appVersionOf(String v) {
    final s = v.replaceAll(RegExp(r'[^A-Za-z0-9.+_\-]'), '');
    return s.length > 32 ? s.substring(0, 32) : s;
  }

  Future<void> _signedOut(String? bearer) async {
    final token = _registeredToken;
    _registeredToken = null;
    if (token != null && bearer != null) await _deleteOnGateway(bearer, token);
    // The FCM token itself is deleted too: even a missed DELETE cannot keep pushes coming
    // (the gateway prunes the dead token on its next send).
    if (_available) await _invoke<bool>('deleteToken');
    _notify();
  }

  Future<void> _deleteOnGateway(String bearer, String token) async {
    try {
      final req = http.Request('DELETE', Uri.parse('${AppConfig.apiUrl}/me/push-tokens'))
        ..headers.addAll({'Accept': 'application/json', 'Content-Type': 'application/json', 'Authorization': 'Bearer $bearer'})
        ..body = jsonEncode({'token': token});
      await _http.send(req).timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('push: unregister note: $e');
    }
  }

  /// The settings switch. On: asks for the notification permission if needed, registers.
  /// Off: removes this phone's token from the gateway and from FCM.
  Future<void> setEnabled(bool on, {Future<bool> Function()? askPermission}) async {
    if (on == _enabled) return;
    _enabled = on;
    _notify();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefKey, on);
    } catch (_) {}
    if (!_android) return;
    await _invoke<void>('setEnabled', {'on': on});
    if (on) {
      final granted = await PermissionsService.isNotificationGranted();
      if (!granted) await (askPermission ?? () => PermissionsService.request('notification'))();
      await register();
    } else {
      final token = _registeredToken;
      _registeredToken = null;
      final bearer = _api.token;
      if (token != null && bearer != null) await _deleteOnGateway(bearer, token);
      if (_available) await _invoke<bool>('deleteToken');
      _notify();
    }
  }

  /// The "News and updates" switch: saved here, on Android and on the gateway. Returns false
  /// when the gateway could not be told (the switch stays as chosen and is sent again next start).
  Future<bool> setNewsEnabled(bool on) async {
    _newsEnabled = on;
    _notify();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(newsPrefKey, on);
    } catch (_) {}
    if (_android) await _invoke<void>('setNewsEnabled', {'on': on});
    return _syncNews();
  }

  /// 3.56: one push kind's switch (events, safety tips, community, partner perks); "News and
  /// updates" goes through [setNewsEnabled]. Saved here, on Android and on the gateway.
  Future<bool> setKindEnabled(PushKind kind, bool on) async {
    if (kind == PushKinds.update) return setNewsEnabled(on);
    _kinds[kind.id] = on;
    _notify();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kind.localKey, on);
    } catch (_) {}
    if (_android) await _invoke<void>('setKindEnabled', {'kind': kind.id, 'on': on});
    if (!_api.hasToken) return false;
    try {
      await _api.put('/me/push-prefs', {kind.serverKey: on});
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _syncKinds() async {
    if (!_api.hasToken) return false;
    try {
      await _api.put('/me/push-prefs', {for (final k in PushKinds.all) if (k != PushKinds.update) k.serverKey: kindEnabled(k)});
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _syncNews() async {
    if (!_api.hasToken) return false;
    try {
      await _api.put('/me/push-prefs', {'news': _newsEnabled});
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Whether Android lets CoRoute post notifications (permission and app switch).
  Future<bool> notificationsAllowed() async => _android ? (await _invoke<bool>('notificationsEnabled') ?? false) : false;

  Future<dynamic> _onNative(MethodCall call) async {
    switch (call.method) {
      case 'onToken':
        DiagLog.info(DiagCat.push, 'token_refreshed');
        // A refreshed token: the gateway gets the new one.
        register().ignore();
        return null;
      case 'onMessage':
        final args = call.arguments;
        if (args is Map) {
          final data = <String, String>{};
          args.forEach((k, v) {
            if (k is String && v != null) data[k] = '$v';
          });
          final type = data.remove('type');
          final title = data.remove('title') ?? '';
          final body = data.remove('body') ?? '';
          DiagLog.info(DiagCat.push, 'received', {'kind': type, 'eventId': data['eventId']});
          if (type != null) _messages.add(PushMessage(type, data, title: title, body: body));
        }
        return null;
      case 'onMessageOpened':
        final args = call.arguments;
        if (args is Map) _emitOpened(args);
        return null;
    }
    return null;
  }

  void _emitOpened(Map<dynamic, dynamic> m) {
    final type = m['type'];
    if (type is! String) return;
    final msg = PushMessage(type, PushRouting.decodePayload(m['payload']));
    DiagLog.info(DiagCat.push, 'opened', {'kind': type});
    if (_opened.hasListener) {
      _opened.add(msg);
    } else {
      _pendingOpen = msg;
    }
  }

  /// Test hook: a native call as Android would send it.
  @visibleForTesting
  Future<dynamic> debugNativeCall(String method, [Object? arguments]) => _onNative(MethodCall(method, arguments));

  @override
  void dispose() {
    _disposed = true;
    _api.removeListener(_onApiChanged);
    if (_android) _channel.setMethodCallHandler(null);
    _opened.close();
    _messages.close();
    super.dispose();
  }
}
