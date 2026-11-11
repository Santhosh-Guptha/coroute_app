import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/models/emergency_roster.dart';
import 'package:coroute_app/domain/safety/emergency_texts.dart';
import 'package:coroute_app/domain/safety/sms_plan.dart';

/// 3.57 phone-first emergency texts (docs/features_355/sos_sms.md, "Phone-first"): the text
/// variants and their SMS parts, dedupe per incident, the retry schedule, the daily cap,
/// cancel-before-send and the "I'm safe now" follow-up. Pure Dart (the native queue executes).
void main() {
  final at = DateTime(2026, 11, 11, 18, 42);
  const token = 'Ab3dEf6hIj9lMn0pQr2tUv';
  final link = SmsText.liveLinkFor('https://coroute.devmonks.space', token)!;
  const t0 = 1762866000000;
  const asha = RosterContact(name: 'Asha', phone: '+91 91234 56780');
  const ravi = RosterContact(name: 'Ravi', phone: '098765 43210');

  EmergencyTextStatus st(String id, EmergencyTextState s, {int attempts = 1}) =>
      EmergencyTextStatus(id: id, state: s, attempts: attempts);

  group('text builder', () {
    test('SOS: name, what happened, time, live link and coordinates in one part (map link only if it fits)', () {
      final body = EmergencyTexts.alert(name: 'Kiran', crash: false, lat: 12.971598, lng: 77.594562, at: at, liveLink: link);
      expect(body, startsWith('CoRoute SOS: Kiran needs help at 18:42.'));
      expect(body, contains('Live: $link'));
      expect(body, contains('Lat 12.97160 Lng 77.59456'));
      expect(SmsText.parts(body), 1);
      final withMap = '$body Map: https://maps.google.com/?q=12.97160,77.59456';
      expect(body.contains('maps.google') || SmsText.parts(withMap) > 1, isTrue);
    });

    test('possible crash says so', () {
      final body = EmergencyTexts.alert(name: 'Kiran', crash: true, lat: 12.97, lng: 77.59, at: at, liveLink: link);
      expect(body, contains('may have crashed at 18:42'));
      expect(SmsText.parts(body), 1);
    });

    test('a long name goes multipart, the coordinates and link are never dropped', () {
      final name = 'Kiran ' * 20;
      final body = EmergencyTexts.alert(name: name, crash: true, lat: 12.97, lng: 77.59, at: at, liveLink: link, convoyName: 'Weekend');
      expect(SmsText.parts(body), greaterThan(1));
      expect(body, contains(link));
      expect(body, contains('Lat 12.97000 Lng 77.59000'));
      expect(body, isNot(contains('maps.google')), reason: 'the map link only while it fits one part');
    });

    test('a non-GSM name (Devanagari) counts UCS-2 parts', () {
      final body = EmergencyTexts.alert(name: 'किरण', crash: false, lat: 12.97, lng: 77.59, at: at, liveLink: link);
      expect(SmsText.parts(body), greaterThan(1));
    });

    test('without a link: the map link text', () {
      final body = EmergencyTexts.alert(name: 'Kiran', crash: false, lat: 12.97, lng: 77.59, at: at);
      expect(body, contains('https://maps.google.com/?q='));
    });

    test('safe now and test texts are short, plain and carry no number', () {
      final safe = EmergencyTexts.safeNow(name: 'Kiran', at: at);
      expect(safe, 'CoRoute: Kiran is safe now. The SOS was closed at 18:42. No action is needed.');
      expect(SmsText.parts(safe), 1);
      expect(EmergencyTexts.safeNow(name: ' ', at: at), startsWith('CoRoute: The rider is safe now.'));
      expect(EmergencyTexts.test, startsWith('CoRoute test: emergency texts work'));
      expect(SmsText.parts(EmergencyTexts.test), 1);
    });
  });

  group('job ids and privacy', () {
    test('ids carry a hash of the number, never the number; same number in any format, same id', () {
      final a = EmergencyTexts.jobId('me-1', EmergencyTextKind.alert, '+91 91234 56780');
      final b = EmergencyTexts.jobId('me-1', EmergencyTextKind.alert, '091234 56780');
      expect(a, b);
      expect(a, isNot(contains('9123456780')));
      expect(EmergencyTexts.partsOf(a)?.$1, 'me-1');
      expect(EmergencyTexts.partsOf(a)?.$2, 'A');
      expect(EmergencyTexts.last3('+91 91234 56780'), '780');
      expect(EmergencyTexts.last3('12'), '');
      final s = EmergencyTextStatus.fromWire({'id': a, 'state': 'DELIVERED', 'attempts': 1, 'last3': '780'})!;
      expect(s.kind, EmergencyTextKind.alert);
      expect(s.incident, 'me-1');
      expect(s.state, EmergencyTextState.delivered);
      expect(EmergencyTextStatus.fromWire({'id': a, 'last3': '9123456780'})!.last3, '', reason: 'only 3 digits ever');
    });

    test('the ledger keeps no number and no text', () {
      final l = EmergencyTextLedger.empty();
      l.planAlert(incident: 'me-1', contacts: [asha], body: 'CoRoute SOS: x', nowMs: t0);
      final json = l.toJson().toString();
      expect(json, isNot(contains('9123456780')));
      expect(json, isNot(contains('CoRoute SOS')));
      final back = EmergencyTextLedger.fromJson(l.toJson());
      expect(back.hasIncident('me-1'), isTrue);
      expect(back.alreadyTexted('me-1', '+919123456780'), isTrue);
    });
  });

  group('dedupe per incident', () {
    test('each contact once, never myself, at most 5; the same incident again gives nothing', () {
      final l = EmergencyTextLedger.empty();
      final many = [
        asha,
        const RosterContact(name: 'Asha again', phone: '09123456780'),
        ravi,
        const RosterContact(name: 'Me', phone: '+91 99999 00000'),
        for (var i = 0; i < 8; i++) RosterContact(name: 'C$i', phone: '+91 9000000${i}11'),
      ];
      final jobs = l.planAlert(incident: 'me-1', contacts: many, body: 'b', nowMs: t0, selfPhone: '9999900000');
      expect(jobs, hasLength(EmergencyTextPolicy.maxContacts));
      expect(jobs.first.to, '+919123456780');
      expect(jobs[1].to, '09876543210');
      expect(jobs.map((j) => j.id).toSet(), hasLength(jobs.length));
      expect(jobs.any((j) => j.to.endsWith('9999900000')), isFalse);
      // Resent / relayed / upgraded to a crash / restored after a restart: same incident id.
      expect(l.planAlert(incident: 'me-1', contacts: many, body: 'b', nowMs: t0 + 5000), isEmpty);
      final restored = EmergencyTextLedger.fromJson(l.toJson());
      expect(restored.planAlert(incident: 'me-1', contacts: many, body: 'b', nowMs: t0 + 9000), isEmpty);
      // A new SOS is a new incident.
      expect(l.planAlert(incident: 'me-2', contacts: [asha], body: 'b', nowMs: t0 + 60000), hasLength(1));
    });

    test('no usable number: recorded, nothing to send, not tried again', () {
      final l = EmergencyTextLedger.empty();
      expect(l.planAlert(incident: 'me-1', contacts: const [RosterContact(name: 'x', phone: '12')], body: 'b', nowMs: t0), isEmpty);
      expect(l.hasIncident('me-1'), isTrue);
      expect(l.openIncident, isNull, reason: 'nothing texted, nothing to follow up');
    });
  });

  group('retry schedule', () {
    test('30 s, 2 min, 5 min, 10 min, then give up', () {
      const code = EmergencyTextPolicy.errorNoService;
      expect(EmergencyTextPolicy.retryAfter(1, code), const Duration(seconds: 30));
      expect(EmergencyTextPolicy.retryAfter(2, code), const Duration(minutes: 2));
      expect(EmergencyTextPolicy.retryAfter(3, code), const Duration(minutes: 5));
      expect(EmergencyTextPolicy.retryAfter(4, code), const Duration(minutes: 10));
      expect(EmergencyTextPolicy.retryAfter(5, code), isNull);
      expect(EmergencyTextPolicy.retryDelaysMs, [30000, 120000, 300000, 600000]);
    });

    test('only no service, radio off, generic failure and a missing report are retried', () {
      expect(EmergencyTextPolicy.retryable(EmergencyTextPolicy.errorRadioOff), isTrue);
      expect(EmergencyTextPolicy.retryable(EmergencyTextPolicy.errorGeneric), isTrue);
      expect(EmergencyTextPolicy.retryable(EmergencyTextPolicy.errorTimeout), isTrue);
      expect(EmergencyTextPolicy.retryable(EmergencyTextPolicy.errorNullPdu), isFalse);
      expect(EmergencyTextPolicy.retryable(EmergencyTextPolicy.errorNoPermission), isFalse);
      expect(EmergencyTextPolicy.retryAfter(1, EmergencyTextPolicy.errorNullPdu), isNull);
    });
  });

  group('daily cap', () {
    test('30 texts per rolling 24 h, alert and test texts alike', () {
      final l = EmergencyTextLedger.empty();
      final five = [for (var i = 0; i < 5; i++) RosterContact(name: 'C$i', phone: '+91 9000000${i}11')];
      for (var n = 0; n < 6; n++) {
        expect(l.planAlert(incident: 'i$n', contacts: five, body: 'b', nowMs: t0 + n * 1000), hasLength(5));
      }
      expect(l.remainingToday(t0 + 6000), 0);
      expect(l.planAlert(incident: 'i6', contacts: five, body: 'b', nowMs: t0 + 7000), isEmpty);
      expect(l.planTest(contacts: five, nowMs: t0 + 8000).$1, EmergencyTestPlan.dailyCap);
      // A day later the cap is free again.
      final later = t0 + const Duration(hours: 24, seconds: 10).inMilliseconds;
      expect(l.planAlert(incident: 'i7', contacts: five, body: 'b', nowMs: later), hasLength(5));
    });

    test('a partly used cap texts the first contacts only', () {
      final l = EmergencyTextLedger.empty();
      final five = [for (var i = 0; i < 5; i++) RosterContact(name: 'C$i', phone: '+91 9000000${i}11')];
      for (var n = 0; n < 5; n++) {
        l.planAlert(incident: 'i$n', contacts: five, body: 'b', nowMs: t0);
      }
      l.planAlert(incident: 'x', contacts: five.sublist(0, 3), body: 'b', nowMs: t0); // 28 used
      expect(l.planAlert(incident: 'y', contacts: five, body: 'b', nowMs: t0).map((j) => j.to), ['+919000000011', '+919000000111']);
    });
  });

  group('cancel before send and safe now', () {
    test('a press waits 10 s; automatic SOS goes at once', () {
      final l = EmergencyTextLedger.empty();
      final pressed = l.planAlert(incident: 'p', contacts: [asha], body: 'b', nowMs: t0, grace: EmergencyTextPolicy.graceFor(deliberatePress: true));
      expect(pressed.single.notBeforeMs, t0 + 10000);
      final auto = l.planAlert(incident: 'c', contacts: [asha], body: 'b', nowMs: t0, grace: EmergencyTextPolicy.graceFor(deliberatePress: false));
      expect(auto.single.notBeforeMs, t0);
    });

    test('cancelled within the grace window: the waiting text is cancelled and nobody gets "safe now"', () {
      final l = EmergencyTextLedger.empty();
      final jobs = l.planAlert(incident: 'me-1', contacts: [asha, ravi], body: 'b', nowMs: t0, grace: EmergencyTextPolicy.pressGrace);
      expect(l.openIncident, 'me-1');
      final waiting = [for (final j in jobs) st(j.id, EmergencyTextState.queued, attempts: 0)];
      expect(l.toCancel('me-1', waiting), [for (final j in jobs) j.id]);
      final afterCancel = [for (final j in jobs) st(j.id, EmergencyTextState.cancelled, attempts: 0)];
      expect(l.planSafe(incident: 'me-1', contacts: [asha, ravi], statuses: afterCancel, body: 's', nowMs: t0 + 3000), isEmpty);
      expect(l.openIncident, isNull);
    });

    test('resolved after texts went out: "safe now" to exactly those contacts, once', () {
      final l = EmergencyTextLedger.empty();
      final jobs = l.planAlert(incident: 'me-1', contacts: [asha, ravi], body: 'b', nowMs: t0);
      final statuses = [st(jobs[0].id, EmergencyTextState.delivered), st(jobs[1].id, EmergencyTextState.failed, attempts: 5)];
      expect(l.toCancel('me-1', statuses), isEmpty);
      final safe = l.planSafe(incident: 'me-1', contacts: [asha, ravi], statuses: statuses, body: 'safe', nowMs: t0 + 600000);
      expect(safe, hasLength(1));
      expect(safe.single.to, '+919123456780');
      expect(safe.single.kind, EmergencyTextKind.safe);
      expect(safe.single.id, EmergencyTexts.jobId('me-1', EmergencyTextKind.safe, '+919123456780'));
      // Closed again (the lead resolves too, ALERT_RESOLVED arrives): nothing more.
      expect(l.planSafe(incident: 'me-1', contacts: [asha, ravi], statuses: statuses, body: 'safe', nowMs: t0 + 700000), isEmpty);
    });

    test('a text still retrying when the SOS closes is cancelled; a text on its way gets "safe now"', () {
      final l = EmergencyTextLedger.empty();
      final jobs = l.planAlert(incident: 'me-1', contacts: [asha, ravi], body: 'b', nowMs: t0);
      final statuses = [st(jobs[0].id, EmergencyTextState.sending), st(jobs[1].id, EmergencyTextState.queued, attempts: 2)];
      expect(l.toCancel('me-1', statuses), [jobs[1].id]);
      final safe = l.planSafe(incident: 'me-1', contacts: [asha, ravi], statuses: statuses, body: 's', nowMs: t0 + 1000);
      expect(safe.map((j) => j.to), ['+919123456780']);
    });

    test('a new SOS closes an older open one; an old open SOS gets no "safe now" a day later', () {
      final l = EmergencyTextLedger.empty();
      l.planAlert(incident: 'me-1', contacts: [asha], body: 'b', nowMs: t0);
      l.planAlert(incident: 'me-2', contacts: [ravi], body: 'b', nowMs: t0 + 1000);
      expect(l.openIncident, 'me-2');
      expect(l.openIncidentAt(t0 + 2000), 'me-2');
      expect(l.openIncidentAt(t0 + const Duration(hours: 25).inMilliseconds), isNull);
      l.close('me-2');
      expect(l.openIncident, isNull, reason: 'me-1 was superseded, never followed up');
      // An SOS that is not texted (not allowed, test alarm) also closes an older open one.
      l.planAlert(incident: 'me-3', contacts: [asha], body: 'b', nowMs: t0 + 3000);
      l.recordWithoutTexts('me-4', t0 + 4000);
      expect(l.openIncident, isNull);
      expect(l.hasIncident('me-4'), isTrue);
    });

    test('another incident\'s statuses never count', () {
      final l = EmergencyTextLedger.empty();
      l.planAlert(incident: 'me-1', contacts: [asha], body: 'b', nowMs: t0);
      final other = st(EmergencyTexts.jobId('me-0', EmergencyTextKind.alert, asha.phone), EmergencyTextState.delivered);
      expect(l.planSafe(incident: 'me-1', contacts: [asha], statuses: [other], body: 's', nowMs: t0 + 1), isEmpty);
    });
  });

  group('test text and status line', () {
    test('the test text goes to the first contact only', () {
      final l = EmergencyTextLedger.empty();
      final (plan, job) = l.planTest(contacts: [asha, ravi], nowMs: t0);
      expect(plan, EmergencyTestPlan.ok);
      expect(job!.to, '+919123456780');
      expect(job.kind, EmergencyTextKind.test);
      expect(job.body, EmergencyTexts.test);
      expect(l.planTest(contacts: const [], nowMs: t0).$1, EmergencyTestPlan.noContact);
    });

    test('status line: counts only', () {
      String id(String p) => EmergencyTexts.jobId('me-1', EmergencyTextKind.alert, p);
      expect(EmergencyTextSummary.line(const []), '');
      expect(EmergencyTextSummary.line([st(id(asha.phone), EmergencyTextState.queued, attempts: 0)]), 'Texting your emergency contact from your phone...');
      expect(EmergencyTextSummary.line([st(id(asha.phone), EmergencyTextState.queued, attempts: 1)]), contains('No signal yet'));
      expect(EmergencyTextSummary.line([st(id(asha.phone), EmergencyTextState.delivered)]), 'Texted your emergency contact from your phone. Delivered.');
      expect(EmergencyTextSummary.line([st(id(asha.phone), EmergencyTextState.cancelled, attempts: 0)]), contains('cancelled in time'));
      final mixed = EmergencyTextSummary.line([st(id(asha.phone), EmergencyTextState.sent), st(id(ravi.phone), EmergencyTextState.failed)]);
      expect(mixed, 'Texted 1 of 2 emergency contacts from your phone. Some texts did not go out.');
      expect(mixed, isNot(contains('780')));
    });
  });
}
