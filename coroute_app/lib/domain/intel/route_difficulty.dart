/// v3.62 route difficulty for a planned ride (gateway POST /api/intel/route-difficulty, src/intel/insights.js).
///
/// Easy / Moderate / Challenging from what riders who share road data met on these roads (twisty and ghat roads,
/// rough road, hazard spots) plus the share of the ride after dark. Pure Dart (unit-tested).
library;

enum RouteDifficultyLevel { easy, moderate, challenging }

class RouteDifficulty {
  const RouteDifficulty({required this.level, required this.label, required this.reasons, required this.fromRiders});

  final RouteDifficultyLevel level;

  /// "Easy", "Moderate", "Challenging".
  final String label;

  /// Up to 4 short reasons ("12 km of ghat roads").
  final List<String> reasons;

  /// False when there is little rider data on these roads yet (only the length and the dark share count).
  final bool fromRiders;

  /// The line under the chip: the first two reasons, or a plain note.
  String get detail {
    if (reasons.isEmpty) return fromRiders ? 'Nothing unusual reported on this route' : 'Little rider data on these roads yet';
    return reasons.take(2).join(' · ');
  }

  /// Null for anything that is not a gateway answer.
  static RouteDifficulty? fromJson(Object? j) {
    if (j is! Map) return null;
    final lv = switch (j['level']) {
      'easy' => RouteDifficultyLevel.easy,
      'moderate' => RouteDifficultyLevel.moderate,
      'challenging' => RouteDifficultyLevel.challenging,
      _ => null,
    };
    if (lv == null) return null;
    final label = j['label'] is String && (j['label'] as String).isNotEmpty ? j['label'] as String : const {'easy': 'Easy', 'moderate': 'Moderate', 'challenging': 'Challenging'}[j['level']]!;
    final rs = j['reasons'] is List ? [for (final r in j['reasons'] as List) if (r is String && r.trim().isNotEmpty) r.trim()] : const <String>[];
    return RouteDifficulty(level: lv, label: label, reasons: rs.take(4).toList(), fromRiders: j['coverage'] == 'riders');
  }
}
