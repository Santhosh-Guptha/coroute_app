import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/trip_history_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/convoy_service.dart';
import '../report/trip_report_screen.dart';
import 'admin_convoy_inspector.dart';
import 'admin_ui.dart';

/// Master admin: one user. Profile, account status with hold, block and
/// delete, and every ride they joined. A ride opens a short sheet with its
/// members and a button to the report (or the live ride).
class AdminUserDetailsScreen extends StatefulWidget {
  final String userId;
  final Map<String, dynamic>? initialUser;

  /// True when shown beside the users list on a wide screen (no back button).
  final bool embedded;

  /// Called after the account status changed (the list reloads).
  final VoidCallback? onChanged;

  /// Called after the account was deleted. When null the screen closes itself.
  final VoidCallback? onDeleted;

  const AdminUserDetailsScreen({
    super.key,
    required this.userId,
    this.initialUser,
    this.embedded = false,
    this.onChanged,
    this.onDeleted,
  });

  @override
  State<AdminUserDetailsScreen> createState() => _AdminUserDetailsScreenState();
}

class _AdminUserDetailsScreenState extends State<AdminUserDetailsScreen> {
  Map<String, dynamic>? _user;
  Map<String, dynamic>? _activeGroup;
  List<Map<String, dynamic>> _groups = [];
  bool _loading = true;
  bool _loaded = false;
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
    String? error;
    try {
      final res = await context.read<ApiClient>().get('/admin/users/${widget.userId}/details');
      if (res is Map) {
        final m = Map<String, dynamic>.from(res);
        _user = m['user'] is Map ? Map<String, dynamic>.from(m['user']) : _user;
        _activeGroup = m['activeGroup'] is Map ? Map<String, dynamic>.from(m['activeGroup']) : null;
        _groups = adminMapList(m['groups']);
      }
      _loaded = true;
    } on ApiException catch (e) {
      error = e.message;
    } catch (_) {
      error = 'Could not load user details.';
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = error;
    });
    if (error != null && _user != null) adminSnack(context, error, error: true);
  }

  bool get _isInActiveConvoy => _activeGroup != null;

  String get _name {
    final n = (_user?['name']?.toString() ?? '').trim();
    return n.isEmpty ? 'This user' : n;
  }

  Future<void> _updateStatus(String status) async {
    if (_isInActiveConvoy && status != 'ACTIVE') {
      adminSnack(context, 'Cannot hold or block a user who is in a live ride.', error: true);
      return;
    }

    String reason = '';
    if (status != 'ACTIVE') {
      final hold = status == 'ON_HOLD';
      final typed = await showAppSheet<String>(
        context,
        isScrollControlled: true,
        title: hold ? 'Put account on hold?' : 'Block account?',
        builder: (_) => _ReasonSheet(
          message: hold
              ? '$_name is signed out and cannot sign in until you release the hold.'
              : '$_name is signed out and cannot use CoRoute until you unblock the account.',
          confirmLabel: hold ? 'Put on hold' : 'Block account',
          destructive: !hold,
        ),
      );
      if (typed == null) return;
      reason = typed;
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
        adminSnack(context, status == 'ACTIVE' ? 'Account active again.' : (status == 'ON_HOLD' ? 'Account on hold.' : 'Account blocked.'));
      }
      widget.onChanged?.call();
    } on ApiException catch (e) {
      if (mounted) adminSnack(context, e.message, error: true);
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
        adminSnack(context, 'Account deleted.');
        final onDeleted = widget.onDeleted;
        if (onDeleted != null) {
          onDeleted();
        } else {
          Navigator.pop(context, true);
        }
      }
    } on ApiException catch (e) {
      if (mounted) adminSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _isActionInProgress = false);
    }
  }

  static bool _groupIsLive(Map<String, dynamic> g) =>
      g['tripStatus'] == 'STARTED' || g['tripStatus'] == 'PLANNING' || g['tripStatus'] == 'PAUSED';

  void _openGroupReport(Map<String, dynamic> g) {
    final groupId = g['groupId']?.toString() ?? '';
    if (_groupIsLive(g)) {
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

  void _showGroup(Map<String, dynamic> g) {
    final members = adminMapList(g['members']);
    final live = _groupIsLive(g);
    final from = g['startName']?.toString() ?? '';
    final to = g['destinationName']?.toString() ?? '';
    final route = (from.isNotEmpty || to.isNotEmpty) ? '${from.isEmpty ? 'Start' : from} to ${to.isEmpty ? 'Destination' : to}' : null;
    showAppSheet<void>(
      context,
      isScrollControlled: true,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSheetHeader(title: g['name']?.toString() ?? 'Ride', subtitle: route),
          Text('Riders (${members.length})', style: AppText.label),
          const SizedBox(height: Space.s8),
          Flexible(
            child: members.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: Space.s8),
                    child: Text('No member list was kept for this ride.', style: AppText.body.copyWith(color: AppTheme.textSecondary)),
                  )
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final m in members)
                        ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 56),
                          child: Row(
                            children: [
                              RiderAvatar(name: m['name']?.toString() ?? 'Rider', size: 36),
                              const SizedBox(width: Space.s12),
                              Expanded(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${m['name'] ?? 'Rider'}${m['userId'] == widget.userId ? ' (this user)' : ''}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppText.body,
                                    ),
                                    Text(
                                      [adminRoleLabel(m['role']), if ((m['vehicleType'] ?? '').toString().isNotEmpty) m['vehicleType'].toString()].join(', '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppText.caption,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: Space.s16),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _openGroupReport(g);
            },
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            icon: Icon(live ? Icons.map_rounded : Icons.description_rounded),
            label: Text(live ? 'Open live ride' : 'Open trip report'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final u = _user ?? const <String, dynamic>{};
    final title = (u['name']?.toString() ?? '').trim();
    final Widget content;
    if (_user == null && _error != null) {
      content = AdminScrollFill(child: AdminErrorState(message: _error!, onRetry: _loadDetails));
    } else {
      final isMasterAdmin = u['role'] == AppConstants.adminRole;
      final status = AccountStatus.fromCode(u['status'] ?? 'ACTIVE');
      content = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(Space.s16, Space.s16, Space.s16, Space.s32),
        children: [
          _header(u, status, isMasterAdmin),
          if (_isInActiveConvoy) ...[
            const SizedBox(height: Space.s16),
            _activeRide(),
          ],
          const AdminSectionLabel('Profile'),
          _profile(u),
          if (!isMasterAdmin) ...[
            const AdminSectionLabel('Account'),
            _actions(status),
          ],
          AdminSectionLabel('Rides (${_groups.length})'),
          if (_groups.isEmpty)
            Text(
              _loaded ? 'No rides yet.' : (_error != null ? 'Rides could not be loaded. Pull down to try again.' : 'Loading rides...'),
              style: AppText.body.copyWith(color: AppTheme.textSecondary),
            )
          else
            for (final g in _groups)
              Padding(padding: const EdgeInsets.only(bottom: Space.s8), child: _groupRow(g)),
        ],
      );
    }

    return Scaffold(
      primary: !widget.embedded,
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        primary: !widget.embedded,
        automaticallyImplyLeading: !widget.embedded,
        title: Text(title.isEmpty ? 'User' : title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh_rounded), onPressed: _loadDetails),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: LoadingState(
            loading: _loading,
            hasData: _user != null || _error != null,
            child: RefreshIndicator(color: AppTheme.neonCyan, onRefresh: _loadDetails, child: content),
          ),
        ),
      ),
    );
  }

  Widget _header(Map<String, dynamic> u, AccountStatus status, bool isMasterAdmin) {
    final name = (u['name']?.toString() ?? '').trim();
    final email = u['email']?.toString() ?? '';
    return Row(
      children: [
        RiderAvatar(name: name.isEmpty ? '?' : name, size: 56, color: isMasterAdmin ? AppTheme.infoBlue : null),
        const SizedBox(width: Space.s16),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name.isEmpty ? 'Rider' : name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title),
              if (email.isNotEmpty) Text(email, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label),
              const SizedBox(height: Space.s8),
              Wrap(
                spacing: Space.s8,
                runSpacing: Space.s4,
                children: [
                  StatusTextChip.account(status),
                  if (isMasterAdmin) StatusTextChip(icon: Icons.admin_panel_settings_rounded, text: 'Admin', color: StatusColors.info),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _activeRide() {
    final gName = _activeGroup?['name']?.toString() ?? 'a live ride';
    final role = adminRoleLabel(_activeGroup?['role']);
    return RideAlert(
      tier: AlertTier.normal,
      title: 'In a live ride: $gName',
      message: 'Role: $role. Hold and block are not available until the ride ends.',
    );
  }

  Widget _profile(Map<String, dynamic> u) {
    final created = (u['createdAt'] as num?)?.toInt() ?? 0;
    final lastActive = (u['lastActiveAt'] as num?)?.toInt() ?? 0;
    final fmt = DateFormat('d MMM yyyy, HH:mm');
    final phone = u['phone']?.toString() ?? '';
    final vehicleNo = u['vehicleNo']?.toString() ?? '';
    final reason = (u['statusReason'] ?? '').toString();
    final rows = <(String, String)>[
      ('Phone', phone.isNotEmpty ? phone : 'Not provided'),
      ('Vehicle', '${u['vehicleType'] ?? 'Motorcycle'}${vehicleNo.isNotEmpty ? ', $vehicleNo' : ''}'),
      if ((u['emergencyContact'] ?? '').toString().isNotEmpty)
        ('Emergency contact', '${u['emergencyContactName'] ?? 'ICE'}, ${u['emergencyContact']}'),
      if (created > 0) ('Registered', fmt.format(DateTime.fromMillisecondsSinceEpoch(created))),
      if (lastActive > 0) ('Last active', fmt.format(DateTime.fromMillisecondsSinceEpoch(lastActive))),
      if (reason.isNotEmpty) ('Status reason', reason),
    ];
    return AdminCard(
      padding: const EdgeInsets.symmetric(horizontal: Space.s16, vertical: Space.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, color: AppTheme.subtleBorder),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.s8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(rows[i].$1, style: AppText.caption),
                  const SizedBox(height: 2),
                  SelectableText(rows[i].$2, style: AppText.body),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _actions(AccountStatus status) {
    final isHeld = status == AccountStatus.onHold;
    final isBlocked = status == AccountStatus.blocked;
    final locked = _isActionInProgress || _isInActiveConvoy;
    const min = Size(48, 48);
    final warn = StatusColors.warning;
    final crit = StatusColors.critical;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_isInActiveConvoy)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s12),
            child: StatusLine(
              icon: Icons.info_rounded,
              text: 'Status cannot change while they are in a live ride.',
              color: warn,
            ),
          ),
        Wrap(
          spacing: Space.s8,
          runSpacing: Space.s8,
          children: [
            if (isHeld)
              FilledButton.icon(
                onPressed: locked ? null : () => _updateStatus('ACTIVE'),
                style: FilledButton.styleFrom(minimumSize: min),
                icon: const Icon(Icons.play_circle_rounded),
                label: const Text('Release hold'),
              )
            else
              OutlinedButton.icon(
                onPressed: locked ? null : () => _updateStatus('ON_HOLD'),
                style: OutlinedButton.styleFrom(minimumSize: min, foregroundColor: AppTheme.textPrimary),
                icon: Icon(Icons.pause_circle_rounded, color: locked ? null : warn),
                label: const Text('Put on hold'),
              ),
            if (isBlocked)
              FilledButton.icon(
                onPressed: locked ? null : () => _updateStatus('ACTIVE'),
                style: FilledButton.styleFrom(minimumSize: min),
                icon: const Icon(Icons.check_circle_rounded),
                label: const Text('Unblock'),
              )
            else
              OutlinedButton.icon(
                onPressed: locked ? null : () => _updateStatus('BLOCKED'),
                style: OutlinedButton.styleFrom(minimumSize: min, foregroundColor: crit, side: BorderSide(color: crit)),
                icon: const Icon(Icons.block_rounded),
                label: const Text('Block'),
              ),
            OutlinedButton.icon(
              onPressed: _isActionInProgress ? null : _deleteUser,
              style: OutlinedButton.styleFrom(minimumSize: min, foregroundColor: crit, side: BorderSide(color: crit)),
              icon: const Icon(Icons.delete_forever_rounded),
              label: const Text('Delete account'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _groupRow(Map<String, dynamic> g) {
    final started = (g['startedAt'] as num?)?.toInt() ?? 0;
    final dateStr = started > 0 ? DateFormat('EEE d MMM yyyy, HH:mm').format(DateTime.fromMillisecondsSinceEpoch(started)) : 'Date unknown';
    final distanceKm = (g['totalDistanceKm'] as num?)?.toDouble() ?? 0.0;
    final movingMs = (g['movingMs'] as num?)?.toInt() ?? 0;
    final members = (g['members'] as List?)?.length ?? 0;
    final live = _groupIsLive(g);
    final facts = [
      formatDistance(distanceKm * 1000),
      '${formatDuration(Duration(milliseconds: movingMs))} riding',
      '$members ${members == 1 ? 'rider' : 'riders'}',
    ].join(', ');
    return AdminRow(
      leading: AdminRowIcon(live ? Icons.two_wheeler_rounded : Icons.route_rounded, color: live ? StatusColors.success : null),
      title: g['name']?.toString() ?? 'Ride',
      subtitle: '$dateStr, ${adminRoleLabel(g['userRole'])}',
      detail: facts,
      status: live ? StatusLine(icon: Icons.sensors_rounded, text: 'Live now', color: StatusColors.success) : null,
      onTap: () => _showGroup(g),
    );
  }
}

/// Form for hold and block: what happens, an optional reason, one button.
/// Pops with the reason ('' when empty); dismissing pops null.
class _ReasonSheet extends StatefulWidget {
  final String message;
  final String confirmLabel;
  final bool destructive;

  const _ReasonSheet({required this.message, required this.confirmLabel, required this.destructive});

  @override
  State<_ReasonSheet> createState() => _ReasonSheetState();
}

class _ReasonSheetState extends State<_ReasonSheet> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.destructive ? StatusColors.critical : StatusColors.warning;
    final fg = widget.destructive ? StatusColors.onCritical : Colors.black;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.message, style: AppText.body.copyWith(color: AppTheme.textSecondary)),
          const SizedBox(height: Space.s16),
          TextField(
            controller: _ctrl,
            maxLines: 2,
            minLines: 1,
            textCapitalization: TextCapitalization.sentences,
            style: AppText.body,
            decoration: const InputDecoration(
              labelText: 'Reason (optional)',
              border: OutlineInputBorder(borderRadius: Radii.mdAll),
            ),
          ),
          const SizedBox(height: Space.s16),
          FilledButton(
            onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: bg, foregroundColor: fg, minimumSize: const Size.fromHeight(56)),
            child: Text(widget.confirmLabel),
          ),
          const SizedBox(height: Space.s8),
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48), foregroundColor: AppTheme.textPrimary),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}
