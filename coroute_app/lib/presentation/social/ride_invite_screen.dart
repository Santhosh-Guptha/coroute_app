import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/rider_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/crews_service.dart';
import '../../data/services/ride_invites_service.dart';
import '../../domain/social/ride_invite_rules.dart';
import '../garage/complete_bike_sheet.dart';
import '../home/ride_start_view.dart';
import '../onboarding/permissions_screen.dart';
import '../widgets/pre_ride_checklist_sheet.dart';
import '../widgets/push_router_host.dart';
import 'user_avatar.dart';

/// 3.55 "Start a ride with this crew": a ride invitation. Shows the host (username, first name,
/// picture), the crew, the ride name, start and destination names (never exact places), when it
/// started and how many ride; big Accept / Decline. Accept runs the normal join (permissions,
/// "Complete your bike" or "I'm riding pillion", then the pillion's bike pick) without a join code.
class RideInviteScreen extends StatefulWidget {
  final String inviteId;
  final RideInvite? initial;
  const RideInviteScreen({super.key, required this.inviteId, this.initial});

  /// Opens one invitation (RIDE_INVITE push taps, the in-app banner, the app-open check).
  static Future<void> open(BuildContext context, String inviteId) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RideInviteScreen(inviteId: inviteId)));

  @override
  State<RideInviteScreen> createState() => _RideInviteScreenState();
}

class _RideInviteScreenState extends State<RideInviteScreen> {
  RideInvite? _invite;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _invite = widget.initial;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final svc = context.read<RideInvitesService?>();
    if (svc == null) return;
    svc.markShown(widget.inviteId).ignore();
    try {
      final inv = await svc.invite(widget.inviteId);
      if (!mounted) return;
      setState(() {
        _invite = inv;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.statusCode == 404 ? 'This ride invitation is not available.' : e.message;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _accept(RideInvite inv) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = context.read<AuthService>();
    final convoys = context.read<ConvoyService>();
    final svc = context.read<RideInvitesService>();
    final nav = Navigator.of(context);
    // The same steps as joining with a code (ride_start_view.dart JoinRideSheet).
    if (!auth.isProfileComplete && !auth.isMasterAdmin) {
      final ok = await RideStartView.openProfile(context);
      if (!ok || !mounted) return setState(() => _busy = false);
    }
    if (!mounted) return;
    if (!await PermissionsScreen.ensure(context)) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    final gate = await BikeGate.ensureReady(context, pillionAccount: auth.isPillion);
    if (!mounted) return;
    if (gate == BikeGateResult.cancelled) return setState(() => _busy = false);
    double lat = 0, lng = 0;
    try {
      final pos = await Geolocator.getLastKnownPosition() ??
          await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 1)));
      lat = pos.latitude;
      lng = pos.longitude;
    } catch (_) {}
    final rider = RiderModel(
      userId: auth.currentUserId ?? '',
      name: auth.currentUserName ?? 'Rider',
      vehicleType: auth.vehicleType ?? 'Motorcycle',
      vehicleNo: auth.vehicleNo ?? '',
      phone: auth.phone ?? '',
      emergencyContact: auth.emergencyContact ?? '',
      emergencyContactName: auth.emergencyContactName ?? '',
      lat: lat,
      lng: lng,
      speedKmh: 0,
      heading: 0,
      batteryLevel: convoys.currentBatteryLevel,
      isCharging: convoys.isCharging,
      role: 'PACK',
      lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
    );
    final joined = await convoys.joinFromRideInvite(inviteId: inv.inviteId, rider: rider);
    if (!mounted) return;
    if (joined == null) {
      setState(() {
        _busy = false;
        _error = convoys.lastError ?? 'Could not join this ride. Try again.';
      });
      return;
    }
    svc.accepted(inv.inviteId);
    if (gate == BikeGateResult.pillion) convoys.requestPillionPick(); // 3.55 pillion seat
    // Back to the home shell (it switches to the Ride tab), then the pre-ride checklist.
    nav.popUntil((r) => r.isFirst);
    if (nav.context.mounted) await PreRideChecklistSheet.show(nav.context);
  }

  Future<void> _decline(RideInvite inv) async {
    if (_busy) return;
    setState(() => _busy = true);
    final err = await context.read<RideInvitesService>().decline(inv.inviteId);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    Navigator.of(context).maybePop();
  }

  static String _time(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final hh = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final mm = d.minute.toString().padLeft(2, '0');
    final now = DateTime.now();
    final today = d.year == now.year && d.month == now.month && d.day == now.day;
    return '${today ? 'today' : '${d.day}/${d.month}'} at $hh:$mm ${d.hour < 12 ? 'am' : 'pm'}';
  }

  @override
  Widget build(BuildContext context) {
    final inv = _invite;
    final open = inv != null && inv.isOpen(DateTime.now().millisecondsSinceEpoch);
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              padding: dsScreenPadding,
              children: [
                DsScreenHeader(title: 'Ride invitation', onBack: () => Navigator.maybePop(context)),
                const SizedBox(height: 18),
                if (_loading && inv == null)
                  const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
                else if (inv == null)
                  DsCard(child: Text(_error ?? 'This ride invitation could not be loaded.', style: AppText.body))
                else ...[
                  DsCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            UserAvatar(label: inv.hostUsername, avatarUrl: inv.hostAvatarUrl, size: 56),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(inv.hostLine, style: AppText.title),
                                  const SizedBox(height: 2),
                                  Text(inv.crewName.isEmpty ? 'invited you to ride' : 'invited you to ride with ${inv.crewName}',
                                      style: AppText.body.copyWith(color: AppTheme.text2)),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: Space.s16),
                        Text(inv.rideName.isEmpty ? 'Group ride' : inv.rideName, style: AppText.headline),
                        if (inv.routeLine.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Row(children: [
                            Icon(Icons.route_rounded, size: 18, color: AppTheme.text2),
                            const SizedBox(width: 6),
                            Expanded(child: Text(inv.routeLine, style: AppText.body)),
                          ]),
                        ],
                        if (inv.startedAt > 0) ...[
                          const SizedBox(height: 6),
                          Row(children: [
                            Icon(Icons.schedule_rounded, size: 18, color: AppTheme.text2),
                            const SizedBox(width: 6),
                            Expanded(child: Text('Started ${_time(inv.startedAt)}', style: AppText.body)),
                          ]),
                        ],
                        const SizedBox(height: 6),
                        Row(children: [
                          Icon(Icons.groups_rounded, size: 18, color: AppTheme.text2),
                          const SizedBox(width: 6),
                          Expanded(child: Text(inv.ridersLine, style: AppText.body)),
                        ]),
                      ],
                    ),
                  ),
                  const SizedBox(height: Space.s16),
                  if (!open)
                    DsCard(
                      child: Text(
                        switch (inv.status) {
                          RideInviteStatus.accepted => 'You accepted this invitation.',
                          RideInviteStatus.declined => 'You declined this invitation.',
                          RideInviteStatus.cancelled => 'The host took this invitation back.',
                          _ => 'This invitation has expired.',
                        },
                        style: AppText.body,
                      ),
                    )
                  else ...[
                    Text('Joining shares your live location with this group while you ride, like any group ride.',
                        style: AppText.caption.copyWith(color: AppTheme.text2)),
                    const SizedBox(height: Space.s16),
                    DsButton(label: _busy ? 'Joining...' : 'Accept', icon: Icons.check_rounded, height: 60, fontSize: 18, onPressed: _busy ? null : () => _accept(inv)),
                    const SizedBox(height: Space.s12),
                    DsButton(label: 'Decline', icon: Icons.close_rounded, tone: DsButtonTone.outline, height: 56, onPressed: _busy ? null : () => _decline(inv)),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: Space.s12),
                    Text(_error!, style: AppText.body.copyWith(color: Theme.of(context).colorScheme.error)),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Several open invitations at once (the app-open check): pick one.
class RideInviteListScreen extends StatelessWidget {
  final List<RideInvite> invites;
  const RideInviteListScreen({super.key, required this.invites});

  static Future<void> open(BuildContext context, List<RideInvite> invites) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RideInviteListScreen(invites: invites)));

  @override
  Widget build(BuildContext context) {
    final live = context.watch<RideInvitesService?>()?.pending;
    final list = live == null ? invites : invites.where((i) => live.any((l) => l.inviteId == i.inviteId)).toList();
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              padding: dsScreenPadding,
              children: [
                DsScreenHeader(title: 'Ride invitations', onBack: () => Navigator.maybePop(context)),
                const SizedBox(height: 18),
                if (list.isEmpty) DsCard(child: Text('No ride invitations waiting.', style: AppText.body)),
                for (final i in list)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.s12),
                    child: DsCard(
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: UserAvatar(label: i.hostUsername, avatarUrl: i.hostAvatarUrl, size: 44),
                        title: Text(i.rideName.isEmpty ? 'Group ride' : i.rideName, style: AppText.title),
                        subtitle: Text('${i.hostUsername}${i.crewName.isEmpty ? '' : ' · ${i.crewName}'}', style: AppText.body.copyWith(color: AppTheme.text2)),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RideInviteScreen(inviteId: i.inviteId, initial: i))),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Placed once in MaterialApp.builder: when the app opens or comes back and a ride invitation is
/// waiting, shows it by itself (once per invite; several: the list). A RIDE_INVITE that arrives on
/// the socket while the app is open shows a banner with "View". After "Start a ride" on a crew,
/// opens the crew member picker as soon as my new ride is live. Answers (accepted / declined) to
/// the host show as a snackbar.
class RideInviteHost extends StatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;
  const RideInviteHost({super.key, required this.child, required this.navigatorKey});

  @override
  State<RideInviteHost> createState() => _RideInviteHostState();
}

class _RideInviteHostState extends State<RideInviteHost> {
  RideInvitesService? _svc;
  ConvoyService? _convoys;
  StreamSubscription<RideInvite>? _arrivedSub;
  StreamSubscription<(String, String)>? _answerSub;
  int _seenChecks = -1;
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    // Tapped RIDE_INVITE pushes open this screen (PushRouterHost; also set in main.dart by the push work).
    PushRouterHost.openRideInvite ??= RideInviteScreen.open;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final svc = context.read<RideInvitesService?>();
    if (!identical(svc, _svc)) {
      _svc?.removeListener(_onChange);
      _arrivedSub?.cancel();
      _answerSub?.cancel();
      _svc = svc?..addListener(_onChange);
      _arrivedSub = svc?.arrived.listen(_onArrived);
      _answerSub = svc?.answers.listen(_onAnswer);
      // The first read may have finished before this host listened.
      if (svc != null) WidgetsBinding.instance.addPostFrameCallback((_) => _onChange());
    }
    final convoys = context.read<ConvoyService?>();
    if (!identical(convoys, _convoys)) {
      _convoys?.removeListener(_onConvoys);
      _convoys = convoys?..addListener(_onConvoys);
    }
  }

  @override
  void dispose() {
    _svc?.removeListener(_onChange);
    _convoys?.removeListener(_onConvoys);
    _arrivedSub?.cancel();
    _answerSub?.cancel();
    super.dispose();
  }

  bool get _ready {
    final auth = context.read<AuthService?>();
    return mounted && auth != null && auth.isAuthenticated && widget.navigatorKey.currentState != null && PushRouterHost.observer.firstScreenShown;
  }

  /// A riding rider is not interrupted by a full screen: the banner is enough.
  bool get _riding {
    final c = _convoys?.activeConvoy;
    return c != null && c.tripStatus != 'ENDED';
  }

  void _onChange() {
    final svc = _svc;
    if (svc == null || svc.checks == _seenChecks) return;
    _seenChecks = svc.checks;
    _autoShow();
  }

  Future<void> _autoShow() async {
    final svc = _svc;
    if (svc == null || _showing || svc.pending.isEmpty) return;
    for (var i = 0; i < 40 && !_ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (!_ready || _riding) return;
    _showing = true;
    try {
      final (mode, list) = await svc.takeAutoShow();
      final nav = widget.navigatorKey.currentContext;
      if (nav == null || !nav.mounted) return;
      switch (mode) {
        case RideInviteAutoShow.single:
          await Navigator.of(nav).push(MaterialPageRoute<void>(builder: (_) => RideInviteScreen(inviteId: list.first.inviteId, initial: list.first)));
        case RideInviteAutoShow.list:
          await RideInviteListScreen.open(nav, list);
        case RideInviteAutoShow.none:
          break;
      }
    } finally {
      _showing = false;
    }
  }

  void _onArrived(RideInvite inv) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(inv.noticeLine),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 10),
        action: SnackBarAction(
          label: 'View',
          onPressed: () {
            final nav = widget.navigatorKey.currentContext;
            if (nav != null && nav.mounted) RideInviteScreen.open(nav, inv.inviteId).ignore();
          },
        ),
      ));
  }

  void _onAnswer((String, String) a) {
    if (!mounted) return;
    final who = a.$1.isEmpty ? 'A rider' : a.$1;
    final line = a.$2 == RideInviteStatus.accepted ? '$who accepted your ride invitation' : '$who declined your ride invitation';
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(line), behavior: SnackBarBehavior.floating));
  }

  void _onConvoys() {
    final svc = _svc;
    final c = _convoys?.activeConvoy;
    final me = _convoys?.myUserId;
    if (svc == null || c == null || me == null || !c.isTripOwner(me) || c.tripStatus == 'ENDED') return;
    final crew = svc.takePendingCrewRide();
    if (crew == null) return;
    // Let the shell switch to the ride first, then ask whom to invite.
    Future<void>.delayed(const Duration(milliseconds: 900), () {
      final nav = widget.navigatorKey.currentContext;
      if (nav != null && nav.mounted) showCrewRideInviteSheet(nav, crewId: crew.$1, crewName: crew.$2, groupId: c.groupId).ignore();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// "Start a ride" on a crew screen. When I already run a live group ride, its crew picker opens
/// at once; otherwise the usual ride creation (trip planner, plan checks) starts and the picker
/// opens as soon as the new ride is live ([RideInviteHost]).
Future<void> startRideWithCrew(BuildContext context, {required String crewId, required String crewName}) async {
  final convoys = context.read<ConvoyService>();
  final svc = context.read<RideInvitesService>();
  final c = convoys.activeConvoy;
  final me = convoys.myUserId;
  if (c != null && c.tripStatus != 'ENDED') {
    if (me != null && c.isTripOwner(me)) {
      await showCrewRideInviteSheet(context, crewId: crewId, crewName: crewName, groupId: c.groupId);
    } else {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('You are in a ride someone else started. Only its trip owner can invite riders.')));
    }
    return;
  }
  svc.setPendingCrewRide(crewId, crewName);
  await RideStartView.startRide(context);
}

/// The host picks crew members to invite to [groupId] (multi-select, select all), sends, and sees
/// each invitation's status.
Future<void> showCrewRideInviteSheet(BuildContext context, {required String crewId, required String crewName, required String groupId}) =>
    showAppSheet<void>(
      context,
      title: 'Invite $crewName to your ride',
      isScrollControlled: true,
      builder: (_) => CrewRideInviteSheet(crewId: crewId, groupId: groupId),
    );

class CrewRideInviteSheet extends StatefulWidget {
  final String crewId;
  final String groupId;
  const CrewRideInviteSheet({super.key, required this.crewId, required this.groupId});

  @override
  State<CrewRideInviteSheet> createState() => _CrewRideInviteSheetState();
}

class _CrewRideInviteSheetState extends State<CrewRideInviteSheet> {
  List<CrewMember>? _members;
  List<SentRideInvite> _sent = const [];
  final Set<String> _picked = {};
  String? _error;
  String? _summary;
  bool _busy = false;
  StreamSubscription<(String, String)>? _answers;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _answers?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final crews = context.read<CrewsService>();
    final svc = context.read<RideInvitesService>();
    final me = context.read<AuthService>().username;
    _answers ??= svc.answers.listen((_) => _reloadSent());
    try {
      final d = await crews.detail(widget.crewId);
      final sent = await svc.sent(widget.crewId, widget.groupId);
      if (!mounted) return;
      setState(() {
        _members = RideInviteRules.pickable<CrewMember>(d.members, (m) => m.username, myUsername: me);
        _sent = sent;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load the crew.');
    }
  }

  Future<void> _reloadSent() async {
    final sent = await context.read<RideInvitesService>().sent(widget.crewId, widget.groupId);
    if (mounted) setState(() => _sent = sent);
  }

  String? _statusOf(String username) {
    for (final s in _sent) {
      if (s.username.toLowerCase() == username.toLowerCase()) return s.status;
    }
    return null;
  }

  bool _canPick(String username) {
    final st = _statusOf(username);
    return st == null || st == RideInviteStatus.declined || st == RideInviteStatus.expired || st == RideInviteStatus.cancelled;
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final res = await context.read<RideInvitesService>().send(widget.crewId, widget.groupId, _picked.toList());
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res.error != null) {
        _error = res.error;
        return;
      }
      _sent = res.invites;
      _picked.clear();
      _summary = RideInviteRules.summary([for (final r in res.results) r.$2]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = _members;
    final pickable = m == null ? const <CrewMember>[] : m.where((x) => _canPick(x.username)).toList();
    final allPicked = pickable.isNotEmpty && pickable.every((x) => _picked.contains(x.username));
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Pick who to invite. They get a notification and join when they accept. Your join code is not shared.',
              style: AppText.body.copyWith(color: AppTheme.text2)),
          const SizedBox(height: 8),
          if (m == null && _error == null)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (m != null && m.isEmpty)
            Text('No one else is in this crew yet.', style: AppText.body)
          else if (m != null) ...[
            if (pickable.isNotEmpty)
              CheckboxListTile(
                value: allPicked,
                onChanged: (v) => setState(() {
                  if (v == true) {
                    _picked.addAll(pickable.map((x) => x.username));
                  } else {
                    _picked.clear();
                  }
                }),
                title: Text('Select all (${pickable.length})', style: AppText.title),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final x in m)
                    CheckboxListTile(
                      value: _canPick(x.username) ? _picked.contains(x.username) : true,
                      onChanged: _canPick(x.username)
                          ? (v) => setState(() => v == true ? _picked.add(x.username) : _picked.remove(x.username))
                          : null,
                      secondary: UserAvatar(label: x.username, avatarUrl: x.avatarUrl, size: 36),
                      title: Text(x.username),
                      subtitle: Text(_statusOf(x.username) != null ? RideInviteStatus.label(_statusOf(x.username)!) : x.displayName),
                    ),
                ],
              ),
            ),
          ],
          if (_summary != null) ...[
            const SizedBox(height: 8),
            Text(_summary!, style: AppText.body),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: AppText.body.copyWith(color: Theme.of(context).colorScheme.error)),
          ],
          if (m != null && m.isNotEmpty) ...[
            const SizedBox(height: 8),
            DsButton(
              label: _busy ? 'Sending...' : RideInviteRules.sendLabel(_picked.length),
              icon: Icons.send_rounded,
              onPressed: _busy || _picked.isEmpty ? null : _send,
            ),
          ],
        ],
      ),
    );
  }
}
