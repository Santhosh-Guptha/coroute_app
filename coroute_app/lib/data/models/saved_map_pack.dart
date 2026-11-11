import '../../domain/geo/offline_map_retention.dart';
import '../../domain/tracking/geo_math.dart';

/// Metadata for a locally saved offline map pack corridor. Since Nov 11 every pack is an automatic
/// trip map: [tripId] ties it to the ride, [completedAt] is set when that ride ends, and
/// [OfflineMapRetention] decides when it is deleted (7 days after the trip, 300 MB cap).
class SavedMapPack {
  final String id;
  final String name;
  final DateTime downloadedAt;
  final bool highDetail;
  final List<int> zooms;
  final int tileCount;
  final int estimatedBytes;
  final List<(double, double)> polyline;

  /// The ride (group id) the map was saved for; null for packs from before Nov 11.
  final String? tripId;

  /// When that ride ended; null while it has not.
  final DateTime? completedAt;

  /// Last time the map was saved again for a ride; [downloadedAt] when unknown.
  final DateTime? lastUsedAt;

  const SavedMapPack({
    required this.id,
    required this.name,
    required this.downloadedAt,
    this.highDetail = false,
    this.zooms = const [12, 14],
    required this.tileCount,
    required this.estimatedBytes,
    required this.polyline,
    this.tripId,
    this.completedAt,
    this.lastUsedAt,
  });

  /// The id automatic trip maps use for [groupId].
  static String idForTrip(String groupId) => 'trip_$groupId';

  SavedMapPack copyWith({DateTime? completedAt, DateTime? lastUsedAt}) => SavedMapPack(
        id: id,
        name: name,
        downloadedAt: downloadedAt,
        highDetail: highDetail,
        zooms: zooms,
        tileCount: tileCount,
        estimatedBytes: estimatedBytes,
        polyline: polyline,
        tripId: tripId,
        completedAt: completedAt ?? this.completedAt,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      );

  /// What the retention rules need. A pack from before Nov 11 (no trip id) counts as an ended
  /// trip from the time it was saved, so it goes 7 days after it was downloaded.
  RetainedMap get retained => RetainedMap(
        id: id,
        createdAtMs: downloadedAt.millisecondsSinceEpoch,
        completedAtMs: completedAt?.millisecondsSinceEpoch ?? (tripId == null ? downloadedAt.millisecondsSinceEpoch : null),
        lastUsedAtMs: (lastUsedAt ?? downloadedAt).millisecondsSinceEpoch,
        bytes: estimatedBytes,
      );

  /// Formatted size in MB.
  String get sizeMb => (estimatedBytes / (1024 * 1024)).toStringAsFixed(1);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'downloaded_at': downloadedAt.toIso8601String(),
        'high_detail': highDetail,
        'zooms': zooms,
        'tile_count': tileCount,
        'estimated_bytes': estimatedBytes,
        'polyline': GeoMath.encodePolyline(polyline),
        if (tripId != null) 'trip_id': tripId,
        if (completedAt != null) 'completed_at': completedAt!.toIso8601String(),
        if (lastUsedAt != null) 'last_used_at': lastUsedAt!.toIso8601String(),
      };
  factory SavedMapPack.fromJson(Map<String, dynamic> map) {
    final polyStr = map['polyline'] as String? ?? '';
    final poly = (polyStr.isNotEmpty ? GeoMath.decodePolyline(polyStr) : null) ?? const <(double, double)>[];
    return SavedMapPack(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? 'Corridor Pack',
      downloadedAt: DateTime.tryParse(map['downloaded_at'] as String? ?? '') ?? DateTime.now(),
      highDetail: map['high_detail'] as bool? ?? false,
      zooms: (map['zooms'] as List<dynamic>?)?.map((e) => (e as num).toInt()).toList() ?? const [12, 14],
      tileCount: (map['tile_count'] as num?)?.toInt() ?? 0,
      estimatedBytes: (map['estimated_bytes'] as num?)?.toInt() ?? 0,
      polyline: poly,
      tripId: map['trip_id'] as String?,
      completedAt: DateTime.tryParse(map['completed_at'] as String? ?? ''),
      lastUsedAt: DateTime.tryParse(map['last_used_at'] as String? ?? ''),
    );
  }
}
