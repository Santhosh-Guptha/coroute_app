import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/friends_service.dart';
import 'user_avatar.dart';

/// 3.55 friends: "Friend requests" waiting for me, with Accept / Decline on each. Shown at the
/// top of the Friends screen (every request) and of My profile (the first [max], then "See all"),
/// so a new request is never only behind a badge. Hides itself when there is none.
class FriendRequestsCard extends StatelessWidget {
  /// How many requests to list (null = all).
  final int? max;

  /// "See all" (shown when more than [max] are waiting) and the header tap.
  final VoidCallback? onSeeAll;

  /// Extra action per request (the Friends screen offers Block).
  final void Function(FriendRequestEntry entry)? onBlock;

  const FriendRequestsCard({super.key, this.max, this.onSeeAll, this.onBlock});

  static void _say(BuildContext context, String text) {
    ScaffoldMessenger.maybeOf(context)
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<FriendsService>();
    if (svc.badgeCount == 0) return const SizedBox.shrink();
    final all = svc.incoming;
    final shown = max == null ? all : all.take(max!).toList();
    final more = all.length - shown.length;
    return DsCard(
      key: const Key('friend_requests_card'),
      warning: true,
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.person_add_alt_1_rounded, color: AppTheme.warnText),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  all.length == 1 ? 'Friend request' : 'Friend requests (${all.length})',
                  style: AppText.title.copyWith(fontSize: 16),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final r in shown) _RequestRow(entry: r, onBlock: onBlock, say: (t) => _say(context, t)),
          if (more > 0 && onSeeAll != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onSeeAll, child: Text('See all ($more more)')),
            ),
        ],
      ),
    );
  }
}

class _RequestRow extends StatefulWidget {
  final FriendRequestEntry entry;
  final void Function(FriendRequestEntry entry)? onBlock;
  final void Function(String text) say;
  const _RequestRow({required this.entry, required this.say, this.onBlock});

  @override
  State<_RequestRow> createState() => _RequestRowState();
}

class _RequestRowState extends State<_RequestRow> {
  bool _busy = false;

  Future<void> _answer(bool accept) async {
    setState(() => _busy = true);
    final svc = context.read<FriendsService>();
    final err = await svc.respond(widget.entry.requestId, accept);
    if (!mounted) return;
    setState(() => _busy = false);
    widget.say(err ?? (accept ? 'You and ${widget.entry.username} are now friends' : 'Request declined'));
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.entry;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              UserAvatar(label: r.username, avatarUrl: r.avatarUrl, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.username, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 15)),
                    Text('Wants to be friends', style: AppText.caption.copyWith(color: AppTheme.text2)),
                  ],
                ),
              ),
              if (widget.onBlock != null)
                IconButton(tooltip: 'Block ${r.username}', icon: const Icon(Icons.block_rounded), onPressed: _busy ? null : () => widget.onBlock!(r)),
            ],
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              TextButton(onPressed: _busy ? null : () => _answer(false), child: const Text('Decline')),
              FilledButton(onPressed: _busy ? null : () => _answer(true), child: const Text('Accept')),
            ],
          ),
        ],
      ),
    );
  }
}
