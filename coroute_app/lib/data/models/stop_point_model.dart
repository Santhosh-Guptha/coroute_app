/// One rider's visit to a stop or the destination (times in epoch ms; 0 = not yet).
class StopArrival {
  final String name;
  final int arrivedAt;
  final int leftAt;
  final int passedAt;
  const StopArrival({this.name = '', this.arrivedAt = 0, this.leftAt = 0, this.passedAt = 0});

  bool get reached => arrivedAt > 0;
  bool get passed => !reached && passedAt > 0;
  bool get isThere => reached && leftAt == 0;

  static Map<String, StopArrival> mapFrom(dynamic raw) {
    final out = <String, StopArrival>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v is Map) {
          int n(String key) => (v[key] as num?)?.toInt() ?? 0;
          out[k.toString()] = StopArrival(name: v['name']?.toString() ?? '', arrivedAt: n('arrivedAt'), leftAt: n('leftAt'), passedAt: n('passedAt'));
        }
      });
    }
    return out;
  }

  Map<String, dynamic> toJson() => {'name': name, if (arrivedAt > 0) 'arrivedAt': arrivedAt, if (leftAt > 0) 'leftAt': leftAt, if (passedAt > 0) 'passedAt': passedAt};
}

class StopPointModel {
  final String stopId;
  final String name;
  final double lat;
  final double lng;
  final bool isVisited;
  final int orderIndex;
  final String category; // 'FUEL', 'REST', 'FOOD', 'SCENIC', 'TOLL', 'OTHER'

  /// 'PLANNED' (on the route), 'SUGGESTED' (waiting for the lead) or 'SKIPPED'.
  final String status;
  final String suggestedBy;
  final String suggestedByName;
  final int plannedDwellMin;

  /// Every rider's arrival, departure or pass, by userId.
  final Map<String, StopArrival> arrivals;

  bool get isSuggested => status == 'SUGGESTED';
  bool get isSkipped => status == 'SKIPPED';
  bool get isPlanned => !isSuggested && !isSkipped;

  StopPointModel({
    required this.stopId,
    required this.name,
    required this.lat,
    required this.lng,
    this.isVisited = false,
    this.orderIndex = 0,
    this.category = 'REST',
    this.status = 'PLANNED',
    this.suggestedBy = '',
    this.suggestedByName = '',
    this.plannedDwellMin = 0,
    this.arrivals = const {},
  });

  Map<String, dynamic> toJson() => {
        'stopId': stopId,
        'name': name,
        'lat': lat,
        'lng': lng,
        'isVisited': isVisited,
        'orderIndex': orderIndex,
        'category': category,
        'status': status,
        'suggestedBy': suggestedBy,
        'suggestedByName': suggestedByName,
        'plannedDwellMin': plannedDwellMin,
        'arrivals': arrivals.map((k, v) => MapEntry(k, v.toJson())),
      };

  factory StopPointModel.fromJson(Map<String, dynamic> json) => StopPointModel(
        stopId: json['stopId'] ?? '',
        name: json['name'] ?? '',
        lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
        lng: (json['lng'] as num?)?.toDouble() ?? 0.0,
        isVisited: json['isVisited'] ?? false,
        orderIndex: (json['orderIndex'] as num?)?.toInt() ?? 0,
        category: json['category'] ?? 'REST',
        status: json['status']?.toString() ?? 'PLANNED',
        suggestedBy: json['suggestedBy']?.toString() ?? '',
        suggestedByName: json['suggestedByName']?.toString() ?? '',
        plannedDwellMin: (json['plannedDwellMin'] as num?)?.toInt() ?? 0,
        arrivals: StopArrival.mapFrom(json['arrivals']),
      );

  StopPointModel copyWith({
    String? stopId,
    String? name,
    double? lat,
    double? lng,
    bool? isVisited,
    int? orderIndex,
    String? category,
  }) {
    return StopPointModel(
      stopId: stopId ?? this.stopId,
      name: name ?? this.name,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      isVisited: isVisited ?? this.isVisited,
      orderIndex: orderIndex ?? this.orderIndex,
      category: category ?? this.category,
      status: status,
      suggestedBy: suggestedBy,
      suggestedByName: suggestedByName,
      plannedDwellMin: plannedDwellMin,
      arrivals: arrivals,
    );
  }
}
