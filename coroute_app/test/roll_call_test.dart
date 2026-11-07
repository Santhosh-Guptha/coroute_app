import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/group/roll_call.dart';

/// 3.55 start and arrival roll call (lib/domain/group/roll_call.dart).
void main() {
  const t0 = 1700000000000;
  const min = 60000;
  RollCallInput r(String id, {int seen = 0, bool pos = true, int arrived = 0}) =>
      RollCallInput(userId: id, name: id, lastSeenMs: seen, hasPosition: pos && seen > 0, arrivedAtMs: arrived);

  test('start: Joined / Not yet during the first 15 minutes until everyone joined', () {
    final s = RollCall.compute(riders: [r('Asha', seen: t0 + min), r('Ravi')], nowMs: t0 + 2 * min, rideStartedAtMs: t0);
    expect(s.phase, RollCallPhase.start);
    expect(s.summary, '1 of 2 joined');
    expect(s.entries.first.name, 'Ravi', reason: 'not yet first');
    expect(s.entries.first.label, 'Not yet');
    expect(s.entries.last.label, 'Joined');
    // Everyone joined: hidden. After 15 minutes: hidden.
    expect(RollCall.compute(riders: [r('Asha', seen: t0 + min), r('Ravi', seen: t0 + min)], nowMs: t0 + 2 * min, rideStartedAtMs: t0).phase, RollCallPhase.none);
    expect(RollCall.compute(riders: [r('Asha', seen: t0 + min), r('Ravi')], nowMs: t0 + 16 * min, rideStartedAtMs: t0).phase, RollCallPhase.none);
  });

  test('a position from an old ride (before the start) does not count as joined', () {
    final s = RollCall.compute(riders: [r('Asha', seen: t0 - 60 * min), r('Ravi', seen: t0)], nowMs: t0 + min, rideStartedAtMs: t0);
    expect(s.entries.firstWhere((e) => e.userId == 'Asha').mark, RollCallMark.notYet);
  });

  test('arrival: Arrived / On the way once anyone arrived; Everyone has arrived', () {
    final s = RollCall.compute(riders: [r('Asha', seen: t0, arrived: t0 + 90 * min), r('Ravi', seen: t0)], nowMs: t0 + 95 * min, rideStartedAtMs: t0);
    expect(s.phase, RollCallPhase.arrival);
    expect(s.summary, '1 of 2 arrived');
    expect(s.entries.first.label, 'On the way');
    final all = RollCall.compute(riders: [r('Asha', arrived: 1), r('Ravi', arrived: 2)], nowMs: t0, rideStartedAtMs: 0);
    expect(all.summary, 'Everyone has arrived');
  });

  test('solo rides and unknown start show nothing', () {
    expect(RollCall.compute(riders: [r('Asha')], nowMs: t0, rideStartedAtMs: t0).phase, RollCallPhase.none);
    expect(RollCall.compute(riders: [r('Asha'), r('Ravi')], nowMs: t0, rideStartedAtMs: t0, groupRide: false).phase, RollCallPhase.none);
    expect(RollCall.compute(riders: [r('Asha'), r('Ravi')], nowMs: t0, rideStartedAtMs: 0).phase, RollCallPhase.none);
  });
}
