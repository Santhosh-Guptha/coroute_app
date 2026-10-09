import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/l10n/l10n.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/weather_service.dart';

const int t0 = 1700000000000;

/// Hyderabad to Warangal, roughly: a straight line of 11 points, about 140 km.
List<(double, double)> line() => [for (var i = 0; i <= 10; i++) (17.385 + (17.978 - 17.385) * i / 10, 78.487 + (79.594 - 78.487) * i / 10)];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;
  late List<Map<String, dynamic>> requests;
  late Map<String, dynamic> Function(List<dynamic> points) answer;
  late int now;

  ApiClient api() => ApiClient(
        httpClient: MockClient((req) async {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          requests.add(body);
          if (!req.url.path.endsWith('/geo/weather')) return http.Response('{}', 404);
          final reply = answer(body['points'] as List<dynamic>);
          if (reply.containsKey('status')) return http.Response(jsonEncode({'error': 'off', 'code': 'WEATHER_OFF'}), reply['status'] as int);
          return http.Response(jsonEncode(reply), 200);
        }),
        storage: const FlutterSecureStorage(),
      );

  Map<String, dynamic> dry(List<dynamic> pts) => {
        'points': [for (final p in pts) {'lat': p['lat'], 'lng': p['lng'], 'at': p['at'], 'precipProb': 10, 'precipMm': 0, 'code': 1, 'tempC': 30}],
        'source': 'Open-Meteo',
        'attribution': 'Weather data by Open-Meteo.com (CC BY 4.0)',
      };

  Map<String, dynamic> rainFrom(List<dynamic> pts, int index, {int code = 61, int prob = 70}) {
    final r = dry(pts);
    final list = r['points'] as List<dynamic>;
    for (var i = index; i < list.length; i++) {
      (list[i] as Map<String, dynamic>)['precipProb'] = prob;
      (list[i] as Map<String, dynamic>)['code'] = code;
    }
    return r;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    L10n.setLanguage(AppLanguage.en);
    settings = SettingsService();
    await settings.load();
    requests = [];
    answer = dry;
    now = t0;
  });

  /// 10:00 UTC departure, 5 h ride: the 3 PM point is the last one.
  const departS = 1700035200; // 2023-11-15 08:00 UTC
  List<WeatherPoint> pts() => WeatherService.samplePoints(
        line: line(),
        durationS: 7 * 3600,
        departS: departS,
        namedStops: const [('Warangal', 17.978, 79.594), ('Bhongir', 17.533, 78.764)],
        destinationName: 'Warangal Fort',
      );

  test('samplePoints: start, three points along the route with ETAs, destination; names from stops within 2 km', () {
    final p = pts();
    expect(p, hasLength(5));
    expect(p.first.lat, closeTo(17.385, 0.001));
    expect(p.first.name, '');
    expect(p.first.atS, departS);
    expect(p.last.name, 'Warangal Fort');
    expect(p.last.atS, departS + 7 * 3600);
    expect(p[2].atS, departS + 7 * 3600 ~/ 2);
    expect(p[2].lat, closeTo((17.385 + 17.978) / 2, 0.01));
    // Bhongir lies about a quarter of the way: within 2 km of the first middle sample.
    expect(p[1].name, 'Bhongir');
    expect(p[3].name, '');
    expect(WeatherService.samplePoints(line: const [], durationS: 0, departS: 0, namedStops: const []), isEmpty);
  });

  test('hourText rounds to the hour', () {
    final local = DateTime.fromMillisecondsSinceEpoch(departS * 1000);
    final rounded = (local.minute >= 30 ? local.hour + 1 : local.hour) % 24;
    final expected = rounded % 12 == 0 ? 12 : rounded % 12;
    expect(WeatherService.hourText(departS), '$expected ${rounded < 12 ? 'AM' : 'PM'}');
  });

  test('rain after a named place around 3 PM', () async {
    answer = (p) => rainFrom(p, 4); // the destination point, 15:00 UTC
    final w = WeatherService(api(), settings, clock: () => now);
    final s = await w.check(pts());
    expect(s, isNotNull);
    expect(s!.rain, isTrue);
    expect(s.firstRainIndex, 4);
    // 15:00 UTC: "3 PM" on a UTC machine; the text uses the phone's local time.
    expect(s.line, 'Rain likely after Bhongir around ${WeatherService.hourText(departS + 7 * 3600)}.');
    expect(s.attribution, contains('Open-Meteo'));
    expect(requests, hasLength(1));
    expect((requests.single['points'] as List).length, 5);
    expect(w.last, same(s));
  });

  test('rain at a point whose previous point is named: that name', () async {
    answer = (p) => rainFrom(p, 2);
    final s = await WeatherService(api(), settings, clock: () => now).check(pts());
    expect(s!.line, 'Rain likely after Bhongir around ${WeatherService.hourText(departS + 7 * 3600 ~/ 2)}.');
  });

  test('rain from the start, storm wins, clear', () async {
    answer = (p) => rainFrom(p, 0);
    expect((await WeatherService(api(), settings, clock: () => now).check(pts()))!.line, 'Rain likely from the start.');
    answer = (p) {
      final r = rainFrom(p, 1);
      ((r['points'] as List)[3] as Map<String, dynamic>)['code'] = 95;
      return r;
    };
    final storm = await WeatherService(api(), settings, clock: () => now).check(pts());
    expect(storm!.line, startsWith('Thunderstorms likely near Bhongir around '));
    expect(storm.rain, isTrue);
    answer = dry;
    final clear = await WeatherService(api(), settings, clock: () => now).check(pts());
    expect(clear!.rain, isFalse);
    expect(clear.line, 'No rain expected on the route.');
    expect(clear.firstRainIndex, isNull);
  });

  test('data saver: null and no request; empty points: null', () async {
    await settings.setLowData(true);
    final w = WeatherService(api(), settings, clock: () => now);
    expect(await w.check(pts()), isNull);
    expect(requests, isEmpty);
    await settings.setLowData(false);
    expect(await w.check(const []), isNull);
    expect(requests, isEmpty);
  });

  test('gateway off (503) or all points unknown: null, nothing cached', () async {
    answer = (_) => {'status': 503};
    final w = WeatherService(api(), settings, clock: () => now);
    expect(await w.check(pts()), isNull);
    expect(w.last, isNull);
    answer = (p) => {'points': [for (final _ in p) null]};
    expect(await w.check(pts()), isNull);
    expect(requests, hasLength(2));
  });

  test('cached for 30 min per point set, one request in flight at a time', () async {
    final w = WeatherService(api(), settings, clock: () => now);
    final a = w.check(pts());
    final b = w.check(pts());
    expect(await a, same(await b));
    expect(requests, hasLength(1));
    now += 29 * 60 * 1000;
    expect(await w.check(pts()), same(await a), reason: 'cached');
    expect(requests, hasLength(1));
    now += 2 * 60 * 1000;
    expect(await w.check(pts()), isNot(same(await a)));
    expect(requests, hasLength(2));
    await w.check(pts(), force: true);
    expect(requests, hasLength(3));
  });

  test('coordinates are rounded to 2 decimals before they leave the phone', () async {
    final w = WeatherService(api(), settings, clock: () => now);
    await w.check([const WeatherPoint(lat: 17.123456, lng: 78.654321, atS: departS)]);
    final p = (requests.single['points'] as List).single as Map<String, dynamic>;
    expect(p['lat'], 17.12);
    expect(p['lng'], 78.65);
  });

  test('Hindi uses a 24 h time', () async {
    L10n.setLanguage(AppLanguage.hi);
    answer = (p) => rainFrom(p, 4);
    final s = await WeatherService(api(), settings, clock: () => now).check(pts());
    expect(s!.line, contains(':00'));
    expect(s.line, isNot(contains('PM')));
    expect(s.line, contains('Bhongir'));
    L10n.setLanguage(AppLanguage.en);
  });
}
