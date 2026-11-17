import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/intel/route_difficulty.dart';

/// v3.62 route difficulty chip in Plan a ride.
void main() {
  test('parses the gateway answer and keeps at most 4 reasons', () {
    final d = RouteDifficulty.fromJson({
      'level': 'challenging', 'label': 'Challenging', 'coverage': 'riders',
      'reasons': ['12 km of ghat roads', '20% rough road', '5 hazard spots riders reported', '45% of the ride after dark', 'extra'],
    })!;
    expect(d.level, RouteDifficultyLevel.challenging);
    expect(d.reasons.length, 4);
    expect(d.detail, '12 km of ghat roads · 20% rough road');
    expect(d.fromRiders, isTrue);
  });
  test('little data and bad answers', () {
    final d = RouteDifficulty.fromJson({'level': 'easy', 'reasons': [], 'coverage': 'little data yet'})!;
    expect(d.label, 'Easy');
    expect(d.detail, 'Little rider data on these roads yet');
    expect(RouteDifficulty.fromJson({'level': 'impossible'}), isNull);
    expect(RouteDifficulty.fromJson('x'), isNull);
    expect(RouteDifficulty.fromJson({'level': 'easy', 'coverage': 'riders', 'reasons': []})!.detail, 'Nothing unusual reported on this route');
  });
}
