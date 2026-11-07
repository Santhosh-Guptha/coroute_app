import '../safety/speed_limit_advisor.dart';

/// 3.55 smart speed limits: an element of a places cell that is not a map place but road context
/// (a road's tagged speed limit, or a school zone). Kept with the cell (memory and disk) and never
/// shown on the map. Pure.
class RoadContextItem {
  const RoadContextItem({required this.id, required this.lat, required this.lng, required this.tags});

  final String id;
  final double lat, lng;
  final Map<String, String> tags;

  /// The road limit this item carries, or null.
  RoadLimitPoint? get road => SpeedLimitAdvisor.roadFromTags(lat, lng, tags);

  /// The school zone this item marks, or null.
  SpeedZonePoint? get zone => SpeedLimitAdvisor.schoolFromTags(lat, lng, tags);

  /// Wire form {i, a, o, t}; null unless it is road context (a road limit or a school).
  static RoadContextItem? fromWire(Object? j) {
    if (j is! Map) return null;
    final id = j['i'], lat = j['a'], lng = j['o'], raw = j['t'];
    if (id is! String || id.isEmpty || lat is! num || lng is! num || raw is! Map) return null;
    if (!lat.isFinite || !lng.isFinite || lat.abs() > 90 || lng.abs() > 180) return null;
    final tags = <String, String>{};
    for (final e in raw.entries) {
      if (e.key is String && e.value is String) tags[e.key as String] = e.value as String;
    }
    final item = RoadContextItem(id: id, lat: lat.toDouble(), lng: lng.toDouble(), tags: tags);
    return item.road != null || item.zone != null ? item : null;
  }

  Map<String, Object> toWire() => {'i': id, 'a': lat, 'o': lng, 't': tags};
}
