import 'package:flutter/material.dart';

/// The kind of a planned stop, mapped to the stop `category` codes the
/// gateway stores (FUEL, FOOD, REST, SCENIC, TOLL, MEETING, OTHER; see
/// StopPointModel.category and gateway/src/convoys.js). An older gateway
/// that does not know MEETING stores it as OTHER.
enum StopKind {
  fuel,
  food,
  rest,
  meeting,
  scenic,
  toll,
  custom;

  /// The kinds offered when adding a stop, in menu order.
  static const List<StopKind> pickable = [
    StopKind.fuel,
    StopKind.food,
    StopKind.rest,
    StopKind.meeting,
    StopKind.custom,
  ];

  String get label {
    switch (this) {
      case StopKind.fuel:
        return 'Fuel';
      case StopKind.food:
        return 'Food';
      case StopKind.rest:
        return 'Rest';
      case StopKind.meeting:
        return 'Meeting point';
      case StopKind.scenic:
        return 'Scenic';
      case StopKind.toll:
        return 'Toll';
      case StopKind.custom:
        return 'Stop';
    }
  }

  IconData get icon {
    switch (this) {
      case StopKind.fuel:
        return Icons.local_gas_station_rounded;
      case StopKind.food:
        return Icons.restaurant_rounded;
      case StopKind.rest:
        return Icons.airline_seat_recline_normal_rounded;
      case StopKind.meeting:
        return Icons.groups_rounded;
      case StopKind.scenic:
        return Icons.landscape_rounded;
      case StopKind.toll:
        return Icons.toll_rounded;
      case StopKind.custom:
        return Icons.place_rounded;
    }
  }

  /// The category code to send to the gateway.
  String get category {
    switch (this) {
      case StopKind.fuel:
        return 'FUEL';
      case StopKind.food:
        return 'FOOD';
      case StopKind.rest:
        return 'REST';
      case StopKind.scenic:
        return 'SCENIC';
      case StopKind.toll:
        return 'TOLL';
      case StopKind.meeting:
        return 'MEETING';
      case StopKind.custom:
        return 'OTHER';
    }
  }

  /// From a stored category code (case-insensitive). Unknown codes are [custom].
  static StopKind fromCategory(String? category) {
    switch ((category ?? '').toUpperCase()) {
      case 'FUEL':
        return StopKind.fuel;
      case 'FOOD':
        return StopKind.food;
      case 'REST':
        return StopKind.rest;
      case 'MEETING':
        return StopKind.meeting;
      case 'SCENIC':
        return StopKind.scenic;
      case 'TOLL':
        return StopKind.toll;
      default:
        return StopKind.custom;
    }
  }
}
