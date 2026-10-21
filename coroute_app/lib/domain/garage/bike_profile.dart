/// Represents a motorcycle in the rider's personal garage.
class BikeProfile {
  final String id;
  final String name;
  final String make;
  final String model;
  final int year;
  final double tankCapacityL;
  final double reserveCapacityL;
  final double expectedMileageKmL;
  final double totalOdometerKm;
  final double serviceIntervalKm;
  final double lastServiceOdometerKm;
  final String notes;
  final bool isDefault;

  const BikeProfile({
    required this.id,
    required this.name,
    this.make = '',
    this.model = '',
    this.year = 2024,
    this.tankCapacityL = 15.0,
    this.reserveCapacityL = 3.0,
    this.expectedMileageKmL = 25.0,
    this.totalOdometerKm = 0.0,
    this.serviceIntervalKm = 5000.0,
    this.lastServiceOdometerKm = 0.0,
    this.notes = '',
    this.isDefault = false,
  });

  /// Theoretical maximum range on a full tank in kilometers.
  double get fullTankRangeKm => tankCapacityL * expectedMileageKmL;

  /// Safety reserve range in kilometers.
  double get reserveRangeKm => reserveCapacityL * expectedMileageKmL;

  /// Next scheduled service odometer mark in kilometers.
  double get nextServiceOdometerKm => lastServiceOdometerKm + serviceIntervalKm;

  /// Distance remaining until the next service is due.
  double get kmUntilService => nextServiceOdometerKm - totalOdometerKm;

  /// True if scheduled service is within 500 km.
  bool get isServiceDueSoon => kmUntilService <= 500 && kmUntilService > 0;

  /// True if scheduled service interval has been exceeded.
  bool get isServiceOverdue => kmUntilService <= 0;

  BikeProfile copyWith({
    String? id,
    String? name,
    String? make,
    String? model,
    int? year,
    double? tankCapacityL,
    double? reserveCapacityL,
    double? expectedMileageKmL,
    double? totalOdometerKm,
    double? serviceIntervalKm,
    double? lastServiceOdometerKm,
    String? notes,
    bool? isDefault,
  }) {
    return BikeProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      make: make ?? this.make,
      model: model ?? this.model,
      year: year ?? this.year,
      tankCapacityL: tankCapacityL ?? this.tankCapacityL,
      reserveCapacityL: reserveCapacityL ?? this.reserveCapacityL,
      expectedMileageKmL: expectedMileageKmL ?? this.expectedMileageKmL,
      totalOdometerKm: totalOdometerKm ?? this.totalOdometerKm,
      serviceIntervalKm: serviceIntervalKm ?? this.serviceIntervalKm,
      lastServiceOdometerKm: lastServiceOdometerKm ?? this.lastServiceOdometerKm,
      notes: notes ?? this.notes,
      isDefault: isDefault ?? this.isDefault,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'make': make,
        'model': model,
        'year': year,
        'tankCapacityL': tankCapacityL,
        'reserveCapacityL': reserveCapacityL,
        'expectedMileageKmL': expectedMileageKmL,
        'totalOdometerKm': totalOdometerKm,
        'serviceIntervalKm': serviceIntervalKm,
        'lastServiceOdometerKm': lastServiceOdometerKm,
        'notes': notes,
        'isDefault': isDefault,
      };

  factory BikeProfile.fromJson(Map<String, dynamic> json) {
    return BikeProfile(
      id: json['id'] as String? ?? 'default',
      name: json['name'] as String? ?? 'My Bike',
      make: json['make'] as String? ?? '',
      model: json['model'] as String? ?? '',
      year: (json['year'] as num?)?.toInt() ?? 2024,
      tankCapacityL: (json['tankCapacityL'] as num?)?.toDouble() ?? 15.0,
      reserveCapacityL: (json['reserveCapacityL'] as num?)?.toDouble() ?? 3.0,
      expectedMileageKmL:
          (json['expectedMileageKmL'] as num?)?.toDouble() ?? 25.0,
      totalOdometerKm: (json['totalOdometerKm'] as num?)?.toDouble() ?? 0.0,
      serviceIntervalKm:
          (json['serviceIntervalKm'] as num?)?.toDouble() ?? 5000.0,
      lastServiceOdometerKm:
          (json['lastServiceOdometerKm'] as num?)?.toDouble() ?? 0.0,
      notes: json['notes'] as String? ?? '',
      isDefault: json['isDefault'] as bool? ?? false,
    );
  }

  /// Preset definitions for popular touring and adventure motorcycles.
  static List<BikeProfile> get popularPresets => [
        const BikeProfile(
          id: 'preset_himalayan_450',
          name: 'Royal Enfield Himalayan 450',
          make: 'Royal Enfield',
          model: 'Himalayan 450',
          year: 2024,
          tankCapacityL: 17.0,
          reserveCapacityL: 3.5,
          expectedMileageKmL: 28.0,
          serviceIntervalKm: 5000.0,
        ),
        const BikeProfile(
          id: 'preset_ktm_390_adv',
          name: 'KTM 390 Adventure',
          make: 'KTM',
          model: '390 Adventure',
          year: 2024,
          tankCapacityL: 14.5,
          reserveCapacityL: 2.8,
          expectedMileageKmL: 27.0,
          serviceIntervalKm: 7500.0,
        ),
        const BikeProfile(
          id: 'preset_bmw_gs_1250',
          name: 'BMW R1250 GS Adventure',
          make: 'BMW',
          model: 'R1250 GS Adv',
          year: 2023,
          tankCapacityL: 30.0,
          reserveCapacityL: 4.0,
          expectedMileageKmL: 20.0,
          serviceIntervalKm: 10000.0,
        ),
        const BikeProfile(
          id: 'preset_re_interceptor_650',
          name: 'Royal Enfield Interceptor 650',
          make: 'Royal Enfield',
          model: 'Interceptor 650',
          year: 2024,
          tankCapacityL: 13.7,
          reserveCapacityL: 2.5,
          expectedMileageKmL: 24.0,
          serviceIntervalKm: 5000.0,
        ),
        const BikeProfile(
          id: 'preset_triumph_tiger_900',
          name: 'Triumph Tiger 900 Rally Pro',
          make: 'Triumph',
          model: 'Tiger 900',
          year: 2024,
          tankCapacityL: 20.0,
          reserveCapacityL: 3.5,
          expectedMileageKmL: 22.0,
          serviceIntervalKm: 10000.0,
        ),
      ];
}
