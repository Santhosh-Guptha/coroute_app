import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/crews_service.dart';
import '../../data/services/friends_service.dart';
import '../../data/services/ride_invites_service.dart';
import '../../domain/social/ride_invite_rules.dart';
import '../../domain/social/username_rules.dart';
import '../widgets/feature_switch.dart';
import 'crew_create_flow.dart';
import 'crew_detail_screen.dart';
import 'ride_invite_screen.dart';
import 'rider_profile_screen.dart';
import 'user_avatar.dart';

/// The three parts of the People hub.
enum PeopleSegment { friends, crews, requests }

/// The badge numbers for the People tab, the hub segments and the profile (one source).
PeopleBadges peopleBadgesOf(BuildContext context) {
  final friendRequests = context.select<FriendsService?, int>((s) => s?.incoming.length ?? 0);
  final crewInvites = context.select<CrewsService?, int>((s) => s?.invites.length ?? 0);
  final votes = context.select<CrewsService?, int>((s) => s?.crews.fold<int>(0, (a, c) => a + c.pendingVotes) ?? 0);
  final rides = context.select<RideInvitesService?, int>((s) => s == null ? 0 : mergeRequests(rideInvites: s.pending).length);
  return PeopleBadges.of(
    friendRequests: friendRequests,
    crewInvites: crewInvites,
    rideInvites: rides,
    pendingVotes: votes,
    friendsOn: context.featureOn(FriendsService.friendsFlag),
    crewsOn: context.featureOn(CrewsService.crewsFlag),
    pollsOn: context.featureOn(CrewsService.pollsFlag),
    crewRidesOn: context.featureOn(RideInvitesService.flag),
  );
}

/// The People icon in the bottom bar with everything waiting (requests and votes).
class PeopleNavIcon extends StatelessWidget {
  final bool selected;
  const PeopleNavIcon({super.key, this.selected = false});

  @override
  Widget build(BuildContext context) {
    final b = peopleBadgesOf(context);
    final icon = Icon(selected ? Icons.people_alt_rounded : Icons.people_alt_outlined);
    if (b.total == 0) return icon;
    return Semantics(
      label: b.requests > 0 ? '${b.requests} ${b.requests == 1 ? 'request' : 'requests'} waiting' : '${b.total} new',
      child: Badge(label: Text(PeopleBadges.label(b.total)), child: icon),
    );
  }
}

/// 3.55 People hub: one place for friends, crews and every request (friend requests, crew invites,
/// ride invites). A search box on top finds riders by username as you type. Reached in one tap from
/// the bottom bar (embedded) or pushed from a notification.
class PeopleScreen extends StatefulWidget {
  final bool embedded;
  final PeopleSegment? initial;
  const PeopleScreen({super.key, this.embedded = false, this.initial});

  /// The segment a caller asked for (read by the hub, then cleared).
  static final ValueNotifier<PeopleSegment?> requested = ValueNotifier<PeopleSegment?>(null);

  /// Set by the home shell: switches to its People tab (true) when the shell is there.
  static bool Function(BuildContext context)? tabOpener;

  /// Opens the hub on [segment]: the People tab when the home shell is up, else a pushed screen.
  static Future<void> open(BuildContext context, {PeopleSegment? segment}) async {
    requested.value = null;
    requested.value = segment;
    final opener = tabOpener;
    if (opener != null && opener(context)) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => PeopleScreen(initial: segment)));
  }

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  PeopleSegment? _segment;
  final _query = TextEditingController();
  final _queryFocus = FocusNode();
  late final PeopleSearch _search;
  PeopleSearchState _searchState = PeopleSearchState.idle;

  @override
  void initState() {
    super.initState();
    _segment = widget.initial;
    _search = PeopleSearch(
      fetch: (key) => context.read<FriendsService>().searchUsers(key),
      onState: (s) {
        if (mounted) setState(() => _searchState = s);
      },
    );
    PeopleScreen.requested.addListener(_onRequested);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _onRequested();
      _refresh();
    });
  }

  @override
  void dispose() {
    PeopleScreen.requested.removeListener(_onRequested);
    _search.dispose();
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  void _onRequested() {
    final s = PeopleScreen.requested.value;
    if (s == null || !mounted) return;
    PeopleScreen.requested.value = null;
    setState(() => _segment = s);
    if (_query.text.isNotEmpty) _clearSearch();
  }

  Future<void> _refresh() async {
    final friends = context.read<FriendsService?>();
    final crews = context.read<CrewsService?>();
    final rides = context.read<RideInvitesService?>();
    await Future.wait([
      if (friends != null) friends.refreshFriends(),
      if (friends != null) friends.refreshSuggestions(),
      if (crews != null) crews.refresh(),
      if (rides != null) rides.refresh(autoCheck: false),
    ]);
  }

  void _clearSearch() {
    _query.clear();
    _search.clear();
    _queryFocus.unfocus();
  }

  void _toast(String? text, {SnackBarAction? action}) {
    if (text == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating, action: action, duration: const Duration(seconds: 3)));
  }

  // ---- actions shared by every part ----
  Future<void> _shareInvite() async {
    final svc = context.read<FriendsService>();
    if (svc.profile?.shareText == null) await svc.refreshProfile();
    final text = svc.profile?.shareText;
    if (!mounted) return;
    if (text == null) return _toast('Could not load your invite link. Try again.');
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(ShareParams(
      text: text,
      subject: 'Ride with me on CoRoute',
      sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    ));
  }

  Future<void> _enterCode() async {
    final msg = await showAppSheet<String>(context, title: 'Enter an invite code', isScrollControlled: true, builder: (_) => const _InviteCodeForm());
    _toast(msg);
  }

  /// One tap on a person's chip: Add or Accept.
  Future<void> _act(String username, String relation) async {
    final svc = context.read<FriendsService>();
    final chip = RelationChip.of(relation);
    if (chip.action == PeopleAction.accept) {
      final req = svc.incoming.where((r) => r.username.toLowerCase() == username.toLowerCase()).firstOrNull;
      if (req != null) return _answerFriend(req.requestId, username, true);
    }
    if (chip.action == PeopleAction.none) return;
    final r = await svc.sendRequest(username, byCode: false);
    if (!r.ok) return _toast(r.error);
    final now = r.status == 'REQUESTED' ? PeopleRelation.pendingOut : PeopleRelation.friends;
    _search.markRelation(username, now);
    _toast(now == PeopleRelation.friends ? 'You and $username are now friends' : 'Request sent');
  }

  Future<void> _answerFriend(String requestId, String username, bool accept) async {
    final err = await context.read<FriendsService>().respond(requestId, accept);
    if (err == null && accept) _search.markRelation(username, PeopleRelation.friends);
    _toast(err ?? (accept ? 'You and $username are now friends' : 'Request declined'));
  }

  Future<void> _answerCrew(RequestItem r, bool accept) async {
    final err = await context.read<CrewsService>().respondInvite(r.id, accept);
    if (!mounted) return;
    if (err != null) return _toast(err);
    if (!accept) return _toast('Invite declined');
    _toast('You joined ${r.title}', action: SnackBarAction(label: 'Open', onPressed: () => CrewDetailScreen.open(context, r.crewId)));
  }

  Future<void> _declineRide(RequestItem r) async {
    _toast(await context.read<RideInvitesService>().decline(r.id) ?? 'Invite declined');
  }

  Future<void> _cancelSent(RequestItem r) async {
    _toast(await context.read<FriendsService>().cancelRequest(r.id) ?? 'Request cancelled');
  }

  void _profile(String username) {
    if (username.isNotEmpty) RiderProfileScreen.open(context, username);
  }

  Future<void> _friendMenu(FriendEntry f) async {
    final svc = context.read<FriendsService>();
    final choice = await showAppSheet<String>(
      context,
      title: f.username,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DsListRow(icon: Icons.person_rounded, label: 'View profile', onTap: () => Navigator.pop(ctx, 'view')),
          DsListRow(icon: Icons.person_remove_rounded, label: 'Remove friend', onTap: () => Navigator.pop(ctx, 'remove')),
          DsListRow(icon: Icons.block_rounded, label: 'Block', divider: false, onTap: () => Navigator.pop(ctx, 'block')),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'view':
        _profile(f.username);
      case 'remove':
        if (await confirmAction(context, title: 'Remove ${f.username}?', message: 'You can add each other again later.', confirmLabel: 'Remove', destructive: true)) {
          _toast(await svc.removeFriend(f.username) ?? 'Removed');
        }
      case 'block':
        if (await confirmAction(context,
            title: 'Block ${f.username}?',
            message: 'They cannot send you requests or see your profile. They are not told.',
            confirmLabel: 'Block',
            destructive: true)) {
          _toast(await svc.block(f.username) ?? 'Blocked');
        }
    }
  }

  Future<void> _blockedSheet() async {
    await showAppSheet<void>(context, title: 'Blocked', builder: (_) => const _BlockedList());
  }

  Future<void> _createCrew() async {
    final id = await CreateCrewFlow.open(context);
    if (id != null && mounted) CrewDetailScreen.open(context, id);
  }

  // ---- layout ----
  List<PeopleSegment> _segments(bool friendsOn, bool crewsOn) => [
        if (friendsOn) PeopleSegment.friends,
        if (crewsOn) PeopleSegment.crews,
        PeopleSegment.requests,
      ];

  @override
  Widget build(BuildContext context) {
    // A missing service (older trees, widget tests) hides its part instead of failing.
    final friendsOn = context.featureOn(FriendsService.friendsFlag) && context.watch<FriendsService?>() != null;
    final crewsOn = context.featureOn(CrewsService.crewsFlag) && context.watch<CrewsService?>() != null;
    final badges = peopleBadgesOf(context);
    final segments = _segments(friendsOn, crewsOn);
    // First open: requests waiting come first, so they are never missed.
    // (decided once, so a request arriving later never moves the rider away from what they read).
    _segment ??= badges.requests > 0 ? PeopleSegment.requests : segments.first;
    final current = segments.contains(_segment) ? _segment! : segments.first;
    final searching = friendsOn && _searchState.active;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: DsScreenHeader(
                    title: 'People',
                    onBack: widget.embedded ? null : () => Navigator.maybePop(context),
                    trailing: friendsOn ? DsRoundButton(icon: Icons.ios_share_rounded, label: 'Share my invite link', size: 48, onTap: _shareInvite) : null,
                  ),
                ),
                if (!friendsOn && !crewsOn)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: DsCard(child: Text('Friends and crews are turned off for now.', style: AppText.body)),
                  )
                else ...[
                  if (friendsOn)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                      child: TextField(
                        key: const Key('people_search_field'),
                        controller: _query,
                        focusNode: _queryFocus,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search_rounded),
                          hintText: 'Search by username',
                          suffixIcon: _query.text.isEmpty ? null : IconButton(tooltip: 'Clear search', icon: const Icon(Icons.close_rounded), onPressed: _clearSearch),
                        ),
                        onChanged: (v) {
                          setState(() {}); // the clear button
                          _search.input(v);
                        },
                      ),
                    ),
                  if (!searching && segments.length > 1)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                      child: _SegmentBar(
                        segments: segments,
                        selected: current,
                        badges: badges,
                        onChanged: (s) => setState(() => _segment = s),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: searching
                        ? _searchResults()
                        : RefreshIndicator(
                            onRefresh: _refresh,
                            child: switch (current) {
                              PeopleSegment.friends => _friendsPart(),
                              PeopleSegment.crews => _crewsPart(),
                              PeopleSegment.requests => _requestsPart(friendsOn),
                            },
                          ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static const EdgeInsets _listPadding = EdgeInsets.fromLTRB(20, 8, 20, 28);

  // ---- search ----
  Widget _searchResults() {
    final s = _searchState;
    final svc = context.watch<FriendsService>();
    Widget centered(Widget child) => ListView(padding: _listPadding, children: [const SizedBox(height: 24), child]);
    switch (s.phase) {
      case PeopleSearchPhase.tooShort:
        return centered(Text(s.message ?? '', textAlign: TextAlign.center, style: AppText.caption.copyWith(color: AppTheme.text2)));
      case PeopleSearchPhase.error:
        return centered(_EmptyHint(line: s.message ?? 'Could not search right now', button: 'Try again', onPressed: _search.retry));
      case PeopleSearchPhase.empty:
        return centered(_EmptyHint(line: 'No rider with that username', button: 'Share your invite link', onPressed: _shareInvite));
      case PeopleSearchPhase.loading when s.results.isEmpty:
        return ListView(padding: _listPadding, children: const [SkeletonRows(count: 5, trailing: true)]); // round 7: rows, not a spinner
      default:
        return ListView(
          padding: _listPadding,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            if (s.phase == PeopleSearchPhase.loading) const LinearProgressIndicator(minHeight: 2),
            DsCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Column(
                children: [
                  for (var i = 0; i < s.results.length; i++)
                    PersonRow(
                      username: s.results[i].username,
                      avatarUrl: s.results[i].avatarUrl,
                      relation: svc.relationOf(s.results[i].username, s.results[i].relation),
                      divider: i < s.results.length - 1,
                      onAct: (rel) => _act(s.results[i].username, rel),
                    ),
                ],
              ),
            ),
          ],
        );
    }
  }

  // ---- Friends ----
  Widget _friendsPart() {
    final svc = context.watch<FriendsService>();
    final suggestions = svc.suggestions;
    return ListView(
      padding: _listPadding,
      children: [
        Row(
          children: [
            Expanded(child: DsButton(label: 'Invite link', icon: Icons.ios_share_rounded, tone: DsButtonTone.outline, height: 48, fontSize: 15, onPressed: _shareInvite)),
            const SizedBox(width: Space.s8),
            Expanded(child: DsButton(label: 'Enter code', icon: Icons.pin_outlined, tone: DsButtonTone.outline, height: 48, fontSize: 15, onPressed: _enterCode)),
          ],
        ),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: Space.s24),
          const DsSectionHeader('People you rode with'),
          const SizedBox(height: Space.s12),
          SizedBox(
            height: 168,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: suggestions.length,
              separatorBuilder: (_, _) => const SizedBox(width: Space.s8),
              itemBuilder: (_, i) => _SuggestionCard(
                person: suggestions[i],
                onOpen: () => _profile(suggestions[i].username),
                onAct: () => _act(suggestions[i].username, suggestions[i].relation),
              ),
            ),
          ),
        ],
        const SizedBox(height: Space.s24),
        if (svc.friends.isEmpty)
          _EmptyHint(line: svc.listsLoaded ? 'No friends yet' : 'Loading...', button: 'Share your invite link', onPressed: _shareInvite)
        else ...[
          DsSectionHeader('Friends (${svc.friends.length})'),
          const SizedBox(height: Space.s12),
          DsCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(
              children: [
                for (var i = 0; i < svc.friends.length; i++)
                  PersonRow(
                    username: svc.friends[i].username,
                    avatarUrl: svc.friends[i].avatarUrl,
                    caption: svc.friends[i].trips > 0 ? '${svc.friends[i].trips} ${svc.friends[i].trips == 1 ? 'trip' : 'trips'}' : null,
                    divider: i < svc.friends.length - 1,
                    trailing: IconButton(tooltip: 'More for ${svc.friends[i].username}', icon: const Icon(Icons.more_vert_rounded), onPressed: () => _friendMenu(svc.friends[i])),
                  ),
              ],
            ),
          ),
        ],
        if (svc.blocked.isNotEmpty) ...[
          const SizedBox(height: Space.s16),
          DsCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
            child: DsListRow(icon: Icons.block_rounded, label: 'Blocked', value: '${svc.blocked.length}', divider: false, onTap: _blockedSheet),
          ),
        ],
      ],
    );
  }

  // ---- Crews ----
  Widget _crewsPart() {
    final svc = context.watch<CrewsService>();
    final pollsOn = context.featureOn(CrewsService.pollsFlag);
    final rideCrews = {for (final i in context.watch<RideInvitesService?>()?.pending ?? const <RideInvite>[]) i.crewId};
    return ListView(
      padding: _listPadding,
      children: [
        if (svc.crews.isEmpty)
          _EmptyHint(line: svc.loaded ? 'No crews yet' : 'Loading...', button: 'Create crew', onPressed: _createCrew)
        else ...[
          DsButton(key: const Key('people_create_crew'), label: 'Create crew', icon: Icons.group_add_rounded, onPressed: _createCrew),
          const SizedBox(height: Space.s16),
          for (final c in svc.crews)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s8),
              child: DsCard(
                onTap: () => CrewDetailScreen.open(context, c.crewId),
                semanticsLabel: 'Crew ${c.name}',
                child: Row(
                  children: [
                    DsAvatar(avatarInitials(c.name), size: 48, filled: true),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(c.name, style: AppText.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          Text(
                            [
                              '${c.memberCount} ${c.memberCount == 1 ? 'rider' : 'riders'}',
                              ?crewHint(
                                pendingVotes: pollsOn ? c.pendingVotes : 0,
                                openPolls: pollsOn ? c.openPolls : 0,
                                nextPollClosesAt: c.nextPollClosesAt,
                                rideInvite: rideCrews.contains(c.crewId),
                              ),
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.caption.copyWith(color: AppTheme.text2),
                          ),
                        ],
                      ),
                    ),
                    if (pollsOn && c.pendingVotes > 0) Badge(label: Text(PeopleBadges.label(c.pendingVotes))),
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }

  // ---- Requests ----
  Widget _requestsPart(bool friendsOn) {
    final friends = context.watch<FriendsService?>();
    final crews = context.watch<CrewsService?>();
    final rides = context.watch<RideInvitesService?>();
    final crewsOn = crews != null && context.featureOn(CrewsService.crewsFlag);
    final ridesOn = crewsOn && context.featureOn(RideInvitesService.flag);
    final all = mergeRequests(
      friendIncoming: friendsOn ? friends?.incoming ?? const [] : const [],
      friendSent: friendsOn ? friends?.outgoing ?? const [] : const [],
      crewInvites: crewsOn ? crews.invites.map((i) => i.asRequest) : const [],
      rideInvites: ridesOn ? rides?.pending ?? const [] : const [],
    );
    final incoming = all.where((r) => r.incoming).toList();
    final sent = all.where((r) => !r.incoming).toList();
    return ListView(
      padding: _listPadding,
      children: [
        if (all.isEmpty)
          _EmptyHint(
            line: 'No requests right now',
            button: friendsOn ? 'Search by username' : null,
            onPressed: () => _queryFocus.requestFocus(),
          ),
        for (final r in incoming)
          _RequestTile(
            key: ValueKey(r.key),
            item: r,
            onProfile: () => _profile(r.username),
            onAccept: () => switch (r.kind) {
              RequestKind.friend => _answerFriend(r.id, r.username, true),
              RequestKind.crew => _answerCrew(r, true),
              RequestKind.ride => RideInviteScreen.open(context, r.id),
            },
            onDecline: () => switch (r.kind) {
              RequestKind.friend => _answerFriend(r.id, r.username, false),
              RequestKind.crew => _answerCrew(r, false),
              RequestKind.ride => _declineRide(r),
            },
          ),
        if (sent.isNotEmpty) ...[
          SizedBox(height: incoming.isEmpty ? 0 : Space.s16),
          DsSectionHeader('Sent (${sent.length})'),
          const SizedBox(height: Space.s12),
          for (final r in sent) _RequestTile(key: ValueKey(r.key), item: r, onProfile: () => _profile(r.username), onDecline: () => _cancelSent(r)),
        ],
      ],
    );
  }
}

/// Friends · Crews · Requests, each with its own badge.
class _SegmentBar extends StatelessWidget {
  final List<PeopleSegment> segments;
  final PeopleSegment selected;
  final PeopleBadges badges;
  final ValueChanged<PeopleSegment> onChanged;
  const _SegmentBar({required this.segments, required this.selected, required this.badges, required this.onChanged});

  static String _label(PeopleSegment s) => switch (s) {
        PeopleSegment.friends => 'Friends',
        PeopleSegment.crews => 'Crews',
        PeopleSegment.requests => 'Requests',
      };

  int _count(PeopleSegment s) => switch (s) {
        PeopleSegment.friends => 0,
        PeopleSegment.crews => badges.crews,
        PeopleSegment.requests => badges.requests,
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: AppTheme.card, borderRadius: BorderRadius.circular(Radii.md), border: Border.all(color: AppTheme.border)),
      child: Row(
        children: [
          for (final s in segments)
            Expanded(
              child: Semantics(
                selected: s == selected,
                button: true,
                label: _count(s) > 0 ? '${_label(s)}, ${_count(s)} new' : _label(s),
                excludeSemantics: true,
                child: Material(
                  key: Key('people_segment_${s.name}'),
                  color: s == selected ? AppTheme.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(Radii.sm),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(Radii.sm),
                    onTap: () => onChanged(s),
                    child: SizedBox(
                      height: 44,
                      child: Center(
                        child: Badge(
                          isLabelVisible: _count(s) > 0,
                          offset: const Offset(14, -6),
                          label: Text(PeopleBadges.label(_count(s))),
                          child: Text(
                            _label(s),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: s == selected ? AppTheme.onPrimary : AppTheme.text, fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A rider row: picture + username (tap opens the profile) and the relationship chip (one tap Add /
/// Accept), or a custom [trailing].
class PersonRow extends StatelessWidget {
  final String username;
  final String? avatarUrl;
  final String? caption;
  final String? relation;
  final Future<void> Function(String relation)? onAct;
  final Widget? trailing;
  final bool divider;
  const PersonRow({super.key, required this.username, this.avatarUrl, this.caption, this.relation, this.onAct, this.trailing, this.divider = true});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(border: divider ? Border(bottom: BorderSide(color: AppTheme.border)) : null),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => RiderProfileScreen.open(context, username),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    UserAvatar(label: username, avatarUrl: avatarUrl, size: 44),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(username, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 16)),
                          if (caption != null) Text(caption!, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppTheme.text2)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (relation != null) ...[const SizedBox(width: 8), RelationButton(relation: relation!, onTap: onAct == null ? null : () => onAct!(relation!))],
          ?trailing,
        ],
      ),
    );
  }
}

/// Friend / Requested / Accept / Add: filled when one tap does something.
class RelationButton extends StatefulWidget {
  final String relation;
  final Future<void> Function()? onTap;
  const RelationButton({super.key, required this.relation, this.onTap});

  @override
  State<RelationButton> createState() => _RelationButtonState();
}

class _RelationButtonState extends State<RelationButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final chip = RelationChip.of(widget.relation);
    if (!chip.actionable || widget.onTap == null) return DsChip(chip.label);
    return SizedBox(
      height: 40,
      child: FilledButton(
        onPressed: _busy
            ? null
            : () async {
                setState(() => _busy = true);
                await widget.onTap!();
                if (mounted) setState(() => _busy = false);
              },
        child: Text(chip.label),
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  final PersonCard person;
  final VoidCallback onOpen;
  final Future<void> Function() onAct;
  const _SuggestionCard({required this.person, required this.onOpen, required this.onAct});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 132,
      child: DsCard(
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
        child: Column(
          children: [
            InkWell(
              onTap: onOpen,
              child: Column(
                children: [
                  UserAvatar(label: person.username, avatarUrl: person.avatarUrl, size: 52),
                  const SizedBox(height: 6),
                  Text(person.username, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                  Text(person.rides <= 1 ? '1 ride' : '${person.rides} rides', style: AppText.caption.copyWith(color: AppTheme.text2)),
                ],
              ),
            ),
            const Spacer(),
            RelationButton(relation: person.relation, onTap: onAct),
          ],
        ),
      ),
    );
  }
}

/// One request: big Accept / Decline (Join for crews, Open for rides), swipe right to accept and
/// left to decline; sent requests have Cancel.
class _RequestTile extends StatefulWidget {
  final RequestItem item;
  final VoidCallback onProfile;
  final Future<void> Function()? onAccept;
  final Future<void> Function() onDecline;
  const _RequestTile({super.key, required this.item, required this.onProfile, required this.onDecline, this.onAccept});

  @override
  State<_RequestTile> createState() => _RequestTileState();
}

class _RequestTileState extends State<_RequestTile> {
  bool _busy = false;

  Future<void> _run(Future<void> Function()? f) async {
    if (f == null || _busy) return;
    setState(() => _busy = true);
    await f();
    if (mounted) setState(() => _busy = false);
  }

  String get _acceptLabel => switch (widget.item.kind) {
        RequestKind.friend => 'Accept',
        RequestKind.crew => 'Join',
        RequestKind.ride => 'Open',
      };

  @override
  Widget build(BuildContext context) {
    final r = widget.item;
    final crewOrRide = r.kind != RequestKind.friend;
    final card = DsCard(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: widget.onProfile,
                child: crewOrRide && r.username.isEmpty
                    ? DsAvatar(avatarInitials(r.title), size: 44, filled: true)
                    : UserAvatar(label: r.username, avatarUrl: r.avatarUrl, size: 44, heroTag: crewOrRide ? null : AppHero.avatar(r.username)), // round 7: a rider's picture flies to the profile (riders are unique in the results)
              ),
              const SizedBox(width: 12),
              Expanded(
                child: InkWell(
                  onTap: widget.onProfile,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 16)),
                      Text(crewOrRide && r.username.isNotEmpty ? '${r.subtitle} · ${r.username}' : r.subtitle,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppTheme.text2)),
                    ],
                  ),
                ),
              ),
              if (!r.incoming) TextButton(onPressed: _busy ? null : () => _run(widget.onDecline), child: const Text('Cancel')),
            ],
          ),
          if (r.incoming) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: DsButton(label: 'Decline', tone: DsButtonTone.outline, height: 48, fontSize: 15, onPressed: _busy ? null : () => _run(widget.onDecline))),
                const SizedBox(width: Space.s8),
                Expanded(child: DsButton(label: _acceptLabel, height: 48, fontSize: 15, onPressed: _busy ? null : () => _run(widget.onAccept))),
              ],
            ),
          ],
        ],
      ),
    );
    final canAcceptBySwipe = r.incoming && r.kind != RequestKind.ride;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s8),
      child: Dismissible(
        key: ValueKey('swipe_${r.key}'),
        direction: canAcceptBySwipe ? DismissDirection.horizontal : DismissDirection.endToStart,
        background: _swipeBg(_acceptLabel, Icons.check_rounded, Alignment.centerLeft, AppTheme.primary, AppTheme.onPrimary),
        secondaryBackground: _swipeBg(r.incoming ? 'Decline' : 'Cancel', Icons.close_rounded, Alignment.centerRight, AppTheme.card, AppTheme.text),
        // The row leaves when the service list changes; the swipe itself only runs the action.
        confirmDismiss: (dir) async {
          await _run(dir == DismissDirection.startToEnd ? widget.onAccept : widget.onDecline);
          return false;
        },
        child: card,
      ),
    );
  }

  Widget _swipeBg(String label, IconData icon, Alignment align, Color bg, Color fg) => Container(
        alignment: align,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.lg), border: Border.all(color: AppTheme.border)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [Icon(icon, color: fg), const SizedBox(width: 6), Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w600))],
        ),
      );
}

/// One line and one button, for an empty part.
class _EmptyHint extends StatelessWidget {
  final String line;
  final String? button;
  final VoidCallback? onPressed;
  const _EmptyHint({required this.line, this.button, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(line, textAlign: TextAlign.center, style: AppText.body.copyWith(color: AppTheme.text2)),
          if (button != null && onPressed != null) ...[
            const SizedBox(height: Space.s16),
            DsButton(label: button!, onPressed: onPressed),
          ],
        ],
      ),
    );
  }
}

class _BlockedList extends StatelessWidget {
  const _BlockedList();

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<FriendsService>();
    if (svc.blocked.isEmpty) return Padding(padding: const EdgeInsets.all(16), child: Text('Nobody is blocked.', style: AppText.body));
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < svc.blocked.length; i++)
          DsListRow(
            icon: Icons.block_rounded,
            label: svc.blocked[i],
            divider: i < svc.blocked.length - 1,
            trailing: TextButton(onPressed: () => svc.unblock(svc.blocked[i]), child: const Text('Unblock')),
          ),
      ],
    );
  }
}

class _InviteCodeForm extends StatefulWidget {
  const _InviteCodeForm();

  @override
  State<_InviteCodeForm> createState() => _InviteCodeFormState();
}

class _InviteCodeFormState extends State<_InviteCodeForm> {
  final _ctrl = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    final r = await context.read<FriendsService>().sendRequest(_ctrl.text, byCode: true);
    if (!mounted) return;
    setState(() => _sending = false);
    if (!r.ok) return setState(() => _error = r.error);
    Navigator.pop(context, r.confirmation);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _ctrl,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            maxLength: 12,
            decoration: InputDecoration(labelText: 'Invite code', errorText: _error),
            onSubmitted: (_) => _sending ? null : _send(),
          ),
          const SizedBox(height: 8),
          DsButton(label: _sending ? 'Sending...' : 'Send request', onPressed: _sending ? null : _send),
        ],
      ),
    );
  }
}
