import 'package:coroute_app/domain/safety/speed_audio_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SpeedAudioPolicy.levelFor', () {
    test('tiers by how far over the limit', () {
      expect(SpeedAudioPolicy.levelFor(60, 60), SpeedAudioLevel.normal);
      expect(SpeedAudioPolicy.levelFor(65, 60), SpeedAudioLevel.normal); // 8 %
      expect(SpeedAudioPolicy.levelFor(66, 60), SpeedAudioLevel.duck60); // 10 %
      expect(SpeedAudioPolicy.levelFor(75, 60), SpeedAudioLevel.duck30); // 25 %
      expect(SpeedAudioPolicy.levelFor(84, 60), SpeedAudioLevel.pause); // 40 %
      expect(SpeedAudioPolicy.levelFor(120, 0), SpeedAudioLevel.normal); // no limit
      expect(SpeedAudioPolicy.levelFor(double.nan, 60), SpeedAudioLevel.normal);
    });
  });

  group('SpeedAudioPolicy episodes', () {
    test('nothing before 4 s over the limit, then ducks', () {
      final p = SpeedAudioPolicy();
      expect(p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 0), isNull);
      expect(p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 2000), isNull);
      expect(p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 3999), isNull);
      expect(p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 4000), const SpeedAudioCommand.apply(SpeedAudioLevel.duck60));
      expect(p.applied, SpeedAudioLevel.duck60);
      // Same level again: no new command.
      expect(p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 5000), isNull);
    });

    test('a short dip under the limit restarts the 4 s hold', () {
      final p = SpeedAudioPolicy();
      p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 0);
      p.onSample(speedKmh: 59, limitKmh: 60, nowMs: 2000);
      expect(p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 3000), isNull);
      expect(p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 6500), isNull);
      expect(p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 7000), const SpeedAudioCommand.apply(SpeedAudioLevel.duck60));
    });

    test('escalates to 30 % and pause, never back up within the episode', () {
      final p = SpeedAudioPolicy();
      p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 0);
      expect(p.onSample(speedKmh: 76, limitKmh: 60, nowMs: 4000), const SpeedAudioCommand.apply(SpeedAudioLevel.duck30));
      expect(p.onSample(speedKmh: 90, limitKmh: 60, nowMs: 5000), const SpeedAudioCommand.apply(SpeedAudioLevel.pause));
      // Slower but still over: stays paused.
      expect(p.onSample(speedKmh: 67, limitKmh: 60, nowMs: 6000), isNull);
      expect(p.applied, SpeedAudioLevel.pause);
    });

    test('far over at once still waits 4 s, then pauses directly', () {
      final p = SpeedAudioPolicy();
      expect(p.onSample(speedKmh: 100, limitKmh: 60, nowMs: 0), isNull);
      expect(p.onSample(speedKmh: 100, limitKmh: 60, nowMs: 4000), const SpeedAudioCommand.apply(SpeedAudioLevel.pause));
    });

    test('restores 5 s after being 3 km/h under the limit (hysteresis)', () {
      final p = SpeedAudioPolicy();
      p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 0);
      p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 4000);
      // At the limit but not 3 km/h under: does not count.
      expect(p.onSample(speedKmh: 59, limitKmh: 60, nowMs: 5000), isNull);
      expect(p.onSample(speedKmh: 58, limitKmh: 60, nowMs: 20000), isNull);
      expect(p.onSample(speedKmh: 57, limitKmh: 60, nowMs: 21000), isNull);
      expect(p.onSample(speedKmh: 55, limitKmh: 60, nowMs: 25999), isNull);
      expect(p.onSample(speedKmh: 55, limitKmh: 60, nowMs: 26000), SpeedAudioCommand.restore);
      expect(p.applied, SpeedAudioLevel.normal);
      expect(p.onSample(speedKmh: 55, limitKmh: 60, nowMs: 30000), isNull);
    });

    test('going over again during the restore wait keeps the music lowered', () {
      final p = SpeedAudioPolicy();
      p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 0);
      p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 4000);
      p.onSample(speedKmh: 50, limitKmh: 60, nowMs: 5000);
      p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 8000);
      expect(p.onSample(speedKmh: 50, limitKmh: 60, nowMs: 11000), isNull);
      expect(p.applied, SpeedAudioLevel.duck60);
      expect(p.onSample(speedKmh: 50, limitKmh: 60, nowMs: 16000), SpeedAudioCommand.restore);
    });

    test('the rider changed the volume: no more changes and no restore (forget)', () {
      final p = SpeedAudioPolicy();
      p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 0);
      p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 4000);
      p.noteUserAdjusted();
      expect(p.userOverride, isTrue);
      expect(p.onSample(speedKmh: 95, limitKmh: 60, nowMs: 6000), isNull); // no escalation
      p.onSample(speedKmh: 50, limitKmh: 60, nowMs: 7000);
      expect(p.onSample(speedKmh: 50, limitKmh: 60, nowMs: 12000), SpeedAudioCommand.forget);
      expect(p.userOverride, isFalse);
    });

    test('user change without anything lowered is ignored', () {
      final p = SpeedAudioPolicy();
      p.noteUserAdjusted();
      expect(p.userOverride, isFalse);
    });

    test('setting off, SOS or no limit restore at once', () {
      for (final args in [
        (enabled: false, emergency: false, limit: 60),
        (enabled: true, emergency: true, limit: 60),
        (enabled: true, emergency: false, limit: 0),
      ]) {
        final p = SpeedAudioPolicy();
        p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 0);
        p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 4000);
        expect(p.onSample(speedKmh: 70, limitKmh: args.limit, nowMs: 4500, enabled: args.enabled, emergency: args.emergency),
            SpeedAudioCommand.restore);
      }
    });

    test('end() with nothing lowered returns null; ride end restores', () {
      final p = SpeedAudioPolicy();
      expect(p.end(), isNull);
      p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 0);
      p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 4000);
      expect(p.end(), SpeedAudioCommand.restore);
      expect(p.end(), isNull);
    });

    test('a missing speed keeps the state', () {
      final p = SpeedAudioPolicy();
      p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 0);
      p.onSample(speedKmh: 70, limitKmh: 60, nowMs: 4000);
      expect(p.onSample(speedKmh: double.nan, limitKmh: 60, nowMs: 5000), isNull);
      expect(p.applied, SpeedAudioLevel.duck60);
    });
  });
}
