// 3.55 "Navigate in Google Maps / Mappls" (lib/domain/navigation/nav_handoff.dart): the links and
// the order they are tried in (rider's choice, installed apps, two-wheeler mode).
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/domain/navigation/nav_handoff.dart';

void main() {
  const lat = 17.5, lng = 78.5;

  group('links', () {
    test('Google Maps turn-by-turn: two-wheeler mode=l, car mode=d', () {
      expect(NavHandoff.googleNavigation(lat, lng).toString(), 'google.navigation:q=17.500000,78.500000&mode=l');
      expect(NavHandoff.googleNavigation(lat, lng, twoWheeler: false).toString(), 'google.navigation:q=17.500000,78.500000&mode=d');
    });

    test('Google Maps web link: travelmode two-wheeler / driving, navigate', () {
      final u = NavHandoff.googleWeb(lat, lng);
      expect(u.host, 'www.google.com');
      expect(u.path, '/maps/dir/');
      expect(u.queryParameters['api'], '1');
      expect(u.queryParameters['destination'], '17.500000,78.500000');
      expect(u.queryParameters['travelmode'], 'two-wheeler');
      expect(u.queryParameters['dir_action'], 'navigate');
      expect(NavHandoff.googleWeb(lat, lng, twoWheeler: false).queryParameters['travelmode'], 'driving');
    });

    test('Mappls https direction link and geo: with a clean label', () {
      final m = NavHandoff.mappls(lat, lng);
      expect(m.scheme, 'https');
      expect(m.host, 'www.mappls.com');
      expect(m.queryParameters['places'], '17.500000,78.500000');
      final g = NavHandoff.geo(lat, lng, label: 'Fort (old)\nLake');
      expect(g.scheme, 'geo');
      expect(g.toString(), startsWith('geo:17.500000,78.500000?q=17.500000,78.500000('));
      expect(g.toString(), isNot(contains('\n')));
      expect(NavHandoff.geo(lat, lng).toString(), 'geo:17.500000,78.500000?q=17.500000,78.500000');
    });

    test('valid targets', () {
      expect(NavHandoff.validTarget(lat, lng), isTrue);
      expect(NavHandoff.validTarget(0, 0), isFalse);
      expect(NavHandoff.validTarget(double.nan, 1), isFalse);
      expect(NavHandoff.validTarget(91, 1), isFalse);
      expect(NavHandoff.validTarget(1, double.infinity), isFalse);
      expect(NavHandoff.plan(0, 0), isEmpty);
    });

    test('two-wheeler unless a car kind', () {
      expect(NavHandoff.isTwoWheeler(''), isTrue);
      expect(NavHandoff.isTwoWheeler('cruiser'), isTrue);
      expect(NavHandoff.isTwoWheeler('Car'), isFalse);
      expect(NavHandoff.isTwoWheeler('suv'), isFalse);
    });
  });

  group('plan', () {
    String s(NavLink l) => '${l.uri.scheme}${l.package == null ? '' : '@${l.package}'}';

    test('Automatic, apps unknown: google.navigation, geo:, Google Maps web (as before)', () {
      final p = NavHandoff.plan(lat, lng);
      expect(p.map(s), ['google.navigation', 'geo', 'https']);
      expect(p.first.uri.toString(), contains('mode=l'));
      expect(p.last.uri.host, 'www.google.com');
    });

    test('Automatic: Google Maps installed first, else Mappls, else any map app', () {
      expect(NavHandoff.plan(lat, lng, googleInstalled: true, mapplsInstalled: true).map(s),
          ['google.navigation@${NavHandoff.googlePackage}', 'https@${NavHandoff.mapplsPackage}', 'geo', 'https']);
      expect(NavHandoff.plan(lat, lng, googleInstalled: false, mapplsInstalled: true).map(s), ['https@${NavHandoff.mapplsPackage}', 'geo', 'https']);
      expect(NavHandoff.plan(lat, lng, googleInstalled: false, mapplsInstalled: false).map(s), ['geo', 'https']);
    });

    test('Always Google Maps: turn-by-turn, then its web link in the app, then the rest', () {
      final p = NavHandoff.plan(lat, lng, choice: NavApp.google, googleInstalled: true, mapplsInstalled: false);
      expect(p.map(s), ['google.navigation@${NavHandoff.googlePackage}', 'https@${NavHandoff.googlePackage}', 'geo', 'https']);
      final missing = NavHandoff.plan(lat, lng, choice: NavApp.google, googleInstalled: false);
      expect(missing.map(s), ['https', 'geo'], reason: 'web link (browser) first, then any map app');
    });

    test('Always Mappls: Mappls first (package when installed), then Google, then any map app', () {
      expect(NavHandoff.plan(lat, lng, choice: NavApp.mappls, googleInstalled: true, mapplsInstalled: true).map(s),
          ['https@${NavHandoff.mapplsPackage}', 'google.navigation@${NavHandoff.googlePackage}', 'geo', 'https']);
      final unknown = NavHandoff.plan(lat, lng, choice: NavApp.mappls);
      expect(unknown.first.uri.host, 'www.mappls.com');
      expect(unknown.first.package, isNull);
    });

    test('Other app: geo: first (the phone picks), browser last', () {
      expect(NavHandoff.plan(lat, lng, choice: NavApp.other, googleInstalled: true, mapplsInstalled: true).map(s), ['geo', 'https']);
    });

    test('no duplicates', () {
      for (final c in NavApp.values) {
        for (final g in [true, false, null]) {
          for (final m in [true, false, null]) {
            final p = NavHandoff.plan(lat, lng, choice: c, googleInstalled: g, mapplsInstalled: m);
            expect(p.toSet().length, p.length, reason: '$c $g $m');
            expect(p, isNotEmpty);
          }
        }
      }
    });
  });

  test('choice parse / wire / labels', () {
    for (final a in NavApp.values) {
      expect(NavApp.parse(a.wire), a);
      expect(a.label.split(' ').length, lessThanOrEqualTo(2));
    }
    expect(NavApp.parse(null), NavApp.auto);
    expect(NavApp.parse('waze'), NavApp.auto);
  });
}
