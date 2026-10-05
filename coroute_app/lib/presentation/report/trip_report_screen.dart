import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/models/timeline_event_model.dart';
import '../../data/models/trip_history_model.dart';
import '../../data/models/trip_plan_model.dart';
import '../../data/models/trip_report_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
import '../../domain/timeline/timeline_text.dart';
import '../../domain/tracking/replay_math.dart';
import '../timeline/member_colors.dart';
import '../timeline/timeline_list.dart';
import 'replay_screen.dart';
import 'trip_route_map.dart';

/// Full report of a finished trip: summary, every member side by side, the
/// group timeline and the replay. Built by the server from the recorded routes.
class TripReportScreen extends StatefulWidget {
  final TripHistoryModel trip;
  const TripReportScreen({super.key, required this.trip});

  @override
  State<TripReportScreen> createState() => _TripReportScreenState();
}

class _TripReportScreenState extends State<TripReportScreen> {
  TripReportModel? _report;
  List<TimelineEventModel> _events = [];
  Map<String, String> _names = {};
  Map<String, Color> _colors = {};
  TripPlan? _plan;
  bool _loading = true;
  String? _error;
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = context.read<ApiClient>();
    try {
      final res = await api.get('/trips/${Uri.encodeComponent(widget.trip.tripId)}/report', timeout: const Duration(seconds: 20));
      if (!mounted) return;
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      final report = m['report'] is Map ? TripReportModel.fromJson(Map<String, dynamic>.from(m['report'] as Map)) : null;
      final events = (m['events'] as List? ?? const []).whereType<Map>().map((e) => TimelineEventModel.fromJson(Map<String, dynamic>.from(e))).toList()
        ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
      final names = <String, String>{};
      for (final mem in (m['members'] as List? ?? const []).whereType<Map>()) {
        final id = mem['userId']?.toString() ?? '';
        if (id.isNotEmpty) names[id] = mem['name']?.toString() ?? '';
      }
      for (final e in events) {
        if (e.userId != null && !names.containsKey(e.userId)) names[e.userId!] = e.userName;
      }
      setState(() {
        _report = report;
        _events = events;
        _names = names;
        _colors = MemberColors.assign(names.keys);
        _plan = TripPlan.fromJson(m['plan']);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() { _error = e.message; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _error = 'Could not load the trip report.'; _loading = false; });
    }
  }

  Future<void> _shareGpx() async {
    setState(() => _sharing = true);
    final api = context.read<ApiClient>();
    try {
      final gpx = await api.getText('/convoys/${widget.trip.groupId}/gpx');
      final safe = widget.trip.tripName.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim().replaceAll(RegExp(r'\s+'), '_');
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(utf8.encode(gpx), mimeType: 'application/gpx+xml', name: '${safe.isEmpty ? 'coroute_trip' : safe}.gpx')],
        subject: 'CoRoute trip: ${widget.trip.tripName}',
      ));
    } on ApiException catch (e) {
      _snack(e.message);
    } catch (_) {
      _snack('Could not share the route.');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  void _shareSummary() {
    final r = _report;
    final me = _memberFor(r, context.read<AuthService>().currentUserId);
    final lines = <String>[
      'CoRoute trip: ${widget.trip.tripName}',
      if (me != null) ...[
        'Distance ${TimelineText.distance(me.distanceM)}, riding ${TimelineText.duration(Duration(milliseconds: me.movingMs))}, '
            'stopped ${TimelineText.duration(Duration(milliseconds: me.restMs))} (${me.stops} stops), top ${me.maxKmh.round()} km/h',
      ],
      if (r != null) '${r.memberCount} riders, ${r.arrived} reached the destination',
    ];
    SharePlus.instance.share(ShareParams(text: lines.join('\n'), subject: 'CoRoute trip: ${widget.trip.tripName}'));
  }

  static MemberReport? _memberFor(TripReportModel? r, String? userId) {
    if (r == null || userId == null) return null;
    for (final m in r.members) {
      if (m.userId == userId) return m;
    }
    return null;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _openOnMap(TimelineEventModel e) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReplayScreen(
          groupId: widget.trip.groupId,
          title: TimelineText.title(e, nowMs: DateTime.now().millisecondsSinceEpoch),
          initialTs: e.startedAt,
          focusUserId: e.userId,
          pin: LatLng(e.lat!, e.lng!),
          colors: _colors,
          events: _events,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: AppTheme.obsidianVoid,
        appBar: AppBar(
          title: Text(widget.trip.tripName, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(tooltip: 'Share summary', icon: const Icon(Icons.ios_share_rounded), onPressed: _report == null ? null : _shareSummary),
            IconButton(
              tooltip: 'Share my route (GPX)',
              icon: _sharing
                  ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.neonCyan))
                  : Icon(Icons.route_rounded, color: AppTheme.neonCyan),
              onPressed: _sharing ? null : _shareGpx,
            ),
          ],
          bottom: TabBar(
            indicatorColor: AppTheme.neonCyan,
            labelColor: AppTheme.neonCyan,
            unselectedLabelColor: AppTheme.textMuted,
            tabs: const [Tab(text: 'Summary'), Tab(text: 'Map'), Tab(text: 'Timeline')],
          ),
        ),
        body: _loading
            ? Center(child: CircularProgressIndicator(color: AppTheme.neonCyan))
            : _error != null
                ? Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_error!, style: TextStyle(color: AppTheme.laserRed), textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      OutlinedButton(onPressed: _load, child: const Text('Try again')),
                    ]),
                  )
                : TabBarView(
                    physics: const NeverScrollableScrollPhysics(), // the replay map needs horizontal drags
                    children: [
                      _summary(),
                      _RouteMapTab(
                        groupId: widget.trip.groupId,
                        title: widget.trip.tripName,
                        colors: _colors,
                        names: _names,
                        events: _events,
                        plan: _plan,
                        myUserId: context.read<AuthService>().currentUserId,
                      ),
                      TimelineList(events: _events, colors: _colors, memberNames: _names, onTap: _openOnMap),
                    ],
                  ),
      ),
    );
  }

  /// One rider's day: start, every wait (when, how long, why, where), finish.
  Widget _riderCard(MemberReport m, String? myId) {
    final c = _colors[m.userId] ?? AppTheme.neonCyan;
    final hm = DateFormat('HH:mm');
    String dur(int ms) => TimelineText.duration(Duration(milliseconds: ms));
    String at(int ms) => ms > 0 ? hm.format(DateTime.fromMillisecondsSinceEpoch(ms)) : '';
    final waits = _events.where((e) => e.userId == m.userId && e.type == 'STOPPED').toList()..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    final started = m.firstFixAt > 0 ? m.firstFixAt : m.joinedAt;
    final line = TextStyle(color: AppTheme.textSecondary, fontSize: 12);
    Widget row(IconData icon, Color iconColor, String text, {VoidCallback? onTap}) => InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, size: 15, color: iconColor),
              const SizedBox(width: 8),
              Expanded(child: Text(text, style: onTap == null ? line : line.copyWith(color: AppTheme.textPrimary))),
            ]),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(radius: 6, backgroundColor: c),
            const SizedBox(width: 8),
            Expanded(
              child: Text(m.userId == myId ? '${m.name} (you)' : m.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 14)),
            ),
            if (m.reachedDestination) Icon(Icons.sports_score_rounded, size: 16, color: AppTheme.emeraldSafe),
          ]),
          const SizedBox(height: 6),
          Text(
            m.trackAvailable
                ? '${TimelineText.distance(m.distanceM)} · riding ${dur(m.movingMs)} · waited ${waits.length} ${waits.length == 1 ? 'time' : 'times'}, ${dur(m.restMs)}'
                : 'No route was uploaded from this phone. Waits below come from the live updates.',
            style: TextStyle(color: m.trackAvailable ? AppTheme.textPrimary : AppTheme.hyperAmber, fontSize: 12),
          ),
          const SizedBox(height: 6),
          row(Icons.play_circle_outline_rounded, c, ['Started ${at(started)}', if (m.startPlace.isNotEmpty) m.startPlace].join(' · ')),
          for (final w in waits)
            row(
              Icons.pause_circle_outline_rounded,
              c,
              [
                '${at(w.startedAt)}-${at(w.endedAt ?? (w.startedAt + w.durationMs))}, ${dur(w.durationMs)}',
                if (w.dataString('reason').isNotEmpty) TimelineText.reason(w.dataString('reason')),
                if (w.placeName.isNotEmpty) w.placeName,
              ].join(' · '),
              onTap: w.hasPlace ? () => _openOnMap(w) : null,
            ),
          row(
            m.reachedDestination ? Icons.sports_score_rounded : Icons.flag_outlined,
            m.reachedDestination ? AppTheme.emeraldSafe : c,
            [
              m.reachedDestination ? 'Reached the destination' : 'Finished',
              if (m.lastFixAt > 0) at(m.lastFixAt),
              if (m.endPlace.isNotEmpty) m.endPlace,
            ].join(' · '),
          ),
        ]),
      ),
    );
  }

  Widget _summary() {
    final r = _report;
    final t = widget.trip;
    final myId = context.read<AuthService>().currentUserId;
    final me = _memberFor(r, myId);
    final dateFmt = DateFormat('EEE d MMM yyyy, HH:mm');
    String dur(int ms) => TimelineText.duration(Duration(milliseconds: ms));

    final tiles = <(String, String)>[
      ('Distance', TimelineText.distance(me?.distanceM ?? t.totalDistanceKm * 1000)),
      ('Total time', dur(me?.durationMs ?? (t.endTimeEpochMs - t.startTimeEpochMs))),
      ('Riding', dur(me?.movingMs ?? t.movingMs)),
      ('Stopped', dur(me?.restMs ?? t.restMs)),
      ('Stops', '${me?.stops ?? t.stopCount}'),
      ('Longest stop', dur(me?.longestStopMs ?? 0)),
      ('Average', '${(me?.avgMovingKmh ?? t.avgSpeedKmh).round()} km/h'),
      ('Top speed', '${(me?.maxKmh ?? t.topSpeedKmh).round()} km/h'),
      if ((r?.speedLimitKmh ?? 0) > 0)
        ('Over ${r!.speedLimitKmh} km/h', (me?.overspeedCount ?? 0) == 0 ? 'Never' : '${me!.overspeedCount}x, ${dur(me.overspeedMs)}'),
    ];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(dateFmt.format(DateTime.fromMillisecondsSinceEpoch(t.startTimeEpochMs)), style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
        if (t.startLocationName.isNotEmpty || t.destinationName.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('${t.startLocationName.isEmpty ? 'Start' : t.startLocationName}  to  ${t.destinationName.isEmpty ? 'destination' : t.destinationName}',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        const SizedBox(height: 14),
        Text('YOUR RIDE', style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
        const SizedBox(height: 8),
        LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth > 700 ? 4 : 2;
          final w = (c.maxWidth - (cols - 1) * 10) / cols;
          return Wrap(spacing: 10, runSpacing: 10, children: [
            for (final (label, value) in tiles)
              SizedBox(
                width: w,
                child: GlassCard(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(label, style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                    const SizedBox(height: 4),
                    Text(value, style: TextStyle(color: AppTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.bold)),
                  ]),
                ),
              ),
          ]);
        }),
        if (me != null && !me.trackAvailable)
          Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text('Your phone did not upload a route for this trip, so distance and riding time are estimates.',
                style: TextStyle(color: AppTheme.hyperAmber, fontSize: 12)),
          ),
        if (r != null) ...[
          const SizedBox(height: 22),
          Text('THE GROUP: ${r.memberCount} RIDERS, ${r.arrived} ARRIVED${r.plannedStops > 0 ? ', ${r.visitedStops} OF ${r.plannedStops} STOPS' : ''}${r.sos > 0 ? ', ${r.sos} SOS' : ''}',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
          const SizedBox(height: 8),
          GlassCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingTextStyle: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.bold),
                dataTextStyle: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                columnSpacing: 18,
                horizontalMargin: 12,
                columns: const [
                  DataColumn(label: Text('Rider')),
                  DataColumn(label: Text('Distance'), numeric: true),
                  DataColumn(label: Text('Riding'), numeric: true),
                  DataColumn(label: Text('Stopped'), numeric: true),
                  DataColumn(label: Text('Stops'), numeric: true),
                  DataColumn(label: Text('Avg'), numeric: true),
                  DataColumn(label: Text('Top'), numeric: true),
                  DataColumn(label: Text('Behind group'), numeric: true),
                  DataColumn(label: Text('No signal'), numeric: true),
                  DataColumn(label: Text('Over limit'), numeric: true),
                  DataColumn(label: Text('Arrived')),
                ],
                rows: [
                  for (final m in r.members)
                    DataRow(cells: [
                      DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                        CircleAvatar(radius: 5, backgroundColor: _colors[m.userId] ?? AppTheme.neonCyan),
                        const SizedBox(width: 6),
                        Text(m.userId == myId ? '${m.name} (you)' : m.name),
                      ])),
                      DataCell(Text(m.trackAvailable ? TimelineText.distance(m.distanceM) : 'n/a')),
                      DataCell(Text(dur(m.movingMs))),
                      DataCell(Text(dur(m.restMs))),
                      DataCell(Text('${m.stops}')),
                      DataCell(Text(m.trackAvailable ? '${m.avgMovingKmh.round()}' : 'n/a')),
                      DataCell(Text(m.trackAvailable ? '${m.maxKmh.round()}' : 'n/a')),
                      DataCell(Text(m.separatedMs > 0 ? dur(m.separatedMs) : '-')),
                      DataCell(Text(m.offlineMs > 0 ? dur(m.offlineMs) : '-')),
                      DataCell(Text(
                        m.overspeedCount > 0 ? '${m.overspeedCount}x · ${dur(m.overspeedMs)} · top ${m.overspeedMaxKmh.round()}' : '-',
                        style: TextStyle(color: m.overspeedCount > 0 ? AppTheme.speedWarning : null),
                      )),
                      DataCell(Icon(m.reachedDestination ? Icons.check_circle_rounded : Icons.remove_rounded,
                          size: 16, color: m.reachedDestination ? AppTheme.emeraldSafe : AppTheme.textMuted)),
                    ]),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
              'Distance, average and top speed come from each rider\'s recorded route. n/a: that phone did not upload a route.'
              '${r.speedLimitKmh > 0 ? ' Over limit: times above the group limit of ${r.speedLimitKmh} km/h, total time and top speed.' : ''}',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
          const SizedBox(height: 22),
          Text('EVERY RIDER: WHERE THEY STARTED, WAITED AND FINISHED',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
          const SizedBox(height: 8),
          for (final m in r.members) _riderCard(m, myId),
        ] else
          Padding(
            padding: EdgeInsets.only(top: 18),
            child: Text('The group report is being prepared. It is ready about a minute after the trip ends.',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
          ),
      ],
    );
  }
}

/// The trip on one map: each rider's route in their colour, their start and
/// finish, where they waited, the planned stops and the destination. Riders
/// can be switched on and off; tapping a symbol tells what happened there.
class _RouteMapTab extends StatefulWidget {
  final String groupId;
  final String title;
  final Map<String, Color> colors;
  final Map<String, String> names;
  final List<TimelineEventModel> events;
  final TripPlan? plan;
  final String? myUserId;

  const _RouteMapTab({
    required this.groupId,
    required this.title,
    required this.colors,
    required this.names,
    required this.events,
    required this.plan,
    required this.myUserId,
  });

  @override
  State<_RouteMapTab> createState() => _RouteMapTabState();
}

class _RouteMapTabState extends State<_RouteMapTab> with AutomaticKeepAliveClientMixin {
  List<ReplayTrack> _tracks = [];
  TripPlan? _plan;
  bool _loading = true;
  String? _error;
  Set<String>? _visible; // null = everyone

  @override
  bool get wantKeepAlive => true; // keep the loaded routes when switching tabs

  @override
  void initState() {
    super.initState();
    _plan = widget.plan;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await context.read<ApiClient>().get('/convoys/${widget.groupId}/tracks?simplify=8', timeout: const Duration(seconds: 25));
      final list = (res is Map ? res['tracks'] : null) as List? ?? const [];
      final tracks = list.whereType<Map>().map((m) => ReplayTrack.fromJson(Map<String, dynamic>.from(m))).where((t) => t.points.length >= 2).toList();
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _plan = (res is Map ? TripPlan.fromJson(res['plan']) : null) ?? widget.plan;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() { _error = e.message; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _error = 'Could not load the routes.'; _loading = false; });
    }
  }

  String _name(String userId) => widget.names[userId]?.isNotEmpty == true ? widget.names[userId]! : 'A rider';

  void _toggle(String userId) {
    setState(() {
      final all = _tracks.map((t) => t.userId).toSet();
      final v = _visible ?? Set<String>.from(all);
      if (!v.remove(userId)) v.add(userId);
      _visible = v.length == all.length ? null : v;
    });
  }

  void _sheet(String title, List<String> lines, {Color? color}) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.slateCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (color != null) ...[CircleAvatar(radius: 6, backgroundColor: color), const SizedBox(width: 8)],
              Expanded(child: Text(title, style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.bold))),
            ]),
            const SizedBox(height: 8),
            for (final l in lines)
              Padding(padding: const EdgeInsets.only(top: 4), child: Text(l, style: TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
          ]),
        ),
      ),
    );
  }

  static String _hm(int ms) => DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(ms));
  static String _dur(int ms) => TimelineText.duration(Duration(milliseconds: ms));

  void _onStop(TimelineEventModel e) {
    final end = e.endedAt ?? (e.startedAt + e.durationMs);
    _sheet(
      '${_name(e.userId ?? '')} waited ${_dur(e.durationMs)}',
      [
        '${_hm(e.startedAt)} to ${_hm(end)}',
        if (e.dataString('reason').isNotEmpty) 'Reason: ${TimelineText.reason(e.dataString('reason'))}',
        if (e.placeName.isNotEmpty) e.placeName,
        if (e.confidence == 'confirmed') 'Measured from the recorded route.' else 'From the live updates during the ride.',
      ],
      color: widget.colors[e.userId],
    );
  }

  void _onPlanStop(PlanStop s) {
    final lines = <String>[];
    if (s.isSkipped) lines.add('Skipped by the lead.');
    final ids = {...widget.names.keys, ...s.arrivals.keys};
    for (final id in ids) {
      final a = s.arrivals[id];
      final who = a?.name.isNotEmpty == true ? a!.name : _name(id);
      if (a == null) {
        lines.add('$who: did not reach it');
      } else if (a.reached) {
        lines.add(a.leftAt > 0
            ? '$who: arrived ${_hm(a.arrivedAt)}, left ${_hm(a.leftAt)} (${_dur(a.leftAt - a.arrivedAt)})'
            : '$who: arrived ${_hm(a.arrivedAt)}');
      } else if (a.passed) {
        lines.add('$who: rode past at ${_hm(a.passedAt)}');
      }
    }
    _sheet(s.name.isEmpty ? 'Planned stop' : s.name, lines);
  }

  void _onRiderEnd(ReplayTrack t, bool start) {
    final p = start ? t.points.first : t.points.last;
    _sheet('${_name(t.userId)} ${start ? 'started' : 'finished'} at ${_hm(p.ts)}', [
      '${DateFormat('EEE d MMM').format(DateTime.fromMillisecondsSinceEpoch(p.ts))}, ${p.lat.toStringAsFixed(5)}, ${p.lng.toStringAsFixed(5)}',
    ], color: widget.colors[t.userId]);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return Center(child: CircularProgressIndicator(color: AppTheme.neonCyan));
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.all(16), child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: AppTheme.laserRed))),
          OutlinedButton(onPressed: _load, child: const Text('Try again')),
        ]),
      );
    }
    final stops = widget.events.where((e) => e.type == 'STOPPED' && e.hasPlace).toList();
    return LayoutBuilder(builder: (context, c) {
      final map = TripRouteMap(
        tracks: _tracks,
        colors: widget.colors,
        plan: _plan,
        stops: stops,
        visible: _visible,
        onStopTap: _onStop,
        onPlanStopTap: _onPlanStop,
        onRiderEndTap: _onRiderEnd,
      );
      final panel = Container(
        color: AppTheme.darkCanvas,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_tracks.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'No recorded routes for this trip (routes are kept for 90 days). The planned stops and destination are still shown.',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                ),
              )
            else
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final t in _tracks)
                  FilterChip(
                    avatar: CircleAvatar(backgroundColor: widget.colors[t.userId] ?? AppTheme.neonCyan, radius: 6),
                    label: Text(t.userId == widget.myUserId ? '${_name(t.userId)} (you)' : _name(t.userId), overflow: TextOverflow.ellipsis),
                    selected: _visible == null || _visible!.contains(t.userId),
                    onSelected: (_) => _toggle(t.userId),
                    showCheckmark: false,
                    selectedColor: (widget.colors[t.userId] ?? AppTheme.neonCyan).withOpacity(0.18),
                    backgroundColor: AppTheme.slateCard,
                    labelStyle: TextStyle(color: AppTheme.textPrimary, fontSize: 12),
                    side: BorderSide(color: AppTheme.subtleBorder),
                  ),
              ]),
            const SizedBox(height: 8),
            const TripMapLegend(),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: _tracks.isEmpty
                  ? null
                  : () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => ReplayScreen(groupId: widget.groupId, title: widget.title, colors: widget.colors, events: widget.events)),
                      ),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Play the ride'),
              style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
            ),
          ]),
        ),
      );
      final wide = c.maxWidth > c.maxHeight && c.maxWidth > 700;
      if (wide) return Row(children: [Expanded(child: map), SizedBox(width: 340, child: SingleChildScrollView(child: panel))]);
      return Column(children: [
        Expanded(child: map),
        ConstrainedBox(constraints: BoxConstraints(maxHeight: c.maxHeight * 0.45), child: SingleChildScrollView(child: panel)),
      ]);
    });
  }
}
