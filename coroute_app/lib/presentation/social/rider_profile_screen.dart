import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/friends_service.dart';
import '../../domain/social/username_rules.dart';
import 'user_avatar.dart';

/// 3.55 another rider's profile. Friends: picture, username, first name and ride totals (trips,
/// km, hours, score). Everyone else: username and picture only. Never phone, e-mail, medical info,
/// emergency contacts, locations, guardians or plan (the gateway does not send them).
class RiderProfileScreen extends StatefulWidget {
  final String username;
  const RiderProfileScreen({super.key, required this.username});

  static Future<void> open(BuildContext context, String username) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => RiderProfileScreen(username: username)));

  @override
  State<RiderProfileScreen> createState() => _RiderProfileScreenState();
}

class _RiderProfileScreenState extends State<RiderProfileScreen> {
  RiderProfile? _p;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Round 7 (stale-while-revalidate): the profile as last seen is shown at once, then refreshed in place.
    final cached = SwrCache.shared.peek<RiderProfile>('rider:${widget.username}');
    if (cached != null) {
      _p = cached;
      _loading = false;
    }
    _load();
  }

  Future<void> _load() async {
    final p = await context.read<FriendsService>().profileOf(widget.username);
    if (p != null) {
      SwrCache.shared.put<RiderProfile>('rider:${widget.username}', p);
    } else {
      SwrCache.shared.remove('rider:${widget.username}');
    }
    if (!mounted) return;
    setState(() {
      _p = p;
      _loading = false;
    });
  }

  Future<void> _run(Future<String?> Function() call, String done) async {
    setState(() => _busy = true);
    final err = await call();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(err ?? done)));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.read<FriendsService>();
    final p = _p;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: dsScreenPadding,
              children: [
                DsScreenHeader(title: 'Rider', onBack: () => Navigator.maybePop(context)),
                const SizedBox(height: 18),
                if (_loading)
                  const SkeletonProfile(cards: 1) // round 7: shaped like the profile
                else if (p == null)
                  DsCard(child: Text('This rider could not be found.', style: AppText.body))
                else ...[
                  DsCard(
                    radius: Radii.xl,
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      children: [
                        UserAvatar(label: p.username, avatarUrl: p.avatarUrl, size: 88, filled: true, heroTag: AppHero.avatar(p.username)),
                        const SizedBox(height: 12),
                        Text(p.username, style: AppText.headline.copyWith(fontSize: 22), maxLines: 1, overflow: TextOverflow.ellipsis),
                        if ((p.displayName ?? '').isNotEmpty) Text(p.displayName!, style: AppText.label),
                        const SizedBox(height: 8),
                        DsChip(switch (p.relation) {
                          'FRIENDS' => 'Friend',
                          'PENDING_OUT' => 'Request sent',
                          'PENDING_IN' => 'Wants to be friends',
                          'BLOCKED' => 'Blocked',
                          'SELF' => 'You',
                          _ => 'Rider',
                        }),
                      ],
                    ),
                  ),
                  if (p.hasStats) ...[
                    const SizedBox(height: Space.s24),
                    const DsSectionHeader('Ride totals'),
                    const SizedBox(height: Space.s12),
                    Row(
                      children: [
                        Expanded(child: DsStatCell(label: 'Trips', value: '${p.trips ?? 0}')),
                        const SizedBox(width: 8),
                        Expanded(child: DsStatCell(label: 'Distance', value: formatKm(p.totalKm ?? 0))),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: DsStatCell(label: 'Riding hours', value: '${(p.ridingHours ?? 0).round()} h')),
                        const SizedBox(width: 8),
                        Expanded(child: DsStatCell(label: 'Rider score', value: p.score == null ? '-' : '${p.score}')),
                      ],
                    ),
                  ] else if (p.relation != 'SELF') ...[
                    const SizedBox(height: Space.s16),
                    Text('Ride totals are shown to friends only.', style: AppText.caption.copyWith(color: AppTheme.text2)),
                  ],
                  const SizedBox(height: Space.s24),
                  if (p.relation == 'NONE')
                    DsButton(label: 'Add friend', icon: Icons.person_add_alt_1_rounded, onPressed: _busy ? null : () => _run(() async => (await svc.sendRequest(p.username, byCode: false)).error, 'Request sent')),
                  if (p.relation == 'PENDING_IN')
                    DsButton(label: 'Accept request', onPressed: _busy ? null : () => _run(() async => (await svc.sendRequest(p.username, byCode: false)).error, 'You are now friends')),
                  if (p.relation == 'FRIENDS')
                    DsButton(label: 'Remove friend', tone: DsButtonTone.outline, onPressed: _busy ? null : () => _run(() => svc.removeFriend(p.username), 'Removed')),
                  if (p.relation == 'BLOCKED')
                    DsButton(label: 'Unblock', tone: DsButtonTone.outline, onPressed: _busy ? null : () => _run(() => svc.unblock(p.username), 'Unblocked')),
                  if (p.relation != 'BLOCKED' && p.relation != 'SELF') ...[
                    const SizedBox(height: 8),
                    TextButton.icon(
                      icon: const Icon(Icons.block_rounded),
                      label: const Text('Block this rider'),
                      onPressed: _busy
                          ? null
                          : () async {
                              if (await confirmAction(context,
                                  title: 'Block ${p.username}?',
                                  message: 'They will not be able to send you requests or see your profile. They are not told.',
                                  confirmLabel: 'Block',
                                  destructive: true)) {
                                await _run(() => svc.block(p.username), 'Blocked');
                              }
                            },
                    ),
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
