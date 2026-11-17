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
import 'package:coroute_app/core/ui/coroute_logo.dart';
import '../../domain/share/ride_card.dart';

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

  /// The route sketch: this rider's recorded track only (never the planned
  /// line, which may contain roads nobody rode). May be empty.
  final List<LatLng> sketch;

  /// Indices in [sketch] where a new ridden piece starts (after a signal gap):
  /// the sketch is not drawn across them.
  final Set<int> sketchBreaks;

  /// v3.63: my CoRoute rider score and level (null = not ready); road hazards logged on the ride and SOS count
  /// (null = not known). Only real numbers are printed.
  final int? score;
  final String? scoreLevel;
  final int? hazards;
  final int? sos;

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
    this.sketchBreaks = const {},
    this.score,
    this.scoreLevel,
    this.hazards,
    this.sos,
  });

  bool get hasDistance => distanceM > 0 && distanceM.isFinite;
  bool get hasRiding => (ridingMs ?? 0) > 0;

  String get dateText => DateFormat('EEE d MMM yyyy').format(date);

  /// v3.63 privacy: only where the ride went ("Ride to Nandi Hills"), never where it started (often home).
  String get routeText => RideCard.routeLine(to);

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
      if (RideCard.scoreOf(score, scoreLevel) != null) '${RideCard.scoreOf(score, scoreLevel)!.label}: ${score!}',
      if (RideCard.hazardsText(hazards) != null) RideCard.hazardsText(hazards)!,
      if (RideCard.safetyLine(sos: sos) != null) RideCard.safetyLine(sos: sos)!,
    ].join('\n');
  }

  /// Ridden pieces as one point list for [sketch] plus the indices where each
  /// later piece starts ([sketchBreaks]). Points without a position are dropped.
  static ({List<LatLng> points, Set<int> breaks}) joinPieces(List<List<LatLng>> pieces) {
    final pts = <LatLng>[];
    final breaks = <int>{};
    for (final piece in pieces) {
      final clean = cleanPoints(piece);
      if (clean.isEmpty) continue;
      if (pts.isNotEmpty) breaks.add(pts.length);
      pts.addAll(clean);
    }
    return (points: pts, breaks: breaks);
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
/// v3.63: [format] gives the exact shape of the shared image (square for WhatsApp, 9:16 for Instagram Stories);
/// the route sketch takes the room that is left.
class RideShareCard extends StatelessWidget {
  final RideShareData data;
  final RideCardFormat format;

  const RideShareCard({super.key, required this.data, this.format = RideCardFormat.square});

  static const AppPalette _p = AppPalette.light;

  @override
  Widget build(BuildContext context) {
    final score = RideCard.scoreOf(data.score, data.scoreLevel);
    final stats = <_CardStat>[
      if (data.hasDistance) _distanceStat(data.distanceM),
      if (data.hasRiding) _CardStat(value: formatDuration(Duration(milliseconds: data.ridingMs!)), label: 'Riding time'),
      if (score != null) _CardStat(value: score.value, label: score.label),
      if (data.riders > 0) _CardStat(value: '${data.riders}', label: data.riders == 1 ? 'Rider' : 'Riders'),
      if (score == null || format == RideCardFormat.story) _CardStat(value: '${data.stops}', label: data.stops == 1 ? 'Stop' : 'Stops'),
    ];
    final safety = <String>[
      if (RideCard.hazardsText(data.hazards) != null) RideCard.hazardsText(data.hazards)!,
      if (RideCard.safetyLine(sos: data.sos) != null) RideCard.safetyLine(sos: data.sos)!,
    ];
    final route = data.routeText;
    final story = format == RideCardFormat.story;
    final baseWidth = story ? 360.0 : 400.0;
    final baseHeight = baseWidth / format.aspect;
    // The image keeps its layout at large font sizes (up to x1.3) and scales to fit any card box.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: AspectRatio(
        aspectRatio: format.aspect,
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: baseWidth,
            height: baseHeight,
            child: Container(
              padding: const EdgeInsets.all(Space.s12),
              color: _p.bg,
              child: Container(
                padding: EdgeInsets.all(story ? Space.s24 : Space.s16),
                decoration: BoxDecoration(
                  color: _p.card,
                  borderRadius: Radii.xlAll,
                  border: Border.all(color: _p.border, width: 2),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                Row(
                  children: [
                    // v3.58 logo on every shared ride card.
                    CoRouteWordmark(fontSize: story ? 22 : 18, color: _p.text),
                    const SizedBox(width: Space.s8),
                    Expanded(
                      child: Text(
                        data.dateText,
                        textAlign: TextAlign.end,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption.copyWith(color: _p.muted, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: story ? Space.s24 : Space.s12),
                Text(
                  data.tripName.isEmpty ? 'Group ride' : data.tripName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.headline.copyWith(color: _p.text, fontSize: story ? 26 : 20),
                ),
                if (route.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.s4),
                    child: Text(route, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: _p.muted)),
                  ),
                const SizedBox(height: Space.s12),
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: _p.brand, borderRadius: Radii.lgAll),
                    child: data.sketch.isEmpty
                        ? Center(child: Icon(Icons.two_wheeler_rounded, size: story ? 96 : 64, color: Colors.white.withValues(alpha: 0.85)))
                        : CustomPaint(
                            painter: RouteSketchPainter(
                              points: data.sketch,
                              breaks: data.sketchBreaks,
                              lineColor: Colors.white,
                              startColor: Colors.white,
                              endColor: _p.brand,
                              ringColor: Colors.white,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: Space.s12),
                LayoutBuilder(builder: (context, c) {
                  final w = (c.maxWidth - Space.s8) / 2;
                  return Wrap(
                    spacing: Space.s8,
                    runSpacing: Space.s8,
                    children: [for (final s in stats) SizedBox(width: w, child: s)],
                  );
                }),
                if (safety.isNotEmpty) ...[
                  const SizedBox(height: Space.s8),
                  Row(children: [
                    Icon(Icons.verified_user_outlined, size: 18, color: _p.brand),
                    const SizedBox(width: Space.s8),
                    Expanded(
                      child: Text(safety.join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: AppText.label.copyWith(color: _p.text, fontWeight: FontWeight.w700)),
                    ),
                  ]),
                ],
              ],
            ),
          ),
        ),
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
      padding: const EdgeInsets.symmetric(horizontal: Space.s12, vertical: 10),
      decoration: BoxDecoration(color: _p.soft, borderRadius: Radii.mdAll),
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
                if (u != null) TextSpan(text: ' $u', style: AppText.label.copyWith(color: _p.muted, fontWeight: FontWeight.w700)),
              ]),
              maxLines: 1,
              style: AppText.title.copyWith(
                color: _p.text,
                fontWeight: FontWeight.w600,
                fontSize: 22,
                fontFeatures: const [ui.FontFeature.tabularFigures()],
              ),
            ),
          ),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: _p.muted, fontWeight: FontWeight.w700)),
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

  /// Indices in [points] where a new piece starts (not joined to the one before).
  final Set<int> breaks;

  /// Longer tracks are thinned to about this many points before drawing.
  static const int maxPoints = 600;

  RouteSketchPainter({
    required this.points,
    this.breaks = const {},
    required this.lineColor,
    required this.startColor,
    required this.endColor,
    required this.ringColor,
  });

  /// Projects [points] into [size] (with [pad]); public for tests.
  /// Which indices of [n] points are drawn (thinned to about [maxPoints], the last always kept).
  static List<int> keptIndices(int n) {
    final step = n > maxPoints ? (n / maxPoints).ceil() : 1;
    return [
      for (var i = 0; i < n; i += step) i,
      if (n > 0 && (n - 1) % step != 0) n - 1,
    ];
  }

  static List<Offset> project(List<LatLng> points, Size size, {double pad = 12}) {
    if (points.isEmpty || size.isEmpty) return const [];
    final pts = <LatLng>[for (final i in keptIndices(points.length)) points[i]];
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
    final kept = keptIndices(points.length);
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      // A signal gap between the two drawn points: lift the pen (no straight line across it).
      final from = i < kept.length ? kept[i - 1] : 0, to = i < kept.length ? kept[i] : 0;
      final cut = breaks.isNotEmpty && breaks.any((b) => b > from && b <= to);
      if (cut) {
        path.moveTo(pts[i].dx, pts[i].dy);
      } else {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
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
      !identical(old.breaks, breaks) ||
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
    // v3.63: exactly 1080 px wide (1080 x 1080 square, 1080 x 1920 story: the card has the format's aspect ratio).
    final ratio = (targetWidthPx / ro.size.width).clamp(1.0, 6.0);
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
  RideCardFormat _format = RideCardFormat.square;

  String get _text => widget.text ?? widget.data.toText();
  String get _subject => 'CoRoute ride: ${widget.data.tripName}';

  Rect? _origin(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Future<void> _shareText(Rect? origin) async {
    if (_textBusy) return; // v3.63: a double tap opens the share sheet once
    _textBusy = true;
    try {
      await SharePlus.instance.share(ShareParams(text: _text, subject: _subject, sharePositionOrigin: origin));
    } finally {
      _textBusy = false;
    }
  }

  bool _textBusy = false;

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
          files: [XFile.fromData(png, mimeType: 'image/png', name: _format == RideCardFormat.story ? widget.data.fileName.replaceAll('.png', '_story.png') : widget.data.fileName)],
          subject: _subject,
          sharePositionOrigin: origin,
        ));
      } catch (e) {
        debugPrint('share card file note: $e');
        await _shareText(origin);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
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
        // v3.63: WhatsApp (square) or Instagram story (9:16).
        SegmentedButton<RideCardFormat>(
          key: const Key('ride_card_format'),
          segments: const [
            ButtonSegment(value: RideCardFormat.square, label: Text('WhatsApp'), icon: Icon(Icons.crop_square_rounded)),
            ButtonSegment(value: RideCardFormat.story, label: Text('Story'), icon: Icon(Icons.crop_portrait_rounded)),
          ],
          selected: {_format},
          onSelectionChanged: _busy ? null : (v) => setState(() => _format = v.first),
        ),
        const SizedBox(height: Space.s12),
        Flexible(
          child: SingleChildScrollView(
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: _format == RideCardFormat.story ? 300 : 400),
                child: RepaintBoundary(key: _boundary, child: RideShareCard(data: widget.data, format: _format)),
              ),
            ),
          ),
        ),
        const SizedBox(height: Space.s16),
        Builder(
          builder: (bc) => FilledButton.icon(
            onPressed: _busy ? null : () => _shareImage(bc),
            icon: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.image_outlined),
            label: const Text('Share image', maxLines: 1, overflow: TextOverflow.ellipsis),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          ),
        ),
        const SizedBox(height: 10),
        Builder(
          builder: (bc) => OutlinedButton.icon(
            onPressed: _busy ? null : () => _shareText(_origin(bc)),
            icon: const Icon(Icons.notes_outlined),
            label: const Text('Share as text', maxLines: 1, overflow: TextOverflow.ellipsis),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          ),
        ),
      ],
    );
  }
}
