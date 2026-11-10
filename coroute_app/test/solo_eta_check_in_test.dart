import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/safety/eta_check_in.dart';

/// 3.55 solo check-in timer (lib/domain/safety/eta_check_in.dart).
void main() {
  const min = 60000;
  const t0 = 1700000000000;

  test('margin is max(20 min, 25 % of the ETA)', () {
    final c = EtaCheckIn();
    expect(c.marginFor(const Duration(minutes: 40)), const Duration(minutes: 20));
    expect(c.marginFor(const Duration(minutes: 80)), const Duration(minutes: 20));
    expect(c.marginFor(const Duration(hours: 4)), const Duration(hours: 1));
  });

  test('arms at ETA + margin, asks at the deadline, escalates after 3 min without an answer', () {
    final c = EtaCheckIn()..arm(nowMs: t0, eta: const Duration(hours: 2));
    expect(c.phase, EtaCheckInPhase.armed);
    expect(c.deadlineMs, t0 + 120 * min + 30 * min);
    expect(c.tick(t0 + 149 * min), EtaCheckInAction.none);
    expect(c.tick(t0 + 150 * min), EtaCheckInAction.ask);
    expect(c.asking, isTrue);
    expect(c.tick(t0 + 152 * min), EtaCheckInAction.none);
    expect(c.tick(t0 + 153 * min), EtaCheckInAction.escalate);
    expect(c.escalated, isTrue);
    // Texted once: nothing more happens on later ticks.
    expect(c.tick(t0 + 200 * min), EtaCheckInAction.none);
  });

  test('3.55 false-SOS review: asked, then riding on without tapping counts as fine (no text)', () {
    final c = EtaCheckIn()..arm(nowMs: t0, eta: const Duration(hours: 2));
    expect(c.tick(t0 + 150 * min), EtaCheckInAction.ask);
    expect(c.ridingOn(nowMs: t0 + 151 * min, eta: const Duration(minutes: 20)), isTrue);
    expect(c.phase, EtaCheckInPhase.armed);
    expect(c.tick(t0 + 153 * min), EtaCheckInAction.none, reason: 'never escalates while riding on');
    expect(c.ridingOn(nowMs: t0 + 154 * min), isFalse, reason: 'only an open question is closed');
  });

  test('ETA updates only move the deadline later, never sooner than 10 min from now', () {
    final c = EtaCheckIn()..arm(nowMs: t0, eta: const Duration(minutes: 60));
    final first = c.deadlineMs!; // t0 + 80 min
    expect(c.updateEta(nowMs: t0 + 10 * min, eta: const Duration(minutes: 30)), isFalse, reason: 'sooner: ignored');
    expect(c.deadlineMs, first);
    expect(c.updateEta(nowMs: t0 + 10 * min, eta: const Duration(minutes: 70)), isTrue);
    expect(c.deadlineMs, t0 + 10 * min + 70 * min + 20 * min);
    // Late in the ride, a tiny ETA still lands at least 10 min out when it moves the deadline.
    final c2 = EtaCheckIn(minMargin: Duration.zero, marginShare: 0)..arm(nowMs: t0, eta: Duration.zero);
    expect(c2.updateEta(nowMs: t0 + min, eta: const Duration(seconds: 30)), isTrue);
    expect(c2.deadlineMs, t0 + min + 10 * min);
  });

  test("I'm fine and +30 min re-arm; after a text, I'm fine asks for a follow-up text", () {
    final c = EtaCheckIn()..arm(nowMs: t0, eta: const Duration(minutes: 30));
    c.tick(t0 + 50 * min); // ask
    expect(c.extend(nowMs: t0 + 51 * min), isFalse);
    expect(c.deadlineMs, t0 + 81 * min);
    c.tick(t0 + 81 * min); // ask again
    c.tick(t0 + 84 * min); // escalate
    expect(c.imFine(nowMs: t0 + 90 * min, eta: const Duration(minutes: 5)), isTrue, reason: 'contact was texted');
    expect(c.phase, EtaCheckInPhase.armed);
    expect(c.deadlineMs, t0 + 120 * min, reason: 'max(30 min, ETA + margin)');
    // Extending while armed adds to the current deadline.
    expect(c.extend(nowMs: t0 + 95 * min), isFalse);
    expect(c.deadlineMs, t0 + 150 * min);
  });

  test('disarm (arrived or ride ended) stops everything', () {
    final c = EtaCheckIn()..arm(nowMs: t0, eta: const Duration(minutes: 10));
    c.disarm();
    expect(c.active, isFalse);
    expect(c.tick(t0 + 1000 * min), EtaCheckInAction.none);
    expect(c.imFine(nowMs: t0), isFalse);
  });

  test('overdue text: name, destination, time and map link; no phone numbers', () {
    final body = EtaCheckInSms.overdue(
      name: 'Asha',
      destination: 'Manali',
      expectedBy: DateTime(2026, 11, 7, 16, 40),
      lat: 32.2432,
      lng: 77.1892,
      fixAt: DateTime(2026, 11, 7, 15, 58),
    );
    expect(body, contains('Asha has not reached Manali by 16:40'));
    expect(body, contains('15:58'));
    expect(body, contains('https://maps.google.com/?q=32.24320,77.18920'));
    expect(EtaCheckInSms.overdue(name: '', destination: '', expectedBy: DateTime(2026, 1, 1, 9, 5)), contains('No recent position'));
    expect(EtaCheckInSms.fineNow(name: 'Asha', at: DateTime(2026, 1, 1, 17, 2)), contains("I'm fine"));
  });
}
