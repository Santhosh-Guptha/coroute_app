import '../../data/models/route_essential.dart';

/// Capabilities and attributes of a roadside puncture repair facility.
class PunctureRepairFacility {
  final String placeId;
  final String name;
  final double lat;
  final double lng;
  final double routePositionM;
  final double accessDistanceM;
  final double detourDistanceM;
  final int detourDurationS;
  final bool isTubelessRepair;
  final bool isTubeVulcanizing;
  final bool is24Hours;
  final String? openingHours;
  final String? contactPhone;

  const PunctureRepairFacility({
    required this.placeId,
    required this.name,
    required this.lat,
    required this.lng,
    required this.routePositionM,
    required this.accessDistanceM,
    required this.detourDistanceM,
    required this.detourDurationS,
    this.isTubelessRepair = true,
    this.isTubeVulcanizing = false,
    this.is24Hours = false,
    this.openingHours,
    this.contactPhone,
  });

  /// Road distance from current rider progress along route.
  double? roadDistanceM(double progressM) =>
      progressM <= routePositionM
          ? (routePositionM - progressM) + accessDistanceM
          : null;
}

/// Helper for tagging and route corridor discovery of roadside puncture repair shops.
class PunctureDiscovery {
  static const Set<String> punctureKeywords = {
    'puncture',
    'punctures',
    'tyre',
    'tyres',
    'tire',
    'tires',
    'vulcanizing',
    'vulcanise',
    'vulcanize',
    'tubeless',
    'wheel care',
    'flat tyre',
    'air pump',
  };

  /// Determines whether a mapped RouteEssential is a puncture repair facility.
  static bool isPunctureFacility(RouteEssential place, {Map<String, dynamic>? tags}) {
    if (place.category == 'TYRE' || place.category == 'PUNCTURE') return true;

    final nameLower = place.name.toLowerCase();
    for (final kw in punctureKeywords) {
      if (nameLower.contains(kw)) return true;
    }

    if (tags != null) {
      final shop = (tags['shop'] as String? ?? '').toLowerCase();
      final service = (tags['service:vehicle:tyres'] as String? ?? '').toLowerCase();
      final puncture = (tags['puncture_repair'] as String? ?? '').toLowerCase();
      final craft = (tags['craft'] as String? ?? '').toLowerCase();

      if (shop == 'tyres' ||
          shop == 'tyre' ||
          craft == 'tyre_repair' ||
          service.contains('puncture') ||
          puncture == 'yes' ||
          tags['service:tyres:puncture'] == 'yes') {
        return true;
      }
    }

    return false;
  }

  /// Discovers and ranks upcoming puncture repair shops along route corridor.
  static List<PunctureRepairFacility> discoverPunctureShops({
    required Iterable<RouteEssential> places,
    required double riderProgressM,
    bool require24x7 = false,
    bool tubelessOnly = false,
    Map<String, Map<String, dynamic>>? tagMap,
  }) {
    final results = <PunctureRepairFacility>[];

    for (final place in places) {
      final tags = tagMap?[place.placeId];
      if (!isPunctureFacility(place, tags: tags)) continue;

      // Filter already passed entries
      if (place.routePositionM < riderProgressM) continue;

      final nameLower = place.name.toLowerCase();
      final hours = place.openingHours ?? (tags?['opening_hours'] as String?);
      final is24x7 = (hours != null && hours.contains('24/7')) ||
          nameLower.contains('24/7') ||
          tags?['service:24_7'] == 'yes';

      if (require24x7 && !is24x7) continue;

      final isTube = nameLower.contains('vulcaniz') ||
          tags?['service:tyres:vulcanizing'] == 'yes';
      final isTubeless = !nameLower.contains('tube only') ||
          tags?['service:tyres:tubeless'] == 'yes';

      if (tubelessOnly && !isTubeless) continue;

      results.add(PunctureRepairFacility(
        placeId: place.placeId,
        name: place.name,
        lat: place.lat,
        lng: place.lng,
        routePositionM: place.routePositionM,
        accessDistanceM: place.accessDistanceM,
        detourDistanceM: place.detourDistanceM,
        detourDurationS: place.detourDurationS,
        isTubelessRepair: isTubeless,
        isTubeVulcanizing: isTube,
        is24Hours: is24x7,
        openingHours: hours,
        contactPhone: tags?['phone'] as String?,
      ));
    }

    // Sort by road distance from the rider's current progress
    results.sort((a, b) {
      final distA = a.roadDistanceM(riderProgressM) ?? double.infinity;
      final distB = b.roadDistanceM(riderProgressM) ?? double.infinity;
      return distA.compareTo(distB);
    });

    return results;
  }
}

/// Facility level for emergency trauma response.
enum TraumaFacilityLevel {
  level1, // Tertiary / Medical College with 24/7 neurosurgery, cardio & full surgical team
  level2, // District / Regional trauma center with general surgery and ICU
  level3, // Community / Stabilization hospital with emergency resuscitation
  general, // Routine hospital or nursing home without designated trauma ward
}

/// A mapped trauma care facility along the route corridor.
class TraumaCenterFacility {
  final String placeId;
  final String name;
  final double lat;
  final double lng;
  final double routePositionM;
  final double accessDistanceM;
  final double detourDistanceM;
  final int detourDurationS;
  final TraumaFacilityLevel traumaLevel;
  final bool has24x7Emergency;
  final bool hasIcu;
  final bool hasBloodBank;
  final String? emergencyPhone;

  const TraumaCenterFacility({
    required this.placeId,
    required this.name,
    required this.lat,
    required this.lng,
    required this.routePositionM,
    required this.accessDistanceM,
    required this.detourDistanceM,
    required this.detourDurationS,
    required this.traumaLevel,
    this.has24x7Emergency = true,
    this.hasIcu = false,
    this.hasBloodBank = false,
    this.emergencyPhone,
  });

  /// Road distance from accident site along route.
  double roadDistanceM(double incidentRoutePositionM) =>
      (routePositionM >= incidentRoutePositionM
          ? routePositionM - incidentRoutePositionM
          : incidentRoutePositionM - routePositionM) +
      accessDistanceM;

  /// Estimated arrival time in minutes from incident site based on detour duration and speed.
  int estimatedMinutes(double incidentRoutePositionM, {double averageSpeedKmh = 60.0}) {
    final highwayDistanceM = (routePositionM - incidentRoutePositionM).abs();
    final highwaySeconds = (highwayDistanceM / (averageSpeedKmh * 1000 / 3600)).round();
    final totalSeconds = highwaySeconds + detourDurationS;
    return (totalSeconds / 60).ceil();
  }
}

/// Helper for tagging, triage ranking, and route discovery of trauma centers.
class TraumaDiscovery {
  static const Set<String> tertiaryKeywords = {
    'aiims',
    'medical college',
    'super speciality',
    'superspeciality',
    'tertiary',
    'level 1 trauma',
    'level-1 trauma',
    'trauma institute',
    'apollo',
    'manipal',
    'fortis',
  };

  static const Set<String> districtKeywords = {
    'district hospital',
    'civil hospital',
    'general hospital',
    'government hospital',
    'regional hospital',
    'trauma care',
    'trauma centre',
    'trauma center',
    'emergency hospital',
  };

  /// Determines whether a mapped RouteEssential is a hospital or medical facility.
  static bool isTraumaFacility(RouteEssential place, {Map<String, dynamic>? tags}) {
    if (place.category == 'HOSPITAL' || place.category == 'TRAUMA') return true;

    final nameLower = place.name.toLowerCase();
    if (nameLower.contains('hospital') ||
        nameLower.contains('trauma') ||
        nameLower.contains('medical centre') ||
        nameLower.contains('medical center') ||
        nameLower.contains('emergency clinic')) {
      return true;
    }

    if (tags != null) {
      final amenity = (tags['amenity'] as String? ?? '').toLowerCase();
      final emergency = (tags['emergency'] as String? ?? '').toLowerCase();
      final healthcare = (tags['healthcare'] as String? ?? '').toLowerCase();
      if (amenity == 'hospital' ||
          emergency == 'yes' ||
          healthcare == 'hospital' ||
          tags['trauma'] == 'yes') {
        return true;
      }
    }

    return false;
  }

  /// Classifies the trauma response level based on facility tags and naming.
  static TraumaFacilityLevel classifyTraumaLevel(
    RouteEssential place, {
    Map<String, dynamic>? tags,
  }) {
    final nameLower = place.name.toLowerCase();
    final tagLevel = (tags?['trauma:level'] as String? ?? '').toLowerCase();

    if (tagLevel == '1' || tagLevel == 'level 1' || tagLevel == 'level_1') {
      return TraumaFacilityLevel.level1;
    }
    if (tagLevel == '2' || tagLevel == 'level 2' || tagLevel == 'level_2') {
      return TraumaFacilityLevel.level2;
    }
    if (tagLevel == '3' || tagLevel == 'level 3' || tagLevel == 'level_3') {
      return TraumaFacilityLevel.level3;
    }

    for (final kw in tertiaryKeywords) {
      if (nameLower.contains(kw)) return TraumaFacilityLevel.level1;
    }

    for (final kw in districtKeywords) {
      if (nameLower.contains(kw)) return TraumaFacilityLevel.level2;
    }

    if (tags?['emergency'] == 'yes' || nameLower.contains('emergency')) {
      return TraumaFacilityLevel.level3;
    }

    return TraumaFacilityLevel.general;
  }

  /// Discovers trauma centers along route corridor and orders them by triage urgency.
  static List<TraumaCenterFacility> discoverTraumaCenters({
    required Iterable<RouteEssential> places,
    required double incidentRoutePositionM,
    bool require24x7 = true,
    int maxDetourMinutes = 60,
    Map<String, Map<String, dynamic>>? tagMap,
  }) {
    final results = <TraumaCenterFacility>[];

    for (final place in places) {
      final tags = tagMap?[place.placeId];
      if (!isTraumaFacility(place, tags: tags)) continue;

      if ((place.detourDurationS / 60) > maxDetourMinutes) continue;

      final level = classifyTraumaLevel(place, tags: tags);
      final nameLower = place.name.toLowerCase();
      final is24x7 = (place.openingHours != null && place.openingHours!.contains('24/7')) ||
          tags?['emergency'] == 'yes' ||
          tags?['opening_hours'] == '24/7' ||
          nameLower.contains('24/7') ||
          level == TraumaFacilityLevel.level1 ||
          level == TraumaFacilityLevel.level2;

      if (require24x7 && !is24x7) continue;

      final hasIcu = level == TraumaFacilityLevel.level1 ||
          level == TraumaFacilityLevel.level2 ||
          tags?['healthcare:speciality:icu'] == 'yes';

      final hasBlood = level == TraumaFacilityLevel.level1 ||
          tags?['blood_bank'] == 'yes';

      results.add(TraumaCenterFacility(
        placeId: place.placeId,
        name: place.name,
        lat: place.lat,
        lng: place.lng,
        routePositionM: place.routePositionM,
        accessDistanceM: place.accessDistanceM,
        detourDistanceM: place.detourDistanceM,
        detourDurationS: place.detourDurationS,
        traumaLevel: level,
        has24x7Emergency: is24x7,
        hasIcu: hasIcu,
        hasBloodBank: hasBlood,
        emergencyPhone: tags?['phone'] as String? ?? tags?['emergency:phone'] as String?,
      ));
    }

    // Sort by golden hour proximity (fastest ETA)
    results.sort((a, b) {
      final minA = a.estimatedMinutes(incidentRoutePositionM);
      final minB = b.estimatedMinutes(incidentRoutePositionM);
      return minA.compareTo(minB);
    });

    return results;
  }

  /// Finds the optimal trauma facility for emergency dispatch within golden hour.
  /// Prioritizes Level 1 / Level 2 centers within reach over basic dispensaries.
  static TraumaCenterFacility? findBestTraumaCenter({
    required Iterable<RouteEssential> places,
    required double incidentRoutePositionM,
    int goldenHourMinutes = 60,
    Map<String, Map<String, dynamic>>? tagMap,
  }) {
    final centers = discoverTraumaCenters(
      places: places,
      incidentRoutePositionM: incidentRoutePositionM,
      require24x7: true,
      maxDetourMinutes: goldenHourMinutes,
      tagMap: tagMap,
    );

    if (centers.isEmpty) return null;

    // Prefer higher capability trauma centers (Level 1 or 2) reachable within golden hour
    final advanced = centers.where((c) =>
        (c.traumaLevel == TraumaFacilityLevel.level1 ||
            c.traumaLevel == TraumaFacilityLevel.level2) &&
        c.estimatedMinutes(incidentRoutePositionM) <= goldenHourMinutes);

    if (advanced.isNotEmpty) {
      return advanced.first;
    }

    // Fall back to nearest reachable facility with 24/7 emergency department
    return centers.first;
  }
}
