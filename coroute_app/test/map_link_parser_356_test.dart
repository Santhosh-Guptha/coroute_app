import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/geo/map_link_parser.dart';

void expectPoint(MapLinkResult? r, double lat, double lng, {String? source, String? name, bool? precise}) {
  expect(r, isNotNull);
  expect(r!.hasPoint, isTrue);
  expect(r.lat!, closeTo(lat, 0.0001));
  expect(r.lng!, closeTo(lng, 0.0001));
  if (source != null) expect(r.source, equals(source));
  if (name != null) expect(r.name, equals(name));
  if (precise != null) expect(r.precise, equals(precise));
}

void expectQuery(MapLinkResult? r, String query, {String? source}) {
  expect(r, isNotNull);
  expect(r!.hasPoint, isFalse);
  expect(r.query, equals(query));
  if (source != null) expect(r.source, equals(source));
}

void main() {
  group('Google Maps', () {
    test('place link: name and the pin from the data blob (not the view centre)', () {
      final r = MapLinkParser.parse(
          'https://www.google.com/maps/place/Charminar/@17.3615636,78.4720803,17z/data=!3m1!4b1!4m6!3m5!1s0x3bcb978ad7b6f6bd:0x3d5e5b3a1cf2a9b0!8m2!3d17.3615636!4d78.4746552!16zL20vMDJ6bTc?entry=ttu');
      expectPoint(r, 17.3615636, 78.4746552, source: 'google', name: 'Charminar', precise: true);
    });

    test('place link with + and percent-encoded name', () {
      final r = MapLinkParser.parse('https://www.google.co.in/maps/place/Nandi+Hills,+Karnataka+562103/@13.3702,77.6835,14z/data=!4m6!3m5!1s0x0:0x0!8m2!3d13.3702!4d77.6835');
      expectPoint(r, 13.3702, 77.6835, name: 'Nandi Hills, Karnataka 562103');
    });

    test('place link without data blob: view centre with the name', () {
      final r = MapLinkParser.parse('https://www.google.com/maps/place/Lalbagh+Botanical+Garden/@12.9507,77.5848,16z');
      expectPoint(r, 12.9507, 77.5848, name: 'Lalbagh Botanical Garden');
    });

    test('dropped pin: the place segment is DMS', () {
      final r = MapLinkParser.parse(
          "https://www.google.com/maps/place/12%C2%B058'16.0%22N+77%C2%B035'38.0%22E/@12.9711,77.5917,17z/data=!3m1!4b1!4m4!3m3!8m2!3d12.9711111!4d77.5938889");
      expectPoint(r, 12.97111, 77.59389);
    });

    test('dropped pin: the place segment is decimal', () {
      final r = MapLinkParser.parse('https://www.google.com/maps/place/17.385044,78.486671/@17.385044,78.486671,17z');
      expectPoint(r, 17.385044, 78.486671);
    });

    test('map view only (@lat,lng,zoom) is not precise', () {
      final r = MapLinkParser.parse('https://www.google.com/maps/@12.9715987,77.5945627,15z?entry=ttu');
      expectPoint(r, 12.9715987, 77.5945627, precise: false);
    });

    test('maps.google.com/?q=lat,lng', () {
      expectPoint(MapLinkParser.parse('https://maps.google.com/?q=12.9716,77.5946'), 12.9716, 77.5946, precise: true);
      expectPoint(MapLinkParser.parse('https://maps.google.com/maps?q=-33.8688,151.2093&z=15'), -33.8688, 151.2093);
    });

    test('?q=Name searches the name', () {
      expectQuery(MapLinkParser.parse('https://maps.google.com/?q=Gateway+of+India,+Mumbai'), 'Gateway of India, Mumbai', source: 'google');
      expectQuery(MapLinkParser.parse('https://www.google.com/maps?q=Hampi&entry=gps'), 'Hampi');
    });

    test('?q=Name with a ftid and a data pin keeps the pin', () {
      final r = MapLinkParser.parse('https://www.google.com/maps?q=Golconda+Fort&ftid=0x3bcb9:0x2b&data=!3d17.3833!4d78.4011');
      expectPoint(r, 17.3833, 78.4011, name: 'Golconda Fort');
    });

    test('?ll= is a point', () {
      expectPoint(MapLinkParser.parse('https://maps.google.com/maps?ll=15.3350,76.4600&z=13&t=m'), 15.335, 76.46);
    });

    test('/maps/search/ with a name and with coordinates', () {
      expectQuery(MapLinkParser.parse('https://www.google.com/maps/search/petrol+pump+near+Kurnool/@15.82,78.03,13z'), 'petrol pump near Kurnool');
      expectPoint(MapLinkParser.parse('https://www.google.com/maps/search/12.9716,+77.5946?entry=tts'), 12.9716, 77.5946);
      expectPoint(MapLinkParser.parse('https://www.google.com/maps/search/?api=1&query=28.6129,77.2295'), 28.6129, 77.2295);
      expectQuery(MapLinkParser.parse('https://www.google.com/maps/search/?api=1&query=India+Gate'), 'India Gate');
    });

    test('/maps/dir/ takes the destination', () {
      final r = MapLinkParser.parse(
          'https://www.google.com/maps/dir/Bengaluru,+Karnataka/Mysore+Palace,+Mysuru/@12.6,76.9,9z/data=!3m1!4b1!4m14!4m13!1m5!1m1!1s0x0:0x0!2m2!1d77.5946!2d12.9716!1m5!1m1!1s0x0:0x0!2m2!1d76.6552!2d12.3052!3e0');
      expectPoint(r, 12.3052, 76.6552, name: 'Mysore Palace, Mysuru');
      expectPoint(MapLinkParser.parse('https://www.google.com/maps/dir/12.97,77.59/13.3702,77.6835/'), 13.3702, 77.6835);
      expectPoint(MapLinkParser.parse('https://www.google.com/maps/dir/?api=1&destination=13.0827,80.2707&travelmode=driving'), 13.0827, 80.2707);
      expectQuery(MapLinkParser.parse('https://www.google.com/maps/dir/?api=1&destination=Marina+Beach'), 'Marina Beach');
      expectQuery(MapLinkParser.parse('https://www.google.com/maps/dir/My+Location/Coorg/'), 'Coorg');
    });

    test('short links need the gateway', () {
      final a = MapLinkParser.parse('https://maps.app.goo.gl/xH7rQ9pVbN2kLmT8A');
      expect(a, isNotNull);
      expect(a!.needsExpansion, isTrue);
      expect(a.shortUrl, equals('https://maps.app.goo.gl/xH7rQ9pVbN2kLmT8A'));
      final b = MapLinkParser.parse('https://goo.gl/maps/AbCdEf12345');
      expect(b!.needsExpansion, isTrue);
      expect(MapLinkParser.parse('maps.app.goo.gl/xH7rQ9pVbN2kLmT8A')!.needsExpansion, isTrue);
      expect(MapLinkParser.parse('https://goo.gl/AbCdEf'), isNull); // not a maps short link
    });

    test('shared text: name line + short link', () {
      final r = MapLinkParser.parse('Charminar\nCharminar Rd, Char Kaman, Ghansi Bazaar, Hyderabad, Telangana 500002\nhttps://maps.app.goo.gl/xH7rQ9pVbN2kLmT8A');
      expect(r!.needsExpansion, isTrue);
      expect(r.name, equals('Charminar'));
      expect(r.query, equals('Charminar'));
    });

    test('shared text: name + full link keeps the link name', () {
      final r = MapLinkParser.parse('Check out this place https://www.google.com/maps/place/Cubbon+Park/@12.9763,77.5929,16z/data=!3d12.9763!4d77.5929.');
      expectPoint(r, 12.9763, 77.5929, name: 'Cubbon Park');
    });

    test('shared text: coordinates link gets the label', () {
      final r = MapLinkParser.parse('Meeting point - https://maps.google.com/?q=17.2403,78.4294');
      expectPoint(r, 17.2403, 78.4294, name: 'Meeting point');
    });
  });

  group('geo: URIs', () {
    test('geo:lat,lng', () => expectPoint(MapLinkParser.parse('geo:12.9716,77.5946'), 12.9716, 77.5946, source: 'geo'));
    test('geo with uncertainty and q label', () {
      expectPoint(MapLinkParser.parse('geo:12.9716,77.5946;u=35?q=Vidhana+Soudha'), 12.9716, 77.5946, name: 'Vidhana Soudha');
    });
    test('geo:0,0?q=lat,lng(Label)', () {
      expectPoint(MapLinkParser.parse('geo:0,0?q=17.3616,78.4747(Charminar)'), 17.3616, 78.4747, name: 'Charminar');
    });
    test('geo:0,0?q=Name searches', () => expectQuery(MapLinkParser.parse('geo:0,0?q=Hussain+Sagar'), 'Hussain Sagar', source: 'geo'));
  });

  group('Apple, OSM, Waze', () {
    test('Apple Maps ll + q', () {
      expectPoint(MapLinkParser.parse('https://maps.apple.com/?ll=12.9763,77.5929&q=Cubbon%20Park&t=m'), 12.9763, 77.5929, source: 'apple', name: 'Cubbon Park');
    });
    test('Apple Maps coordinate + name', () {
      expectPoint(MapLinkParser.parse('https://maps.apple.com/place?coordinate=19.0760,72.8777&name=Mumbai'), 19.076, 72.8777, name: 'Mumbai');
    });
    test('Apple Maps address only', () => expectQuery(MapLinkParser.parse('https://maps.apple.com/?address=MG%20Road,%20Bengaluru'), 'MG Road, Bengaluru'));
    test('Apple Maps q with search area only searches', () => expectQuery(MapLinkParser.parse('https://maps.apple.com/?q=Coffee&sll=12.97,77.59'), 'Coffee'));
    test('OSM marker', () {
      expectPoint(MapLinkParser.parse('https://www.openstreetmap.org/?mlat=12.97160&mlon=77.59460#map=17/12.97160/77.59460'), 12.9716, 77.5946, source: 'osm', precise: true);
    });
    test('OSM map view', () {
      expectPoint(MapLinkParser.parse('https://www.openstreetmap.org/#map=15/17.3850/78.4867'), 17.385, 78.4867, precise: false);
      expectPoint(MapLinkParser.parse('https://www.openstreetmap.org/search?query=hampi#map=12/15.3350/76.4600'), 15.335, 76.46, precise: false);
    });
    test('Waze ul?ll=', () {
      expectPoint(MapLinkParser.parse('https://waze.com/ul?ll=12.9716,77.5946&navigate=yes'), 12.9716, 77.5946, source: 'waze');
      expectPoint(MapLinkParser.parse('https://www.waze.com/ul?ll=12.9716%2C77.5946&navigate=yes&zoom=17'), 12.9716, 77.5946);
      expectPoint(MapLinkParser.parse('https://www.waze.com/live-map/directions?to=ll.13.0827%2C80.2707'), 13.0827, 80.2707);
      expectQuery(MapLinkParser.parse('https://waze.com/ul?q=Ooty%20Lake'), 'Ooty Lake');
    });
  });

  group('plain coordinates', () {
    test('comma, space, semicolon, letters', () {
      expectPoint(MapLinkParser.parse('12.97, 77.59'), 12.97, 77.59, source: 'coords');
      expectPoint(MapLinkParser.parse('12.97 77.59'), 12.97, 77.59);
      expectPoint(MapLinkParser.parse('(12.9716; 77.5946)'), 12.9716, 77.5946);
      expectPoint(MapLinkParser.parse('12.9716N, 77.5946E'), 12.9716, 77.5946);
      expectPoint(MapLinkParser.parse('33.8688 S, 151.2093 E'), -33.8688, 151.2093);
      expectPoint(MapLinkParser.parse('77.5946E, 12.9716N'), 12.9716, 77.5946);
      expectPoint(MapLinkParser.parse('lat: 12.9716 lng: 77.5946'), 12.9716, 77.5946);
    });
    test('DMS', () {
      expectPoint(MapLinkParser.parse('12°58\'16"N 77°35\'38"E'), 12.97111, 77.59389, source: 'dms');
      expectPoint(MapLinkParser.parse('17°23\'06.2"N 78°29\'12.0"E'), 17.38506, 78.48667);
    });
    test('plus code', () {
      final r = MapLinkParser.parse('7J4VXHFR+2C');
      expect(r, isNotNull);
      expect(r!.source, equals('pluscode'));
      expect(r.lat!, closeTo(12.9726, 0.001));
      expect(r.lng!, closeTo(77.5911, 0.001));
      final hq = MapLinkParser.decodePlusCode('849VCWC8+R9')!; // the Open Location Code reference example
      expect(hq.$1, closeTo(37.4220625, 0.000001));
      expect(hq.$2, closeTo(-122.0840625, 0.000001));
      final withTown = MapLinkParser.parse('7J4VXHFR+2C Bengaluru, Karnataka');
      expect(withTown!.name, equals('Bengaluru, Karnataka'));
    });
    test('out of range, zero and ordinary text are rejected', () {
      expect(MapLinkParser.parse('95.0, 77.59'), isNull);
      expect(MapLinkParser.parse('12.97, 190.5'), isNull);
      expect(MapLinkParser.parse('0.0, 0.0'), isNull);
      expect(MapLinkParser.parse('Sector 21 22'), isNull);
      expect(MapLinkParser.parse('NH 44 Kurnool'), isNull);
      expect(MapLinkParser.parse('Charminar'), isNull);
      expect(MapLinkParser.parse(''), isNull);
      expect(MapLinkParser.parse('https://example.com/?q=12.97,77.59'), isNull);
      expect(MapLinkParser.parse('https://maps.google.com/?q=95.1,77.5'), isNull);
      expect(MapLinkParser.decodePlusCode('7J4V+2C'), isNull);
    });
  });
}
