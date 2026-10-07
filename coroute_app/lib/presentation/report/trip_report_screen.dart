import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
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

/// Full report of a finished trip, in two tabs:
///  * Summary: the key numbers first (shown at once from the saved trip, no
///    network needed), then "More details" with the group and every rider.
///  * Route: the map (planned route, every rider's route, stops, long rests,
///    off-route points) above the timeline. Tapping a timeline entry
///    highlights it on the map in place.
/// The group report is built by the server from the recorded routes; it
/// loads in the background and never blocks the screen.
class TripReportScreen extends StatefulWidget {
  final TripHistoryModel trip;

  /// Opened by an administrator from Ride history: the whole group's report,
  /// without the personal "your ride" part.
  final bool adminView;
  const TripReportScreen({super.key, required this.trip, this.adminView = false});

  @override
  State<TripReportScreen> createState() => _TripReportScreenState();
}

class _TripReportScreenState extends State<TripReportScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  TripReportModel? _report;
  List<TimelineEventModel> _events = [];
  Map<String, String> _names = {};
  Map<String, Color> _colors = {};
  TripPlan? _plan;
  bool _loading = true;
  String? _error;
  bool _sharing = false;
  TimelineEventModel? _highlight;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_error != null) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final api = context.read<ApiClient>();
    try {
      final path = widget.adminView || widget.trip.tripId.isEmpty
          ? '/convoys/${Uri.encodeComponent(widget.trip.groupId)}/summary'
          : '/trips/${Uri.encodeComponent(widget.trip.tripId)}/report';
      final res = await api.get(path, timeout: const Duration(seconds: 20));
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
    final t = widget.trip;
    final me = _memberFor(r, context.read<AuthService>().currentUserId);
    final distanceM = me?.distanceM ?? t.totalDistanceKm * 1000;
    final movingMs = me?.movingMs ?? t.movingMs;
    final restMs = me?.restMs ?? t.restMs;
    final stops = me?.stops ?? t.stopCount;
    final top = me?.maxKmh ?? t.topSpeedKmh;
    final lines = <String>[
      'CoRoute trip: ${t.tripName}',
      'Distance ${formatDistance(distanceM)}, riding ${formatDuration(Duration(milliseconds: movingMs))}, '
          'stopped ${formatDuration(Duration(milliseconds: restMs))} ($stops stops), top ${top.round()} km/h',
      if (r != null) '${r.memberCount} riders, ${r.arrived} reached the destination',
    ];
    SharePlus.instance.share(ShareParams(text: lines.join('\n'), subject: 'CoRoute trip: ${t.tripName}'));
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

  /// Highlights [e] on the route map, in place (switches to the Route tab).
  void _showOnMap(TimelineEventModel e) {
    setState(() => _highlight = e);
    if (_tabs.index != 1) _tabs.animateTo(1);
  }

  @override
  Widget build(BuildContext context) {
    final myId = context.read<AuthService>().currentUserId;
    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        title: Text(widget.trip.tripName, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(tooltip: 'Share summary', icon: const Icon(Icons.ios_share_rounded), onPressed: _shareSummary),
          if (!widget.adminView)
            IconButton(
              tooltip: 'Share my route (GPX)',
              icon: _sharing
                  ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.neonCyan))
                  : Icon(Icons.route_rounded, color: AppTheme.neonCyan),
              onPressed: _sharing ? null : _shareGpx,
            ),
        ],
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: AppTheme.neonCyan,
          labelColor: AppTheme.neonCyan,
          unselectedLabelColor: AppTheme.textMuted,
          tabs: const [Tab(text: 'Summary'), Tab(text: 'Route')],
        ),
      ),
      body: LoadingState(
        loading: _loading,
        child: TabBarView(
          controller: _tabs,
          physics: const NeverScrollableScrollPhysics(), // the map needs horizontal drags
          children: [
            _summary(myId),
            _RouteView(
              groupId: widget.trip.groupId,
              title: widget.trip.tripName,
              colors: _colors,
              names: _names,
              events: _events,
              plan: _plan,
              report: _report,
              myUserId: myId,
              eventsLoading: _loading,
              highlight: _highlight,
              onHighlight: (e) => setState(() => _highlight = e),
            ),
          ],
        ),
      ),
    );
  }

  /// Longest wait of [userId] from the timeline, when the report does not have it.
  int? _longestFromEvents(String? userId) {
    if (userId == null) return null;
    int? best;
    for (final e in _events) {
      if (e.type != 'STOPPED' || e.userId != userId) continue;
      if (best == null || e.durationMs > best) best = e.durationMs;
    }
    return best;
  }

  Widget _summary(String? myId) {
    final r = _report;
    final t = widget.trip;
    final me = _memberFor(r, myId);
    final dateFmt = DateFormat('EEE d MMM yyyy, HH:mm');
    String dur(int ms) => formatDuration(Duration(milliseconds: ms));

    final stops = me?.stops ?? t.stopCount;
    final moving = me?.movingMs ?? t.movingMs;
    final rest = me?.restMs ?? t.restMs;
    final longest = me != null && me.longestStopMs > 0 ? me.longestStopMs : _longestFromEvents(myId);
    final avg = me?.avgMovingKmh ?? t.avgSpeedKmh;
    final hasTimes = me != null || moving > 0 || rest > 0;

    final keyStats = <Widget>[
      _distanceMetric(me?.distanceM ?? t.totalDistanceKm * 1000, 'Distance', emphasis: true),
      RideMetric(value: dur(me?.durationMs ?? (t.endTimeEpochMs - t.startTimeEpochMs)), label: 'Duration', emphasis: true),
      RideMetric(value: hasTimes ? dur(moving) : '-', label: 'Riding time'),
      RideMetric(value: hasTimes ? dur(rest) : '-', label: 'Rest time'),
      RideMetric(value: '$stops', label: stops == 1 ? 'Stop' : 'Stops'),
      RideMetric(value: avg > 0 ? '${avg.round()}' : '-', unit: avg > 0 ? 'km/h' : null, label: 'Average speed'),
      RideMetric(value: longest != null && longest > 0 ? dur(longest) : (stops == 0 ? 'None' : '-'), label: 'Longest stop'),
    ];

    final error = _error;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Space.s16, Space.s16, Space.s16, Space.s32),
      children: [
        if (error != null) ...[
          RideAlert(tier: AlertTier.normal, title: 'Could not load the group report', message: error, actionLabel: 'Try again', onAction: _load),
          const SizedBox(height: Space.s16),
        ],
        Text(dateFmt.format(DateTime.fromMillisecondsSinceEpoch(t.startTimeEpochMs)), style: AppText.caption.copyWith(color: AppTheme.textSecondary)),
        if (t.startLocationName.isNotEmpty || t.destinationName.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Space.s4),
            child: Text(
              '${t.startLocationName.isEmpty ? 'Start' : t.startLocationName} to ${t.destinationName.isEmpty ? 'destination' : t.destinationName}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.title,
            ),
          ),
        const SizedBox(height: Space.s16),
        if (widget.adminView)
          _Panel(
            child: RouteSummary(
              distanceKm: (r?.distanceM ?? t.totalDistanceKm * 1000) / 1000,
              duration: Duration(milliseconds: r?.durationMs ?? (t.endTimeEpochMs - t.startTimeEpochMs)),
              stops: r?.plannedStops ?? t.stopCount,
              riders: r?.memberCount ?? t.riderCount,
            ),
          )
        else ...[
          Semantics(header: true, child: Text('Your ride', style: AppText.label)),
          const SizedBox(height: Space.s8),
          _MetricGrid(children: keyStats),
          if (t.isEstimate && r == null && !_loading)
            Padding(
              padding: const EdgeInsets.only(top: Space.s12),
              child: Text('These numbers are from your phone. The exact report is ready about a minute after the trip ends.', style: AppText.caption),
            ),
        ],
        const SizedBox(height: Space.s16),
        _moreDetails(r, me, myId),
      ],
    );
  }

  /// "186 km" as value 186 and unit km.
  static RideMetric _distanceMetric(double meters, String label, {bool emphasis = false}) {
    final text = formatDistance(meters);
    final cut = text.lastIndexOf(' ');
    if (cut <= 0) return RideMetric(value: text, label: label, emphasis: emphasis);
    return RideMetric(value: text.substring(0, cut), unit: text.substring(cut + 1), label: label, emphasis: emphasis);
  }

  Widget _moreDetails(TripReportModel? r, MemberReport? me, String? myId) {
    final t = widget.trip;
    String dur(int ms) => formatDuration(Duration(milliseconds: ms));
    final extra = <Widget>[
      RideMetric(value: '${(me?.maxKmh ?? t.topSpeedKmh).round()}', unit: 'km/h', label: 'Top speed'),
      if ((r?.speedLimitKmh ?? 0) > 0)
        RideMetric(
          value: (me?.overspeedCount ?? 0) == 0 ? 'Never' : '${me!.overspeedCount} times',
          label: 'Over ${r!.speedLimitKmh} km/h${(me?.overspeedMs ?? 0) > 0 ? ', ${dur(me!.overspeedMs)}' : ''}',
        ),
      if (t.riderCount > 1 || (r?.memberCount ?? 0) > 1) RideMetric(value: '${r?.memberCount ?? t.riderCount}', label: 'Riders'),
    ];
    final children = <Widget>[
      if (!widget.adminView) ...[
        _MetricGrid(children: extra),
        if (me != null && !me.trackAvailable)
          Padding(
            padding: const EdgeInsets.only(top: Space.s12),
            child: Text('Your phone did not upload a route for this trip, so distance and riding time are estimates.',
                style: AppText.caption.copyWith(color: StatusColors.warning)),
          ),
        const SizedBox(height: Space.s16),
      ],
      if (r != null) ..._groupDetails(r, myId)
      else if (!_loading && _error == null)
        Text('The group report is being prepared. It is ready about a minute after the trip ends.', style: AppText.caption),
    ];
    return _Panel(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text('More details', style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
        subtitle: Text(widget.adminView ? 'The group and every rider' : 'Top speed, the group and every rider', style: AppText.caption),
        iconColor: AppTheme.neonCyan,
        collapsedIconColor: AppTheme.textSecondary,
        childrenPadding: const EdgeInsets.fromLTRB(Space.s12, 0, Space.s12, Space.s16),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  List<Widget> _groupDetails(TripReportModel r, String? myId) {
    String dur(int ms) => formatDuration(Duration(milliseconds: ms));
    final summary = [
      '${r.memberCount} riders',
      '${r.arrived} arrived',
      if (r.plannedStops > 0) '${r.visitedStops} of ${r.plannedStops} stops',
      if (r.sos > 0) '${r.sos} SOS',
    ].join(', ');
    return [
      Semantics(header: true, child: Text('The group', style: AppText.label)),
      const SizedBox(height: Space.s4),
      Text(summary, style: AppText.body),
      const SizedBox(height: Space.s8),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingTextStyle: AppText.label,
          dataTextStyle: AppText.body.copyWith(fontSize: 14),
          columnSpacing: Space.s16,
          horizontalMargin: Space.s8,
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
                  RiderAvatar(name: m.name, color: _colors[m.userId], size: 24),
                  const SizedBox(width: Space.s8),
                  Text(m.userId == myId ? '${m.name} (you)' : m.name),
                ])),
                DataCell(Text(m.trackAvailable ? formatDistance(m.distanceM) : 'n/a')),
                DataCell(Text(dur(m.movingMs))),
                DataCell(Text(dur(m.restMs))),
                DataCell(Text('${m.stops}')),
                DataCell(Text(m.trackAvailable ? '${m.avgMovingKmh.round()}' : 'n/a')),
                DataCell(Text(m.trackAvailable ? '${m.maxKmh.round()}' : 'n/a')),
                DataCell(Text(m.separatedMs > 0 ? dur(m.separatedMs) : '-')),
                DataCell(Text(m.offlineMs > 0 ? dur(m.offlineMs) : '-')),
                DataCell(Text(
                  m.overspeedCount > 0 ? '${m.overspeedCount} times, ${dur(m.overspeedMs)}, top ${m.overspeedMaxKmh.round()}' : '-',
                  style: m.overspeedCount > 0 ? TextStyle(color: StatusColors.warning) : null,
                )),
                DataCell(Text(m.reachedDestination ? 'Yes' : 'No',
                    style: TextStyle(color: m.reachedDestination ? StatusColors.success : AppTheme.textMuted))),
              ]),
          ],
        ),
      ),
      const SizedBox(height: Space.s4),
      Text(
          'Distance, average and top speed (km/h) come from each rider\'s recorded route. n/a: that phone did not upload a route.'
          '${r.speedLimitKmh > 0 ? ' Over limit: times above the group limit of ${r.speedLimitKmh} km/h, total time and top speed.' : ''}',
          style: AppText.caption),
      const SizedBox(height: Space.s16),
      Semantics(header: true, child: Text('Every rider: where they started, waited and finished', style: AppText.label)),
      const SizedBox(height: Space.s8),
      for (final m in r.members) _riderCard(m, myId),
    ];
  }

  /// One rider's day: start, every wait (when, how long, why, where), finish.
  Widget _riderCard(MemberReport m, String? myId) {
    final c = _colors[m.userId] ?? AppTheme.neonCyan;
    final hm = DateFormat('HH:mm');
    String dur(int ms) => formatDuration(Duration(milliseconds: ms));
    String at(int ms) => ms > 0 ? hm.format(DateTime.fromMillisecondsSinceEpoch(ms)) : '';
    final waits = _events.where((e) => e.userId == m.userId && e.type == 'STOPPED').toList()..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    final started = m.firstFixAt > 0 ? m.firstFixAt : m.joinedAt;
    Widget row(IconData icon, Color iconColor, String text, {VoidCallback? onTap}) {
      final line = Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.s4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 16, color: iconColor)),
          const SizedBox(width: Space.s8),
          Expanded(child: Text(text, style: AppText.caption.copyWith(color: onTap == null ? AppTheme.textSecondary : AppTheme.textPrimary))),
          if (onTap != null) Icon(Icons.map_rounded, size: 16, color: AppTheme.neonCyan),
        ]),
      );
      if (onTap == null) return line;
      return Semantics(
        button: true,
        hint: 'Show on map',
        child: InkWell(
          onTap: onTap,
          borderRadius: Radii.smAll,
          child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 48), child: Align(alignment: Alignment.centerLeft, child: line)),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s8),
      child: _Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            RiderAvatar(name: m.name, color: c, size: 32),
            const SizedBox(width: Space.s8),
            Expanded(
              child: Text(m.userId == myId ? '${m.name} (you)' : m.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
            ),
            if (m.reachedDestination) ...[
              Icon(Icons.sports_score_rounded, size: 16, color: StatusColors.success),
              const SizedBox(width: Space.s4),
              Text('Arrived', style: AppText.caption.copyWith(color: StatusColors.success)),
            ],
          ]),
          const SizedBox(height: Space.s8),
          Text(
            m.trackAvailable
                ? '${formatDistance(m.distanceM)} · riding ${dur(m.movingMs)} · waited ${waits.length} ${waits.length == 1 ? 'time' : 'times'}, ${dur(m.restMs)}'
                : 'No route was uploaded from this phone. Waits below come from the live updates.',
            style: AppText.caption.copyWith(color: m.trackAvailable ? AppTheme.textPrimary : StatusColors.warning),
          ),
          const SizedBox(height: Space.s4),
          row(Icons.play_circle_outline_rounded, c, ['Started ${at(started)}', if (m.startPlace.isNotEmpty) m.startPlace].join(' · ')),
          for (final w in waits)
            row(
              Icons.pause_circle_outline_rounded,
              c,
              [
                '${at(w.startedAt)} to ${at(w.endedAt ?? (w.startedAt + w.durationMs))}, ${dur(w.durationMs)}',
                if (w.dataString('reason').isNotEmpty) TimelineText.reason(w.dataString('reason')),
                if (w.placeName.isNotEmpty) w.placeName,
              ].join(' · '),
              onTap: w.hasPlace ? () => _showOnMap(w) : null,
            ),
          row(
            m.reachedDestination ? Icons.sports_score_rounded : Icons.flag_rounded,
            m.reachedDestination ? StatusColors.success : c,
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
}

/// The one card surface on this screen: flat, medium radius, hairline border.
class _Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const _Panel({required this.child, this.padding = const EdgeInsets.all(Space.s12)});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(color: AppTheme.slateCard, borderRadius: Radii.mdAll, border: Border.all(color: AppTheme.subtleBorder)),
      child: child,
    );
  }
}

/// RideMetric tiles, two per row on a phone and four on a wide screen.
class _MetricGrid extends StatelessWidget {
  final List<Widget> children;
  const _MetricGrid({required this.children});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth > 600 ? 4 : 2;
      final w = (c.maxWidth - (cols - 1) * Space.s8) / cols;
      return Wrap(spacing: Space.s8, runSpacing: Space.s8, children: [
        for (final m in children) SizedBox(width: w, child: _Panel(child: m)),
      ]);
    });
  }
}

/// The trip on one map with the timeline under it (beside it in landscape).
/// The map shows each rider's route in their colour, the planned route
/// dashed, their start and finish, where they waited (long rests marked),
/// where they left the route, the planned stops and the destination.
/// Tapping a timeline entry or a map symbol highlights it here.
class _RouteView extends StatefulWidget {
  final String groupId;
  final String title;
  final Map<String, Color> colors;
  final Map<String, String> names;
  final List<TimelineEventModel> events;
  final TripPlan? plan;
  final TripReportModel? report;
  final String? myUserId;
  final bool eventsLoading;
  final TimelineEventModel? highlight;
  final ValueChanged<TimelineEventModel?> onHighlight;

  const _RouteView({
    required this.groupId,
    required this.title,
    required this.colors,
    required this.names,
    required this.events,
    required this.plan,
    required this.report,
    required this.myUserId,
    required this.eventsLoading,
    required this.highlight,
    required this.onHighlight,
  });

  @override
  State<_RouteView> createState() => _RouteViewState();
}

class _RouteViewState extends State<_RouteView> with AutomaticKeepAliveClientMixin {
  final GlobalKey<TripRouteMapState> _mapKey = GlobalKey<TripRouteMapState>();
  List<ReplayTrack> _tracks = [];
  TripPlan? _trackPlan;
  bool _loading = true;
  String? _error;
  Set<String>? _visible; // null = everyone

  // Derived lists, rebuilt only when the events or the plan change.
  List<TimelineEventModel>? _eventsFor;
  List<TimelineEventModel> _stops = const [];
  List<TimelineEventModel> _deviations = const [];
  TripPlan? _lineFor;
  List<LatLng> _planned = const [];

  @override
  bool get wantKeepAlive => true; // keep the loaded routes when switching tabs

  @override
  void initState() {
    super.initState();
    _load();
  }

  TripPlan? get _plan => _trackPlan ?? widget.plan;

  Future<void> _load() async {
    if (_error != null) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final res = await context.read<ApiClient>().get('/convoys/${widget.groupId}/tracks?simplify=8', timeout: const Duration(seconds: 25));
      final list = (res is Map ? res['tracks'] : null) as List? ?? const [];
      final tracks = list.whereType<Map>().map((m) => ReplayTrack.fromJson(Map<String, dynamic>.from(m))).where((t) => t.points.length >= 2).toList();
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _trackPlan = res is Map ? TripPlan.fromJson(res['plan']) : null;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() { _error = e.message; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _error = 'Could not load the routes.'; _loading = false; });
    }
  }

  void _derive() {
    if (!identical(_eventsFor, widget.events)) {
      _eventsFor = widget.events;
      _stops = widget.events.where((e) => e.type == 'STOPPED' && e.hasPlace).toList();
      _deviations = widget.events.where((e) => e.type == 'OFF_ROUTE' && e.hasPlace).toList();
    }
    final p = _plan;
    if (!identical(_lineFor, p)) {
      _lineFor = p;
      _planned = TripRouteMap.plannedLineOf(p);
    }
  }

  String _name(String userId) => widget.names[userId]?.isNotEmpty == true ? widget.names[userId]! : 'A rider';

  static String _hm(int ms) => DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(ms));
  static String _dur(int ms) => formatDuration(Duration(milliseconds: ms));

  void _sheet(String title, List<String> lines) {
    showAppSheet<void>(
      context,
      title: title,
      builder: (_) => SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final l in lines)
            Padding(padding: const EdgeInsets.only(bottom: Space.s8), child: Text(l, style: AppText.body.copyWith(color: AppTheme.textSecondary))),
        ]),
      ),
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
    _sheet(s.name.isEmpty ? StopKind.fromCategory(s.category).label : s.name, lines);
  }

  void _onRiderEnd(ReplayTrack t, bool start) {
    final p = start ? t.points.first : t.points.last;
    MemberReport? m;
    for (final x in widget.report?.members ?? const <MemberReport>[]) {
      if (x.userId == t.userId) m = x;
    }
    final place = m == null ? '' : (start ? m.startPlace : m.endPlace);
    _sheet('${_name(t.userId)} ${start ? 'started' : 'finished'} at ${_hm(p.ts)}', [
      DateFormat('EEE d MMM').format(DateTime.fromMillisecondsSinceEpoch(p.ts)),
      if (place.isNotEmpty) place,
    ]);
  }

  Future<void> _pickRiders() async {
    final all = _tracks.map((t) => t.userId).toSet();
    await showAppSheet<void>(
      context,
      title: 'Riders on the map',
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: Space.s8, runSpacing: Space.s8, children: [
              for (final t in _tracks)
                FilterChip(
                  avatar: RiderAvatar(name: _name(t.userId), color: widget.colors[t.userId], size: 24),
                  label: Text(t.userId == widget.myUserId ? '${_name(t.userId)} (you)' : _name(t.userId), maxLines: 1, overflow: TextOverflow.ellipsis),
                  selected: _visible == null || _visible!.contains(t.userId),
                  onSelected: (_) {
                    if (!mounted) return;
                    setState(() {
                      final v = _visible ?? Set<String>.from(all);
                      if (!v.remove(t.userId)) v.add(t.userId);
                      _visible = v.length == all.length ? null : v;
                    });
                    setSheet(() {});
                  },
                  showCheckmark: true,
                  checkmarkColor: AppTheme.textPrimary,
                  selectedColor: (widget.colors[t.userId] ?? AppTheme.neonCyan).withOpacity(0.18),
                  backgroundColor: AppTheme.slateCard,
                  labelStyle: AppText.label.copyWith(color: AppTheme.textPrimary),
                  side: BorderSide(color: AppTheme.subtleBorder),
                  shape: const RoundedRectangleBorder(borderRadius: Radii.smAll),
                ),
            ]),
            const SizedBox(height: Space.s16),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Done')),
          ]),
        ),
      ),
    );
  }

  void _showLegend() {
    showAppSheet<void>(context, title: 'Map key', builder: (_) => const SingleChildScrollView(child: TripMapLegend()));
  }

  void _openReplay({TimelineEventModel? from}) {
    final e = from;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReplayScreen(
          groupId: widget.groupId,
          title: e == null ? widget.title : TimelineText.title(e, nowMs: DateTime.now().millisecondsSinceEpoch),
          initialTs: e?.startedAt,
          focusUserId: e?.userId,
          pin: e != null && e.hasPlace ? LatLng(e.lat!, e.lng!) : null,
          colors: widget.colors,
          events: widget.events,
        ),
      ),
    );
  }

  Widget _map() {
    final h = widget.highlight;
    final error = _error;
    return Stack(children: [
      Positioned.fill(
        child: LoadingState(
          loading: _loading,
          child: TripRouteMap(
            key: _mapKey,
            tracks: _tracks,
            colors: widget.colors,
            plan: _plan,
            stops: _stops,
            deviations: _deviations,
            plannedLine: _planned,
            visible: _visible,
            highlightEvent: h,
            onStopTap: widget.onHighlight,
            onDeviationTap: widget.onHighlight,
            onPlanStopTap: _onPlanStop,
            onRiderEndTap: _onRiderEnd,
          ),
        ),
      ),
      Positioned(
        top: Space.s8,
        right: Space.s8,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          MapControl(icon: Icons.zoom_out_map_rounded, tooltip: 'Show the whole trip', onPressed: () => _mapKey.currentState?.showAll()),
          const SizedBox(height: Space.s8),
          MapControl(icon: Icons.people_alt_rounded, tooltip: 'Choose riders', active: _visible != null, onPressed: _tracks.length > 1 ? _pickRiders : null),
          const SizedBox(height: Space.s8),
          MapControl(icon: Icons.help_outline_rounded, tooltip: 'Map key', onPressed: _showLegend),
        ]),
      ),
      if (error != null || h != null || (!_loading && _tracks.isEmpty))
        Positioned(
          left: Space.s8,
          right: Space.s8,
          bottom: Space.s8,
          child: error != null
              ? RideAlert(tier: AlertTier.normal, title: 'Could not load the routes', message: error, actionLabel: 'Try again', onAction: _load)
              : h != null
                  ? _HighlightCard(
                      event: h,
                      color: widget.colors[h.userId],
                      canReplay: _tracks.isNotEmpty,
                      onReplay: () => _openReplay(from: h),
                      onClose: () => widget.onHighlight(null),
                    )
                  : const RideAlert(
                      tier: AlertTier.normal,
                      title: 'No recorded routes for this trip',
                      message: 'Routes are kept for 90 days. The planned stops and destination are still shown.',
                    ),
        ),
    ]);
  }

  Widget _timeline() {
    return TimelineList(
      events: widget.events,
      colors: widget.colors,
      memberNames: widget.names,
      onTap: widget.onHighlight,
      tapWithoutPlace: true,
      selectedEventId: widget.highlight?.eventId,
      emptyState: widget.eventsLoading
          ? const LoadingSpinner()
          : const EmptyState(icon: Icons.timeline_rounded, title: 'No events for this trip'),
    );
  }

  Widget _playButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.s12, Space.s8, Space.s12, Space.s4),
      child: FilledButton.icon(
        onPressed: _tracks.isEmpty ? null : () => _openReplay(),
        icon: const Icon(Icons.play_arrow_rounded),
        label: const Text('Play the ride', maxLines: 1, overflow: TextOverflow.ellipsis),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    _derive();
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth > c.maxHeight) {
        final side = c.maxWidth * 0.45 < 380 ? c.maxWidth * 0.45 : 380.0;
        return Row(children: [
          Expanded(child: _map()),
          SizedBox(
            width: side,
            child: ColoredBox(
              color: AppTheme.darkCanvas,
              child: SafeArea(
                left: false,
                top: false,
                child: Column(children: [_playButton(), Expanded(child: _timeline())]),
              ),
            ),
          ),
        ]);
      }
      return Column(children: [
        Expanded(flex: 5, child: _map()),
        ColoredBox(color: AppTheme.darkCanvas, child: _playButton()),
        Expanded(
          flex: 4,
          child: ColoredBox(color: AppTheme.darkCanvas, child: SafeArea(top: false, child: _timeline())),
        ),
      ]);
    });
  }
}

/// What the highlighted timeline entry was, over the bottom of the map.
class _HighlightCard extends StatelessWidget {
  final TimelineEventModel event;
  final Color? color;
  final bool canReplay;
  final VoidCallback onReplay;
  final VoidCallback onClose;

  const _HighlightCard({required this.event, required this.color, required this.canReplay, required this.onReplay, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final detail = TimelineText.detail(event, nowMs: now);
    final time = DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(event.startedAt));
    return Material(
      color: AppTheme.slateCard,
      shape: RoundedRectangleBorder(borderRadius: Radii.mdAll, side: BorderSide(color: AppTheme.subtleBorder)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.s12, Space.s8, 0, Space.s8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: Space.s8),
            child: event.isGroupEntry
                ? Icon(Icons.groups_rounded, size: 28, color: AppTheme.textSecondary)
                : RiderAvatar(name: event.userName, color: color, size: 28),
          ),
          const SizedBox(width: Space.s8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: Space.s4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(TimelineText.title(event, nowMs: now), maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                Text(detail.isEmpty ? time : '$time · $detail', maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppTheme.textSecondary)),
                if (!event.hasPlace)
                  Text('Shows where riders were at that time.', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
              ]),
            ),
          ),
          if (canReplay)
            IconButton(tooltip: 'Play from here', onPressed: onReplay, icon: Icon(Icons.slow_motion_video_rounded, color: AppTheme.neonCyan)),
          IconButton(tooltip: 'Clear', onPressed: onClose, icon: Icon(Icons.close_rounded, color: AppTheme.textSecondary)),
        ]),
      ),
    );
  }
}
