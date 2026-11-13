/// DATA FILE: default speed limits for MOTORCYCLES in India, used only when a road has no
/// usable limit tag (docs/features_355/curve_and_speed_limit.md has the same table with sources).
///
/// Statutory maximum (the ceiling of every value here): Ministry of Road Transport and Highways
/// notification S.O. 1522(E) of 6 April 2018, motor cycles:
///   expressway with access control 80 (only where motorcycles may use it),
///   4-lane and above divided carriageway 80, road within municipal limits 60, other roads 60.
/// States and local authorities post lower limits; signs always win. The values below the
/// statutory maximum (streets in built-up areas) are deliberately conservative guesses, not law.
///
/// Confidence: high = the statutory maximum for a road type that is clear from the map;
/// medium = the statutory maximum, but the road type is inferred (for example "divided" from
/// one-way + lanes); low = a conservative guess below the maximum.
library;

enum LimitConfidence { low, medium, high }

class LimitEstimate {
  const LimitEstimate(this.kmh, this.confidence, this.basis);
  final int kmh;
  final LimitConfidence confidence;

  /// Why (shown in help and the ride report, never spoken).
  final String basis;
}

class IndiaSpeedLimits {
  IndiaSpeedLimits._();

  /// The most a motorcycle may do on any road (S.O. 1522(E)).
  static const int motorcycleMaxKmh = 80;

  /// Outside a divided 4-lane road or expressway (municipal limits and "other roads").
  static const int motorcycleOtherRoadsKmh = 60;

  /// highway class -> (urban estimate, rural estimate).
  static const Map<String, (LimitEstimate, LimitEstimate)> table = {
    'motorway': (
      LimitEstimate(80, LimitConfidence.high, 'Expressway: motorcycle maximum 80 (where motorcycles are allowed)'),
      LimitEstimate(80, LimitConfidence.high, 'Expressway: motorcycle maximum 80 (where motorcycles are allowed)'),
    ),
    'trunk': (
      LimitEstimate(50, LimitConfidence.low, 'Main road in a built-up area: below the municipal maximum of 60'),
      LimitEstimate(60, LimitConfidence.medium, 'Other roads: motorcycle maximum 60 (80 only on a divided road of 4 lanes or more)'),
    ),
    'primary': (
      LimitEstimate(50, LimitConfidence.low, 'Main road in a built-up area: below the municipal maximum of 60'),
      LimitEstimate(60, LimitConfidence.medium, 'Other roads: motorcycle maximum 60'),
    ),
    'secondary': (
      LimitEstimate(50, LimitConfidence.low, 'Road in a built-up area: below the municipal maximum of 60'),
      LimitEstimate(60, LimitConfidence.medium, 'Other roads: motorcycle maximum 60'),
    ),
    'tertiary': (
      LimitEstimate(40, LimitConfidence.low, 'Local road in a built-up area: a careful guess'),
      LimitEstimate(50, LimitConfidence.low, 'Minor rural road: a careful guess below the maximum of 60'),
    ),
    'unclassified': (
      LimitEstimate(40, LimitConfidence.low, 'Local road in a built-up area: a careful guess'),
      LimitEstimate(50, LimitConfidence.low, 'Minor rural road: a careful guess below the maximum of 60'),
    ),
    'residential': (
      LimitEstimate(30, LimitConfidence.low, 'Residential street: a careful guess'),
      LimitEstimate(30, LimitConfidence.low, 'Residential street: a careful guess'),
    ),
    'living_street': (
      LimitEstimate(20, LimitConfidence.low, 'Shared street: a careful guess'),
      LimitEstimate(20, LimitConfidence.low, 'Shared street: a careful guess'),
    ),
    'service': (
      LimitEstimate(20, LimitConfidence.low, 'Service road: a careful guess'),
      LimitEstimate(20, LimitConfidence.low, 'Service road: a careful guess'),
    ),
    'road': (
      LimitEstimate(40, LimitConfidence.low, 'Road of unknown type: a careful guess'),
      LimitEstimate(50, LimitConfidence.low, 'Road of unknown type: a careful guess'),
    ),
  };

  /// A divided road of 4 lanes or more, outside built-up areas (S.O. 1522(E): 80).
  static const LimitEstimate dividedRural =
      LimitEstimate(80, LimitConfidence.medium, 'Divided road of 4 lanes or more: motorcycle maximum 80 (the map suggests a divided road)');

  /// Per-state overrides: state code (ISO 3166-2:IN without the prefix, for example 'KA') ->
  /// highway class -> (urban, rural). EMPTY on purpose: no state notification has been verified
  /// yet. Add a state only with its gazette notification as the source, and keep every value at
  /// or below the statutory maximum above.
  static const Map<String, Map<String, (LimitEstimate, LimitEstimate)>> stateOverrides = {};

  /// Limits implied by an OpenStreetMap type tag (maxspeed:type / source:maxspeed / zone:maxspeed),
  /// for a motorcycle. "IN:urban" means 70 for cars; a motorcycle is held to 60.
  static const Map<String, int> implicit = {
    'urban': 60,
    'rural': 60,
    'motorway': 80,
    'trunk': 60,
    'living_street': 20,
  };
}
