import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/map_tiles.dart';
import '../../data/models/timeline_event_model.dart';
import '../../data/models/trip_plan_model.dart';
import '../../domain/tracking/replay_math.dart';
import '../timeline/member_colors.dart';

/// The map of a finished trip: every rider's route in their own colour, where
/// each rider started and finished, every place they waited (with how long),
/// the planned stops and the destination.
///
/// With [timeMs] set it becomes the replay map: routes fade, each rider gets
/// a bright 10-minute tail and a marker where they were at that moment.
class TripRouteMap extends StatefulWidget {
  final List<ReplayTrack> tracks;
  final Map<String, Color> colors;
  final TripPlan? plan;

  /// STOPPED timeline entries (with a place) to show as waiting points.
  final List<TimelineEventModel> stops;

  /// Riders to show; null shows everyone.
  final Set<String>? visible;
  final int? timeMs;
  final String? focusUserId;
  final LatLng? pin;
  final void Function(TimelineEventModel stop)? onStopTap;
  final void Function(PlanStop stop)? onPlanStopTap;
  final void Function(ReplayTrack track, bool start)? onRiderEndTap;

  /// Shortest wait drawn on the map (shorter ones stay on the timeline).
  final Duration minWait;

  const TripRouteMap({
    super.key,
    required this.tracks,
    required this.colors,
    this.plan,
    this.stops = const [],
    this.visible,
    this.timeMs,
    this.focusUserId,
    this.pin,
    this.onStopTap,
    this.onPlanStopTap,
    this.onRiderEndTap,
    this.minWait = const Duration(minutes: 2),
  });

  /// "12m", "1h 05m": short enough for a map label.
  static String shortDuration(int ms) {
    final m = (ms / 60000).round();
    if (m < 60) return '${m < 1 ? 1 : m}m';
    return '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
  }

  /// Readable text colour on a filled [c].
  static Color onColor(Color c) => c.computeLuminance() > 0.4 ? Colors.black : Colors.white;

  @override
  State<TripRouteMap> createState() => _TripRouteMapState();
}

class _Prepared {
  final ReplayTrack track;
  final List<List<LatLng>> pieces;
  final List<List<LatLng>> gaps;
  _Prepared(this.track, this.pieces, this.gaps);
}

class _TripRouteMapState extends State<TripRouteMap> {
  List<_Prepared> _prepared = [];
  LatLngBounds? _bounds;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(TripRouteMap old) {
    super.didUpdateWidget(old);
    // Converting the routes is done once, not on every replay frame.
    if (!identical(old.tracks, widget.tracks) || !identical(old.plan, widget.plan)) _prepare();
  }

  void _prepare() {
    _prepared = [
      for (final t in widget.tracks)
        () {
          final s = t.split();
          return _Prepared(
            t,
            [for (final p in s.pieces) [for (final q in p) LatLng(q.lat, q.lng)]],
            [for (final (a, b) in s.gaps) [LatLng(a.lat, a.lng), LatLng(b.lat, b.lng)]],
          );
        }(),
    ];
    final all = <LatLng>[
      for (final p in _prepared) for (final piece in p.pieces) ...piece,
      if (widget.plan?.destination != null) LatLng(widget.plan!.destination!.lat, widget.plan!.destination!.lng),
      if (widget.plan?.start != null) LatLng(widget.plan!.start!.lat, widget.plan!.start!.lng),
      for (final s in widget.plan?.stops ?? const <PlanStop>[]) LatLng(s.lat, s.lng),
    ];
    _bounds = all.length >= 2 ? LatLngBounds.fromPoints(all) : null;
  }

  bool _shown(String userId) => widget.visible == null || widget.visible!.contains(userId);
  Color _color(String userId) => widget.colors[userId] ?? AppTheme.neonCyan;

  @override
  Widget build(BuildContext context) {
    final replay = widget.timeMs != null;
    final focus = widget.focusUserId;
    final shown = _prepared.where((p) => _shown(p.track.userId)).toList();
    final fallback = widget.plan?.destination != null
        ? LatLng(widget.plan!.destination!.lat, widget.plan!.destination!.lng)
        : (widget.plan?.start != null ? LatLng(widget.plan!.start!.lat, widget.plan!.start!.lng) : null);

    return FlutterMap(
      options: MapOptions(
        initialCenter: widget.pin ?? _bounds?.center ?? fallback ?? const LatLng(AppConstants.defaultMapLat, AppConstants.defaultMapLng),
        initialZoom: widget.pin != null ? 15 : (_bounds == null && fallback == null ? 5 : 13),
        initialCameraFit: (widget.pin == null && _bounds != null) ? CameraFit.bounds(bounds: _bounds!, padding: const EdgeInsets.all(48)) : null,
      ),
      children: [
        TileLayer(tileBuilder: mapTileBuilder, urlTemplate: AppConstants.osmTileUrl, userAgentPackageName: AppConstants.osmUserAgent),
        PolylineLayer(polylines: [
          // Dark casing under every route so a colour stays visible on any map background.
          for (final p in shown)
            for (final piece in p.pieces)
              Polyline(points: piece, strokeWidth: (p.track.userId == focus ? 7 : 6), color: AppTheme.obsidianVoid.withOpacity(replay ? 0.25 : 0.55)),
          for (final p in shown)
            for (final piece in p.pieces)
              Polyline(
                points: piece,
                strokeWidth: p.track.userId == focus ? 5 : 4,
                color: _color(p.track.userId).withOpacity(replay ? (focus == null || p.track.userId == focus ? 0.45 : 0.2) : 1),
              ),
          // Where the phone had no signal: a dotted link, not a ridden line.
          for (final p in shown)
            for (final g in p.gaps)
              Polyline(points: g, strokeWidth: 2.5, color: _color(p.track.userId).withOpacity(0.8), pattern: StrokePattern.dotted()),
          if (replay)
            for (final p in shown)
              Polyline(
                points: [for (final q in p.track.tail(widget.timeMs!)) LatLng(q.lat, q.lng)],
                strokeWidth: p.track.userId == focus ? 7 : 5.5,
                color: _color(p.track.userId),
              ),
        ]),
        MarkerLayer(markers: [
          ..._planMarkers(),
          ..._waitMarkers(),
          ..._riderEnds(shown),
          if (widget.pin != null)
            Marker(point: widget.pin!, width: 36, height: 36, alignment: Alignment.topCenter, child: Icon(Icons.location_on, color: AppTheme.hyperAmber, size: 34)),
          if (replay) ..._riderNow(shown),
        ]),
      ],
    );
  }

  List<Marker> _planMarkers() {
    final plan = widget.plan;
    if (plan == null) return const [];
    var n = 0;
    return [
      for (final s in plan.stops)
        () {
          if (!s.isSkipped) n++;
          final label = s.isSkipped ? '' : '$n';
          final fill = s.isSkipped ? AppTheme.textMuted : (s.isVisited ? AppTheme.emeraldSafe : AppTheme.hyperAmber);
          return Marker(
            point: LatLng(s.lat, s.lng),
            width: 28,
            height: 28,
            child: GestureDetector(
              onTap: widget.onPlanStopTap == null ? null : () => widget.onPlanStopTap!(s),
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(color: fill, shape: BoxShape.circle, border: Border.all(color: AppTheme.slateCard, width: 2)),
                child: s.isVisited
                    ? const Icon(Icons.check_rounded, size: 15, color: Colors.black)
                    : Text(label, style: const TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.bold)),
              ),
            ),
          );
        }(),
      if (plan.destination != null)
        Marker(
          point: LatLng(plan.destination!.lat, plan.destination!.lng),
          width: 40,
          height: 40,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(color: AppTheme.slateCard, shape: BoxShape.circle, border: Border.all(color: AppTheme.laserRed, width: 2.5)),
            child: Icon(Icons.sports_score_rounded, color: AppTheme.laserRed, size: 22),
          ),
        ),
    ];
  }

  List<Marker> _waitMarkers() {
    final out = <Marker>[];
    for (final e in widget.stops) {
      if (e.type != 'STOPPED' || !e.hasPlace || e.userId == null || !_shown(e.userId!)) continue;
      if (!e.open && e.durationMs < widget.minWait.inMilliseconds) continue;
      final c = _color(e.userId!);
      final dur = e.open ? (DateTime.now().millisecondsSinceEpoch - e.startedAt) : e.durationMs;
      out.add(Marker(
        point: LatLng(e.lat!, e.lng!),
        width: 62,
        height: 26,
        child: GestureDetector(
          onTap: widget.onStopTap == null ? null : () => widget.onStopTap!(e),
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: AppTheme.slateCard, width: 1.5),
              boxShadow: [BoxShadow(color: AppTheme.shadow, blurRadius: 4)],
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.pause_rounded, size: 13, color: TripRouteMap.onColor(c)),
              Flexible(
                child: Text(TripRouteMap.shortDuration(dur),
                    maxLines: 1, overflow: TextOverflow.clip, style: TextStyle(color: TripRouteMap.onColor(c), fontSize: 11, fontWeight: FontWeight.bold)),
              ),
            ]),
          ),
        ),
      ));
    }
    return out;
  }

  /// Each rider's own start (filled dot) and finish (flag) in their colour.
  List<Marker> _riderEnds(List<_Prepared> shown) {
    final out = <Marker>[];
    for (final p in shown) {
      final pts = p.track.points;
      if (pts.length < 2) continue;
      final c = _color(p.track.userId);
      final first = pts.first, last = pts.last;
      out.add(Marker(
        point: LatLng(first.lat, first.lng),
        width: 24,
        height: 24,
        child: GestureDetector(
          onTap: widget.onRiderEndTap == null ? null : () => widget.onRiderEndTap!(p.track, true),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: AppTheme.slateCard, width: 2.5)),
            child: Icon(Icons.play_arrow_rounded, size: 14, color: TripRouteMap.onColor(c)),
          ),
        ),
      ));
      out.add(Marker(
        point: LatLng(last.lat, last.lng),
        width: 30,
        height: 30,
        alignment: Alignment.topCenter,
        child: GestureDetector(
          onTap: widget.onRiderEndTap == null ? null : () => widget.onRiderEndTap!(p.track, false),
          child: Icon(Icons.flag_rounded, size: 28, color: c, shadows: [Shadow(color: AppTheme.obsidianVoid, blurRadius: 3)]),
        ),
      ));
    }
    return out;
  }

  List<Marker> _riderNow(List<_Prepared> shown) {
    final out = <Marker>[];
    for (final p in shown) {
      final at = p.track.positionAt(widget.timeMs!);
      if (at == null) continue;
      final c = _color(p.track.userId);
      out.add(Marker(
        point: LatLng(at.lat, at.lng),
        width: 34,
        height: 34,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppTheme.slateCard,
            shape: BoxShape.circle,
            border: Border.all(color: c, width: p.track.userId == widget.focusUserId ? 3.5 : 2.5),
          ),
          child: Text(MemberColors.initials(p.track.name), style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.bold)),
        ),
      ));
    }
    return out;
  }
}

/// The key under the map: what each symbol means.
class TripMapLegend extends StatelessWidget {
  const TripMapLegend({super.key});

  @override
  Widget build(BuildContext context) {
    Widget item(Widget icon, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
          icon,
          const SizedBox(width: 4),
          Text(text, style: TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
        ]);
    final c = AppTheme.textSecondary;
    return Wrap(spacing: 14, runSpacing: 6, children: [
      item(Container(width: 14, height: 14, decoration: BoxDecoration(color: c, shape: BoxShape.circle), child: Icon(Icons.play_arrow_rounded, size: 10, color: AppTheme.slateCard)), 'started'),
      item(Icon(Icons.flag_rounded, size: 15, color: c), 'finished'),
      item(Container(padding: const EdgeInsets.symmetric(horizontal: 4), decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(7)), child: Icon(Icons.pause_rounded, size: 11, color: AppTheme.slateCard)), 'waited'),
      item(Container(width: 14, height: 14, decoration: BoxDecoration(color: AppTheme.hyperAmber, shape: BoxShape.circle)), 'planned stop'),
      item(Icon(Icons.sports_score_rounded, size: 15, color: AppTheme.laserRed), 'destination'),
      item(SizedBox(width: 18, child: Text('·····', style: TextStyle(color: c, fontSize: 11, height: 1))), 'no signal'),
    ]);
  }
}
