import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/ui/optimistic.dart';
import '../../domain/explore/destinations.dart';
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
}
