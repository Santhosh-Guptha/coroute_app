import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/map_tiles.dart';
import '../../core/ui/ui.dart';
import '../../data/models/timeline_event_model.dart';
import '../../data/models/trip_plan_model.dart';
import '../../domain/tracking/replay_math.dart';

/// The map of a finished trip: every rider's route in their own colour, where
/// each rider started and finished, every place they waited (with how long),
/// the planned stops, the planned route, where riders left the route, and the
/// destination.
///
/// With [timeMs] set it becomes the replay map: routes fade, each rider gets
/// a bright 10-minute tail and a marker where they were at that moment.
///
/// [highlightEvent] / [highlightTs] mark one timeline moment in place: the
/// camera moves there once and the place gets a ring that settles once (no
/// looping animation). Without a place, [highlightTs] shows where every rider
/// was at that moment.
class TripRouteMap extends StatefulWidget {
  final List<ReplayTrack> tracks;
  final Map<String, Color> colors;
  final TripPlan? plan;

  /// STOPPED timeline entries (with a place) to show as waiting points.
  final List<TimelineEventModel> stops;

  /// OFF_ROUTE timeline entries (with a place) to show as deviation markers.
  final List<TimelineEventModel> deviations;

  /// The planned route as a line (drawn dashed under the ridden routes).
  final List<LatLng>? plannedLine;

  /// Riders to show; null shows everyone.
  final Set<String>? visible;
  final int? timeMs;
  final String? focusUserId;
  final LatLng? pin;

  /// The timeline entry to highlight on the map (moves the camera once).
  final TimelineEventModel? highlightEvent;

  /// The moment to highlight; defaults to the start of [highlightEvent].
  final int? highlightTs;
  final void Function(TimelineEventModel stop)? onStopTap;
  final void Function(TimelineEventModel deviation)? onDeviationTap;
  final void Function(PlanStop stop)? onPlanStopTap;
  final void Function(ReplayTrack track, bool start)? onRiderEndTap;

  /// Shortest wait drawn on the map (shorter ones stay on the timeline).
  final Duration minWait;

  /// Waits at least this long are drawn as a long rest.
  final Duration longRest;

  const TripRouteMap({
    super.key,
    required this.tracks,
    required this.colors,
    this.plan,
    this.stops = const [],
    this.deviations = const [],
    this.plannedLine,
    this.visible,
    this.timeMs,
    this.focusUserId,
    this.pin,
    this.highlightEvent,
    this.highlightTs,
    this.onStopTap,
    this.onDeviationTap,
    this.onPlanStopTap,
    this.onRiderEndTap,
    this.minWait = const Duration(minutes: 2),
    this.longRest = RideThresholds.restingAfter,
  });

  /// "12m", "1h 05m": short enough for a map label.
  static String shortDuration(int ms) {
    final m = (ms / 60000).round();
    if (m < 60) return '${m < 1 ? 1 : m}m';
    return '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
  }

  /// Readable text colour on a filled [c].
  static Color onColor(Color c) => c.computeLuminance() > 0.4 ? Colors.black : Colors.white;

  /// The planned route as straight legs: start, the stops that were not
  /// skipped (in order), destination. Empty when fewer than two points.
  static List<LatLng> plannedLineOf(TripPlan? plan) {
    if (plan == null) return const [];
    final pts = <LatLng>[
      if (plan.start != null) LatLng(plan.start!.lat, plan.start!.lng),
      for (final s in plan.stops)
        if (!s.isSkipped) LatLng(s.lat, s.lng),
      if (plan.destination != null) LatLng(plan.destination!.lat, plan.destination!.lng),
    ];
    return pts.length >= 2 ? pts : const [];
  }

  @override
  State<TripRouteMap> createState() => TripRouteMapState();
}

class _Prepared {
  final ReplayTrack track;
  final List<List<LatLng>> pieces;
  final List<List<LatLng>> gaps;
  _Prepared(this.track, this.pieces, this.gaps);
}

class TripRouteMapState extends State<TripRouteMap> {
  final MapController _map = MapController();
  List<_Prepared> _prepared = [];
  LatLngBounds? _bounds;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(TripRouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Converting the routes is done once, not on every replay frame.
    final changed = !identical(oldWidget.tracks, widget.tracks) || !identical(oldWidget.plan, widget.plan);
    if (changed) _prepare();
    final moved = oldWidget.highlightEvent?.eventId != widget.highlightEvent?.eventId || oldWidget.highlightTs != widget.highlightTs;
    if (moved && (widget.highlightEvent != null || widget.highlightTs != null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusHighlight());
    } else if (changed && oldWidget.tracks.isEmpty && widget.tracks.isNotEmpty && widget.pin == null && widget.highlightEvent == null) {
      // Routes arrived after the map was first shown: show the whole trip.
      WidgetsBinding.instance.addPostFrameCallback((_) => showAll());
    }
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

  /// Moves the camera back to the whole trip.
  void showAll() {
    final b = _bounds;
    if (!mounted || b == null) return;
    try {
      _map.fitCamera(CameraFit.bounds(bounds: b, padding: const EdgeInsets.all(48)));
    } catch (_) {
      // The map is not laid out yet; the initial fit covers it.
    }
  }

  int? get _highlightMoment => widget.highlightTs ?? widget.highlightEvent?.startedAt;

  /// Where riders were at the highlighted moment (when the entry has no place).
  List<(_Prepared, ReplayPoint)> _positionsAt(int ts) {
    final out = <(_Prepared, ReplayPoint)>[];
    for (final p in _prepared) {
      if (!_shown(p.track.userId)) continue;
      final userId = widget.highlightEvent?.userId;
      if (userId != null && userId.isNotEmpty && p.track.userId != userId) continue;
      final at = p.track.positionAt(ts);
      if (at != null) out.add((p, at));
    }
    return out;
  }

  void _focusHighlight() {
    if (!mounted) return;
    final e = widget.highlightEvent;
    try {
      if (e != null && e.hasPlace) {
        final zoom = _map.camera.zoom < 14 ? 14.0 : _map.camera.zoom;
        _map.move(LatLng(e.lat!, e.lng!), zoom);
        return;
      }
      final ts = _highlightMoment;
      if (ts == null) return;
      final pts = [for (final (_, at) in _positionsAt(ts)) LatLng(at.lat, at.lng)];
      if (pts.isEmpty) return;
      _map.fitCamera(CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(64), maxZoom: 15));
    } catch (_) {
      // The map is not laid out yet; nothing to move.
    }
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
    final planned = widget.plannedLine;
    final h = widget.highlightEvent;
    final hPoint = h != null && h.hasPlace ? LatLng(h.lat!, h.lng!) : null;
    final hTs = _highlightMoment;
    final hRiders = (!replay && hPoint == null && hTs != null) ? _positionsAt(hTs) : const <(_Prepared, ReplayPoint)>[];
    final initial = widget.pin ?? hPoint;

    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: initial ?? _bounds?.center ?? fallback ?? const LatLng(AppConstants.defaultMapLat, AppConstants.defaultMapLng),
        initialZoom: initial != null ? 15 : (_bounds == null && fallback == null ? 5 : 13),
        initialCameraFit: (initial == null && _bounds != null) ? CameraFit.bounds(bounds: _bounds!, padding: const EdgeInsets.all(48)) : null,
      ),
      children: [
        appTileLayer(),
        PolylineLayer(polylines: [
          // The plan: a dashed neutral line under the ridden routes.
          if (planned != null && planned.length >= 2) ...[
            Polyline(points: planned, strokeWidth: 6, color: AppTheme.obsidianVoid.withOpacity(0.35)),
            Polyline(
              points: planned,
              strokeWidth: 3.5,
              color: AppTheme.textSecondary,
              pattern: StrokePattern.dashed(segments: const [14, 10]),
            ),
          ],
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
          ..._deviationMarkers(),
          ..._waitMarkers(),
          ..._riderEnds(shown),
          if (widget.pin != null)
            Marker(
              point: widget.pin!,
              width: 36,
              height: 36,
              alignment: Alignment.topCenter,
              child: Semantics(label: 'Selected place', child: Icon(Icons.location_on_rounded, color: AppTheme.hyperAmber, size: 34)),
            ),
          if (replay) ..._riderNow(shown, widget.timeMs!, widget.focusUserId),
          for (final (p, at) in hRiders) _riderMarker(p, at, true),
          if (h != null && hPoint != null) _highlightMarker(h, hPoint),
        ]),
      ],
    );
  }

  List<Marker> _planMarkers() {
    final plan = widget.plan;
    if (plan == null) return const [];
    return [
      for (final s in plan.stops)
        () {
          final kind = StopKind.fromCategory(s.category);
          final Color fill = s.isSkipped ? AppTheme.textMuted : (s.isVisited ? StatusColors.success : StatusColors.warning);
          final status = s.isSkipped ? 'skipped' : (s.isVisited ? 'visited' : 'not visited');
          final name = s.name.isEmpty ? kind.label : s.name;
          return Marker(
            point: LatLng(s.lat, s.lng),
            width: 48,
            height: 48,
            child: Semantics(
              button: widget.onPlanStopTap != null,
              label: 'Planned stop $name, $status',
              excludeSemantics: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onPlanStopTap == null ? null : () => widget.onPlanStopTap!(s),
                child: Center(
                  child: SizedBox(
                    width: 32,
                    height: 32,
                    child: Stack(clipBehavior: Clip.none, children: [
                      Positioned.fill(
                        child: Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: fill, shape: BoxShape.circle, border: Border.all(color: AppTheme.slateCard, width: 2)),
                          child: Icon(kind.icon, size: 18, color: TripRouteMap.onColor(fill)),
                        ),
                      ),
                      if (s.isVisited)
                        Positioned(
                          right: -4,
                          bottom: -4,
                          child: Container(
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(color: AppTheme.slateCard, shape: BoxShape.circle, border: Border.all(color: StatusColors.success, width: 1.5)),
                            child: Icon(Icons.check_rounded, size: 12, color: StatusColors.success),
                          ),
                        ),
                    ]),
                  ),
                ),
              ),
            ),
          );
        }(),
      if (plan.destination != null)
        Marker(
          point: LatLng(plan.destination!.lat, plan.destination!.lng),
          width: 40,
          height: 40,
          child: Semantics(
            label: plan.destination!.name.isEmpty ? 'Destination' : 'Destination ${plan.destination!.name}',
            excludeSemantics: true,
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(color: AppTheme.slateCard, shape: BoxShape.circle, border: Border.all(color: StatusColors.critical, width: 2.5)),
              child: Icon(Icons.sports_score_rounded, color: StatusColors.critical, size: 22),
            ),
          ),
        ),
    ];
  }

  /// Where a rider left the planned route.
  List<Marker> _deviationMarkers() {
    final out = <Marker>[];
    for (final e in widget.deviations) {
      if (e.type != 'OFF_ROUTE' || !e.hasPlace) continue;
      if (e.userId != null && !_shown(e.userId!)) continue;
      out.add(Marker(
        point: LatLng(e.lat!, e.lng!),
        width: 48,
        height: 48,
        child: Semantics(
          button: widget.onDeviationTap != null,
          label: '${e.userName.isEmpty ? 'A rider' : e.userName} went off the route',
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onDeviationTap == null ? null : () => widget.onDeviationTap!(e),
            child: Center(
              child: Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppTheme.slateCard,
                  borderRadius: Radii.smAll,
                  border: Border.all(color: StatusColors.warning, width: 2),
                ),
                child: Icon(Icons.wrong_location_rounded, size: 18, color: StatusColors.warning),
              ),
            ),
          ),
        ),
      ));
    }
    return out;
  }

  List<Marker> _waitMarkers() {
    final out = <Marker>[];
    for (final e in widget.stops) {
      if (e.type != 'STOPPED' || !e.hasPlace || e.userId == null || !_shown(e.userId!)) continue;
      if (!e.open && e.durationMs < widget.minWait.inMilliseconds) continue;
      final c = _color(e.userId!);
      final dur = e.open ? (DateTime.now().millisecondsSinceEpoch - e.startedAt) : e.durationMs;
      final long = dur >= widget.longRest.inMilliseconds;
      final who = e.userName.isEmpty ? 'A rider' : e.userName;
      out.add(Marker(
        point: LatLng(e.lat!, e.lng!),
        width: 76,
        height: 32,
        child: Semantics(
          button: widget.onStopTap != null,
          label: '$who ${long ? 'rested' : 'waited'} ${formatDuration(Duration(milliseconds: dur))}',
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onStopTap == null ? null : () => widget.onStopTap!(e),
            child: Center(
              child: Container(
                height: long ? 30 : 26,
                padding: const EdgeInsets.symmetric(horizontal: Space.s4),
                decoration: BoxDecoration(
                  color: c,
                  borderRadius: Radii.smAll,
                  border: Border.all(color: long ? AppTheme.textPrimary : AppTheme.slateCard, width: long ? 2 : 1.5),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(long ? Icons.hotel_rounded : Icons.pause_rounded, size: 14, color: TripRouteMap.onColor(c)),
                  const SizedBox(width: 2),
                  Flexible(
                    child: Text(
                      TripRouteMap.shortDuration(dur),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      textScaler: TextScaler.noScaling,
                      style: TextStyle(color: TripRouteMap.onColor(c), fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                ]),
              ),
            ),
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
      final name = p.track.name.isEmpty ? 'A rider' : p.track.name;
      out.add(Marker(
        point: LatLng(first.lat, first.lng),
        width: 40,
        height: 40,
        child: Semantics(
          button: widget.onRiderEndTap != null,
          label: '$name started',
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onRiderEndTap == null ? null : () => widget.onRiderEndTap!(p.track, true),
            child: Center(
              child: Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: AppTheme.slateCard, width: 2.5)),
                child: Icon(Icons.play_arrow_rounded, size: 14, color: TripRouteMap.onColor(c)),
              ),
            ),
          ),
        ),
      ));
      out.add(Marker(
        point: LatLng(last.lat, last.lng),
        width: 40,
        height: 40,
        alignment: Alignment.topCenter,
        child: Semantics(
          button: widget.onRiderEndTap != null,
          label: '$name finished',
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onRiderEndTap == null ? null : () => widget.onRiderEndTap!(p.track, false),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: AppTheme.slateCard, shape: BoxShape.circle, border: Border.all(color: c, width: 2)),
                child: Icon(Icons.flag_rounded, size: 18, color: c),
              ),
            ),
          ),
        ),
      ));
    }
    return out;
  }

  Marker _highlightMarker(TimelineEventModel e, LatLng at) {
    return Marker(
      key: ValueKey('hl-${e.eventId}'),
      point: at,
      width: 64,
      height: 64,
      child: _HighlightRing(key: ValueKey('ring-${e.eventId}'), color: _color(e.userId ?? '')),
    );
  }

  Marker _riderMarker(_Prepared p, ReplayPoint at, bool focused) {
    return Marker(
      point: LatLng(at.lat, at.lng),
      width: 36,
      height: 36,
      child: RiderAvatar(name: p.track.name, color: _color(p.track.userId), size: focused ? 36 : 32),
    );
  }

  List<Marker> _riderNow(List<_Prepared> shown, int ts, String? focus) {
    final out = <Marker>[];
    for (final p in shown) {
      final at = p.track.positionAt(ts);
      if (at == null) continue;
      out.add(_riderMarker(p, at, p.track.userId == focus));
    }
    return out;
  }
}

/// A ring that shrinks onto the highlighted place once, then stays still.
/// No loop: the animation runs a single time per highlighted entry.
class _HighlightRing extends StatelessWidget {
  final Color color;
  const _HighlightRing({super.key, required this.color});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Highlighted place',
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 1.0, end: 0.0),
        duration: Motion.screen,
        curve: Motion.curve,
        builder: (context, t, _) {
          final size = 40 + 24 * t;
          return Center(
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withOpacity(0.18),
                border: Border.all(color: AppTheme.textPrimary, width: 3),
              ),
              child: Center(
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: AppTheme.slateCard, width: 2)),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The key under the map: what each symbol means.
class TripMapLegend extends StatelessWidget {
  /// Adds the planned route and off-route entries.
  final bool showPlan;
  const TripMapLegend({super.key, this.showPlan = true});

  @override
  Widget build(BuildContext context) {
    Widget item(Widget icon, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 24, child: Center(child: icon)),
          const SizedBox(width: Space.s4),
          Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppTheme.textSecondary))),
        ]);
    final c = AppTheme.textSecondary;
    return Wrap(spacing: Space.s16, runSpacing: Space.s8, children: [
      item(Container(width: 16, height: 16, decoration: BoxDecoration(color: c, shape: BoxShape.circle), child: Icon(Icons.play_arrow_rounded, size: 12, color: AppTheme.slateCard)), 'Started'),
      item(Icon(Icons.flag_rounded, size: 16, color: c), 'Finished'),
      item(Container(padding: const EdgeInsets.symmetric(horizontal: 3), decoration: BoxDecoration(color: c, borderRadius: Radii.smAll), child: Icon(Icons.pause_rounded, size: 12, color: AppTheme.slateCard)), 'Waited'),
      item(Container(padding: const EdgeInsets.symmetric(horizontal: 3), decoration: BoxDecoration(color: c, borderRadius: Radii.smAll), child: Icon(Icons.hotel_rounded, size: 12, color: AppTheme.slateCard)), 'Long rest'),
      item(Container(width: 16, height: 16, decoration: BoxDecoration(color: StatusColors.warning, shape: BoxShape.circle)), 'Planned stop'),
      item(Icon(Icons.sports_score_rounded, size: 16, color: StatusColors.critical), 'Destination'),
      if (showPlan) ...[
        item(Text('- - -', style: AppText.caption.copyWith(color: c, fontWeight: FontWeight.w700)), 'Planned route'),
        item(Icon(Icons.wrong_location_rounded, size: 16, color: StatusColors.warning), 'Off route'),
      ],
      item(Text('.....', style: AppText.caption.copyWith(color: c, fontWeight: FontWeight.w700)), 'No signal'),
    ]);
  }
}
