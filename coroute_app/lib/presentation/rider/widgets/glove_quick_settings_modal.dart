import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/theme_controller.dart';
import '../../../core/ui/ui.dart';
import '../../../data/services/intercom_service.dart';
import '../../../data/services/settings_service.dart';
import '../../ride/fuel_sheet.dart';
import '../../ride/guardian_sheet.dart';

/// The cockpit's quick settings: three big in-ride toggles, sized for gloves
/// (tiles >= 96 dp tall; the whole tile toggles). Everything else is in Settings.
///   1. Voice: mute or unmute spoken alerts and the intercom (emergencies always speak).
///   2. Night map: dark map now, or back to automatic.
///   3. Battery saver: on, or automatic at 20 % (round 9: its only switch; no Settings row).
/// 3.55 minimal settings: the screen always stays on while riding (battery saver may dim it),
/// so it has no toggle here; [keepScreenOn] / [onToggleKeepScreenOn] are kept for callers.
/// Quick actions: Guardian link, Fuel and (when given) offline voice navigation.
class GloveQuickSettingsModal extends StatefulWidget {
  final SettingsService? settingsService;
  final IntercomService? intercomService;
  final bool keepScreenOn;
  final VoidCallback? onToggleKeepScreenOn;
  final void Function(String name, bool isEnabled)? onSettingToggled;
  final String? groupId;
  final VoidCallback? onOpenGuardian;
  final VoidCallback? onOpenFuel;
  final VoidCallback? onLaunchOfflineNav;

  const GloveQuickSettingsModal({
    super.key,
    this.settingsService,
    this.intercomService,
    this.keepScreenOn = true,
    this.onToggleKeepScreenOn,
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
    bool keepScreenOn = true,
    VoidCallback? onToggleKeepScreenOn,
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
  State<GloveQuickSettingsModal> createState() => _GloveQuickSettingsModalState();
}

class _GloveQuickSettingsModalState extends State<GloveQuickSettingsModal> {
  /// Under the tiles: what muting never silences.
  static const String emergencyNote = 'Emergencies are always spoken.';

  @override
  Widget build(BuildContext context) {
    final settings = widget.settingsService ?? (context.mounted ? context.read<SettingsService?>() : null);
    final intercom = widget.intercomService ?? (context.mounted ? context.read<IntercomService?>() : null);
    // 3.55 fix: the rows follow the services. Settings and the intercom were only read, so after a
    // tap the row kept its old state, and a second tap repeated the same change (Voice could not be
    // turned back on without closing the sheet).
    return ListenableBuilder(
      listenable: Listenable.merge([settings, intercom]),
      builder: (context, _) => _content(context, settings, intercom),
    );
  }

  Widget _content(BuildContext context, SettingsService? settings, IntercomService? intercom) {
    final themeCtrl = context.watch<ThemeController?>();

    // 1. Voice: spoken alerts and the intercom together (emergencies always speak).
    final voiceAlertsOn = settings?.voiceWarnings ?? true;
    final isMicMuted = intercom?.isMicMuted ?? false;
    final isDeafened = intercom?.isDeafened ?? false;
    final isVoiceOn = voiceAlertsOn && !isMicMuted && !isDeafened;

    // 2. Night map: dark now, or automatic (by sunrise and sunset).
    final isNightMap = themeCtrl?.preference == ThemePreference.dark;

    // 3. Battery saver (round 9: the only switch for it).
    final batterySaverOn = settings?.batterySaver ?? false;

    final toggles = [
      _QuickSettingItem(
        key: const Key('quick_setting_voice_alerts'),
        label: 'Voice',
        subtitle: isVoiceOn ? 'On' : 'Muted',
        icon: isVoiceOn ? Icons.volume_up_rounded : Icons.volume_off_rounded,
        isActive: isVoiceOn,
        onToggle: () {
          final next = !isVoiceOn;
          settings?.setVoiceWarnings(next);
          if (intercom != null) {
            intercom.setMicMuted(!next);
            intercom.setDeafened(!next);
          }
          widget.onSettingToggled?.call('Voice', next);
        },
      ),
      _QuickSettingItem(
        key: const Key('quick_setting_night_map'),
        label: 'Night map',
        subtitle: isNightMap ? 'On' : 'Auto',
        icon: Icons.dark_mode_rounded,
        isActive: isNightMap,
        onToggle: () {
          final next = !isNightMap;
          themeCtrl?.setPreference(next ? ThemePreference.dark : ThemePreference.auto);
          widget.onSettingToggled?.call('Night map', next);
        },
      ),
      _QuickSettingItem(
        key: const Key('quick_setting_battery_saver'),
        label: 'Battery saver',
        subtitle: batterySaverOn ? 'On' : 'Auto',
        icon: Icons.battery_saver_rounded,
        isActive: batterySaverOn,
        onToggle: () {
          final next = !batterySaverOn;
          settings?.setBatterySaver(next);
          widget.onSettingToggled?.call('Battery saver', next);
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
                        'More in Settings',
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < toggles.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(
                    child: _GloveSettingTile(
                      key: toggles[i].key,
                      label: toggles[i].label,
                      state: toggles[i].subtitle,
                      icon: toggles[i].icon,
                      isActive: toggles[i].isActive,
                      onToggle: toggles[i].onToggle,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Text(emergencyNote, textAlign: TextAlign.center, style: AppText.caption),
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
                      if (widget.onOpenGuardian != null) {
                        widget.onOpenGuardian!();
                      } else if (widget.groupId != null && context.mounted) {
                        showGuardianSheet(context, groupId: widget.groupId!);
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
                      if (widget.onOpenFuel != null) {
                        widget.onOpenFuel!();
                      } else if (context.mounted) {
                        showFuelSheet(context);
                      }
                    },
                  ),
                ),
              ],
            ),
            if (widget.onLaunchOfflineNav != null) ...[
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
                  widget.onLaunchOfflineNav!();
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

/// One big glove-friendly toggle tile: icon, 1-2 word label and its state ("On", "Auto",
/// "Muted"). The whole tile (>= 96 dp tall) toggles; filled with the tint when on.
class _GloveSettingTile extends StatelessWidget {
  final String label;
  final String state;
  final IconData icon;
  final bool isActive;
  final VoidCallback onToggle;

  const _GloveSettingTile({
    super.key,
    required this.label,
    required this.state,
    required this.icon,
    required this.isActive,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final fg = isActive ? AppTheme.accentText : AppTheme.text2;
    return Semantics(
      button: true,
      toggled: isActive,
      label: label,
      value: state,
      excludeSemantics: true,
      child: Material(
        color: isActive ? AppTheme.tint : AppTheme.soft,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.lgAll,
          side: BorderSide(color: isActive ? AppTheme.accentText : AppTheme.border, width: isActive ? 1.5 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onToggle,
          child: Container(
            constraints: const BoxConstraints(minHeight: 96),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 30, color: fg),
                const SizedBox(height: 8),
                Text(
                  label,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body.copyWith(fontWeight: FontWeight.w600, color: AppTheme.text, height: 1.2),
                ),
                const SizedBox(height: 2),
                Text(state, maxLines: 1, style: AppText.label.copyWith(color: fg)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
