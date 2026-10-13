import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../presentation/ride/navigate_to.dart';

/// Service managing offline navigation handoffs, store redirects, and GPX 1.1 export
/// to companion navigation apps like Organic Maps.
class OfflineNavService {
  static const String organicMapsPlayStoreUrl =
      'https://play.google.com/store/apps/details?id=app.organicmaps';
  static const String organicMapsFDroidUrl =
      'https://f-droid.org/packages/app.organicmaps/';

  @visibleForTesting
  static Future<bool> Function({
    required String tripName,
    required List<(double lat, double lng)> points,
    List<(String name, double lat, double lng)> checkpoints,
  })? exportOverride;

  @visibleForTesting
  static Future<bool> Function()? installedOverride;

  @visibleForTesting
  static Future<bool> Function(Uri uri)? downloadRegionOverride;

  /// Checks if Organic Maps is installed and registered on the device.
  static Future<bool> isInstalled() {
    if (installedOverride != null) return installedOverride!();
    return isOrganicMapsInstalled();
  }

  /// Prompts the rider to install Organic Maps from Google Play Store or F-Droid.
  static Future<bool> openStoreInstall() async {
    try {
      final playUri = Uri.parse(organicMapsPlayStoreUrl);
      if (await canLaunchUrl(playUri)) {
        return await launchUrl(playUri, mode: LaunchMode.externalApplication);
      }
      final fdroidUri = Uri.parse(organicMapsFDroidUrl);
      return await launchUrl(fdroidUri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  /// Opens Organic Maps targeted at coordinates [lat],[lng] with a backlink
  /// to CoRoute cockpit (`coroute://cockpit`). If the regional map is not yet
  /// downloaded, Organic Maps immediately triggers its on-demand download prompt.
  static Future<bool> openOrganicMapsRegionDownload({
    required double lat,
    required double lng,
    String? label,
  }) async {
    if (!lat.isFinite || !lng.isFinite || (lat == 0 && lng == 0)) return false;
    final name = (label ?? '').replaceAll(RegExp(r'[()\n\r]'), ' ').trim();
    final encName = Uri.encodeComponent(name);
    final la = lat.toStringAsFixed(6);
    final ln = lng.toStringAsFixed(6);
    final uri = Uri.parse('om://map?v=1&ll=$la,$ln&n=$encName&backurl=coroute://cockpit');
    if (downloadRegionOverride != null) return downloadRegionOverride!(uri);
    try {
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Opens Organic Maps vehicle navigation route from start to destination coordinates
  /// with a backlink to CoRoute (`coroute://cockpit`). If start coordinates are omitted or 0,
  /// Organic Maps routes from the rider's current GPS position.
  static Future<bool> openOrganicMapsRoute({
    double? startLat,
    double? startLng,
    required double destLat,
    required double destLng,
    String? startName,
    String? destName,
  }) async {
    if (!destLat.isFinite || !destLng.isFinite || (destLat == 0 && destLng == 0)) {
      return false;
    }
    final dLa = destLat.toStringAsFixed(6);
    final dLn = destLng.toStringAsFixed(6);
    final dAddr = Uri.encodeComponent((destName ?? 'Destination').trim());

    final Uri uri;
    if (startLat != null &&
        startLng != null &&
        startLat.isFinite &&
        startLng.isFinite &&
        (startLat != 0 || startLng != 0)) {
      final sLa = startLat.toStringAsFixed(6);
      final sLn = startLng.toStringAsFixed(6);
      final sAddr = Uri.encodeComponent((startName ?? 'Start').trim());
      uri = Uri.parse(
        'om://route?sll=$sLa,$sLn&saddr=$sAddr&dll=$dLa,$dLn&daddr=$dAddr&type=vehicle&backurl=coroute://cockpit',
      );
    } else {
      uri = Uri.parse(
        'om://route?dll=$dLa,$dLn&daddr=$dAddr&type=vehicle&backurl=coroute://cockpit',
      );
    }

    if (downloadRegionOverride != null) return downloadRegionOverride!(uri);
    try {
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Builds a valid GPX 1.1 XML document from convoy route polyline points and named checkpoints.
  static String buildGpxContent({
    required String tripName,
    required List<(double lat, double lng)> points,
    List<(String name, double lat, double lng)> checkpoints = const [],
  }) {
    final sb = StringBuffer();
    sb.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    sb.writeln('<gpx version="1.1" creator="CoRoute Convoy Safety Telemetry" xmlns="http://www.topografix.com/GPX/1/1">');
    sb.writeln('  <metadata>');
    sb.writeln('    <name>${_escape(tripName)}</name>');
    sb.writeln('  </metadata>');

    // Checkpoints / Regroup stops as waypoints
    for (final cp in checkpoints) {
      sb.writeln('  <wpt lat="${cp.$2.toStringAsFixed(6)}" lon="${cp.$3.toStringAsFixed(6)}">');
      sb.writeln('    <name>${_escape(cp.$1)}</name>');
      sb.writeln('  </wpt>');
    }

    // Polyline route track
    sb.writeln('  <trk>');
    sb.writeln('    <name>${_escape(tripName)}</name>');
    sb.writeln('    <trkseg>');
    for (final pt in points) {
      sb.writeln('      <trkpt lat="${pt.$1.toStringAsFixed(6)}" lon="${pt.$2.toStringAsFixed(6)}" />');
    }
    sb.writeln('    </trkseg>');
    sb.writeln('  </trk>');
    sb.writeln('</gpx>');

    return sb.toString();
  }

  /// Exports convoy GPX track to Organic Maps or the system share sheet.
  static Future<bool> exportRouteToOrganicMaps({
    required String tripName,
    required List<(double lat, double lng)> points,
    List<(String name, double lat, double lng)> checkpoints = const [],
  }) async {
    if (points.isEmpty) return false;
    if (exportOverride != null) {
      return exportOverride!(tripName: tripName, points: points, checkpoints: checkpoints);
    }

    try {
      final gpxString = buildGpxContent(
        tripName: tripName,
        points: points,
        checkpoints: checkpoints,
      );

      final sanitizedName = tripName.replaceAll(RegExp(r'[^\w\s\-]'), '_').trim().replaceAll(RegExp(r'\s+'), '_');
      final fileName = '${sanitizedName.isEmpty ? "convoy_route" : sanitizedName}.gpx';

      final file = XFile.fromData(
        utf8.encode(gpxString),
        mimeType: 'application/gpx+xml',
        name: fileName,
      );

      final result = await SharePlus.instance.share(ShareParams(
        files: [file],
        subject: '$tripName - Convoy Offline Route',
      ));
      return result.status == ShareResultStatus.success;
    } catch (e) {
      debugPrint('GPX export note: $e');
      return false;
    }
  }

  static String _escape(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
}
