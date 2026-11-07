import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../data/models/convoy_model.dart';
import '../../../data/models/rider_model.dart';

/// Structured, ultra-minimal cockpit settings cards for the live ride bottom sheet.
///
/// Designed to be distraction-free and strictly enforce subscription plan gates:
/// 1. Navigation & Route Tools (Route & Stops, Mid-Ride Waypoint Push, Turn-by-turn, Messages)
/// 2. Safety & Fuel Health (Fuel range with inline refuel, Ride Guardian with plan gate, Stop reason)
/// 3. Convoy & Comms (Invite code with capacity gate, Intercom with priority ducking, Group settings, Share ETA)
/// 4. Ride Controls (Pause/Resume, End ride, Leave ride)

class _CardTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _CardTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.s16,
          vertical: Space.s12,
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(Space.s8),
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 22),
            ),
            const SizedBox(width: Space.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.title.copyWith(fontSize: 15),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption,
                  ),
                ],
              ),
            ),
            const SizedBox(width: Space.s8),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: AppTheme.muted,
            ),
          ],
        ),
      ),
    );
  }
}

/// An individual glove-friendly action tile designed for >=56dp touch target.
class GloveActionTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final String? badgeText;
  final Color? badgeColor;

  const GloveActionTile({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.badgeText,
    this.badgeColor,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppTheme.border, width: 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: iconColor.withOpacity(0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, color: iconColor, size: 22),
                  ),
                  if (badgeText != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: (badgeColor ?? AppTheme.brand).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        badgeText!,
                        style: TextStyle(
                          color: badgeColor ?? AppTheme.brand,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.title.copyWith(fontSize: 14, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(fontSize: 11, color: AppTheme.muted),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Glove-friendly 2x3 quick action grid (Section 2) for essential in-ride controls.
class GloveQuickActionGrid extends StatelessWidget {
  final ConvoyModel convoy;
  final RiderModel me;
  final VoidCallback onOpenIntercom;
  final VoidCallback onOpenStops;
  final VoidCallback onTellWhy;
  final String? stopReasonText;
  final VoidCallback onOpenFuel;
  final double? estimatedUsableKm;
  final String? nearestFuelName;
  final double? nearestFuelAheadM;
  final VoidCallback onOpenMessages;
  final int chatQueued;
  final VoidCallback onOpenSafetyStatus;
  final bool isSafetyHealthy;
  final bool isSolo;

  /// False in a solo ride (Community host): no Talk and no Messages tiles.
  final bool groupFeatures;

  const GloveQuickActionGrid({
    super.key,
    required this.convoy,
    required this.me,
    required this.onOpenIntercom,
    required this.onOpenStops,
    required this.onTellWhy,
    this.stopReasonText,
    required this.onOpenFuel,
    this.estimatedUsableKm,
    this.nearestFuelName,
    this.nearestFuelAheadM,
    required this.onOpenMessages,
    this.chatQueued = 0,
    required this.onOpenSafetyStatus,
    this.isSafetyHealthy = true,
    this.isSolo = false,
    this.groupFeatures = true,
  });

  @override
  Widget build(BuildContext context) {
    final commsSubtitle = isSolo ? 'Solo ride' : 'Group ride active';
    final stopsCount = convoy.plannedStops.length;
    final stopsSubtitle = stopsCount == 0 ? 'No stops' : '$stopsCount stop${stopsCount > 1 ? 's' : ''}';
    final reason = stopReasonText ?? '';
    final reasonSubtitle = reason.isEmpty ? 'Tap to report' : reason;
    final reasonColor = reason.isEmpty ? AppTheme.muted : AppTheme.warnText;

    final estimate = estimatedUsableKm;
    final fuelTitle = estimate != null ? '${estimate.floor()} km range' : 'Fuel range';
    final fuelSubtitle = nearestFuelAheadM != null
        ? '${nearestFuelName ?? "Station"} in ${formatDistanceRounded(nearestFuelAheadM!)}'
        : 'Tap for nearby';
    final fuelColor = (estimate != null && estimate <= 20)
        ? AppTheme.sos
        : (estimate != null && estimate <= 40 ? AppTheme.warnText : AppTheme.brand);

    final msgCount = convoy.messages.length;
    final msgSubtitle = chatQueued > 0
        ? '$chatQueued sending'
        : (convoy.messages.isEmpty ? 'No unread' : convoy.messages.last.text);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (groupFeatures) ...[
              Expanded(
                child: GloveActionTile(
                  icon: Icons.headset_mic_rounded,
                  iconColor: AppTheme.brand,
                  title: isSolo ? 'Intercom' : 'Talk to All',
                  subtitle: commsSubtitle,
                  onTap: onOpenIntercom,
                ),
              ),
              const SizedBox(width: Space.s8),
            ],
            Expanded(
              child: GloveActionTile(
                icon: Icons.route_rounded,
                iconColor: AppTheme.brand,
                title: 'Route & Stops',
                subtitle: stopsSubtitle,
                onTap: onOpenStops,
                badgeText: stopsCount > 0 ? '$stopsCount' : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.s8),
        Row(
          children: [
            Expanded(
              child: GloveActionTile(
                icon: Icons.pause_circle_outline_rounded,
                iconColor: reasonColor,
                title: 'Stop Reason',
                subtitle: reasonSubtitle,
                onTap: onTellWhy,
                badgeText: reason.isNotEmpty ? 'SET' : null,
                badgeColor: AppTheme.warnText,
              ),
            ),
            const SizedBox(width: Space.s8),
            Expanded(
              child: GloveActionTile(
                icon: Icons.local_gas_station_rounded,
                iconColor: fuelColor,
                title: fuelTitle,
                subtitle: fuelSubtitle,
                onTap: onOpenFuel,
                badgeText: 'REFUEL',
                badgeColor: fuelColor,
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.s8),
        Row(
          children: [
            if (groupFeatures) ...[
              Expanded(
                child: GloveActionTile(
                  icon: Icons.chat_bubble_outline_rounded,
                  iconColor: AppTheme.warnText,
                  title: 'Messages ($msgCount)',
                  subtitle: msgSubtitle,
                  onTap: onOpenMessages,
                  badgeText: chatQueued > 0 ? '$chatQueued' : null,
                  badgeColor: AppTheme.warnText,
                ),
              ),
              const SizedBox(width: Space.s8),
            ],
            Expanded(
              child: GloveActionTile(
                icon: Icons.shield_rounded,
                iconColor: isSafetyHealthy ? AppTheme.accentText : AppTheme.warnText,
                title: 'Safety Health',
                subtitle: isSafetyHealthy ? 'All systems active' : 'Check status',
                onTap: onOpenSafetyStatus,
                badgeText: isSafetyHealthy ? 'OK' : 'CHECK',
                badgeColor: isSafetyHealthy ? AppTheme.accentText : AppTheme.warnText,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Compact convoy roster (Section 3) with horizontal avatars and spread summary.
class CompactConvoyRoster extends StatelessWidget {
  final ConvoyModel convoy;
  final RiderModel me;
  final double? spreadM;
  final Map<String, Color> colors;
  final Map<String, RiderStatus> statuses;
  final int nowMs;
  final ValueChanged<RiderModel> onTapRider;
  final VoidCallback onOpenManageRiders;
  final bool isLead;

  const CompactConvoyRoster({
    super.key,
    required this.convoy,
    required this.me,
    this.spreadM,
    required this.colors,
    required this.statuses,
    required this.nowMs,
    required this.onTapRider,
    required this.onOpenManageRiders,
    this.isLead = false,
  });

  @override
  Widget build(BuildContext context) {
    final riders = convoy.riders.values.toList();
    final spreadText = spreadM != null && spreadM!.isFinite
        ? formatDistanceRounded(spreadM!)
        : '-';

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.border, width: 1.5),
      ),
      padding: const EdgeInsets.all(Space.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // Expanded + ellipsis: "CONVOY SPREAD: 12.4 km" and "N Riders" overflowed the
              // card on 360 dp phones with large text.
              Expanded(
                child: Row(
                  children: [
                    Icon(Icons.swap_calls_rounded, size: 18, color: AppTheme.accentText),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'GROUP SPREAD: $spreadText',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.overline.copyWith(color: AppTheme.accentText),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: onOpenManageRiders,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${riders.length} Riders',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.brand,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(Icons.chevron_right_rounded, size: 16, color: AppTheme.brand),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.s12),
          SizedBox(
            // 72 dp at normal text size; taller with large text so the names are not clipped.
            height: (58 + MediaQuery.textScalerOf(context).scale(14)).clamp(72.0, 120.0).toDouble(),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: riders.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final r = riders[i];
                final isMe = r.userId == me.userId;
                final riderColor = colors[r.userId] ?? AppTheme.brand;
                final initials = r.name.trim().isNotEmpty
                    ? r.name.trim().split(' ').map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase()
                    : 'R';

                final isOwner = convoy.isTripOwner(r.userId);
                final isHead = convoy.isTripHead(r.userId);
                String roleTag = '';
                if (isOwner) {
                  roleTag = 'OWNER';
                } else if (isHead) {
                  roleTag = 'HEAD';
                } else if (r.role == 'LEAD') {
                  roleTag = 'LEAD';
                } else if (r.role == 'SWEEPER') {
                  roleTag = 'SWEEPER';
                }

                return InkWell(
                  onTap: () => onTapRider(r),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: 68,
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: isMe ? AppTheme.brand.withOpacity(0.08) : AppTheme.bg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isMe ? AppTheme.brand : AppTheme.border,
                        width: isMe ? 1.5 : 1,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            CircleAvatar(
                              radius: 16,
                              backgroundColor: riderColor.withOpacity(0.2),
                              child: Text(
                                initials,
                                style: TextStyle(
                                  color: riderColor,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                            if (roleTag.isNotEmpty)
                              Positioned(
                                bottom: -4,
                                right: -4,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: isOwner || isHead ? AppTheme.brand : AppTheme.accentText,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    roleTag,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 7,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        Text(
                          isMe ? 'You' : r.name.split(' ').first,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: isMe ? FontWeight.w800 : FontWeight.w600,
                            color: AppTheme.text,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Grouped secondary management tiles (Section 4) for settings & tools.
class SecondaryManagementGroup extends StatelessWidget {
  final ConvoyModel convoy;
  final bool isLead;
  final VoidCallback onOpenManageRiders;
  final VoidCallback onOpenAudioSettings;
  final VoidCallback onOpenGroupSettings;
  final VoidCallback onOpenGuardian;
  final VoidCallback onOpenSafetyStatus;
  final VoidCallback? onShareEta;
  final String? etaSubtitle;
  final bool isSolo;

  /// False in a solo ride (Community host): no invite code, audio or group settings.
  final bool groupFeatures;

  const SecondaryManagementGroup({
    super.key,
    required this.convoy,
    this.isLead = false,
    required this.onOpenManageRiders,
    required this.onOpenAudioSettings,
    required this.onOpenGroupSettings,
    required this.onOpenGuardian,
    required this.onOpenSafetyStatus,
    this.onShareEta,
    this.etaSubtitle,
    this.isSolo = false,
    this.groupFeatures = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.border, width: 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (groupFeatures) ...[
            _CardTile(
              icon: Icons.group_add_rounded,
              iconColor: AppTheme.brand,
              title: 'Manage Riders & Invite',
              subtitle: '${convoy.riderCountLabel} riders · Join code ${convoy.joinCode}',
              onTap: onOpenManageRiders,
            ),
            const Divider(height: 1),
          ],
          if (!isSolo && groupFeatures) ...[
            _CardTile(
              icon: Icons.tune_rounded,
              iconColor: AppTheme.accentText,
              title: 'Talk settings',
              subtitle: 'Hear the group, microphone, headset button',
              onTap: onOpenAudioSettings,
            ),
            const Divider(height: 1),
            _CardTile(
              icon: Icons.admin_panel_settings_rounded,
              iconColor: AppTheme.warnText,
              title: 'Group Safety & Speed Limits',
              subtitle: 'Speed limit, distance alerts, who sees you',
              onTap: onOpenGroupSettings,
            ),
            const Divider(height: 1),
          ],
          _CardTile(
            icon: Icons.shield_rounded,
            iconColor: AppTheme.accentText,
            title: 'Ride Guardian',
            subtitle: 'A private live link for family or friends',
            onTap: onOpenGuardian,
          ),
          const Divider(height: 1),
          _CardTile(
            icon: Icons.settings_rounded,
            iconColor: AppTheme.brand,
            title: 'Settings',
            subtitle: 'Safety, voice, map and privacy',
            onTap: onOpenSafetyStatus,
          ),
          if (onShareEta != null) ...[
            const Divider(height: 1),
            _CardTile(
              icon: Icons.share_location_rounded,
              iconColor: AppTheme.warnText,
              title: 'Share my ETA',
              subtitle: etaSubtitle ?? 'Share arrival time with family or friends',
              onTap: onShareEta!,
            ),
          ],
        ],
      ),
    );
  }
}

/// Ride lifecycle bar (Section 5) fixed at sheet bottom with clear confirmation.
class RideLifecycleBar extends StatelessWidget {
  final bool isLead;
  final bool isPaused;
  final VoidCallback onTogglePause;
  final VoidCallback onEndRide;
  final VoidCallback onLeaveRide;

  const RideLifecycleBar({
    super.key,
    required this.isLead,
    required this.isPaused,
    required this.onTogglePause,
    required this.onEndRide,
    required this.onLeaveRide,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isLead) ...[
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: isPaused ? AppTheme.accentText : AppTheme.warnText,
              side: BorderSide(
                color: isPaused ? AppTheme.accentText : AppTheme.warnText,
                width: 1.5,
              ),
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: onTogglePause,
            icon: Icon(
              isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
            ),
            label: Text(
              isPaused ? 'Resume group ride' : 'Pause group ride',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
          ),
          const SizedBox(height: Space.s12),
        ],
        Row(
          children: [
            if (isLead) ...[
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: StatusColors.critical,
                    foregroundColor: StatusColors.onCritical,
                    minimumSize: const Size(0, 52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: onEndRide,
                  icon: const Icon(Icons.flag_rounded, size: 20),
                  label: const Text(
                    'End Ride',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
              ),
              const SizedBox(width: Space.s12),
            ],
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: StatusColors.critical,
                  side: BorderSide(color: StatusColors.critical, width: 1.5),
                  minimumSize: const Size(0, 52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: onLeaveRide,
                icon: const Icon(Icons.logout_rounded, size: 20),
                label: const Text(
                  'Leave Ride',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

