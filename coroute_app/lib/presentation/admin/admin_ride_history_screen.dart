import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/models/trip_history_model.dart';
import '../../data/services/api_client.dart';
import '../../domain/timeline/timeline_text.dart';
import '../report/trip_report_screen.dart';

/// Master admin: every finished ride across all riders, with fleet totals.
/// Tapping a ride opens the full group report (summary, map of every rider,
/// timeline, replay), the same screens riders see for their own trips.
class AdminRideHistoryScreen extends StatefulWidget {
  const AdminRideHistoryScreen({super.key});

  @override
  State<AdminRideHistoryScreen> createState() => _AdminRideHistoryScreenState();
}

class _AdminRideHistoryScreenState extends State<AdminRideHistoryScreen> {
  List<Map<String, dynamic>> _rides = [];
  Map<String, dynamic> _stats = {};
  int _days = 30;
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
    final api = context.read<ApiClient>();
    try {
      final h = await api.get('/admin/convoys/history?limit=200', timeout: const Duration(seconds: 20));
      final s = await api.get('/admin/stats?days=$_days', timeout: const Duration(seconds: 20));
      _rides = ((h is Map ? h['convoys'] : null) as List? ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      _stats = s is Map ? Map<String, dynamic>.from(s) : {};
    } on ApiException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Could not load the ride history.';
    }
    if (mounted) setState(() => _loading = false);
  }

  static num _n(Map m, String k) => m[k] is num ? m[k] as num : 0;
  static num _n2(Map m, String k, String sub) => m[k] is Map ? _n(m[k] as Map, sub) : 0;

  void _open(Map<String, dynamic> c) {
    final trip = TripHistoryModel(
      tripId: '',
      tripName: c['name']?.toString() ?? 'Ride',
      startLocationName: c['startName']?.toString() ?? '',
      destinationName: c['destinationName']?.toString() ?? '',
      startTimeEpochMs: _n(c, 'startedAt').toInt(),
      endTimeEpochMs: _n(c, 'endedAt').toInt(),
      totalDistanceKm: _n(c, 'distanceM') / 1000,
      topSpeedKmh: 0,
      avgSpeedKmh: 0,
      riderCount: _n(c, 'members').toInt(),
      groupId: c['groupId']?.toString() ?? '',
      source: 'server',
    );
    Navigator.push(context, MaterialPageRoute(builder: (_) => TripReportScreen(trip: trip, adminView: true)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        title: const Text('Ride history'),
        actions: [IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh_rounded), onPressed: _load)],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppTheme.neonCyan))
          : _error != null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Padding(padding: const EdgeInsets.all(16), child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: AppTheme.laserRed))),
                    OutlinedButton(onPressed: _load, child: const Text('Try again')),
                  ]),
                )
              : RefreshIndicator(
                  color: AppTheme.neonCyan,
                  onRefresh: _load,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(16),
                        children: [
                          _statsCard(),
                          const SizedBox(height: 16),
                          Text('FINISHED RIDES (${_rides.length})',
                              style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
                          const SizedBox(height: 8),
                          if (_rides.isEmpty)
                            Text('No ride has finished yet.', style: TextStyle(color: AppTheme.textMuted))
                          else
                            for (final c in _rides) _rideTile(c),
                        ],
                      ),
                    ),
                  ),
                ),
    );
  }

  Widget _statsCard() {
    final s = _stats;
    String dur(num ms) => TimelineText.duration(Duration(milliseconds: ms.toInt()));
    final tiles = <(String, String)>[
      ('Riders registered', '${_n(s, 'riders')}'),
      ('Active riders', '${_n(s, 'activeRiders')}'),
      ('New riders', '${_n(s, 'newRiders')}'),
      ('Riding now', '${_n(s, 'liveConvoys')} convoys'),
      ('Rides', '${_n2(s, 'rides', 'recent')} (${_n2(s, 'rides', 'all')} in all)'),
      ('Distance', '${TimelineText.distance(_n2(s, 'distanceM', 'recent'))} (${TimelineText.distance(_n2(s, 'distanceM', 'all'))})'),
      ('Time on the road', '${dur(_n2(s, 'rideMs', 'recent'))} (${dur(_n2(s, 'rideMs', 'all'))})'),
      ('Average group', '${_n(s, 'avgGroupSize')} riders'),
      ('Rider trip records', '${_n(s, 'riderTrips')}'),
      ('SOS', '${_n2(s, 'sos', 'recent')} (${_n2(s, 'sos', 'all')})'),
    ];
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('Fleet totals', style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.bold))),
          DropdownButton<int>(
            value: _days,
            dropdownColor: AppTheme.elevatedCard,
            underline: const SizedBox.shrink(),
            style: TextStyle(color: AppTheme.neonCyan, fontSize: 13),
            items: const [
              DropdownMenuItem(value: 7, child: Text('Last 7 days')),
              DropdownMenuItem(value: 30, child: Text('Last 30 days')),
              DropdownMenuItem(value: 365, child: Text('Last year')),
            ],
            onChanged: (v) {
              if (v == null) return;
              _days = v;
              _load();
            },
          ),
        ]),
        const SizedBox(height: 4),
        Text('Numbers for the chosen period; totals for all time in brackets. A ride\'s distance is its longest rider\'s distance.',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
        const SizedBox(height: 10),
        LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth > 600 ? 3 : 2;
          final w = (c.maxWidth - (cols - 1) * 10) / cols;
          return Wrap(spacing: 10, runSpacing: 10, children: [
            for (final (label, value) in tiles)
              SizedBox(
                width: w,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                  Text(value, style: TextStyle(color: AppTheme.textPrimary, fontSize: 14, fontWeight: FontWeight.bold)),
                ]),
              ),
          ]);
        }),
      ]),
    );
  }

  Widget _rideTile(Map<String, dynamic> c) {
    final fmt = DateFormat('EEE d MMM yyyy, HH:mm');
    final started = _n(c, 'startedAt').toInt();
    final from = c['startName']?.toString() ?? '', to = c['destinationName']?.toString() ?? '';
    final members = _n(c, 'members').toInt(), arrived = _n(c, 'arrived').toInt();
    final details = [
      if (c['hasReport'] == true) TimelineText.distance(_n(c, 'distanceM')),
      TimelineText.duration(Duration(milliseconds: _n(c, 'durationMs').toInt())),
      '$members ${members == 1 ? 'rider' : 'riders'}${c['hasReport'] == true ? ', $arrived arrived' : ''}',
      if (_n(c, 'plannedStops') > 0) '${_n(c, 'visitedStops')} of ${_n(c, 'plannedStops')} stops',
      if (_n(c, 'sos') > 0) '${_n(c, 'sos')} SOS',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        onTap: () => _open(c),
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(c['name']?.toString() ?? 'Ride',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.bold)),
            ),
            if (c['hasReport'] != true)
              Text('no report', style: TextStyle(color: AppTheme.hyperAmber, fontSize: 11))
            else
              Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
          ]),
          Text(
            [if (started > 0) fmt.format(DateTime.fromMillisecondsSinceEpoch(started)), if ((c['createdByUserName'] ?? '').toString().isNotEmpty) 'lead ${c['createdByUserName']}'].join(' · '),
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          if (from.isNotEmpty || to.isNotEmpty)
            Text('${from.isEmpty ? 'Start' : from}  to  ${to.isEmpty ? 'open ride' : to}',
                maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
          const SizedBox(height: 4),
          Text(details, style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
        ]),
      ),
    );
  }
}
