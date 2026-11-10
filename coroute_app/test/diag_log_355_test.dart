// 3.55 diagnostics log (docs/features_355/diagnostics_logs.md): redaction, level filtering,
// entry encoding, file rotation / retention / size policy and the GPS summary. Pure Dart.
import 'package:coroute_app/domain/diag/diag_log.dart';
import 'package:coroute_app/domain/diag/diag_policy.dart';
import 'package:coroute_app/domain/diag/diag_redact.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DiagRedact.text', () {
    test('e-mail addresses are removed', () {
      expect(DiagRedact.text('send to rider.one+x@example.co.in now'), 'send to <email> now');
    });

    test('phone numbers in common formats are removed', () {
      expect(DiagRedact.text('call +91 98765 43210'), 'call <phone>');
      expect(DiagRedact.text('call 9876543210 now'), 'call <phone> now');
      expect(DiagRedact.text('(020) 2612-3456 office'), '<phone> office');
    });

    test('JWTs and bearer tokens are removed', () {
      const jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyMSJ9.abcDEF123_-xyz';
      expect(DiagRedact.text('auth $jwt'), isNot(contains('eyJ')));
      expect(DiagRedact.text('Authorization: Bearer abc.def.ghi'), isNot(contains('abc.def')));
      expect(DiagRedact.text('token=AbC123xyz'), isNot(contains('AbC123xyz')));
    });

    test('long mixed tokens and hex runs are removed, plain paths are kept', () {
      expect(DiagRedact.text('fcm dGhpc0lzQUxvbmdGY21Ub2tlbjEyMzQ1Njc4OTBhYmNk end'), 'fcm <token> end');
      expect(DiagRedact.text('id 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b'), 'id <hex>');
      expect(DiagRedact.text('at package:coroute_app/data/services/realtime_service.dart'), contains('realtime_service'));
    });

    test('long digit runs are removed, short numbers stay', () {
      expect(DiagRedact.text('epoch 1731234567890 waited 120ms'), 'epoch <num> waited 120ms');
      expect(DiagRedact.text('P1 decision->audio 340ms'), 'P1 decision->audio 340ms');
    });

    test('URL query strings are dropped', () {
      expect(DiagRedact.text('GET https://api.coroute.app/ws?token=secretvalue'), 'GET https://api.coroute.app/ws');
    });

    test('precise coordinates in text are rounded to 3 decimals', () {
      expect(DiagRedact.text('at 17.385044, 78.486671'), 'at 17.385, 78.487');
    });

    test('long text is cut', () {
      expect(DiagRedact.text('a' * 500).length, DiagRedact.maxString);
    });
  });

  group('DiagRedact.fields', () {
    test('personal keys are dropped whatever the value', () {
      final f = DiagRedact.fields({
        'riderName': 'Raj',
        'phone': '+919876543210',
        'email': 'a@b.co',
        'messageText': 'hello',
        'bloodGroup': 'O+',
        'fcmToken': 'abc',
        'homeAddress': 'x',
        'emergencyContact': 'y',
        'status': 403,
      });
      expect(f.keys.toList(), ['status']);
    });

    test('counts and flags of blocked words are allowed', () {
      final f = DiagRedact.fields({'textLen': 12, 'tokenOk': true, 'messageCount': 3});
      expect(f, {'textLen': 12, 'tokenOk': true, 'messageCount': 3});
    });

    test('values are flattened and rounded', () {
      final f = DiagRedact.fields({'g': 3.14159, 'n': 4, 'list': [1, 2, 3], 'map': {'a': 1}, 'ok': false, 'lat': 17.385044});
      expect(f['g'], 3.14);
      expect(f['n'], 4);
      expect(f['list'], 3);
      expect(f['map'], 1);
      expect(f['ok'], false);
      expect(f['lat'], 17.385);
    });

    test('at most maxFields fields', () {
      final f = DiagRedact.fields({for (var i = 0; i < 40; i++) 'k$i': i});
      expect(f.length, DiagRedact.maxFields);
    });
  });

  group('DiagRedact ids and paths', () {
    test('hashId is stable per salt and differs across salts', () {
      final a = DiagRedact.hashId('user-123', 'salt1');
      expect(a.length, 10);
      expect(DiagRedact.hashId('user-123', 'salt1'), a);
      expect(DiagRedact.hashId('user-123', 'salt2'), isNot(a));
      expect(DiagRedact.hashId('user-124', 'salt1'), isNot(a));
      expect(a, isNot(contains('123')));
    });

    test('pathTemplate strips ids and the query', () {
      expect(DiagRedact.pathTemplate('/friends/raj_rides/accept?x=1'), '/friends/:id/accept');
      expect(DiagRedact.pathTemplate('/trips/G-12AB/feedback'), '/trips/:id/feedback');
      expect(DiagRedact.pathTemplate('/me/push-tokens'), '/me/push-tokens');
      expect(DiagRedact.pathTemplate('/friends/requests/req_9f8e7d/accept'), '/friends/requests/:id/accept');
      expect(DiagRedact.pathTemplate('/users/username-available?u=raj'), '/users/username-available');
      expect(DiagRedact.pathTemplate('/crews/c_1234/polls/p_99'), '/crews/:id/polls/:id');
    });

    test('stackTop keeps file names and lines only', () {
      const st = '#0      RealtimeService._open (package:coroute_app/data/services/realtime_service.dart:374:15)\n'
          '#1      _rootRun (dart:async/zone.dart:1399:13)\n';
      expect(DiagRedact.stackTop(st), 'RealtimeService._open realtime_service.dart:374 | _rootRun zone.dart:1399');
    });
  });

  group('DiagLog', () {
    setUp(() {
      DiagLog.resetForTest();
      DiagLog.clock = () => 1000000;
    });

    test('info is written, debug only while detailed logs are on', () {
      expect(DiagLog.info(DiagCat.ride, 'start'), isNotNull);
      expect(DiagLog.debug(DiagCat.ride, 'tick'), isNull);
      DiagLog.detailedUntilMs = 1000000 + 1;
      expect(DiagLog.debug(DiagCat.ride, 'tick'), isNotNull);
      DiagLog.detailedUntilMs = 999999; // expired (auto-off after 24 h)
      expect(DiagLog.debug(DiagCat.ride, 'tick'), isNull);
    });

    test('location fields only during a ride', () {
      final off = DiagLog.info(DiagCat.location, 'fix', {'lat': 17.385044, 'lng': 78.486671});
      expect(off!.fields.containsKey('lat'), isFalse);
      DiagLog.rideId = 'G-1';
      final on = DiagLog.info(DiagCat.location, 'fix', {'lat': 17.385044, 'lng': 78.486671});
      expect(on!.fields['lat'], 17.385);
      expect(on.fields['lng'], 78.487);
      expect(on.ride, 'G-1');
    });

    test('entries wait for the sink and are handed over once', () {
      DiagLog.info(DiagCat.lifecycle, 'start');
      final got = <DiagEntry>[];
      DiagLog.sink = got.add;
      DiagLog.drainEarly();
      DiagLog.drainEarly();
      DiagLog.info(DiagCat.lifecycle, 'resume');
      expect(got.map((e) => e.event).toList(), ['start', 'resume']);
    });

    test('the memory ring is capped', () {
      for (var i = 0; i < DiagLog.ringSize + 20; i++) {
        DiagLog.info(DiagCat.network, 'n');
      }
      expect(DiagLog.recent.length, DiagLog.ringSize);
    });

    test('userHash needs the install salt', () {
      expect(DiagLog.userHash('u1'), '');
      DiagLog.salt = 's';
      expect(DiagLog.userHash('u1').length, 10);
    });

    test('a sink that logs again does not recurse', () {
      var calls = 0;
      DiagLog.sink = (e) {
        calls++;
        DiagLog.info(DiagCat.diag, 'inner');
      };
      DiagLog.info(DiagCat.diag, 'outer');
      expect(calls, 1);
    });
  });

  group('DiagEntry encoding', () {
    test('encode / decode round trip', () {
      const e = DiagEntry(
          wallMs: 1731234567890, monoMs: 42, level: DiagLevel.warn, cat: DiagCat.sos, event: 'raise',
          fields: {'src': 'manual', 'queued': true}, build: '3.55.0+1', session: 'abc', ride: 'G-1', seq: 7);
      final line = e.encode();
      expect(line, contains('"c":"sos"'));
      expect(line, contains('"l":"W"'));
      final d = DiagEntry.decode(line)!;
      expect(d.wallMs, e.wallMs);
      expect(d.level, DiagLevel.warn);
      expect(d.cat, DiagCat.sos);
      expect(d.fields['queued'], true);
      expect(d.ride, 'G-1');
      expect(d.seq, 7);
    });

    test('a torn line is skipped', () {
      expect(DiagEntry.decode('{"t":17312345'), isNull);
      expect(DiagEntry.decode(''), isNull);
      expect(DiagEntry.decode('{"meta":true}'), isNull);
    });
  });

  group('DiagFiles rotation and retention', () {
    const today = '20261110';
    test('appends to today until 2 MB, then a new part', () {
      expect(DiagFiles.currentFile(const [], today), 'diag-20261110-00.jsonl');
      final small = [const DiagFileInfo('diag-20261110-00.jsonl', 1000, 0)];
      expect(DiagFiles.currentFile(small, today), 'diag-20261110-00.jsonl');
      final full = [const DiagFileInfo('diag-20261110-00.jsonl', DiagFiles.maxFileBytes, 0)];
      expect(DiagFiles.currentFile(full, today, pendingBytes: 10), 'diag-20261110-01.jsonl');
      final gz = [const DiagFileInfo('diag-20261110-00.jsonl.gz', 100, 0)];
      expect(DiagFiles.currentFile(gz, today), 'diag-20261110-01.jsonl');
    });

    test('keeps the last 7 days, compresses closed files', () {
      final files = [
        for (var d = 1; d <= 10; d++) DiagFileInfo('diag-202611${d.toString().padLeft(2, '0')}-00.jsonl', 1000, 0),
        const DiagFileInfo('other.txt', 5, 0),
      ];
      final plan = DiagFiles.plan(files, today: today, current: 'diag-20261110-00.jsonl');
      expect(plan.delete, ['diag-20261101-00.jsonl', 'diag-20261102-00.jsonl', 'diag-20261103-00.jsonl']);
      expect(plan.compress.length, 6);
      expect(plan.compress, isNot(contains('diag-20261110-00.jsonl')));
      expect(plan.delete, isNot(contains('other.txt')));
    });

    test('the total stays under 20 MB, oldest first, never the current file', () {
      const mb = 1024 * 1024;
      final files = [
        const DiagFileInfo('diag-20261108-00.jsonl.gz', 9 * mb, 0),
        const DiagFileInfo('diag-20261109-00.jsonl.gz', 9 * mb, 0),
        const DiagFileInfo('diag-20261110-00.jsonl', 2 * mb + 1, 0),
        const DiagFileInfo('diag-20261110-01.jsonl', 1 * mb, 0),
      ];
      final plan = DiagFiles.plan(files, today: today, current: 'diag-20261110-01.jsonl');
      expect(plan.delete, ['diag-20261108-00.jsonl.gz']);
      expect(plan.compress, ['diag-20261110-00.jsonl']);
    });

    test('bundle picks the newest files within the budget', () {
      final files = [
        const DiagFileInfo('diag-20261108-00.jsonl.gz', 3000, 0),
        const DiagFileInfo('diag-20261109-00.jsonl.gz', 3000, 0),
        const DiagFileInfo('diag-20261110-00.jsonl', 8000, 0),
      ];
      final pick = DiagFiles.forBundle(files, budgetBytes: 4500);
      expect(pick.map((f) => f.name).toList(), ['diag-20261110-00.jsonl', 'diag-20261109-00.jsonl.gz']);
      final since = DiagFiles.forBundle(files, budgetBytes: 1 << 30, sinceDay: '20261109');
      expect(since.length, 2);
    });
  });

  group('GPS summary and sampler', () {
    test('one summary per 30 s window', () {
      final g = GpsDiagSummary();
      Map<String, Object?>? out;
      for (var i = 0; i <= 30; i++) {
        out = g.add(tMs: 1000 + i * 1000, accuracyM: i == 10 ? 40 : 5, rejected: i == 5, kmh: 60) ?? out;
      }
      expect(out, isNotNull);
      expect(out!['fixes'], 31);
      expect(out['rejected'], 1);
      expect(out['accP50'], 5);
      expect(out['accMax'], 40);
      expect(out['maxGapMs'], 1000);
    });

    test('sampler lets one event per key through per window', () {
      final s = DiagSampler(every: const Duration(seconds: 10));
      expect(s.take('a', 0), isTrue);
      expect(s.take('a', 5000), isFalse);
      expect(s.take('b', 5000), isTrue);
      expect(s.take('a', 10000), isTrue);
    });

    test('level gate', () {
      expect(DiagLevelGate.allows(DiagLevel.info, detailedUntilMs: 0, nowMs: 5), isTrue);
      expect(DiagLevelGate.allows(DiagLevel.debug, detailedUntilMs: 0, nowMs: 5), isFalse);
      expect(DiagLevelGate.untilFrom(0), 24 * 3600 * 1000);
    });
  });
}
