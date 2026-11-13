import 'package:coroute_app/domain/privacy/private_places.dart';
import 'package:flutter_test/flutter_test.dart';

/// 3.56 (round 6): private places (kept on the phone; rides hidden within 300 m).
void main() {
  const home = PrivatePlace(label: 'Home', lat: 17.4000, lng: 78.5000);
  const work = PrivatePlace(label: 'Work', lat: 17.4500, lng: 78.4000);

  test('inside 300 m is hidden, outside is not', () {
    final places = [home, work];
    expect(PrivatePlaces.isNear(places, 17.4000, 78.5000), isTrue);
    expect(PrivatePlaces.isNear(places, 17.4020, 78.5000), isTrue, reason: '222 m north');
    expect(PrivatePlaces.isNear(places, 17.4030, 78.5000), isFalse, reason: '333 m north');
    expect(PrivatePlaces.isNear(places, 17.4500, 78.4010), isTrue, reason: 'near work');
    expect(PrivatePlaces.isNear(const [], 17.4, 78.5), isFalse);
    expect(PrivatePlaces.isNear(places, double.nan, 78.5), isFalse);
  });

  test('a ride that starts at home: the recorded route begins outside the circle', () {
    // North from home, 111 m per point.
    final ride = [for (var i = 0; i < 10; i++) (17.4 + i * 0.001, 78.5)];
    final kept = PrivatePlaces.trim<(double, double)>([home], ride, (p) => p);
    expect(kept.length, 7);
    expect(kept.first.$1, closeTo(17.403, 1e-9));
    expect(PrivatePlaces.trim<(double, double)>(const [], ride, (p) => p), same(ride));
  });

  test('at most three, and storage round trip skips broken entries', () {
    var list = <PrivatePlace>[];
    for (var i = 0; i < 3; i++) {
      list = PrivatePlaces.add(list, PrivatePlace(label: 'P$i', lat: 17.0 + i, lng: 78.0))!;
    }
    expect(PrivatePlaces.add(list, home), isNull);
    final back = PrivatePlaces.decode(PrivatePlaces.encode(list));
    expect(back.length, 3);
    expect(back[1].label, 'P1');
    expect(back[2].lat, 19.0);
    expect(PrivatePlaces.decode('not json'), isEmpty);
    expect(PrivatePlaces.decode(null), isEmpty);
    expect(PrivatePlaces.decode('{"a":1}'), isEmpty);
    final mixed = PrivatePlaces.decode('[{"l":"ok","a":17.4,"o":78.5},{"l":"zero","a":0,"o":0},{"l":"bad","a":"x","o":1},{"l":"far","a":95,"o":1},7]');
    expect(mixed.length, 1);
    expect(mixed.single.label, 'ok');
    final five = PrivatePlaces.decode('[${List.filled(5, '{"l":"x","a":17.4,"o":78.5}').join(',')}]');
    expect(five.length, 3);
    expect(PrivatePlace.fromJson({'l': 'x' * 60, 'a': 1.0, 'o': 1.0})!.label.length, 24);
  });
}
