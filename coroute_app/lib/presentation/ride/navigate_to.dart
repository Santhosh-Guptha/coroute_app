import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/services/nav_handoff_service.dart';
import '../../domain/navigation/nav_handoff.dart';

/// Opens a link outside the app; true when something opened it.
typedef ExternalLauncher = Future<bool> Function(Uri uri);

/// Tests replace the launcher to see which links were tried (packages are then ignored and the
/// installed apps are unknown, so the plan is: google.navigation, geo:, Google Maps web).
@visibleForTesting
ExternalLauncher? navigateLauncherOverride;

/// The links tried with the Automatic choice when the installed apps are unknown, in order:
/// 1. Google Maps turn-by-turn (`google.navigation:`, two-wheeler mode)
/// 2. Any map app (`geo:`)
/// 3. Google Maps directions link (`https://www.google.com/maps/dir/...`)
/// The full rules (rider's choice, Mappls, installed apps) are in [NavHandoff.plan].
List<Uri> navigationUris(
  double lat,
  double lng, {
  String? label,
  double? startLat,
  double? startLng,
  bool twoWheeler = true,
}) =>
    [for (final l in NavHandoff.plan(lat, lng, label: label, twoWheeler: twoWheeler)) l.uri];

/// One tap hand-off to turn-by-turn navigation (3.55 "Navigate in Google Maps / Mappls"): the
/// rider's choice from Settings (Automatic: Google Maps, else Mappls, else any map app). CoRoute
/// keeps running in the background (the ride's foreground service is not touched; the ride
/// notification brings the rider back). True when an app took it.
Future<bool> navigateTo(
  double lat,
  double lng, {
  String? label,
  double? startLat,
  double? startLng,
  bool twoWheeler = true,
}) async {
  if (!NavHandoff.validTarget(lat, lng)) return false;
  final override = navigateLauncherOverride;
  final NavApp choice;
  bool? google, mappls;
  if (override != null) {
    choice = NavHandoffService.choice;
  } else {
    choice = await NavHandoffService.load();
    final i = await NavHandoffService.installed();
    google = i.google;
    mappls = i.mappls;
  }
  final links = NavHandoff.plan(lat, lng, label: label, choice: choice, googleInstalled: google, mapplsInstalled: mappls, twoWheeler: twoWheeler);
  for (final link in links) {
    try {
      if (override != null) {
        if (await override(link.uri)) return true;
        continue;
      }
      final pkg = link.package;
      if (pkg != null) {
        final r = await NavHandoffService.openInPackage(link.uri, pkg);
        if (r == true) return true;
        if (r == false) continue; // that app did not take it: next link
        // No bridge: plain launch below.
      }
      if (await _launchExternal(link.uri)) return true;
    } catch (_) {
      // Not handled on this phone: try the next link.
    }
  }
  return false;
}

Future<bool> _launchExternal(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
