/// 3.55 "Start and arrival roll call" (switch `rollCall`): who has joined at the start of a group
/// ride and who has arrived at the end, from data the phone already has (the riders of the ride
/// and the destination arrivals). Pure.
///
///  * Start: during the first [startWindow] of the ride, until everyone has joined: "Joined" for a
///    rider whose phone has reported a position since the ride started, "Not yet" otherwise.
///  * End: once anyone has arrived at the destination: "Arrived" / "On the way".
///  * Otherwise nothing is shown. The guardians' "Arrived safely" when everyone arrived is sent by
///    the server (gateway/src/guardian_arrival.js on destinationAllReachedAt).
enum RollCallPhase { none, start, arrival }

enum RollCallMark { joined, notYet, arrived, onTheWay }

class RollCallInput {
  final String userId;
  final String name;

  /// Last position report (epoch ms; 0 = never) and whether that report has a position.
  final int lastSeenMs;
  final bool hasPosition;

  /// Arrival time at the destination (epoch ms; 0 = not arrived).
  final int arrivedAtMs;

  const RollCallInput({required this.userId, required this.name, this.lastSeenMs = 0, this.hasPosition = false, this.arrivedAtMs = 0});
}

class RollCallEntry {
  final String userId;
  final String name;
  final RollCallMark mark;
  const RollCallEntry(this.userId, this.name, this.mark);

  bool get done => mark == RollCallMark.joined || mark == RollCallMark.arrived;

  String get label => switch (mark) {
        RollCallMark.joined => 'Joined',
        RollCallMark.notYet => 'Not yet',
        RollCallMark.arrived => 'Arrived',
        RollCallMark.onTheWay => 'On the way',
      };
}

class RollCallState {
  final RollCallPhase phase;
  final List<RollCallEntry> entries;
  const RollCallState(this.phase, this.entries);

  static const RollCallState none = RollCallState(RollCallPhase.none, <RollCallEntry>[]);

  int get done => entries.where((e) => e.done).length;
  int get total => entries.length;
  bool get complete => total > 0 && done == total;

  /// "4 of 6 joined" / "Everyone has arrived".
  String get summary {
    if (phase == RollCallPhase.none) return '';
    if (complete) return phase == RollCallPhase.start ? 'Everyone has joined' : 'Everyone has arrived';
    return phase == RollCallPhase.start ? '$done of $total joined' : '$done of $total arrived';
  }
}

class RollCall {
  RollCall._();

  static const Duration startWindow = Duration(minutes: 15);

  /// [rideStartedAtMs]: when this phone first saw the ride started (0 = unknown: no start roll call).
  static RollCallState compute({
    required List<RollCallInput> riders,
    required int nowMs,
    required int rideStartedAtMs,
    bool groupRide = true,
  }) {
    if (!groupRide || riders.length < 2) return RollCallState.none;
    int byName(RollCallEntry a, RollCallEntry b) {
      final d = (a.done ? 1 : 0) - (b.done ? 1 : 0);
      return d != 0 ? d : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    }

    if (riders.any((r) => r.arrivedAtMs > 0)) {
      final list = [
        for (final r in riders) RollCallEntry(r.userId, r.name, r.arrivedAtMs > 0 ? RollCallMark.arrived : RollCallMark.onTheWay),
      ]..sort(byName);
      return RollCallState(RollCallPhase.arrival, list);
    }
    if (rideStartedAtMs <= 0) return RollCallState.none;
    final age = nowMs - rideStartedAtMs;
    if (age < 0 || age > startWindow.inMilliseconds) return RollCallState.none;
    // "Joined": a position reported since the ride started (a little slack for clock drift).
    final since = rideStartedAtMs - 5 * 60000;
    final list = [
      for (final r in riders)
        RollCallEntry(r.userId, r.name, r.hasPosition && r.lastSeenMs >= since ? RollCallMark.joined : RollCallMark.notYet),
    ]..sort(byName);
    final state = RollCallState(RollCallPhase.start, list);
    // Shown until everyone has joined.
    return state.complete ? RollCallState.none : state;
  }
}
