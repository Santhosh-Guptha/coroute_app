import 'package:flutter/material.dart';

import '../../domain/places/poi_category.dart';

/// Map icon and colour per place category (same in light and dark: white icon on a coloured disc).
extension PoiCategoryStyle on PoiCategory {
  IconData get icon => switch (this) {
        PoiCategory.fuel => Icons.local_gas_station_rounded,
        PoiCategory.ev => Icons.ev_station_rounded,
        PoiCategory.food => Icons.restaurant_rounded,
        PoiCategory.hospital => Icons.local_hospital_rounded,
        PoiCategory.police => Icons.local_police_rounded,
        PoiCategory.pharmacy => Icons.local_pharmacy_rounded,
        PoiCategory.mechanic => Icons.build_rounded,
        PoiCategory.atm => Icons.local_atm_rounded,
        PoiCategory.stay => Icons.hotel_rounded,
        PoiCategory.toilet => Icons.wc_rounded,
        PoiCategory.viewpoint => Icons.landscape_rounded,
      };

  Color get color => switch (this) {
        PoiCategory.fuel => const Color(0xFF2E7D32),
        PoiCategory.ev => const Color(0xFF00897B),
        PoiCategory.food => const Color(0xFFE65100),
        PoiCategory.hospital => const Color(0xFFC62828),
        PoiCategory.police => const Color(0xFF283593),
        PoiCategory.pharmacy => const Color(0xFF8E24AA),
        PoiCategory.mechanic => const Color(0xFF5D4037),
        PoiCategory.atm => const Color(0xFF455A64),
        PoiCategory.stay => const Color(0xFF0277BD),
        PoiCategory.toilet => const Color(0xFF546E7A),
        PoiCategory.viewpoint => const Color(0xFF558B2F),
      };
}
