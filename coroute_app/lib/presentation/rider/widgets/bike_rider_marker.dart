import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../../core/ui/rider_status.dart';
import '../../../domain/garage/bike_type.dart';
import '../../../domain/ride/bike_markers.dart';
import '../../garage/bike_silhouette.dart';
import 'smooth_rider_marker_layer.dart' show MarkerHeading;

/// 3.56 3D bike marker: a top-down rendered motorcycle with its rider (two people with a pillion),
/// in the bike's type and colour, turned to the rider's heading like a navigation app's 3D arrow,
/// with a soft shadow on the map. No plate. State cues suit the 3D look: a soft ground halo / ring
/// under the bike (rider colour while moving, amber stopped / warning, pulsing red SOS, blue glow
/// for me, white ring and a little larger when selected), a status dot and a role chip (L lead,
/// S sweeper) that stay upright, desaturated and translucent when stale.
///
/// The images come from assets/map_bikes ([BikeSprites], rendered by tool/map_bikes). Per look
/// (type + colour + people + pixel size, [BikeMarkerKey]) base, tinted paint and gloss are merged
/// once into one bitmap ([BikeSpriteCache]); every marker draws that bitmap and the shadow, turned
/// by a transform, so dozens of riders cost two textured quads each. If an image cannot be loaded
/// the marker falls back to the vector side silhouette ([BikeShapes]).
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
    this.upright = true,
    this.showStatusDot = true,
  });

  final String vehicleKind;
  final String vehicleColor;
  final Color fallbackColor;

  /// Halo colour while moving normally (the rider's colour; the lead's teal).
  final Color ring;
  final Color statusColor;

  /// Size class of the marker (kept from the plate design): the bike's square box is
  /// [widthFor] (height × 1.42) wide and tall.
  final double height;
  final bool twoUp;

  /// Degrees from north. Inside a [SmoothMarkerLayer] the layer's smoothed heading wins.
  final double heading;
  final BikeMarkerCue cue;
  final bool me;
  final bool selected;
  final String roleLetter;
  final Color roleColor;

  /// The marker is kept upright on a rotated map (flutter_map `Marker(rotate: true)`): the map's
  /// rotation is added to the heading. False when the marker turns with the map.
  final bool upright;
  final bool showStatusDot;

  /// The marker box for a size class [height].
  static double widthFor(double height) => height * 1.42;

  static const Color sosRed = Color(0xFFE53935);
  static const Color amber = Color(0xFFF59E0B);
  static const Color meBlue = Color(0xFF2F7CF6);

  @override
  Widget build(BuildContext context) {
    final box = widthFor(height);
    final bike = selected ? box * 1.12 : box;
    return SizedBox(
      width: box,
      height: box,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: IgnorePointer(child: _GroundHalo(cue: cue, me: me, selected: selected, ring: ring, statusColor: statusColor)),
          ),
          OverflowBox(
            maxWidth: bike,
            maxHeight: bike,
            child: SizedBox(
              width: bike,
              height: bike,
              child: Bike3d(
                vehicleKind: vehicleKind,
                vehicleColor: vehicleColor,
                fallbackColor: fallbackColor,
                twoUp: twoUp,
                heading: heading,
                stale: cue == BikeMarkerCue.stale,
                upright: upright,
              ),
            ),
          ),
          if (showStatusDot)
            Positioned(
              left: box * 0.8 - 6,
              top: box * 0.8 - 6,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: statusColor,
                  border: Border.all(color: const Color(0xFFFFFFFF), width: 2),
                  boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 2, offset: Offset(0, 1))],
                ),
              ),
            ),
          if (roleLetter.isNotEmpty)
            Positioned(
              left: box * 0.14 - 9,
              top: box * 0.14 - 8,
              child: Container(
                width: 18,
                height: 16,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  color: roleColor,
                  border: Border.all(color: const Color(0xFFFFFFFF), width: 1.5),
                  boxShadow: const [BoxShadow(color: Color(0x4D000000), blurRadius: 3, offset: Offset(0, 1))],
                ),
                child: Text(
                  roleLetter,
                  textScaler: TextScaler.noScaling,
                  style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 9, fontWeight: FontWeight.w900, height: 1),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The 3D bike alone (shadow + bike), filling its box and turned to the heading.
class Bike3d extends StatefulWidget {
  const Bike3d({
    super.key,
    required this.vehicleKind,
    required this.vehicleColor,
    required this.fallbackColor,
    this.twoUp = false,
    this.heading = 0,
    this.stale = false,
    this.upright = true,
  });

  final String vehicleKind;
  final String vehicleColor;
  final Color fallbackColor;
  final bool twoUp;
  final double heading;
  final bool stale;
  final bool upright;

  @override
  State<Bike3d> createState() => _Bike3dState();
}

class _Bike3dState extends State<Bike3d> {
  @override
  void initState() {
    super.initState();
    BikeSpriteCache.revision.addListener(_onLoaded);
  }

  @override
  void dispose() {
    BikeSpriteCache.revision.removeListener(_onLoaded);
    super.dispose();
  }

  void _onLoaded() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final type = BikeType.parse(widget.vehicleKind) ?? BikeType.commuter;
    final argb = BikeColours.parse(widget.vehicleColor) ?? widget.fallbackColor.toARGB32();
    final people = widget.twoUp ? 2 : 1;
    final cfg = createLocalImageConfiguration(context);
    final sprites = BikeSpriteCache.setFor(type, people, cfg);
    final heading = MarkerHeading.maybeOf(context) ?? widget.heading;
    final rotation = widget.upright ? (MapCamera.maybeOf(context)?.rotation ?? 0.0) : 0.0;
    final screen = ((heading + rotation) % 360 + 360) % 360;
    Widget body;
    if (sprites == null) {
      if (!BikeSpriteCache.failed(type, people, cfg)) return const SizedBox.expand();
      // Images missing: the vector side silhouette (faces the way the rider goes, left / right).
      final key = BikeMarkerKey(type: type, argb: argb, twoUp: widget.twoUp, cue: BikeMarkerCue.normal, size: 48);
      body = CustomPaint(painter: _GlyphPainter(key, screen > 180 && screen < 360), size: Size.infinite);
    } else {
      final merged = BikeSpriteCache.merged(type, people, argb, sprites);
      final angle = screen * math.pi / 180.0;
      body = LayoutBuilder(
        builder: (context, c) {
          final k = c.maxWidth / BikeSprites.mapBox;
          return Stack(
            fit: StackFit.expand,
            children: [
              // The shadow turns with the bike but falls the same way on the map (light top left).
              Transform.translate(
                offset: Offset(BikeSprites.shadowDx * k, BikeSprites.shadowDy * k),
                child: Transform.rotate(
                  angle: angle,
                  child: Opacity(opacity: 0.9, child: RawImage(image: sprites.shadow, fit: BoxFit.fill, filterQuality: FilterQuality.medium)),
                ),
              ),
              Transform.rotate(
                angle: angle,
                child: RepaintBoundary(child: RawImage(image: merged, fit: BoxFit.fill, filterQuality: FilterQuality.medium)),
              ),
            ],
          );
        },
      );
    }
    if (widget.stale) {
      body = Opacity(opacity: 0.55, child: ColorFiltered(colorFilter: const ColorFilter.matrix(_greyscale), child: body));
    }
    return body;
  }
}

const List<double> _greyscale = <double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0,
];

/// The soft ground halo / ring under the bike (does not turn). SOS pulses (unless the platform
/// asks for reduced motion).
class _GroundHalo extends StatefulWidget {
  const _GroundHalo({required this.cue, required this.me, required this.selected, required this.ring, required this.statusColor});
  final BikeMarkerCue cue;
  final bool me;
  final bool selected;
  final Color ring;
  final Color statusColor;

  @override
  State<_GroundHalo> createState() => _GroundHaloState();
}

class _GroundHaloState extends State<_GroundHalo> with SingleTickerProviderStateMixin {
  AnimationController? _pulse;

  void _sync() {
    final want = widget.cue == BikeMarkerCue.sos && !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    if (want && _pulse == null) {
      _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
    } else if (!want && _pulse != null) {
      _pulse!.dispose();
      _pulse = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _GroundHalo oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _pulse?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _pulse;
    HaloPainter painter(double t) => HaloPainter(cue: widget.cue, me: widget.me, selected: widget.selected, ring: widget.ring, pulse: t);
    if (p == null) return CustomPaint(painter: painter(0.5));
    return AnimatedBuilder(animation: p, builder: (_, _) => CustomPaint(painter: painter(p.value)));
  }
}

/// Paints the ground halo for a cue (also used by the preview tool's maths: tool/map_bikes/composite.js).
class HaloPainter extends CustomPainter {
  const HaloPainter({required this.cue, required this.me, required this.selected, required this.ring, this.pulse = 0.5});
  final BikeMarkerCue cue;
  final bool me;
  final bool selected;
  final Color ring;
  final double pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide * 0.44 * (selected ? 1.12 : 1);
    void glow(Color color, double a0, double a1, double rr) {
      final shader = RadialGradient(colors: [color.withValues(alpha: a0), color.withValues(alpha: a1)], stops: const [0.2, 1.0])
          .createShader(Rect.fromCircle(center: c, radius: rr * 1.05));
      canvas.drawCircle(c, rr * 1.05, Paint()..shader = shader);
    }

    void ringAt(Color color, double alpha, double width, double rr) => canvas.drawCircle(
          c,
          rr,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = width
            ..color = color.withValues(alpha: alpha),
        );

    switch (cue) {
      case BikeMarkerCue.sos:
        final t = pulse;
        glow(BikeMarkerBadge.sosRed, 0.0, 0.32, r * 1.25);
        ringAt(BikeMarkerBadge.sosRed, 0.6 * (1 - t), 2.5, r * (1.0 + 0.45 * t));
        ringAt(BikeMarkerBadge.sosRed, 0.95, 3, r);
      case BikeMarkerCue.warning:
        glow(BikeMarkerBadge.amber, 0.05, 0.22, r);
        ringAt(BikeMarkerBadge.amber, 0.95, 2.5, r);
      case BikeMarkerCue.stopped when !me:
        glow(BikeMarkerBadge.amber, 0.04, 0.14, r);
        ringAt(BikeMarkerBadge.amber, 0.8, 2, r);
      case _ when me:
        glow(BikeMarkerBadge.meBlue, 0.32, 0.0, r * 1.3);
        ringAt(BikeMarkerBadge.meBlue, 0.9, 2.5, r);
      case BikeMarkerCue.stale:
        ringAt(ring, 0.35, 1.5, r);
      default:
        glow(ring, 0.03, 0.14, r);
        ringAt(ring, 0.7, 2, r);
    }
    if (selected) {
      ringAt(const Color(0x2E000000), 1, 1, r + 4.6);
      ringAt(const Color(0xFFFFFFFF), 1, 2.5, r + 3);
    }
  }

  @override
  bool shouldRepaint(covariant HaloPainter old) =>
      old.cue != cue || old.me != me || old.selected != selected || old.ring != ring || old.pulse != pulse;
}

/// The four layers of one bike look, decoded.
class BikeSpriteSet {
  const BikeSpriteSet(this.shadow, this.base, this.paint, this.gloss);
  final ui.Image shadow, base, paint, gloss;
}

/// Loads the 3D bike images (resolution-aware: 1x / 2.0x / 3.0x by the screen's pixel ratio) and
/// keeps one merged bitmap per look. [revision] ticks when images arrive so markers redraw.
class BikeSpriteCache {
  BikeSpriteCache._();

  static final ValueNotifier<int> revision = ValueNotifier<int>(0);
  static final Map<String, ui.Image> _ready = <String, ui.Image>{};
  static final Set<String> _loading = <String>{};
  static final Set<String> _failed = <String>{};
  static final BikeGlyphLru<ui.Image> _merged = BikeGlyphLru<ui.Image>(max: 64, onEvict: (i) => i.dispose());

  static String _id(String path, ImageConfiguration cfg) => '$path@${(cfg.devicePixelRatio ?? 1).toStringAsFixed(1)}';

  static bool _bumpQueued = false;

  // Listeners may fire synchronously (an image already in the cache) while a marker builds:
  // markers are told after the current frame's work, once per batch.
  static void _bump() {
    if (_bumpQueued) return;
    _bumpQueued = true;
    scheduleMicrotask(() {
      _bumpQueued = false;
      revision.value++;
    });
  }

  static void _load(String path, ImageConfiguration cfg) {
    final id = _id(path, cfg);
    if (_ready.containsKey(id) || _failed.contains(id) || !_loading.add(id)) return;
    final stream = AssetImage(path).resolve(cfg);
    late final ImageStreamListener l;
    l = ImageStreamListener(
      (info, _) {
        _ready[id] = info.image;
        _loading.remove(id);
        stream.removeListener(l);
        _bump();
      },
      onError: (e, _) {
        _failed.add(id);
        _loading.remove(id);
        stream.removeListener(l);
        _bump();
      },
    );
    stream.addListener(l);
  }

  /// The decoded layers for [type] with [people], or null while loading / when missing
  /// ([failed] tells which). Starts loading on first use.
  static BikeSpriteSet? setFor(BikeType type, int people, ImageConfiguration cfg) {
    final out = <ui.Image>[];
    for (final l in BikeLayer.values) {
      final path = BikeSprites.map(type, people, l);
      var img = _ready[_id(path, cfg)];
      if (img == null) {
        _load(path, cfg);
        img = _ready[_id(path, cfg)]; // already decoded: arrives synchronously
      }
      if (img != null) out.add(img);
    }
    if (out.length < BikeLayer.values.length) return null;
    return BikeSpriteSet(out[0], out[1], out[2], out[3]);
  }

  /// True when an image of this look could not be loaded (the vector silhouette is drawn).
  static bool failed(BikeType type, int people, ImageConfiguration cfg) =>
      BikeLayer.values.any((l) => _failed.contains(_id(BikeSprites.map(type, people, l), cfg)));

  /// Starts loading every map bike image for this screen (call once when a ride map opens).
  static void precache(BuildContext context) {
    final cfg = createLocalImageConfiguration(context);
    for (final t in BikeType.values) {
      for (final p in const [1, 2]) {
        setFor(t, p, cfg);
      }
    }
  }

  /// Base + paint tinted with [argb] (rgb × colour, [BikeSprites.paintArgb]) + gloss, merged into
  /// one bitmap per look and pixel size (LRU of 64).
  static ui.Image merged(BikeType type, int people, int argb, BikeSpriteSet s) {
    final key = BikeMarkerKey(type: type, argb: argb, twoUp: people >= 2, cue: BikeMarkerCue.normal, size: BikeMarkerKey.bucket(s.base.width.toDouble()));
    return _merged.putIfAbsent(key, () {
      final w = s.base.width, h = s.base.height;
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      final dst = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
      void draw(ui.Image img, [Paint? p]) => c.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), dst, p ?? Paint());
      draw(s.base);
      draw(s.paint, Paint()..colorFilter = ColorFilter.mode(Color(BikeSprites.paintArgb(argb)), BlendMode.modulate));
      draw(s.gloss);
      final pic = rec.endRecording();
      final img = pic.toImageSync(w, h);
      pic.dispose();
      return img;
    });
  }

  static void clear() => _merged.clear();
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
    final s = math.min(size.width / w, size.height / h) * 0.9;
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

/// A far rider in a big group: a small 3D bike (no label), in the bike's colour and type.
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
            final h = math.min(c.maxHeight, c.maxWidth) / 1.42;
            return Center(
              child: BikeMarkerBadge(
                vehicleKind: vehicleKind,
                vehicleColor: vehicleColor,
                fallbackColor: color,
                ring: color,
                statusColor: color,
                height: h,
                twoUp: twoUp,
                showStatusDot: false,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A rider on an overview map (admin live maps, trip report / replay): the 3D bike in the bike's
/// type and colour (rider colour when unknown) turned to [heading], with the status dot.
/// [status] picks the cue (SOS red ring, stopped amber, faded when offline). Screen readers hear
/// "[name], [status]". With [onTap] the whole box is the touch target. These maps keep markers
/// turning with the map (no `rotate: true`), so the map's rotation is not added ([upright] false).
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
    this.upright = false,
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
  final bool upright;
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
            upright: upright,
          ),
        ),
      ),
    );
  }
}
