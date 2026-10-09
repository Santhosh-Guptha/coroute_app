import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/l10n/l10n.dart';
import '../../core/ui/confirm.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/trip_history_model.dart';
import '../../data/services/background_service.dart';
import '../../core/ui/ride_alert.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/ride_notification_service.dart';
import '../../data/services/safety_service.dart';
import '../../data/services/timeline_service.dart';
import '../account/account_screen.dart';
import '../alerts/alerts_screen.dart';
import '../home/ride_start_view.dart';
import '../ride/emergency_guidance.dart';
import '../ride/map_focus.dart';
import 'live_cockpit_map_screen.dart';
import 'trip_history_screen.dart';

/// The four tabs of the app, in bottom navigation order.
enum HomeTab { ride, trips, alerts, profile }

/// "Leave ride" from the ride notification (3.16, item 3). The notification
/// button only sets [ConvoyService.leaveRequestedFromNotification]; this
/// clears it, asks the rider to confirm, and only then leaves. Used by the
/// ride screen, and by the shell when the ride screen is not built yet.
Future<void> leaveFromNotification(BuildContext context, ConvoyService convoys, String uid, {bool embedded = true}) async {
  convoys.clearLeaveRequest();
  final ok = await confirmAction(
    context,
    title: L10n.t('leave.title'),
    message: L10n.t('leave.body'),
    confirmLabel: L10n.t('leave.confirm'),
    destructive: true,
  );
  if (!ok || !context.mounted) return;
  convoys.leaveActiveConvoy(uid);
  if (!embedded) Navigator.of(context).maybePop();
}

/// The app shell: Ride | Trips | Alerts | Profile in a bottom navigation bar.
///
/// Ride is selected at start and whenever a ride becomes active (create, join,
/// restore). When the ride ends the shell stays on Ride, which then offers the
/// saved trip. A join link opens the join sheet. There is no drawer: every
/// destination has exactly one entry point.
class RiderHomeScreen extends StatefulWidget {
  const RiderHomeScreen({super.key});

  static _RiderHomeScreenState? _current;

  /// Switches the shell to [tab], from inside the shell or from a screen
  /// pushed above it (which is then closed so the tab is visible).
  static void selectTab(BuildContext context, HomeTab tab) {
    final state = context.findAncestorStateOfType<_RiderHomeScreenState>() ?? _current;
    if (state == null || !state.mounted) return;
    final route = ModalRoute.of(state.context);
    if (route != null && !route.isCurrent) {
      Navigator.of(state.context).popUntil((r) => r == route);
    }
    state._select(tab);
  }

  /// Switches to the Ride tab, centres the map on [userId] and opens their
  /// rider card (from the Alerts tab: "Show on map"). Nothing happens
  /// without an active ride.
  static void showRiderOnMap(BuildContext context, String userId) {
    final state = context.findAncestorStateOfType<_RiderHomeScreenState>() ?? _current;
    if (state == null || !state.mounted || state._lastGroupId == null) return;
    selectTab(context, HomeTab.ride);
    state._mapFocus.showRider(userId);
  }

  @override
  State<RiderHomeScreen> createState() => _RiderHomeScreenState();
}

class _RiderHomeScreenState extends State<RiderHomeScreen> {
  HomeTab _tab = HomeTab.ride;

  /// Tabs are built the first time they are opened, then kept alive.
  final Set<HomeTab> _built = {HomeTab.ride};
  ConvoyService? _convoys;
  String? _lastGroupId;
  bool _rideSaved = false;
  bool _joinOpen = false;
  bool _leaveAsking = false;

  /// "Show on map" requests from the Alerts tab to the ride map.
  final MapFocus _mapFocus = MapFocus();

  /// Taps on the big ride notification (Open map, SOS, Navigate to emergency).
  RideNotificationService? _rideNotif;

  @override
  void initState() {
    super.initState();
    RiderHomeScreen._current = this;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final s = context.read<ConvoyService>();
      _convoys = s;
      _lastGroupId = s.activeGroupId;
      s.addListener(_onConvoyChanged);
      _onConvoyChanged();
      final rn = Provider.of<RideNotificationService?>(context, listen: false);
      _rideNotif = rn;
      rn?.pendingUiAction.addListener(_onRideNotifAction);
      _onRideNotifAction();
    });
  }

  /// A tap on the ride notification: show the ride map; SOS opens the hold
  /// screen there (the ride screen does it, nothing is sent by the tap);
  /// "Navigate to emergency" starts the in-app guidance.
  void _onRideNotifAction() {
    final rn = _rideNotif;
    final action = rn?.pendingUiAction.value;
    if (rn == null || action == null || !mounted) return;
    rn.clearUiAction();
    _select(HomeTab.ride);
    switch (action.kind) {
      case RideNotifActionKind.openMap:
      case RideNotifActionKind.sos:
      case RideNotifActionKind.wait:
        break;
      case RideNotifActionKind.navigateEmergency:
      case RideNotifActionKind.assistAccept:
        final ref = action.ref;
        final guidance = Provider.of<EmergencyGuidance?>(context, listen: false);
        if (ref == null || ref.isEmpty || guidance == null) break;
        final convoy = _convoys?.activeConvoy;
        final own = convoy?.activeAlerts.any((a) => a.alertId == ref && !a.resolved) ?? false;
        guidance.start(NavTarget(kind: own ? NavTargetKind.groupEmergency : NavTargetKind.assist, ref: ref)).ignore();
        break;
    }
  }

  @override
  void dispose() {
    _convoys?.removeListener(_onConvoyChanged);
    _rideNotif?.pendingUiAction.removeListener(_onRideNotifAction);
    _mapFocus.dispose();
    if (RiderHomeScreen._current == this) RiderHomeScreen._current = null;
    super.dispose();
  }

  void _select(HomeTab tab) {
    if (!mounted) return;
    if (_tab == tab && _built.contains(tab)) return;
    setState(() {
      _tab = tab;
      _built.add(tab);
    });
  }

  /// Ride starts: show the Ride tab. Ride ends: stay, and offer the summary.
  /// A join link: open the join sheet with the code filled in.
  void _onConvoyChanged() {
    final s = _convoys;
    if (s == null || !mounted) return;
    final gid = s.activeGroupId;
    // "Leave ride" from the notification while the ride screen is not built (the ride screen
    // handles it itself once it is): confirm first, never one tap.
    if (s.leaveRequestedFromNotification && gid != null && !_built.contains(HomeTab.ride) && !_leaveAsking) {
      _leaveAsking = true;
      final uid = s.myUserId ?? '';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          _leaveAsking = false;
          return;
        }
        leaveFromNotification(context, s, uid).whenComplete(() => _leaveAsking = false);
      });
    }
    if (gid != _lastGroupId) {
      final started = _lastGroupId == null && gid != null;
      final ended = _lastGroupId != null && gid == null;
      _lastGroupId = gid;
      if (started) {
        _rideSaved = false;
        _built.add(HomeTab.ride);
        setState(() => _tab = HomeTab.ride);
      } else if (ended) {
        setState(() => _rideSaved = true);
      }
    }
    final code = s.pendingJoinCode;
    if (code == null || _joinOpen || gid != null) return; // already riding: the link is ignored
    _joinOpen = true;
    s.setPendingJoinCode(null);
    _select(HomeTab.ride);
    showJoinRideSheet(context, initialCode: code).whenComplete(() => _joinOpen = false);
  }

  Widget _rideTab(String? groupId) {
    if (groupId != null) {
      return LiveCockpitMapScreen(key: ValueKey(groupId), convoyId: groupId, embedded: true, focus: _mapFocus);
    }
    return RideStartView(
      showRideSaved: _rideSaved,
      onViewSummary: () {
        setState(() => _rideSaved = false);
        _select(HomeTab.trips);
      },
      onDismissRideSaved: () => setState(() => _rideSaved = false),
    );
  }

  Widget _body(HomeTab tab, String? groupId) => switch (tab) {
        HomeTab.ride => _rideTab(groupId),
        HomeTab.trips => TripHistoryScreen(embedded: true),
        HomeTab.alerts => const AlertsScreen(),
        HomeTab.profile => const AccountScreen(embedded: true),
      };

  @override
  Widget build(BuildContext context) {
    final groupId = context.select<ConvoyService, HomeConvoyFacts>((s) => homeConvoyFacts(s.activeConvoy)).groupId;
    // Android back: from another tab it returns to Ride; during a ride it sends the app to the
    // background instead of closing it (the ride, GPS and intercom keep running). Only on the
    // Ride tab with no ride does back leave the app as usual.
    return PopScope(
      canPop: _tab == HomeTab.ride && groupId == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_tab != HomeTab.ride) {
          _select(HomeTab.ride);
        } else {
          BackgroundService.minimizeApp();
        }
      },
      child: _scaffold(groupId),
    );
  }

  Widget _scaffold(String? groupId) {
    return Scaffold(
      body: IndexedStack(
        index: _tab.index,
        sizing: StackFit.expand,
        children: [
          for (final t in HomeTab.values) _built.contains(t) ? _body(t, groupId) : const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab.index,
        onDestinationSelected: (i) => _select(HomeTab.values[i]),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.two_wheeler_rounded), label: 'Ride'),
          NavigationDestination(icon: Icon(Icons.route_rounded), label: 'Trips'),
          NavigationDestination(icon: _AlertsNavIcon(), label: 'Alerts'),
          NavigationDestination(icon: Icon(Icons.person_rounded), label: 'Profile'),
        ],
      ),
    );
  }
}

/// The Alerts icon with the number of critical and important alerts.
/// Rebuilds on timeline changes and on ride facts, never on positions.
class _AlertsNavIcon extends StatelessWidget {
  const _AlertsNavIcon();

  @override
  Widget build(BuildContext context) {
    final facts = context.select<ConvoyService, AlertFacts>(alertFactsOf);
    final timeline = context.watch<TimelineService>();
    // This phone's own safety prompts ("Are you OK?") count too; "Time for a break" does not.
    final prompts = context.select<SafetyService?, int>((s) => s?.prompts.where((p) => p.tier != AlertTier.normal).length ?? 0);
    // Assistance requests from other groups and accidents reported ahead count too (never social).
    final network = context.select<ConvoyService, int>((s) => s.assistRequests.length + s.hazards.length);
    final n = alertsBadgeCount(facts, timeline) + prompts + network;
    return Semantics(
      label: n > 0 ? '$n alerts need attention' : null,
      child: Badge.count(
        count: n,
        isLabelVisible: n > 0,
        child: const Icon(Icons.notifications_rounded),
      ),
    );
  }
}

/// What the home screen shows about the active convoy.
typedef HomeConvoyFacts = ({String? groupId, String name, int riders, String joinCode, String destination});

/// The few convoy facts the home screen shows. A record compares by value, so the home
/// screen rebuilds only when one of these changes, never on a rider's position update.
HomeConvoyFacts homeConvoyFacts(ConvoyModel? c) =>
    (groupId: c?.groupId, name: c?.name ?? '', riders: c?.riders.length ?? 0, joinCode: c?.joinCode ?? '', destination: c?.destinationName ?? '');

/// Ride totals over the trip history, for the home screen.
class HomeAnalytics {
  final int rides;
  final double totalDistanceKm;
  final int totalMinutes;
  final double maxSpeedKmh;
  final double avgSpeedKmh;
  final double avgRiders;
  final double avgDistanceKm;
  final double movingPercent;

  const HomeAnalytics({
    required this.rides,
    required this.totalDistanceKm,
    required this.totalMinutes,
    required this.maxSpeedKmh,
    required this.avgSpeedKmh,
    required this.avgRiders,
    required this.avgDistanceKm,
    required this.movingPercent,
  });

  factory HomeAnalytics.of(List<TripHistoryModel> trips) {
    double distance = 0, maxSpeed = 0, sumAvg = 0;
    int minutes = 0, riders = 0, moving = 0, rest = 0;
    for (final t in trips) {
      distance += t.totalDistanceKm;
      minutes += t.durationMinutes;
      if (t.topSpeedKmh > maxSpeed) maxSpeed = t.topSpeedKmh;
      sumAvg += t.avgSpeedKmh;
      riders += t.riderCount;
      moving += t.movingMs;
      rest += t.restMs;
    }
    final n = trips.length;
    return HomeAnalytics(
      rides: n,
      totalDistanceKm: distance,
      totalMinutes: minutes,
      maxSpeedKmh: maxSpeed,
      avgSpeedKmh: n > 0 ? sumAvg / n : 0.0,
      avgRiders: n > 0 ? riders / n : 0.0,
      avgDistanceKm: n > 0 ? distance / n : 0.0,
      movingPercent: (moving + rest) > 0 ? moving / (moving + rest) * 100 : 100.0,
    );
  }
}
