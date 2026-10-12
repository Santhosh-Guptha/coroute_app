import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui_tokens.dart';
import '../../../data/services/intercom_service.dart';
import '../../../data/services/settings_service.dart';

/// Glove-friendly modal displaying an oversized 2x3 grid of in-flight toggle cards.
///
/// Designed for riders wearing thick motorcycle gloves:
/// - Oversized touch targets (>64dp tall).
/// - 6 critical in-flight settings:
///   1. Voice Alerts
///   2. Screen Always On
///   3. Auto-Follow Map
///   4. Intercom VOX
///   5. Battery Conserve
///   6. Ride Guardian
/// - High-contrast glowing borders when active.
/// - Clear ON / OFF badge indicators.
/// - ZERO emojis, ASCII hyphens only.
class GloveQuickSettingsModal extends StatelessWidget {
  final SettingsService? settingsService;
  final IntercomService? intercomService;
  final bool keepScreenOn;
  final bool autoFollow;
  final VoidCallback onToggleKeepScreenOn;
  final VoidCallback onToggleAutoFollow;
  final void Function(String name, bool isEnabled)? onSettingToggled;

  const GloveQuickSettingsModal({
    super.key,
    this.settingsService,
    this.intercomService,
    required this.keepScreenOn,
    required this.autoFollow,
    required this.onToggleKeepScreenOn,
    required this.onToggleAutoFollow,
    this.onSettingToggled,
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
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.75),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: Space.s16, vertical: Space.s24),
        child: GloveQuickSettingsModal(
          settingsService: settingsService,
          intercomService: intercomService,
          keepScreenOn: keepScreenOn,
          autoFollow: autoFollow,
          onToggleKeepScreenOn: onToggleKeepScreenOn,
          onToggleAutoFollow: onToggleAutoFollow,
          onSettingToggled: onSettingToggled,
        ),
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
        icon: Icons.campaign_rounded,
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
        icon: Icons.light_mode_rounded,
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
        icon: Icons.record_voice_over_rounded,
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
        icon: Icons.battery_saver_rounded,
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
        icon: Icons.shield_rounded,
        isActive: rideGuardianOn,
        onToggle: () {
          final next = !rideGuardianOn;
          settings?.setCrashDetection(next);
          onSettingToggled?.call('Ride Guardian', next);
        },
      ),
    ];

    return Container(
      constraints: const BoxConstraints(maxWidth: 440),
      decoration: BoxDecoration(
        color: AppTheme.obsidianVoid,
        borderRadius: Radii.lgAll,
        border: Border.all(color: AppTheme.glassBorder, width: 2.0),
        boxShadow: [
          BoxShadow(
            color: AppTheme.shadow,
            blurRadius: 16.0,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.all(Space.s16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Icon(Icons.tune_rounded, color: AppTheme.neonCyan, size: 28),
                      const SizedBox(width: Space.s8),
                      Expanded(
                        child: Text(
                          'Glove Quick Settings',
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('quick_settings_close'),
                  tooltip: 'Close settings',
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  icon: Icon(Icons.close_rounded, color: AppTheme.textSecondary, size: 26),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          const SizedBox(height: Space.s4),
          Text(
            'High-contrast in-flight toggles for gloved riding',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: Space.s16),
          // 2x3 Grid of oversized toggle cards
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: Space.s12,
            crossAxisSpacing: Space.s12,
            childAspectRatio: 1.45,
            children: [
              for (final card in cards)
                _GloveSettingCard(
                  key: card.key,
                  label: card.label,
                  subtitle: card.subtitle,
                  icon: card.icon,
                  isActive: card.isActive,
                  onToggle: card.onToggle,
                ),
            ],
          ),
          const SizedBox(height: Space.s16),
          FilledButton(
            key: const Key('quick_settings_done'),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.slateCard,
              foregroundColor: AppTheme.neonCyan,
              minimumSize: const Size.fromHeight(52),
              shape: const RoundedRectangleBorder(
                borderRadius: Radii.mdAll,
                side: BorderSide(color: Colors.white24, width: 1.5),
              ),
            ),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Done',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
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

class _GloveSettingCard extends StatelessWidget {
  final String label;
  final String subtitle;
  final IconData icon;
  final bool isActive;
  final VoidCallback onToggle;

  const _GloveSettingCard({
    super.key,
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.isActive,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final activeBorderColor = AppTheme.neonCyan;
    return Semantics(
      button: true,
      label: '$label: ${isActive ? "ON" : "OFF"}',
      child: Material(
        color: isActive ? activeBorderColor.withOpacity(0.16) : AppTheme.slateCard,
        borderRadius: Radii.mdAll,
        child: InkWell(
          borderRadius: Radii.mdAll,
          onTap: onToggle,
          child: Container(
            padding: const EdgeInsets.all(Space.s12),
            decoration: BoxDecoration(
              borderRadius: Radii.mdAll,
              border: Border.all(
                color: isActive ? activeBorderColor : AppTheme.subtleBorder,
                width: isActive ? 2.5 : 1.5,
              ),
              boxShadow: isActive
                  ? [
                      BoxShadow(
                        color: activeBorderColor.withOpacity(0.3),
                        blurRadius: 10,
                        spreadRadius: 1,
                      )
                    ]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Icon(
                      icon,
                      size: 26,
                      color: isActive ? activeBorderColor : AppTheme.textSecondary,
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: Space.s8, vertical: 2),
                      decoration: BoxDecoration(
                        color: isActive ? activeBorderColor : Colors.white12,
                        borderRadius: Radii.smAll,
                      ),
                      child: Text(
                        isActive ? 'ON' : 'OFF',
                        style: TextStyle(
                          color: isActive ? Colors.black : AppTheme.textMuted,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: isActive ? AppTheme.textPrimary : AppTheme.textSecondary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
