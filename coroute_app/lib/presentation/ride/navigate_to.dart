import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a link outside the app; true when something opened it.
typedef ExternalLauncher = Future<bool> Function(Uri uri);

/// Tests replace the launcher to see which links were tried.
@visibleForTesting
ExternalLauncher? navigateLauncherOverride;

/// Checks if Organic Maps is installed and registered on the device.
Future<bool> isOrganicMapsInstalled() async {
  try {
    return await canLaunchUrl(Uri.parse('om://map?v=1'));
  } catch (_) {
    return false;
  }
}

/// The links tried, in prioritized order:
/// 1. Organic Maps Turn-by-Turn Route (`om://route`)
/// 2. Organic Maps Location Pin with backurl (`om://map`)
/// 3. Google Maps Turn-by-Turn (`google.navigation:`)
/// 4. Any map app (`geo:`)
/// 5. Google Maps in browser (`https://...`)
List<Uri> navigationUris(
  double lat,
  double lng, {
  String? label,
  double? startLat,
  double? startLng,
}) {
  final la = lat.toStringAsFixed(6);
  final ln = lng.toStringAsFixed(6);
  final name = (label ?? '').replaceAll(RegExp(r'[()\n\r]'), ' ').trim();
  final encName = Uri.encodeComponent(name);

  final uris = <Uri>[];

  // 1. Organic Maps Turn-by-Turn Route
  if (startLat != null && startLng != null && startLat != 0 && startLng != 0) {
    final sLa = startLat.toStringAsFixed(6);
    final sLn = startLng.toStringAsFixed(6);
    uris.add(Uri.parse('om://route?sll=$sLa,$sLn&saddr=My%20Location&dll=$la,$ln&daddr=$encName&type=vehicle&backurl=coroute://cockpit'));
  } else {
    uris.add(Uri.parse('om://route?dll=$la,$ln&daddr=$encName&type=vehicle&backurl=coroute://cockpit'));
  }

  // 2. Organic Maps Location Pin (with CoRoute return link)
  uris.add(Uri.parse('om://map?v=1&ll=$la,$ln&n=$encName&backurl=coroute://cockpit'));

  // 3. Google Maps Turn-by-Turn
  uris.add(Uri.parse('google.navigation:q=$la,$ln&mode=d'));

  // 4. Any map app (geo:)
  final q = name.isEmpty ? '$la,$ln' : '$la,$ln($encName)';
  uris.add(Uri.parse('geo:$la,$ln?q=$q'));

  // 5. Browser fallback
  uris.add(Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$la,$ln'));

  return uris;
}

/// Starts navigation to [lat], [lng] trying offline Organic Maps first.
Future<bool> navigateTo(
  double lat,
  double lng, {
  String? label,
  double? startLat,
  double? startLng,
}) async {
  if (!lat.isFinite || !lng.isFinite || (lat == 0 && lng == 0)) return false;
  final ExternalLauncher launch = navigateLauncherOverride ?? _launchExternal;
  for (final uri in navigationUris(lat, lng, label: label, startLat: startLat, startLng: startLng)) {
    try {
      if (await launch(uri)) return true;
    } catch (_) {
      // Not handled on this phone: try the next link.
    }
  }
  return false;
}

Future<bool> _launchExternal(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
