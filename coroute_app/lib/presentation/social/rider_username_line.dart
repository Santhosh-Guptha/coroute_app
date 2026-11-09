import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/friends_service.dart';
import 'rider_profile_screen.dart';

/// 3.55: "@SwiftFalcon482" under a rider's name in the ride (rider card). Tapping opens their
/// profile (what they allow me to see). Nothing is shown while unknown, offline, or on an older
/// gateway; one request per ride (FriendsService caches the group's usernames).
class RiderUsernameLine extends StatelessWidget {
  final String groupId;
  final String userId;
  const RiderUsernameLine({super.key, required this.groupId, required this.userId});

  @override
  Widget build(BuildContext context) {
    FriendsService? svc;
    try {
      svc = context.read<FriendsService?>();
    } catch (_) {
      svc = null;
    }
    if (svc == null || groupId.isEmpty) return const SizedBox.shrink();
    return FutureBuilder<Map<String, ({String username, String? avatarUrl})>>(
      future: svc.usernamesOfGroup(groupId),
      builder: (context, snap) {
        final name = snap.data?[userId]?.username ?? '';
        if (name.isEmpty) return const SizedBox.shrink();
        return Semantics(
          button: true,
          label: 'Username $name. Open profile',
          excludeSemantics: true,
          child: InkWell(
            onTap: () => RiderProfileScreen.open(context, name),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text('@$name', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppTheme.accentText, fontWeight: FontWeight.w700)),
            ),
          ),
        );
      },
    );
  }
}
