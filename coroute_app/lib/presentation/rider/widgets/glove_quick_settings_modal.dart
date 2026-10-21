import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../data/services/intercom_service.dart';
import '../../../data/services/settings_service.dart';
import '../../ride/fuel_sheet.dart';
import '../../ride/guardian_sheet.dart';

/// Glove-friendly sheet listing the six in-flight toggles as oversized
/// switch rows on one card.
///
/// Designed for riders wearing thick motorcycle gloves:
/// - Oversized touch targets (58 dp rows; the whole row toggles).
/// - 6 critical in-flight settings:
///   1. Voice Alerts
///   2. Screen Always On
///   3. Auto-Follow Map
///   4. Intercom VOX
///   5. Battery Conserve
///   6. Ride Guardian
/// - Teal switch when on, grey when off.
/// - ZERO emojis, ASCII hyphens only.
class GloveQuickSettingsModal extends StatelessWidget {
  final SettingsService? settingsService;
  final IntercomService? intercomService;
  final bool keepScreenOn;
  final bool autoFollow;
  final VoidCallback onToggleKeepScreenOn;
  final VoidCallback onToggleAutoFollow;
  final void Function(String name, bool isEnabled)? onSettingToggled;
  final String? groupId;
  final VoidCallback? onOpenGuardian;
  final VoidCallback? onOpenFuel;
  final VoidCallback? onLaunchOfflineNav;

  const GloveQuickSettingsModal({
    super.key,
    this.settingsService,
    this.intercomService,
    required this.keepScreenOn,
    required this.autoFollow,
    required this.onToggleKeepScreenOn,
    required this.onToggleAutoFollow,
    this.onSettingToggled,
    this.groupId,
    this.onOpenGuardian,
    this.onOpenFuel,
    this.onLaunchOfflineNav,
  });

  static Future<void> show(
    BuildContext context, {
    SettingsService? settingsService,
    IntercomService? intercomService,
    required bool keepScreenOn,
    required bool autoFollow,
    required VoidCallback onToggleKeepScreenOn,
    required VoidCallback onToggleAutoFollow,
    void Function(String name, bool isEnabled)? onSettingToggled,
    String? groupId,
    VoidCallback? onOpenGuardian,
    VoidCallback? onOpenFuel,
    VoidCallback? onLaunchOfflineNav,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0xFF15232E).withOpacity(0.5),
      builder: (ctx) => GloveQuickSettingsModal(
        settingsService: settingsService,
        intercomService: intercomService,
        keepScreenOn: keepScreenOn,
        autoFollow: autoFollow,
        onToggleKeepScreenOn: onToggleKeepScreenOn,
        onToggleAutoFollow: onToggleAutoFollow,
        onSettingToggled: onSettingToggled,
        groupId: groupId,
        onOpenGuardian: onOpenGuardian,
        onOpenFuel: onOpenFuel,
        onLaunchOfflineNav: onLaunchOfflineNav,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = settingsService;
    final intercom = intercomService;

    final voiceAlertsOn = settings?.voiceAnnounceAllAlerts ?? true;
    final intercomVoxOn = (intercom?.mode == IntercomMode.vox) && !(intercom?.isMicMuted ?? false);
    final batteryConserveOn = settings?.lowData ?? false;
    final rideGuardianOn = settings?.crashDetection ?? true;

    final cards = [
      _QuickSettingItem(
        key: const Key('quick_setting_voice_alerts'),
        label: 'Voice Alerts',
        subtitle: 'Announce all alerts',
        icon: Icons.campaign_outlined,
        isActive: voiceAlertsOn,
        onToggle: () {
          final next = !voiceAlertsOn;
          settings?.setVoiceAnnounceAllAlerts(next);
          onSettingToggled?.call('Voice Alerts', next);
        },
      ),
      _QuickSettingItem(
        key: const Key('quick_setting_screen_always_on'),
        label: 'Screen Always On',
        subtitle: 'Prevent sleep',
        icon: Icons.light_mode_outlined,
        isActive: keepScreenOn,
        onToggle: () {
          onToggleKeepScreenOn();
          onSettingToggled?.call('Screen Always On', !keepScreenOn);
        },
      ),
      _QuickSettingItem(
        key: const Key('quick_setting_auto_follow_map'),
        label: 'Auto-Follow Map',
        subtitle: 'Keep me centered',
        icon: Icons.my_location_rounded,
        isActive: autoFollow,
        onToggle: () {
          onToggleAutoFollow();
          onSettingToggled?.call('Auto-Follow Map', !autoFollow);
        },
      ),
      _QuickSettingItem(
        key: const Key('quick_setting_intercom_vox'),
        label: 'Intercom VOX',
        subtitle: 'Hands-free voice',
        icon: Icons.record_voice_over_outlined,
        isActive: intercomVoxOn,
        onToggle: () {
          final next = !intercomVoxOn;
          if (intercom != null) {
            intercom.setMode(next ? IntercomMode.vox : IntercomMode.ptt);
            if (next && intercom.isMicMuted) {
              intercom.setMicMuted(false);
            }
          }
          onSettingToggled?.call('Intercom VOX', next);
        },
      ),
      _QuickSettingItem(
        key: const Key('quick_setting_battery_conserve'),
        label: 'Battery Conserve',
        subtitle: 'Low data & battery',
        icon: Icons.battery_saver_outlined,
        isActive: batteryConserveOn,
        onToggle: () {
          final next = !batteryConserveOn;
          settings?.setLowData(next);
          onSettingToggled?.call('Battery Conserve', next);
        },
      ),
      _QuickSettingItem(
        key: const Key('quick_setting_ride_guardian'),
        label: 'Ride Guardian',
        subtitle: 'Crash detection active',
        icon: Icons.verified_user_outlined,
        isActive: rideGuardianOn,
        onToggle: () {
          final next = !rideGuardianOn;
          settings?.setCrashDetection(next);
          onSettingToggled?.call('Ride Guardian', next);
        },
      ),
    ];

    final media = MediaQuery.of(context);
    final bottom = media.padding.bottom;

    return Container(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.9),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: Radii.sheetTop,
        boxShadow: [
          BoxShadow(color: AppTheme.shadow, blurRadius: 40, offset: const Offset(0, -12)),
        ],
      ),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 28 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(color: AppTheme.border2, borderRadius: BorderRadius.circular(3)),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: AppTheme.tint, borderRadius: BorderRadius.circular(16)),
                  child: Icon(Icons.tune_rounded, color: AppTheme.accentText, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Quick settings', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.headline),
                      const SizedBox(height: 2),
                      Text(
                        'In-flight toggles sized for gloves',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.label,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                DsRoundButton(
                  key: const Key('quick_settings_close'),
                  icon: Icons.close_rounded,
                  label: 'Close settings',
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 18),
            DsCard(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < cards.length; i++)
                    _GloveSettingRow(
                      key: cards[i].key,
                      label: cards[i].label,
                      subtitle: cards[i].subtitle,
                      icon: cards[i].icon,
                      isActive: cards[i].isActive,
                      divider: i < cards.length - 1,
                      onToggle: cards[i].onToggle,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            // In-flight Quick Actions (Ride Guardian & Fuel)
            Row(
              children: [
                Expanded(
                  child: DsButton(
                    key: const Key('quick_action_guardian_share'),
                    label: 'Guardian link',
                    icon: Icons.verified_user_outlined,
                    tone: DsButtonTone.outline,
                    height: 52,
                    fontSize: 14,
                    onPressed: () {
                      Navigator.of(context).pop();
                      if (onOpenGuardian != null) {
                        onOpenGuardian!();
                      } else if (groupId != null && context.mounted) {
                        showGuardianSheet(context, groupId: groupId!);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DsButton(
                    key: const Key('quick_action_fuel_sheet'),
                    label: 'Fuel / Refuel',
                    icon: Icons.local_gas_station_outlined,
                    tone: DsButtonTone.outline,
                    height: 52,
                    fontSize: 14,
                    onPressed: () {
                      Navigator.of(context).pop();
                      if (onOpenFuel != null) {
                        onOpenFuel!();
                      } else if (context.mounted) {
                        showFuelSheet(context);
                      }
                    },
                  ),
                ),
              ],
            ),
            if (onLaunchOfflineNav != null) ...[
              const SizedBox(height: 10),
              DsButton(
                key: const Key('quick_action_offline_nav'),
                label: 'Offline voice nav',
                icon: Icons.navigation_outlined,
                tone: DsButtonTone.brand,
                height: 52,
                fontSize: 14,
                onPressed: () {
                  Navigator.of(context).pop();
                  onLaunchOfflineNav!();
                },
              ),
            ],
            const SizedBox(height: 10),
            DsButton(
              key: const Key('quick_settings_done'),
              label: 'Done',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickSettingItem {
  final Key key;
  final String label;
  final String subtitle;
  final IconData icon;
  final bool isActive;
  final VoidCallback onToggle;

  const _QuickSettingItem({
    required this.key,
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.isActive,
    required this.onToggle,
  });
}

/// One switch row: teal icon, label, subtitle and a switch. The whole row
/// toggles, so a gloved thumb never has to hit the switch itself.
class _GloveSettingRow extends StatelessWidget {
  final String label;
  final String subtitle;
  final IconData icon;
  final bool isActive;
  final bool divider;
  final VoidCallback onToggle;

  const _GloveSettingRow({
    super.key,
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.isActive,
    required this.divider,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: InkWell(
        onTap: onToggle,
        child: Row(
          children: [
            Icon(icon, size: 22, color: isActive ? AppTheme.accentText : AppTheme.muted),
            const SizedBox(width: 12),
            Expanded(
              child: DsSwitchRow(
                label: label,
                subtitle: subtitle,
                value: isActive,
                divider: divider,
                onChanged: (_) => onToggle(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
