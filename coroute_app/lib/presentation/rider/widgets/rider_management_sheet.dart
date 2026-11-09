import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../data/models/convoy_model.dart';
import '../../../data/models/rider_model.dart';

/// Clean secondary management sheet for convoy membership, invite code, and rider roles.
///
/// Complies with CoRoute formal authority model:
/// - Trip Owner: controls membership, billing, invitations, Trip Head assignment, removing riders
///   and ending the trip.
/// - Trip Head: changes the trip's group settings only (3.55 owner decision, Nov 9).
/// - Capacity tiers: Individual (1), Small Group (2–6), Large Group (7–12).
class RiderManagementSheet extends StatelessWidget {
  final ConvoyModel convoy;
  final RiderModel me;
  final bool isOwner;
  final bool isHead;
  final VoidCallback onShareInvite;
  final VoidCallback onCopyCode;

  const RiderManagementSheet({
    super.key,
    required this.convoy,
    required this.me,
    required this.isOwner,
    required this.isHead,
    required this.onShareInvite,
    required this.onCopyCode,
  });

  /// One line per role (3.55 naming, UX_NAMING_GUIDE §2/§4): trip roles manage the trip, riding
  /// roles are positions on the road.
  static const List<String> roleExplanations = [
    'Trip owner: created this trip.',
    'Trip head: can change the trip\'s settings. Only the trip owner removes riders or ends the trip.',
    'Lead: rides first and guides the group. Middle: rides between. Sweeper: rides last.',
  ];

  /// The badges for one rider (pure, for tests): the trip role first (TRIP OWNER or TRIP HEAD,
  /// if any), then the riding role (LEAD, SWEEPER or MIDDLE).
  static List<String> roleBadges({required bool owner, required bool head, required String ridingRole}) => [
        if (owner) 'TRIP OWNER' else if (head) 'TRIP HEAD',
        switch (ridingRole) {
          'LEAD' => 'LEAD',
          'SWEEPER' => 'SWEEPER',
          _ => 'MIDDLE',
        },
      ];

  static Future<void> show(
    BuildContext context, {
    required ConvoyModel convoy,
    required RiderModel me,
    required VoidCallback onShareInvite,
    required VoidCallback onCopyCode,
  }) async {
    final uid = me.userId;
    final isOwner = convoy.isTripOwner(uid);
    final isHead = convoy.isTripHead(uid);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: true,
      enableDrag: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.88),
      backgroundColor: Colors.transparent,
      barrierColor: AppScrim.color,
      // Only as tall as the card, at the bottom: a full-height Center made the
      // transparent sheet around the card swallow taps meant for the scrim.
      builder: (ctx) => Align(
        alignment: Alignment.bottomCenter,
        heightFactor: 1.0,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Container(
            decoration: BoxDecoration(
              color: AppTheme.card,
              borderRadius: Radii.sheetTop,
              border: Border.all(color: AppTheme.border, width: 2),
            ),
            padding: const EdgeInsets.fromLTRB(Space.s16, Space.s16, Space.s16, Space.s32),
            child: SingleChildScrollView(
              child: RiderManagementSheet(
                convoy: convoy,
                me: me,
                isOwner: isOwner,
                isHead: isHead,
                onShareInvite: onShareInvite,
                onCopyCode: onCopyCode,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Seats come from the host's membership (set by the gateway on the ride), never a global cap.
    final isAtCapacity = convoy.isFull;
    final String tierLabel;
    if (convoy.capacity <= 0) {
      tierLabel = 'Group ride';
    } else if (convoy.capacity <= 1) {
      tierLabel = 'Solo trip';
    } else {
      tierLabel = 'Up to ${convoy.capacity} riders';
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Handle bar
        Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppTheme.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: Space.s16),

        // Header
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(Space.s8),
              decoration: BoxDecoration(
                color: AppTheme.brand.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.group_rounded, color: AppTheme.brand, size: 24),
            ),
            const SizedBox(width: Space.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Manage riders', style: AppText.title),
                  const SizedBox(height: 2),
                  Text(
                    '$tierLabel · ${convoy.riderCountLabel} joined',
                    style: AppText.caption.copyWith(color: AppTheme.text2),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.s16),

        // Invite code card
        Container(
          padding: const EdgeInsets.all(Space.s16),
          decoration: BoxDecoration(
            color: AppTheme.bg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.border, width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('INVITE CODE', style: AppText.overline),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: isAtCapacity ? AppTheme.warnTint : AppTheme.tint,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      isAtCapacity ? 'CAPACITY REACHED' : 'OPEN FOR RIDERS',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: isAtCapacity ? AppTheme.warnText : AppTheme.accentText,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      convoy.joinCode,
                      style: AppText.headline.copyWith(
                        letterSpacing: 4,
                        fontWeight: FontWeight.w900,
                        color: AppTheme.brand,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy_rounded, size: 22),
                    tooltip: 'Copy code',
                    onPressed: onCopyCode,
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                    onPressed: onShareInvite,
                    icon: const Icon(Icons.share_rounded, size: 18),
                    label: const Text('Share', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.s16),

        // Roster title
        Text('CONNECTED RIDERS (${convoy.riders.length})', style: AppText.overline),
        const SizedBox(height: Space.s4),
        // 3.55 naming: what each badge means (trip roles manage the trip, riding roles are positions).
        for (final line in RiderManagementSheet.roleExplanations)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(line, style: AppText.caption),
          ),
        const SizedBox(height: Space.s8),

        // List of riders
        ...convoy.riders.values.map((r) {
          final isRiderOwner = convoy.isTripOwner(r.userId);
          final isRiderHead = convoy.isTripHead(r.userId);
          final isCurrentUser = r.userId == me.userId;

          // The trip role (if any) and the riding role, side by side: a trip owner can also ride Lead.
          final badges = <(String, Color)>[
            for (final b in RiderManagementSheet.roleBadges(owner: isRiderOwner, head: isRiderHead, ridingRole: r.role))
              (b, switch (b) {
                'TRIP OWNER' => AppTheme.brand,
                'TRIP HEAD' || 'LEAD' => AppTheme.accentText,
                'SWEEPER' => AppTheme.warnText,
                _ => AppTheme.muted,
              }),
          ];

          final initials = r.name.trim().isNotEmpty
              ? r.name.trim().split(' ').map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase()
              : 'R';

          return Container(
            margin: const EdgeInsets.only(bottom: Space.s8),
            padding: const EdgeInsets.symmetric(horizontal: Space.s12, vertical: Space.s8),
            decoration: BoxDecoration(
              color: AppTheme.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isCurrentUser ? AppTheme.brand.withOpacity(0.5) : AppTheme.border,
                width: isCurrentUser ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: AppTheme.brand.withOpacity(0.2),
                  child: Text(
                    initials,
                    style: TextStyle(
                      color: AppTheme.brand,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: Space.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              isCurrentUser ? '${r.name} (You)' : r.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.body.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                          for (final (roleBadge, roleBadgeColor) in badges) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: roleBadgeColor.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                roleBadge,
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  color: roleBadgeColor,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        r.statusReason.isNotEmpty
                            ? 'Status: ${r.statusReason}'
                            : (r.speedKmh > 5 ? 'Moving at ${r.speedKmh.round()} km/h' : 'Stationary'),
                        style: AppText.caption,
                      ),
                    ],
                  ),
                ),
                if (r.batteryLevel < 25)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.battery_alert_rounded, size: 16, color: AppTheme.warnText),
                      const SizedBox(width: 4),
                      Text('${r.batteryLevel}%', style: TextStyle(color: AppTheme.warnText, fontSize: 11)),
                    ],
                  ),
              ],
            ),
          );
        }),
      ],
    );
  }
}
