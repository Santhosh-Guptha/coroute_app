import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/config/feature_gates.dart';

/// Waypoint metadata for incidents and stops embedded into the GPX stream.
class GpxWaypoint {
  final String name;
  final String description;
  final double latitude;
  final double longitude;
  final double? elevationM;
  final DateTime? timestamp;
  final String symbol; // e.g. "Gas Station", "Flag, Blue", "Wrench", "Danger Area"

  const GpxWaypoint({
    required this.name,
    this.description = '',
    required this.latitude,
    required this.longitude,
    this.elevationM,
    this.timestamp,
    this.symbol = 'Waypoint',
  });
}

/// Trackpoint representing a single GPS fix in the recorded ride.
class GpxTrackpoint {
  final double latitude;
  final double longitude;
  final double? elevationM;
  final DateTime timestamp;
  final double speedKmh;
  final double? bearing;
  final double? leanAngleDeg;

  const GpxTrackpoint({
    required this.latitude,
    required this.longitude,
    this.elevationM,
    required this.timestamp,
    required this.speedKmh,
    this.bearing,
    this.leanAngleDeg,
  });
}

/// Enterprise GPX 1.1 telemetry exporter for Strava, Garmin, Google Earth, and GIS tools.
class GpxService {
  GpxService._();

  /// Converts recorded trackpoints and stop waypoints into standard GPX 1.1 XML.
  static String buildTelemetryGpx({
    required String rideName,
    required List<GpxTrackpoint> trackpoints,
    List<GpxWaypoint> waypoints = const [],
    String creator = 'CoRoute Tactical Motorcycle Telemetry v3.38.0',
  }) {
    final sb = StringBuffer();
    sb.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    sb.writeln(
        '<gpx version="1.1" creator="${_escape(creator)}" xmlns="http://www.topografix.com/GPX/1/1" xmlns:coroute="https://coroute.space/gpx/1">');

    // Metadata
    sb.writeln('  <metadata>');
    sb.writeln('    <name>${_escape(rideName)}</name>');
    if (trackpoints.isNotEmpty) {
      sb.writeln('    <time>${trackpoints.first.timestamp.toUtc().toIso8601String()}</time>');
    }
    sb.writeln('  </metadata>');

    // Waypoints (Stops, Incidents, Regroups)
    for (final wpt in waypoints) {
      sb.writeln('  <wpt lat="${wpt.latitude.toStringAsFixed(6)}" lon="${wpt.longitude.toStringAsFixed(6)}">');
      if (wpt.elevationM != null) {
        sb.writeln('    <ele>${wpt.elevationM!.toStringAsFixed(1)}</ele>');
      }
      if (wpt.timestamp != null) {
        sb.writeln('    <time>${wpt.timestamp!.toUtc().toIso8601String()}</time>');
      }
      sb.writeln('    <name>${_escape(wpt.name)}</name>');
      if (wpt.description.isNotEmpty) {
        sb.writeln('    <desc>${_escape(wpt.description)}</desc>');
      }
      sb.writeln('    <sym>${_escape(wpt.symbol)}</sym>');
      sb.writeln('  </wpt>');
    }

    // Main Track and Segment
    sb.writeln('  <trk>');
    sb.writeln('    <name>${_escape(rideName)}</name>');
    sb.writeln('    <trkseg>');
    for (final pt in trackpoints) {
      sb.writeln('      <trkpt lat="${pt.latitude.toStringAsFixed(6)}" lon="${pt.longitude.toStringAsFixed(6)}">');
      if (pt.elevationM != null) {
        sb.writeln('        <ele>${pt.elevationM!.toStringAsFixed(1)}</ele>');
      }
      sb.writeln('        <time>${pt.timestamp.toUtc().toIso8601String()}</time>');
      // Speed in m/s standard for GPX 1.1
      final speedMs = (pt.speedKmh / 3.6).clamp(0.0, 100.0);
      sb.writeln('        <speed>${speedMs.toStringAsFixed(2)}</speed>');

      // Telemetry extensions
      sb.writeln('        <extensions>');
      sb.writeln('          <coroute:speed_kmh>${pt.speedKmh.toStringAsFixed(1)}</coroute:speed_kmh>');
      if (pt.bearing != null) {
        sb.writeln('          <coroute:bearing>${pt.bearing!.toStringAsFixed(1)}</coroute:bearing>');
      }
      if (pt.leanAngleDeg != null) {
        sb.writeln('          <coroute:lean_angle>${pt.leanAngleDeg!.toStringAsFixed(1)}</coroute:lean_angle>');
      }
      sb.writeln('        </extensions>');
      sb.writeln('      </trkpt>');
    }
    sb.writeln('    </trkseg>');
    sb.writeln('  </trk>');
    sb.writeln('</gpx>');

    return sb.toString();
  }

  /// Exports the telemetry GPX file to the system share sheet.
  static Future<bool> shareGpxFile({
    required String rideName,
    required List<GpxTrackpoint> trackpoints,
    List<GpxWaypoint> waypoints = const [],
  }) async {
    if (trackpoints.isEmpty) return false;

    // Feature gate check for telemetry export
    if (!FeatureGates.isUnlocked(Feature.advancedTelemetryReplay)) {
      return false;
    }

    try {
      final xml = buildTelemetryGpx(
        rideName: rideName,
        trackpoints: trackpoints,
        waypoints: waypoints,
      );

      final cleanName = rideName
          .replaceAll(RegExp(r'[^\w\s\-]'), '_')
          .trim()
          .replaceAll(RegExp(r'\s+'), '_');
      final fileName = '${cleanName.isEmpty ? "coroute_telemetry" : cleanName}.gpx';

      final file = XFile.fromData(
        utf8.encode(xml),
        mimeType: 'application/gpx+xml',
        name: fileName,
      );

      final result = await SharePlus.instance.share(ShareParams(
        files: [file],
        subject: '$rideName - CoRoute Telemetry Track',
      ));

      return result.status == ShareResultStatus.success;
    } catch (e) {
      debugPrint('GPX export failed: $e');
      return false;
    }
  }

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
