import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/services/friends_service.dart';
import 'friends_screen.dart';

/// 3.55 friends: shows "X wants to be friends" / "X accepted your friend request" (and the
/// invite-link outcome) as a snackbar while the app is open. In the background FriendsService
/// posts a system notification instead. Placed once in MaterialApp.builder.
class FriendNoticeHost extends StatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;
  const FriendNoticeHost({super.key, required this.child, required this.navigatorKey});

  @override
  State<FriendNoticeHost> createState() => _FriendNoticeHostState();
}

class _FriendNoticeHostState extends State<FriendNoticeHost> {
  FriendsService? _svc;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final svc = context.read<FriendsService?>();
    if (identical(svc, _svc)) return;
    _svc?.removeListener(_onChange);
    _svc = svc?..addListener(_onChange);
  }

  @override
  void dispose() {
    _svc?.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    final svc = _svc;
    if (svc == null || !mounted) return;
    final line = svc.takeNotice();
    if (line == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final request = line.endsWith('wants to be friends');
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(line),
        behavior: SnackBarBehavior.floating,
        action: request
            ? SnackBarAction(
                label: 'View',
                onPressed: () {
                  final nav = widget.navigatorKey.currentState;
                  if (nav != null) nav.push(MaterialPageRoute<void>(builder: (_) => const FriendsScreen()));
                },
              )
            : null,
      ));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
