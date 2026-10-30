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
import 'admin_plans_pricing_screen.dart';
import 'admin_ride_history_screen.dart';
import 'admin_ui.dart';
import 'admin_users_screen.dart';
import '../subscription/plan_selector_screen.dart';

/// The sections of the admin console nav (rail on wide screens, chip row on phones).
enum AdminSection { dashboard, users, plans, rides, insights }

/// The nav items for an admin screen that shows [current]. From the
/// dashboard a section is pushed; from another section it replaces that
/// section, so "Dashboard" is always one pop away.
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

  return [
    AdminNavItem(
      icon: Icons.space_dashboard_outlined,
      label: 'Dashboard',
      selected: current == AdminSection.dashboard,
      badge: emergencies,
      onTap: current == AdminSection.dashboard ? null : () => Navigator.maybePop(context),
    ),
    AdminNavItem(
      icon: Icons.people_alt_outlined,
      label: 'Users',
      selected: current == AdminSection.users,
      onTap: () => go(AdminSection.users, () => const AdminUsersScreen()),
    ),
    AdminNavItem(
      icon: Icons.payments_outlined,
      label: 'Payments & Plans',
      selected: current == AdminSection.plans,
      onTap: () => go(AdminSection.plans, () => const AdminPlansPricingScreen()),
    ),
    AdminNavItem(
      icon: Icons.history_rounded,
      label: 'Ride history',
      selected: current == AdminSection.rides,
      onTap: () => go(AdminSection.rides, () => const AdminRideHistoryScreen()),
    ),
    AdminNavItem(
      icon: Icons.insights_rounded,
      label: 'Insights',
      selected: current == AdminSection.insights,
      onTap: () => go(AdminSection.insights, () => const AdminInsightsScreen()),
    ),
    if (onSignOut != null) AdminNavItem(icon: Icons.logout_rounded, label: 'Sign out', danger: true, onTap: onSignOut),
  ];
}

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
              subtitle: 'Finished rides are in Ride history.',
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
      if (users != null)
        AdminKpiTile(
          label: 'Accounts',
          value: '${users.length}',
          delta: (onHold ?? 0) > 0 ? '$onHold on hold' : 'All in good standing',
          deltaColor: (onHold ?? 0) > 0 ? AppTheme.warnText : null,
        ),
    ];
    final stats = <Widget>[
      const AdminSectionLabel('Overview'),
      AdminKpiGrid(tiles: kpis),
    ];

    final statusCard = DsCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: AppTheme.accentText,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppTheme.accentText.withValues(alpha: 0.5),
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'OPERATIONS & CONFIGURATION CLUSTER',
                  style: AppText.overline.copyWith(color: AppTheme.accentText, letterSpacing: 1.1),
                ),
                const SizedBox(height: 1),
                Text(
                  'Dual Oracle Nodes Active · Live Razorpay Gateway · coroute.duckdns.org',
                  style: AppText.caption.copyWith(color: AppTheme.text2),
                ),
              ],
            ),
          ),
          DsRoundButton(
            icon: Icons.refresh_rounded,
            label: 'Refresh',
            onTap: _refresh,
          ),
        ],
      ),
    );

    final configModulesSection = <Widget>[
      const AdminSectionLabel('Configuration & Operations Modules'),
      _AdminConfigModuleCard(
        icon: Icons.payments_rounded,
        title: 'Subscription Plans & Tier Pricing',
        subtitle: 'Configure dynamic monthly & annual INR amounts for Community, Pro, Captain & Tour Operator tiers. Instant sync to web and apps.',
        badge: 'LIVE PRICING',
        badgeColor: AppTheme.accentText,
        actionLabel: 'Configure Plans',
        onTap: () => _push(const AdminPlansPricingScreen(initialTab: AdminPaymentsTab.pricing)),
      ),
      const SizedBox(height: 12),
      _AdminConfigModuleCard(
        icon: Icons.account_balance_wallet_rounded,
        title: 'Payment Gateway Engine (Razorpay)',
        subtitle: 'Switch between TEST (sandbox) and LIVE PRODUCTION modes, verify API key credentials, and test live webhook callbacks.',
        badge: 'GATEWAY CONTROL',
        badgeColor: AppTheme.brand,
        actionLabel: 'Manage Gateway',
        onTap: () => _push(const AdminPlansPricingScreen(initialTab: AdminPaymentsTab.gateway)),
      ),
      const SizedBox(height: 12),
      _AdminConfigModuleCard(
        icon: Icons.discount_rounded,
        title: 'Promotional Coupons & Discounts',
        subtitle: 'Manage promo discount codes (WELCOME50, CAPTAIN100, RIDERFREE), toggle active status, and define custom promotions.',
        badge: 'PROMOTIONS',
        badgeColor: AppTheme.brand,
        actionLabel: 'Manage Coupons',
        onTap: () => _push(const AdminPlansPricingScreen(initialTab: AdminPaymentsTab.coupons)),
      ),
      const SizedBox(height: 12),
      _AdminConfigModuleCard(
        icon: Icons.people_alt_rounded,
        title: 'Users & Entitlements Directory',
        subtitle: 'Browse all accounts, inspect active plans, review subscription history, toggle account holds, and grant/revoke manual access.',
        badge: 'ACCOUNTS',
        badgeColor: AppTheme.accentText,
        actionLabel: 'Manage Users',
        onTap: () => _push(const AdminUsersScreen()),
      ),
      const SizedBox(height: 12),
      _AdminConfigModuleCard(
        icon: Icons.alt_route_rounded,
        title: 'Ride Operations & Convoy History',
        subtitle: 'Review finished rides, rider GPS trails, distance spreads, speed distributions, and emergency incident chronologies.',
        badge: 'OPERATIONS',
        badgeColor: AppTheme.accentText,
        actionLabel: 'Ride History',
        onTap: () => _push(const AdminRideHistoryScreen()),
      ),
      const SizedBox(height: 12),
      _AdminConfigModuleCard(
        icon: Icons.insights_rounded,
        title: 'System Insights & Telemetry',
        subtitle: 'Active mobile client versions, battery & GPS accuracy distributions, feature flags analytics, and error diagnostics.',
        badge: 'TELEMETRY',
        badgeColor: AppTheme.brand,
        actionLabel: 'System Insights',
        onTap: () => _push(const AdminInsightsScreen()),
      ),
      const SizedBox(height: 12),
      _AdminConfigModuleCard(
        icon: Icons.two_wheeler_rounded,
        title: 'Rider View & Checkout Simulator',
        subtitle: 'Experience the rider-facing membership selector, review entitlements, test coupon redemptions, and inspect native Razorpay sheets.',
        badge: 'SIMULATOR',
        badgeColor: AppTheme.accentText,
        actionLabel: 'Preview Rider View',
        onTap: () => _push(const PlanSelectorScreen()),
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
      subtitle: 'Operations & Configuration Console',
      actions: [
        AdminIconAction(
          icon: Icons.payments_outlined,
          label: 'Payments & Plans',
          onTap: () => _push(const AdminPlansPricingScreen()),
        ),
        AdminIconAction(
          icon: Icons.two_wheeler_rounded,
          label: 'Rider View',
          onTap: () => _push(const PlanSelectorScreen()),
        ),
        AdminIconAction(icon: Icons.campaign_rounded, label: 'Safety broadcast', onTap: () => _showBroadcastSheet(convoyService)),
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
                  statusCard,
                  const SizedBox(height: 16),
                  ...stats,
                  const SizedBox(height: 16),
                  AdminTwoUp(
                    left: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [...configModulesSection, ...holdSection],
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
              // Phone: status bar, SOS emergencies (if any), stats, config modules, rides, and map.
              body = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  statusCard,
                  const SizedBox(height: 16),
                  ...sosSection,
                  ...ridesSection,
                  ...holdSection,
                  const SizedBox(height: 16),
                  ...stats,
                  const SizedBox(height: 20),
                  ...configModulesSection,
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

/// A rich dashboard configuration module card representing a core system area
/// (e.g. Plan Pricing, Payment Gateway, Promo Coupons, Users, Telemetry).
class _AdminConfigModuleCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? badge;
  final Color? badgeColor;
  final String actionLabel;
  final VoidCallback onTap;

  const _AdminConfigModuleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.badge,
    this.badgeColor,
    required this.actionLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return DsCard(
      padding: const EdgeInsets.all(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppTheme.tint,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Icon(icon, color: AppTheme.accentText, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: AppText.title.copyWith(fontSize: 16)),
                      if (badge != null) ...[
                        const SizedBox(height: 2),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: (badgeColor ?? AppTheme.brand).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            badge!.toUpperCase(),
                            style: TextStyle(
                              color: badgeColor ?? AppTheme.accentText,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_ios_rounded, color: AppTheme.muted, size: 14),
              ],
            ),
            const SizedBox(height: 10),
            Text(subtitle, style: AppText.body.copyWith(fontSize: 13, color: AppTheme.text2)),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      actionLabel,
                      style: TextStyle(color: AppTheme.accentText, fontSize: 13, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right_rounded, color: AppTheme.accentText, size: 18),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
