import '../places/fuel_match.dart';

/// How the engine is cooled (3.55): sets how long it can work hard before a rest is advised.
enum EngineCooling {
  unknown,
  air,
  oil,
  liquid;

  String get label => switch (this) {
        unknown => 'Not sure',
        air => 'Air-cooled',
        oil => 'Air/oil-cooled',
        liquid => 'Liquid-cooled',
      };

  static EngineCooling parse(Object? raw) {
    for (final c in EngineCooling.values) {
      if (c.name == raw) return c;
    }
    return EngineCooling.unknown;
  }
}

/// Represents a motorcycle in the rider's personal garage.
/// Tank, reserve and mileage are in the unit of [fuelType] (L, kg or kWh).
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

  /// What the bike runs on; stations are matched to it. Default petrol.
  final BikeFuelType fuelType;

  /// 3.55 bike details: engine size (cc, 0 = not given), colour (shown to the group) and cooling.
  final int engineCc;
  final String colour;
  final EngineCooling cooling;

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
    this.fuelType = BikeFuelType.petrol,
    this.engineCc = 0,
    this.colour = '',
    this.cooling = EngineCooling.unknown,
  });

  /// The cooling as given, else a careful guess from the engine size (small engines are usually
  /// air-cooled in India); unknown without either.
  EngineCooling get effectiveCooling {
    if (cooling != EngineCooling.unknown) return cooling;
    if (engineCc <= 0) return EngineCooling.unknown;
    return engineCc < 250 ? EngineCooling.air : EngineCooling.liquid;
  }

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
    BikeFuelType? fuelType,
    int? engineCc,
    String? colour,
    EngineCooling? cooling,
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
      fuelType: fuelType ?? this.fuelType,
      engineCc: engineCc ?? this.engineCc,
      colour: colour ?? this.colour,
      cooling: cooling ?? this.cooling,
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
        'fuelType': fuelType.name,
        if (engineCc > 0) 'engineCc': engineCc,
        if (colour.isNotEmpty) 'colour': colour,
        if (cooling != EngineCooling.unknown) 'cooling': cooling.name,
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
      fuelType: BikeFuelTypeInfo.parse(json['fuelType']),
      engineCc: (json['engineCc'] as num?)?.toInt() ?? 0,
      colour: json['colour'] as String? ?? '',
      cooling: EngineCooling.parse(json['cooling']),
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
          engineCc: 452,
          cooling: EngineCooling.liquid,
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
          engineCc: 373,
          cooling: EngineCooling.liquid,
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
          engineCc: 1254,
          cooling: EngineCooling.liquid,
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
          engineCc: 648,
          cooling: EngineCooling.oil,
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
          engineCc: 888,
          cooling: EngineCooling.liquid,
        ),
        // Popular Indian bikes (3.55). Typical published figures; riders adjust to their own.
        const BikeProfile(id: 'preset_re_classic_350', name: 'Royal Enfield Classic 350', make: 'Royal Enfield', model: 'Classic 350',
            tankCapacityL: 13.0, reserveCapacityL: 2.5, expectedMileageKmL: 35.0, engineCc: 349, cooling: EngineCooling.oil),
        const BikeProfile(id: 'preset_pulsar_150', name: 'Bajaj Pulsar 150', make: 'Bajaj', model: 'Pulsar 150',
            tankCapacityL: 15.0, reserveCapacityL: 3.2, expectedMileageKmL: 45.0, engineCc: 149, cooling: EngineCooling.air),
        const BikeProfile(id: 'preset_apache_160', name: 'TVS Apache RTR 160 4V', make: 'TVS', model: 'Apache RTR 160 4V',
            tankCapacityL: 12.0, reserveCapacityL: 2.0, expectedMileageKmL: 45.0, engineCc: 160, cooling: EngineCooling.oil),
        const BikeProfile(id: 'preset_r15_v4', name: 'Yamaha R15 V4', make: 'Yamaha', model: 'R15 V4',
            tankCapacityL: 11.0, reserveCapacityL: 2.0, expectedMileageKmL: 45.0, engineCc: 155, cooling: EngineCooling.liquid),
        const BikeProfile(id: 'preset_splendor_plus', name: 'Hero Splendor Plus', make: 'Hero', model: 'Splendor Plus',
            tankCapacityL: 9.8, reserveCapacityL: 1.5, expectedMileageKmL: 65.0, engineCc: 97, cooling: EngineCooling.air),
        const BikeProfile(id: 'preset_shine_125', name: 'Honda Shine 125', make: 'Honda', model: 'Shine 125',
            tankCapacityL: 10.5, reserveCapacityL: 1.5, expectedMileageKmL: 55.0, engineCc: 124, cooling: EngineCooling.air),
      ];
}
