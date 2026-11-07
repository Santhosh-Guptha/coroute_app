import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
import 'realtime_service.dart';

/// 3.55 admin feature switches ("kill switches").
///
/// The master admin can turn a feature off for every rider from the admin console (a feature that
/// misbehaves in the field is stopped without an app release). This service keeps the switches on
/// the phone and the UI hides the entry points of what is off. The gateway enforces the same
/// switches on its side (403 FEATURE_OFF), so hiding here is about a clean UI, not security.
///
/// Rules that keep riders safe:
///  * Anything unknown is ON: an outage, an old cache, a newer feature id or a missing answer never
///    switches a feature off. Only an explicit `false` from the gateway does.
///  * Core safety ([lockedIds]: SOS, crash detection, emergency texts, medical ID) is never gated,
///    whatever the gateway says.
///
/// Sources, newest wins (by the server's `updatedAt`): the copy saved on the phone (at start), GET
/// /features (at start, on resume, after sign-in and every 10 minutes) and the socket push
/// `FEATURE_FLAGS` (within seconds of an admin change, and on reconnect while something is off).
///
/// Separate from [FeatureGates] (core/config/feature_gates.dart, the static plan map): a switch
/// here only ever takes a feature away for everyone, temporarily.
class FeatureFlagsService extends ChangeNotifier {
  FeatureFlagsService(this._api, {RealtimeService? realtime, bool autoStart = true}) : _rt = realtime {
    instance = this;
    if (autoStart) start();
  }

  final ApiClient _api;
  final RealtimeService? _rt;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  bool _hadToken = false;
  bool _started = false;
  bool _disposed = false;

  Map<String, bool> _flags = const {};
  int _updatedAt = 0;

  static const String prefsKey = 'coroute_feature_flags_v1';
  static const Duration refreshEvery = Duration(minutes: 10);

  /// Never gated (the gateway refuses to store them off too).
  static const Set<String> lockedIds = {'sos', 'crashDetection', 'emergencySms', 'medicalId'};

  /// The live instance, for code without a BuildContext (services). Null in tests without it.
  static FeatureFlagsService? instance;

  /// Static check for services: true when no instance exists (tests, early start-up).
  static bool on(String id) => instance?.isOn(id) ?? true;

  /// Short note for a hidden / disabled entry point.
  static const String offNote = 'Turned off for now.';

  // ---- pure helpers (unit tested) ----

  /// `{id: bool}` from a JSON map; anything that is not a bool is dropped (unknown = on).
  static Map<String, bool> parseFlags(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, bool>{};
    raw.forEach((k, v) {
      if (k is String && k.isNotEmpty && k.length <= 40 && v is bool) out[k] = v;
    });
    return Map.unmodifiable(out);
  }

  /// The server's `updatedAt` as an int (0 when missing).
  static int parseUpdatedAt(Object? raw) => raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}') ?? 0;

  /// True unless [flags] says exactly `false` for [id]; locked safety ids are always true.
  static bool isOnIn(Map<String, bool> flags, String id) => lockedIds.contains(id) || flags[id] != false;

  /// Whether an incoming copy ([updatedAt]) should replace the one we have ([currentAt]). Equal
  /// times also apply (same state again is harmless) unless the incoming copy has no time at all
  /// while ours has one (an older gateway or a broken answer never overrides a dated copy).
  static bool isNewer(int updatedAt, int currentAt) => !(updatedAt == 0 && currentAt > 0) && updatedAt >= currentAt;

  // ---- state ----

  bool isOn(String id) => isOnIn(_flags, id);
  Map<String, bool> get flags => _flags;
  int get updatedAt => _updatedAt;

  /// Applies a server payload `{flags, updatedAt}` (GET /features or the socket push).
  /// Returns true when the state changed.
  bool applyPayload(Object? payload, {bool persist = true}) {
    if (payload is! Map) return false;
    final at = parseUpdatedAt(payload['updatedAt']);
    if (!isNewer(at, _updatedAt)) return false;
    final next = parseFlags(payload['flags']);
    final changed = !mapEquals(next, _flags);
    _flags = next;
    _updatedAt = at;
    if (persist) _save();
    if (changed && !_disposed) notifyListeners();
    return changed;
  }

  void start() {
    if (_started) return;
    _started = true;
    _hadToken = _api.hasToken;
    _sub = _rt?.events.listen((msg) {
      if (msg['type'] == 'FEATURE_FLAGS') applyPayload(msg);
    });
    // After sign-in (a token appears) the switches are read at once.
    _api.addListener(_onApiChanged);
    _timer = Timer.periodic(refreshEvery, (_) => refresh());
    try {
      _lifecycle = AppLifecycleListener(onResume: () => refresh());
    } catch (_) {
      // No binding (pure unit tests): resume refresh is not needed there.
    }
    _load().then((_) => refresh());
  }

  void _onApiChanged() {
    final has = _api.hasToken;
    if (has && !_hadToken) refresh();
    _hadToken = has;
  }

  /// GET /features. Errors keep the current state (an outage never switches anything off).
  Future<void> refresh() async {
    if (_disposed || !_api.hasToken) return;
    try {
      final res = await _api.get('/features');
      if (res is Map && res['ok'] != false) applyPayload(res);
    } catch (e) {
      debugPrint('Feature switches not refreshed: $e');
    }
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null || raw.isEmpty) return;
      applyPayload(jsonDecode(raw), persist: false);
    } catch (_) {
      // A broken saved copy is ignored: everything stays on.
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, jsonEncode({'flags': _flags, 'updatedAt': _updatedAt}));
    } catch (_) {
      // Best effort.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _timer?.cancel();
    _lifecycle?.dispose();
    _api.removeListener(_onApiChanged);
    if (identical(instance, this)) instance = null;
    super.dispose();
  }
}
