import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/services/admin_warnings_service.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/crews_service.dart';
import '../../data/services/friends_service.dart';
import '../../data/services/push_service.dart';
import '../../domain/notify/push_routing.dart';
import '../social/crew_detail_screen.dart';
import '../social/crews_screen.dart';
import '../social/friends_screen.dart';
import '../subscription/membership_dashboard_screen.dart';

/// 3.55 push notifications: opens the right screen for a tapped push, and shows a push that
/// arrives while the app is in front as a snackbar (with "View"). Placed once in
/// MaterialApp.builder (main.dart), next to FriendNoticeHost.
///
/// A cold start waits until the rider is signed in and the splash screen has handed over to the
/// first real screen ([observer] sees that replacement), so the splash cannot replace the
/// opened screen.
class PushRouterHost extends StatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;
  const PushRouterHost({super.key, required this.child, required this.navigatorKey});

  /// Added to MaterialApp.navigatorObservers: tells when the splash screen was replaced.
  static final PushNavObserver observer = PushNavObserver();

  /// Opens a ride invitation (RIDE_INVITE). Wired in main.dart to RideInviteScreen.open; while
  /// null, a tapped ride invite only brings the app to the front.
  static Future<void> Function(BuildContext context, String inviteId)? openRideInvite;

  @override
  State<PushRouterHost> createState() => _PushRouterHostState();
}

/// Records that the first route was replaced (splash -> home / sign-in).
class PushNavObserver extends NavigatorObserver {
  bool firstScreenShown = false;

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    firstScreenShown = true;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) firstScreenShown = true;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    firstScreenShown = true;
  }
}

class _PushRouterHostState extends State<PushRouterHost> {
  PushService? _push;
  StreamSubscription<PushMessage>? _openSub;
  StreamSubscription<PushMessage>? _msgSub;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final push = context.read<PushService?>();
    if (identical(push, _push)) return;
    _openSub?.cancel();
    _msgSub?.cancel();
    _push = push;
    if (push == null) return;
    _openSub = push.opened.listen(_openWhenReady);
    _msgSub = push.messages.listen(_onForeground);
    final pending = push.takePendingOpen();
    if (pending != null) _openWhenReady(pending);
  }

  @override
  void dispose() {
    _openSub?.cancel();
    _msgSub?.cancel();
    super.dispose();
  }

  Future<void> _openWhenReady(PushMessage m) async {
    final route = m.route;
    if (route.destination == PushDestination.none) return;
    // Up to ~20 s for sign-in and the splash hand-over; then the push is dropped.
    for (var i = 0; i < 80; i++) {
      if (!mounted) return;
      final auth = context.read<AuthService?>();
      final ready = auth != null && auth.isAuthenticated && widget.navigatorKey.currentState != null && PushRouterHost.observer.firstScreenShown;
      if (ready) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (!mounted) return;
    final auth = context.read<AuthService?>();
    if (auth == null || !auth.isAuthenticated) return;
    await _go(route);
  }

  Future<void> _go(PushRoute route) async {
    final navContext = widget.navigatorKey.currentContext;
    if (navContext == null) return;
    switch (route.destination) {
      case PushDestination.friends:
        context.read<FriendsService?>()?.refreshFriends().ignore();
        await FriendsScreen.open(navContext);
      case PushDestination.crewInvites:
        context.read<CrewsService?>()?.refresh().ignore();
        await CrewsScreen.open(navContext);
      case PushDestination.crewPoll:
        final crewId = route.crewId;
        if (crewId == null) return;
        context.read<CrewsService?>()?.refresh().ignore();
        await CrewDetailScreen.open(navContext, crewId);
      case PushDestination.rideInvite:
        final inviteId = route.inviteId;
        if (inviteId == null) return;
        final open = PushRouterHost.openRideInvite;
        if (open != null) await open(navContext, inviteId);
      case PushDestination.adminWarnings:
        context.read<AdminWarningsService?>()?.refresh().ignore();
      case PushDestination.membership:
        await Navigator.of(navContext).push(MaterialPageRoute<void>(builder: (_) => const MembershipDashboardScreen()));
      case PushDestination.none:
        return;
    }
  }

  /// A push while CoRoute is in front (its socket was not connected): refresh and offer "View".
  void _onForeground(PushMessage m) {
    if (!mounted) return;
    final route = m.route;
    switch (route.destination) {
      case PushDestination.friends:
        context.read<FriendsService?>()?.refreshFriends().ignore();
      case PushDestination.crewInvites:
      case PushDestination.crewPoll:
        context.read<CrewsService?>()?.refresh().ignore();
      case PushDestination.adminWarnings:
        context.read<AdminWarningsService?>()?.refresh().ignore();
      case PushDestination.rideInvite:
      case PushDestination.membership:
      case PushDestination.none:
        break;
    }
    final text = m.body.isNotEmpty ? m.body : m.title;
    if (text.isEmpty || route.destination == PushDestination.none) return;
    // 3.55: ride invites in the foreground get their own banner from the socket message
    // (RideInvitesService), so no second snackbar here.
    if (route.destination == PushDestination.rideInvite) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(SnackBar(
      content: Text(text),
      behavior: SnackBarBehavior.floating,
      action: route.destination == PushDestination.adminWarnings
          ? null
          : SnackBarAction(label: 'View', onPressed: () => _go(route).ignore()),
    ));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
