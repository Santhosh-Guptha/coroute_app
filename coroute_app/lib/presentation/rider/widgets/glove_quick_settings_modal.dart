import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/theme_controller.dart';
import '../../../core/ui/ui.dart';
import '../../../data/services/intercom_service.dart';
import '../../../data/services/settings_service.dart';
import '../../ride/fuel_sheet.dart';
import '../../ride/guardian_sheet.dart';

/// The cockpit's quick settings: only in-ride toggles, sized for gloves
/// (>= 64 dp rows; the whole row toggles). Everything else is in Settings.
///   1. Voice: mute or unmute spoken alerts and the intercom (emergencies always speak).
///   2. Night map: dark map now, or back to automatic.
///   3. Battery saver: the same switch as in Settings.
///   4. Screen always on while the phone is mounted.
/// Quick actions: Guardian link, Fuel and (when given) offline voice navigation.
class GloveQuickSettingsModal extends StatelessWidget {
  final SettingsService? settingsService;
  final IntercomService? intercomService;
  final bool keepScreenOn;
  final VoidCallback onToggleKeepScreenOn;
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
    required this.onToggleKeepScreenOn,
    this.onSettingToggled,
    this.groupId,
    this.onOpenGuardian,
    this.onOpenFuel,
    this.onLaunchOfflineNav,
  });

  static bool _isShowing = false;

  static Future<void> show(
    BuildContext context, {
    SettingsService? settingsService,
    IntercomService? intercomService,
    required bool keepScreenOn,
    required VoidCallback onToggleKeepScreenOn,
    void Function(String name, bool isEnabled)? onSettingToggled,
    String? groupId,
    VoidCallback? onOpenGuardian,
    VoidCallback? onOpenFuel,
    VoidCallback? onLaunchOfflineNav,
  }) async {
    if (_isShowing) return;
    _isShowing = true;
    try {
      final screenSize = MediaQuery.sizeOf(context);
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        constraints: BoxConstraints(
          maxWidth: 600,
          maxHeight: screenSize.height * 0.88,
        ),
        isDismissible: true,
        enableDrag: true,
        backgroundColor: Colors.transparent,
        barrierColor: AppScrim.color,
        // Only as tall as the card, at the bottom: with a full-height Center
        // the transparent sheet around the card swallowed taps, so a tap
        // "outside" the card did not close it. Now the space around the card
        // is the scrim and a tap there closes it.
        builder: (ctx) => Align(
          alignment: Alignment.bottomCenter,
          heightFactor: 1.0,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: GloveQuickSettingsModal(
              settingsService: settingsService,
              intercomService: intercomService,
              keepScreenOn: keepScreenOn,
              onToggleKeepScreenOn: onToggleKeepScreenOn,
              onSettingToggled: onSettingToggled,
              groupId: groupId,
              onOpenGuardian: onOpenGuardian,
              onOpenFuel: onOpenFuel,
              onLaunchOfflineNav: onLaunchOfflineNav,
            ),
          ),
        ),
      );
    } finally {
      _isShowing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = settingsService ?? (context.mounted ? context.read<SettingsService?>() : null);
    final intercom = intercomService ?? (context.mounted ? context.read<IntercomService?>() : null);
    final themeCtrl = context.watch<ThemeController?>();

    // 1. Voice: spoken alerts and the intercom together (emergencies always speak).
    final voiceAlertsOn = settings?.voiceWarnings ?? true;
    final isMicMuted = intercom?.isMicMuted ?? false;
    final isDeafened = intercom?.isDeafened ?? false;
    final isVoiceOn = voiceAlertsOn && !isMicMuted && !isDeafened;

    // 2. Night map: dark now, or automatic (by sunrise and sunset).
    final isNightMap = themeCtrl?.preference == ThemePreference.dark;

    // 3. Battery saver (the Settings switch).
    final batterySaverOn = settings?.batterySaver ?? false;

    final toggles = [
      _QuickSettingItem(
        key: const Key('quick_setting_voice_alerts'),
        label: 'Voice',
        subtitle: isVoiceOn ? 'Spoken alerts and talk on' : 'Muted. Emergencies are still spoken.',
        icon: isVoiceOn ? Icons.volume_up_rounded : Icons.volume_off_rounded,
        isActive: isVoiceOn,
        onToggle: () {
          final next = !isVoiceOn;
          settings?.setVoiceWarnings(next);
          if (intercom != null) {
            intercom.setMicMuted(!next);
            intercom.setDeafened(!next);
          }
          onSettingToggled?.call('Voice', next);
        },
      ),
      _QuickSettingItem(
        key: const Key('quick_setting_night_map'),
        label: 'Night map',
        subtitle: isNightMap ? 'Dark map on' : 'Automatic by sunrise and sunset',
        icon: Icons.dark_mode_rounded,
        isActive: isNightMap,
        onToggle: () {
          final next = !isNightMap;
          themeCtrl?.setPreference(next ? ThemePreference.dark : ThemePreference.auto);
          onSettingToggled?.call('Night map', next);
        },
      ),
      _QuickSettingItem(
        key: const Key('quick_setting_battery_saver'),
        label: 'Battery saver',
        subtitle: batterySaverOn ? 'Gentler GPS and a lighter map' : 'Turns on by itself when battery is low',
        icon: Icons.battery_saver_rounded,
        isActive: batterySaverOn,
        onToggle: () {
          final next = !batterySaverOn;
          settings?.setBatterySaver(next);
          onSettingToggled?.call('Battery saver', next);
        },
      ),
      _QuickSettingItem(
        key: const Key('quick_setting_screen_always_on'),
        label: 'Screen always on',
        subtitle: keepScreenOn ? 'The screen stays awake while mounted' : 'Follows the phone\'s sleep time',
        icon: Icons.screen_lock_portrait_rounded,
        isActive: keepScreenOn,
        onToggle: () {
          onToggleKeepScreenOn();
          onSettingToggled?.call('Screen always on', !keepScreenOn);
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
      padding: EdgeInsets.fromLTRB(20, 12, 20, 24 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: AppTheme.border2,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppTheme.tint,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(Icons.tune_rounded, color: AppTheme.accentText, size: 26),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Quick settings',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.headline.copyWith(fontSize: 18)),
                      const SizedBox(height: 2),
                      Text(
                        'In-ride switches. Everything else is in Settings.',
                        maxLines: 1,
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
                  onTap: () {
                    if (context.mounted) Navigator.of(context).maybePop();
                  },
                ),
              ],
            ),
            const SizedBox(height: 18),
            DsCard(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < toggles.length; i++)
                    _GloveSettingRow(
                      key: toggles[i].key,
                      label: toggles[i].label,
                      subtitle: toggles[i].subtitle,
                      icon: toggles[i].icon,
                      isActive: toggles[i].isActive,
                      divider: i < toggles.length - 1,
                      onToggle: toggles[i].onToggle,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            // Minimal in-flight quick actions: Fuel and Ride Guardian (strictly gated)
            Row(
              children: [
                Expanded(
                  child: DsButton(
                    key: const Key('quick_action_guardian_share'),
                    label: 'Guardian link',
                    icon: Icons.verified_user_outlined,
                    tone: DsButtonTone.outline,
                    height: 54,
                    fontSize: 13,
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
                    icon: Icons.local_gas_station_rounded,
                    tone: DsButtonTone.outline,
                    height: 54,
                    fontSize: 13,
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
            const SizedBox(height: 12),
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

/// One oversized glove-friendly switch row.
/// The entire 64 dp row is clickable so thick motorcycle leather gloves never miss.
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
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          decoration: BoxDecoration(
            border: divider ? Border(bottom: BorderSide(color: AppTheme.border)) : null,
          ),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isActive ? AppTheme.tint : AppTheme.soft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 20, color: isActive ? AppTheme.accentText : AppTheme.muted),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: AppText.body.copyWith(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(color: AppTheme.text2, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Switch(
                value: isActive,
                onChanged: (_) => onToggle(),
                activeColor: AppTheme.brand,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
