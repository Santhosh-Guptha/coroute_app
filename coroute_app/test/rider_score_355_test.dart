// 3.55 rider score: parsing of GET /me/score, the leaderboard and own places, the plain
// explanations and the phone counts body (counts only). Pure Dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/score/rider_score.dart';

void main() {
  test('score parses, clamps and explains', () {
    final s = RiderScore.fromJson({
      'enabled': true,
      'score': 78,
      'level': 'Skilled',
      'components': {'smoothness': 64, 'speedDiscipline': 120, 'safety': 90, 'consistency': null},
      'ridesCounted': 5,
      'minRides': 3,
      'updatedAt': 1700000000000,
      'tips': ['Keep within the limit on highways.', 7, ''],
    });
    expect(s.ready, isTrue);
    expect(s.level, 'Skilled');
    expect(s.component(ScoreComponent.speedDiscipline), 100);
    expect(s.component(ScoreComponent.consistency), isNull);
    expect(s.tips, ['Keep within the limit on highways.']);
    expect(s.progressLine, isNull);
    expect(ScoreComponent.consistency.verdict(null), 'Not measured yet');
    expect(ScoreComponent.smoothness.verdict(null), contains('ride safety report'));
    expect(ScoreComponent.speedDiscipline.verdict(90), 'Excellent');
    expect(ScoreComponent.speedDiscipline.verdict(40), 'Needs attention');
    expect(ScoreComponent.values.fold<int>(0, (a, c) => a + c.weight), 100);
    for (final c in ScoreComponent.values) {
      expect(c.explanation, isNotEmpty);
    }
    expect(ScoreComponent.speedDiscipline.explanation, contains('never adds points'));
    expect(ScoreComponent.safety.explanation, contains('SOS'));
    expect(levelDescription('Ace Rider'), isNotEmpty);
    expect(levelDescription('Road Captain'), levelDescription('Ace Rider'));
    expect(RiderScore.fromJson({'score': 90, 'level': 'Road Captain'}).level, 'Ace Rider');
    expect(levelDescription(null), contains('appears'));
  });

  test('not ready: rides to go', () {
    final s = RiderScore.fromJson({'score': null, 'ridesCounted': 1, 'minRides': 3, 'components': {}});
    expect(s.ready, isFalse);
    expect(s.ridesToGo, 2);
    expect(s.progressLine, '2 more rides of 10 km or more to get your score.');
    expect(RiderScore.fromJson({'score': null, 'ridesCounted': 2, 'minRides': 3}).progressLine, startsWith('1 more ride'));
    expect(RiderScore.fromJson({'enabled': false}).enabled, isFalse);
    expect(RiderScore.fromJson('junk').ready, isFalse);
  });

  test('leaderboard parses and formats; own place line', () {
    final lb = Leaderboard.fromJson({
      'updatedAt': 1,
      'topScore': [
        {'username': 'asha', 'score': 91, 'rides': 12},
        {'username': 'bad'},
      ],
      'mostKm': [
        {'username': 'dev', 'km': 12345},
      ],
      'mostHours': [
        {'username': 'dev', 'hours': 101.25},
      ],
      'mostRides': [
        {'username': 'asha', 'rides': 1},
      ],
      'longestRide': 'nope',
    });
    expect(lb.rows(LeaderboardBoard.topScore).length, 1);
    expect(lb.rows(LeaderboardBoard.topScore).first.rides, 12);
    expect(lb.rows(LeaderboardBoard.longestRide), isEmpty);
    expect(LeaderboardBoard.mostKm.format(12345), '12,345 km');
    expect(LeaderboardBoard.mostHours.format(101.25), '101.3 h');
    expect(LeaderboardBoard.mostRides.format(1), '1 ride');
    expect(LeaderboardBoard.topScore.format(91), '91');

    final p = LeaderboardPosition.fromJson({'username': 'asha', 'onLeaderboard': true, 'ranks': {'topScore': 42, 'mostKm': null}});
    expect(p.line(LeaderboardBoard.topScore), 'You: #42');
    expect(p.line(LeaderboardBoard.mostKm), contains('3 rides'));
    expect(const LeaderboardPosition().line(LeaderboardBoard.topScore), contains('username'));
  });

  test('phone counts body carries counts only', () {
    final b = phoneCountsBody(groupId: 'GRP-1', hardBrakes: 5000, breaks: 2, fatiguePeak: 140, overLimitMin: 3);
    expect(b.keys.toSet(), {'groupId', 'hardBrakes', 'breaks', 'fatiguePeak', 'fatiguePrompts', 'overLimitMin'});
    expect(b['hardBrakes'], 1000);
    expect(b['fatiguePeak'], 100);
  });
}
