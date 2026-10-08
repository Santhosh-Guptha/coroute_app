import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/map_tiles.dart';
import '../../core/ui/ui.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/sos_alert_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../auth/access_gate_screen.dart';
import '../ride/riders_ladder.dart';
import '../timeline/member_colors.dart';
import 'admin_convoy_inspector.dart';
import 'admin_emergencies_panel.dart';
import 'admin_insights_screen.dart';
import 'admin_ride_history_screen.dart';
import 'admin_ui.dart';
import 'admin_users_screen.dart';

/// The admin home: what needs attention first (the Emergencies panel with
/// every open SOS and crash and its alarm, live rides, accounts on hold),
/// then the numbers, the fleet map and the admin tools.
/// Every number comes from the server (live fleet over the socket, accounts
/// from /admin/users); nothing is estimated. Pull down to refresh; what is on
/// screen stays while it reloads.
class MasterAdminDashboard extends StatefulWidget {
  /// The emergency alarm sound; tests pass a fake.
  final AdminAlarm? alarm;

  const MasterAdminDashboard({super.key, this.alarm});

  @override
  State<MasterAdminDashboard> createState() => _MasterAdminDashboardState();
}

class _MasterAdminDashboardState extends State<MasterAdminDashboard> {
  /// Registered accounts, null until the first answer (then the counts show).
  List<Map<String, dynamic>>? _users;
  bool _loadingUsers = false;
  final GlobalKey<AdminEmergenciesPanelState> _emergencies = GlobalKey<AdminEmergenciesPanelState>();

  @override
  void initState() {
    super.initState();
    // Live fleet overview is pushed by the gateway (read-only, no audio).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<ConvoyService>().startAdminFleetWatch();
      _loadUsers();
    });
  }

  Future<void> _loadUsers() async {
    if (_loadingUsers) return;
    setState(() => _loadingUsers = true);
    try {
      final res = await context.read<ApiClient>().get('/admin/users');
      _users = adminMapList(res is Map ? res['users'] : null);
    } catch (_) {
      // Offline or busy: the counts that need it stay hidden or keep their last value.
    }
    if (mounted) setState(() => _loadingUsers = false);
  }

  Future<void> _refresh() async {
    context.read<ConvoyService>().startAdminFleetWatch();
    await Future.wait([_loadUsers(), _emergencies.currentState?.reload() ?? Future<void>.value()]);
  }

  void _push(Widget screen) => Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

  void _openConvoy(ConvoyModel convoy) => _push(AdminConvoyInspector(convoy: convoy));

  Future<void> _signOut() async {
    await context.read<AuthService>().logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const AccessGateScreen()), (_) => false);
  }

  void _showBroadcastSheet(ConvoyService convoyService) {
    showAppSheet<void>(
      context,
      isScrollControlled: true,
      title: 'Safety broadcast',
      builder: (_) => _BroadcastSheet(
        onSend: (msg) {
          convoyService.adminBroadcastSafetyAlert(msg);
          adminSnack(context, 'Safety alert sent to every live ride.');
        },
      ),
    );
  }

  LatLng _fleetCenter(List<LatLng> points) {
    if (points.isEmpty) return const LatLng(AppConstants.defaultMapLat, AppConstants.defaultMapLng); // India centre as neutral default
    var lat = 0.0, lng = 0.0;
    for (final p in points) {
      lat += p.latitude;
      lng += p.longitude;
    }
    return LatLng(lat / points.length, lng / points.length);
  }

  @override
  Widget build(BuildContext context) {
    final convoyService = context.watch<ConvoyService>();
    final now = DateTime.now().millisecondsSinceEpoch;
    final convoys = convoyService.allConvoys.values.toList();

    // Open SOS across every live ride, newest first.
    final sos = <(ConvoyModel, SosAlertModel)>[
      for (final c in convoys)
        for (final a in c.activeAlerts)
          if (!a.resolved) (c, a),
    ]..sort((x, y) => y.$2.timestamp.compareTo(x.$2.timestamp));
    final sosGroups = {for (final s in sos) s.$1.groupId};
    convoys.sort((a, b) {
      final s = (sosGroups.contains(b.groupId) ? 1 : 0) - (sosGroups.contains(a.groupId) ? 1 : 0);
      return s != 0 ? s : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    final totalRiders = convoys.fold<int>(0, (n, c) => n + c.riders.length);

    final users = _users;
    final onHold = users?.where((u) => AccountStatus.fromCode(u['status']) == AccountStatus.onHold).length;

    // 1. Emergencies: every open SOS and crash, with the alarm while the console is open.
    final sosSection = <Widget>[
      AdminEmergenciesPanel(
        key: _emergencies,
        alarm: widget.alarm ?? const NotifierAdminAlarm(),
        onOpenConvoy: _openConvoy,
      ),
    ];

    // 2. Live rides.
    final ridesSection = <Widget>[
      const AdminSectionLabel('Live rides'),
      if (convoys.isEmpty)
        AdminRow(
          leading: const AdminRowIcon(Icons.two_wheeler_rounded),
          title: 'No live rides right now',
          subtitle: 'Finished rides are in Ride history.',
          onTap: () => _push(const AdminRideHistoryScreen()),
        )
      else
        for (final c in convoys)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s8),
            child: _ConvoyRow(
              key: ValueKey(c.groupId),
              convoy: c,
              sosCount: sos.where((s) => s.$1.groupId == c.groupId).length,
              onTap: () => _openConvoy(c),
            ),
          ),
    ];

    // 3. Accounts on hold.
    final holdSection = <Widget>[
      if (onHold != null && onHold > 0)
        Padding(
          padding: const EdgeInsets.only(top: Space.s16),
          child: RideAlert(
            tier: AlertTier.important,
            title: onHold == 1 ? '1 account on hold' : '$onHold accounts on hold',
            message: 'They cannot sign in until you release the hold.',
            actionLabel: 'Review',
            onAction: () => _push(const AdminUsersScreen(initialFilter: AdminUserFilter.onHold)),
          ),
        ),
    ];

    // 4. Numbers.
    final stats = <Widget>[
      const AdminSectionLabel('Overview'),
      AdminCard(
        child: Row(
          children: [
            Expanded(child: RideMetric(value: '${convoys.length}', label: 'Live rides')),
            Expanded(child: RideMetric(value: '$totalRiders', label: 'Riders online')),
            Expanded(
              child: RideMetric(
                value: '${sos.length}',
                label: 'Open SOS',
                color: sos.isEmpty ? null : StatusColors.critical,
              ),
            ),
            if (users != null) Expanded(child: RideMetric(value: '${users.length}', label: 'Accounts')),
          ],
        ),
      ),
    ];

    // Fleet map, only when someone is out riding.
    final points = <LatLng>[
      for (final c in convoys)
        for (final r in c.riders.values)
          if (r.lat != 0.0 || r.lng != 0.0) LatLng(r.lat, r.lng),
    ];
    final mapSection = <Widget>[
      if (points.isNotEmpty) ...[
        const AdminSectionLabel('Fleet map'),
        SizedBox(height: 240, child: _fleetMap(convoys, points, now)),
      ],
    ];

    // 5. Tools.
    Widget tool(IconData icon, String title, String subtitle, VoidCallback onTap, {Color? color}) => ListTile(
          contentPadding: EdgeInsets.zero,
          minVerticalPadding: Space.s12,
          leading: Icon(icon, color: color ?? AppTheme.textSecondary),
          title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(color: color ?? AppTheme.textPrimary)),
          subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption),
          trailing: color == null ? Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted) : null,
          onTap: onTap,
        );
    final tools = <Widget>[
      const AdminSectionLabel('Manage'),
      tool(Icons.people_alt_rounded, 'Users', 'Accounts, hold, block, delete and their rides', () => _push(const AdminUsersScreen())),
      tool(Icons.history_rounded, 'Ride history', 'Live and finished rides, retention and delete', () => _push(const AdminRideHistoryScreen())),
      tool(Icons.insights_rounded, 'Feedback and analytics', 'Feedback, page views and app versions', () => _push(const AdminInsightsScreen())),
      tool(Icons.logout_rounded, 'Sign out', 'Leave the admin console on this phone', _signOut, color: AppTheme.textPrimary),
    ];

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        title: const Text('Admin'),
        actions: [
          IconButton(
            tooltip: 'Safety broadcast',
            icon: const Icon(Icons.campaign_rounded),
            onPressed: () => _showBroadcastSheet(convoyService),
          ),
        ],
      ),
      body: LoadingState(
        loading: _loadingUsers,
        child: RefreshIndicator(
          color: AppTheme.neonCyan,
          onRefresh: _refresh,
          child: LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth >= adminWideBreakpoint;
            final Widget body;
            if (wide) {
              body = Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [...sosSection, ...ridesSection, ...holdSection],
                    ),
                  ),
                  const SizedBox(width: Space.s24),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [...stats, ...mapSection, ...tools],
                    ),
                  ),
                ],
              );
            } else {
              body = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [...sosSection, ...ridesSection, ...holdSection, ...stats, ...mapSection, ...tools],
              );
            }
            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(Space.s16, Space.s8, Space.s16, Space.s32),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: wide ? 1200 : 760),
                  child: body,
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _fleetMap(List<ConvoyModel> convoys, List<LatLng> points, int now) {
    final markers = <Marker>[];
    for (final c in convoys) {
      final colors = MemberColors.assign(c.riders.keys);
      for (final r in c.riders.values) {
        if (r.lat == 0.0 && r.lng == 0.0) continue;
        markers.add(Marker(
          point: LatLng(r.lat, r.lng),
          width: 48,
          height: 48,
          child: RiderAvatar(
            name: r.name,
            color: colors[r.userId],
            status: riderStatusOf(r, c, isMe: false, nowMs: now),
            size: 36,
            onTap: () => _openConvoy(c),
          ),
        ));
      }
    }
    return ClipRRect(
      borderRadius: Radii.mdAll,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(borderRadius: Radii.mdAll, border: Border.all(color: AppTheme.subtleBorder)),
        child: FlutterMap(
          // A new fleet (rides started or ended) fits the camera again.
          key: ValueKey(convoys.map((c) => c.groupId).join(',')),
          options: MapOptions(
            initialCenter: _fleetCenter(points),
            initialZoom: 12,
            initialCameraFit: points.length > 1
                ? CameraFit.coordinates(coordinates: points, padding: const EdgeInsets.all(32), maxZoom: 14)
                : null,
          ),
          children: [
            TileLayer(
              tileBuilder: mapTileBuilder,
              urlTemplate: AppConstants.osmTileUrl,
              userAgentPackageName: AppConstants.osmUserAgent,
            ),
            MarkerLayer(markers: markers),
          ],
        ),
      ),
    );
  }
}

/// One live ride: name, code and lead, riders and destination, and an
/// "Emergency" chip when someone in it has an open SOS.
class _ConvoyRow extends StatelessWidget {
  final ConvoyModel convoy;
  final int sosCount;
  final VoidCallback onTap;

  const _ConvoyRow({super.key, required this.convoy, required this.sosCount, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = convoy;
    final n = c.riders.length;
    final dest = c.destinationName.trim();
    return AdminRow(
      leading: AdminRowIcon(Icons.two_wheeler_rounded, color: sosCount > 0 ? StatusColors.critical : null),
      title: c.name.isEmpty ? 'Ride' : c.name,
      subtitle: [
        if (c.joinCode.isNotEmpty) 'Code ${c.joinCode}',
        if (c.createdByUserName.isNotEmpty) 'lead ${c.createdByUserName}',
      ].join(', '),
      detail: '$n ${n == 1 ? 'rider' : 'riders'}, ${dest.isEmpty ? 'no destination set' : 'to $dest'}',
      status: sosCount > 0 ? RiderStatusChip(status: RiderStatus.emergency, detail: sosCount == 1 ? '1 SOS' : '$sosCount SOS') : null,
      onTap: onTap,
    );
  }
}

/// The broadcast form: what it does, the message, one send button.
class _BroadcastSheet extends StatefulWidget {
  final ValueChanged<String> onSend;

  const _BroadcastSheet({required this.onSend});

  @override
  State<_BroadcastSheet> createState() => _BroadcastSheetState();
}

class _BroadcastSheetState extends State<_BroadcastSheet> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _send() {
    final msg = _ctrl.text.trim();
    if (msg.isEmpty) return;
    Navigator.pop(context);
    widget.onSend(msg);
  }

  @override
  Widget build(BuildContext context) {
    final ready = _ctrl.text.trim().isNotEmpty;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Every rider in a live ride sees this alert on their map right away.',
            style: AppText.body.copyWith(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: Space.s16),
          TextField(
            controller: _ctrl,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            maxLength: 300,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            style: AppText.body,
            decoration: const InputDecoration(
              labelText: 'Message',
              hintText: 'Heavy rain on NH 48. Reduce speed and regroup.',
              border: OutlineInputBorder(borderRadius: Radii.mdAll),
            ),
          ),
          const SizedBox(height: Space.s8),
          FilledButton.icon(
            onPressed: ready ? _send : null,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            icon: const Icon(Icons.campaign_rounded),
            label: const Text('Send to all live rides'),
          ),
        ],
      ),
    );
  }
}
