import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/privacy/private_places.dart';
import 'package:coroute_app/domain/intel/intel_event.dart';

/// v3.63 privacy zones: per-place radius, live position masking with exit hysteresis, the emergency
/// override (SOS / crash alarm always share the exact position), and the recorded-route / road-data trims.
void main() {
  const home = PrivatePlace(label: 'Home', lat: 17.4000, lng: 78.5000, radiusM: 500);
  const work = PrivatePlace(label: 'Work', lat: 17.4500, lng: 78.4000); // saved before v3.63: 300 m
  final places = [home, work];
  // ~111 m per 0.001 degree of latitude.
  double north(double m) => 17.4000 + m / 111195.0;

  test('each place has its own radius; old places keep 300 m; JSON round trip', () {
    expect(PrivatePlaces.isNear(places, north(450), 78.5), isTrue, reason: '450 m from home (500 m zone)');
    expect(PrivatePlaces.isNear(places, north(520), 78.5), isFalse);
    expect(PrivatePlaces.isNear(places, 17.4500 + 350 / 111195.0, 78.4), isFalse, reason: 'work is 300 m');
    final back = PrivatePlaces.decode(PrivatePlaces.encode(places));
    expect(back.first.radiusM, 500);
    expect(back.last.radiusM, 300);
    expect(PrivatePlaces.decode('[{"l":"X","a":17.1,"o":78.1,"r":777}]').first.radiusM, 300, reason: 'unknown radius falls back to 300 m');
    expect(PrivatePlaces.isNear(places, 0, 0), isFalse);
  });

  test('live mask: hidden inside, stays hidden 50 m past the edge, visible beyond', () {
    final m = LivePrivacyMask();
    expect(m.update(places, north(100), 78.5, emergency: false, nowMs: 1000), isTrue);
    expect(m.hiddenSinceMs, 1000);
    expect(m.update(places, north(530), 78.5, emergency: false, nowMs: 2000), isTrue, reason: 'within the 50 m exit margin');
    expect(m.update(places, north(560), 78.5, emergency: false, nowMs: 3000), isFalse);
    expect(m.hiddenSinceMs, isNull);
    expect(m.update(places, north(530), 78.5, emergency: false, nowMs: 4000), isFalse, reason: 'entering needs the real radius');
    expect(LivePrivacyMask.shared(true, 17.4, 78.5), (0.0, 0.0));
    expect(LivePrivacyMask.shared(false, 17.4, 78.5), (17.4, 78.5));
  });

  test('SAFETY: an emergency always shares the exact position, also inside a zone, and reveals it at once', () {
    final m = LivePrivacyMask();
    expect(m.update(places, 17.4000, 78.5000, emergency: false), isTrue, reason: 'at home, no emergency: hidden');
    expect(m.update(places, 17.4000, 78.5000, emergency: true), isFalse, reason: 'SOS / crash alarm: exact position');
    expect(LivePrivacyMask.shared(m.hidden, 17.4000, 78.5000), (17.4000, 78.5000));
    expect(m.update(places, 17.4000, 78.5000, emergency: true), isFalse, reason: 'stays exact for the whole emergency');
    expect(m.update(places, 17.4000, 78.5000, emergency: false), isTrue, reason: 'hidden again after the emergency');
  });

  test('no places or no fix: never hidden (nothing to hide, nothing stuck)', () {
    final m = LivePrivacyMask();
    expect(m.update(const [], 17.4, 78.5, emergency: false), isFalse);
    expect(m.update(places, 17.4, 78.5, emergency: false), isTrue);
    expect(m.update(places, 0, 0, emergency: false), isTrue, reason: 'a fix without a position keeps the last state');
    expect(m.update(const [], 17.4, 78.5, emergency: false), isFalse, reason: 'all places removed: visible');
  });

  test('recorded route and road data: nothing inside a zone is kept', () {
    final pts = [(north(100), 78.5), (north(450), 78.5), (north(900), 78.5), (17.46, 78.4)];
    final kept = PrivatePlaces.trim(places, pts, (p) => p);
    expect(kept, [(north(900), 78.5), (17.46, 78.4)]);
    final q = IntelEventQueue()..isPrivate = (lat, lng) => PrivatePlaces.isNear(places, lat, lng);
    q.startRide();
    q.onFix(17.30, 78.30);
    expect(q.add(IntelEvent(type: IntelEventType.values.first, gh: 'tepg', hb: 0, sb: 0, lat: north(450), lng: 78.5, ts: 1)), isFalse, reason: '450 m from home: dropped');
    expect(q.add(IntelEvent(type: IntelEventType.values.first, gh: 'tepg', hb: 0, sb: 0, lat: 17.35, lng: 78.45, ts: 2)), isTrue);
  });
}
