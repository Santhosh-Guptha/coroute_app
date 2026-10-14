import '../../domain/tracking/geo_math.dart';

/// Metadata for a locally saved offline map pack corridor.
class SavedMapPack {
  final String id;
  final String name;
  final DateTime downloadedAt;
  final bool highDetail;
  final List<int> zooms;
  final int tileCount;
  final int estimatedBytes;
  final List<(double, double)> polyline;

  const SavedMapPack({
    required this.id,
    required this.name,
    required this.downloadedAt,
    this.highDetail = false,
    this.zooms = const [12, 14],
    required this.tileCount,
    required this.estimatedBytes,
    required this.polyline,
  });

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
    );
  }
}
