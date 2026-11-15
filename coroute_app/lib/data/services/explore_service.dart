import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/ui/optimistic.dart';
import '../../domain/explore/destinations.dart';
import '../../domain/explore/explore_config.dart';
import '../../domain/intel/geohash.dart';
import '../../domain/intel/hazard_ahead.dart';
import 'api_client.dart';

/// Road intel near a destination for the ride detail page (anonymous, k-anonymous cells from GET /api/intel/*).
@immutable
class DestinationIntel {
  final int hazardSpots;
  final int highHazardSpots;
  final int roughSpots;

  /// Highest twistiness 0-100 seen around the place and on the way in (0 = none known).
  final int twistiness;
  final bool ghat;

  /// Popular rider stops near the place (names when the place is known).
  final List<String> stops;

  /// Pre-ride tip for the region and hour (risky times), or null.
  final String? riskyTimes;
  const DestinationIntel({
    this.hazardSpots = 0,
    this.highHazardSpots = 0,
    this.roughSpots = 0,
    this.twistiness = 0,
    this.ghat = false,
    this.stops = const [],
    this.riskyTimes,
  });

  bool get isEmpty => hazardSpots == 0 && roughSpots == 0 && twistiness == 0 && stops.isEmpty && riskyTimes == null;
}

/// v3.59: everything the Explore tab needs in one call.
@immutable
class ExploreData {
  final ExploreConfig config;
  final List<Destination> destinations;

  /// Live shared rider routes per destination id.
  final Map<String, int> routeCounts;
  const ExploreData(this.config, this.destinations, this.routeCounts);
}

/// v3.58 Explore data: the admin-curated destinations (cached on the phone for offline / instant start) and
/// the road intel around one destination.
class ExploreService {
  ExploreService(this._api);
  final ApiClient _api;

  static const String prefsKey = 'explore_destinations_v1';
  static const String cacheKey = 'explore:destinations';

  /// The last list at once: memory first, else the copy kept on the phone.
  static Future<List<Destination>?> cached() async {
    final mem = SwrCache.shared.peek<List<Destination>>(cacheKey);
    if (mem != null) return mem;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(prefsKey);
      if (raw == null) return null;
      final list = jsonDecode(raw);
      if (list is! List) return null;
      final out = [for (final d in list) ?Destination.fromJson(d)];
      SwrCache.shared.put<List<Destination>>(cacheKey, out);
      return out;
    } catch (_) {
      return null;
    }
  }

  /// GET /api/public/destinations. Throws on a network error (the screen keeps its cached list then).
  Future<List<Destination>> load() async {
    final res = await _api.get('/public/destinations');
    final raw = res is Map ? res['destinations'] : null;
    final out = [if (raw is List) for (final d in raw) ?Destination.fromJson(d)];
    SwrCache.shared.put<List<Destination>>(cacheKey, out);
    try {
      await (await SharedPreferences.getInstance()).setString(prefsKey, jsonEncode([for (final d in out) d.toJson()]));
    } catch (_) {}
    return out;
  }

  /// Full URL of a destination photo (our own gateway only), or null.
  String? photoUrl(Destination d) => d.photoUrl == null ? null : _api.apiUrlOf(d.photoUrl!.substring(4));

  /// Road intel around [d] and on the straight line from the rider ([fromLat], [fromLng]) when known.
  /// Never throws; empty intel when the rider is offline or the area has too few riders (k-anonymity).
  Future<DestinationIntel> intelFor(Destination d, {double? fromLat, double? fromLng}) async {
    final key = 'explore:intel:${d.id}';
    final hit = SwrCache.shared.peek<DestinationIntel>(key);
    if (hit != null && SwrCache.shared.isFresh(key, const Duration(minutes: 30))) return hit;
    final line = <(double, double)>[
      if (fromLat != null && fromLng != null) (fromLat, fromLng),
      (d.lat, d.lng),
    ];
    final tiles = line.length >= 2 ? Geohash.tilesAlong(line, max: 24) : [Geohash.encode(d.lat, d.lng, 4) ?? ''];
    final q = tiles.where((t) => t.isNotEmpty).join(',');
    if (q.isEmpty || !_api.hasToken) return const DestinationIntel();
    Future<List<IntelCell>> layer(String path) async {
      try {
        final r = await _api.get('/intel/$path?tiles=$q', timeout: const Duration(seconds: 12));
        final list = r is Map ? r['cells'] : null;
        return [if (list is List) for (final c in list) ?IntelCell.fromJson(c)];
      } catch (_) {
        return const [];
      }
    }

    final results = await Future.wait([layer('hazards'), layer('road-quality'), layer('twisty'), layer('stops')]);
    final hz = results[0], rq = results[1], tw = results[2], st = results[3];
    String? tip;
    try {
      final r = await _api.get('/intel/ride-tip?lat=${d.lat.toStringAsFixed(3)}&lng=${d.lng.toStringAsFixed(3)}');
      final t = r is Map ? r['tip'] : null;
      if (t is String && t.isNotEmpty) tip = t;
    } catch (_) {}
    final twist = tw.fold<int>(0, (m, c) => c.score > m ? c.score : m);
    final out = DestinationIntel(
      hazardSpots: hz.length,
      highHazardSpots: hz.where((c) => c.level == 'high').length,
      roughSpots: rq.length,
      twistiness: twist,
      ghat: tw.any((c) => c.ghat),
      stops: [for (final c in st.take(3)) c.name.isNotEmpty ? c.name : (c.fuel ? 'Fuel stop' : 'Rider stop')],
      riskyTimes: tip,
    );
    SwrCache.shared.put<DestinationIntel>(key, out);
    return out;
  }

  // ------------------------------------------------------------------ v3.59 config + rider routes
  static const String dataKey = 'explore:data';
  static const String dataPrefsKey = 'explore_data_v2';

  /// The last Explore data at once (memory, then the copy on the phone), or null.
  static Future<ExploreData?> cachedData() async {
    final mem = SwrCache.shared.peek<ExploreData>(dataKey);
    if (mem != null) return mem;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(dataPrefsKey);
      if (raw == null) return null;
      return _dataFrom(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  static ExploreData? _dataFrom(Object? j) {
    if (j is! Map) return null;
    final raw = j['destinations'], counts = j['routeCounts'];
    final out = ExploreData(
      ExploreConfig.fromJson(j['config']),
      [if (raw is List) for (final d in raw) ?Destination.fromJson(d)],
      {if (counts is Map) for (final e in counts.entries) if (e.key is String && e.value is num) e.key as String: (e.value as num).toInt()},
    );
    SwrCache.shared.put<ExploreData>(dataKey, out);
    SwrCache.shared.put<List<Destination>>(cacheKey, out.destinations);
    return out;
  }

  /// GET /api/public/explore (admin layout + destinations + route counts). An older gateway without it: the
  /// plain destination list with the built-in layout. Throws on a network error.
  Future<ExploreData> loadData() async {
    try {
      final res = await _api.get('/public/explore');
      final d = _dataFrom(res);
      if (d != null) {
        try {
          await (await SharedPreferences.getInstance()).setString(dataPrefsKey, jsonEncode(res));
        } catch (_) {}
        return d;
      }
    } on ApiException catch (e) {
      if (e.statusCode != 404) rethrow;
    }
    final list = await load();
    final out = ExploreData(ExploreConfig.fallback, list, const {});
    SwrCache.shared.put<ExploreData>(dataKey, out);
    return out;
  }

  /// Shared routes of one destination, newest first (riders only). Empty when sharing is off or offline.
  Future<List<RiderRoute>> routesFor(String destId) async {
    final key = 'explore:routes:$destId';
    try {
      final r = await _api.get('/explore/destinations/$destId/routes', timeout: const Duration(seconds: 12));
      final list = r is Map ? r['routes'] : null;
      final out = [if (list is List) for (final x in list) ?RiderRoute.fromJson(x)];
      SwrCache.shared.put<List<RiderRoute>>(key, out);
      return out;
    } catch (_) {
      return SwrCache.shared.peek<List<RiderRoute>>(key) ?? const [];
    }
  }

  static List<RiderRoute>? cachedRoutes(String destId) => SwrCache.shared.peek<List<RiderRoute>>('explore:routes:$destId');

  /// Shares a finished ride's route (the rider ticked the consent box). Returns (route, first rider to share it).
  /// Throws ApiException with the gateway's message (NOT_REACHED, TOO_SHORT, USERNAME_REQUIRED, FEATURE_OFF).
  Future<(RiderRoute?, bool)> shareRoute({
    required String destId,
    required List<(double, double)> track,
    int? durationMin,
    DateTime? endedAt,
    String note = '',
    String bike = '',
  }) async {
    final pts = RouteSharing.payload(track);
    if (pts.length < 2) throw ApiException(422, 'This ride is too short to share once the first and last kilometre are left out.', 'TOO_SHORT');
    final r = await _api.post('/explore/routes', {
      'destId': destId,
      'points': pts,
      'consent': true,
      if (durationMin != null && durationMin > 0) 'durationMin': durationMin,
      if (endedAt != null) 'rideEndedAt': endedAt.millisecondsSinceEpoch,
      if (note.trim().isNotEmpty) 'note': note.trim(),
      if (bike.trim().isNotEmpty) 'bike': bike.trim(),
    });
    SwrCache.shared.remove('explore:routes:$destId');
    return (r is Map ? RiderRoute.fromJson(r['route']) : null, r is Map && r['first'] == true);
  }

  Future<List<RiderRoute>> myRoutes() async {
    final r = await _api.get('/explore/routes/mine');
    final list = r is Map ? r['routes'] : null;
    return [if (list is List) for (final x in list) ?RiderRoute.fromJson(x)];
  }

  Future<void> deleteRoute(String id) async => _api.delete('/explore/routes/$id');

  // ------------------------------------------------------------------ v3.59 in-app admin (MASTER_ADMIN)
  Future<Map<String, dynamic>> adminConfig() async => Map<String, dynamic>.from(await _api.get('/admin/explore/config') as Map);
  Future<void> adminSaveConfig(Map<String, dynamic> cfg) async => _api.put('/admin/explore/config', cfg);
  Future<List<Map<String, dynamic>>> adminDestinations() async {
    final r = await _api.get('/admin/destinations');
    final list = r is Map ? r['destinations'] : null;
    return [if (list is List) for (final d in list) if (d is Map) Map<String, dynamic>.from(d)];
  }

  Future<void> adminPatchDestination(String id, Map<String, dynamic> fields) async => _api.patch('/admin/destinations/$id', fields);
  Future<List<Map<String, dynamic>>> adminRoutes({String status = ''}) async {
    final r = await _api.get('/admin/explore/routes${status.isEmpty ? '' : '?status=$status'}');
    final list = r is Map ? r['routes'] : null;
    return [if (list is List) for (final d in list) if (d is Map) Map<String, dynamic>.from(d)];
  }

  Future<void> adminSetRouteStatus(String id, String status) async => _api.patch('/admin/explore/routes/$id', {'status': status});
  Future<void> adminDeleteRoute(String id) async => _api.delete('/admin/explore/routes/$id');
}
