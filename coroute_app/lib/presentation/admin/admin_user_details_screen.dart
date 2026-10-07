import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/models/trip_history_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/convoy_service.dart';
import '../../domain/timeline/timeline_text.dart';
import '../report/trip_report_screen.dart';
import 'admin_convoy_inspector.dart';

class AdminUserDetailsScreen extends StatefulWidget {
  final String userId;
  final Map<String, dynamic>? initialUser;

  const AdminUserDetailsScreen({super.key, required this.userId, this.initialUser});

  @override
  State<AdminUserDetailsScreen> createState() => _AdminUserDetailsScreenState();
}

class _AdminUserDetailsScreenState extends State<AdminUserDetailsScreen> {
  Map<String, dynamic>? _user;
  Map<String, dynamic>? _activeGroup;
  List<Map<String, dynamic>> _groups = [];
  bool _loading = true;
  String? _error;
  bool _isActionInProgress = false;

  @override
  void initState() {
    super.initState();
    _user = widget.initialUser;
    _loadDetails();
  }

  Future<void> _loadDetails() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await context.read<ApiClient>().get('/admin/users/${widget.userId}/details');
      if (res is Map) {
        final m = Map<String, dynamic>.from(res);
        _user = m['user'] is Map ? Map<String, dynamic>.from(m['user']) : _user;
        _activeGroup = m['activeGroup'] is Map ? Map<String, dynamic>.from(m['activeGroup']) : null;
        final glist = m['groups'];
        _groups = (glist is List) ? glist.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : [];
      }
    } on ApiException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Could not load user details.';
    }
    if (mounted) setState(() => _loading = false);
  }

  bool get _isInActiveConvoy => _activeGroup != null;

  Future<void> _updateStatus(String status) async {
    if (_isInActiveConvoy && status != 'ACTIVE') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Cannot hold or block a user who is actively in a convoy.'),
          backgroundColor: AppTheme.laserRed,
        ),
      );
      return;
    }

    String reason = '';
    if (status != 'ACTIVE') {
      final textCtrl = TextEditingController();
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.slateCard,
          title: Text(
            status == 'ON_HOLD' ? 'Hold User Account?' : 'Block User Account?',
            style: TextStyle(color: status == 'ON_HOLD' ? AppTheme.hyperAmber : AppTheme.laserRed),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                status == 'ON_HOLD'
                    ? 'This user will be suspended and unable to log in until released.'
                    : 'This user will be completely blocked from accessing CoRoute.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: textCtrl,
                style: TextStyle(color: AppTheme.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Reason (optional)',
                  hintStyle: TextStyle(color: AppTheme.textMuted),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel', style: TextStyle(color: AppTheme.textMuted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: status == 'ON_HOLD' ? AppTheme.hyperAmber : AppTheme.laserRed,
                foregroundColor: status == 'ON_HOLD' ? Colors.black : Colors.white,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(status == 'ON_HOLD' ? 'Confirm Hold' : 'Confirm Block'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
      reason = textCtrl.text.trim();
    }

    if (!mounted) return;
    setState(() => _isActionInProgress = true);
    try {
      final res = await context.read<ApiClient>().patch('/admin/users/${widget.userId}/status', {
        'status': status,
        'reason': reason,
      });
      if (res is Map && res['user'] is Map) {
        _user = Map<String, dynamic>.from(res['user']);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(status == 'ACTIVE' ? 'User account activated.' : (status == 'ON_HOLD' ? 'User placed on hold.' : 'User blocked.')),
            backgroundColor: status == 'ACTIVE' ? AppTheme.emeraldSafe : (status == 'ON_HOLD' ? AppTheme.hyperAmber : AppTheme.laserRed),
          ),
        );
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppTheme.laserRed));
      }
    } finally {
      if (mounted) setState(() => _isActionInProgress = false);
    }
  }

  Future<void> _deleteUser() async {
    final confirm = await confirmAction(
      context,
      title: 'Delete this account?',
      message: 'Permanently delete ${_user?['name'] ?? 'this user'}? Their account, profile and personal records are removed. This cannot be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirm || !mounted) return;

    setState(() => _isActionInProgress = true);
    try {
      await context.read<ApiClient>().delete('/admin/users/${widget.userId}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('User account permanently deleted.'), backgroundColor: AppTheme.laserRed),
        );
        Navigator.pop(context, true);
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppTheme.laserRed));
      }
    } finally {
      if (mounted) setState(() => _isActionInProgress = false);
    }
  }

  void _openGroupReport(Map<String, dynamic> g) {
    final groupId = g['groupId']?.toString() ?? '';
    final isGroupActive = g['tripStatus'] == 'STARTED' || g['tripStatus'] == 'PLANNING' || g['tripStatus'] == 'PAUSED';

    if (isGroupActive) {
      final convoyService = context.read<ConvoyService>();
      final room = convoyService.allConvoys[groupId];
      if (room != null) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => AdminConvoyInspector(convoy: room)));
        return;
      }
    }

    final trip = TripHistoryModel(
      tripId: g['tripId']?.toString() ?? '',
      tripName: g['name']?.toString() ?? 'Ride',
      startLocationName: g['startName']?.toString() ?? '',
      destinationName: g['destinationName']?.toString() ?? '',
      startTimeEpochMs: (g['startedAt'] as num?)?.toInt() ?? 0,
      endTimeEpochMs: (g['endedAt'] as num?)?.toInt() ?? 0,
      totalDistanceKm: (g['totalDistanceKm'] as num?)?.toDouble() ?? 0.0,
      topSpeedKmh: 0,
      avgSpeedKmh: 0,
      riderCount: (g['members'] as List?)?.length ?? 1,
      groupId: groupId,
      source: 'server',
    );
    Navigator.push(context, MaterialPageRoute(builder: (_) => TripReportScreen(trip: trip, adminView: true)));
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'ON_HOLD':
        return AppTheme.hyperAmber;
      case 'BLOCKED':
        return AppTheme.laserRed;
      default:
        return AppTheme.emeraldSafe;
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = _user ?? {};
    final status = (u['status']?.toString() ?? 'ACTIVE').toUpperCase();
    final statusColor = _statusColor(status);
    final isMasterAdmin = u['role'] == 'MASTER_ADMIN';

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        title: Text(u['name']?.toString() ?? 'User Profile', overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadDetails,
          ),
        ],
      ),
      body: _loading && _user == null
          ? Center(child: CircularProgressIndicator(color: AppTheme.neonCyan))
          : _error != null && _user == null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, style: TextStyle(color: AppTheme.laserRed))))
              : RefreshIndicator(
                  color: AppTheme.neonCyan,
                  onRefresh: _loadDetails,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          _buildProfileCard(u, status, statusColor, isMasterAdmin),
                          const SizedBox(height: 14),

                          // Active convoy warning banner
                          if (_isInActiveConvoy) ...[
                            _buildActiveConvoyBanner(),
                            const SizedBox(height: 14),
                          ],

                          // Admin Actions Card (Hold / Block / Delete)
                          if (!isMasterAdmin) ...[
                            _buildActionsCard(status),
                            const SizedBox(height: 18),
                          ],

                          // User's Groups & Trips with fellow members
                          _buildGroupsSection(),
                        ],
                      ),
                    ),
                  ),
                ),
    );
  }

  Widget _buildProfileCard(Map<String, dynamic> u, String status, Color statusColor, bool isMasterAdmin) {
    final created = (u['createdAt'] as num?)?.toInt() ?? 0;
    final lastActive = (u['lastActiveAt'] as num?)?.toInt() ?? 0;
    final fmt = DateFormat('dd MMM yyyy, HH:mm');

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: isMasterAdmin ? AppTheme.infoBlue.withOpacity(0.25) : statusColor.withOpacity(0.2),
                child: Icon(
                  isMasterAdmin ? Icons.shield_rounded : Icons.person_rounded,
                  color: isMasterAdmin ? AppTheme.infoBlue : statusColor,
                  size: 28,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            u['name']?.toString() ?? 'Rider',
                            style: TextStyle(color: AppTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: statusColor.withOpacity(0.18),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: statusColor.withOpacity(0.6)),
                          ),
                          child: Text(
                            status.replaceAll('_', ' '),
                            style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(u['email']?.toString() ?? '', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
          Divider(color: AppTheme.subtleBorder, height: 24),
          Wrap(
            spacing: 16,
            runSpacing: 10,
            children: [
              _infoTile('Phone', u['phone']?.toString().isNotEmpty == true ? u['phone'] : 'Not provided'),
              _infoTile('Vehicle', '${u['vehicleType'] ?? 'Motorcycle'} ${u['vehicleNo']?.toString().isNotEmpty == true ? "(${u['vehicleNo']})" : ""}'),
              if ((u['emergencyContact'] ?? '').toString().isNotEmpty)
                _infoTile('Emergency Contact', '${u['emergencyContactName'] ?? "ICE"} · ${u['emergencyContact']}'),
              if (created > 0) _infoTile('Registered', fmt.format(DateTime.fromMillisecondsSinceEpoch(created))),
              if (lastActive > 0) _infoTile('Last Active', fmt.format(DateTime.fromMillisecondsSinceEpoch(lastActive))),
              if ((u['statusReason'] ?? '').toString().isNotEmpty)
                _infoTile('Status Reason', u['statusReason'], color: AppTheme.hyperAmber),
            ],
          ),
        ],
      ),
    );
  }

  Widget _infoTile(String label, String value, {Color? color}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(color: color ?? AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _buildActiveConvoyBanner() {
    final gName = _activeGroup?['name']?.toString() ?? 'Active Ride';
    final gRole = _activeGroup?['role']?.toString() ?? 'RIDER';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.neonCyan.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.neonCyan.withOpacity(0.7)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.two_wheeler_rounded, color: AppTheme.neonCyan, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CURRENTLY IN ACTIVE CONVOY: $gName',
                  style: TextStyle(color: AppTheme.neonCyan, fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 3),
                Text(
                  'Role: $gRole. Hold and block options are restricted while participating in an ongoing ride.',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionsCard(String status) {
    final isHeld = status == 'ON_HOLD';
    final isBlocked = status == 'BLOCKED';

    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Admin Actions', style: TextStyle(color: AppTheme.textPrimary, fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          if (_isInActiveConvoy)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Cannot change status while the rider is in an active convoy.',
                style: TextStyle(color: AppTheme.hyperAmber, fontSize: 12),
              ),
            ),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (isHeld)
                ElevatedButton.icon(
                  onPressed: _isActionInProgress || _isInActiveConvoy ? null : () => _updateStatus('ACTIVE'),
                  icon: const Icon(Icons.play_circle_outline_rounded, size: 18),
                  label: const Text('Release Hold (Activate)'),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.emeraldSafe, foregroundColor: Colors.black),
                )
              else
                ElevatedButton.icon(
                  onPressed: _isActionInProgress || _isInActiveConvoy ? null : () => _updateStatus('ON_HOLD'),
                  icon: const Icon(Icons.pause_circle_outline_rounded, size: 18),
                  label: const Text('Hold User'),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.hyperAmber, foregroundColor: Colors.black),
                ),
              if (isBlocked)
                ElevatedButton.icon(
                  onPressed: _isActionInProgress || _isInActiveConvoy ? null : () => _updateStatus('ACTIVE'),
                  icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
                  label: const Text('Unblock User'),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.emeraldSafe, foregroundColor: Colors.black),
                )
              else
                OutlinedButton.icon(
                  onPressed: _isActionInProgress || _isInActiveConvoy ? null : () => _updateStatus('BLOCKED'),
                  icon: const Icon(Icons.block_rounded, size: 18),
                  label: const Text('Block User'),
                  style: OutlinedButton.styleFrom(foregroundColor: AppTheme.laserRed, side: BorderSide(color: AppTheme.laserRed)),
                ),
              OutlinedButton.icon(
                onPressed: _isActionInProgress ? null : _deleteUser,
                icon: const Icon(Icons.delete_forever_rounded, size: 18),
                label: const Text('Delete User'),
                style: OutlinedButton.styleFrom(foregroundColor: AppTheme.textMuted, side: BorderSide(color: AppTheme.subtleBorder)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGroupsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'ALL CONVOYS & TRIPS (${_groups.length})',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_groups.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text('This user has not participated in any convoy rides yet.', style: TextStyle(color: AppTheme.textMuted)),
            ),
          )
        else
          for (final g in _groups) _buildGroupCard(g),
      ],
    );
  }

  Widget _buildGroupCard(Map<String, dynamic> g) {
    final started = (g['startedAt'] as num?)?.toInt() ?? 0;
    final dateStr = started > 0 ? DateFormat('EEE d MMM yyyy, HH:mm').format(DateTime.fromMillisecondsSinceEpoch(started)) : 'Trip';
    final from = g['startName']?.toString() ?? '';
    final to = g['destinationName']?.toString() ?? '';
    final distanceKm = (g['totalDistanceKm'] as num?)?.toDouble() ?? 0.0;
    final movingMs = (g['movingMs'] as num?)?.toInt() ?? 0;
    final userRole = g['userRole']?.toString() ?? 'PACK';
    final members = (g['members'] as List?)?.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList() ?? [];
    final isGroupActive = g['tripStatus'] == 'STARTED' || g['tripStatus'] == 'PLANNING' || g['tripStatus'] == 'PAUSED';

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    g['name']?.toString() ?? 'Convoy Ride',
                    style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: (isGroupActive ? AppTheme.neonCyan : AppTheme.slateCard).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: isGroupActive ? AppTheme.neonCyan : AppTheme.subtleBorder),
                  ),
                  child: Text(
                    isGroupActive ? 'ACTIVE' : 'COMPLETED',
                    style: TextStyle(color: isGroupActive ? AppTheme.neonCyan : AppTheme.textMuted, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text('$dateStr · Role in convoy: $userRole', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            if (from.isNotEmpty || to.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                '${from.isEmpty ? "Start" : from} to ${to.isEmpty ? "Destination" : to}',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 4),
            Text(
              '${distanceKm.toStringAsFixed(1)} km · ${TimelineText.duration(Duration(milliseconds: movingMs))} riding · ${members.length} members',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
            Divider(color: AppTheme.subtleBorder, height: 18),

            // Members who rode in that group
            Text('Members in this group (${members.length}):', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final m in members)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.slateCard,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.subtleBorder),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 5,
                          backgroundColor: m['role'] == 'LEAD' ? AppTheme.hyperAmber : (m['role'] == 'SWEEP' ? AppTheme.infoBlue : AppTheme.neonCyan),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${m['name'] ?? 'Rider'}${m['userId'] == widget.userId ? " (this rider)" : ""} [${m['role'] ?? "PACK"}]',
                          style: TextStyle(color: AppTheme.textPrimary, fontSize: 12, fontWeight: FontWeight.w500),
                        ),
                        if ((m['vehicleType'] ?? '').toString().isNotEmpty) ...[
                          const SizedBox(width: 4),
                          Text('· ${m['vehicleType']}', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => _openGroupReport(g),
                icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                label: Text(isGroupActive ? 'Inspect Live Convoy' : 'View Group Trip Report', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
