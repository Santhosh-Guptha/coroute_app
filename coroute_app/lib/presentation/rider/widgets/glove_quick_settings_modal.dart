import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/config/feature_gates.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/theme_controller.dart';
import '../../../core/ui/ui.dart';
import '../../../data/services/intercom_service.dart';
import '../../../data/services/settings_service.dart';
import '../../ride/fuel_sheet.dart';
import '../../ride/guardian_sheet.dart';

/// Ultra-clean, minimal, glove-friendly sheet for the live cockpit.
///
/// Designed for riders wearing thick motorcycle gloves:
/// - Oversized touch targets (>= 60 dp rows; entire row toggles).
/// - Exactly 4 essential, high-impact in-flight toggles:
///   1. Voice Alerts & Intercom (Mute/Unmute voice and intercom audio)
///   2. Sunlight Mode (High-contrast AMOLED outdoor HUD strictly gated by [Feature.sunlightHudMode])
///   3. Battery Conserve (Standard vs Endurance Low-Data mode)
///   4. Screen Always-On (Prevent display sleeping while mounted)
/// - Clean quick actions: Fuel and Guardian (strictly gated by [Feature.guardianLiveShare]).
/// - ZERO emojis, ASCII hyphens only.
class GloveQuickSettingsModal extends StatelessWidget {
  final SettingsService? settingsService;
  final IntercomService? intercomService;
  final bool keepScreenOn;
  final bool autoFollow;
  final VoidCallback onToggleKeepScreenOn;
  final VoidCallback? onToggleAutoFollow;
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
    this.autoFollow = true,
    required this.onToggleKeepScreenOn,
    this.onToggleAutoFollow,
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
    bool autoFollow = true,
    required VoidCallback onToggleKeepScreenOn,
    VoidCallback? onToggleAutoFollow,
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
        backgroundColor: Colors.transparent,
        barrierColor: const Color(0xFF15232E).withOpacity(0.5),
        builder: (ctx) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: GloveQuickSettingsModal(
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

    // 1. Voice Alerts & Intercom State
    final voiceAlertsOn = settings?.voiceAnnounceAllAlerts ?? true;
    final isMicMuted = intercom?.isMicMuted ?? false;
    final isDeafened = intercom?.isDeafened ?? false;
    final isVoiceAndIntercomOn = voiceAlertsOn && !isMicMuted && !isDeafened;

    // 2. Sunlight Mode (Gated by FeatureGates)
    final isSunlightUnlocked = FeatureGates.isUnlocked(Feature.sunlightHudMode);
    final isSunlightActive = isSunlightUnlocked && (themeCtrl?.preference == ThemePreference.light);

    // 3. Battery Conserve
    final batteryConserveOn = settings?.lowData ?? false;

    // 4. Screen Always-On
    final screenAlwaysOn = keepScreenOn;

    // Guardian Unlocked status
    final isGuardianUnlocked = FeatureGates.isUnlocked(Feature.guardianLiveShare);

    final toggles = [
      _QuickSettingItem(
        key: const Key('quick_setting_voice_alerts'),
        label: 'Voice & Intercom',
        subtitle: isVoiceAndIntercomOn
            ? 'Voice alerts & intercom live'
            : 'All voice prompts and intercom muted',
        icon: isVoiceAndIntercomOn ? Icons.volume_up_rounded : Icons.volume_off_rounded,
        isActive: isVoiceAndIntercomOn,
        isLocked: false,
        onToggle: () {
          final next = !isVoiceAndIntercomOn;
          settings?.setVoiceAnnounceAllAlerts(next);
          if (intercom != null) {
            intercom.setMicMuted(!next);
            intercom.setDeafened(!next);
            if (next) {
              intercom.setMode(IntercomMode.vox);
            }
          }
          onSettingToggled?.call('Voice & Intercom', next);
          onSettingToggled?.call('Voice Alerts', next);
        },
      ),
      _QuickSettingItem(
        key: const Key('quick_setting_sunlight_mode'),
        label: 'Sunlight Mode',
        subtitle: !isSunlightUnlocked
            ? 'Requires Pro Rider plan · Tap to unlock'
            : (isSunlightActive
                ? 'High-contrast AMOLED outdoor HUD active'
                : 'Auto daytime/night ambient contrast'),
        icon: Icons.wb_sunny_rounded,
        isActive: isSunlightActive,
        isLocked: !isSunlightUnlocked,
        onToggle: () {
          if (!isSunlightUnlocked) {
            FeatureGates.showUpgradeModal(context, Feature.sunlightHudMode);
            return;
          }
          final next = !isSunlightActive;
          themeCtrl?.setPreference(next ? ThemePreference.light : ThemePreference.auto);
          onSettingToggled?.call('Sunlight Mode', next);
        },
      ),
      _QuickSettingItem(
        key: const Key('quick_setting_battery_conserve'),
        label: 'Battery Conserve',
        subtitle: batteryConserveOn
            ? 'Endurance low-data & throttled sync'
            : 'Standard live telemetry & sync rate',
        icon: Icons.battery_saver_rounded,
        isActive: batteryConserveOn,
        isLocked: false,
        onToggle: () {
          final next = !batteryConserveOn;
          settings?.setLowData(next);
          onSettingToggled?.call('Battery Conserve', next);
        },
      ),
      _QuickSettingItem(
        key: const Key('quick_setting_screen_always_on'),
        label: 'Screen Always-On',
        subtitle: screenAlwaysOn
            ? 'Display stays awake while mounted'
            : 'Follow phone display sleep timeout',
        icon: Icons.screen_lock_portrait_rounded,
        isActive: screenAlwaysOn,
        isLocked: false,
        onToggle: () {
          onToggleKeepScreenOn();
          onSettingToggled?.call('Screen Always-On', !keepScreenOn);
          onSettingToggled?.call('Screen Always On', !keepScreenOn);
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
                      Text('Cockpit Quick Settings',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.headline.copyWith(fontSize: 18)),
                      const SizedBox(height: 2),
                      Text(
                        '4 essential in-flight controls sized for gloves',
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
                      isLocked: toggles[i].isLocked,
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
                    label: isGuardianUnlocked ? 'Guardian link' : 'Guardian (Locked)',
                    icon: isGuardianUnlocked ? Icons.verified_user_outlined : Icons.lock_rounded,
                    tone: isGuardianUnlocked ? DsButtonTone.outline : DsButtonTone.warn,
                    height: 54,
                    fontSize: 13,
                    onPressed: () {
                      if (!isGuardianUnlocked) {
                        FeatureGates.showUpgradeModal(context, Feature.guardianLiveShare);
                        return;
                      }
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
  final bool isLocked;
  final VoidCallback onToggle;

  const _QuickSettingItem({
    required this.key,
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.isActive,
    required this.isLocked,
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
  final bool isLocked;
  final bool divider;
  final VoidCallback onToggle;

  const _GloveSettingRow({
    super.key,
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.isActive,
    required this.isLocked,
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
                  color: isLocked
                      ? AppTheme.warnTint
                      : (isActive ? AppTheme.tint : AppTheme.soft),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  size: 20,
                  color: isLocked
                      ? AppTheme.warnText
                      : (isActive ? AppTheme.accentText : AppTheme.muted),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            label,
                            style: AppText.body.copyWith(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.text,
                            ),
                          ),
                        ),
                        if (isLocked) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppTheme.warnTint,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: AppTheme.warnBorder, width: 0.8),
                            ),
                            child: Text(
                              'PRO',
                              style: TextStyle(
                                color: AppTheme.warnText,
                                fontSize: 9,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(
                        color: isLocked ? AppTheme.warnText : AppTheme.text2,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (isLocked)
                IconButton(
                  icon: Icon(Icons.lock_rounded, size: 22, color: AppTheme.warnText),
                  tooltip: 'Requires upgrade',
                  onPressed: onToggle,
                )
              else
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
