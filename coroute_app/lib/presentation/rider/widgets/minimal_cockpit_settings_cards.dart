import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../data/models/convoy_model.dart';
import '../../../domain/safety/fuel_profile.dart';

/// Structured, minimal cockpit settings cards for the live ride bottom sheet.
///
/// Replaces the loose 12-item list with 4 high-efficiency cards:
/// 1. Navigation & Route Tools (Route & Stops, Turn-by-turn, Offline Map, Messages)
/// 2. Safety & Fuel Health (Fuel range with inline refuel, Ride Guardian, Stop reason)
/// 3. Convoy & Comms (Invite code, Intercom options, Group settings, Share ETA)
/// 4. Ride Controls (Pause/Resume, End ride, Leave ride)

class NavigationToolsCard extends StatelessWidget {
  final ConvoyModel convoy;
  final VoidCallback onOpenStops;
  final VoidCallback onOpenMessages;
  final VoidCallback? onTurnByTurn;
  final Widget? saveMapWidget;
  final int chatQueued;
  final bool isOnline;

  const NavigationToolsCard({
    super.key,
    required this.convoy,
    required this.onOpenStops,
    required this.onOpenMessages,
    this.onTurnByTurn,
    this.saveMapWidget,
    required this.chatQueued,
    required this.isOnline,
  });

  @override
  Widget build(BuildContext context) {
    final stopsSubtitle = convoy.suggestedStops.isEmpty
        ? '${convoy.plannedStops.length} planned'
        : '${convoy.plannedStops.length} planned · ${convoy.suggestedStops.length} suggested';

    final msgSubtitle = chatQueued > 0
        ? (isOnline ? '$chatQueued sending' : '$chatQueued waiting for signal')
        : (convoy.messages.isEmpty ? 'No unread messages' : convoy.messages.last.text);

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
          _CardTile(
            icon: Icons.route_rounded,
            iconColor: AppTheme.brand,
            title: 'Route and stops',
            subtitle: stopsSubtitle,
            onTap: onOpenStops,
          ),
          const Divider(height: 1),
          if (onTurnByTurn != null) ...[
            _CardTile(
              key: const Key('sheet_row_offline_nav'),
              icon: Icons.navigation_rounded,
              iconColor: AppTheme.accentText,
              title: 'Turn-by-turn navigation',
              subtitle: convoy.destinationName.isEmpty ? 'Active route guidance' : 'Route to ${convoy.destinationName}',
              onTap: onTurnByTurn!,
            ),
            const Divider(height: 1),
          ],
          _CardTile(
            icon: Icons.chat_bubble_outline_rounded,
            iconColor: AppTheme.warnText,
            title: 'Messages (${convoy.messages.length})',
            subtitle: msgSubtitle,
            onTap: onOpenMessages,
          ),
          if (saveMapWidget != null) ...[
            const Divider(height: 1),
            saveMapWidget!,
          ],
        ],
      ),
    );
  }
}

class SafetyFuelCard extends StatelessWidget {
  final double? estimatedUsableKm;
  final FuelProfile? profile;
  final double? nearestFuelAheadM;
  final String? nearestFuelName;
  final bool fuelUncertain;
  final double riddenSinceFillM;
  final VoidCallback onOpenFuel;
  final VoidCallback onOpenGuardian;
  final VoidCallback onTellWhy;
  final String? stopReasonText;
  final String? queuedStopReason;

  const SafetyFuelCard({
    super.key,
    required this.estimatedUsableKm,
    required this.profile,
    required this.nearestFuelAheadM,
    required this.nearestFuelName,
    required this.fuelUncertain,
    required this.riddenSinceFillM,
    required this.onOpenFuel,
    required this.onOpenGuardian,
    required this.onTellWhy,
    this.stopReasonText,
    this.queuedStopReason,
  });

  @override
  Widget build(BuildContext context) {
    final estimate = estimatedUsableKm;
    String fuelTitle;
    String fuelSubtitle;
    Color fuelColor = AppTheme.brand;

    if (estimate != null) {
      fuelTitle = 'Fuel range: ${estimate.floor()} km remaining';
      if (estimate <= 60) {
        fuelColor = AppTheme.sos;
        fuelSubtitle = nearestFuelAheadM != null
            ? 'LOW FUEL: Next station in ${formatDistanceRounded(nearestFuelAheadM!)}'
            : 'LOW FUEL: Please plan a refuel stop';
      } else if (nearestFuelAheadM != null) {
        final name = nearestFuelName ?? 'Station';
        fuelSubtitle = '$name in ${formatDistanceRounded(nearestFuelAheadM!)} ahead';
      } else {
        fuelSubtitle = 'Ridden ${(riddenSinceFillM / 1000).toStringAsFixed(1)} km · Range healthy';
      }
    } else if (profile != null && profile!.valid) {
      fuelTitle = 'Fuel profile: ${profile!.rangeKm.floor()} km full range';
      fuelSubtitle = 'Tap to update fuel level';
    } else {
      fuelTitle = 'Fuel estimate & refuel';
      fuelSubtitle = 'Set up motorcycle mileage & tank capacity';
    }

    final reason = stopReasonText ?? '';
    final reasonSubtitle = queuedStopReason ?? (reason.isEmpty ? 'Tap to inform convoy why you stopped' : reason);

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
          _CardTile(
            key: const Key('sheet_row_fuel_status'),
            icon: Icons.local_gas_station_rounded,
            iconColor: fuelColor,
            title: fuelTitle,
            subtitle: fuelSubtitle,
            onTap: onOpenFuel,
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: fuelColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'REFUEL',
                style: TextStyle(color: fuelColor, fontSize: 11, fontWeight: FontWeight.w800),
              ),
            ),
          ),
          const Divider(height: 1),
          _CardTile(
            key: const Key('sheet_row_guardian'),
            icon: Icons.shield_rounded,
            iconColor: AppTheme.accentText,
            title: 'Share Ride Guardian link',
            subtitle: 'Live web tracking link with PIN protection for family or friends',
            onTap: onOpenGuardian,
            trailing: Icon(Icons.share_rounded, size: 20, color: AppTheme.accentText),
          ),
          const Divider(height: 1),
          _CardTile(
            icon: Icons.pause_circle_outline_rounded,
            iconColor: AppTheme.warnText,
            title: stopReasonText?.isEmpty == true ? 'Tell the group why you stop' : 'Your stop reason',
            subtitle: reasonSubtitle,
            onTap: onTellWhy,
          ),
        ],
      ),
    );
  }
}

class ConvoyCommsCard extends StatelessWidget {
  final ConvoyModel convoy;
  final VoidCallback onShareInvite;
  final VoidCallback onCopyCode;
  final VoidCallback onOpenIntercom;
  final VoidCallback onOpenGroupSettings;
  final VoidCallback? onShareEta;
  final String? etaSubtitle;

  const ConvoyCommsCard({
    super.key,
    required this.convoy,
    required this.onShareInvite,
    required this.onCopyCode,
    required this.onOpenIntercom,
    required this.onOpenGroupSettings,
    this.onShareEta,
    this.etaSubtitle,
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
          // Invite code row
          Padding(
            padding: const EdgeInsets.all(Space.s16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('INVITE CODE', style: AppText.overline),
                      const SizedBox(height: 4),
                      Text(
                        convoy.joinCode,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.headline.copyWith(
                          letterSpacing: 4,
                          fontWeight: FontWeight.w900,
                          color: AppTheme.brand,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy_rounded, size: 20),
                  tooltip: 'Copy code',
                  onPressed: onCopyCode,
                ),
                const SizedBox(width: Space.s4),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  ),
                  onPressed: onShareInvite,
                  icon: const Icon(Icons.share_rounded, size: 16),
                  label: const Text('Share', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          _CardTile(
            icon: Icons.headset_mic_rounded,
            iconColor: AppTheme.brand,
            title: 'Intercom options',
            subtitle: 'Microphone, VOX hands-free, and audio routing',
            onTap: onOpenIntercom,
          ),
          const Divider(height: 1),
          _CardTile(
            icon: Icons.tune_rounded,
            iconColor: AppTheme.accentText,
            title: 'Group settings',
            subtitle: 'Ride name, convoy speed limit, and member controls',
            onTap: onOpenGroupSettings,
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

class RideControlsCard extends StatelessWidget {
  final bool isLead;
  final bool isPaused;
  final VoidCallback onTogglePause;
  final VoidCallback onEndRide;
  final VoidCallback onLeaveRide;

  const RideControlsCard({
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
              side: BorderSide(color: isPaused ? AppTheme.accentText : AppTheme.warnText, width: 1.5),
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: onTogglePause,
            icon: Icon(isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded),
            label: Text(
              isPaused ? 'Resume Convoy Ride' : 'Pause Convoy Ride',
              style: const TextStyle(fontWeight: FontWeight.bold),
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
                    minimumSize: const Size(0, 50),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: onEndRide,
                  icon: const Icon(Icons.flag_rounded, size: 20),
                  label: const Text('End Ride', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(width: Space.s12),
            ],
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: StatusColors.critical,
                  side: BorderSide(color: StatusColors.critical, width: 1.5),
                  minimumSize: const Size(0, 50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: onLeaveRide,
                icon: const Icon(Icons.logout_rounded, size: 20),
                label: const Text('Leave Ride', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _CardTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;

  const _CardTile({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.s16, vertical: Space.s12),
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
            if (trailing != null) ...[
              const SizedBox(width: Space.s8),
              trailing!,
            ] else ...[
              const SizedBox(width: Space.s8),
              Icon(Icons.chevron_right_rounded, size: 20, color: AppTheme.muted),
            ],
          ],
        ),
      ),
    );
  }
}
