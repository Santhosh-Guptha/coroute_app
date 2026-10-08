import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:share_plus/share_plus.dart';
import '../../core/theme/app_palette.dart';
import '../../core/ui/ui.dart';

/// What the post-ride share card shows. Only real numbers: a value that is
/// not known is left out of the card (never shown as 0 or guessed).
class RideShareData {
  final String tripName;
  final DateTime date;

  /// Metres; 0 or less = not known.
  final double distanceM;

  /// Riding (moving) time; null or 0 = not known.
  final int? ridingMs;

  /// Riders in the group; 0 = not known.
  final int riders;

  /// Stops made on the ride.
  final int stops;
  final String from;
  final String to;

  /// The route sketch: the recorded track, or the planned line. May be empty.
  final List<LatLng> sketch;

  const RideShareData({
    required this.tripName,
    required this.date,
    required this.distanceM,
    this.ridingMs,
    required this.riders,
    required this.stops,
    this.from = '',
    this.to = '',
    this.sketch = const [],
  });

  bool get hasDistance => distanceM > 0 && distanceM.isFinite;
  bool get hasRiding => (ridingMs ?? 0) > 0;

  String get dateText => DateFormat('EEE d MMM yyyy').format(date);

  String get routeText {
    if (from.isEmpty && to.isEmpty) return '';
    return '${from.isEmpty ? 'Start' : from} to ${to.isEmpty ? 'destination' : to}';
  }

  /// A safe file name for the image, from the trip name.
  String get fileName {
    final safe = tripName.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim().replaceAll(RegExp(r'\s+'), '_');
    return '${safe.isEmpty ? 'coroute_ride' : safe}.png';
  }

  /// The same facts as plain text (used when the image cannot be made).
  String toText() {
    final facts = <String>[
      if (hasDistance) 'Distance ${formatDistance(distanceM)}',
      if (hasRiding) 'riding ${formatDuration(Duration(milliseconds: ridingMs!))}',
    ];
    final group = <String>[
      if (riders > 0) '$riders ${riders == 1 ? 'rider' : 'riders'}',
      '$stops ${stops == 1 ? 'stop' : 'stops'}',
    ];
    return <String>[
      'CoRoute ride: $tripName',
      dateText,
      if (routeText.isNotEmpty) routeText,
      if (facts.isNotEmpty) facts.join(', '),
      group.join(', '),
    ].join('\n');
  }

  /// Drops points that are not real positions (missing values read as 0, 0).
  static List<LatLng> cleanPoints(Iterable<LatLng> points) => [
        for (final p in points)
          if (p.latitude.isFinite && p.longitude.isFinite && !(p.latitude == 0 && p.longitude == 0)) p,
      ];
}

/// The card itself: a fixed light surface (it is an image to share, so it
/// looks the same whatever theme the phone uses) with a hairline border, so it
/// also reads well on a dark sheet. No gradients, no emoji, no map tiles.
class RideShareCard extends StatelessWidget {
  final RideShareData data;

  const RideShareCard({super.key, required this.data});

  static const AppPalette _p = AppPalette.light;

  @override
  Widget build(BuildContext context) {
    final stats = <_CardStat>[
      if (data.hasDistance) _distanceStat(data.distanceM),
      if (data.hasRiding) _CardStat(value: formatDuration(Duration(milliseconds: data.ridingMs!)), label: 'Riding time'),
      if (data.riders > 0) _CardStat(value: '${data.riders}', label: data.riders == 1 ? 'Rider' : 'Riders'),
      _CardStat(value: '${data.stops}', label: data.stops == 1 ? 'Stop' : 'Stops'),
    ];
    final route = data.routeText;
    // The image keeps its layout at large font sizes (up to x1.3).
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Container(
        padding: const EdgeInsets.all(Space.s12),
        color: _p.obsidianVoid,
        child: Container(
          padding: const EdgeInsets.all(Space.s16),
          decoration: BoxDecoration(
            color: _p.slateCard,
            borderRadius: Radii.lgAll,
            border: Border.all(color: _p.subtleBorder),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    'CoRoute',
                    style: AppText.label.copyWith(color: _p.neonCyan, fontWeight: FontWeight.w700, letterSpacing: 0.4),
                  ),
                  const SizedBox(width: Space.s8),
                  Expanded(
                    child: Text(
                      data.dateText,
                      textAlign: TextAlign.end,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(color: _p.textSecondary),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.s12),
              Text(
                data.tripName.isEmpty ? 'Group ride' : data.tripName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.title.copyWith(color: _p.textPrimary),
              ),
              if (route.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: Space.s4),
                  child: Text(route, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(color: _p.textSecondary)),
                ),
              if (data.sketch.isNotEmpty) ...[
                const SizedBox(height: Space.s12),
                AspectRatio(
                  aspectRatio: 2,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: _p.elevatedCard, borderRadius: Radii.mdAll),
                    child: CustomPaint(
                      painter: RouteSketchPainter(
                        points: data.sketch,
                        lineColor: _p.neonCyan,
                        startColor: _p.emeraldSafe,
                        endColor: _p.textPrimary,
                        ringColor: _p.slateCard,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: Space.s12),
              LayoutBuilder(builder: (context, c) {
                final w = (c.maxWidth - Space.s8) / 2;
                return Wrap(
                  spacing: Space.s8,
                  runSpacing: Space.s8,
                  children: [for (final s in stats) SizedBox(width: w, child: s)],
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  /// "186 km" as value 186 and unit km.
  static _CardStat _distanceStat(double meters) {
    final text = formatDistance(meters);
    final cut = text.lastIndexOf(' ');
    if (cut <= 0) return _CardStat(value: text, label: 'Distance');
    return _CardStat(value: text.substring(0, cut), unit: text.substring(cut + 1), label: 'Distance');
  }
}

class _CardStat extends StatelessWidget {
  final String value;
  final String? unit;
  final String label;

  const _CardStat({required this.value, this.unit, required this.label});

  static const AppPalette _p = AppPalette.light;

  @override
  Widget build(BuildContext context) {
    final u = unit;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.s12, vertical: Space.s8),
      decoration: BoxDecoration(color: _p.elevatedCard, borderRadius: Radii.smAll),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: value),
                if (u != null) TextSpan(text: ' $u', style: AppText.label.copyWith(color: _p.textSecondary)),
              ]),
              maxLines: 1,
              style: AppText.title.copyWith(
                color: _p.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 22,
                fontFeatures: const [ui.FontFeature.tabularFigures()],
              ),
            ),
          ),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: _p.textSecondary)),
        ],
      ),
    );
  }
}

/// A small route sketch from points only (no map, no network): the line fitted
/// into the box with even scaling, a start dot and a finish dot.
/// Empty: paints nothing. One point (or all the same place): one dot in the middle.
class RouteSketchPainter extends CustomPainter {
  final List<LatLng> points;
  final Color lineColor;
  final Color startColor;
  final Color endColor;
  final Color ringColor;

  /// Longer tracks are thinned to about this many points before drawing.
  static const int maxPoints = 600;

  RouteSketchPainter({
    required this.points,
    required this.lineColor,
    required this.startColor,
    required this.endColor,
    required this.ringColor,
  });

  /// Projects [points] into [size] (with [pad]); public for tests.
  static List<Offset> project(List<LatLng> points, Size size, {double pad = 12}) {
    if (points.isEmpty || size.isEmpty) return const [];
    final step = points.length > maxPoints ? (points.length / maxPoints).ceil() : 1;
    final pts = <LatLng>[
      for (var i = 0; i < points.length; i += step) points[i],
      if ((points.length - 1) % step != 0) points.last,
    ];
    var minLat = double.infinity, maxLat = -double.infinity;
    for (final p in pts) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
    }
    // Equirectangular: shrink longitude by cos(latitude) so shapes keep their proportions.
    final k = math.cos((minLat + maxLat) / 2 * math.pi / 180).abs().clamp(0.01, 1.0);
    var minX = double.infinity, maxX = -double.infinity, minY = double.infinity, maxY = -double.infinity;
    final raw = <Offset>[];
    for (final p in pts) {
      final o = Offset(p.longitude * k, -p.latitude);
      raw.add(o);
      minX = math.min(minX, o.dx);
      maxX = math.max(maxX, o.dx);
      minY = math.min(minY, o.dy);
      maxY = math.max(maxY, o.dy);
    }
    final w = math.max(0.0, size.width - 2 * pad);
    final h = math.max(0.0, size.height - 2 * pad);
    final spanX = maxX - minX;
    final spanY = maxY - minY;
    final centre = size.center(Offset.zero);
    if (spanX <= 1e-9 && spanY <= 1e-9) return [centre];
    final scale = math.min(spanX > 1e-9 ? w / spanX : double.infinity, spanY > 1e-9 ? h / spanY : double.infinity);
    final mid = Offset((minX + maxX) / 2, (minY + maxY) / 2);
    return [for (final o in raw) centre + (o - mid) * scale];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final pts = project(points, size);
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      _dot(canvas, pts.first, startColor);
      return;
    }
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    _dot(canvas, pts.first, startColor);
    _dot(canvas, pts.last, endColor);
  }

  void _dot(Canvas canvas, Offset at, Color color) {
    canvas.drawCircle(at, 6, Paint()..color = ringColor);
    canvas.drawCircle(at, 4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(RouteSketchPainter old) =>
      !identical(old.points, points) ||
      old.lineColor != lineColor ||
      old.startColor != startColor ||
      old.endColor != endColor ||
      old.ringColor != ringColor;
}

/// Opens the share preview: the card, "Share image" and "Share as text".
/// [text] is what "Share as text" (and the fallback) shares; default: the card's facts.
Future<void> showRideShareSheet(BuildContext context, RideShareData data, {String? text}) {
  return showAppSheet<void>(
    context,
    title: 'Share ride',
    isScrollControlled: true,
    builder: (_) => RideSharePreview(data: data, text: text),
  );
}

/// The card inside a [RepaintBoundary], and the two share buttons.
class RideSharePreview extends StatefulWidget {
  final RideShareData data;
  final String? text;

  const RideSharePreview({super.key, required this.data, this.text});

  /// Renders the boundary under [key] to PNG bytes, about [targetWidthPx] wide.
  /// Returns null when there is nothing to capture.
  static Future<Uint8List?> capturePng(GlobalKey key, {double targetWidthPx = 1080}) async {
    final ro = key.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary || !ro.hasSize || ro.size.width <= 0) return null;
    final ratio = (targetWidthPx / ro.size.width).clamp(2.0, 4.0);
    final image = await ro.toImage(pixelRatio: ratio);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      return bytes?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  @override
  State<RideSharePreview> createState() => _RideSharePreviewState();
}

class _RideSharePreviewState extends State<RideSharePreview> {
  final GlobalKey _boundary = GlobalKey();
  bool _busy = false;

  String get _text => widget.text ?? widget.data.toText();
  String get _subject => 'CoRoute ride: ${widget.data.tripName}';

  Rect? _origin(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Future<void> _shareText(Rect? origin) {
    return SharePlus.instance.share(ShareParams(text: _text, subject: _subject, sharePositionOrigin: origin));
  }

  Future<void> _shareImage(BuildContext buttonContext) async {
    if (_busy) return;
    final origin = _origin(buttonContext);
    setState(() => _busy = true);
    try {
      Uint8List? png;
      try {
        png = await RideSharePreview.capturePng(_boundary);
      } catch (e) {
        debugPrint('share card capture note: $e');
        png = null;
      }
      if (png == null || png.isEmpty) {
        await _shareText(origin); // the image could not be made: share the same facts as text
        return;
      }
      try {
        await SharePlus.instance.share(ShareParams(
          files: [XFile.fromData(png, mimeType: 'image/png', name: widget.data.fileName)],
          subject: _subject,
          sharePositionOrigin: origin,
        ));
      } catch (e) {
        debugPrint('share card file note: $e');
        await _shareText(origin);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open sharing.')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: RepaintBoundary(key: _boundary, child: RideShareCard(data: widget.data)),
              ),
            ),
          ),
        ),
        const SizedBox(height: Space.s16),
        Builder(
          builder: (bc) => FilledButton.icon(
            onPressed: _busy ? null : () => _shareImage(bc),
            icon: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.image_rounded),
            label: const Text('Share image', maxLines: 1, overflow: TextOverflow.ellipsis),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          ),
        ),
        const SizedBox(height: Space.s8),
        Builder(
          builder: (bc) => OutlinedButton.icon(
            onPressed: _busy ? null : () => _shareText(_origin(bc)),
            icon: const Icon(Icons.notes_rounded),
            label: const Text('Share as text', maxLines: 1, overflow: TextOverflow.ellipsis),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          ),
        ),
      ],
    );
  }
}
