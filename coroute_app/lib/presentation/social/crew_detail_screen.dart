import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/crews_service.dart';
import '../../data/services/feature_flags_service.dart';
import '../../domain/social/crew_rules.dart';
import '../widgets/feature_switch.dart';
import '../../data/services/ride_invites_service.dart';
import '../../domain/social/ride_invite_rules.dart';
import 'crew_create_flow.dart';
import 'people_screen.dart';
import 'ride_invite_screen.dart';
import 'rider_profile_screen.dart';
import 'user_avatar.dart';

/// 3.55 One crew, in three tabs: Members (invite friends, invites waiting, leave / delete), Polls
/// (live result bars: vote, change, close, delete) and Rides (start a ride with the crew, ride
/// invites from it). Settings for the admin. No chat.
class CrewDetailScreen extends StatefulWidget {
  final String crewId;
  const CrewDetailScreen({super.key, required this.crewId});

  static Future<void> open(BuildContext context, String crewId) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => CrewDetailScreen(crewId: crewId)));

  @override
  State<CrewDetailScreen> createState() => _CrewDetailScreenState();
}

enum _CrewTab { members, polls, rides }

class _CrewDetailScreenState extends State<CrewDetailScreen> {
  _CrewTab? _tab;
  CrewDetail? _crew;
  List<CrewPoll> _polls = const [];
  bool _loading = true;
  bool _gone = false;
  StreamSubscription<String>? _sub;
  Timer? _debounce;

  CrewsService get _svc => context.read<CrewsService>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _sub = _svc.changes.where((id) => id == widget.crewId).listen((_) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 400), _load);
      });
      _load();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    try {
      final crew = await _svc.detail(widget.crewId);
      List<CrewPoll> polls = const [];
      if (FeatureFlagsService.on(CrewsService.pollsFlag)) {
        try {
          polls = await _svc.polls(widget.crewId);
        } on ApiException catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _crew = crew;
        _polls = polls;
        _loading = false;
        _gone = false;
        // First open: the polls when one waits for my vote, else the members.
        _tab ??= polls.any((p) => p.open && p.myVote.isEmpty) ? _CrewTab.polls : _CrewTab.members;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _gone = e.statusCode == 404 || e.statusCode == 403;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _say(String? text) {
    if (text == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _after(Future<String?> call, String done) async {
    final err = await call;
    _say(err ?? done);
    await _load();
  }

  /// I run a live group ride (trip owner): "Start a ride" becomes "Invite crew to my ride".
  bool _ownsLiveRide(BuildContext context) {
    final convoys = context.watch<ConvoyService?>();
    final c = convoys?.activeConvoy;
    final me = convoys?.myUserId;
    return c != null && me != null && c.tripStatus != 'ENDED' && c.isTripOwner(me);
  }

  // ---- crew actions ----
  Future<void> _invite(CrewDetail c) async {
    final n = await showAppSheet<int>(
      context,
      title: 'Invite friends',
      isScrollControlled: true,
      builder: (_) => _InvitePicker(service: _svc, crewId: c.crewId),
    );
    if (n != null && n > 0) _say(n == 1 ? 'Invite sent' : '$n invites sent');
    await _load();
  }

  Future<void> _settings(CrewDetail c) async {
    final changed = await showAppSheet<bool>(
      context,
      title: 'Crew settings',
      isScrollControlled: true,
      builder: (_) => _SettingsForm(service: _svc, crew: c),
    );
    if (changed == true) await _load();
  }

  Future<void> _leave(CrewDetail c) async {
    final others = c.members.where((m) => m.role != CrewRoles.admin).toList();
    if (c.isAdmin && others.isNotEmpty) {
      final pick = await showAppSheet<String>(
        context,
        title: 'Hand over the crew',
        isScrollControlled: true,
        builder: (ctx) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Choose who runs the crew after you leave.', style: AppText.body.copyWith(color: AppTheme.text2)),
            const SizedBox(height: 8),
            DsListRow(icon: Icons.auto_mode_rounded, label: 'Choose for me', value: 'oldest co-admin, else oldest member', onTap: () => Navigator.pop(ctx, '')),
            for (final m in others)
              DsListRow(icon: Icons.person_rounded, label: m.username, value: CrewRoles.label(m.role), onTap: () => Navigator.pop(ctx, m.username)),
          ],
        ),
      );
      if (pick == null || !mounted) return;
      final ok = await confirmAction(context,
          title: 'Leave ${c.name}?',
          message: pick.isEmpty ? 'The oldest co-admin (or member) becomes the crew admin.' : '$pick becomes the crew admin.',
          confirmLabel: 'Leave crew',
          destructive: true);
      if (!ok) return;
      final err = await _svc.leave(c.crewId, transferTo: pick.isEmpty ? null : pick);
      if (err != null) return _say(err);
    } else {
      final ok = await confirmAction(context,
          title: 'Leave ${c.name}?',
          message: c.members.length <= 1 ? 'You are the last rider. The crew and its polls are deleted.' : 'You can join again if someone invites you.',
          confirmLabel: 'Leave crew',
          destructive: true);
      if (!ok) return;
      final err = await _svc.leave(c.crewId);
      if (err != null) return _say(err);
    }
    if (mounted) Navigator.maybePop(context);
  }

  Future<void> _delete(CrewDetail c) async {
    final ok = await confirmAction(context,
        title: 'Delete ${c.name}?',
        message: 'The crew, its polls and votes are deleted for everyone. This cannot be undone.',
        confirmLabel: 'Delete crew',
        destructive: true);
    if (!ok) return;
    final err = await _svc.deleteCrew(c.crewId);
    if (err != null) return _say(err);
    if (mounted) Navigator.maybePop(context);
  }

  Future<void> _memberActions(CrewDetail c, CrewMember m) async {
    final admin = c.isAdmin && m.role != CrewRoles.admin;
    final choice = await showAppSheet<String>(
      context,
      title: m.username,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DsListRow(icon: Icons.person_rounded, label: 'View profile', divider: admin, onTap: () => Navigator.pop(ctx, 'view')),
          if (admin && m.role == CrewRoles.member)
            DsListRow(
              icon: Icons.shield_outlined,
              label: 'Make co-admin',
              value: '${c.coAdmins} of ${CrewLimits.maxCoAdmins}',
              onTap: () => Navigator.pop(ctx, 'promote'),
            ),
          if (admin && m.role == CrewRoles.coAdmin) DsListRow(icon: Icons.remove_moderator_outlined, label: 'Make member', onTap: () => Navigator.pop(ctx, 'demote')),
          if (admin) DsListRow(icon: Icons.swap_horiz_rounded, label: 'Hand over the crew', onTap: () => Navigator.pop(ctx, 'transfer')),
          if (admin) DsListRow(icon: Icons.person_remove_rounded, label: 'Remove from crew', divider: false, onTap: () => Navigator.pop(ctx, 'remove')),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'view':
        RiderProfileScreen.open(context, m.username);
      case 'promote':
        await _after(_svc.setRole(c.crewId, m.username, CrewRoles.coAdmin), '${m.username} is now a co-admin');
      case 'demote':
        await _after(_svc.setRole(c.crewId, m.username, CrewRoles.member), '${m.username} is now a member');
      case 'transfer':
        if (await confirmAction(context,
            title: 'Hand over to ${m.username}?',
            message: '${m.username} becomes the crew admin. You stay in the crew as a co-admin (or member).',
            confirmLabel: 'Hand over')) {
          await _after(_svc.transfer(c.crewId, m.username), '${m.username} is now the crew admin');
        }
      case 'remove':
        if (await confirmAction(context,
            title: 'Remove ${m.username}?',
            message: 'They leave the crew and are told. You can invite them again later.',
            confirmLabel: 'Remove',
            destructive: true)) {
          await _after(_svc.removeMember(c.crewId, m.username), 'Removed');
        }
    }
  }

  // ---- polls ----
  Future<void> _newPoll(CrewDetail c) async {
    final err = await showAppSheet<bool>(
      context,
      title: 'New poll',
      isScrollControlled: true,
      builder: (_) => CreatePollForm(service: _svc, crewId: c.crewId),
    );
    if (err == true) {
      _say('Poll started');
      await _load();
    }
  }

  Future<void> _vote(CrewPoll p, List<String> ids) async {
    final (updated, err) = await _svc.vote(widget.crewId, p, ids);
    if (err != null) return _say(err);
    if (updated != null && mounted) setState(() => _polls = [for (final x in _polls) x.pollId == updated.pollId ? updated : x]);
  }

  Future<void> _pollMenu(CrewPoll p) async {
    final choice = await showAppSheet<String>(
      context,
      title: 'Poll',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (p.open && p.myVote.isNotEmpty) DsListRow(icon: Icons.undo_rounded, label: 'Remove my vote', onTap: () => Navigator.pop(ctx, 'retract')),
          if (p.canClose) DsListRow(icon: Icons.lock_outline_rounded, label: 'Close poll now', onTap: () => Navigator.pop(ctx, 'close')),
          if (p.canDelete) DsListRow(icon: Icons.delete_outline_rounded, label: 'Delete poll', divider: false, onTap: () => Navigator.pop(ctx, 'delete')),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'retract':
        await _after(_svc.retractVote(widget.crewId, p.pollId), 'Vote removed');
      case 'close':
        if (await confirmAction(context, title: 'Close this poll?', message: 'Nobody can vote or change their vote after this. Results stay.', confirmLabel: 'Close poll')) {
          await _after(_svc.closePoll(widget.crewId, p.pollId), 'Poll closed');
        }
      case 'delete':
        if (await confirmAction(context, title: 'Delete this poll?', message: 'The poll and its votes are deleted for everyone.', confirmLabel: 'Delete', destructive: true)) {
          await _after(_svc.deletePoll(widget.crewId, p.pollId), 'Poll deleted');
        }
    }
  }

  List<_CrewTab> _tabs(BuildContext context) => [
        _CrewTab.members,
        if (context.featureOn(CrewsService.pollsFlag)) _CrewTab.polls,
        if (context.featureOn('crewRides')) _CrewTab.rides,
      ];

  static String _tabLabel(_CrewTab t) => switch (t) {
        _CrewTab.members => 'Members',
        _CrewTab.polls => 'Polls',
        _CrewTab.rides => 'Rides',
      };

  @override
  Widget build(BuildContext context) {
    final c = _crew;
    final tabs = _tabs(context);
    final tab = _tab != null && tabs.contains(_tab) ? _tab! : _CrewTab.members;
    final toVote = _polls.where((p) => p.open && p.myVote.isEmpty).length;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: dsScreenPadding,
                children: [
                  DsScreenHeader(
                    title: c?.name ?? 'Crew',
                    subtitle: c == null ? null : '${c.members.length} ${c.members.length == 1 ? 'rider' : 'riders'} · ${CrewRoles.label(c.myRole)}',
                    onBack: () => Navigator.maybePop(context),
                    trailing: c == null
                        ? null
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (c.canInvite) DsRoundButton(icon: Icons.person_add_alt_1_rounded, label: 'Invite friends', size: 48, onTap: () => _invite(c)),
                              if (c.isAdmin) ...[
                                const SizedBox(width: 8),
                                DsRoundButton(icon: Icons.tune_rounded, label: 'Crew settings', size: 48, onTap: () => _settings(c)),
                              ],
                            ],
                          ),
                  ),
                  const SizedBox(height: 18),
                  if (_loading && c == null)
                    const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
                  else if (_gone || c == null)
                    DsCard(child: Text(_gone ? 'You are not in this crew any more.' : 'This crew could not be loaded. Pull down to try again.', style: AppText.body))
                  else ...[
                    if (c.description.isNotEmpty) ...[
                      Text(c.description, style: AppText.body.copyWith(color: AppTheme.text2)),
                      const SizedBox(height: Space.s16),
                    ],
                    if (tabs.length > 1) ...[
                      DsSegment<_CrewTab>(
                        values: tabs,
                        selected: tab,
                        label: (t) => t == _CrewTab.polls && toVote > 0 ? 'Polls ($toVote)' : _tabLabel(t),
                        onChanged: (t) => setState(() => _tab = t),
                      ),
                      const SizedBox(height: Space.s16),
                    ],
                    ...switch (tab) {
                      _CrewTab.members => _membersTab(c),
                      _CrewTab.polls => _pollsTab(c),
                      _CrewTab.rides => _ridesTab(c),
                    },
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _membersTab(CrewDetail c) => [
        if (c.canInvite) ...[
          DsButton(key: const Key('crew_invite_friends'), label: 'Invite friends', icon: Icons.person_add_alt_1_rounded, onPressed: () => _invite(c)),
          const SizedBox(height: Space.s16),
        ],
        DsCard(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            children: [
              for (var i = 0; i < c.members.length; i++)
                _MemberRow(
                  member: c.members[i],
                  divider: i < c.members.length - 1,
                  onTap: () => RiderProfileScreen.open(context, c.members[i].username),
                  onMore: c.isAdmin && c.members[i].role != CrewRoles.admin ? () => _memberActions(c, c.members[i]) : null,
                ),
            ],
          ),
        ),
        if (c.canInvite && c.invites.isNotEmpty) ...[
          const SizedBox(height: Space.s24),
          DsSectionHeader('Invited (${c.invites.length})'),
          const SizedBox(height: Space.s12),
          DsCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(
              children: [
                for (var i = 0; i < c.invites.length; i++)
                  DsListRow(
                    label: c.invites[i].username,
                    value: 'Waiting',
                    divider: i < c.invites.length - 1,
                    trailing: TextButton(
                      onPressed: () => _after(_svc.cancelInvite(c.crewId, c.invites[i].inviteId), 'Invite cancelled'),
                      child: const Text('Cancel'),
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: Space.s24),
        DsButton(label: 'Leave crew', icon: Icons.logout_rounded, tone: DsButtonTone.outline, onPressed: () => _leave(c)),
        if (c.isAdmin) ...[
          const SizedBox(height: Space.s12),
          DsButton(label: 'Delete crew', icon: Icons.delete_outline_rounded, tone: DsButtonTone.sos, onPressed: () => _delete(c)),
        ],
      ];

  List<Widget> _pollsTab(CrewDetail c) {
    final open = _polls.where((p) => p.open).toList();
    final closed = _polls.where((p) => !p.open).toList();
    return [
      if (c.canCreatePoll) ...[
        DsButton(label: 'New poll', icon: Icons.add_rounded, tone: DsButtonTone.outline, onPressed: () => _newPoll(c)),
        const SizedBox(height: Space.s16),
      ],
      if (_polls.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.s16),
          child: Text(c.canCreatePoll ? 'No polls yet. Ask the crew where or when to ride.' : 'No polls yet.',
              textAlign: TextAlign.center, style: AppText.body.copyWith(color: AppTheme.text2)),
        ),
      for (final p in open) PollCard(poll: p, onVote: (ids) => _vote(p, ids), onMore: () => _pollMenu(p)),
      if (closed.isNotEmpty) ...[
        const SizedBox(height: Space.s8),
        Text('Closed', style: AppText.label.copyWith(color: AppTheme.text2)),
        const SizedBox(height: Space.s8),
        for (final p in closed) PollCard(poll: p, onVote: null, onMore: p.canDelete ? () => _pollMenu(p) : null),
      ],
    ];
  }

  List<Widget> _ridesTab(CrewDetail c) {
    final invites = (context.watch<RideInvitesService?>()?.pending ?? const <RideInvite>[]).where((i) => i.crewId == c.crewId).toList();
    return [
      // 3.55 "Start a ride with this crew": any member can host (the plan rules decide the seats).
      DsButton(
        label: _ownsLiveRide(context) ? 'Invite crew to my ride' : 'Start a ride',
        icon: Icons.two_wheeler_rounded,
        onPressed: () => startRideWithCrew(context, crewId: c.crewId, crewName: c.name),
      ),
      const SizedBox(height: Space.s16),
      if (invites.isEmpty)
        Text('Start a ride and the crew gets an invite to join.', textAlign: TextAlign.center, style: AppText.body.copyWith(color: AppTheme.text2))
      else
        for (final i in invites)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s8),
            child: DsCard(
              onTap: () => RideInviteScreen.open(context, i.inviteId),
              semanticsLabel: 'Ride invite from ${i.hostUsername}',
              child: Row(
                children: [
                  UserAvatar(label: i.hostUsername, avatarUrl: i.hostAvatarUrl, size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(i.rideName.isNotEmpty ? i.rideName : 'Group ride', style: AppText.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text('${i.hostUsername} invited you', style: AppText.caption.copyWith(color: AppTheme.text2)),
                      ],
                    ),
                  ),
                  const DsChip('Open'),
                ],
              ),
            ),
          ),
    ];
  }
}

class _MemberRow extends StatelessWidget {
  final CrewMember member;
  final bool divider;

  /// Opens the member's profile.
  final VoidCallback onTap;

  /// Admin actions (null when there are none for me).
  final VoidCallback? onMore;
  const _MemberRow({required this.member, required this.divider, required this.onTap, this.onMore});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      decoration: BoxDecoration(border: divider ? Border(bottom: BorderSide(color: AppTheme.border)) : null),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    UserAvatar(label: member.username, avatarUrl: member.avatarUrl, size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(member.username, style: AppText.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          if (member.displayName.isNotEmpty) Text(member.displayName, style: AppText.caption.copyWith(color: AppTheme.text2)),
                        ],
                      ),
                    ),
                    if (member.role != CrewRoles.member) DsChip(member.role == CrewRoles.admin ? 'Admin' : 'Co-admin'),
                  ],
                ),
              ),
            ),
          ),
          if (onMore != null) IconButton(tooltip: 'More for ${member.username}', icon: const Icon(Icons.more_vert_rounded), onPressed: onMore),
        ],
      ),
    );
  }
}

/// One poll: question, meta line, options with result bars. Tap an option to vote (single
/// choice) or tick options and save (multiple choice). [onVote] null = read-only (closed).
class PollCard extends StatefulWidget {
  final CrewPoll poll;
  final ValueChanged<List<String>>? onVote;
  final VoidCallback? onMore;
  const PollCard({super.key, required this.poll, required this.onVote, this.onMore});

  @override
  State<PollCard> createState() => _PollCardState();
}

class _PollCardState extends State<PollCard> {
  Set<String>? _picked;
  bool _showVoters = false;

  @override
  void didUpdateWidget(covariant PollCard old) {
    super.didUpdateWidget(old);
    if (old.poll.myVote.join(',') != widget.poll.myVote.join(',')) _picked = null;
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.poll;
    final canVote = p.open && widget.onVote != null;
    final picked = _picked ?? p.myVote.toSet();
    final dirty = p.multi && _picked != null && _picked!.join(',') != p.myVote.toSet().join(',');
    final meta = [
      p.multi ? 'Multiple choice' : 'One answer',
      p.anonymous ? 'Anonymous votes' : 'Names shown to the crew',
      CrewRules.closesLabel(DateTime.fromMillisecondsSinceEpoch(p.closesAt), closed: !p.open),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s12),
      child: DsCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: Text(p.question, style: AppText.title)),
                if (widget.onMore != null) IconButton(tooltip: 'Poll options', icon: const Icon(Icons.more_vert_rounded), onPressed: widget.onMore),
              ],
            ),
            Text(meta, style: AppText.caption.copyWith(color: AppTheme.text2)),
            const SizedBox(height: 10),
            for (final o in p.options)
              _OptionBar(
                option: o,
                fill: p.fill(o.id),
                mine: picked.contains(o.id),
                leader: !p.open && p.leaders.contains(o.id),
                multi: p.multi,
                voters: p.anonymous || !_showVoters ? const [] : (p.voters[o.id] ?? const []),
                onTap: !canVote
                    ? null
                    : () {
                        if (p.multi) {
                          setState(() {
                            final next = {...picked};
                            if (!next.remove(o.id)) next.add(o.id);
                            _picked = next;
                          });
                        } else if (!p.myVote.contains(o.id)) {
                          widget.onVote!([o.id]);
                        }
                      },
              ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text('${p.totalVoters} ${p.totalVoters == 1 ? 'vote' : 'votes'}${p.createdBy == null ? '' : ' · by ${p.createdBy}'}',
                      style: AppText.caption.copyWith(color: AppTheme.text2)),
                ),
                if (!p.anonymous && p.totalVoters > 0)
                  TextButton(onPressed: () => setState(() => _showVoters = !_showVoters), child: Text(_showVoters ? 'Hide names' : 'Who voted')),
              ],
            ),
            if (dirty)
              DsButton(
                label: picked.isEmpty ? 'Pick at least one' : 'Save my vote',
                height: 48,
                onPressed: picked.isEmpty ? null : () => widget.onVote!([for (final o in p.options) if (picked.contains(o.id)) o.id]),
              ),
          ],
        ),
      ),
    );
  }
}

class _OptionBar extends StatelessWidget {
  final PollOption option;
  final double fill;
  final bool mine;
  final bool leader;
  final bool multi;
  final List<String> voters;
  final VoidCallback? onTap;
  const _OptionBar({required this.option, required this.fill, required this.mine, required this.leader, required this.multi, required this.voters, this.onTap});

  @override
  Widget build(BuildContext context) {
    final icon = multi
        ? (mine ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded)
        : (mine ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded);
    return Semantics(
      button: onTap != null,
      selected: mine,
      label: '${option.text}, ${option.count} ${option.count == 1 ? 'vote' : 'votes'}, ${option.percent} percent',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: mine ? AppTheme.accentText : AppTheme.border, width: mine ? 2 : 1),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: AnimatedFractionallySizedBox(
                        duration: const Duration(milliseconds: 300),
                        widthFactor: fill.clamp(0, 1).toDouble(),
                        heightFactor: 1,
                        child: ColoredBox(color: AppTheme.tint),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(icon, size: 20, color: mine ? AppTheme.accentText : AppTheme.text2),
                          const SizedBox(width: 8),
                          Expanded(child: Text(option.text, style: AppText.body.copyWith(fontWeight: leader ? FontWeight.w700 : null))),
                          Text('${option.percent}%', style: AppText.label),
                        ],
                      ),
                      if (voters.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 28, top: 4),
                          child: Text(voters.join(', '), style: AppText.caption.copyWith(color: AppTheme.text2)),
                        ),
                    ],
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

/// New poll sheet: question, 2-6 options, one / multiple answers, anonymous, closes in, and the
/// "Ride date" template. Pops true when the poll was started.
class CreatePollForm extends StatefulWidget {
  final CrewsService service;
  final String crewId;
  const CreatePollForm({super.key, required this.service, required this.crewId});

  @override
  State<CreatePollForm> createState() => _CreatePollFormState();
}

class _CreatePollFormState extends State<CreatePollForm> {
  static const List<(String, Duration)> _durations = [
    ('1 day', Duration(days: 1)),
    ('3 days', Duration(days: 3)),
    ('1 week', Duration(days: 7)),
    ('2 weeks', Duration(days: 14)),
    ('30 days', Duration(days: 30)),
  ];
  final _question = TextEditingController();
  final List<TextEditingController> _options = [TextEditingController(), TextEditingController()];
  bool _multi = false;
  bool _anonymous = false;
  Duration _duration = CrewLimits.pollDefault;
  String? _template;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _question.dispose();
    for (final c in _options) {
      c.dispose();
    }
    super.dispose();
  }

  void _useTemplate() {
    final t = CrewRules.rideDateTemplate(DateTime.now());
    setState(() {
      _template = 'RIDE_DATE_PLACE';
      _question.text = t.question;
      for (final c in _options) {
        c.dispose();
      }
      _options
        ..clear()
        ..addAll(t.options.map((o) => TextEditingController(text: o)));
    });
  }

  Future<void> _send() async {
    final options = _options.map((c) => c.text).toList();
    final err = CrewRules.checkPoll(question: _question.text, options: options);
    if (err != null) return setState(() => _error = err);
    setState(() {
      _busy = true;
      _error = null;
    });
    final res = await widget.service.createPoll(widget.crewId,
        question: _question.text, options: options, multi: _multi, anonymous: _anonymous, duration: _duration, template: _template);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res != null) return setState(() => _error = res);
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: _useTemplate, icon: const Icon(Icons.event_rounded), label: const Text('Use "Ride date" template')),
            ),
            TextField(
              controller: _question,
              maxLength: CrewLimits.questionMax,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Question'),
            ),
            for (var i = 0; i < _options.length; i++)
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _options[i],
                      maxLength: CrewLimits.optionMax,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(labelText: 'Option ${i + 1}'),
                    ),
                  ),
                  if (_options.length > CrewLimits.optionsMin)
                    IconButton(
                      tooltip: 'Remove option',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => setState(() => _options.removeAt(i).dispose()),
                    ),
                ],
              ),
            if (_options.length < CrewLimits.optionsMax)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _options.add(TextEditingController())),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add option'),
                ),
              ),
            const SizedBox(height: 8),
            DsSegment<bool>(
              values: const [false, true],
              selected: _multi,
              label: (v) => v ? 'Multiple answers' : 'One answer',
              onChanged: (v) => setState(() => _multi = v),
            ),
            DsSwitchRow(
              label: 'Anonymous votes',
              subtitle: 'Off: the crew sees who voted for what.',
              value: _anonymous,
              onChanged: (v) => setState(() => _anonymous = v),
            ),
            const SizedBox(height: 8),
            Text('Closes in', style: AppText.label),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final d in _durations)
                  ChoiceChip(label: Text(d.$1), selected: _duration == d.$2, onSelected: (_) => setState(() => _duration = d.$2)),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: AppText.body.copyWith(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 12),
            DsButton(label: _busy ? 'Starting...' : 'Start poll', onPressed: _busy ? null : _send),
          ],
        ),
      ),
    );
  }
}

/// Invite picker: only my friends; members and already-invited friends are shown but not pickable.
class _InvitePicker extends StatefulWidget {
  final CrewsService service;
  final String crewId;
  const _InvitePicker({required this.service, required this.crewId});

  @override
  State<_InvitePicker> createState() => _InvitePickerState();
}

class _InvitePickerState extends State<_InvitePicker> {
  List<InvitableFriend>? _friends;
  final Set<String> _picked = {};
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.service.invitable(widget.crewId).then((f) {
      if (mounted) setState(() => _friends = f);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : 'Could not load your friends.');
    });
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final (n, err) = await widget.service.invite(widget.crewId, _picked.toList());
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null && n == 0) return setState(() => _error = err);
    Navigator.pop(context, n);
  }

  @override
  Widget build(BuildContext context) {
    final f = _friends;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (f == null && _error == null)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (f != null && f.isEmpty) ...[
            Text('No friends yet.', style: AppText.body),
            const SizedBox(height: 8),
            DsButton(
              label: 'Find friends',
              tone: DsButtonTone.outline,
              onPressed: () {
                final nav = Navigator.of(context);
                nav.pop();
                PeopleScreen.open(nav.context, segment: PeopleSegment.friends);
              },
            ),
          ] else if (f != null)
            Flexible(
              child: FriendPickerList(
                friends: [
                  for (final fr in f)
                    PickableFriend(
                      username: fr.username,
                      avatarUrl: fr.avatarUrl,
                      lockedReason: fr.available ? null : (fr.status == 'MEMBER' ? 'In the crew' : 'Invited'),
                    ),
                ],
                picked: _picked,
                onChanged: (s) => setState(() {
                  _picked
                    ..clear()
                    ..addAll(s);
                }),
              ),
            ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: AppText.body.copyWith(color: Theme.of(context).colorScheme.error)),
          ],
          if (f != null && f.isNotEmpty) ...[
            const SizedBox(height: 8),
            DsButton(
              label: _busy ? 'Sending...' : (_picked.isEmpty ? 'Pick friends' : 'Invite ${_picked.length}'),
              onPressed: _busy || _picked.isEmpty ? null : _send,
            ),
          ],
        ],
      ),
    );
  }
}

class _SettingsForm extends StatefulWidget {
  final CrewsService service;
  final CrewDetail crew;
  const _SettingsForm({required this.service, required this.crew});

  @override
  State<_SettingsForm> createState() => _SettingsFormState();
}

class _SettingsFormState extends State<_SettingsForm> {
  late final _name = TextEditingController(text: widget.crew.name);
  late final _desc = TextEditingController(text: widget.crew.description);
  late bool _membersPolls = widget.crew.membersCanCreatePolls;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final err = CrewRules.checkName(_name.text) ?? CrewRules.checkDescription(_desc.text);
    if (err != null) return setState(() => _error = err);
    setState(() => _busy = true);
    final res = await widget.service.update(widget.crew.crewId, name: _name.text, description: _desc.text, membersCanCreatePolls: _membersPolls);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res != null) return setState(() => _error = res);
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(controller: _name, maxLength: CrewLimits.nameMax, decoration: InputDecoration(labelText: 'Crew name', errorText: _error)),
          TextField(controller: _desc, maxLength: CrewLimits.descriptionMax, maxLines: 3, minLines: 1, decoration: const InputDecoration(labelText: 'Description')),
          if (context.featureOn(CrewsService.pollsFlag))
            DsSwitchRow(
              label: 'Members can create polls',
              subtitle: 'Off: only you and co-admins start polls.',
              value: _membersPolls,
              divider: false,
              onChanged: (v) => setState(() => _membersPolls = v),
            ),
          const SizedBox(height: 8),
          DsButton(label: _busy ? 'Saving...' : 'Save', onPressed: _busy ? null : _save),
        ],
      ),
    );
  }
}
