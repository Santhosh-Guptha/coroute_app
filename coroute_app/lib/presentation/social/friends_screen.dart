import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/friends_service.dart';
import '../widgets/feature_switch.dart';
import 'rider_profile_screen.dart';
import 'user_avatar.dart';

/// 3.55 friends: my friends, requests waiting for me (accept / decline), requests I sent
/// (cancel), blocked riders, add by username or invite code, invite friends to CoRoute.
class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => const FriendsScreen()));

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<FriendsService>().refreshFriends();
    });
  }

  void _say(String? text) {
    if (text == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _add(FriendsService svc) async {
    final msg = await showAppSheet<String>(
      context,
      title: 'Add a friend',
      isScrollControlled: true,
      builder: (_) => _AddFriendForm(service: svc),
    );
    _say(msg);
  }

  Future<void> _invite(FriendsService svc) async {
    final p = svc.profile;
    if (p == null) await svc.refreshProfile();
    final text = svc.profile?.shareText;
    if (text == null || !mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(ShareParams(
      text: text,
      subject: 'Ride with me on CoRoute',
      sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    ));
  }

  Future<void> _friendActions(FriendsService svc, FriendEntry f) async {
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
    if (choice == 'view') {
      RiderProfileScreen.open(context, f.username);
    } else if (choice == 'remove') {
      if (await confirmAction(context, title: 'Remove ${f.username}?', message: 'You can add each other again later.', confirmLabel: 'Remove', destructive: true)) {
        _say(await svc.removeFriend(f.username) ?? 'Removed');
      }
    } else if (choice == 'block') {
      if (!mounted) return;
      if (await confirmAction(context,
          title: 'Block ${f.username}?',
          message: 'They will not be able to send you requests or see your profile. They are not told.',
          confirmLabel: 'Block',
          destructive: true)) {
        _say(await svc.block(f.username) ?? 'Blocked');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<FriendsService>();
    final on = context.featureOn(FriendsService.friendsFlag);
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: RefreshIndicator(
              onRefresh: svc.refreshFriends,
              child: ListView(
                padding: dsScreenPadding,
                children: [
                  DsScreenHeader(
                    title: 'Friends',
                    onBack: () => Navigator.maybePop(context),
                    trailing: on ? DsRoundButton(icon: Icons.person_add_alt_1_rounded, label: 'Add a friend', size: 48, onTap: () => _add(svc)) : null,
                  ),
                  const SizedBox(height: 18),
                  if (!on)
                    DsCard(child: Text('Friends are turned off for now.', style: AppText.body))
                  else ...[
                    DsButton(label: 'Invite friends to CoRoute', icon: Icons.share_rounded, tone: DsButtonTone.outline, onPressed: () => _invite(svc)),
                    if (svc.incoming.isNotEmpty) ...[
                      const SizedBox(height: Space.s24),
                      DsSectionHeader('Requests (${svc.incoming.length})'),
                      const SizedBox(height: Space.s12),
                      for (final r in svc.incoming)
                        _RequestCard(
                          entry: r,
                          subtitle: 'Wants to be friends',
                          actions: [
                            TextButton(onPressed: () async => _say(await svc.respond(r.requestId, false)), child: const Text('Decline')),
                            FilledButton(onPressed: () async => _say(await svc.respond(r.requestId, true) ?? 'You are now friends'), child: const Text('Accept')),
                          ],
                          onMore: () async {
                            if (await confirmAction(context,
                                title: 'Block ${r.username}?',
                                message: 'The request disappears and they cannot send another. They are not told.',
                                confirmLabel: 'Block',
                                destructive: true)) {
                              _say(await svc.block(r.username) ?? 'Blocked');
                            }
                          },
                        ),
                    ],
                    const SizedBox(height: Space.s24),
                    DsSectionHeader('My friends (${svc.friends.length})'),
                    const SizedBox(height: Space.s12),
                    if (svc.friends.isEmpty)
                      DsCard(
                        child: Text('Add riders by their username or share your invite code. Friends see your username, first name and ride totals, never your phone, e-mail or locations.',
                            style: AppText.body.copyWith(color: AppTheme.text2)),
                      )
                    else
                      DsCard(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        child: Column(
                          children: [
                            for (var i = 0; i < svc.friends.length; i++)
                              _FriendRow(
                                f: svc.friends[i],
                                divider: i < svc.friends.length - 1,
                                onTap: () => RiderProfileScreen.open(context, svc.friends[i].username),
                                onMore: () => _friendActions(svc, svc.friends[i]),
                              ),
                          ],
                        ),
                      ),
                    if (svc.outgoing.isNotEmpty) ...[
                      const SizedBox(height: Space.s24),
                      DsSectionHeader('Sent (${svc.outgoing.length})'),
                      const SizedBox(height: Space.s12),
                      for (final r in svc.outgoing)
                        _RequestCard(
                          entry: r,
                          subtitle: 'Waiting for an answer',
                          actions: [TextButton(onPressed: () async => _say(await svc.cancelRequest(r.requestId) ?? 'Request cancelled'), child: const Text('Cancel'))],
                        ),
                    ],
                    if (svc.blocked.isNotEmpty) ...[
                      const SizedBox(height: Space.s24),
                      const DsSectionHeader('Blocked'),
                      const SizedBox(height: Space.s12),
                      DsCard(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        child: Column(
                          children: [
                            for (var i = 0; i < svc.blocked.length; i++)
                              DsListRow(
                                icon: Icons.block_rounded,
                                label: svc.blocked[i],
                                divider: i < svc.blocked.length - 1,
                                trailing: TextButton(onPressed: () async => _say(await svc.unblock(svc.blocked[i]) ?? 'Unblocked'), child: const Text('Unblock')),
                              ),
                          ],
                        ),
                      ),
                    ],
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

class _FriendRow extends StatelessWidget {
  final FriendEntry f;
  final bool divider;
  final VoidCallback onTap;
  final VoidCallback onMore;
  const _FriendRow({required this.f, required this.divider, required this.onTap, required this.onMore});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                UserAvatar(label: f.username, avatarUrl: f.avatarUrl, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(f.username, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 16)),
                      Text('${f.displayName.isEmpty ? '' : '${f.displayName} · '}${f.trips} trips · ${f.totalKm.round()} km',
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppTheme.text2)),
                    ],
                  ),
                ),
                IconButton(tooltip: 'More for ${f.username}', icon: const Icon(Icons.more_vert_rounded), onPressed: onMore),
              ],
            ),
          ),
        ),
        if (divider) Divider(height: 1, color: AppTheme.border),
      ],
    );
  }
}

class _RequestCard extends StatelessWidget {
  final FriendRequestEntry entry;
  final String subtitle;
  final List<Widget> actions;
  final VoidCallback? onMore;
  const _RequestCard({required this.entry, required this.subtitle, required this.actions, this.onMore});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DsCard(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          children: [
            UserAvatar(label: entry.username, avatarUrl: entry.avatarUrl, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.username, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 16)),
                  Text(subtitle, style: AppText.caption.copyWith(color: AppTheme.text2)),
                ],
              ),
            ),
            ...actions,
            if (onMore != null) IconButton(tooltip: 'Block ${entry.username}', icon: const Icon(Icons.block_rounded), onPressed: onMore),
          ],
        ),
      ),
    );
  }
}

class _AddFriendForm extends StatefulWidget {
  final FriendsService service;
  const _AddFriendForm({required this.service});

  @override
  State<_AddFriendForm> createState() => _AddFriendFormState();
}

class _AddFriendFormState extends State<_AddFriendForm> {
  final _ctrl = TextEditingController();
  bool _byCode = false;
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
    final r = await widget.service.sendRequest(_ctrl.text, byCode: _byCode);
    if (!mounted) return;
    setState(() => _sending = false);
    if (!r.ok) {
      setState(() => _error = r.error);
      return;
    }
    Navigator.pop(
      context,
      switch (r.status) {
        'FRIENDS' => 'You are now friends',
        'ALREADY_FRIENDS' => 'You are already friends',
        _ => 'Request sent. You will be friends once they accept.',
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DsSegment<bool>(
            values: const [false, true],
            selected: _byCode,
            label: (v) => v ? 'Invite code' : 'Username',
            onChanged: (v) => setState(() => _byCode = v),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: _byCode ? TextCapitalization.characters : TextCapitalization.none,
            maxLength: 20,
            decoration: InputDecoration(labelText: _byCode ? 'Invite code' : 'Username', errorText: _error),
            onSubmitted: (_) => _sending ? null : _send(),
          ),
          const SizedBox(height: 8),
          DsButton(label: _sending ? 'Sending...' : 'Send request', onPressed: _sending ? null : _send),
        ],
      ),
    );
  }
}
