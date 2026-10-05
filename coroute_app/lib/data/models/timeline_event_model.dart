/// One entry of the shared group timeline (gateway collection trip_events).
class TimelineEventModel {
  final String eventId;
  final String groupId;
  final String? userId;
  final String userName;
  final String type;
  final int startedAt;
  final int? endedAt;
  final int durationMs;
  final double? lat;
  final double? lng;
  final String placeName;
  final Map<String, dynamic> data;
  final String confidence; // 'live' | 'confirmed'
  final bool open;
  final int updatedAt;

  const TimelineEventModel({
    required this.eventId,
    required this.groupId,
    this.userId,
    this.userName = '',
    required this.type,
    required this.startedAt,
    this.endedAt,
    this.durationMs = 0,
    this.lat,
    this.lng,
    this.placeName = '',
    this.data = const {},
    this.confidence = 'live',
    this.open = false,
    this.updatedAt = 0,
  });

  bool get isGroupEntry => userId == null || userId!.isEmpty;
  bool get hasPlace => lat != null && lng != null;

  /// Duration so far for an open entry, final duration otherwise.
  Duration durationAt(int nowMs) => Duration(milliseconds: open ? (nowMs - startedAt).clamp(0, 1 << 52).toInt() : durationMs);

  String dataString(String key) => data[key]?.toString() ?? '';
  num? dataNum(String key) => data[key] is num ? data[key] as num : null;

  factory TimelineEventModel.fromJson(Map<String, dynamic> j) {
    double? d(dynamic v) => v is num ? v.toDouble() : null;
    final rawData = j['data'];
    return TimelineEventModel(
      eventId: j['eventId']?.toString() ?? '',
      groupId: j['groupId']?.toString() ?? '',
      userId: (j['userId'] == null || j['userId'].toString().isEmpty) ? null : j['userId'].toString(),
      userName: j['userName']?.toString() ?? '',
      type: j['type']?.toString() ?? '',
      startedAt: (j['startedAt'] as num?)?.toInt() ?? 0,
      endedAt: (j['endedAt'] as num?)?.toInt(),
      durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
      lat: d(j['lat']),
      lng: d(j['lng']),
      placeName: j['placeName']?.toString() ?? '',
      data: rawData is Map ? Map<String, dynamic>.from(rawData) : const {},
      confidence: j['confidence']?.toString() ?? 'live',
      open: j['open'] == true,
      updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }
}
