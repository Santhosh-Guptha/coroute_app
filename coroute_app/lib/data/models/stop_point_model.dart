class StopPointModel {
  final String stopId;
  final String name;
  final double lat;
  final double lng;
  final bool isVisited;
  final int orderIndex;
  final String category; // 'FUEL', 'REST', 'FOOD', 'SCENIC', 'TOLL'

  StopPointModel({
    required this.stopId,
    required this.name,
    required this.lat,
    required this.lng,
    this.isVisited = false,
    this.orderIndex = 0,
    this.category = 'REST',
  });

  Map<String, dynamic> toJson() => {
        'stopId': stopId,
        'name': name,
        'lat': lat,
        'lng': lng,
        'isVisited': isVisited,
        'orderIndex': orderIndex,
        'category': category,
      };

  factory StopPointModel.fromJson(Map<String, dynamic> json) => StopPointModel(
        stopId: json['stopId'] ?? '',
        name: json['name'] ?? '',
        lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
        lng: (json['lng'] as num?)?.toDouble() ?? 0.0,
        isVisited: json['isVisited'] ?? false,
        orderIndex: (json['orderIndex'] as num?)?.toInt() ?? 0,
        category: json['category'] ?? 'REST',
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
    );
  }
}
