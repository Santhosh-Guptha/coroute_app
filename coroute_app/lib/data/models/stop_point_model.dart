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
    );
  }
}
