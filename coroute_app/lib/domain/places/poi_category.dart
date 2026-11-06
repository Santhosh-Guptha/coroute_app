/// Map place categories and how an OpenStreetMap tag set maps to one.
/// Pure: no Flutter, no I/O.
enum PoiCategory { fuel, ev, food, hospital, police, pharmacy, mechanic, atm, stay, toilet, viewpoint }

/// Categories shown until the rider changes them.
const Set<PoiCategory> defaultPoiCategories = {
  PoiCategory.fuel,
  PoiCategory.hospital,
  PoiCategory.mechanic,
  PoiCategory.food,
};

extension PoiCategoryInfo on PoiCategory {
  /// Chip text.
  String get label => switch (this) {
        PoiCategory.fuel => 'Fuel',
        PoiCategory.ev => 'EV charging',
        PoiCategory.food => 'Food',
        PoiCategory.hospital => 'Hospitals',
        PoiCategory.police => 'Police',
        PoiCategory.pharmacy => 'Pharmacy',
        PoiCategory.mechanic => 'Mechanics',
        PoiCategory.atm => 'ATM',
        PoiCategory.stay => 'Stays',
        PoiCategory.toilet => 'Toilets',
        PoiCategory.viewpoint => 'Viewpoints',
      };

  /// What one place of this kind is called when it has no name.
  String get singular => switch (this) {
        PoiCategory.fuel => 'Fuel station',
        PoiCategory.ev => 'EV charging point',
        PoiCategory.food => 'Place to eat',
        PoiCategory.hospital => 'Hospital or clinic',
        PoiCategory.police => 'Police station',
        PoiCategory.pharmacy => 'Pharmacy',
        PoiCategory.mechanic => 'Mechanic',
        PoiCategory.atm => 'ATM',
        PoiCategory.stay => 'Place to stay',
        PoiCategory.toilet => 'Toilet',
        PoiCategory.viewpoint => 'Viewpoint',
      };

  /// Lower wins when two markers would overlap at the same distance.
  int get rank => switch (this) {
        PoiCategory.hospital => 0,
        PoiCategory.fuel => 1,
        PoiCategory.ev => 1,
        PoiCategory.mechanic => 2,
        PoiCategory.police => 2,
        PoiCategory.pharmacy => 3,
        PoiCategory.food => 4,
        PoiCategory.stay => 5,
        PoiCategory.atm => 5,
        PoiCategory.toilet => 6,
        PoiCategory.viewpoint => 7,
      };

  static PoiCategory? byName(String name) {
    for (final c in PoiCategory.values) {
      if (c.name == name) return c;
    }
    return null;
  }
}

const _health = {'hospital', 'clinic', 'doctors'};
const _healthcare = {'hospital', 'clinic', 'centre'};
const _repairShops = {'motorcycle', 'motorcycle_repair', 'car_repair', 'tyres', 'tyre_repair'};
const _food = {'restaurant', 'cafe', 'fast_food', 'food_court'};
const _stay = {'hotel', 'motel', 'hostel', 'guest_house', 'chalet'};

/// The category of an OSM tag set, or null for anything the map does not show.
PoiCategory? classifyPoi(Map<String, String> t) {
  final amenity = t['amenity'];
  if (amenity == 'fuel') return PoiCategory.fuel;
  if (amenity == 'charging_station') return PoiCategory.ev;
  if (_health.contains(amenity) || _healthcare.contains(t['healthcare'])) return PoiCategory.hospital;
  if (amenity == 'police') return PoiCategory.police;
  if (amenity == 'pharmacy') return PoiCategory.pharmacy;
  if (_repairShops.contains(t['shop']) || t['craft'] == 'mechanic' || t['service:vehicle:tyres'] == 'yes' ||
      t['service:motorcycle:repair'] == 'yes') {
    return PoiCategory.mechanic;
  }
  if (_food.contains(amenity)) return PoiCategory.food;
  if (amenity == 'atm') return PoiCategory.atm;
  if (amenity == 'toilets') return PoiCategory.toilet;
  final tourism = t['tourism'];
  if (_stay.contains(tourism)) return PoiCategory.stay;
  if (tourism == 'viewpoint') return PoiCategory.viewpoint;
  return null;
}
