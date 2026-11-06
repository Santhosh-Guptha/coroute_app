import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' show LatLng;

import '../../../domain/tracking/nav_motion.dart';
import '../map/nav_camera_controller.dart';

/// One rider on the [SmoothMarkerLayer].
@immutable
class SmoothMarker {
  /// Stable id (the rider's user id): keys the animation and the marker widget.
  final String id;

  /// Newest reported position and heading; the layer glides to them.
  final LatLng point;
  final double heading;

  /// Draw the direction-of-travel arrow around the avatar.
  final bool showHeading;

  /// Distance of the arrow from the marker's centre (the avatar's radius).
  final double headingRadius;
  final Color headingColor;

  /// Box of [child]; the avatar must sit at the box's centre.
  final double width;
  final double height;
  final Widget child;

  /// Small stand-in drawn for far riders in a big group (null: always [child]).
  final Widget? compact;
  final double compactSize;

  /// Never clustered or simplified (me, the selected rider, the lead, anyone in trouble).
  final bool pinned;

  const SmoothMarker({
    required this.id,
    required this.point,
    required this.child,
    this.heading = 0.0,
    this.showHeading = false,
    this.headingRadius = 22.0,
    this.headingColor = const Color(0xFF0E7C86),
    this.width = 144.0,
    this.height = 140.0,
    this.compact,
    this.compactSize = 30.0,
    this.pinned = false,
  });
}

/// Rider markers that glide between position reports instead of jumping
/// (each marker tweens position and heading over about the time between its
/// reports), with a heading arrow, upright labels on a rotated map, and, in
/// big groups, far riders drawn as small dots or merged into count bubbles.
///
/// The marker [SmoothMarker.child] widgets are reused untouched between
/// animation frames (only their position changes), each behind a
/// [RepaintBoundary], so 50+ riders stay cheap. The marker whose id is
/// [driverId] follows [driverPose] (my own smoothed position from the
/// navigation camera) so it never drifts from the camera.
class SmoothMarkerLayer extends StatefulWidget {
  final List<SmoothMarker> markers;
  final String? driverId;
  final ValueListenable<NavPose?>? driverPose;

  /// Riders within [nearRadiusM] of this point are always drawn in full.
  final LatLng? focus;

  /// With more markers than this, far riders are simplified / clustered.
  final int simplifyAbove;
  final double nearRadiusM;
  final Color clusterColor;
  final void Function(LatLng center, int count)? onClusterTap;

  const SmoothMarkerLayer({
    super.key,
    required this.markers,
    this.driverId,
    this.driverPose,
    this.focus,
    this.simplifyAbove = 15,
    this.nearRadiusM = 600.0,
    this.clusterColor = const Color(0xFF0E7C86),
    this.onClusterTap,
  });

  @override
  State<SmoothMarkerLayer> createState() => _SmoothMarkerLayerState();
}

class _SmoothMarkerLayerState extends State<SmoothMarkerLayer> with SingleTickerProviderStateMixin {
  final Map<String, MarkerTrack> _tracks = <String, MarkerTrack>{};
  late final Ticker _ticker = createTicker(_onTick);

  /// Monotonic animation clock (ms), advanced by the ticker only.
  int _clockMs = 0;
  int _clockBaseMs = 0;
  Duration? _lastFrame;

  @override
  void initState() {
    super.initState();
    widget.driverPose?.addListener(_onPose);
    _sync();
  }

  @override
  void didUpdateWidget(covariant SmoothMarkerLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.driverPose, widget.driverPose)) {
      oldWidget.driverPose?.removeListener(_onPose);
      widget.driverPose?.addListener(_onPose);
    }
    _sync();
  }

  @override
  void dispose() {
    widget.driverPose?.removeListener(_onPose);
    _ticker.dispose();
    super.dispose();
  }

  void _onPose() {
    if (mounted) setState(() {});
  }

  void _sync() {
    final now = _clockMs;
    final ids = <String>{};
    var animating = false;
    for (final m in widget.markers) {
      final lat = m.point.latitude, lng = m.point.longitude;
      if (!lat.isFinite || !lng.isFinite) continue;
      ids.add(m.id);
      final track = _tracks[m.id];
      if (m.id == widget.driverId && widget.driverPose?.value != null) {
        // Drawn from the camera's pose: no tween of its own (keeps the ticker idle).
        _tracks[m.id] = MarkerTrack(lat, lng, m.heading.isFinite ? m.heading : 0.0, now);
      } else if (track == null) {
        _tracks[m.id] = MarkerTrack(lat, lng, m.heading.isFinite ? m.heading : 0.0, now);
      } else {
        track.retarget(lat, lng, m.heading.isFinite ? m.heading : track.targetHeading, now);
        if (track.isAnimating(now)) animating = true;
      }
    }
    _tracks.removeWhere((id, _) => !ids.contains(id));
    if (animating && !_ticker.isActive) {
      _lastFrame = null;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    _clockMs = _clockBaseMs + elapsed.inMilliseconds;
    // ~30 fps is plenty for other riders' markers; ~20 fps in a big group.
    final minMs = widget.markers.length > 30 ? 50 : 33;
    final last = _lastFrame;
    final active = _tracks.values.any((t) => t.isAnimating(_clockMs));
    if (active && last != null && (elapsed - last).inMilliseconds < minMs) return;
    _lastFrame = elapsed;
    if (mounted) setState(() {});
    if (!active) {
      _ticker.stop();
      _clockBaseMs = _clockMs;
    }
  }

  (double, double, double) _valueOf(SmoothMarker m, NavPose? pose) {
    if (pose != null && m.id == widget.driverId) return (pose.lat, pose.lng, pose.heading);
    final t = _tracks[m.id];
    if (t != null) return t.valueAt(_clockMs);
    return (m.point.latitude, m.point.longitude, m.heading);
  }

  Marker _full(SmoothMarker m, (double, double, double) v) => Marker(
        key: ValueKey<String>('rider-${m.id}'),
        point: LatLng(v.$1, v.$2),
        width: m.width,
        height: m.height,
        rotate: true,
        child: _MarkerBody(
          heading: v.$3,
          showHeading: m.showHeading,
          radius: m.headingRadius,
          color: m.headingColor,
          child: m.child,
        ),
      );

  Marker _compact(SmoothMarker m, (double, double, double) v) {
    final c = m.compact;
    if (c == null) return _full(m, v);
    final box = m.compactSize + 16.0;
    return Marker(
      key: ValueKey<String>('rider-c-${m.id}'),
      point: LatLng(v.$1, v.$2),
      width: box,
      height: box,
      rotate: true,
      child: _MarkerBody(
        heading: v.$3,
        showHeading: m.showHeading,
        radius: m.compactSize / 2,
        color: m.headingColor,
        child: Center(child: SizedBox(width: m.compactSize, height: m.compactSize, child: c)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final markers = widget.markers;
    final pose = widget.driverPose?.value;
    final out = <Marker>[];
    if (markers.length <= widget.simplifyAbove) {
      for (final m in markers) {
        if (!_tracks.containsKey(m.id)) continue;
        out.add(_full(m, _valueOf(m, pose)));
      }
      return MarkerLayer(markers: out, rotate: true);
    }

    // Big group: riders near me (and pinned ones) in full; far ones as dots,
    // merged into a count bubble where they would overlap at this zoom.
    final camera = MapCamera.maybeOf(context);
    final zoom = camera?.zoom ?? 14.0;
    final zq = (zoom * 2).floorToDouble() / 2; // re-cluster per half zoom level only
    final focus = widget.focus ?? pose?.point;
    final far = <SmoothMarker>[];
    for (final m in markers) {
      final t = _tracks[m.id];
      if (t == null) continue;
      final near = m.pinned ||
          m.id == widget.driverId ||
          (focus != null && NavMath.distanceM(focus.latitude, focus.longitude, t.targetLat, t.targetLng) <= widget.nearRadiusM);
      if (near) {
        out.add(_full(m, _valueOf(m, pose)));
      } else {
        far.add(m);
      }
    }
    final groups = clusterByGrid(
      [for (final m in far) (lat: _tracks[m.id]!.targetLat, lng: _tracks[m.id]!.targetLng, pinned: false)],
      zoom: zq,
      cellPx: 64,
    );
    for (final g in groups) {
      if (g.length == 1) {
        final m = far[g.first];
        out.add(_compact(m, _valueOf(m, pose)));
        continue;
      }
      var sLat = 0.0, sLng = 0.0;
      for (final i in g) {
        final v = _valueOf(far[i], pose);
        sLat += v.$1;
        sLng += v.$2;
      }
      final center = LatLng(sLat / g.length, sLng / g.length);
      out.add(Marker(
        key: ValueKey<String>('cluster-${far[g.first].id}'),
        point: center,
        width: 48,
        height: 48,
        rotate: true,
        child: _ClusterBubble(
          count: g.length,
          color: widget.clusterColor,
          onTap: widget.onClusterTap == null ? null : () => widget.onClusterTap!(center, g.length),
        ),
      ));
    }
    // Full markers last so they draw above dots and bubbles.
    out.sort((a, b) => _rank(a).compareTo(_rank(b)));
    return MarkerLayer(markers: out, rotate: true);
  }

  static int _rank(Marker m) {
    final k = m.key;
    if (k is ValueKey<String>) {
      if (k.value.startsWith('cluster-')) return 0;
      if (k.value.startsWith('rider-c-')) return 1;
    }
    return 2;
  }
}

/// The marker child (sized to the whole marker box) with the heading arrow behind it.
class _MarkerBody extends StatelessWidget {
  final double heading;
  final bool showHeading;
  final double radius;
  final Color color;
  final Widget child;

  const _MarkerBody({
    required this.heading,
    required this.showHeading,
    required this.radius,
    required this.color,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        if (showHeading)
          Positioned.fill(
            child: IgnorePointer(child: HeadingArrow(heading: heading, radius: radius, color: color)),
          ),
        RepaintBoundary(child: child),
      ],
    );
  }
}

/// A small arrow just outside the avatar pointing the way the rider is going.
/// It reads the map's rotation itself, so on a rotated map it still points
/// along the road (only this tiny widget rebuilds when the camera turns).
class HeadingArrow extends StatelessWidget {
  final double heading;
  final double radius;
  final Color color;

  const HeadingArrow({super.key, required this.heading, required this.radius, required this.color});

  @override
  Widget build(BuildContext context) {
    final rotation = MapCamera.maybeOf(context)?.rotation ?? 0.0;
    final angle = (heading + rotation) * math.pi / 180.0;
    return Transform.rotate(
      angle: angle.isFinite ? angle : 0.0,
      child: CustomPaint(painter: _ArrowPainter(radius: radius, color: color)),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  final double radius;
  final Color color;

  const _ArrowPainter({required this.radius, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final tip = Offset(c.dx, c.dy - radius - 13);
    final baseY = c.dy - radius + 1;
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(c.dx + 8, baseY)
      ..quadraticBezierTo(c.dx, baseY - 4, c.dx - 8, baseY)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _ArrowPainter oldDelegate) => oldDelegate.radius != radius || oldDelegate.color != color;
}

/// Several far riders merged into one bubble ("7"); tap to zoom in.
class _ClusterBubble extends StatelessWidget {
  final int count;
  final Color color;
  final VoidCallback? onTap;

  const _ClusterBubble({required this.count, required this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      label: '$count riders here, tap to zoom in',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              border: Border.all(color: const Color(0xFFFFFFFF), width: 3),
              boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 6, offset: Offset(0, 2))],
            ),
            child: Text(
              count > 99 ? '99+' : '$count',
              textScaler: TextScaler.noScaling,
              style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 14, fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ),
    );
  }
}

/// A far rider in a big group: a small coloured dot with initials (no label pill).
class CompactRiderDot extends StatelessWidget {
  final String initials;
  final Color color;
  final String semanticsLabel;
  final VoidCallback? onTap;

  const CompactRiderDot({
    super.key,
    required this.initials,
    required this.color,
    required this.semanticsLabel,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      label: semanticsLabel,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: const Color(0xFFFFFFFF), width: 2),
          ),
          child: Text(
            initials,
            maxLines: 1,
            textScaler: TextScaler.noScaling,
            style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 10, fontWeight: FontWeight.w800),
          ),
        ),
      ),
    );
  }
}
