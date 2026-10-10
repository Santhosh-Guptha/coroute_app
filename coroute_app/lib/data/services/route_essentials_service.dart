import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/route_model.dart';
import '../models/route_essential.dart';
import 'api_client.dart';

typedef EssentialsLoad = Future<String?> Function();
typedef EssentialsSave = Future<void> Function(String value);

/// One bounded route window. Failed refreshes preserve the last successful
/// snapshot, with its original timestamp. No timer and no calls per GPS fix.
class RouteEssentialsService extends ChangeNotifier {
  RouteEssentialsService(this.api, {EssentialsLoad? load, EssentialsSave? save, int Function()? clock})
      : _load = load ?? _read, _save = save ?? _write, _clock = clock ?? _now;
  final ApiClient api;
  final EssentialsLoad _load;
  final EssentialsSave _save;
  final int Function() _clock;
  static int _now() => DateTime.now().millisecondsSinceEpoch;
  static Future<String?> _read() async => (await SharedPreferences.getInstance()).getString('essentials_cache_v1');
  static Future<void> _diskWrites = Future.value();
  static Future<void> _write(String value) {
    final write = _diskWrites.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final merged = <String, EssentialsSnapshot>{};
      for (final raw in [prefs.getString('essentials_cache_v1'), value]) {
        try {
          final decoded = raw == null ? null : jsonDecode(raw);
          if (decoded is Map) {
            for (final entry in decoded.entries) {
              final item = EssentialsSnapshot.fromJson(entry.value);
              if (item != null && item.fetchedAt >= (merged[entry.key]?.fetchedAt ?? 0)) merged[entry.key.toString()] = item;
            }
          }
        } catch (_) { /* An invalid older cache does not prevent saving live data. */ }
      }
      final entries = merged.entries.toList()..sort((a, b) => b.value.fetchedAt.compareTo(a.value.fetchedAt));
      final encoded = jsonEncode({for (final entry in entries.take(18)) entry.key: entry.value.toJson()});
      if (!await prefs.setString('essentials_cache_v1', encoded)) throw StateError('Cache write failed');
    });
    _diskWrites = write.catchError((Object _) {});
    return write;
  }
  String? _key;
  int _generation = 0, _retryAt = 0, _failures = 0;
  bool _disposed = false, _authBlocked = false;
  String? _blockedToken;
  bool loading = false, offline = false, cacheSaveFailed = false;
  String? error;
  EssentialsSnapshot? snapshot;
  final Map<String, EssentialsSnapshot> _cache = {};
  Future<void>? _restore;
  Future<void> _writes = Future.value();
  double progressM = 0;
  String category = 'FUEL';
  String? groupId;
  List<RouteEssential> get upcoming => snapshot?.places.where((p) => p.routePositionM >= progressM).toList() ?? const [];
  bool get reliable => !offline && error == null && snapshot?.complete == true && snapshot!.freshAt(_clock());

  Future<void> _restoreCache() async {
    try {
      final raw = await _load();
      final j = raw == null ? null : jsonDecode(raw);
      if (j is Map) {
        for (final e in j.entries.take(18)) {
          final s = EssentialsSnapshot.fromJson(e.value);
          if (s != null && _clock() >= s.fetchedAt && _clock() - s.fetchedAt < const Duration(days: 7).inMilliseconds) _cache[e.key.toString()] = s;
        }
      }
    } catch (_) { /* Corrupt or unavailable storage must not prevent live results. */ }
  }

  Future<void> update(RouteModel? route, {required double fromM, required bool online,
      bool lowData = false, String selectedCategory = 'FUEL', bool force = false}) async {
    if (_disposed) return;
    progressM = fromM.isFinite && fromM >= 0 ? fromM : 0;
    offline = !online;
    category = selectedCategory;
    if (route == null || route.approximate || route.points.length < 2) {
      _generation++; _key = null; snapshot = null; loading = false;
      error = 'A calculated road route is needed.'; notifyListeners(); return;
    }
    // Store the exact geometry in the key: no hash collision can resurrect another route.
    final key = '${route.polyline}|$category|${progressM ~/ 5000}';
    if (_key != key) {
      _key = key; _generation++; loading = false; snapshot = null; error = null; _retryAt = 0; _failures = 0;
    }
    final generation = _generation;
    await (_restore ??= _restoreCache());
    if (_disposed || generation != _generation) return;
    snapshot ??= _cache[key];
    if (snapshot == null && !online) {
      final prefix = '${route.polyline}|$category|';
      for (final entry in _cache.entries.toList().reversed) {
        if (entry.key.startsWith(prefix) && entry.value.toM >= progressM) {
          snapshot = entry.value;
          break;
        }
      }
    }
    if (snapshot != null && (_clock() < snapshot!.fetchedAt || _clock() - snapshot!.fetchedAt >= const Duration(days: 7).inMilliseconds)) {
      snapshot = null; _cache.remove(key);
    }
    if (!online || (lowData && !force)) { notifyListeners(); return; }
    if (_authBlocked && _blockedToken != api.token) _authBlocked = false;
    if (_authBlocked) { error = 'Sign in again to refresh route essentials.'; notifyListeners(); return; }
    if (loading || (!force && (snapshot?.freshAt(_clock()) == true || _clock() < _retryAt))) { notifyListeners(); return; }
    loading = true; error = null; notifyListeners();
    try {
      final raw = await api.post('/geo/essentials', {if (groupId != null) 'groupId': groupId, 'polyline': route.polyline, 'category': category, 'fromM': progressM}, const Duration(seconds: 55));
      if (_disposed || generation != _generation) return;
      final result = EssentialsSnapshot.fromJson(raw);
      if (result == null || result.category != category || result.fromM > progressM || result.toM < progressM || result.fetchedAt > _clock() + 60000) throw const FormatException('Invalid essentials response');
      snapshot = result; _failures = 0;
      // Stale server fallback is usable offline, but must not cause immediate refresh loops.
      _retryAt = _clock() + const Duration(minutes: 2).inMilliseconds;
      _cache.remove(key); _cache[key] = result;
      while (_cache.length > 18) { _cache.remove(_cache.keys.first); }
      final encoded = jsonEncode(_cache.map((k, v) => MapEntry(k, v.toJson())));
      _writes = _writes.then((_) async {
        try { await _save(encoded); cacheSaveFailed = false; } catch (_) { cacheSaveFailed = true; }
      });
      await _writes;
    } catch (e) {
      if (_disposed || generation != _generation) return;
      if (e is ApiException && e.isOffline) offline = true;
      if (e is ApiException && (e.statusCode == 401 || (e.statusCode == 403 && e.code != 'FEATURE_DISABLED'))) { _authBlocked = true; _blockedToken = api.token; }
      error = 'Could not refresh route essentials.';
      _failures = (_failures + 1).clamp(1, 5);
      _retryAt = _clock() + 30000 * (1 << _failures);
    } finally {
      if (!_disposed && generation == _generation) { loading = false; notifyListeners(); }
    }
  }
  @override
  void dispose() { _disposed = true; _generation++; super.dispose(); }
}
