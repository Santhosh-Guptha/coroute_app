import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/models/trip_history_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/convoy_service.dart';
import '../../domain/timeline/timeline_text.dart';
import '../report/trip_report_screen.dart';
import 'admin_convoy_inspector.dart';

/// Master admin: Groups and Ride History with full retention management
/// and immediate group deletion capabilities.
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
  int _days = 30;
  bool _loading = true;
  String? _error;
  String _selectedTab = 'ALL'; // ALL, ACTIVE, COMPLETED, RETENTION

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
      final g = await api.get('/admin/groups', timeout: const Duration(seconds: 20));
      final s = await api.get('/admin/stats?days=$_days', timeout: const Duration(seconds: 20));

      if (g is Map) {
        final act = g['active'];
        final comp = g['completed'];
        final ret = g['approachingRetention'];
        _activeGroups = (act is List) ? act.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : [];
        _completedGroups = (comp is List) ? comp.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : [];
        _approachingRetention = (ret is List) ? ret.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : [];
      }
      _stats = s is Map ? Map<String, dynamic>.from(s) : {};
    } on ApiException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Could not load group records.';
    }
    if (mounted) setState(() => _loading = false);
  }

  static num _n(Map m, String k) => m[k] is num ? m[k] as num : 0;
  static num _n2(Map m, String k, String sub) => m[k] is Map ? _n(m[k] as Map, sub) : 0;

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
      startTimeEpochMs: _n(c, 'startedAt').toInt(),
      endTimeEpochMs: _n(c, 'endedAt').toInt(),
      totalDistanceKm: _n(c, 'distanceM') / 1000,
      topSpeedKmh: 0,
      avgSpeedKmh: 0,
      riderCount: _n(c, 'members').toInt(),
      groupId: groupId,
      source: 'server',
    );
    Navigator.push(context, MaterialPageRoute(builder: (_) => TripReportScreen(trip: trip, adminView: true)));
  }

  Future<void> _deleteGroupImmediately(Map<String, dynamic> c) async {
    final groupId = c['groupId']?.toString() ?? '';
    final name = c['name']?.toString() ?? 'this group';
    final isActive = c['tripStatus'] != 'ENDED';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.slateCard,
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: AppTheme.laserRed),
            const SizedBox(width: 8),
            Flexible(child: Text('Delete Group Immediately?', style: TextStyle(color: AppTheme.laserRed, fontSize: 16))),
          ],
        ),
        content: Text(
          isActive
              ? 'Permanently delete active convoy "$name"? This will immediately dismiss all active riders and purge all route tracks, telemetry, messages, alerts, and records from the database.'
              : 'Permanently delete completed group "$name"? All recorded GPS tracks, timeline events, and trip reports will be permanently purged immediately.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: AppTheme.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.laserRed, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete Immediately'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      await context.read<ApiClient>().delete('/admin/convoys/$groupId');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Group "$name" permanently purged from the database.'),
            backgroundColor: AppTheme.laserRed,
          ),
        );
        _load();
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: AppTheme.laserRed),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    List<Map<String, dynamic>> displayList = [];
    if (_selectedTab == 'ACTIVE') {
      displayList = _activeGroups.map((g) => {...g, 'isActive': true}).toList();
    } else if (_selectedTab == 'COMPLETED') {
      displayList = _completedGroups.map((g) => {...g, 'isActive': false}).toList();
    } else if (_selectedTab == 'RETENTION') {
      displayList = _approachingRetention.map((g) => {...g, 'isActive': false}).toList();
    } else {
      displayList = [
        ..._activeGroups.map((g) => {...g, 'isActive': true}),
        ..._completedGroups.map((g) => {...g, 'isActive': false}),
      ];
    }

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        title: const Text('Groups & Retention'),
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
                          const SizedBox(height: 14),

                          // Filter Chips for Groups Lifecycle
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                _filterChip('All Groups (${_activeGroups.length + _completedGroups.length})', 'ALL'),
                                const SizedBox(width: 6),
                                _filterChip('Active Groups (${_activeGroups.length})', 'ACTIVE', color: AppTheme.neonCyan),
                                const SizedBox(width: 6),
                                _filterChip('Completed (${_completedGroups.length})', 'COMPLETED', color: AppTheme.emeraldSafe),
                                const SizedBox(width: 6),
                                _filterChip('Approaching Retention (${_approachingRetention.length})', 'RETENTION', color: AppTheme.hyperAmber),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),

                          if (displayList.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 32),
                              child: Center(
                                child: Text('No groups found in this category.', style: TextStyle(color: AppTheme.textMuted)),
                              ),
                            )
                          else
                            for (final c in displayList) _groupTile(c),
                        ],
                      ),
                    ),
                  ),
                ),
    );
  }

  Widget _filterChip(String label, String value, {Color? color}) {
    final isSelected = _selectedTab == value;
    final chipColor = color ?? AppTheme.neonCyan;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => setState(() => _selectedTab = value),
      selectedColor: chipColor.withOpacity(0.2),
      labelStyle: TextStyle(
        color: isSelected ? chipColor : AppTheme.textSecondary,
        fontSize: 12,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
      ),
      backgroundColor: AppTheme.slateCard,
      side: BorderSide(color: isSelected ? chipColor : AppTheme.subtleBorder),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      showCheckmark: false,
    );
  }

  Widget _statsCard() {
    final s = _stats;
    String dur(num ms) => TimelineText.duration(Duration(milliseconds: ms.toInt()));
    final tiles = <(String, String)>[
      ('Active Groups', '${_activeGroups.length} live'),
      ('Completed Groups', '${_completedGroups.length} rides'),
      ('Approaching Retention', '${_approachingRetention.length} groups'),
      ('Riders registered', '${_n(s, 'riders')}'),
      ('Distance covered', TimelineText.distance(_n2(s, 'distanceM', 'all'))),
      ('Time on the road', dur(_n2(s, 'rideMs', 'all'))),
    ];

    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Fleet & Retention Overview', style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.bold)),
              ),
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
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'GPS routes are kept for 90 days before automatic retention cleanup. Admins can trigger immediate deletion anytime.',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
          ),
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
        ],
      ),
    );
  }

  Widget _groupTile(Map<String, dynamic> c) {
    final isActive = c['isActive'] == true || c['tripStatus'] == 'STARTED' || c['tripStatus'] == 'PLANNING' || c['tripStatus'] == 'PAUSED';
    final fmt = DateFormat('EEE d MMM yyyy, HH:mm');
    final started = _n(c, 'startedAt').toInt();
    final from = c['startName']?.toString() ?? '', to = c['destinationName']?.toString() ?? '';
    final members = _n(c, 'members').toInt(), arrived = _n(c, 'arrived').toInt();
    final daysRemaining = c['retentionDaysRemaining'] as num?;
    final isApproachingRetention = c['isApproachingRetention'] == true;
    final gpsStripped = c['gpsStripped'] == true;

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
        onTap: () => _openGroup(c, isActive: isActive),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          c['name']?.toString() ?? 'Ride',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: (isActive ? AppTheme.neonCyan : AppTheme.slateCard).withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: isActive ? AppTheme.neonCyan : AppTheme.subtleBorder),
                        ),
                        child: Text(
                          isActive ? 'ACTIVE' : 'COMPLETED',
                          style: TextStyle(color: isActive ? AppTheme.neonCyan : AppTheme.textMuted, fontSize: 9, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ),
                // Immediate Deletion Button
                IconButton(
                  tooltip: 'Immediate Deletion',
                  icon: Icon(Icons.delete_forever_rounded, color: AppTheme.laserRed, size: 20),
                  onPressed: () => _deleteGroupImmediately(c),
                ),
              ],
            ),
            Text(
              [if (started > 0) fmt.format(DateTime.fromMillisecondsSinceEpoch(started)), if ((c['createdByUserName'] ?? '').toString().isNotEmpty) 'lead ${c['createdByUserName']}'].join(' · '),
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            if (from.isNotEmpty || to.isNotEmpty)
              Text(
                '${from.isEmpty ? 'Start' : from} to ${to.isEmpty ? 'Destination' : to}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
            const SizedBox(height: 4),
            Text(details, style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),

            // Retention status pill
            if (!isActive) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  if (gpsStripped)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.slateCard,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('Retention Cleaned (GPS stripped)', style: TextStyle(color: AppTheme.textMuted, fontSize: 10)),
                    )
                  else if (isApproachingRetention)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.laserRed.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: AppTheme.laserRed.withOpacity(0.6)),
                      ),
                      child: Text(
                        'Approaching retention: ${daysRemaining ?? 0} days left',
                        style: TextStyle(color: AppTheme.laserRed, fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    )
                  else if (daysRemaining != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.slateCard,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('⏱️ $daysRemaining days retention remaining', style: TextStyle(color: AppTheme.textSecondary, fontSize: 10)),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
