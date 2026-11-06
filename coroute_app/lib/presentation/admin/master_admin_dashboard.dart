import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/constants/telemetry_utils.dart';
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
import 'admin_payments_logic.dart';
import 'admin_plans_pricing_screen.dart';
import 'admin_reviews_screen.dart';
import 'admin_ride_history_screen.dart';
import 'admin_rider_insights.dart';
import 'admin_safety_screen.dart';
import 'admin_settings_screen.dart';
import 'admin_ui.dart';
import 'admin_users_screen.dart';

/// The sections of the one admin console (rail on wide screens, drawer on phones): eight, each
/// with a short plain name. Plans and coupons are tabs of Payments; phone reports are in Insights.
enum AdminSection { dashboard, users, rides, safety, payments, reviews, insights, settings }

/// The nav items for an admin screen that shows [current]. From the
/// overview a section is pushed; from another section it replaces that
/// section, so "Overview" is always one pop away.
List<AdminNavItem> adminNavItems(BuildContext context, AdminSection current, {int emergencies = 0, VoidCallback? onSignOut}) {
  void go(AdminSection s, Widget Function() screen) {
    if (s == current) return;
    final route = MaterialPageRoute<void>(builder: (_) => screen());
    if (current == AdminSection.dashboard) {
      Navigator.push(context, route);
    } else {
      Navigator.pushReplacement(context, route);
    }
  }

  AdminNavItem item(AdminSection s, IconData icon, String label, Widget Function() screen, {int badge = 0}) => AdminNavItem(
        icon: icon,
        label: label,
        selected: current == s,
        badge: badge,
        onTap: () => go(s, screen),
      );

  return [
    AdminNavItem(
      icon: Icons.space_dashboard_outlined,
      label: 'Overview',
      selected: current == AdminSection.dashboard,
      badge: emergencies,
      onTap: current == AdminSection.dashboard ? null : () => Navigator.maybePop(context),
    ),
    item(AdminSection.users, Icons.people_alt_outlined, 'Riders', () => const AdminUsersScreen()),
    item(AdminSection.rides, Icons.alt_route_rounded, 'Rides', () => const AdminRideHistoryScreen()),
    item(AdminSection.safety, Icons.sos_rounded, 'Safety', () => const AdminSafetyScreen()),
    item(AdminSection.payments, Icons.payments_outlined, 'Payments', () => const AdminPlansPricingScreen()),
    item(AdminSection.reviews, Icons.rate_review_outlined, 'Reviews', () => const AdminReviewsScreen()),
    item(AdminSection.insights, Icons.insights_rounded, 'Insights', () => const AdminInsightsScreen()),
    item(AdminSection.settings, Icons.settings_outlined, 'Settings', () => const AdminSettingsScreen()),
    if (onSignOut != null) AdminNavItem(icon: Icons.logout_rounded, label: 'Sign out', danger: true, onTap: onSignOut),
  ];
}

/// The admin console home (Overview), the one entry point of the admin app on
/// phones and tablets: what needs attention first (the Emergencies panel with
/// every open SOS and crash and its alarm, live rides, accounts on hold), then
/// the live numbers, the totals from /admin/analytics/overview, the sections
/// and the fleet map. Every number comes from the server (live fleet over the
/// socket, accounts from /admin/users, totals from the analytics endpoint);
/// nothing is estimated. Pull down to refresh; what is on screen stays while
/// it reloads.
class MasterAdminDashboard extends StatefulWidget {
  /// The emergency alarm sound; tests pass a fake.
  final AdminAlarm? alarm;

  const MasterAdminDashboard({super.key, this.alarm});

  /// Riders, staff and accounts on hold from `GET /admin/users`: the server's `counts` (staff
  /// and guests are not riders). An older gateway without `counts` is counted the same way.
  static ({int riders, int staff, int onHold}) userCounts(Object? res) {
    int n(Object? v) => v is num ? v.toInt() : 0;
    final c = res is Map ? res['counts'] : null;
    if (c is Map) return (riders: n(c['riders']), staff: n(c['staff']), onHold: n(c['onHold']));
    final users = adminMapList(res is Map ? res['users'] : null);
    bool guest(Map<String, dynamic> u) =>
        u['provider'] == 'guest' || u['isGuest'] == true || (u['email']?.toString() ?? '').endsWith('@guest.coroute.local');
    return (
      riders: users.where((u) => !AdminUsersScreen.isStaff(u) && !guest(u)).length,
      staff: users.where(AdminUsersScreen.isStaff).length,
      onHold: users.where((u) => AccountStatus.fromCode(u['status']) == AccountStatus.onHold).length,
    );
  }

  @override
  State<MasterAdminDashboard> createState() => _MasterAdminDashboardState();
}

class _MasterAdminDashboardState extends State<MasterAdminDashboard> {
  /// Rider / staff / on-hold counts from /admin/users, null until the first answer.
  ({int riders, int staff, int onHold})? _userCounts;
  bool _loadingUsers = false;
  final GlobalKey<AdminEmergenciesPanelState> _emergencies = GlobalKey<AdminEmergenciesPanelState>();

  /// Totals from /admin/analytics/overview (null until the first answer).
  Map<String, dynamic>? _overview;
  String? _overviewError;
  int _days = 30;
  int _overviewSeq = 0;

  @override
  void initState() {
    super.initState();
    // Live fleet overview is pushed by the gateway (read-only, no audio).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final auth = context.read<AuthService>();
      if (auth.isAuthenticated && !auth.isMasterAdmin) return;
      context.read<ConvoyService>().startAdminFleetWatch();
      _loadUsers();
      _loadOverview();
    });
  }

  /// Loads the totals for the last [_days] days. Only the newest answer counts.
  Future<void> _loadOverview({bool fresh = false}) async {
    final seq = ++_overviewSeq;
    String? error;
    Map<String, dynamic>? data;
    try {
      final res = await context.read<ApiClient>().get('/admin/analytics/overview?days=$_days${fresh ? '&fresh=1' : ''}', timeout: const Duration(seconds: 25));
      if (res is Map && res['riders'] is Map) data = Map<String, dynamic>.from(res);
    } catch (e) {
      error = e is ApiException ? e.message : 'Could not load the totals.';
    }
    if (!mounted || seq != _overviewSeq) return;
    setState(() {
      if (data != null) _overview = data;
      _overviewError = error ?? (data == null ? 'Totals are not available from the server yet.' : null);
    });
  }

  Future<void> _loadUsers() async {
    if (_loadingUsers) return;
    setState(() => _loadingUsers = true);
    try {
      final res = await context.read<ApiClient>().get('/admin/users');
      _userCounts = MasterAdminDashboard.userCounts(res);
    } catch (_) {
      // Offline or busy: the counts that need it stay hidden or keep their last value.
    }
    if (mounted) setState(() => _loadingUsers = false);
  }

  Future<void> _refresh() async {
    context.read<ConvoyService>().startAdminFleetWatch();
    await Future.wait([_loadUsers(), _loadOverview(fresh: true), _emergencies.currentState?.reload() ?? Future<void>.value()]);
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
    final auth = context.watch<AuthService>();
    if (auth.isAuthenticated && !auth.isMasterAdmin) {
      return Scaffold(
        backgroundColor: AppTheme.bg,
        appBar: AppBar(
          backgroundColor: AppTheme.bg,
          title: const Text('Access Denied'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.gavel_rounded, size: 64, color: AppTheme.sos),
                const SizedBox(height: 16),
                Text('Master Admin Access Required', style: AppText.headline),
                const SizedBox(height: 8),
                Text(
                  'Regular riders cannot access the Master Admin Console.',
                  textAlign: TextAlign.center,
                  style: AppText.caption,
                ),
                const SizedBox(height: 24),
                DsButton(
                  label: 'Return to Safety',
                  onPressed: () => Navigator.maybePop(context),
                ),
              ],
            ),
          ),
        ),
      );
    }

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

    final counts = _userCounts;
    final onHold = counts?.onHold;

    // 1. Emergencies: every open SOS and crash, with the alarm while the console is open.
    final sosSection = <Widget>[
      AdminEmergenciesPanel(
        key: _emergencies,
        alarm: widget.alarm ?? const NotifierAdminAlarm(),
        onOpenConvoy: _openConvoy,
      ),
    ];

    // 2. Live rides: a table card, one row per ride, with its spread at the right.
    final ridesSection = <Widget>[
      const SizedBox(height: 20),
      AdminTable(
        title: 'Live rides',
        trailing: convoys.isEmpty
            ? null
            : Text(
                '${convoys.length} riding now',
                style: AppText.caption.copyWith(color: AppTheme.accentText, fontWeight: FontWeight.w700),
              ),
        rows: [
          if (convoys.isEmpty)
            AdminRow(
              leading: const AdminRowIcon(Icons.two_wheeler_rounded),
              title: 'No live rides right now',
              subtitle: 'Finished rides are in Rides.',
              divider: false,
              onTap: () => _push(const AdminRideHistoryScreen()),
            )
          else
            for (var i = 0; i < convoys.length; i++)
              _ConvoyRow(
                key: ValueKey(convoys[i].groupId),
                convoy: convoys[i],
                sosCount: sos.where((s) => s.$1.groupId == convoys[i].groupId).length,
                last: i == convoys.length - 1,
                onTap: () => _openConvoy(convoys[i]),
              ),
        ],
      ),
    ];

    // 3. Accounts on hold.
    final holdSection = <Widget>[
      if (onHold != null && onHold > 0)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: RideAlert(
            tier: AlertTier.important,
            title: onHold == 1 ? '1 account on hold' : '$onHold accounts on hold',
            message: 'They cannot sign in until you release the hold.',
            actionLabel: 'Review',
            onAction: () => _push(const AdminUsersScreen(initialFilter: AdminUserFilter.onHold)),
          ),
        ),
    ];

    // 4. Numbers: the KPI tiles of the canvas.
    final kpis = <Widget>[
      AdminKpiTile(
        label: 'Live rides',
        value: '${convoys.length}',
        delta: convoys.isEmpty ? 'Nobody out riding' : (sosGroups.isEmpty ? 'All clear' : '${sosGroups.length} with an open SOS'),
        deltaColor: sosGroups.isEmpty ? null : AppTheme.sos,
      ),
      AdminKpiTile(
        label: 'Riders online',
        value: '$totalRiders',
        delta: convoys.isEmpty ? 'In live rides' : 'Across ${convoys.length} ${convoys.length == 1 ? 'ride' : 'rides'}',
      ),
      AdminKpiTile(
        label: 'Open SOS',
        value: '${sos.length}',
        valueColor: sos.isEmpty ? null : AppTheme.sos,
        delta: sos.isEmpty ? 'None open' : 'Needs attention',
        deltaColor: sos.isEmpty ? null : AppTheme.sos,
      ),
      if (counts != null)
        AdminKpiTile(
          label: 'Riders (excl. staff)',
          value: '${counts.riders}',
          delta: (onHold ?? 0) > 0 ? '$onHold on hold' : (counts.staff > 0 ? '${counts.staff} staff not counted' : 'All in good standing'),
          deltaColor: (onHold ?? 0) > 0 ? AppTheme.warnText : null,
        ),
    ];
    final stats = <Widget>[
      const AdminSectionLabel('Overview'),
      AdminKpiGrid(tiles: kpis),
    ];

    // 5. Totals from the server for the chosen period.
    final ov = _overview;
    Map<String, dynamic> part(String k) => ov != null && ov[k] is Map ? Map<String, dynamic>.from(ov[k] as Map) : <String, dynamic>{};
    final riders = part('riders');
    final rides = part('rides');
    final safety = part('safety');
    final pay = part('payments');
    final response = adminNumOrNull(safety['medianResponseSec']);
    final totals = <Widget>[
      AdminSectionLabel(
        'Totals',
        trailing: AdminFilterButton<int>(
          value: _days,
          label: 'Last $_days days',
          options: const [(7, 'Last 7 days'), (30, 'Last 30 days'), (90, 'Last 90 days'), (365, 'Last year')],
          onSelected: (d) {
            setState(() => _days = d);
            _loadOverview();
          },
        ),
      ),
      if (ov == null)
        AdminCard(
          child: Text(
            _overviewError ?? 'Loading totals...',
            style: AppText.body.copyWith(color: _overviewError == null ? AppTheme.text2 : AppTheme.sos),
          ),
        )
      else ...[
        AdminKpiGrid(tiles: [
          AdminKpiTile(label: 'Riders', value: adminCount(riders['total']), delta: '${adminCount(riders['newInPeriod'])} new, excl. staff'),
          AdminKpiTile(label: 'Active 7 days', value: adminCount(riders['active7d']), delta: '${adminCount(riders['active30d'])} in 30 days'),
          AdminKpiTile(label: 'Rides finished', value: adminCount(rides['groupsInPeriod']), delta: '${adminCount(rides['groupsCompleted'])} all time'),
          AdminKpiTile(label: 'Rider trips', value: adminCount(rides['tripsInPeriod']), delta: '${adminCount(rides['completedTrips'])} all time'),
          AdminKpiTile(label: 'Km ridden', value: adminCount(rides['kmInPeriod']), delta: '${adminCount(rides['kmRidden'])} all time'),
          AdminKpiTile(label: 'Avg group', value: adminCount(rides['avgGroupSize']), delta: 'Riders per ride'),
          AdminKpiTile(
            label: 'SOS',
            value: adminCount(safety['sosInPeriod']),
            delta: '${adminCount(safety['resolved'])} resolved, ${adminCount(safety['falseAlarms'])} false',
          ),
          AdminKpiTile(
            label: 'SOS answered',
            value: response == null ? '—' : formatDuration(Duration(seconds: response.round())),
            delta: 'Median first response',
          ),
          AdminKpiTile(label: 'Paying riders', value: adminCount(riders['paying']), delta: '${adminCount(riders['conversionPct'])}% of riders'),
          AdminKpiTile(label: 'Revenue', value: adminInr(adminNum(pay, 'revenueInPeriodInr')), delta: '${adminInr(adminNum(pay, 'revenueInr'))} all time'),
        ]),
        if (ov['truncated'] == true)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: StatusLine(icon: Icons.info_outline_rounded, text: 'Some totals stop at the scan limit and may be higher.', color: AppTheme.warnText),
          ),
      ],
    ];

    // 6. Every section of the console, one tap away.
    final sectionsSection = <Widget>[
      const AdminSectionLabel('Sections'),
      AdminTable(
        rows: [
          AdminRow(
            leading: const AdminRowIcon(Icons.people_alt_outlined),
            title: 'Riders',
            subtitle: 'Accounts, riding numbers, plan, role and limits',
            onTap: () => _push(const AdminUsersScreen()),
          ),
          AdminRow(
            leading: const AdminRowIcon(Icons.alt_route_rounded),
            title: 'Rides',
            subtitle: 'Live and finished rides, with each ride\'s numbers',
            onTap: () => _push(const AdminRideHistoryScreen()),
          ),
          AdminRow(
            leading: AdminRowIcon(Icons.sos_rounded, color: sos.isEmpty ? null : AppTheme.sos),
            title: 'Safety',
            subtitle: 'Emergencies, false alarms, public ride reports',
            onTap: () => _push(const AdminSafetyScreen()),
          ),
          AdminRow(
            leading: const AdminRowIcon(Icons.payments_outlined),
            title: 'Payments',
            subtitle: 'Payments, revenue, plans and coupons',
            onTap: () => _push(const AdminPlansPricingScreen()),
          ),
          AdminRow(
            leading: const AdminRowIcon(Icons.rate_review_outlined),
            title: 'Reviews',
            subtitle: 'Rider reviews waiting for a decision',
            onTap: () => _push(const AdminReviewsScreen()),
          ),
          AdminRow(
            leading: const AdminRowIcon(Icons.insights_rounded),
            title: 'Insights',
            subtitle: 'Feedback, website visits, app versions, phones',
            onTap: () => _push(const AdminInsightsScreen()),
          ),
          AdminRow(
            leading: const AdminRowIcon(Icons.settings_outlined),
            title: 'Settings',
            subtitle: 'Website, payment gateway, audit log',
            onTap: () => _push(const AdminSettingsScreen()),
            divider: false,
          ),
        ],
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
        SizedBox(height: 280, child: _fleetMap(convoys, points, now)),
      ],
    ];

    return AdminShell(
      title: 'Admin',
      subtitle: 'Live status and totals',
      actions: [
        AdminIconAction(icon: Icons.campaign_rounded, label: 'Safety broadcast', onTap: () => _showBroadcastSheet(convoyService)),
        AdminIconAction(icon: Icons.refresh_rounded, label: 'Refresh', onTap: _refresh),
      ],
      // The badge is the open SOS count of the live fleet.
      nav: adminNavItems(context, AdminSection.dashboard, emergencies: sos.length, onSignOut: _signOut),
      railFooter: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Live fleet', style: AppText.caption.copyWith(color: AppTheme.text, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            convoys.isEmpty ? 'No rides in progress' : '${convoys.length} ${convoys.length == 1 ? 'ride' : 'rides'} · $totalRiders riders online',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: AppTheme.accentText),
          ),
        ],
      ),
      body: LoadingState(
        loading: _loadingUsers,
        child: adminRefresh(
          onRefresh: _refresh,
          child: LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth >= adminWideBreakpoint;
            final Widget body;
            if (wide) {
              // Canvas order: numbers on top, then configuration beside operations and map.
              body = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...stats,
                  ...totals,
                  const SizedBox(height: 16),
                  AdminTwoUp(
                    left: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [...holdSection, ...sectionsSection],
                    ),
                    right: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ...sosSection,
                        ...ridesSection,
                        if (mapSection.isNotEmpty) ...mapSection,
                      ],
                    ),
                  ),
                ],
              );
            } else {
              // Phone: SOS emergencies (if any), live rides, holds, live numbers, totals, sections, map.
              body = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...sosSection,
                  ...ridesSection,
                  ...holdSection,
                  const SizedBox(height: 16),
                  ...stats,
                  ...totals,
                  ...sectionsSection,
                  const SizedBox(height: 16),
                  ...mapSection,
                ],
              );
            }
            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: AdminContent(wide: wide, child: body),
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
    return DsCard(
      padding: EdgeInsets.zero,
      child: FlutterMap(
        // A new fleet (rides started or ended) fits the camera again.
        key: ValueKey(convoys.map((c) => c.groupId).join(',')),
        options: MapOptions(
          minZoom: 3.0,
          maxZoom: 19.0,
          cameraConstraint: const CameraConstraint.containLatitude(),
          initialCenter: _fleetCenter(points),
          initialZoom: 12,
          initialCameraFit: points.length > 1
              ? CameraFit.coordinates(coordinates: points, padding: const EdgeInsets.all(32), maxZoom: 14)
              : null,
        ),
        children: [
          appTileLayer(),
          MarkerLayer(markers: markers),
        ],
      ),
    );
  }
}

/// One live ride row: name, code and lead, riders and destination, an
/// "Emergency" chip when someone in it has an open SOS, and the spread of
/// the group at the right (teal, amber from 3 km, red from 6 km).
class _ConvoyRow extends StatelessWidget {
  final ConvoyModel convoy;
  final int sosCount;
  final bool last;
  final VoidCallback onTap;

  const _ConvoyRow({super.key, required this.convoy, required this.sosCount, required this.onTap, this.last = false});

  @override
  Widget build(BuildContext context) {
    final c = convoy;
    final n = c.riders.length;
    final dest = c.destinationName.trim();
    final located = c.riders.values.where((r) => r.lat != 0 || r.lng != 0).toList();
    final metrics = TelemetryUtils.calculateConvoyMetrics(located);
    final spreadColor = metrics.spreadKm >= 6
        ? AppTheme.sos
        : metrics.spreadKm >= 3
            ? AppTheme.warnText
            : AppTheme.accentText;
    return AdminRow(
      leading: AdminRowIcon(Icons.two_wheeler_rounded, color: sosCount > 0 ? AppTheme.sos : null),
      title: c.name.isEmpty ? 'Ride' : c.name,
      subtitle: [
        if (c.joinCode.isNotEmpty) 'Code ${c.joinCode}',
        if (c.createdByUserName.isNotEmpty) 'lead ${c.createdByUserName}',
      ].join(', '),
      detail: '$n ${n == 1 ? 'rider' : 'riders'}, ${dest.isEmpty ? 'no destination set' : 'to $dest'}',
      status: sosCount > 0 ? RiderStatusChip(status: RiderStatus.emergency, detail: sosCount == 1 ? '1 SOS' : '$sosCount SOS') : null,
      trailing: located.length < 2
          ? null
          : Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(formatDistance(metrics.spreadKm * 1000), style: AppText.label.copyWith(color: spreadColor, fontWeight: FontWeight.w800)),
                  Text('spread', style: AppText.caption.copyWith(fontWeight: FontWeight.w700)),
                ],
              ),
            ),
      divider: !last,
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
      physics: const BouncingScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Every rider in a live ride sees this alert on their map right away.',
            style: AppText.body.copyWith(color: AppTheme.text2),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            maxLength: 300,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            style: AppText.body,
            decoration: InputDecoration(
              labelText: 'Message',
              hintText: 'Heavy rain on NH 48. Reduce speed and regroup.',
              filled: true,
              fillColor: AppTheme.card,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: AppTheme.border, width: 2)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: AppTheme.border, width: 2)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: AppTheme.accentText, width: 2)),
            ),
          ),
          const SizedBox(height: 8),
          DsButton(
            label: 'Send to all live rides',
            icon: Icons.campaign_rounded,
            onPressed: ready ? _send : null,
          ),
        ],
      ),
    );
  }
}
