// Round 7 faster safety response: the one advisory warning scheduler, alert-first frame handling
// and marker glide. Pure Dart:
//   DART=/opt/dartpkg/bin/dart tool/pure_dart_test/run.sh test/safety_fast_scheduler_test.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/net/inbound_frame_sequencer.dart';
import 'package:coroute_app/domain/safety/warning_scheduler.dart';
import 'package:coroute_app/domain/tracking/nav_motion.dart';

AdvisoryWarning w(WarnKind k, [String key = 'k', int ms = 3000]) => AdvisoryWarning(kind: k, key: key, speech: 'x', estimatedSpeakMs: ms);

void main() {
  group('warning scheduler', () {
    test('priority order: hazard > curve > speed limit > falling behind > rough road > fatigue > twisty', () {
      final p = [for (final k in WarnKind.values) WarningScheduler.defaultRules[k]!.priority];
      expect(WarnKind.values.first, WarnKind.hazard);
      expect(WarnKind.values.last, WarnKind.twisty);
      for (var i = 1; i < p.length; i++) {
        expect(p[i], lessThan(p[i - 1]));
      }
    });

    test('never two voices at once: a second warning waits and is spoken when the voice is free', () {
      final s = WarningScheduler();
      expect(s.submit(w(WarnKind.roughRoad), 0), WarnOutcome.speak);
      expect(s.submit(w(WarnKind.curve, 'c1'), 1000), WarnOutcome.speakInterrupting, reason: 'a bend is far more urgent than rough road');
      expect(s.submit(w(WarnKind.hazard, 'h1'), 1500), WarnOutcome.queued, reason: 'one step more urgent: waits its turn');
      expect(s.next(2000), isNull, reason: 'the bend is still being spoken');
      expect(s.speakingAt(2000)!.kind, WarnKind.curve);
      final n = s.next(4100);
      expect(n!.kind, WarnKind.hazard);
      expect(s.next(4200), isNull);
    });

    test('a less urgent warning never interrupts; the most urgent waiting one goes first', () {
      final s = WarningScheduler();
      expect(s.submit(w(WarnKind.hazard, 'h', 4000), 0), WarnOutcome.speak);
      expect(s.submit(w(WarnKind.twisty, 't'), 100), WarnOutcome.queued);
      expect(s.submit(w(WarnKind.speedLimit, 's'), 200), WarnOutcome.queued);
      expect(s.submit(w(WarnKind.fatigue, 'f'), 300), WarnOutcome.queued);
      expect(s.queued, 3);
      expect(s.next(4000 + 2500)!.kind, WarnKind.speedLimit);
    });

    test('a waiting bend warning expires after 3 s (later would be wrong)', () {
      final s = WarningScheduler();
      s.submit(w(WarnKind.hazard, 'h', 6000), 0);
      expect(s.submit(w(WarnKind.curve, 'c'), 500), WarnOutcome.queued);
      expect(s.next(6100), isNull);
      expect(s.queued, 0);
    });

    test('rate limits: a gap per kind, the same key not repeated, at most 4 a minute (hazard and curve exempt)', () {
      final s = WarningScheduler();
      expect(s.submit(w(WarnKind.speedLimit, 'a', 1500), 0), WarnOutcome.speak);
      expect(s.submit(w(WarnKind.speedLimit, 'b', 1500), 10000), WarnOutcome.silent, reason: 'speed limit: 20 s gap');
      expect(s.submit(w(WarnKind.speedLimit, 'a', 1500), 30000), WarnOutcome.silent, reason: 'the same warning within a minute');
      expect(s.submit(w(WarnKind.speedLimit, 'b', 1500), 30000), WarnOutcome.speak);
      expect(s.submit(w(WarnKind.roughRoad, 'r', 1500), 36000), WarnOutcome.speak);
      expect(s.submit(w(WarnKind.fatigue, 'f', 1500), 42000), WarnOutcome.speak);
      expect(s.submit(w(WarnKind.twisty, 't', 1500), 48000), WarnOutcome.silent, reason: 'four spoken in this minute');
      expect(s.submit(w(WarnKind.curve, 'c', 1500), 49000), WarnOutcome.speak, reason: 'a bend is never held back by the cap');
      expect(s.submit(w(WarnKind.twisty, 't', 1500), 61000 + 30000), WarnOutcome.speak);
    });

    test('SOS / crash pre-empts at once: the queue is emptied and nothing is spoken until it is over', () {
      final s = WarningScheduler();
      s.submit(w(WarnKind.curve, 'c', 4000), 0);
      s.submit(w(WarnKind.roughRoad, 'r'), 100);
      expect(s.setEmergency(true, 500), isTrue, reason: 'the caller stops the advisory voice now');
      expect(s.queued, 0);
      expect(s.speakingAt(600), isNull);
      for (final k in WarnKind.values) {
        expect(s.submit(w(k, 'e$k'), 1000), WarnOutcome.suppressed);
      }
      expect(s.next(5000), isNull);
      expect(s.setEmergency(true, 6000), isFalse);
      expect(s.setEmergency(false, 60000), isFalse);
      expect(s.submit(w(WarnKind.hazard, 'after'), 61000), WarnOutcome.speak);
    });

    test('muted: advisories are silent; an idle scheduler has nothing to stop on an emergency', () {
      final s = WarningScheduler()..muted = true;
      expect(s.submit(w(WarnKind.hazard), 0), WarnOutcome.suppressed);
      expect(WarningScheduler().setEmergency(true, 0), isFalse);
    });

    test('speech length is estimated from the text when not given', () {
      const short = AdvisoryWarning(kind: WarnKind.curve, key: 'k', speech: 'Hi');
      const long = AdvisoryWarning(kind: WarnKind.curve, key: 'k', speech: 'Series of bends for 2 km, first one right. Slow to 30.');
      expect(short.speakMs, 1500);
      expect(long.speakMs, inInclusiveRange(4000, 5500));
    });
  });

  group('inbound frames: alerts before positions', () {
    FrameLane lane(String t) => switch (t) {
          'ALERT' || 'WAIT' || 'REPORT_DOWN' => FrameLane.alert,
          'RIDER_UPDATE' || 'RIDER_UPDATES' => FrameLane.position,
          _ => FrameLane.ordered,
        };
    String frame(String type, [int pad = 0, int n = 0]) => jsonEncode({'type': type, 'n': n, 'pad': 'x' * pad});

    test('the type is read from the head of the text without decoding', () {
      expect(InboundFrameSequencer.defaultTypeOf('{"type":"ALERT","alert":{}}'), 'ALERT');
      expect(InboundFrameSequencer.defaultTypeOf('{ "type" : "RIDER_UPDATES", "riders": []}'), 'RIDER_UPDATES');
      expect(InboundFrameSequencer.defaultTypeOf('garbage'), '');
    });

    test('small frames with nothing waiting are delivered at once, in order', () {
      final got = <String>[];
      final s = InboundFrameSequencer<Map>(laneOfType: lane, decodeSmall: (r) => jsonDecode(r) as Map, decodeBig: (r) async => jsonDecode(r) as Map, deliver: (f) => got.add('${f['type']}${f['n']}'));
      s..add(frame('RIDER_UPDATE', 0, 1))..add(frame('ALERT', 0, 2))..add(frame('MESSAGE', 0, 3));
      expect(got, ['RIDER_UPDATE1', 'ALERT2', 'MESSAGE3']);
      expect(s.idle, isTrue);
      expect(s.bigDecoded, 0);
    });

    test('while a big position batch decodes off-thread, an alert overtakes the waiting positions', () async {
      final got = <String>[];
      final gate = Completer<void>();
      final s = InboundFrameSequencer<Map>(
        laneOfType: lane,
        decodeSmall: (r) => jsonDecode(r) as Map,
        decodeBig: (r) async {
          await gate.future;
          return jsonDecode(r) as Map;
        },
        deliver: (f) => got.add('${f['type']}${f['n']}'),
        bigBytes: 1000,
      );
      s.add(frame('RIDER_UPDATES', 5000, 1)); // big: decoding
      s.add(frame('RIDER_UPDATE', 0, 2));
      s.add(frame('RIDER_UPDATE', 0, 3));
      s.add(frame('ALERT', 0, 4));
      expect(got, isEmpty);
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(got, ['RIDER_UPDATES1', 'ALERT4', 'RIDER_UPDATE2', 'RIDER_UPDATE3']);
      expect(s.overtakes, 1);
      expect(s.bigDecoded, 1);
      expect(s.idle, isTrue);
    });

    test('an alert never jumps over a snapshot or any other ordered frame', () async {
      final got = <String>[];
      final gate = Completer<void>();
      final s = InboundFrameSequencer<Map>(
        laneOfType: lane,
        decodeSmall: (r) => jsonDecode(r) as Map,
        decodeBig: (r) async {
          await gate.future;
          return jsonDecode(r) as Map;
        },
        deliver: (f) => got.add('${f['type']}${f['n']}'),
        bigBytes: 1000,
      );
      s.add(frame('SNAPSHOT', 5000, 1));
      s.add(frame('RIDER_UPDATE', 0, 2));
      s.add(frame('MESSAGE', 0, 3));
      s.add(frame('ALERT', 0, 4));
      s.add(frame('RIDER_UPDATE', 0, 5));
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(got, ['SNAPSHOT1', 'RIDER_UPDATE2', 'MESSAGE3', 'ALERT4', 'RIDER_UPDATE5']);
    });

    test('a big frame that fails to decode is dropped and the rest still flows', () async {
      final got = <String>[];
      final s = InboundFrameSequencer<Map>(laneOfType: lane, decodeSmall: (r) => jsonDecode(r) as Map, decodeBig: (r) async => throw const FormatException('bad'), deliver: (f) => got.add('${f['type']}'), bigBytes: 100);
      s..add(frame('RIDER_UPDATES', 500))..add(frame('ALERT'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(got, ['ALERT']);
      expect(s.idle, isTrue);
    });
  });

  group('marker glide (dead reckoning between reports)', () {
    const lat = 12.0, lng = 77.0;
    const step = 0.00018; // about 20 m north: 72 km/h at 1 Hz

    test('steady 1 Hz reports: the marker never stops and never jumps', () {
      final t = GlideTrack(lat, lng, 0, 0);
      var prev = t.valueAt(0).$1;
      var maxStep = 0.0, stalls = 0;
      for (var s = 1; s <= 10; s++) {
        t.retarget(lat + step * s, lng, 0, s * 1000);
        for (var ms = 0; ms < 1000; ms += 50) {
          final v = t.valueAt(s * 1000 + ms).$1;
          final d = v - prev;
          expect(d, greaterThanOrEqualTo(-1e-12), reason: 'never backwards');
          if (d > maxStep) maxStep = d;
          if (s > 2 && d < step / 200) stalls++;
          prev = v;
        }
      }
      expect(maxStep, lessThan(step * 0.12), reason: 'no jump: at most ~2 m per 50 ms at 20 m/s');
      expect(stalls, 0);
    });

    test('a late report: the plain track stands still, the glide track keeps moving, then eases in', () {
      final plain = MarkerTrack(lat, lng, 0, 0), glide = GlideTrack(lat, lng, 0, 0);
      for (final t in [plain, glide]) {
        t.retarget(lat + step, lng, 0, 1000);
        t.retarget(lat + step * 2, lng, 0, 2000);
      }
      // The next report is 600 ms late.
      expect(plain.valueAt(3000).$1, plain.valueAt(3500).$1);
      expect(plain.isAnimating(3200), isFalse);
      expect(glide.isAnimating(3200), isTrue);
      final a = glide.valueAt(3000).$1, b = glide.valueAt(3300).$1, c = glide.valueAt(3600).$1;
      expect(b, greaterThan(a));
      expect(c, greaterThan(b));
      expect(glide.coastMs, 600);
      // Coast distance is bounded: less than a third of one report's travel.
      expect(glide.valueAt(9000).$1 - (lat + step * 2), lessThan(step * 0.31));
      expect(glide.isAnimating(3700), isFalse);
      // The late report arrives: continuous from where the marker is drawn.
      final before = glide.valueAt(3600).$1;
      glide.retarget(lat + step * 3.6, lng, 0, 3600);
      expect(glide.valueAt(3600).$1, closeTo(before, 1e-12));
      expect(glide.valueAt(5200).$1, closeTo(lat + step * 3.6, step));
    });

    test('a standing rider, a teleport and an odd interval do not coast', () {
      final still = GlideTrack(lat, lng, 0, 0)..retarget(lat + 0.000005, lng, 0, 1000);
      expect(still.coastMs, 0);
      final jump = GlideTrack(lat, lng, 0, 0)..retarget(lat + 0.05, lng, 0, 1000);
      expect(jump.coastMs, 0);
      expect(jump.valueAt(1000).$1, lat + 0.05);
      final slow = GlideTrack(lat, lng, 0, 0)..retarget(lat + step, lng, 0, 8000);
      expect(slow.coastMs, 0);
    });
  });
}
