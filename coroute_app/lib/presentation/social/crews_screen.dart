import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/crews_service.dart';
import '../../domain/social/crew_rules.dart';
import '../../domain/social/username_rules.dart';
import '../widgets/feature_switch.dart';
import 'crew_detail_screen.dart';
import 'user_avatar.dart';

/// 3.55 Crews: my crews, invitations to accept or decline, and "Create a crew".
/// A crew is a standing circle of riding friends (not a live ride). No chat: polls only.
class CrewsScreen extends StatefulWidget {
  const CrewsScreen({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => const CrewsScreen()));

  @override
  State<CrewsScreen> createState() => _CrewsScreenState();
}

class _CrewsScreenState extends State<CrewsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<CrewsService>().refresh();
    });
  }

  void _say(String? text) {
    if (text == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _create(CrewsService svc) async {
    final crewId = await showAppSheet<String>(
      context,
      title: 'Create a crew',
      isScrollControlled: true,
      builder: (_) => _CreateCrewForm(service: svc),
    );
    if (crewId != null && mounted) CrewDetailScreen.open(context, crewId);
  }

  Future<void> _answer(CrewsService svc, CrewInvite inv, bool accept) async {
    final err = await svc.respondInvite(inv.inviteId, accept);
    if (err != null) return _say(err);
    if (accept && mounted) {
      _say('You joined ${inv.crewName}');
      CrewDetailScreen.open(context, inv.crewId);
    } else {
      _say('Invite declined');
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<CrewsService>();
    final on = context.featureOn(CrewsService.crewsFlag);
    final pollsOn = context.featureOn(CrewsService.pollsFlag);
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: RefreshIndicator(
              onRefresh: svc.refresh,
              child: ListView(
                padding: dsScreenPadding,
                children: [
                  DsScreenHeader(
                    title: 'Crews',
                    subtitle: 'Your riding friends, with polls to plan rides',
                    onBack: () => Navigator.maybePop(context),
                    trailing: on ? DsRoundButton(icon: Icons.group_add_rounded, label: 'Create a crew', size: 48, onTap: () => _create(svc)) : null,
                  ),
                  const SizedBox(height: 18),
                  if (!on)
                    DsCard(child: Text('Crews are turned off for now.', style: AppText.body))
                  else ...[
                    if (svc.invites.isNotEmpty) ...[
                      DsSectionHeader('Invitations (${svc.invites.length})'),
                      const SizedBox(height: Space.s12),
                      for (final inv in svc.invites)
                        Padding(
                          padding: const EdgeInsets.only(bottom: Space.s8),
                          child: DsCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    UserAvatar(label: inv.invitedBy, avatarUrl: inv.invitedByAvatar, size: 40),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(inv.crewName, style: AppText.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                          Text('${inv.invitedBy} invited you · ${inv.memberCount} ${inv.memberCount == 1 ? 'rider' : 'riders'}',
                                              style: AppText.caption.copyWith(color: AppTheme.text2)),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                if (inv.description.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(inv.description, style: AppText.body),
                                ],
                                const SizedBox(height: 8),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    TextButton(onPressed: () => _answer(svc, inv, false), child: const Text('Decline')),
                                    const SizedBox(width: 8),
                                    FilledButton(onPressed: () => _answer(svc, inv, true), child: const Text('Join crew')),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      const SizedBox(height: Space.s16),
                    ],
                    DsSectionHeader('My crews (${svc.crews.length})'),
                    const SizedBox(height: Space.s12),
                    if (svc.crews.isEmpty)
                      DsCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(svc.loaded ? 'No crews yet.' : 'Loading...', style: AppText.title),
                            const SizedBox(height: 6),
                            Text('Create a crew and invite your friends. Crews have polls to plan rides, and no chat.',
                                style: AppText.body.copyWith(color: AppTheme.text2)),
                            const SizedBox(height: 12),
                            DsButton(label: 'Create a crew', icon: Icons.group_add_rounded, onPressed: () => _create(svc)),
                          ],
                        ),
                      )
                    else
                      for (final c in svc.crews)
                        Padding(
                          padding: const EdgeInsets.only(bottom: Space.s8),
                          child: DsCard(
                            onTap: () => CrewDetailScreen.open(context, c.crewId),
                            semanticsLabel: 'Crew ${c.name}',
                            child: Row(
                              children: [
                                DsAvatar(avatarInitials(c.name), size: 44, filled: true),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(c.name, style: AppText.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                      Text(
                                        '${c.memberCount} ${c.memberCount == 1 ? 'rider' : 'riders'}'
                                        '${c.myRole == CrewRoles.member ? '' : ' · ${CrewRoles.label(c.myRole)}'}',
                                        style: AppText.caption.copyWith(color: AppTheme.text2),
                                      ),
                                    ],
                                  ),
                                ),
                                if (pollsOn && c.pendingVotes > 0)
                                  DsChip('${c.pendingVotes} to vote', warning: true)
                                else if (pollsOn && c.openPolls > 0)
                                  DsChip('${c.openPolls} open'),
                                const Icon(Icons.chevron_right_rounded),
                              ],
                            ),
                          ),
                        ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CreateCrewForm extends StatefulWidget {
  final CrewsService service;
  const _CreateCrewForm({required this.service});

  @override
  State<_CreateCrewForm> createState() => _CreateCrewFormState();
}

class _CreateCrewFormState extends State<_CreateCrewForm> {
  final _name = TextEditingController();
  final _desc = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final (crewId, err) = await widget.service.create(_name.text, _desc.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null || crewId == null) {
      setState(() => _error = err ?? 'Could not create the crew. Try again.');
      return;
    }
    Navigator.pop(context, crewId);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('You will be the crew admin. You can invite your friends only.', style: AppText.body.copyWith(color: AppTheme.text2)),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: CrewLimits.nameMax,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: 'Crew name', errorText: _error),
          ),
          TextField(
            controller: _desc,
            maxLength: CrewLimits.descriptionMax,
            maxLines: 3,
            minLines: 1,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Description (optional)'),
          ),
          const SizedBox(height: 8),
          DsButton(label: _busy ? 'Creating...' : 'Create crew', onPressed: _busy ? null : _send),
        ],
      ),
    );
  }
}

/// "Crews" row for the profile screen: count of crews, or invitations and polls waiting.
class CrewsEntryRow extends StatelessWidget {
  const CrewsEntryRow({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<CrewsService?>();
    final badge = svc?.badgeCount ?? 0;
    return DsListRow(
      icon: Icons.groups_2_rounded,
      label: 'Crews',
      value: badge > 0 ? '$badge new' : '${svc?.crews.length ?? 0}',
      valueColor: badge > 0 ? AppTheme.warnText : null,
      onTap: () => CrewsScreen.open(context),
    );
  }
}
