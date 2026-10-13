import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

/// Service managing GPX 1.1 route file generation and standard system sharing.
class OfflineNavService {
  OfflineNavService._();

  @visibleForTesting
  static Future<bool> Function({
    required String tripName,
    required List<(double lat, double lng)> points,
    List<(String name, double lat, double lng)> checkpoints,
  })? exportOverride;

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

  /// Exports convoy GPX track to the system share sheet.
  static Future<bool> exportGpxRoute({
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
        subject: '$tripName - Convoy Route GPX',
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
