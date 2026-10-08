import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/safety_service.dart';
import 'package:coroute_app/domain/safety/fatigue_tracker.dart';
import 'package:coroute_app/domain/safety/solo_check_in.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

const int t0 = 1700000000000;
int min(num m) => t0 + (m * 60000).round();

TrackPoint fixAt(num minutes, double kmh) => TrackPoint(ts: min(minutes), lat: 12.97, lng: 77.59, speedKmh: kmh);

/// Feeds one fix every 30 s from [from] to [to] minutes; returns the minutes at which a reminder fired.
List<double> feed(FatigueTracker f, double from, double to, double kmh) {
  final out = <double>[];
  for (var m = from; m <= to + 1e-9; m += 0.5) {
    if (f.onFix(fixAt(m, kmh))) out.add(m);
  }
  return out;
}

void main() {
  group('break reminder', () {
    test('2 h of riding reminds once', () {
      final f = FatigueTracker();
      final fired = feed(f, 0, 150, 60);
      expect(fired.first, 120);
      expect(fired, hasLength(1), reason: 'next one only after 60 more minutes');
    });

    test('a 9 min stop does not count as a break', () {
      final f = FatigueTracker();
      expect(feed(f, 0, 60, 60), isEmpty);
      expect(feed(f, 60.5, 69.5, 0), isEmpty); // 9 min stopped (fixes at 0 km/h)
      final fired = feed(f, 70, 125, 60);
      expect(fired, [120]);
    });

    test('a 9 min gap without fixes does not count as a break either', () {
      final f = FatigueTracker();
      feed(f, 0, 60, 60);
      final fired = feed(f, 69, 125, 60);
      expect(fired, [120]);
    });

    test('a 10 min break starts the count again', () {
      final f = FatigueTracker();
      feed(f, 0, 100, 60);
      expect(feed(f, 100.5, 110.5, 0), isEmpty); // 10 min stopped
      final fired = feed(f, 111, 240, 60);
      expect(fired.first, closeTo(231, 0.01), reason: '2 h after riding again at 111 min');
    });

    test('a 10 min gap without fixes (parked, GPS quiet) is a break', () {
      final f = FatigueTracker();
      feed(f, 0, 100, 60);
      final fired = feed(f, 110, 235, 60);
      expect(fired.first, 230);
    });

    test('reminds again after 60 min without a break', () {
      final f = FatigueTracker();
      final fired = feed(f, 0, 245, 60);
      expect(fired, [120, 180, 240]);
    });

    test('reset forgets the stretch', () {
      final f = FatigueTracker();
      feed(f, 0, 110, 60);
      f.reset();
      expect(feed(f, 110.5, 200, 60), isEmpty);
    });
  });

  group('solo check-in', () {
    const limit = 1000.0;

    test('asks after 15 min far from the group, tells the lead after 2 more min', () {
      final c = SoloCheckIn();
      CheckInStep? last;
      for (var m = 0.0; m < 15; m += 0.25) {
        last = c.onSample(tMs: min(m), awayM: 3000, limitM: limit);
        expect(last, isNull);
      }
      expect(c.onSample(tMs: min(15), awayM: 3000, limitM: limit), CheckInStep.prompt);
      expect(c.awaitingAnswer, isTrue);
      expect(c.onSample(tMs: min(15.25), awayM: 3000, limitM: limit), isNull, reason: 'one prompt at a time');
      expect(c.onTimeout(min(16.5)), isNull, reason: 'not 2 min yet');
      expect(c.onTimeout(min(17)), CheckInStep.noReply);
      expect(c.noReplySent, isTrue);
      expect(c.onTimeout(min(18)), isNull, reason: 'told once');
    });

    test('no prompt when no other rider was seen recently', () {
      final c = SoloCheckIn();
      for (var m = 0.0; m <= 40; m += 0.25) {
        expect(c.onSample(tMs: min(m), awayM: null, limitM: limit), isNull);
      }
    });

    test('coming back within the limit resets the 15 min', () {
      final c = SoloCheckIn();
      for (var m = 0.0; m <= 10; m += 0.25) {
        c.onSample(tMs: min(m), awayM: 3000, limitM: limit);
      }
      c.onSample(tMs: min(10.25), awayM: 500, limitM: limit);
      for (var m = 10.5; m < 25.5; m += 0.25) {
        expect(c.onSample(tMs: min(m), awayM: 3000, limitM: limit), isNull);
      }
      expect(c.onSample(tMs: min(25.5), awayM: 3000, limitM: limit), CheckInStep.prompt);
    });

    test('I\'m OK after the prompt: nothing was sent; no new prompt for 30 min', () {
      final c = SoloCheckIn();
      c.onSample(tMs: min(0), awayM: 3000, limitM: limit);
      expect(c.onSample(tMs: min(15), awayM: 3000, limitM: limit), CheckInStep.prompt);
      expect(c.noReplySent, isFalse, reason: 'so the service sends nothing for this OK');
      c.answeredOk(min(15.5));
      expect(c.awaitingAnswer, isFalse);
      expect(c.onTimeout(min(18)), isNull);
      for (var m = 15.75; m < 45; m += 0.25) {
        expect(c.onSample(tMs: min(m), awayM: 3000, limitM: limit), isNull);
      }
      expect(c.onSample(tMs: min(45), awayM: 3000, limitM: limit), CheckInStep.prompt);
    });

    test('I\'m OK after the lead was told: noReplySent says an OK must be sent', () {
      final c = SoloCheckIn();
      c.onSample(tMs: min(0), awayM: 3000, limitM: limit);
      c.onSample(tMs: min(15), awayM: 3000, limitM: limit);
      expect(c.onTimeout(min(17)), CheckInStep.noReply);
      expect(c.noReplySent, isTrue);
      c.answeredOk(min(20));
      expect(c.noReplySent, isFalse);
    });

    test('back with the group before the answer was due closes the question', () {
      final c = SoloCheckIn();
      c.onSample(tMs: min(0), awayM: 3000, limitM: limit);
      c.onSample(tMs: min(15), awayM: 3000, limitM: limit);
      expect(c.awaitingAnswer, isTrue);
      c.onSample(tMs: min(16), awayM: 200, limitM: limit);
      expect(c.awaitingAnswer, isFalse);
      expect(c.onTimeout(min(17)), isNull);
    });
  });

  group('distance from the group', () {
    RiderModel r(String id, double lat, double lng, int seenMinAgo) =>
        RiderModel(userId: id, name: id, lat: lat, lng: lng, lastSeenEpochMs: min(30) - seenMinAgo * 60000);

    test('measured to the median of the riders seen in the last 5 min', () {
      final convoy = ConvoyModel(
        groupId: 'G',
        name: 'Ride',
        joinCode: '123456',
        createdByUserId: 'lead',
        createdByUserName: 'Lead',
        startLocationName: '',
        destinationName: '',
        destinationLat: 0,
        destinationLng: 0,
        createdAtEpochMs: t0,
        riders: {
          'me': r('me', 12.97, 77.59, 0),
          'a': r('a', 13.00, 77.59, 1),
          'b': r('b', 13.01, 77.59, 2),
          'c': r('c', 13.02, 77.59, 3),
          'old': r('old', 12.97, 77.59, 10), // not seen for 10 min: left out
        },
      );
      final away = SafetyService.awayFromGroup(convoy, 'me', min(30));
      expect(away, isNotNull);
      expect(away!, closeTo(0.03 * 111195, 300), reason: 'median is 13.01, nearest (a) at 13.00 is closer');
      final alone = convoy.copyWith(riders: {'me': convoy.riders['me']!, 'old': convoy.riders['old']!});
      expect(SafetyService.awayFromGroup(alone, 'me', min(30)), isNull);
    });

    // Regression (r314 behaviour test): a group split in two halves 5 km apart (say at a fuel
    // stop) put the median in the other half for EVERY rider, so everyone was asked "Are you
    // OK?" and the lead got "No reply" for each rider who did not look at the phone.
    test('a group split in two halves: nobody is alone; a lone rider still is', () {
      ConvoyModel split(Map<String, RiderModel> riders) => ConvoyModel(
            groupId: 'G',
            name: 'Ride',
            joinCode: '123456',
            createdByUserId: 'lead',
            createdByUserName: 'Lead',
            createdAtEpochMs: t0,
            riders: riders,
          );
      final halves = split({
        'me': r('me', 12.97, 77.59, 0),
        'a1': r('a1', 12.9702, 77.59, 0),
        'a2': r('a2', 12.9704, 77.59, 0),
        'b1': r('b1', 13.015, 77.59, 0),
        'b2': r('b2', 13.0152, 77.59, 0),
        'b3': r('b3', 13.0154, 77.59, 0),
      });
      expect(SafetyService.awayFromGroup(halves, 'me', min(30))!, lessThan(100));
      expect(SafetyService.awayFromGroup(halves, 'b1', min(30))!, lessThan(100));
      final lone = split({
        'me': r('me', 12.97, 77.59, 0),
        'b1': r('b1', 13.015, 77.59, 0),
        'b2': r('b2', 13.0152, 77.59, 0),
      });
      expect(SafetyService.awayFromGroup(lone, 'me', min(30))!, greaterThan(4900));
    });
  });
}
