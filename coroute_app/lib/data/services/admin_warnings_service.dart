import 'dart:async';
import 'package:flutter/widgets.dart';
import 'api_client.dart';
import 'feature_flags_service.dart';
import 'realtime_service.dart';

/// One moderator warning for this rider (plain text from the gateway).
@immutable
class AdminWarning {
  final String id;
  final String message;
  final int at;
  const AdminWarning({required this.id, required this.message, required this.at});

  /// Longest text shown (the gateway caps at 280 already).
  static const int maxLength = 280;
  static final RegExp _id = RegExp(r'^AW-[0-9A-F]{12}$');

  /// From a gateway map; null when the id or text is missing or malformed.
  static AdminWarning? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString() ?? '';
    if (!_id.hasMatch(id)) return null;
    var text = (raw['message']?.toString() ?? '').replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return null;
    if (text.length > maxLength) text = '${text.substring(0, maxLength - 1)}…';
    final at = raw['at'];
    return AdminWarning(id: id, message: text, at: at is num ? at.toInt() : 0);
  }
}

/// 3.55 platform: moderator warnings ("Warn" on a public-ride report) shown to the rider on Home.
///
/// Sources: GET /me/warnings (at start, after sign-in and on resume) and the socket push
/// `ADMIN_WARNING` (at once while connected). The rider acknowledges with POST
/// /me/warnings/:id/ack; "dismiss" only hides it until the next app start. Admin switch
/// `adminWarnings` (off: nothing is shown). Never shown during a ride (Home only shows with no ride).
class AdminWarningsService extends ChangeNotifier {
  AdminWarningsService(this._api, {RealtimeService? realtime, bool autoStart = true}) : _rt = realtime {
    if (autoStart) start();
  }

  final ApiClient _api;
  final RealtimeService? _rt;
  StreamSubscription<Map<String, dynamic>>? _sub;
  AppLifecycleListener? _lifecycle;
  bool _hadToken = false;
  bool _started = false;
  bool _disposed = false;

  final List<AdminWarning> _pending = [];
  final Set<String> _hidden = {};

  static const String flagId = 'adminWarnings';

  /// The oldest warning not acknowledged or hidden, or null (also while the switch is off).
  AdminWarning? get current {
    if (!FeatureFlagsService.on(flagId)) return null;
    for (final w in _pending) {
      if (!_hidden.contains(w.id)) return w;
    }
    return null;
  }

  List<AdminWarning> get pending => List.unmodifiable(_pending);

  /// Adds a warning (socket push or list); duplicates by id are ignored. True when added.
  bool add(AdminWarning w) {
    if (_pending.any((x) => x.id == w.id)) return false;
    _pending.add(w);
    if (!_disposed) notifyListeners();
    return true;
  }

  /// Replaces the list with the gateway's (what was acknowledged elsewhere disappears).
  void replaceAll(Iterable<AdminWarning> list) {
    _pending
      ..clear()
      ..addAll(list);
    if (!_disposed) notifyListeners();
  }

  void start() {
    if (_started) return;
    _started = true;
    _hadToken = _api.hasToken;
    _sub = _rt?.events.listen((msg) {
      if (msg['type'] != 'ADMIN_WARNING') return;
      final w = AdminWarning.fromJson(msg);
      if (w != null) add(w);
    });
    _api.addListener(_onApiChanged);
    try {
      _lifecycle = AppLifecycleListener(onResume: () => refresh());
    } catch (_) {
      // No binding (pure unit tests).
    }
    refresh();
  }

  void _onApiChanged() {
    final has = _api.hasToken;
    if (has && !_hadToken) refresh();
    if (!has && _hadToken) replaceAll(const []);
    _hadToken = has;
  }

  /// GET /me/warnings. Errors keep what we have (an older gateway answers 404: nothing to show).
  Future<void> refresh() async {
    if (_disposed || !_api.hasToken || !FeatureFlagsService.on(flagId)) return;
    try {
      final res = await _api.get('/me/warnings');
      final raw = res is Map ? res['warnings'] : null;
      if (raw is List) replaceAll(raw.map(AdminWarning.fromJson).whereType<AdminWarning>());
    } catch (e) {
      debugPrint('Moderator warnings not refreshed: $e');
    }
  }

  /// Hides [id] until the next app start (the close button).
  void hide(String id) {
    if (_hidden.add(id) && !_disposed) notifyListeners();
  }

  /// "Acknowledge": removed at once on the phone, then POST /me/warnings/:id/ack. A failed call
  /// leaves it hidden for this session; the next start shows it again from the gateway.
  Future<void> acknowledge(String id) async {
    _hidden.add(id);
    _pending.removeWhere((w) => w.id == id);
    if (!_disposed) notifyListeners();
    try {
      await _api.post('/me/warnings/${Uri.encodeComponent(id)}/ack');
    } catch (e) {
      debugPrint('Moderator warning not acknowledged: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _lifecycle?.dispose();
    _api.removeListener(_onApiChanged);
    super.dispose();
  }
}
