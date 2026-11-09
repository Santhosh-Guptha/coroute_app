// 3.55 rider score (docs/features_355/rider_score.md): the models for GET /me/score,
// GET /public/leaderboard and GET /me/leaderboard, plus the plain-language explanations shown on
// the "Your rider score" screen. Pure Dart (no Flutter), so it is unit tested directly.

/// One of the four parts of the score.
enum ScoreComponent { speedDiscipline, smoothness, safety, consistency }

extension ScoreComponentText on ScoreComponent {
  String get key => switch (this) {
        ScoreComponent.speedDiscipline => 'speedDiscipline',
        ScoreComponent.smoothness => 'smoothness',
        ScoreComponent.safety => 'safety',
        ScoreComponent.consistency => 'consistency',
      };

  String get title => switch (this) {
        ScoreComponent.speedDiscipline => 'Speed discipline',
        ScoreComponent.smoothness => 'Smoothness',
        ScoreComponent.safety => 'Safety habits',
        ScoreComponent.consistency => 'Regular riding',
      };

  /// Share of the overall score (percent).
  int get weight => switch (this) {
        ScoreComponent.speedDiscipline => 40,
        ScoreComponent.smoothness => 25,
        ScoreComponent.safety => 25,
        ScoreComponent.consistency => 10,
      };

  /// What it measures, in one or two plain sentences.
  String get explanation => switch (this) {
        ScoreComponent.speedDiscipline =>
          'How much of your riding stays within the speed limit. Going far over (40% or more) counts '
              'much more than a little over. Riding faster under the limit never adds points.',
        ScoreComponent.smoothness =>
          'Hard braking per 100 km, from your phone\'s private ride safety report. Fewer hard brakes '
              'usually means you are reading the road early.',
        ScoreComponent.safety =>
          'Breaks on long rides and staying with your group. Using SOS or having a crash never '
              'lowers your score.',
        ScoreComponent.consistency =>
          'Riding regularly over the last six months. Recent weeks count more than older ones.',
      };

  /// What the shown value means right now (a short verdict for the row).
  String verdict(int? value) {
    if (value == null) {
      return switch (this) {
        ScoreComponent.speedDiscipline => 'Not measured yet: ride with a group speed limit or the ride safety report',
        ScoreComponent.smoothness => 'Not measured: the ride safety report is not used',
        _ => 'Not measured yet',
      };
    }
    if (value >= 85) return 'Excellent';
    if (value >= 70) return 'Good';
    if (value >= 50) return 'Room to improve';
    return 'Needs attention';
  }
}

/// The plain meaning of each level name the gateway sends.
String levelDescription(String? level) => switch (level) {
      // 'Road Captain' was the old name of the top level (renamed Ace Rider in 3.55; it is a retired plan name).
      'Ace Rider' || 'Road Captain' => 'Smooth, within the limit and looking after the group. A rider others can follow.',
      'Skilled' => 'Safe, steady riding with a few things to polish.',
      'Steady' => 'A good base. The tips below show where to gain the most.',
      'Learner' => 'Everyone starts somewhere. Focus on the first tip below.',
      _ => 'Your level appears once your score is ready.',
    };

int? _int(Object? v) => v is num && v.isFinite ? v.round() : null;

class RiderScore {
  final bool enabled;
  final int? score;
  final String? level;
  final Map<ScoreComponent, int?> components;
  final int ridesCounted;
  final int minRides;
  final int? updatedAt;
  final List<String> tips;

  const RiderScore({
    this.enabled = true,
    this.score,
    this.level,
    this.components = const {},
    this.ridesCounted = 0,
    this.minRides = 3,
    this.updatedAt,
    this.tips = const [],
  });

  bool get ready => score != null;

  /// Rides still needed before the score appears (0 when ready).
  int get ridesToGo => ready ? 0 : (minRides - ridesCounted).clamp(0, minRides);

  /// "2 more rides of 10 km or more" (null once ready).
  String? get progressLine {
    if (ready) return null;
    final n = ridesToGo;
    if (n <= 0) return 'Your score is being calculated.';
    return n == 1 ? '1 more ride of 10 km or more to get your score.' : '$n more rides of 10 km or more to get your score.';
  }

  int? component(ScoreComponent c) => components[c];

  factory RiderScore.fromJson(Object? j) {
    if (j is! Map) return const RiderScore();
    final comps = j['components'];
    final tips = j['tips'];
    final score = _int(j['score']);
    final level = j['level'];
    return RiderScore(
      enabled: j['enabled'] != false,
      score: score?.clamp(0, 100),
      // An older gateway still sends the old top level name; show the new one.
      level: level is String && level.isNotEmpty ? (level == 'Road Captain' ? 'Ace Rider' : level) : null,
      components: {
        for (final c in ScoreComponent.values) c: comps is Map ? _int(comps[c.key])?.clamp(0, 100) : null,
      },
      ridesCounted: _int(j['ridesCounted']) ?? 0,
      minRides: _int(j['minRides']) ?? 3,
      updatedAt: _int(j['updatedAt']),
      tips: tips is List ? [for (final t in tips.take(6)) if (t is String && t.isNotEmpty) t] : const [],
    );
  }
}

/// One public leaderboard row: a username and one number.
class LeaderboardRow {
  final String username;
  final num value;
  final int? rides;
  const LeaderboardRow(this.username, this.value, {this.rides});
}

/// The five public boards.
enum LeaderboardBoard { topScore, mostKm, mostHours, mostRides, longestRide }

extension LeaderboardBoardText on LeaderboardBoard {
  String get key => switch (this) {
        LeaderboardBoard.topScore => 'topScore',
        LeaderboardBoard.mostKm => 'mostKm',
        LeaderboardBoard.mostHours => 'mostHours',
        LeaderboardBoard.mostRides => 'mostRides',
        LeaderboardBoard.longestRide => 'longestRide',
      };

  String get title => switch (this) {
        LeaderboardBoard.topScore => 'Top score',
        LeaderboardBoard.mostKm => 'Most km',
        LeaderboardBoard.mostHours => 'Most hours',
        LeaderboardBoard.mostRides => 'Most rides',
        LeaderboardBoard.longestRide => 'Longest ride',
      };

  String get _field => switch (this) {
        LeaderboardBoard.topScore => 'score',
        LeaderboardBoard.mostKm || LeaderboardBoard.longestRide => 'km',
        LeaderboardBoard.mostHours => 'hours',
        LeaderboardBoard.mostRides => 'rides',
      };

  String format(num v) => switch (this) {
        LeaderboardBoard.topScore => '${v.round()}',
        LeaderboardBoard.mostKm || LeaderboardBoard.longestRide => '${_thousands(v.round())} km',
        LeaderboardBoard.mostHours => '${v.toStringAsFixed(1)} h',
        LeaderboardBoard.mostRides => v.round() == 1 ? '1 ride' : '${v.round()} rides',
      };
}

String _thousands(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

class Leaderboard {
  final int? updatedAt;
  final Map<LeaderboardBoard, List<LeaderboardRow>> boards;
  const Leaderboard({this.updatedAt, this.boards = const {}});

  bool get isEmpty => boards.values.every((l) => l.isEmpty);

  List<LeaderboardRow> rows(LeaderboardBoard b) => boards[b] ?? const [];

  factory Leaderboard.fromJson(Object? j) {
    if (j is! Map) return const Leaderboard();
    List<LeaderboardRow> parse(LeaderboardBoard b) {
      final list = j[b.key];
      if (list is! List) return const [];
      return [
        for (final r in list.take(50))
          if (r is Map && r['username'] is String && r[b._field] is num)
            LeaderboardRow(r['username'] as String, r[b._field] as num, rides: _int(r['rides'])),
      ];
    }

    return Leaderboard(updatedAt: _int(j['updatedAt']), boards: {for (final b in LeaderboardBoard.values) b: parse(b)});
  }
}

/// GET /me/leaderboard: the rider's own places.
class LeaderboardPosition {
  final String? username;
  final bool onLeaderboard;
  final Map<LeaderboardBoard, int?> ranks;
  const LeaderboardPosition({this.username, this.onLeaderboard = false, this.ranks = const {}});

  int? rank(LeaderboardBoard b) => ranks[b];

  /// "You: #42" for a board, or a short reason why there is no place.
  String line(LeaderboardBoard b, {int minRides = 3}) {
    final r = ranks[b];
    if (r != null && onLeaderboard) return 'You: #$r';
    if (username == null) return 'Set a username and keep the leaderboard on in your profile to appear here.';
    return 'You appear here after $minRides rides of 10 km or more.';
  }

  factory LeaderboardPosition.fromJson(Object? j) {
    if (j is! Map) return const LeaderboardPosition();
    final ranks = j['ranks'];
    final u = j['username'];
    return LeaderboardPosition(
      username: u is String && u.isNotEmpty ? u : null,
      onLeaderboard: j['onLeaderboard'] == true,
      ranks: {for (final b in LeaderboardBoard.values) b: ranks is Map ? _int(ranks[b.key]) : null},
    );
  }
}

/// Per-ride counts from the phone's private ride safety report, as sent to POST /me/score/rides.
/// Counts only: never a position, a time, a speed or a track.
Map<String, Object> phoneCountsBody({
  required String groupId,
  required int hardBrakes,
  required int breaks,
  int fatiguePeak = 0,
  int fatiguePrompts = 0,
  int overLimitMin = 0,
}) =>
    {
      'groupId': groupId,
      'hardBrakes': hardBrakes.clamp(0, 1000),
      'breaks': breaks.clamp(0, 100),
      'fatiguePeak': fatiguePeak.clamp(0, 100),
      'fatiguePrompts': fatiguePrompts.clamp(0, 100),
      'overLimitMin': overLimitMin.clamp(0, 1440),
    };
