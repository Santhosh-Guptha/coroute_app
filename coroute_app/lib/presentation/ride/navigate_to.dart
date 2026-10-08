import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a link outside the app; true when something opened it.
typedef ExternalLauncher = Future<bool> Function(Uri uri);

/// Tests replace the launcher to see which links were tried.
@visibleForTesting
ExternalLauncher? navigateLauncherOverride;

/// The links tried, in order: Google Maps turn-by-turn, any map app (geo:),
/// then Google Maps in the browser. Coordinates with 6 decimals.
List<Uri> navigationUris(double lat, double lng, {String? label}) {
  final la = lat.toStringAsFixed(6);
  final ln = lng.toStringAsFixed(6);
  final name = (label ?? '').replaceAll(RegExp(r'[()\n\r]'), ' ').trim();
  final q = name.isEmpty ? '$la,$ln' : '$la,$ln(${Uri.encodeComponent(name)})';
  return [
    Uri.parse('google.navigation:q=$la,$ln&mode=d'),
    Uri.parse('geo:$la,$ln?q=$q'),
    Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$la,$ln'),
  ];
}

/// Starts navigation to [lat], [lng] in the phone's map app. No
/// `canLaunchUrl` gate (it needs package visibility rules and is often wrong
/// on Android 11+): each link is simply tried until one opens.
Future<bool> navigateTo(double lat, double lng, {String? label}) async {
  if (!lat.isFinite || !lng.isFinite || (lat == 0 && lng == 0)) return false;
  final ExternalLauncher launch = navigateLauncherOverride ?? _launchExternal;
  for (final uri in navigationUris(lat, lng, label: label)) {
    try {
      if (await launch(uri)) return true;
    } catch (_) {
      // Not handled on this phone: try the next link.
    }
  }
  return false;
}

Future<bool> _launchExternal(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
