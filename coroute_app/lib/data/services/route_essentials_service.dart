import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/tracking/geo_math.dart';
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
  List<RouteEssential> nearbyFuelStations = [];

  List<(double, double)>? _activeRouteLine;
  double? _riderHeadingDeg;
  double? _riderLat;
  double? _riderLng;

  void setRiderTelemetry({
    List<(double, double)>? routeLine,
    double? headingDeg,
    double? lat,
    double? lng,
  }) {
    _activeRouteLine = routeLine;
    _riderHeadingDeg = headingDeg;
    _riderLat = lat;
    _riderLng = lng;
  }

  /// Returns exclusively fuel stations that lie FORWARD along the rider's route or travel path.
  /// Backward / behind stations (e.g. 7km away in opposite direction) or stations on unrelated
  /// roads are strictly excluded.
  List<RouteEssential> get onRouteFuelAhead {
    final route = _activeRouteLine;
    final allSources = <RouteEssential>[
      if (snapshot != null) ...snapshot!.places.where((p) => p.category == 'FUEL'),
      ...nearbyFuelStations.where((p) => p.category == 'FUEL'),
    ];

    final unique = <String, RouteEssential>{};
    for (final s in allSources) {
      final key = '${s.lat.toStringAsFixed(4)},${s.lng.toStringAsFixed(4)}';
      unique.putIfAbsent(key, () => s);
    }

    final out = <RouteEssential>[];
    if (route != null && route.length >= 2) {
      for (final st in unique.values) {
        final match = GeoMath.alongRoute(st.lat, st.lng, route);
        if (match == null) continue;
        // Strictly exclude stations behind the rider or lateral offset > 1200m
        if (match.along < progressM - 100 || match.offRoute > 1200) continue;

        out.add(RouteEssential(
          placeId: st.placeId,
          visitId: st.visitId,
          name: st.name,
          category: 'FUEL',
          source: st.source,
          lat: st.lat,
          lng: st.lng,
          routePositionM: match.along,
          entryM: match.along,
          exitM: match.along + match.offRoute,
          accessDistanceM: match.offRoute,
          detourDistanceM: match.offRoute * 2,
          detourDurationS: (match.offRoute * 2 / 8.33).round(),
          isCoco: st.isCoco,
          operatorName: st.operatorName,
          priority: st.priority,
        ));
      }
      out.sort((a, b) => (a.routePositionM - progressM).compareTo(b.routePositionM - progressM));
    } else {
      // Free ride with no planned route: filter using rider heading if moving
      final rLat = _riderLat ?? 0.0;
      final rLng = _riderLng ?? 0.0;
      final heading = _riderHeadingDeg;
      for (final st in unique.values) {
        if (rLat != 0 && rLng != 0 && heading != null && heading >= 0) {
          final isAhead = GeoMath.isForward(
            riderLat: rLat,
            riderLng: rLng,
            riderHeadingDeg: heading,
            targetLat: st.lat,
            targetLng: st.lng,
            maxDiffDeg: 75.0, // Strict forward cone
          );
          if (!isAhead) continue; // Skip backwards station!
        }
        final dM = (rLat != 0 && rLng != 0) ? GeoMath.haversine(rLat, rLng, st.lat, st.lng) : st.accessDistanceM;
        out.add(RouteEssential(
          placeId: st.placeId,
          visitId: st.visitId,
          name: st.name,
          category: 'FUEL',
          source: st.source,
          lat: st.lat,
          lng: st.lng,
          routePositionM: progressM + dM,
          entryM: progressM,
          exitM: progressM + dM,
          accessDistanceM: dM,
          detourDistanceM: 0,
          detourDurationS: 0,
          isCoco: st.isCoco,
          operatorName: st.operatorName,
          priority: st.priority,
        ));
      }
      out.sort((a, b) => a.accessDistanceM.compareTo(b.accessDistanceM));
    }

    return out;
  }

  List<RouteEssential> get upcoming {
    final onRoute = onRouteFuelAhead;
    if (onRoute.isNotEmpty) return onRoute;
    final list = snapshot?.places.where((p) => p.routePositionM >= progressM - 100).toList() ?? const [];
    if (list.isNotEmpty) return list;
    return nearbyFuelStations;
  }
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
      if (result == null || result.category != category || result.fromM > progressM + 5000 || result.toM < progressM - 5000 || result.fetchedAt > _clock() + 60000) throw const FormatException('Invalid essentials response');
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
  /// Fetches real nearby petrol stations from the gateway within [radiusKm] (default 25 km)
  /// around the rider's coordinates. Works with or without a calculated road route.
  Future<List<RouteEssential>> fetchNearbyFuel({
    required double lat,
    required double lng,
    double radiusKm = 25,
    bool force = false,
  }) async {
    if (_disposed || !lat.isFinite || !lng.isFinite || (lat == 0 && lng == 0)) return nearbyFuelStations;
    if (!force && nearbyFuelStations.isNotEmpty && (_clock() < _retryAt)) return nearbyFuelStations;
    loading = true;
    notifyListeners();
    try {
      final raw = await api.get(
        '/geo/nearby-fuel?lat=${lat.toStringAsFixed(4)}&lng=${lng.toStringAsFixed(4)}&radiusKm=${radiusKm.toStringAsFixed(0)}',
        timeout: const Duration(seconds: 12),
      );
      if (raw is Map && raw['results'] is List) {
        final list = <RouteEssential>[];
        for (final item in raw['results']) {
          if (item is! Map) continue;
          final pLat = (item['lat'] as num?)?.toDouble();
          final pLng = (item['lng'] as num?)?.toDouble();
          if (pLat == null || pLng == null) continue;
          final distM = (item['distanceM'] as num?)?.toDouble() ?? 0;
          list.add(RouteEssential(
            placeId: item['placeId']?.toString() ?? 'osm:$pLat,$pLng',
            visitId: item['placeId']?.toString() ?? 'osm:$pLat,$pLng',
            name: item['name']?.toString() ?? 'Petrol Pump',
            category: 'FUEL',
            source: 'OpenStreetMap',
            lat: pLat,
            lng: pLng,
            routePositionM: distM,
            entryM: 0,
            exitM: 0,
            accessDistanceM: distM,
            detourDistanceM: 0,
            detourDurationS: 0,
            isCoco: item['isCoco'] == true,
            operatorName: item['brand']?.toString(),
            priority: item['isCoco'] == true ? 1 : 2,
          ));
        }
        if (list.isNotEmpty) {
          nearbyFuelStations = list;
          _retryAt = _clock() + const Duration(minutes: 5).inMilliseconds;
        }
      }
    } catch (_) {
      // In case of error or offline, preserve existing nearby stations
    } finally {
      if (!_disposed) {
        loading = false;
        notifyListeners();
      }
    }
    return nearbyFuelStations;
  }

  @override
  void dispose() { _disposed = true; _generation++; super.dispose(); }
}
