import 'dart:math' as math;
import 'package:latlong2/latlong.dart';
import '../../data/models/rider_model.dart';

class TelemetryUtils {
  static const List<String> cardinalDirections8 = [
    'N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'
  ];

  static const List<String> cardinalDirections16 = [
    'N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE',
    'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW'
  ];

  /// Returns 8-point cardinal direction for a given heading in degrees (0-360)
  static String getCardinalDirection(double heading) {
    final normalized = (heading % 360 + 360) % 360;
    final index = ((normalized + 22.5) ~/ 45) % 8;
    return cardinalDirections8[index];
  }

  /// Returns 16-point high-resolution cardinal direction
  static String getCardinalDirection16(double heading) {
    final normalized = (heading % 360 + 360) % 360;
    final index = ((normalized + 11.25) ~/ 22.5) % 16;
    return cardinalDirections16[index];
  }

  /// Formats heading into human readable badge (e.g. 45° NE)
  static String formatHeading(double heading) {
    final cardinal = getCardinalDirection(heading);
    return '${heading.round()}° $cardinal';
  }

  /// Categorizes speed in km/h
  static String getSpeedCategory(double speedKmh) {
    if (speedKmh < 1.5) return 'Parked';
    if (speedKmh < 25.0) return 'Slow Pace';
    if (speedKmh < 60.0) return 'City Cruising';
    if (speedKmh < 95.0) return 'Highway Pace';
    return 'High Speed';
  }

  /// Calculates Haversine distance in meters between two coordinates
  static double calculateDistanceMeters(LatLng p1, LatLng p2) {
    const Distance distance = Distance();
    return distance.as(LengthUnit.Meter, p1, p2);
  }

  /// Calculates initial bearing in degrees from p1 to p2
  static double calculateBearing(LatLng p1, LatLng p2) {
    final lat1 = p1.latitude * math.pi / 180.0;
    final lon1 = p1.longitude * math.pi / 180.0;
    final lat2 = p2.latitude * math.pi / 180.0;
    final lon2 = p2.longitude * math.pi / 180.0;

    final dLon = lon2 - lon1;
    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);

    final bearingRad = math.atan2(y, x);
    final bearingDeg = (bearingRad * 180.0 / math.pi + 360.0) % 360.0;
    return bearingDeg;
  }

  /// Computes convoy group formation metrics (spread, average speed, health)
  static ConvoyFormationMetrics calculateConvoyMetrics(List<RiderModel> riders) {
    if (riders.isEmpty) {
      return ConvoyFormationMetrics(
        activeRiderCount: 0,
        movingRiderCount: 0,
        averageSpeedKmh: 0,
        maxSpeedKmh: 0,
        spreadKm: 0,
        status: 'Empty Group',
        statusColor: 0xFF94A3B8,
      );
    }

    int moving = 0;
    double speedSum = 0;
    double maxSpeed = 0;

    for (final r in riders) {
      if (r.speedKmh >= 2.0) moving++;
      speedSum += r.speedKmh;
      if (r.speedKmh > maxSpeed) maxSpeed = r.speedKmh;
    }

    final avgSpeed = speedSum / riders.length;

    // Calculate maximum pairwise spread
    double maxDistanceMeters = 0;
    for (int i = 0; i < riders.length; i++) {
      for (int j = i + 1; j < riders.length; j++) {
        final d = calculateDistanceMeters(
          LatLng(riders[i].lat, riders[i].lng),
          LatLng(riders[j].lat, riders[j].lng),
        );
        if (d > maxDistanceMeters) maxDistanceMeters = d;
      }
    }

    final spreadKm = maxDistanceMeters / 1000.0;

    String status;
    int statusColor;

    if (riders.length == 1) {
      status = 'Solo Rider';
      statusColor = 0xFF00E5FF;
    } else if (spreadKm < 1.0) {
      status = 'Tight Convoy';
      statusColor = 0xFF00E676; // Emerald green
    } else if (spreadKm < 3.0) {
      status = 'Normal Spread';
      statusColor = 0xFFFFD600; // Gold
    } else if (spreadKm < 6.0) {
      status = 'Stretched Out';
      statusColor = 0xFFFF9100; // Amber
    } else {
      status = 'Scattered';
      statusColor = 0xFFFF1744; // Crimson
    }

    return ConvoyFormationMetrics(
      activeRiderCount: riders.length,
      movingRiderCount: moving,
      averageSpeedKmh: avgSpeed,
      maxSpeedKmh: maxSpeed,
      spreadKm: spreadKm,
      status: status,
      statusColor: statusColor,
    );
  }

  /// Computes relative position between my location and another member
  static RelativePositionResult getRelativePosition({
    required double myLat,
    required double myLng,
    required double myHeading,
    required double otherLat,
    required double otherLng,
  }) {
    final distanceMeters = calculateDistanceMeters(
      LatLng(myLat, myLng),
      LatLng(otherLat, otherLng),
    );

    if (distanceMeters < 35.0) {
      return RelativePositionResult(
        label: 'Nearby',
        distanceMeters: distanceMeters,
        colorHex: 0xFF94A3B8,
        symbol: '⚪',
      );
    }

    final bearingToOther = calculateBearing(
      LatLng(myLat, myLng),
      LatLng(otherLat, otherLng),
    );

    var diff = (bearingToOther - myHeading + 360) % 360;
    if (diff > 180) diff -= 360;

    if (diff.abs() < 90) {
      return RelativePositionResult(
        label: 'Ahead',
        distanceMeters: distanceMeters,
        colorHex: 0xFF00E676,
        symbol: '🟢',
      );
    } else {
      return RelativePositionResult(
        label: 'Behind',
        distanceMeters: distanceMeters,
        colorHex: 0xFFFF1744,
        symbol: '🔴',
      );
    }
  }
}

class RelativePositionResult {
  final String label; // 'Ahead', 'Behind', 'Nearby'
  final double distanceMeters;
  final int colorHex;
  final String symbol;

  RelativePositionResult({
    required this.label,
    required this.distanceMeters,
    required this.colorHex,
    required this.symbol,
  });

  String get formattedDistance {
    if (distanceMeters < 1000) {
      return '${distanceMeters.round()} m';
    }
    return '${(distanceMeters / 1000).toStringAsFixed(1)} km';
  }
}

class ConvoyFormationMetrics {
  final int activeRiderCount;
  final int movingRiderCount;
  final double averageSpeedKmh;
  final double maxSpeedKmh;
  final double spreadKm;
  final String status;
  final int statusColor;

  ConvoyFormationMetrics({
    required this.activeRiderCount,
    required this.movingRiderCount,
    required this.averageSpeedKmh,
    required this.maxSpeedKmh,
    required this.spreadKm,
    required this.status,
    required this.statusColor,
  });
}
