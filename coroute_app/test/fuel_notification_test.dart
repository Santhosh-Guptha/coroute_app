import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/notify/fuel_notification.dart';
import 'package:coroute_app/data/models/route_essential.dart';
import 'route_essentials_test.dart' as fixture;
void main() {
  FuelNotification build({bool current = true, bool online = true, bool uncertain = false,
      int age = 0, double from = 0, double? usable = 2, bool data = true}) => FuelNotification.build(
        snapshot: data ? EssentialsSnapshot.fromJson(fixture.response()) : null,
        progressM: from, usableKm: usable, uncertain: uncertain, online: online,
        currentPosition: current, now: fixture.t0 + age);
  test('route line is from self and warning uses road access distance', () {
    final result = build(); expect(result.line, startsWith('You →')); expect(result.warning, true);
    expect(result.detail, contains('exceeds estimate'));
  });
  test('stale offline uncertain and passed-access data never creates a fresh fuel warning', () {
    expect(build(age: 1800000).warning, false);
    expect(build(online: false).warning, false);
    expect(build(uncertain: true).warning, false);
    expect(build(from: 9500).warning, false);
    expect(build(current: false).line, contains('waiting for location'));
  });
  test('missing data and profile stay explicitly unknown', () {
    expect(build(data: false, online: false).line, contains('unavailable offline'));
    expect(build(usable: null).detail, contains('not set'));
    expect(build(from: 11000).line, contains('No upcoming mapped'));
  });
}
