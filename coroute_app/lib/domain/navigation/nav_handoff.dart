// 3.55 owner decision "Navigate in Google Maps / Mappls": one tap hands the turn-by-turn part of the
// ride to a navigation app while CoRoute keeps running in the background (ride tracking, intercom,
// safety; the ride notification brings the rider back).
//
// Which links are tried, in order, is decided here. Pure Dart (no Flutter, no I/O):
// test/nav_handoff_test.dart.
//
// Links used:
// * Google Maps turn-by-turn: `google.navigation:q=<lat>,<lng>&mode=l`. Documented Android intent
//   (developers.google.com/maps/documentation/urls/android-intents): mode d = drive, b = bicycle,
//   l = two-wheeler, w = walk. Where two-wheeler routing is not offered, Google Maps itself falls
//   back to driving, so `l` is safe for bikes; cars get `d`.
// * Google Maps web / app link: `https://www.google.com/maps/dir/?api=1&destination=<lat>,<lng>
//   &travelmode=two-wheeler&dir_action=navigate` (Maps URLs; travelmode accepts driving, walking,
//   bicycling, two-wheeler, transit). Opens the app when installed, else the browser.
// * Mappls (MapmyIndia, Android package `com.mmi.maps`): Mappls publishes no stable custom URL
//   scheme for third-party navigation that we could verify (a `mappls://` scheme is not documented
//   for public use). We therefore use the https web direction link
//   `https://www.mappls.com/direction?places=<lat>,<lng>`, sent to the Mappls package when it is
//   installed (the app handles its own web links); if it does not take it, the next link is tried.
// * Any map app: `geo:<lat>,<lng>?q=<lat>,<lng>(<label>)` (Android standard geo intent).

/// The rider's navigation app choice (Settings > More > "Navigation app").
enum NavApp {
  /// Google Maps when installed, else Mappls, else any map app.
  auto('auto'),

  /// "Always use Google Maps".
  google('google'),

  /// "Always use Mappls".
  mappls('mappls'),

  /// Any map app (the phone asks or uses its default).
  other('other');

  final String wire;
  const NavApp(this.wire);

  static NavApp parse(Object? raw) {
    for (final a in NavApp.values) {
      if (a.wire == raw) return a;
    }
    return NavApp.auto;
  }

  /// Settings choice labels (one or two words).
  String get label => switch (this) {
        NavApp.auto => 'Automatic',
        NavApp.google => 'Google Maps',
        NavApp.mappls => 'Mappls',
        NavApp.other => 'Other app',
      };
}

/// One link to try: [uri], sent only to [package] when set (Android), else to whatever app takes it.
class NavLink {
  final Uri uri;
  final String? package;

  const NavLink(this.uri, {this.package});

  @override
  bool operator ==(Object other) => other is NavLink && other.uri == uri && other.package == package;

  @override
  int get hashCode => Object.hash(uri, package);

  @override
  String toString() => package == null ? '$uri' : '$uri -> $package';
}

class NavHandoff {
  NavHandoff._();

  static const String googlePackage = 'com.google.android.apps.maps';
  static const String mapplsPackage = 'com.mmi.maps';

  /// Short line after a hand-off (the ride notification brings the rider back).
  static const String handedOffLine = 'Ride keeps running. Tap the ride notification to come back.';

  /// A point worth navigating to (finite, in range, not the 0,0 "no fix" placeholder).
  static bool validTarget(double lat, double lng) =>
      lat.isFinite && lng.isFinite && lat.abs() <= 90 && lng.abs() <= 180 && !(lat == 0 && lng == 0);

  static String _c(double v) => v.toStringAsFixed(6);

  /// Google Maps turn-by-turn ([twoWheeler]: mode=l, else mode=d).
  static Uri googleNavigation(double lat, double lng, {bool twoWheeler = true}) =>
      Uri.parse('google.navigation:q=${_c(lat)},${_c(lng)}&mode=${twoWheeler ? 'l' : 'd'}');

  /// Google Maps directions link (app when installed, else browser).
  static Uri googleWeb(double lat, double lng, {bool twoWheeler = true}) => Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=${_c(lat)},${_c(lng)}&travelmode=${twoWheeler ? 'two-wheeler' : 'driving'}&dir_action=navigate');

  /// Mappls directions link (see the file comment about the scheme).
  static Uri mappls(double lat, double lng) => Uri.parse('https://www.mappls.com/direction?places=${_c(lat)},${_c(lng)}');

  /// Any map app, with an optional pin label.
  static Uri geo(double lat, double lng, {String? label}) {
    final name = (label ?? '').replaceAll(RegExp(r'[()\n\r]'), ' ').trim();
    final q = name.isEmpty ? '${_c(lat)},${_c(lng)}' : '${_c(lat)},${_c(lng)}(${Uri.encodeComponent(name)})';
    return Uri.parse('geo:${_c(lat)},${_c(lng)}?q=$q');
  }

  /// Car-like vehicle kinds (garage bike types are two-wheelers unless named here).
  static bool isTwoWheeler(String vehicleKind) {
    final k = vehicleKind.trim().toLowerCase();
    return !(k == 'car' || k == 'suv' || k == 'jeep' || k == 'van' || k.startsWith('car_') || k.startsWith('4w'));
  }

  /// The links to try, best first, without duplicates.
  ///
  /// [googleInstalled] / [mapplsInstalled]: what the phone reported; null when unknown (no native
  /// check, e.g. tests or iOS), then links are tried without a package, as before.
  static List<NavLink> plan(
    double lat,
    double lng, {
    String? label,
    NavApp choice = NavApp.auto,
    bool? googleInstalled,
    bool? mapplsInstalled,
    bool twoWheeler = true,
  }) {
    if (!validTarget(lat, lng)) return const [];
    final gNav = googleNavigation(lat, lng, twoWheeler: twoWheeler);
    final gWeb = googleWeb(lat, lng, twoWheeler: twoWheeler);
    final mWeb = mappls(lat, lng);
    final anyMap = geo(lat, lng, label: label);

    final google = <NavLink>[
      if (googleInstalled == true) NavLink(gNav, package: googlePackage),
      if (googleInstalled == null) NavLink(gNav),
    ];
    final mapplsLinks = <NavLink>[
      if (mapplsInstalled == true) NavLink(mWeb, package: mapplsPackage),
    ];
    final out = <NavLink>[];
    switch (choice) {
      case NavApp.auto:
        out..addAll(google)..addAll(mapplsLinks);
        break;
      case NavApp.google:
        out
          ..addAll(google)
          ..add(googleInstalled == false ? NavLink(gWeb) : NavLink(gWeb, package: googleInstalled == true ? googlePackage : null))
          ..addAll(mapplsLinks);
        break;
      case NavApp.mappls:
        // Chosen but not detected (or unknown): the Mappls web link still opens Mappls or the browser.
        out
          ..add(mapplsInstalled == true ? NavLink(mWeb, package: mapplsPackage) : NavLink(mWeb))
          ..addAll(google);
        break;
      case NavApp.other:
        break;
    }
    out
      ..add(NavLink(anyMap))
      ..add(NavLink(gWeb));
    final seen = <NavLink>{};
    return [for (final l in out) if (seen.add(l)) l];
  }
}
