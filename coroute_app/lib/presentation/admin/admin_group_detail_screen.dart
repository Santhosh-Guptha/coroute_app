import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/trip_history_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/convoy_service.dart';
import '../report/trip_report_screen.dart';
import 'admin_convoy_inspector.dart';
import 'admin_payments_logic.dart';
import 'admin_payments_widgets.dart';
import 'admin_rider_insights.dart';
import 'admin_ui.dart';

/// Master admin: one ride (group) in numbers. Riders, distance, duration,
/// regroups, separations, alerts and incidents, and each rider's distance and
/// speed, from `/admin/analytics/groups/:groupId`. Opens the trip report (a
/// finished ride) or the live view (a ride in progress). Pull down to refresh.
class AdminGroupDetailScreen extends StatefulWidget {
  final String groupId;

  /// The ride's name while the numbers load.
  final String initialName;

  const AdminGroupDetailScreen({super.key, required this.groupId, this.initialName = ''});

  @override
  State<AdminGroupDetailScreen> createState() => _AdminGroupDetailScreenState();
}

class _AdminGroupDetailScreenState extends State<AdminGroupDetailScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;

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
    String? error;
    Map<String, dynamic>? data;
    try {
      final res = await context.read<ApiClient>().get('/admin/analytics/groups/${Uri.encodeComponent(widget.groupId)}', timeout: const Duration(seconds: 20));
      if (res is Map && res['group'] is Map) data = Map<String, dynamic>.from(res);
    } catch (e) {
      error = adminErrorOf(e);
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = error ?? (data == null && _data == null ? 'No numbers for this ride.' : null);
      if (data != null) _data = data;
    });
    if (error != null && _data != null) adminSnack(context, error, error: true);
  }

  Map<String, dynamic> _map(Map<String, dynamic>? m, String k) {
    final v = m?[k];
    return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  }

  void _openReport(Map<String, dynamic> g, Map<String, dynamic> s) {
    final trip = TripHistoryModel(
      tripId: '',
      tripName: g['name']?.toString() ?? 'Ride',
      startLocationName: g['startName']?.toString() ?? '',
      destinationName: g['destinationName']?.toString() ?? '',
      startTimeEpochMs: adminEpoch(g['startedAt']),
      endTimeEpochMs: adminEpoch(g['endedAt']),
      totalDistanceKm: (adminNumOrNull(s['distanceKm']) ?? 0).toDouble(),
      topSpeedKmh: 0,
      avgSpeedKmh: 0,
      riderCount: (adminNumOrNull(s['members']) ?? 0).toInt(),
      groupId: widget.groupId,
      source: 'server',
    );
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => TripReportScreen(trip: trip, adminView: true)));
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final g = _map(data, 'group');
    final s = _map(data, 'stats');
    final alerts = _map(s, 'alerts');
    final members = adminMapList(data?['members']);
    final name = (g['name']?.toString() ?? '').trim().isNotEmpty ? g['name'].toString() : (widget.initialName.isEmpty ? 'Ride' : widget.initialName);
    final live = g['live'] == true;
    final room = live ? context.watch<ConvoyService>().allConvoys[widget.groupId] : null;
    final median = adminNumOrNull(alerts['medianResponseSec']);
    final e = _error;

    final Widget content;
    if (data == null && e != null && !_loading) {
      content = AdminScrollFill(child: AdminErrorState(message: e, onRetry: _load));
    } else {
      content = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        children: [
          if (data != null) ...[
            Text(
              [
                live ? 'Riding now' : 'Finished ${adminDate(g['endedAt'], time: true)}',
                if ((g['createdByUserName']?.toString() ?? '').isNotEmpty) 'lead ${g['createdByUserName']}',
                if ((g['destinationName']?.toString() ?? '').isNotEmpty) 'to ${g['destinationName']}',
                if (g['hasStaff'] == true) 'staff on this ride',
              ].join(', '),
              style: AppText.body.copyWith(color: AppTheme.text2),
            ),
            const AdminSectionLabel('Ride'),
            AdminKpiGrid(
              minTileWidth: 130,
              tiles: [
                AdminKpiTile(label: 'Riders', value: adminCount(s['members']), delta: '${adminCount(s['arrived'])} arrived'),
                AdminKpiTile(label: 'Distance', value: '${adminCount(s['distanceKm'])} km', delta: 'Longest rider track'),
                AdminKpiTile(label: 'Duration', value: formatDuration(Duration(milliseconds: (adminNumOrNull(s['durationMs']) ?? 0).toInt()))),
                AdminKpiTile(label: 'Stops', value: '${adminCount(s['stopsVisited'])} of ${adminCount(s['stopsPlanned'])}', delta: 'Visited of planned'),
              ],
            ),
            const AdminSectionLabel('Safety'),
            AdminKpiGrid(
              minTileWidth: 130,
              tiles: [
                AdminKpiTile(
                  label: 'Alerts',
                  value: adminCount(alerts['total']),
                  valueColor: adminNum(alerts, 'open') > 0 ? AppTheme.sos : null,
                  delta: adminNum(alerts, 'open') > 0 ? '${adminCount(alerts['open'])} open' : '${adminCount(alerts['resolved'])} resolved, ${adminCount(alerts['falseAlarms'])} false',
                  deltaColor: adminNum(alerts, 'open') > 0 ? AppTheme.sos : null,
                ),
                AdminKpiTile(label: 'First response', value: median == null ? '—' : formatDuration(Duration(seconds: median.round())), delta: 'Median, SOS answered'),
                AdminKpiTile(label: 'Incidents', value: adminCount(s['incidents']), delta: 'Possible crash, sweeper help'),
                AdminKpiTile(label: 'Regroups', value: adminCount(s['regroups']), delta: '${adminCount(s['separations'])} separations'),
                AdminKpiTile(label: 'Off route', value: adminCount(s['offRoute']), delta: '${adminCount(s['overspeed'])} over the limit'),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (room != null)
                  FilledButton.icon(
                    onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => AdminConvoyInspector(convoy: room))),
                    icon: const Icon(Icons.map_rounded, size: 18),
                    label: const Text('Live view'),
                  ),
                if (!live)
                  OutlinedButton.icon(
                    onPressed: () => _openReport(g, s),
                    icon: const Icon(Icons.description_rounded, size: 18),
                    label: const Text('Trip report'),
                  ),
              ],
            ),
            AdminSectionLabel('Riders (${members.length})'),
            AdminTable(
              empty: Text('No riders recorded.', style: AppText.body.copyWith(color: AppTheme.text2)),
              rows: [
                for (var i = 0; i < members.length; i++) _memberRow(members[i], live, last: i == members.length - 1),
              ],
            ),
          ],
        ],
      );
    }

    return AdminShell(
      title: name,
      subtitle: 'Ride numbers',
      onBack: () => Navigator.maybePop(context),
      actions: [AdminIconAction(icon: Icons.refresh_rounded, label: 'Refresh', onTap: _load)],
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: LoadingState(
            loading: _loading,
            hasData: data != null || e != null,
            child: adminRefresh(onRefresh: _load, child: content),
          ),
        ),
      ),
    );
  }

  Widget _memberRow(Map<String, dynamic> m, bool live, {required bool last}) {
    final name = (m['name']?.toString() ?? '').trim();
    final track = m['trackAvailable'] == true;
    final sos = adminNum(m, 'sos');
    final separated = adminNum(m, 'separatedMs');
    return AdminRow(
      leading: RiderAvatar(name: name.isEmpty ? '?' : name),
      title: name.isEmpty ? 'Rider' : name,
      subtitle: [
        adminCapitalize((m['role']?.toString() ?? 'PACK').toLowerCase()),
        if (m['staff'] == true) 'staff',
        if (live) (m['online'] == true ? 'online' : 'not connected'),
        if (m['reachedDestination'] == true) 'arrived',
      ].join(', '),
      detail: track
          ? '${adminCount(m['distanceKm'])} km, avg ${adminCount(m['avgKmh'])} km/h, top ${adminCount(m['maxKmh'])} km/h'
              '${separated > 0 ? ', apart ${formatDuration(Duration(milliseconds: separated.toInt()))}' : ''}'
          : (live ? 'Numbers after the ride ends' : 'No track uploaded'),
      status: sos > 0 ? StatusLine(icon: Icons.sos_rounded, text: sos == 1 ? '1 SOS' : '${adminCount(sos)} SOS', color: AppTheme.sos) : null,
      divider: !last,
    );
  }
}
