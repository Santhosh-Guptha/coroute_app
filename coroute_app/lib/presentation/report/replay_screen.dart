import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/timeline_event_model.dart';
import '../../data/models/trip_plan_model.dart';
import '../../data/services/api_client.dart';
import '../../domain/tracking/replay_math.dart';
import '../timeline/member_colors.dart';
import 'trip_route_map.dart';

/// Replays a convoy: drag the time slider (or press play) and every rider's
/// marker moves to where they were at that moment, with a 10-minute tail.
/// The whole route of each rider, their start and finish, where they waited,
/// the planned stops and the destination stay on the map.
/// Opened from a timeline entry it starts at that moment, with a pin on the
/// place and that rider highlighted.
class ReplayScreen extends StatefulWidget {
  final String groupId;
  final String title;
  final int? initialTs;
  final String? focusUserId;
  final LatLng? pin;
  final String? pinLabel;
  final Map<String, Color>? colors;

  /// Timeline entries already loaded by the caller (waiting points come from here).
  final List<TimelineEventModel>? events;

  const ReplayScreen({
    super.key,
    required this.groupId,
    this.title = 'Replay',
    this.initialTs,
    this.focusUserId,
    this.pin,
    this.pinLabel,
    this.colors,
    this.events,
  });

  @override
  State<ReplayScreen> createState() => _ReplayScreenState();
}

class _ReplayScreenState extends State<ReplayScreen> {
  List<ReplayTrack> _tracks = [];
  List<TimelineEventModel> _stops = [];
  TripPlan? _plan;
  Map<String, Color> _colors = {};
  bool _loading = true;
  String? _error;
  int _t = 0, _from = 0, _to = 0;
  Timer? _timer;
  int _speedIndex = 1;
  static const _speeds = [30, 120, 600]; // seconds of ride per second of replay

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<ApiClient>();
    try {
      final res = await api.get('/convoys/${widget.groupId}/tracks?simplify=8', timeout: const Duration(seconds: 25));
      final list = (res is Map ? res['tracks'] : null) as List? ?? const [];
      final tracks = list.whereType<Map>().map((m) => ReplayTrack.fromJson(Map<String, dynamic>.from(m))).where((t) => t.points.length >= 2).toList();
      final plan = res is Map ? TripPlan.fromJson(res['plan']) : null;
      var events = widget.events;
      if (events == null) {
        try {
          final tl = await api.get('/convoys/${widget.groupId}/timeline?types=STOPPED', timeout: const Duration(seconds: 20));
          events = ((tl is Map ? tl['events'] : null) as List? ?? const [])
              .whereType<Map>()
              .map((e) => TimelineEventModel.fromJson(Map<String, dynamic>.from(e)))
              .toList();
        } catch (_) {
          events = const []; // the routes still show without the waiting points
        }
      }
      if (!mounted) return;
      final from = tracks.isEmpty ? 0 : tracks.map((t) => t.firstTs).reduce((a, b) => a < b ? a : b);
      final to = tracks.isEmpty ? 0 : tracks.map((t) => t.lastTs).reduce((a, b) => a > b ? a : b);
      setState(() {
        _tracks = tracks;
        _plan = plan;
        _stops = events!.where((e) => e.type == 'STOPPED' && e.hasPlace).toList();
        _colors = widget.colors ?? MemberColors.assign(tracks.map((t) => t.userId));
        _from = from;
        _to = to;
        final start = widget.initialTs ?? from;
        _t = start.clamp(from, to < from ? from : to).toInt();
        _loading = false;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() { _error = e.message; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _error = 'Could not load the routes.'; _loading = false; });
    }
  }

  void _togglePlay() {
    if (_timer != null) {
      _timer!.cancel();
      setState(() => _timer = null);
      return;
    }
    if (_t >= _to) _t = _from;
    // 5 frames a second is smooth enough for map markers and keeps the phone cool.
    const frame = Duration(milliseconds: 200);
    _timer = Timer.periodic(frame, (_) {
      if (!mounted) return;
      setState(() {
        _t += _speeds[_speedIndex] * frame.inMilliseconds;
        if (_t >= _to) {
          _t = _to;
          _timer?.cancel();
          _timer = null;
        }
      });
    });
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(title: Text(widget.title, overflow: TextOverflow.ellipsis)),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppTheme.neonCyan))
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: AppTheme.laserRed))))
              : LayoutBuilder(builder: (context, c) {
                  final wide = c.maxWidth > c.maxHeight && c.maxWidth > 700;
                  final map = TripRouteMap(
                    tracks: _tracks,
                    colors: _colors,
                    plan: _plan,
                    stops: _stops,
                    timeMs: _tracks.isEmpty ? null : _t,
                    focusUserId: widget.focusUserId,
                    pin: widget.pin,
                  );
                  final panel = _panel();
                  if (wide) return Row(children: [Expanded(flex: 3, child: map), SizedBox(width: 360, child: SingleChildScrollView(child: panel))]);
                  // The panel never takes more than 45% of the height, so the map stays usable in landscape.
                  return Column(children: [
                    Expanded(child: map),
                    ConstrainedBox(constraints: BoxConstraints(maxHeight: c.maxHeight * 0.45), child: SingleChildScrollView(child: panel)),
                  ]);
                }),
    );
  }

  Widget _panel() {
    final fmt = DateFormat('HH:mm:ss');
    final day = DateFormat('EEE d MMM');
    final hasRange = _to > _from;
    return Container(
      color: AppTheme.darkCanvas,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_tracks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                    _plan == null
                        ? 'No recorded route for this trip yet. Routes appear a minute after riders move.'
                        : 'No recorded routes for this trip. The map shows the planned stops and destination.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 13)),
              )
            else ...[
              Row(
                children: [
                  IconButton(
                    onPressed: hasRange ? _togglePlay : null,
                    icon: Icon(_timer != null ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded, color: AppTheme.neonCyan, size: 36),
                    tooltip: _timer != null ? 'Pause' : 'Play',
                  ),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text(_t > 0 ? fmt.format(DateTime.fromMillisecondsSinceEpoch(_t)) : '',
                          style: TextStyle(color: AppTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.bold, fontFeatures: const [FontFeature.tabularFigures()])),
                      if (_t > 0) Text(day.format(DateTime.fromMillisecondsSinceEpoch(_t)), style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                    ]),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _speedIndex = (_speedIndex + 1) % _speeds.length),
                    child: Text('${_speeds[_speedIndex]}x', style: TextStyle(color: AppTheme.neonCyan)),
                  ),
                ],
              ),
              if (hasRange)
                Slider(
                  value: _t.toDouble().clamp(_from.toDouble(), _to.toDouble()).toDouble(),
                  min: _from.toDouble(),
                  max: _to.toDouble(),
                  activeColor: AppTheme.neonCyan,
                  onChanged: (v) => setState(() => _t = v.round()),
                ),
              Wrap(
                spacing: 12,
                runSpacing: 6,
                children: [
                  for (final t in _tracks)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(radius: 5, backgroundColor: _colors[t.userId] ?? AppTheme.neonCyan),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(_riderNow(t), style: TextStyle(color: AppTheme.textSecondary, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            const TripMapLegend(),
          ],
        ),
      ),
    );
  }

  /// "Asha: 54 km/h", "Asha: waiting", "Asha: not started", "Asha: finished", "Asha: no signal".
  String _riderNow(ReplayTrack t) {
    if (_t < t.firstTs) return '${t.name}: not started';
    if (_t > t.lastTs) return '${t.name}: finished';
    final waiting = _stops.any((e) => e.userId == t.userId && e.startedAt <= _t && (e.endedAt ?? e.startedAt + e.durationMs) >= _t);
    if (waiting) return '${t.name}: waiting';
    final at = t.positionAt(_t);
    if (at == null) return '${t.name}: no signal';
    return '${t.name}: ${at.kmh.round()} km/h';
  }
}
