class RouteEssential {
  final String placeId, visitId, name, category, source;
  final double lat, lng, routePositionM, entryM, exitM, accessDistanceM, detourDistanceM;
  final int detourDurationS;
  final String? openingHours;
  final bool isCoco;
  final String? operatorName;
  final bool isTraumaCenter;
  final int priority;
  const RouteEssential({required this.placeId, required this.visitId, required this.name,
    required this.category, required this.source, required this.lat, required this.lng,
    required this.routePositionM, required this.entryM, required this.exitM,
    required this.accessDistanceM, required this.detourDistanceM, required this.detourDurationS, this.openingHours,
    this.isCoco = false, this.operatorName, this.isTraumaCenter = false, this.priority = 2});

  /// Access was routed from the entry anchor. After passing it, that road distance
  /// is no longer valid: don't subtract progress from an off-route access road.
  double? roadDistanceM(double progressM) => progressM <= entryM ? entryM - progressM + accessDistanceM : null;
  double aheadM(double progressM) => (routePositionM - progressM).clamp(0, double.infinity);
  static RouteEssential? fromJson(Map j) {
    const fields = ['lat', 'lng', 'routePositionM', 'entryM', 'exitM', 'accessDistanceM', 'detourDistanceM', 'detourDurationS'];
    if (fields.any((k) => j[k] is! num || !(j[k] as num).isFinite)) return null;
    if (fields.skip(2).any((k) => (j[k] as num) < 0) || (j['lat'] as num).abs() > 90 || (j['lng'] as num).abs() > 180) return null;
    if (['placeId', 'visitId', 'name', 'category', 'source'].any((k) => j[k] is! String || (j[k] as String).isEmpty)) return null;
    if (j['entryM'] > j['routePositionM'] || j['exitM'] < j['routePositionM']) return null;
    double n(String k) => (j[k] as num).toDouble();
    return RouteEssential(placeId: j['placeId'], visitId: j['visitId'], name: j['name'], category: j['category'], source: j['source'],
      lat: n('lat'), lng: n('lng'), routePositionM: n('routePositionM'), entryM: n('entryM'), exitM: n('exitM'),
      accessDistanceM: n('accessDistanceM'), detourDistanceM: n('detourDistanceM'), detourDurationS: n('detourDurationS').round(),
      openingHours: j['openingHours'] is String ? j['openingHours'] : null,
      isCoco: j['isCoco'] == true,
      operatorName: j['operator'] is String ? j['operator'] as String : (j['operatorName'] is String ? j['operatorName'] as String : null),
      isTraumaCenter: j['isTraumaCenter'] == true,
      priority: j['priority'] is num ? (j['priority'] as num).toInt() : 2);
  }
  Map<String, dynamic> toJson() => {'placeId': placeId, 'visitId': visitId, 'name': name, 'category': category,
    'source': source, 'lat': lat, 'lng': lng, 'routePositionM': routePositionM, 'entryM': entryM, 'exitM': exitM,
    'accessDistanceM': accessDistanceM, 'detourDistanceM': detourDistanceM, 'detourDurationS': detourDurationS, 'openingHours': openingHours,
    'isCoco': isCoco, 'operator': operatorName, 'isTraumaCenter': isTraumaCenter, 'priority': priority};
}

class EssentialsSnapshot {
  final String category, routeKey, attribution;
  final double fromM, toM;
  final int fetchedAt;
  final bool complete, stale;
  final List<RouteEssential> places;
  const EssentialsSnapshot({required this.category, required this.routeKey, required this.attribution,
    required this.fromM, required this.toM, required this.fetchedAt, required this.complete, required this.stale, required this.places});
  bool freshAt(int now) => !stale && now >= fetchedAt && now - fetchedAt < const Duration(minutes: 30).inMilliseconds;
  static EssentialsSnapshot? fromJson(Object? raw) {
    if (raw is! Map || raw['version'] != 1 || raw['places'] is! List || raw['routeKey'] is! String || raw['category'] is! String) return null;
    for (final k in ['fromM', 'toM', 'fetchedAt']) {
      if (raw[k] is! num || !(raw[k] as num).isFinite || raw[k] < 0) return null;
    }
    if (raw['toM'] < raw['fromM']) return null;
    final places = (raw['places'] as List).whereType<Map>().map(RouteEssential.fromJson).whereType<RouteEssential>().toList()
      ..sort((a, b) => a.routePositionM.compareTo(b.routePositionM));
    return EssentialsSnapshot(category: raw['category'], routeKey: raw['routeKey'], attribution: raw['attribution'] is String ? raw['attribution'] : '',
      fromM: (raw['fromM'] as num).toDouble(), toM: (raw['toM'] as num).toDouble(), fetchedAt: (raw['fetchedAt'] as num).toInt(),
      complete: raw['complete'] == true && places.length == (raw['places'] as List).length, stale: raw['stale'] == true, places: List.unmodifiable(places));
  }
  Map<String, dynamic> toJson() => {'version': 1, 'category': category, 'routeKey': routeKey, 'attribution': attribution,
    'fromM': fromM, 'toM': toM, 'fetchedAt': fetchedAt, 'complete': complete, 'stale': stale, 'places': places.map((p) => p.toJson()).toList()};
}
