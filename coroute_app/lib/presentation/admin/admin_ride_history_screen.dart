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
import 'master_admin_dashboard.dart';

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
          padding: const EdgeInsets.only(top: 16, bottom: 12),
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
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: EmptyState(
              icon: Icons.route_rounded,
              title: q.isNotEmpty ? 'No matching rides' : 'No rides here',
              message: _filter == _RideFilter.live ? 'Nobody is riding right now.' : 'Try another search or filter.',
              primaryLabel: _filter != _RideFilter.all ? 'Show all rides' : null,
              onPrimary: _filter != _RideFilter.all ? () => setState(() => _filter = _RideFilter.all) : null,
            ),
          )
        else
          AdminTable(
            title: _filterLabel(_filter),
            trailing: Text(
              '${display.length} ${display.length == 1 ? 'ride' : 'rides'}',
              style: AppText.caption.copyWith(color: AppTheme.accentText, fontWeight: FontWeight.w700),
            ),
            columns: const ['Ride', 'Status'],
            rows: [
              for (var i = 0; i < display.length; i++)
                _RideRow(
                  key: ValueKey(display[i]['groupId']),
                  ride: display[i],
                  live: _isLive(display[i]),
                  last: i == display.length - 1,
                  onTap: () => _openGroup(display[i], isActive: _isLive(display[i])),
                  onDelete: () => _deleteGroupImmediately(display[i]),
                ),
            ],
          ),
      ];
      content = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        children: children,
      );
    }

    return AdminShell(
      title: 'Ride history',
      subtitle: 'Live and finished rides',
      onBack: () => Navigator.maybePop(context),
      actions: [AdminIconAction(icon: Icons.refresh_rounded, label: 'Refresh', onTap: _load)],
      nav: adminNavItems(context, AdminSection.rides),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: adminMaxContentWidth),
          child: LoadingState(
            loading: _loading,
            hasData: _loaded || _error != null,
            child: adminRefresh(onRefresh: _load, child: content),
          ),
        ),
      ),
    );
  }

  /// Totals for the chosen period, straight from /admin/stats: a period
  /// picker and the KPI tiles of the canvas, then the all-time line.
  Widget _totals() {
    final s = _stats;
    final keep = _retentionDays;
    final picker = PopupMenuButton<int>(
      tooltip: 'Period',
      initialValue: _days,
      color: AppTheme.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: AppTheme.border, width: 2)),
      onSelected: (v) {
        _days = v;
        _load();
      },
      itemBuilder: (_) => [
        for (final (d, label) in _periods) PopupMenuItem<int>(value: d, height: 48, child: Text(label, style: AppText.body.copyWith(fontWeight: FontWeight.w700))),
      ],
      child: Container(
        height: 40,
        padding: const EdgeInsets.fromLTRB(12, 0, 6, 0),
        decoration: BoxDecoration(color: AppTheme.soft, borderRadius: BorderRadius.circular(12)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_periodLabel(_days), style: AppText.label.copyWith(color: AppTheme.text, fontWeight: FontWeight.w800)),
            Icon(Icons.arrow_drop_down_rounded, color: AppTheme.accentText),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 8, 0, 12),
          child: Row(
            children: [
              Expanded(child: Semantics(header: true, child: Text('Totals', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title))),
              picker,
            ],
          ),
        ),
        AdminKpiGrid(
          tiles: [
            AdminKpiTile(label: 'Rides', value: '${_n2(s, 'rides', 'recent')}', delta: _periodLabel(_days)),
            AdminKpiTile(label: 'Distance', value: formatDistance(_n2(s, 'distanceM', 'recent')), delta: 'All rides together'),
            AdminKpiTile(label: 'On the road', value: formatDuration(Duration(milliseconds: _n2(s, 'rideMs', 'recent').toInt())), delta: 'Riding time'),
            AdminKpiTile(label: 'Active riders', value: '${adminNum(s, 'activeRiders')}', delta: '${adminNum(s, 'riders')} registered'),
          ],
        ),
        const SizedBox(height: 12),
        DsCard(
          tinted: true,
          borderColor: AppTheme.tint,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'All time: ${_n2(s, 'rides', 'all')} rides, ${formatDistance(_n2(s, 'distanceM', 'all'))}, '
                '${formatDuration(Duration(milliseconds: _n2(s, 'rideMs', 'all').toInt()))} on the road. '
                '${adminNum(s, 'riders')} riders registered.',
                style: AppText.label.copyWith(color: AppTheme.text, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                keep == null
                    ? 'Routes are removed automatically after the retention period. You can delete a ride at any time.'
                    : 'Routes are kept for $keep days after a ride, then removed automatically. You can delete a ride at any time.',
                style: AppText.caption,
              ),
            ],
          ),
        ),
      ],
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
  final bool last;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _RideRow({super.key, required this.ride, required this.live, required this.onTap, required this.onDelete, this.last = false});

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
      status = StatusTextChip(icon: Icons.sensors_rounded, text: 'Live now', color: AppTheme.accentText);
    } else if (c['gpsStripped'] == true) {
      status = StatusTextChip(icon: Icons.location_off_rounded, text: 'Route removed (retention)', color: AppTheme.muted);
    } else if (c['isApproachingRetention'] == true) {
      status = StatusTextChip(icon: Icons.schedule_rounded, text: 'Route removed in ${daysRemaining ?? 0} days', color: AppTheme.warnText);
    } else if (daysRemaining != null) {
      status = StatusLine(icon: Icons.inventory_2_rounded, text: 'Route kept $daysRemaining more days');
    } else {
      status = null;
    }

    return AdminRow(
      leading: AdminRowIcon(live ? Icons.two_wheeler_rounded : Icons.route_rounded, color: live ? AppTheme.accentText : AppTheme.muted),
      title: c['name']?.toString() ?? 'Ride',
      subtitle: when,
      detail: facts,
      status: sos > 0
          ? Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatusTextChip(icon: Icons.sos_rounded, text: '$sos SOS during this ride', color: AppTheme.sos),
                ?status,
              ],
            )
          : status,
      trailing: PopupMenuButton<String>(
        tooltip: 'More options',
        color: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: AppTheme.border, width: 2)),
        onSelected: (v) {
          if (v == 'delete') onDelete();
        },
        itemBuilder: (_) => [
          PopupMenuItem<String>(
            value: 'delete',
            height: 48,
            child: Row(children: [
              Icon(Icons.delete_outline_rounded, color: AppTheme.sos),
              const SizedBox(width: 12),
              Flexible(child: Text('Delete ride', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w700))),
            ]),
          ),
        ],
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(shape: BoxShape.circle, color: AppTheme.card, border: Border.all(color: AppTheme.border, width: 2)),
          child: Icon(Icons.more_horiz_rounded, color: AppTheme.text, size: 22),
        ),
      ),
      divider: !last,
      onTap: onTap,
    );
  }
}
