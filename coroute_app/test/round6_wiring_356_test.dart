import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 3.56 round 6: the wiring of the pending items, read from the sources (runs without a device):
/// consent for hard-brake collection, private places, "Where riders stop" on the ride map, the
/// GPS gate and the position stream restart, weather credit.
void main() {
  String read(String p) => File(p).readAsStringSync();

  test('hard brakes are queued and sent only with the road-data opt-in', () {
    final gs = read('lib/data/services/group_safety_service.dart');
    expect(gs.contains('bool Function()? roadDataConsent;'), isTrue);
    expect(gs.contains('final consent = roadDataConsent?.call() ?? false;'), isTrue, reason: 'not wired = off');
    expect(gs.contains('if (consent && !PrivatePlacesStore.shared.isNear(me.lat, me.lng))'), isTrue);
    // The flush drops instead of sending when there is no opt-in.
    final flush = gs.substring(gs.indexOf('void _flushBrakes()'));
    expect(flush.indexOf('roadDataConsent') < flush.indexOf("_api.post('/road-risk/brakes'"), isTrue);
    // The warning itself is not behind the opt-in.
    final near = gs.substring(gs.indexOf("'/road-risk/near?groupId="), gs.indexOf("'/road-risk/near?groupId=") + 200);
    expect(near.contains('roadDataConsent'), isFalse);
    expect(read('lib/main.dart').contains('..roadDataConsent = (() => safety.intel.consentOn)'), isTrue);
  });

  test('private places: recorder, road data and brakes ask the phone-only store; nothing is sent', () {
    expect(read('lib/main.dart').contains('..isPrivate = PrivatePlacesStore.shared.isNear'), isTrue);
    final rec = read('lib/data/services/track_recorder.dart');
    expect(rec.indexOf('if (isPrivate?.call(p.lat, p.lng) ?? false)') < rec.indexOf('_queue.add(gid, p)'), isTrue, reason: 'dropped before it is stored');
    expect(read('lib/data/services/intel_care_service.dart').contains('queue.zones = PrivatePlacesStore.shared.zones;'), isTrue);
    final store = read('lib/data/services/private_places_store.dart');
    for (final bad in ['ApiClient', 'http', '_api.', 'RealtimeService']) {
      expect(store.contains(bad), isFalse, reason: 'the store must not talk to the network ($bad)');
    }
    // The live position path does not consult private places (group map, guardian link, SOS).
    expect(read('lib/data/services/convoy_service.dart').contains('PrivatePlaces'), isFalse);
    expect(read('lib/data/services/safety_service.dart').contains('PrivatePlaces'), isFalse);
  });

  test('"Where riders stop" on the ride map: off by default, in the places sheet, hidden during alerts', () {
    final pref = read('lib/presentation/map_places/rider_stops_layer.dart');
    expect(pref.contains('ValueNotifier<bool>(false)'), isTrue);
    expect(pref.contains('getBool(prefKey) ?? false'), isTrue);
    expect(pref.contains('switchedOn && !alertOpen'), isTrue);
    final cockpit = read('lib/presentation/rider/live_cockpit_map_screen.dart');
    expect(cockpit.contains('riderStopsSwitch: true'), isTrue);
    expect(cockpit.contains('RiderStopsLivePref.show(switchedOn: on, alertOpen: convoy.activeAlerts.isNotEmpty)'), isTrue);
    expect(read('lib/presentation/map_places/place_chips.dart').contains("ValueKey('riderStopsLiveSwitch')"), isTrue);
  });

  test('GPS: the gate runs before the speed filter, fix age uses the phone clock, the stream is re-opened', () {
    final c = read('lib/data/services/convoy_service.dart');
    final on = c.substring(c.indexOf('void _onPosition(Position position)'));
    expect(on.indexOf('_fixGate.check(') < on.indexOf('_speedEst.update('), isTrue);
    expect(on.contains('_lastGpsFixTime = now;'), isFalse, reason: 'GPS time must not be compared with the phone clock');
    expect(RegExp(r'_lastGpsFixTime = _clock\(\);').allMatches(on).length, greaterThanOrEqualTo(3));
    expect(c.contains('onDone: _scheduleGpsRestart'), isTrue);
    expect(c.contains('if (!_isRealGpsActive || _locationRevoked || _gpsRestartTimer != null) return;'), isTrue, reason: 'one restart at a time, never against a revoked permission');
    // Timers are cancelled when tracking stops and on dispose.
    expect(RegExp(r'_gpsRestartTimer\?\.cancel\(\);').allMatches(c).length, greaterThanOrEqualTo(3));
  });

  test('weather credit names the provider the gateway used', () {
    expect(read('lib/presentation/trip_planner/trip_review_sheet.dart').contains('_weather!.attribution'), isTrue);
    expect(read('lib/core/l10n/strings_safety.dart').contains('based on data from MET Norway'), isTrue);
  });

  test('build number unchanged', () {
    expect(read('pubspec.yaml').contains('version: 3.55.0+10026'), isTrue);
  });
}
