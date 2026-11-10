import 'dart:async';

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
import '../../domain/analytics/chart_math.dart';
import '../auth/access_gate_screen.dart';
import '../ride/riders_ladder.dart';
import '../timeline/member_colors.dart';
import 'admin_convoy_inspector.dart';
import 'admin_emergencies_panel.dart';
import 'admin_nav.dart';
import 'admin_payments_logic.dart';
import 'admin_rider_insights.dart' show adminCount;
import 'admin_ride_history_screen.dart';
import 'admin_ui.dart';
import 'admin_users_screen.dart';
import 'charts/charts.dart';
import '../rider/widgets/bike_rider_marker.dart';
import '../../domain/ride/bike_markers.dart';
import '../widgets/feature_switch.dart';

export 'admin_nav.dart';

/// The periods of the Overview.
const List<int> adminOverviewPeriods = [7, 30, 90];

/// The admin console home (Overview): calm and short. Any open emergency first
/// (the Emergencies panel with its alarm), then four numbers with a trend
/// (active today, rides, km, open SOS), two charts (rides per day, active
/// riders against the period before), the plan mix, what needs attention with
/// one-tap actions, the live rides and the fleet map. Every number comes from
/// the server (`/admin/analytics/trends`, `/admin/users`, the live fleet);
/// nothing is estimated. Refreshes itself every minute while it is on screen
/// and the app is open; pull down to refresh by hand.
class MasterAdminDashboard extends StatefulWidget {
  /// The emergency alarm sound; tests pass a fake.
  final AdminAlarm? alarm;

  /// How often the Overview refreshes itself while visible.
  final Duration autoRefresh;

  const MasterAdminDashboard({super.key, this.alarm, this.autoRefresh = const Duration(seconds: 60)});

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

/// The parsed answer of `GET /admin/analytics/trends`.
class AdminTrends {
  final int days;
  final List<String> labels;
  final Map<String, List<num>> series;
  final Map<String, List<num>> previous;
  final int activeToday;
  final int activeYesterday;
  final List<({String id, int count})> plans;
  final Map<String, int?> attention;

  const AdminTrends({
    required this.days,
    required this.labels,
    required this.series,
    required this.previous,
    required this.activeToday,
    required this.activeYesterday,
    required this.plans,
    required this.attention,
  });

  static AdminTrends? fromJson(Object? res) {
    if (res is! Map || res['series'] is! Map) return null;
    List<num> nums(Object? v) => v is List ? [for (final x in v) x is num ? x : 0] : const [];
    Map<String, List<num>> part(Object? m) => m is Map ? {for (final e in m.entries) e.key.toString(): nums(e.value)} : {};
    int n(Object? v) => v is num ? v.toInt() : 0;
    final riders = res['riders'] is Map ? res['riders'] as Map : const {};
    final att = res['attention'] is Map ? res['attention'] as Map : const {};
    return AdminTrends(
      days: n(res['days']),
      labels: res['labels'] is List ? [for (final l in res['labels'] as List) l.toString()] : const [],
      series: part(res['series']),
      previous: part(res['previous']),
      activeToday: n(riders['activeToday']),
      activeYesterday: n(riders['activeYesterday']),
      plans: [
        for (final p in adminMapList(res['plans']))
          if (p['id'] != null) (id: p['id'].toString(), count: n(p['count'])),
      ],
      attention: {for (final e in att.entries) e.key.toString(): e.value is num ? (e.value as num).toInt() : null},
    );
  }

  List<num> s(String k) => series[k] ?? const [];
  List<num> p(String k) => previous[k] ?? const [];
}

/// A plan id in plain words.
String adminPlanLabel(String id) {
  switch (id) {
    case 'community':
      return 'Community (free)';
    case 'group_small':
      return 'Small group';
    case 'group_large':
      return 'Large group';
    default:
      return adminCapitalize(id.replaceAll('_', ' '));
  }
}

class _MasterAdminDashboardState extends State<MasterAdminDashboard> {
  /// Rider / staff / on-hold counts from /admin/users, null until the first answer.
  ({int riders, int staff, int onHold})? _userCounts;
  bool _loadingUsers = false;
  final GlobalKey<AdminEmergenciesPanelState> _emergencies = GlobalKey<AdminEmergenciesPanelState>();

  /// Daily series from /admin/analytics/trends (null until the first answer).
  AdminTrends? _trends;
  String? _trendsError;
  int _trendsSeq = 0;

  /// Totals from /admin/analytics/overview, shown under "More numbers".
  Map<String, dynamic>? _overview;
  int _overviewSeq = 0;
  bool _moreOpen = false;

  int _days = 30;
  Timer? _timer;
  late final AppLifecycleListener _life;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(onStateChange: (s) {
      final fg = s == AppLifecycleState.resumed;
      if (fg == _foreground) return;
      _foreground = fg;
      // Back in front after a while: catch up at once.
      if (fg && mounted) _refresh(auto: true);
    });
    // Live fleet overview is pushed by the gateway (read-only, no audio).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final auth = context.read<AuthService>();
      if (auth.isAuthenticated && !auth.isMasterAdmin) return;
      context.read<ConvoyService>().startAdminFleetWatch();
      _loadUsers();
      _loadTrends();
      _loadOverview();
      _timer = Timer.periodic(widget.autoRefresh, (_) => _tick());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _life.dispose();
    super.dispose();
  }

  /// One auto-refresh: only while the app is open and the Overview is the screen on top.
  void _tick() {
    if (!mounted || !_foreground) return;
    if (ModalRoute.of(context)?.isCurrent == false) return;
    _refresh(auto: true);
  }

  int get _tzMin => DateTime.now().timeZoneOffset.inMinutes;

  /// Loads the charts for the last [_days] days. Only the newest answer counts.
  Future<void> _loadTrends({bool fresh = false}) async {
    final seq = ++_trendsSeq;
    AdminTrends? data;
    String? error;
    try {
      final res = await context.read<ApiClient>().get('/admin/analytics/trends?days=$_days&tz=$_tzMin${fresh ? '&fresh=1' : ''}', timeout: const Duration(seconds: 25));
      data = AdminTrends.fromJson(res);
    } catch (e) {
      error = e is ApiException ? e.message : 'Could not load the charts.';
    }
    if (!mounted || seq != _trendsSeq) return;
    setState(() {
      if (data != null) _trends = data;
      _trendsError = error ?? (data == null ? 'Charts are not available from the server yet.' : null);
    });
  }

  Future<void> _loadOverview({bool fresh = false}) async {
    final seq = ++_overviewSeq;
    Map<String, dynamic>? data;
    try {
      final res = await context.read<ApiClient>().get('/admin/analytics/overview?days=$_days${fresh ? '&fresh=1' : ''}', timeout: const Duration(seconds: 25));
      if (res is Map && res['riders'] is Map) data = Map<String, dynamic>.from(res);
    } catch (_) {
      // "More numbers" keeps its last answer.
    }
    if (!mounted || seq != _overviewSeq) return;
    if (data != null) setState(() => _overview = data);
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

  /// Reloads everything; what is on screen stays while it loads. The minute timer uses the
  /// server's short cache ([auto]); a pull or the Refresh button asks for fresh numbers.
  Future<void> _refresh({bool auto = false}) async {
    if (!auto) context.read<ConvoyService>().startAdminFleetWatch();
    await Future.wait([
      _loadUsers(),
      _loadTrends(fresh: !auto),
      _loadOverview(fresh: !auto),
      _emergencies.currentState?.reload() ?? Future<void>.value(),
    ]);
  }

  void _setDays(int d) {
    if (d == _days) return;
    setState(() => _days = d);
    _loadTrends();
    _loadOverview();
  }

  void _push(Widget screen) => Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

  void _open(AdminPage page) => adminGo(context, AdminPage.overview, page);

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
          title: const Text('Access denied'),
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

    final tr = _trends;
    final loading = tr == null && _trendsError == null;
    final period = 'last $_days days';
    final onHold = tr?.attention['onHold'] ?? _userCounts?.onHold;
    final openSos = [sos.length, tr?.attention['openSos'] ?? 0].reduce((a, b) => a > b ? a : b);

    // 1. Emergencies: every open SOS and crash, with the alarm while the console is open.
    final sosSection = AdminEmergenciesPanel(
      key: _emergencies,
      alarm: widget.alarm ?? const NotifierAdminAlarm(),
      onOpenConvoy: _openConvoy,
    );

    // 2. Four numbers with a trend.
    final rides = tr?.s('rides') ?? const <num>[];
    final km = tr?.s('km') ?? const <num>[];
    final active = tr?.s('activeRiders') ?? const <num>[];
    final compare = 'previous $_days days';
    final kpis = AdminKpiGrid(
      minTileWidth: 150,
      tiles: [
        AdminTrendTile(
          label: 'Active today',
          value: compactNumber(tr?.activeToday ?? 0),
          current: tr?.activeToday ?? 0,
          previous: tr?.activeYesterday,
          compareText: 'day before',
          spark: active,
          loading: loading,
        ),
        AdminTrendTile(
          label: 'Rides',
          value: compactNumber(sumOf(rides)),
          current: sumOf(rides),
          previous: tr == null ? null : sumOf(tr.p('rides')),
          compareText: compare,
          spark: rides,
          loading: loading,
        ),
        AdminTrendTile(
          label: 'Km ridden',
          value: compactNumber(sumOf(km)),
          current: sumOf(km),
          previous: tr == null ? null : sumOf(tr.p('km')),
          compareText: compare,
          spark: km,
          loading: loading,
        ),
        AdminTrendTile(
          label: 'Open SOS',
          value: '$openSos',
          current: openSos,
          note: openSos > 0 ? 'Needs attention' : 'All clear',
          spark: tr?.s('sos') ?? const [],
          upIsGood: false,
          valueColor: openSos > 0 ? AppTheme.palette.danger : null,
          sparkColor: AppTheme.palette.textFaint,
        ),
      ],
    );

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(2, 18, 0, 12),
      child: Row(
        children: [
          Expanded(child: Semantics(header: true, child: Text('Overview', style: AppText.title))),
          const _InfoDot(
            message: 'Active today: riders who opened the app today.\n'
                'Rides: group rides finished. Km: distance riders recorded.\n'
                'Arrows compare with the period before. Staff accounts are never counted.',
          ),
          const SizedBox(width: 8),
          _PeriodSelector(value: _days, onChanged: _setDays),
        ],
      ),
    );

    // 3. Charts. 90 days are shown per week so the bars stay readable.
    final weekly = _days > 30;
    final labels = tr?.labels ?? const <String>[];
    final barValues = weekly ? rollup(rides, 7) : rides;
    final barLabels = weekly ? [for (var i = labels.length % 7 == 0 ? 0 : labels.length % 7 - 7; i < labels.length; i += 7) labels[i < 0 ? 0 : i]] : labels;
    final ridesChart = AdminTitledCard(
      title: weekly ? 'Rides per week' : 'Rides per day',
      child: AdminBarChart(
        values: barValues,
        labels: barLabels,
        title: weekly ? 'Rides per week' : 'Rides per day',
        period: period,
        unit: 'rides',
        emptyText: 'No rides yet',
        loading: loading,
      ),
    );
    final activeChart = AdminTitledCard(
      title: 'Active riders',
      trailing: const _Legend(),
      child: AdminLineChart(
        values: active,
        previous: tr?.p('activeRiders'),
        labels: labels,
        title: 'Riders who rode, per day',
        period: period,
        unit: 'riders',
        emptyText: 'No riders out yet',
        loading: loading,
      ),
    );
    final plans = tr?.plans ?? const <({String id, int count})>[];
    final plansCard = AdminTitledCard(
      title: 'Plans',
      child: AdminHorizontalBars(
        title: 'Riders per plan',
        loading: loading,
        emptyText: 'No riders yet',
        items: [for (final p in plans) HBarItem(adminPlanLabel(p.id), p.count, highlight: p.id != 'community')],
      ),
    );
    final chartsError = _trendsError != null && tr == null
        ? Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: AdminCard(
              child: Row(
                children: [
                  Expanded(child: StatusLine(icon: Icons.cloud_off_rounded, text: _trendsError!, color: AppTheme.palette.danger)),
                  TextButton(onPressed: () => _loadTrends(fresh: true), child: const Text('Try again')),
                ],
              ),
            ),
          )
        : null;

    // 4. Needs attention, with one tap to act.
    int? att(String k) => tr?.attention[k];
    final attention = <_Attention>[
      if (openSos > 0)
        _Attention(Icons.sos_rounded, openSos == 1 ? '1 open emergency' : '$openSos open emergencies', 'View', AppTheme.palette.danger, () => _open(AdminPage.safety)),
      if ((att('reportsOpen') ?? 0) > 0)
        _Attention(Icons.flag_outlined, _plural(att('reportsOpen')!, 'ride report', 'ride reports', ' to check'), 'Check', AppTheme.palette.warning, () => _open(AdminPage.safety)),
      if ((att('reviewsPending') ?? 0) > 0)
        _Attention(Icons.rate_review_outlined, _plural(att('reviewsPending')!, 'review', 'reviews', ' waiting'), 'Approve', AppTheme.palette.primary, () => _open(AdminPage.reviews)),
      if ((att('photosPending') ?? 0) > 0)
        _Attention(Icons.photo_outlined, _plural(att('photosPending')!, 'photo', 'photos', ' to check'), 'Check', AppTheme.palette.primary, () => _open(AdminPage.places)),
      if ((onHold ?? 0) > 0)
        _Attention(Icons.pause_circle_outline_rounded, onHold == 1 ? '1 account on hold' : '$onHold accounts on hold', 'Review', AppTheme.palette.warning,
            () => _push(const AdminUsersScreen(initialFilter: AdminUserFilter.onHold))),
    ];
    final attentionCard = AdminTitledCard(
      title: 'Needs attention',
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (attention.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  AdminRowIcon(Icons.check_circle_outline_rounded, color: AppTheme.palette.success),
                  const SizedBox(width: 12),
                  Expanded(child: Text('All clear', style: AppText.body)),
                ],
              ),
            )
          else
            for (var i = 0; i < attention.length; i++) _AttentionRow(item: attention[i], divider: i < attention.length - 1),
        ],
      ),
    );

    // 5. Live rides: one compact row per ride, its spread at the right.
    final ridesSection = AdminTable(
      title: 'Live rides',
      trailing: convoys.isEmpty
          ? null
          : Text('${convoys.length} out · $totalRiders riders', style: AppText.label.copyWith(color: AppTheme.accentText)),
      rows: [
        if (convoys.isEmpty)
          AdminRow(
            leading: const AdminRowIcon(Icons.two_wheeler_rounded),
            title: 'No live rides right now',
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
    );

    // Fleet map, only when someone is out riding.
    final points = <LatLng>[
      for (final c in convoys)
        for (final r in c.riders.values)
          if (r.lat != 0.0 || r.lng != 0.0) LatLng(r.lat, r.lng),
    ];
    final map = points.isEmpty ? null : SizedBox(height: 280, child: _fleetMap(convoys, points, now));

    // 6. Everything else from the server, folded away.
    final more = _MoreNumbers(overview: _overview, days: _days, open: _moreOpen, onToggle: () => setState(() => _moreOpen = !_moreOpen));

    const gap = SizedBox(height: 16);
    return AdminShell(
      title: 'Admin',
      subtitle: convoys.isEmpty ? 'No live rides' : '${convoys.length} live ${convoys.length == 1 ? 'ride' : 'rides'}',
      actions: [
        AdminIconAction(icon: Icons.campaign_rounded, label: 'Safety broadcast', onTap: () => _showBroadcastSheet(convoyService)),
        AdminIconAction(icon: Icons.refresh_rounded, label: 'Refresh', onTap: _refresh),
      ],
      // The badge is the open SOS count of the live fleet.
      nav: adminNavItems(context, AdminPage.overview, emergencies: sos.length, onSignOut: _signOut),
      railFooter: Row(
        children: [
          Icon(Icons.circle, size: 8, color: convoys.isEmpty ? AppTheme.palette.textFaint : AppTheme.palette.success),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              convoys.isEmpty ? 'No rides out' : '$totalRiders riding now',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.label.copyWith(color: AppTheme.text),
            ),
          ),
        ],
      ),
      body: adminRefresh(
        onRefresh: _refresh,
        child: LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= adminWideBreakpoint;
          final Widget body;
          if (wide) {
            body = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                sosSection,
                header,
                ?chartsError,
                kpis,
                gap,
                AdminTwoUp(left: ridesChart, right: activeChart),
                gap,
                AdminTwoUp(left: attentionCard, right: plansCard),
                gap,
                if (map != null) AdminTwoUp(left: ridesSection, right: map) else ridesSection,
                gap,
                more,
              ],
            );
          } else {
            body = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                sosSection,
                header,
                ?chartsError,
                kpis,
                gap,
                ridesChart,
                gap,
                activeChart,
                gap,
                attentionCard,
                gap,
                plansCard,
                gap,
                ridesSection,
                if (map != null) ...[gap, map],
                gap,
                more,
              ],
            );
          }
          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: AdminContent(wide: wide, child: body),
          );
        }),
      ),
    );
  }

  static String _plural(int n, String one, String many, String tail) => '$n ${n == 1 ? one : many}$tail';

  Widget _fleetMap(List<ConvoyModel> convoys, List<LatLng> points, int now) {
    final markers = <Marker>[];
    for (final c in convoys) {
      final colors = MemberColors.assign(c.riders.keys);
      // 3.55 follow-up: one marker per bike (a seated pillion rides on the two-up bike).
      for (final e in BikeMarkerPlan.forViewer(c.riders, mergePillions: context.featureOn('pillionSeat')).values) {
        final r = c.riders[e.markerId];
        if (r == null) continue;
        markers.add(Marker(
          point: LatLng(r.lat, r.lng),
          width: 48,
          height: 48,
          // 3.55: the rider's bike (shape and colour) instead of a round avatar.
          child: StatusBikeMarker(
            name: BikeMarkerPlan.nameOf(e),
            color: colors[e.bikeRider.userId] ?? AppTheme.accentText,
            vehicleKind: e.bikeRider.vehicleKind,
            vehicleColor: e.bikeRider.vehicleColor,
            status: riderStatusOf(r, c, isMe: false, nowMs: now),
            heading: r.heading,
            twoUp: e.twoUp,
            height: 26,
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
        if (c.createdByUserName.isNotEmpty) 'trip owner ${c.createdByUserName}',
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
                  Text(formatDistance(metrics.spreadKm * 1000), style: AppText.label.copyWith(color: spreadColor, fontWeight: FontWeight.w600)),
                  Text('spread', style: AppText.caption.copyWith(fontWeight: FontWeight.w600)),
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
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: AppTheme.border)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: AppTheme.border)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: AppTheme.accentText, width: 1.5)),
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

/// 7d / 30d / 90d as one small segmented control.
class _PeriodSelector extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;

  const _PeriodSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.palette;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: p.surfaceAlt, borderRadius: BorderRadius.circular(12)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final d in adminOverviewPeriods)
            Semantics(
              button: true,
              selected: d == value,
              label: 'Last $d days',
              excludeSemantics: true,
              child: GestureDetector(
                onTap: () => onChanged(d),
                child: AnimatedContainer(
                  duration: Motion.tab,
                  curve: Motion.curve,
                  constraints: const BoxConstraints(minHeight: 34, minWidth: 44),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: d == value ? p.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: d == value ? [BoxShadow(color: p.shadow, blurRadius: 4, offset: const Offset(0, 1))] : null,
                  ),
                  child: Text(
                    '${d}d',
                    style: AppText.label.copyWith(color: d == value ? p.text : p.textMuted, fontWeight: d == value ? FontWeight.w600 : FontWeight.w500),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A small (i): the longer explanation stays out of the way until asked for.
class _InfoDot extends StatelessWidget {
  final String message;
  const _InfoDot({required this.message});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      triggerMode: TooltipTriggerMode.tap,
      showDuration: const Duration(seconds: 6),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(Icons.info_outline_rounded, size: 18, color: AppTheme.palette.textMuted),
      ),
    );
  }
}

/// "This period" (teal line) and "Before" (dashed amber) under the active-riders title.
class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.palette;
    Widget key(Color c, String t, {bool dashed = false}) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 2,
              child: dashed
                  ? Row(children: [Expanded(child: ColoredBox(color: c)), const SizedBox(width: 3), Expanded(child: ColoredBox(color: c))])
                  : ColoredBox(color: c),
            ),
            const SizedBox(width: 5),
            Text(t, style: AppText.caption),
          ],
        );
    return ExcludeSemantics(
      child: Wrap(spacing: 10, children: [key(p.primary, 'Now'), key(p.accent, 'Before', dashed: true)]),
    );
  }
}

/// One thing that needs an admin, with its action.
class _Attention {
  final IconData icon;
  final String title;
  final String action;
  final Color color;
  final VoidCallback onTap;

  const _Attention(this.icon, this.title, this.action, this.color, this.onTap);
}

class _AttentionRow extends StatelessWidget {
  final _Attention item;
  final bool divider;

  const _AttentionRow({required this.item, required this.divider});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${item.title}. ${item.action}',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: item.onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(border: divider ? Border(bottom: BorderSide(color: AppTheme.border)) : null),
          child: Row(
            children: [
              AdminRowIcon(item.icon, color: item.color),
              const SizedBox(width: 12),
              Expanded(child: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontSize: 14))),
              const SizedBox(width: 8),
              Text(item.action, style: AppText.label.copyWith(color: AppTheme.accentText, fontWeight: FontWeight.w600)),
              Icon(Icons.chevron_right_rounded, size: 20, color: AppTheme.palette.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// The rest of the server totals for the period, folded away under "More numbers".
class _MoreNumbers extends StatelessWidget {
  final Map<String, dynamic>? overview;
  final int days;
  final bool open;
  final VoidCallback onToggle;

  const _MoreNumbers({required this.overview, required this.days, required this.open, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final ov = overview;
    Map<String, dynamic> part(String k) => ov != null && ov[k] is Map ? Map<String, dynamic>.from(ov[k] as Map) : <String, dynamic>{};
    final riders = part('riders');
    final rides = part('rides');
    final safety = part('safety');
    final response = adminNumOrNull(safety['medianResponseSec']);
    final rows = <(String, String, String)>[
      ('Riders', adminCount(riders['total']), '${adminCount(riders['newInPeriod'])} new'),
      ('Active 7 days', adminCount(riders['active7d']), '${adminCount(riders['active30d'])} in 30 days'),
      ('Rides finished', adminCount(rides['groupsInPeriod']), '${adminCount(rides['groupsCompleted'])} all time'),
      ('Rider trips', adminCount(rides['tripsInPeriod']), '${adminCount(rides['completedTrips'])} all time'),
      ('Km ridden', adminCount(rides['kmInPeriod']), '${adminCount(rides['kmRidden'])} all time'),
      ('Avg group', adminCount(rides['avgGroupSize']), 'riders per ride'),
      ('SOS', adminCount(safety['sosInPeriod']), '${adminCount(safety['resolved'])} resolved, ${adminCount(safety['falseAlarms'])} false'),
      ('SOS answered', response == null ? '—' : formatDuration(Duration(seconds: response.round())), 'median first response'),
      ('On a group plan', adminCount(riders['paying']), '${adminCount(riders['conversionPct'])}% of riders'),
    ];
    return DsCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(
                children: [
                  Expanded(child: Text('More numbers', style: AppText.title)),
                  Text('Last $days days', style: AppText.caption),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: Motion.tab,
                    child: Icon(Icons.expand_more_rounded, color: AppTheme.palette.textMuted),
                  ),
                ],
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: ov == null
                  ? Text('Loading…', style: AppText.label)
                  : Column(
                      children: [
                        for (final (label, value, note) in rows)
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 9),
                            decoration: BoxDecoration(border: Border(top: BorderSide(color: AppTheme.border))),
                            child: Row(
                              children: [
                                Expanded(child: Text(label, style: AppText.label.copyWith(color: AppTheme.text))),
                                Text(value, style: AppText.body.copyWith(fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()])),
                                const SizedBox(width: 10),
                                SizedBox(width: 132, child: Text(note, textAlign: TextAlign.end, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption)),
                              ],
                            ),
                          ),
                        if (ov['truncated'] == true)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: StatusLine(icon: Icons.info_outline_rounded, text: 'Some totals stop at the scan limit and may be higher.', color: AppTheme.warnText),
                          ),
                      ],
                    ),
            ),
        ],
      ),
    );
  }
}
