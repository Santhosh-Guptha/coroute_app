import 'package:flutter/material.dart';

import '../../../core/config/feature_gates.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../data/models/convoy_model.dart';
import '../../../data/models/rider_model.dart';

/// Clean secondary management sheet for convoy membership, invite code, and rider roles.
///
/// Complies with CoRoute formal authority model:
/// - Trip Owner: controls membership, billing, invitations, and Trip Head assignment.
/// - Trip Head: manages route, stops, speed limits, and pause/resume.
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
      backgroundColor: Colors.transparent,
      builder: (ctx) => Center(
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
    final maxCapacity = FeatureGates.maxConvoyMembers();
    final riderCount = convoy.riders.length;
    final isAtCapacity = riderCount >= maxCapacity;

    String tierLabel;
    if (maxCapacity <= 1) {
      tierLabel = 'Individual Solo (1)';
    } else if (maxCapacity <= 6) {
      tierLabel = 'Small Group (2–6)';
    } else {
      tierLabel = 'Large Group (7–12)';
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
                  Text('Manage Convoy Riders', style: AppText.title),
                  const SizedBox(height: 2),
                  Text(
                    '$tierLabel · $riderCount/$maxCapacity Bikes Joined',
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
                  Text('CONVOY INVITE CODE', style: AppText.overline),
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
        const SizedBox(height: Space.s8),

        // List of riders
        ...convoy.riders.values.map((r) {
          final isRiderOwner = convoy.isTripOwner(r.userId);
          final isRiderHead = convoy.isTripHead(r.userId);
          final isCurrentUser = r.userId == me.userId;

          String roleBadge;
          Color roleBadgeColor;
          if (isRiderOwner) {
            roleBadge = 'TRIP OWNER';
            roleBadgeColor = AppTheme.brand;
          } else if (isRiderHead) {
            roleBadge = 'TRIP HEAD';
            roleBadgeColor = AppTheme.accentText;
          } else if (r.role == 'LEAD') {
            roleBadge = 'LEAD (POINT)';
            roleBadgeColor = AppTheme.accentText;
          } else if (r.role == 'SWEEPER') {
            roleBadge = 'SWEEPER';
            roleBadgeColor = AppTheme.warnText;
          } else {
            roleBadge = 'RIDER';
            roleBadgeColor = AppTheme.muted;
          }

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
