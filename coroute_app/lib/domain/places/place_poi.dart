import 'poi_category.dart';

/// One mapped place as the phone keeps it: id, position, category and the
/// few OSM tags the gateway passes on (name, hours, phone, fuel:*, ...).
class PlacePoi {
  const PlacePoi({required this.id, required this.lat, required this.lng, required this.category, this.tags = const {}});

  final String id;
  final double lat, lng;
  final PoiCategory category;
  final Map<String, String> tags;

  String get name {
    final n = (tags['name:en'] ?? tags['name'] ?? tags['brand'] ?? '').trim();
    return n;
  }

  bool get hasName => name.isNotEmpty;
  String get displayName => hasName ? name : category.singular;

  String? get openingHours {
    final h = tags['opening_hours']?.trim();
    return h == null || h.isEmpty ? null : h;
  }

  bool get open24h {
    final h = openingHours?.replaceAll(' ', '').toLowerCase();
    return h == '24/7' || h == 'mo-su00:00-24:00' || h == '00:00-24:00';
  }

  /// First phone number, digits and + only, or null.
  String? get phone {
    final raw = tags['phone'] ?? tags['contact:phone'];
    if (raw == null) return null;
    final first = raw.split(RegExp(r'[;,/]')).first.trim();
    final cleaned = first.replaceAll(RegExp(r'[^0-9+]'), '');
    return cleaned.length >= 5 ? cleaned : null;
  }

  /// A hospital that takes emergencies (tagged, open 24 hours or a trauma centre).
  bool get isEmergencyHospital {
    if (category != PoiCategory.hospital) return false;
    if (tags['emergency'] == 'yes' || open24h) return true;
    final spec = '${tags['healthcare:speciality'] ?? ''} ${tags['name'] ?? ''}'.toLowerCase();
    return spec.contains('trauma') || spec.contains('emergency');
  }

  /// Wire form from the gateway: {i, a, o, t}. Null for anything malformed or not shown on the map.
  static PlacePoi? fromWire(Object? j) {
    if (j is! Map) return null;
    final id = j['i'], lat = j['a'], lng = j['o'], rawTags = j['t'];
    if (id is! String || id.isEmpty || lat is! num || lng is! num) return null;
    if (!lat.isFinite || !lng.isFinite || lat.abs() > 90 || lng.abs() > 180) return null;
    final tags = <String, String>{};
    if (rawTags is Map) {
      for (final e in rawTags.entries) {
        if (e.key is String && e.value is String) tags[e.key as String] = e.value as String;
      }
    }
    final category = classifyPoi(tags);
    if (category == null) return null;
    return PlacePoi(id: id, lat: lat.toDouble(), lng: lng.toDouble(), category: category, tags: tags);
  }

  Map<String, Object> toWire() => {'i': id, 'a': lat, 'o': lng, 't': tags};
}
