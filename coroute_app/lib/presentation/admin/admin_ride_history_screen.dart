import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/trip_history_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/convoy_service.dart';
import '../report/trip_report_screen.dart';
import 'admin_convoy_inspector.dart';
import 'admin_ui.dart';

enum _RideFilter { all, live, ended, retention }

/// Master admin: every ride, live and finished, with totals for a period,
/// how long each route is still kept, and delete. Search and filter sit in
/// one row. Pull down to refresh; the list stays visible while it reloads.
class AdminRideHistoryScreen extends StatefulWidget {
  const AdminRideHistoryScreen({super.key});

  @override
  State<AdminRideHistoryScreen> createState() => _AdminRideHistoryScreenState();
}

class _AdminRideHistoryScreenState extends State<AdminRideHistoryScreen> {
  List<Map<String, dynamic>> _activeGroups = [];
  List<Map<String, dynamic>> _completedGroups = [];
  List<Map<String, dynamic>> _approachingRetention = [];
  Map<String, dynamic> _stats = {};
  int? _retentionDays;
  int _days = 30;
  int _loadSeq = 0;
  bool _loading = true;
  bool _loaded = false;
  String? _error;
  String _query = '';
  _RideFilter _filter = _RideFilter.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Only the newest load counts: picking 7 days and then a year quickly must
    // not end with the 7-day totals under "Last year".
    final seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = context.read<ApiClient>();
    String? error;
    try {
      final g = await api.get('/admin/groups', timeout: const Duration(seconds: 20));
      final s = await api.get('/admin/stats?days=$_days', timeout: const Duration(seconds: 20));
      if (seq != _loadSeq) return;

      if (g is Map) {
        _activeGroups = adminMapList(g['active']);
        _completedGroups = adminMapList(g['completed']);
        _approachingRetention = adminMapList(g['approachingRetention']);
        final r = g['retentionPolicyDays'];
        _retentionDays = r is num ? r.toInt() : null;
      }
      _stats = s is Map ? Map<String, dynamic>.from(s) : {};
      _loaded = true;
    } on ApiException catch (e) {
      error = e.message;
    } catch (_) {
      error = 'Could not load group records.';
    }
    if (!mounted || seq != _loadSeq) return;
    setState(() {
      _loading = false;
      _error = error;
    });
    if (error != null && _loaded) adminSnack(context, error, error: true);
  }

  static num _n2(Map m, String k, String sub) => m[k] is Map ? adminNum(m[k] as Map, sub) : 0;

  static bool _isLive(Map<String, dynamic> c) =>
      c['isActive'] == true || c['tripStatus'] == 'STARTED' || c['tripStatus'] == 'PLANNING' || c['tripStatus'] == 'PAUSED';

  void _openGroup(Map<String, dynamic> c, {bool isActive = false}) {
    final groupId = c['groupId']?.toString() ?? '';
    if (isActive) {
      final convoyService = context.read<ConvoyService>();
      final room = convoyService.allConvoys[groupId];
      if (room != null) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => AdminConvoyInspector(convoy: room)));
        return;
      }
    }

    final trip = TripHistoryModel(
      tripId: '',
      tripName: c['name']?.toString() ?? 'Ride',
      startLocationName: c['startName']?.toString() ?? '',
      destinationName: c['destinationName']?.toString() ?? '',
      startTimeEpochMs: adminNum(c, 'startedAt').toInt(),
      endTimeEpochMs: adminNum(c, 'endedAt').toInt(),
      totalDistanceKm: adminNum(c, 'distanceM') / 1000,
      topSpeedKmh: 0,
      avgSpeedKmh: 0,
      riderCount: adminNum(c, 'members').toInt(),
      groupId: groupId,
      source: 'server',
    );
    Navigator.push(context, MaterialPageRoute(builder: (_) => TripReportScreen(trip: trip, adminView: true)));
  }

  Future<void> _deleteGroupImmediately(Map<String, dynamic> c) async {
    final groupId = c['groupId']?.toString() ?? '';
    final name = c['name']?.toString() ?? 'this group';
    final isActive = c['tripStatus'] != 'ENDED';

    final confirm = await confirmAction(
      context,
      title: 'Delete trip?',
      message: isActive
          ? 'Permanently delete the active ride "$name"? All riders are removed and its tracks, messages, alerts and records are deleted.'
          : 'Permanently delete the ride "$name"? Its tracks, timeline and trip report are deleted.',
      confirmLabel: 'Delete',
      destructive: true,
    );

    if (!confirm || !mounted) return;

    try {
      await context.read<ApiClient>().delete('/admin/convoys/$groupId');
      if (mounted) {
        adminSnack(context, 'Ride "$name" deleted.');
        _load();
      }
    } on ApiException catch (e) {
      if (mounted) adminSnack(context, e.message, error: true);
    }
  }

  List<Map<String, dynamic>> _list(_RideFilter f) {
    switch (f) {
      case _RideFilter.live:
        return _activeGroups.map((g) => {...g, 'isActive': true}).toList();
      case _RideFilter.ended:
        return _completedGroups.map((g) => {...g, 'isActive': false}).toList();
      case _RideFilter.retention:
        return _approachingRetention.map((g) => {...g, 'isActive': false}).toList();
      case _RideFilter.all:
        return [
          ..._activeGroups.map((g) => {...g, 'isActive': true}),
          ..._completedGroups.map((g) => {...g, 'isActive': false}),
        ];
    }
  }

  static String _filterLabel(_RideFilter f) {
    switch (f) {
      case _RideFilter.all:
        return 'All rides';
      case _RideFilter.live:
        return 'Live';
      case _RideFilter.ended:
        return 'Finished';
      case _RideFilter.retention:
        return 'Removal soon';
    }
  }

  int _count(_RideFilter f) {
    switch (f) {
      case _RideFilter.all:
        return _activeGroups.length + _completedGroups.length;
      case _RideFilter.live:
        return _activeGroups.length;
      case _RideFilter.ended:
        return _completedGroups.length;
      case _RideFilter.retention:
        return _approachingRetention.length;
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final display = _list(_filter).where((c) {
      if (q.isEmpty) return true;
      for (final k in const ['name', 'createdByUserName', 'startName', 'destinationName']) {
        if ((c[k]?.toString() ?? '').toLowerCase().contains(q)) return true;
      }
      return false;
    }).toList();

    final Widget content;
    if (!_loaded && _error != null) {
      content = AdminScrollFill(child: AdminErrorState(message: _error!, onRetry: _load));
    } else {
      final children = <Widget>[
        _totals(),
        Padding(
          padding: const EdgeInsets.only(top: Space.s16, bottom: Space.s12),
          child: AdminSearchRow(
            hint: 'Ride, lead or place',
            onChanged: (v) => setState(() => _query = v),
            filter: AdminFilterButton<_RideFilter>(
              value: _filter,
              label: _filterLabel(_filter),
              options: [for (final f in _RideFilter.values) (f, '${_filterLabel(f)} (${_count(f)})')],
              onSelected: (f) => setState(() => _filter = f),
            ),
          ),
        ),
        if (display.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.s24),
            child: EmptyState(
              icon: Icons.route_rounded,
              title: q.isNotEmpty ? 'No matching rides' : 'No rides here',
              message: _filter == _RideFilter.live ? 'Nobody is riding right now.' : 'Try another search or filter.',
              primaryLabel: _filter != _RideFilter.all ? 'Show all rides' : null,
              onPrimary: _filter != _RideFilter.all ? () => setState(() => _filter = _RideFilter.all) : null,
            ),
          )
        else
          for (final c in display)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s8),
              child: _RideRow(
                key: ValueKey(c['groupId']),
                ride: c,
                live: _isLive(c),
                onTap: () => _openGroup(c, isActive: _isLive(c)),
                onDelete: () => _deleteGroupImmediately(c),
              ),
            ),
      ];
      content = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(Space.s16, Space.s16, Space.s16, Space.s32),
        children: children,
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        title: const Text('Ride history'),
        actions: [IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh_rounded), onPressed: _load)],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: LoadingState(
            loading: _loading,
            hasData: _loaded || _error != null,
            child: RefreshIndicator(color: AppTheme.neonCyan, onRefresh: _load, child: content),
          ),
        ),
      ),
    );
  }

  /// Totals for the chosen period, straight from /admin/stats.
  Widget _totals() {
    final s = _stats;
    final dist = formatDistance(_n2(s, 'distanceM', 'recent'));
    final cut = dist.lastIndexOf(' ');
    final keep = _retentionDays;
    return AdminCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('Totals', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title)),
              PopupMenuButton<int>(
                tooltip: 'Period',
                initialValue: _days,
                onSelected: (v) {
                  _days = v;
                  _load();
                },
                itemBuilder: (_) => [
                  for (final (d, label) in _periods) PopupMenuItem<int>(value: d, height: 48, child: Text(label, style: AppText.body)),
                ],
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_periodLabel(_days), style: AppText.label.copyWith(color: AppTheme.neonCyan)),
                      Icon(Icons.arrow_drop_down_rounded, color: AppTheme.neonCyan),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.s8),
          Row(
            children: [
              Expanded(child: RideMetric(value: '${_n2(s, 'rides', 'recent')}', label: 'Rides')),
              Expanded(
                child: cut > 0
                    ? RideMetric(value: dist.substring(0, cut), unit: dist.substring(cut + 1), label: 'Distance')
                    : RideMetric(value: dist, label: 'Distance'),
              ),
              Expanded(child: RideMetric(value: formatDuration(Duration(milliseconds: _n2(s, 'rideMs', 'recent').toInt())), label: 'On the road')),
              Expanded(child: RideMetric(value: '${adminNum(s, 'activeRiders')}', label: 'Active riders')),
            ],
          ),
          const SizedBox(height: Space.s12),
          Text(
            'All time: ${_n2(s, 'rides', 'all')} rides, ${formatDistance(_n2(s, 'distanceM', 'all'))}, '
            '${formatDuration(Duration(milliseconds: _n2(s, 'rideMs', 'all').toInt()))} on the road. '
            '${adminNum(s, 'riders')} riders registered.',
            style: AppText.label,
          ),
          const SizedBox(height: Space.s8),
          Text(
            keep == null
                ? 'Routes are removed automatically after the retention period. You can delete a ride at any time.'
                : 'Routes are kept for $keep days after a ride, then removed automatically. You can delete a ride at any time.',
            style: AppText.caption,
          ),
        ],
      ),
    );
  }

  static const _periods = <(int, String)>[(7, 'Last 7 days'), (30, 'Last 30 days'), (365, 'Last year')];

  static String _periodLabel(int days) {
    for (final (d, label) in _periods) {
      if (d == days) return label;
    }
    return 'Last $days days';
  }
}

/// One ride: name, date and lead, route, the numbers, and its retention state.
class _RideRow extends StatelessWidget {
  final Map<String, dynamic> ride;
  final bool live;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _RideRow({super.key, required this.ride, required this.live, required this.onTap, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final c = ride;
    final started = adminNum(c, 'startedAt').toInt();
    final from = c['startName']?.toString() ?? '';
    final to = c['destinationName']?.toString() ?? '';
    final members = adminNum(c, 'members').toInt();
    final arrived = adminNum(c, 'arrived').toInt();
    final daysRemaining = c['retentionDaysRemaining'] as num?;
    final lead = (c['createdByUserName'] ?? '').toString();
    final hasReport = c['hasReport'] == true;

    final when = [
      if (started > 0) DateFormat('EEE d MMM yyyy, HH:mm').format(DateTime.fromMillisecondsSinceEpoch(started)),
      if (lead.isNotEmpty) 'lead $lead',
    ].join(', ');
    final facts = [
      if (from.isNotEmpty || to.isNotEmpty) '${from.isEmpty ? 'Start' : from} to ${to.isEmpty ? 'Destination' : to}',
      [
        if (hasReport) formatDistance(adminNum(c, 'distanceM')),
        formatDuration(Duration(milliseconds: adminNum(c, 'durationMs').toInt())),
        '$members ${members == 1 ? 'rider' : 'riders'}${hasReport ? ', $arrived arrived' : ''}',
        if (adminNum(c, 'plannedStops') > 0) '${adminNum(c, 'visitedStops')} of ${adminNum(c, 'plannedStops')} stops',
      ].join(', '),
    ].join('\n');

    final sos = adminNum(c, 'sos');
    final Widget? status;
    if (live) {
      status = StatusLine(icon: Icons.sensors_rounded, text: 'Live now', color: StatusColors.success);
    } else if (c['gpsStripped'] == true) {
      status = StatusLine(icon: Icons.location_off_rounded, text: 'Route removed (retention)', color: StatusColors.offline);
    } else if (c['isApproachingRetention'] == true) {
      status = StatusLine(icon: Icons.schedule_rounded, text: 'Route removed in ${daysRemaining ?? 0} days', color: StatusColors.warning);
    } else if (daysRemaining != null) {
      status = StatusLine(icon: Icons.inventory_2_rounded, text: 'Route kept $daysRemaining more days');
    } else {
      status = null;
    }

    return AdminRow(
      leading: AdminRowIcon(live ? Icons.two_wheeler_rounded : Icons.route_rounded, color: live ? StatusColors.success : null),
      title: c['name']?.toString() ?? 'Ride',
      subtitle: when,
      detail: facts,
      status: sos > 0
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                StatusLine(icon: Icons.sos_rounded, text: '$sos SOS during this ride', color: StatusColors.critical),
                ?status,
              ],
            )
          : status,
      trailing: PopupMenuButton<String>(
        tooltip: 'More options',
        icon: Icon(Icons.more_vert_rounded, color: AppTheme.textSecondary),
        onSelected: (v) {
          if (v == 'delete') onDelete();
        },
        itemBuilder: (_) => [
          PopupMenuItem<String>(
            value: 'delete',
            height: 48,
            child: Row(children: [
              Icon(Icons.delete_outline_rounded, color: StatusColors.critical),
              const SizedBox(width: Space.s12),
              const Flexible(child: Text('Delete ride', maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}
