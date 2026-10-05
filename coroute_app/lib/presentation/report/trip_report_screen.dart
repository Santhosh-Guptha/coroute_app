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
import '../../data/models/trip_report_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
import '../../domain/timeline/timeline_text.dart';
import '../timeline/member_colors.dart';
import '../timeline/timeline_list.dart';
import 'replay_screen.dart';

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
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.neonCyan))
                  : const Icon(Icons.route_rounded, color: AppTheme.neonCyan),
              onPressed: _sharing ? null : _shareGpx,
            ),
          ],
          bottom: const TabBar(
            indicatorColor: AppTheme.neonCyan,
            labelColor: AppTheme.neonCyan,
            unselectedLabelColor: AppTheme.textMuted,
            tabs: [Tab(text: 'Summary'), Tab(text: 'Timeline'), Tab(text: 'Replay')],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator(color: AppTheme.neonCyan))
            : _error != null
                ? Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_error!, style: const TextStyle(color: AppTheme.laserRed), textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      OutlinedButton(onPressed: _load, child: const Text('Try again')),
                    ]),
                  )
                : TabBarView(
                    physics: const NeverScrollableScrollPhysics(), // the replay map needs horizontal drags
                    children: [
                      _summary(),
                      TimelineList(events: _events, colors: _colors, memberNames: _names, onTap: _openOnMap),
                      _replayTab(),
                    ],
                  ),
      ),
    );
  }

  Widget _replayTab() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.slow_motion_video_rounded, color: AppTheme.neonCyan, size: 48),
          const SizedBox(height: 12),
          const Text('Watch the whole group ride again. Drag the time bar to see where everyone was at any moment.',
              textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ReplayScreen(groupId: widget.trip.groupId, title: widget.trip.tripName, colors: _colors)),
            ),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Open replay'),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.neonCyan, foregroundColor: Colors.black, minimumSize: const Size(200, 46)),
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
    ];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(dateFmt.format(DateTime.fromMillisecondsSinceEpoch(t.startTimeEpochMs)), style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
        if (t.startLocationName.isNotEmpty || t.destinationName.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('${t.startLocationName.isEmpty ? 'Start' : t.startLocationName}  to  ${t.destinationName.isEmpty ? 'destination' : t.destinationName}',
                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        const SizedBox(height: 14),
        const Text('YOUR RIDE', style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
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
                    Text(label, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                    const SizedBox(height: 4),
                    Text(value, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  ]),
                ),
              ),
          ]);
        }),
        if (me != null && !me.trackAvailable)
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text('Your phone did not upload a route for this trip, so distance and riding time are estimates.',
                style: TextStyle(color: AppTheme.hyperAmber, fontSize: 12)),
          ),
        if (r != null) ...[
          const SizedBox(height: 22),
          Text('THE GROUP: ${r.memberCount} RIDERS, ${r.arrived} ARRIVED${r.plannedStops > 0 ? ', ${r.visitedStops} OF ${r.plannedStops} STOPS' : ''}${r.sos > 0 ? ', ${r.sos} SOS' : ''}',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
          const SizedBox(height: 8),
          GlassCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingTextStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.bold),
                dataTextStyle: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
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
                      DataCell(Icon(m.reachedDestination ? Icons.check_circle_rounded : Icons.remove_rounded,
                          size: 16, color: m.reachedDestination ? AppTheme.emeraldSafe : AppTheme.textMuted)),
                    ]),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Text('Distance, average and top speed come from each rider\'s recorded route. n/a: that phone did not upload a route.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
        ] else
          const Padding(
            padding: EdgeInsets.only(top: 18),
            child: Text('The group report is being prepared. It is ready about a minute after the trip ends.',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
          ),
      ],
    );
  }
}
