import '../../data/services/ride_essentials_coordinator.dart';
import '../ride/essentials_sheet.dart';
import '../../data/services/geo_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/l10n/l10n.dart';
import '../../core/ui/confirm.dart';
import '../../data/models/trip_history_model.dart';
import '../../data/services/background_service.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/place_review_service.dart';
import '../map_places/after_ride_place_reviews.dart';
import '../widgets/feature_switch.dart';
import '../../data/services/ride_notification_service.dart';
import '../account/account_screen.dart';
import '../alerts/alerts_screen.dart';
import '../home/ride_start_view.dart';
import '../ride/emergency_guidance.dart';
import '../ride/map_focus.dart';
import '../chat/chat_list_screen.dart'; // v3.58 shell
import '../explore/explore_screen.dart'; // v3.58 shell
import '../home/home_screen.dart'; // v3.58 shell
import '../shell/coroute_nav_bar.dart'; // v3.58 shell
import '../shell/quick_actions_sheet.dart'; // v3.58 shell
import '../shell/shell_badges.dart'; // v3.58 shell
import '../social/community_screen.dart'; // v3.58 shell
import 'live_cockpit_map_screen.dart';
import 'trip_history_screen.dart';
import '../engagement/ride_wrapup_sheet.dart';
import '../review/app_review_prompt.dart';
import '../../data/services/api_client.dart';
import '../../data/services/engagement_service.dart';
import '../../domain/security/lock_screen_cockpit_policy.dart';
import '../security/locked_cockpit_gate.dart';

/// The tabs of the app shell. v3.58 (docs/design/REDESIGN_v3.58.md): the bottom bar shows
/// Home (ride) · Explore · + · Community (people) · Chat; Trips, Alerts and Profile are kept as tabs
/// without a bar slot (opened from Home's header and Profile; Back returns to Home), so every
/// existing `selectTab` caller keeps working.
enum HomeTab { ride, explore, people, chat, trips, alerts, profile }

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

/// The app shell: Home | Trips | People | Alerts | Profile in a bottom navigation bar.
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
    // v3.58: the Community tab is its own screen; "open friends / crews / requests" pushes the People hub
    // (PeopleScreen.open with no tab opener), which keeps the requested segment.
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
      _offerStoredPlaceReviews();
    });
  }

  /// 3.55 follow-up: after-ride place questions kept from an earlier ride (the app was closed
  /// before they were answered): asked once on this app open, not during a ride or an SOS.
  Future<void> _offerStoredPlaceReviews() async {
    // 3.55: the admin's engagement templates (texts, chips, rating rules); at most every 6 hours.
    EngagementService.instance?.refresh().ignore();
    final places = Provider.of<PlaceReviewService?>(context, listen: false);
    if (places == null) return;
    await places.restored;
    // Let the home screen settle first (deep links, the join sheet).
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    final on = context.featureOnNow('placeReviews') && context.featureOnNow('reviewPrompt');
    final nav = Navigator.maybeOf(context, rootNavigator: true);
    if (nav == null || !nav.mounted) return;
    if (places.takeOpenPrompt(enabled: on)) {
      // 3.55: the same calm wrap-up as after a ride (places only here), with category chips.
      ApiClient? api;
      try {
        api = context.read<ApiClient>();
      } catch (_) {
        api = null;
      }
      if (api != null) {
        await RideWrapUpSheet.show(nav.context, api: api, tripId: '', tripName: '', canReviewTrip: false, tripReviewed: false, places: places, placesEnabled: on);
      } else {
        await AfterRidePlaceReviews.show(nav.context, service: places, enabled: on);
      }
    }
    // 3.55 "Rate CoRoute": a finished clean ride still waiting for its ask (its own rules decide).
    if (mounted && nav.mounted) await AppReviewPrompt.maybeAskAtAppOpen(nav.context);
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
      case RideNotifActionKind.viewGroup:
      case RideNotifActionKind.viewFuel:
        break;
      case RideNotifActionKind.openFuel:
        final shared = context.read<RideEssentialsCoordinator?>();
        final c = _convoys;
        if (shared == null || c == null || shared.groupId != c.activeConvoy?.groupId) break;
        shared.refresh(category: 'FUEL').ignore();
        showEssentialsSheet(context, service: shared.essentials,
          leader: c.canEditRoute, moving: (c.activeConvoy?.riders[c.myUserId]?.speedKmh ?? 0) > 5,
          refresh: (category, force) => shared.refresh(category: category, force: force),
          addStop: (place) {
            if (!c.isOnline || (c.activeConvoy?.riders[c.myUserId]?.speedKmh ?? 0) > 5) return false;
            final picked = PickedPlace(name: place.name, lat: place.lat, lng: place.lng, category: place.category);
            return c.canEditRoute ? c.addStop(picked) : c.suggestStop(picked);
          });
        break;
      case RideNotifActionKind.openMap:
      case RideNotifActionKind.sos:
      case RideNotifActionKind.wait:
      case RideNotifActionKind.talk:
        // Talk: the ride screen (selected above) has the hold-to-talk bar; nothing is sent by the tap.
        break;
      case RideNotifActionKind.endRide:
        // End ride / Leave from the notification: always the confirm first (never one tap).
        final c = _convoys;
        final uid = c?.myUserId;
        if (c == null || uid == null || c.activeConvoy == null) break;
        leaveFromNotification(context, c, uid).ignore();
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
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
        setState(() => _rideSaved = true);
        if (mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('The ride was ended. Trip saved to your history.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
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
      return LiveCockpitMapScreen(key: ValueKey(groupId), convoyId: groupId, embedded: true, focus: _mapFocus, isVisible: _tab == HomeTab.ride);
    }
    return HomeScreen(
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
        HomeTab.explore => const ExploreScreen(),
        HomeTab.chat => const ChatListScreen(),
        HomeTab.trips => TripHistoryScreen(embedded: true),
        HomeTab.people => const CommunityScreen(),
        HomeTab.alerts => const AlertsScreen(),
        HomeTab.profile => const AccountScreen(embedded: true),
      };

  @override
  Widget build(BuildContext context) {
    final groupId = context.select<ConvoyService, String?>((s) => s.activeGroupId);
    // Android back: from another tab it returns to Ride; during a ride it sends the app to the
    // background instead of closing it (the ride, GPS and intercom keep running). Only on the
    // Ride tab with no ride does back leave the app as usual.
    return PopScope(
      canPop: _tab == HomeTab.ride && groupId == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Locked cockpit (shown over the keyguard): Back never navigates; the ride screen stays.
        if (!LockScreenCockpitPolicy.backNavigates(locked: LockedCockpit.isLocked(context, listen: false))) return;
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
      bottomNavigationBar: (groupId != null && _tab == HomeTab.ride)
          ? null
          // v3.58: Home · Explore · + · Community · Chat (lib/presentation/shell). Trips, Alerts and Profile
          // have no slot: nothing is highlighted while one of them is shown.
          : CoRouteNavBar(
              selected: switch (_tab) {
                HomeTab.ride => NavSlot.home,
                HomeTab.explore => NavSlot.explore,
                HomeTab.people => NavSlot.community,
                HomeTab.chat => NavSlot.chat,
                _ => null,
              },
              onSelect: (slot) => _select(switch (slot) {
                NavSlot.home => HomeTab.ride,
                NavSlot.explore => HomeTab.explore,
                NavSlot.community => HomeTab.people,
                NavSlot.chat => HomeTab.chat,
              }),
              onPlus: () => QuickActionsSheet.show(context, onExplore: () => _select(HomeTab.explore)),
              badges: {
                NavSlot.home: ShellBadges.alerts(context),
                NavSlot.community: ShellBadges.community(context),
                NavSlot.chat: ShellBadges.chat(context),
              },
              badgeLabels: const {
                NavSlot.home: 'alerts need attention',
                NavSlot.community: 'requests waiting',
                NavSlot.chat: 'unread messages',
              },
            ),
    );
  }
}

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
