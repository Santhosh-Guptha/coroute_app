import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../../core/ui/rider_status.dart';
import '../../../domain/ride/bike_markers.dart';
import '../../garage/bike_silhouette.dart';

/// 3.55 bike marker body: a rounded plate carrying the rider's bike shape (its type, in the bike's
/// colour) with one or two people on it, instead of a round avatar. The state cues stay: the plate's
/// ring (moving colour / amber stopped / red SOS), a status dot, a role letter (L lead, S sweeper),
/// a glow for me and for the selected rider, faded when the position is stale. The bike faces the
/// way it travels (mirrored when heading left on the map; the heading arrow still points exactly).
/// The glyph is a cached picture per type + colour + people + size ([BikeGlyphCache]), so dozens of
/// riders cost one replay each.
class BikeMarkerBadge extends StatelessWidget {
  const BikeMarkerBadge({
    super.key,
    required this.vehicleKind,
    required this.vehicleColor,
    required this.fallbackColor,
    required this.ring,
    required this.statusColor,
    required this.height,
    this.twoUp = false,
    this.heading = 0,
    this.cue = BikeMarkerCue.normal,
    this.me = false,
    this.selected = false,
    this.roleLetter = '',
    this.roleColor = const Color(0xFF0E7C86),
  });

  final String vehicleKind;
  final String vehicleColor;
  final Color fallbackColor;
  final Color ring;
  final Color statusColor;
  final double height;
  final bool twoUp;
  final double heading;
  final BikeMarkerCue cue;
  final bool me;
  final bool selected;
  final String roleLetter;
  final Color roleColor;

  /// Plate width for a plate [height] (the bike is wider than tall).
  static double widthFor(double height) => height * 1.42;

  @override
  Widget build(BuildContext context) {
    final w = widthFor(height);
    final rotation = MapCamera.maybeOf(context)?.rotation ?? 0.0;
    final screenHeading = ((heading + rotation) % 360 + 360) % 360;
    final faceLeft = screenHeading > 180 && screenHeading < 360;
    final key = BikeMarkerKey.of(
      vehicleKind: vehicleKind,
      vehicleColor: vehicleColor,
      fallbackArgb: fallbackColor.toARGB32(),
      twoUp: twoUp,
      cue: cue,
      size: w - 8,
    );
    final ringWidth = cue == BikeMarkerCue.sos ? 4.0 : 3.0;
    final ring = cue == BikeMarkerCue.sos ? statusColor : this.ring;
    Widget plate = Container(
      width: w,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(height * 0.32),
        border: Border.all(color: ring, width: ringWidth),
        boxShadow: [
          if (me) BoxShadow(color: ring.withValues(alpha: 0.45), blurRadius: 16, offset: const Offset(0, 6)),
          if (selected && !me) BoxShadow(color: ring.withValues(alpha: 0.35), spreadRadius: 4),
          if (!me && !selected) const BoxShadow(color: Color(0x40000000), blurRadius: 5, offset: Offset(0, 2)),
        ],
      ),
      padding: const EdgeInsets.all(2),
      child: CustomPaint(painter: _GlyphPainter(key, faceLeft)),
    );
    if (cue == BikeMarkerCue.stale) plate = Opacity(opacity: 0.55, child: plate);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        plate,
        Positioned(
          right: -2,
          bottom: -2,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: statusColor,
              border: Border.all(color: const Color(0xFFFFFFFF), width: 2),
            ),
          ),
        ),
        if (roleLetter.isNotEmpty)
          Positioned(
            left: -4,
            top: -4,
            child: Container(
              width: 16,
              height: 16,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: roleColor,
                border: Border.all(color: const Color(0xFFFFFFFF), width: 1.5),
              ),
              child: Text(
                roleLetter,
                textScaler: TextScaler.noScaling,
                style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 9, fontWeight: FontWeight.w900, height: 1),
              ),
            ),
          ),
      ],
    );
  }
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.glyph, this.faceLeft);
  final BikeMarkerKey glyph;
  final bool faceLeft;

  @override
  void paint(Canvas canvas, Size size) {
    final pic = BikeGlyphCache.pictureFor(glyph);
    final w = glyph.size.toDouble();
    final h = w * BikeShapes.designHeight / BikeShapes.designWidth;
    final s = math.min(size.width / w, size.height / h);
    canvas.save();
    canvas.translate((size.width - w * s) / 2, (size.height - h * s) / 2);
    canvas.scale(s);
    if (faceLeft) {
      canvas.translate(w, 0);
      canvas.scale(-1, 1);
    }
    canvas.drawPicture(pic);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GlyphPainter old) => old.glyph != glyph || old.faceLeft != faceLeft;
}

/// A far rider in a big group: a small bike plate (no label), in the bike's colour and shape.
class CompactBikeDot extends StatelessWidget {
  const CompactBikeDot({
    super.key,
    required this.vehicleKind,
    required this.vehicleColor,
    required this.color,
    required this.semanticsLabel,
    this.twoUp = false,
    this.onTap,
  });

  final String vehicleKind;
  final String vehicleColor;
  final Color color;
  final String semanticsLabel;
  final bool twoUp;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      label: semanticsLabel,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: LayoutBuilder(
          builder: (context, c) {
            final h = math.min(c.maxHeight, c.maxWidth / 1.42);
            return Center(
              child: BikeMarkerBadge(
                vehicleKind: vehicleKind,
                vehicleColor: vehicleColor,
                fallbackColor: color,
                ring: color,
                statusColor: color,
                height: h,
                twoUp: twoUp,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 3.55 a rider on an overview map (admin live maps, trip report / replay): the bike plate in the
/// bike's shape and colour (rider colour when unknown) with the status dot, instead of a round
/// initials avatar. [status] picks the cue (SOS red ring, stopped amber, faded when offline).
/// Screen readers hear "[name], [status]". With [onTap] the whole box is the touch target.
class StatusBikeMarker extends StatelessWidget {
  const StatusBikeMarker({
    super.key,
    required this.name,
    required this.color,
    this.vehicleKind = '',
    this.vehicleColor = '',
    this.status,
    this.heading = 0,
    this.twoUp = false,
    this.height = 28,
    this.onTap,
  });

  final String name;
  final Color color;
  final String vehicleKind;
  final String vehicleColor;
  final RiderStatus? status;
  final double heading;
  final bool twoUp;
  final double height;
  final VoidCallback? onTap;

  static BikeMarkerCue cueOf(RiderStatus? s) => switch (s) {
        RiderStatus.emergency => BikeMarkerCue.sos,
        RiderStatus.offline || RiderStatus.disconnected => BikeMarkerCue.stale,
        RiderStatus.stopped || RiderStatus.resting => BikeMarkerCue.stopped,
        _ => BikeMarkerCue.normal,
      };

  @override
  Widget build(BuildContext context) {
    final s = status;
    return Semantics(
      button: onTap != null,
      label: s == null ? name : '$name, ${s.label}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: BikeMarkerBadge(
            vehicleKind: vehicleKind,
            vehicleColor: vehicleColor,
            fallbackColor: color,
            ring: color,
            statusColor: s?.color ?? color,
            height: height,
            heading: heading,
            twoUp: twoUp,
            cue: cueOf(s),
          ),
        ),
      ),
    );
  }
}
