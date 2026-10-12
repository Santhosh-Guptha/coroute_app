import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui_format.dart';
import '../../../core/ui/ui_tokens.dart';
import '../../../data/models/convoy_model.dart';
import '../../../data/models/rider_model.dart';
import '../../../data/services/convoy_service.dart';
import '../../../data/services/intercom_service.dart';
import '../../../data/services/route_essentials_service.dart';
import '../../../data/services/safety_service.dart';
import '../../../data/services/settings_service.dart';
import '../../ride/fuel_sheet.dart';
import '../../ride/guardian_sheet.dart';
import 'glove_quick_settings_modal.dart';
import 'quick_stop_reason_modal.dart';

/// Spoken voice alert mode cycles for in-flight rider convenience.
enum CockpitVoiceMode {
  allAlerts(
    label: 'All Alerts Spoken',
    icon: Icons.volume_up_rounded,
  ),
  criticalOnly(
    label: 'Critical SOS Only',
    icon: Icons.warning_amber_rounded,
  ),
  nightLoud(
    label: 'Night Extra Loud',
    icon: Icons.nights_stay_rounded,
  );

  final String label;
  final IconData icon;

  const CockpitVoiceMode({
    required this.label,
    required this.icon,
  });

  CockpitVoiceMode next() {
    switch (this) {
      case CockpitVoiceMode.allAlerts:
        return CockpitVoiceMode.criticalOnly;
      case CockpitVoiceMode.criticalOnly:
        return CockpitVoiceMode.nightLoud;
      case CockpitVoiceMode.nightLoud:
        return CockpitVoiceMode.allAlerts;
    }
  }
}

/// Glove-friendly, high-contrast Cockpit Quick-Action Shortcuts Dock.
///
/// Provides motorcycle riders with 1-tap thumb-accessible controls:
/// 1. Voice Mode Quick Toggle (All Alerts Spoken <-> Critical SOS Only <-> Night Extra Loud).
/// 2. Quick Stop Reason Picker (Opens modal with 4 oversized buttons).
/// 3. Quick Essentials Radar Jump (Shows nearest corridor essential, 1-tap opens corridor).
/// 4. Intercom Mic Mute/VOX Toggle (Rapid toggle without opening options sheet).
/// 5. Glove Quick Settings Grid (Opens 2x3 grid of top in-flight toggles).
///
/// Strict CoRoute Standards:
/// - Glove-sized touch targets (minimum 52-56dp).
/// - High-contrast icons and glowing active borders.
/// - ZERO emojis, ASCII hyphens only.
class CockpitShortcutsDock extends StatefulWidget {
  final ConvoyModel convoy;
  final RiderModel me;
  final RouteEssentialsService? essentialsService;
  final SettingsService? settingsService;
  final IntercomService? intercomService;
  final bool keepScreenOn;
  final bool autoFollow;
  final VoidCallback onToggleKeepScreenOn;
  final VoidCallback onToggleAutoFollow;
  final VoidCallback onEssentialsRadarTap;
  final void Function(String message, IconData icon, [Color? color])? onHudToast;

  const CockpitShortcutsDock({
    super.key,
    required this.convoy,
    required this.me,
    this.essentialsService,
    this.settingsService,
    this.intercomService,
    required this.keepScreenOn,
    required this.autoFollow,
    required this.onToggleKeepScreenOn,
    required this.onToggleAutoFollow,
    required this.onEssentialsRadarTap,
    this.onHudToast,
  });

  @override
  State<CockpitShortcutsDock> createState() => _CockpitShortcutsDockState();
}

class _CockpitShortcutsDockState extends State<CockpitShortcutsDock> {
  CockpitVoiceMode _voiceMode = CockpitVoiceMode.allAlerts;

  @override
  void initState() {
    super.initState();
    _initVoiceMode();
    widget.settingsService?.addListener(_onExternalChange);
    widget.intercomService?.addListener(_onExternalChange);
  }

  @override
  void didUpdateWidget(covariant CockpitShortcutsDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.settingsService, widget.settingsService)) {
      oldWidget.settingsService?.removeListener(_onExternalChange);
      widget.settingsService?.addListener(_onExternalChange);
    }
    if (!identical(oldWidget.intercomService, widget.intercomService)) {
      oldWidget.intercomService?.removeListener(_onExternalChange);
      widget.intercomService?.addListener(_onExternalChange);
    }
  }

  @override
  void dispose() {
    widget.settingsService?.removeListener(_onExternalChange);
    widget.intercomService?.removeListener(_onExternalChange);
    super.dispose();
  }

  void _onExternalChange() {
    if (mounted) setState(() {});
  }

  void _initVoiceMode() {
    final settings = widget.settingsService;
    if (settings != null) {
      if (!settings.voiceAnnounceAllAlerts || !settings.voiceWarnings) {
        _voiceMode = CockpitVoiceMode.criticalOnly;
      } else {
        _voiceMode = CockpitVoiceMode.allAlerts;
      }
    }
  }

  void _cycleVoiceMode(SettingsService? settings) {
    final nextMode = _voiceMode.next();
    setState(() => _voiceMode = nextMode);

    if (settings != null) {
      switch (nextMode) {
        case CockpitVoiceMode.allAlerts:
          settings.setVoiceAnnounceAllAlerts(true);
          settings.setVoiceCritical(true);
          settings.setVoiceWarnings(true);
          settings.setSpeakMoreAfterDark(false);
          break;
        case CockpitVoiceMode.criticalOnly:
          settings.setVoiceAnnounceAllAlerts(false);
          settings.setVoiceCritical(true);
          settings.setVoiceWarnings(false);
          settings.setSpeakMoreAfterDark(false);
          break;
        case CockpitVoiceMode.nightLoud:
          settings.setVoiceAnnounceAllAlerts(true);
          settings.setVoiceCritical(true);
          settings.setVoiceWarnings(true);
          settings.setSpeakMoreAfterDark(true);
          break;
      }
    }

    final accent = nextMode == CockpitVoiceMode.nightLoud
        ? AppTheme.devmonksPurple
        : (nextMode == CockpitVoiceMode.criticalOnly ? AppTheme.hyperAmber : AppTheme.neonCyan);

    widget.onHudToast?.call('Voice: ${nextMode.label}', nextMode.icon, accent);
  }

  void _openStopReasonPicker(BuildContext context, ConvoyService convoyService) {
    QuickStopReasonModal.show(
      context,
      convoyService: convoyService,
      userId: widget.me.userId,
      currentReason: widget.me.statusReason,
      onBroadcast: (reason, label) {
        widget.onHudToast?.call(
          'Broadcast: $label',
          Icons.pause_circle_filled_rounded,
          AppTheme.hyperAmber,
        );
      },
    );
  }

  void _toggleIntercom(IntercomService? intercom) {
    if (intercom == null) return;
    if (intercom.isMicMuted) {
      intercom.setMicMuted(false);
      intercom.setMode(IntercomMode.vox);
      if (mounted) setState(() {});
      widget.onHudToast?.call(
        'Intercom: VOX Hands-free Active',
        Icons.record_voice_over_rounded,
        AppTheme.neonCyan,
      );
    } else {
      intercom.setMicMuted(true);
      if (mounted) setState(() {});
      widget.onHudToast?.call(
        'Intercom: Mic Muted',
        Icons.mic_off_rounded,
        AppTheme.laserRed,
      );
    }
  }

  void _openQuickSettings(BuildContext context, SettingsService? settings, IntercomService? intercom) {
    GloveQuickSettingsModal.show(
      context,
      settingsService: settings,
      intercomService: intercom,
      keepScreenOn: widget.keepScreenOn,
      autoFollow: widget.autoFollow,
      onToggleKeepScreenOn: widget.onToggleKeepScreenOn,
      onToggleAutoFollow: widget.onToggleAutoFollow,
      groupId: widget.convoy.groupId,
      onSettingToggled: (name, isEnabled) {
        widget.onHudToast?.call(
          '$name: ${isEnabled ? "ON" : "OFF"}',
          Icons.tune_rounded,
          isEnabled ? AppTheme.neonCyan : AppTheme.textSecondary,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settingsService ??
        (context.mounted ? Provider.of<SettingsService?>(context, listen: false) : null);
    final intercom = widget.intercomService ??
        (context.mounted ? Provider.of<IntercomService?>(context, listen: false) : null);
    final convoyService = context.mounted
        ? Provider.of<ConvoyService?>(context, listen: false)
        : null;

    final isStopped = widget.me.statusReason.isNotEmpty;

    // Upcoming nearest essential for Radar jump
    final essentials = widget.essentialsService;
    final nearest = essentials?.upcoming.firstOrNull;
    final nearestDist = nearest?.aheadM(essentials?.progressM ?? 0);

    IconData radarIcon = Icons.radar_rounded;
    String radarLabel = 'Radar';
    if (nearest != null) {
      if (nearest.category == 'FUEL') {
        radarIcon = Icons.local_gas_station_rounded;
      } else if (nearest.category == 'HOSPITAL') {
        radarIcon = Icons.medical_services_rounded;
      } else if (nearest.category == 'TYRE' || nearest.category == 'REPAIR') {
        radarIcon = Icons.build_rounded;
      }
      if (nearestDist != null && nearestDist > 0) {
        radarLabel = formatDistanceRounded(nearestDist);
      }
    }

    // Safety & Fuel info
    final safety = context.mounted
        ? Provider.of<SafetyService?>(context, listen: false)
        : null;
    final estimate = safety?.estimatedUsableKm;
    String? fuelBadge;
    Color fuelColor = AppTheme.neonCyan;
    bool fuelActive = false;
    if (estimate != null) {
      fuelBadge = '${estimate.floor()}k';
      fuelActive = true;
      if (estimate < 25) {
        fuelColor = AppTheme.laserRed;
      } else if (estimate < 50) {
        fuelColor = AppTheme.hyperAmber;
      }
    }

    // Intercom status
    final isMicMuted = intercom?.isMicMuted ?? false;
    final isVoxMode = (intercom?.mode == IntercomMode.vox);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.s8, vertical: Space.s8),
      decoration: BoxDecoration(
        color: AppTheme.obsidianVoid.withOpacity(0.92),
        borderRadius: Radii.lgAll,
        border: Border.all(color: AppTheme.glassBorder, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: AppTheme.shadow,
            blurRadius: 16.0,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: AppTheme.neonCyan.withOpacity(0.12),
            blurRadius: 10.0,
            spreadRadius: 1.0,
          ),
        ],
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 1. Voice Mode Quick Toggle
            _DockButton(
              key: const Key('cockpit_dock_voice_toggle'),
              icon: _voiceMode.icon,
              tooltip: 'Voice: ${_voiceMode.label}',
              activeColor: _voiceMode == CockpitVoiceMode.nightLoud
                  ? AppTheme.devmonksPurple
                  : (_voiceMode == CockpitVoiceMode.criticalOnly
                      ? AppTheme.hyperAmber
                      : AppTheme.neonCyan),
              isActive: true,
              onTap: () => _cycleVoiceMode(settings),
            ),
            const SizedBox(width: Space.s8),

            // 2. Ride Guardian Link Share
            _DockButton(
              key: const Key('cockpit_dock_guardian'),
              icon: Icons.shield_rounded,
              badgeText: 'Share',
              tooltip: 'Ride Guardian: Share live tracking link',
              activeColor: AppTheme.neonCyan,
              isActive: true,
              onTap: () => showGuardianSheet(context, groupId: widget.convoy.groupId),
            ),
            const SizedBox(width: Space.s8),

            // 3. Fuel Range & Quick Refuel
            _DockButton(
              key: const Key('cockpit_dock_fuel'),
              icon: Icons.local_gas_station_rounded,
              badgeText: fuelBadge,
              tooltip: estimate != null ? 'Fuel Range: ${estimate.floor()} km' : 'Fuel: Confirm refuel or profile',
              activeColor: fuelColor,
              isActive: fuelActive,
              onTap: () => showFuelSheet(context),
            ),
            const SizedBox(width: Space.s8),

            // 4. Quick Stop Reason Picker
            _DockButton(
              key: const Key('cockpit_dock_stop_reason'),
              icon: isStopped ? Icons.pause_circle_filled_rounded : Icons.report_problem_rounded,
              tooltip: isStopped ? 'Stop: ${widget.me.statusReason}' : 'Report Stop Reason',
              activeColor: AppTheme.hyperAmber,
              isActive: isStopped,
              onTap: () {
                if (convoyService != null) {
                  _openStopReasonPicker(context, convoyService);
                }
              },
            ),
            const SizedBox(width: Space.s8),

            // 5. Quick Essentials Radar Jump
            _DockButton(
              key: const Key('cockpit_dock_essentials_radar'),
              icon: radarIcon,
              badgeText: radarLabel != 'Radar' ? radarLabel : null,
              tooltip: 'Essentials Radar: $radarLabel',
              activeColor: AppTheme.neonCyan,
              isActive: nearest != null,
              onTap: widget.onEssentialsRadarTap,
            ),
            const SizedBox(width: Space.s8),

            // 6. Intercom Mic Mute / VOX Toggle
            _DockButton(
              key: const Key('cockpit_dock_intercom_toggle'),
              icon: isMicMuted
                  ? Icons.mic_off_rounded
                  : (isVoxMode ? Icons.record_voice_over_rounded : Icons.mic_rounded),
              tooltip: isMicMuted
                  ? 'Mic Muted - Tap for VOX'
                  : (isVoxMode ? 'VOX Active - Tap to Mute' : 'PTT - Tap to Mute'),
              activeColor: isMicMuted
                  ? AppTheme.laserRed
                  : (isVoxMode ? AppTheme.neonCyan : AppTheme.hyperAmber),
              isActive: isMicMuted || isVoxMode,
              onTap: () => _toggleIntercom(intercom),
            ),
            const SizedBox(width: Space.s8),

            // 7. Glove Quick Settings Grid Button
            _DockButton(
              key: const Key('cockpit_dock_quick_settings'),
              icon: Icons.tune_rounded,
              tooltip: 'Glove Quick Settings',
              activeColor: AppTheme.neonCyan,
              isActive: false,
              onTap: () => _openQuickSettings(context, settings, intercom),
            ),
          ],
        ),
      ),
    );
  }
}

class _DockButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color activeColor;
  final bool isActive;
  final String? badgeText;
  final VoidCallback onTap;

  const _DockButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.activeColor,
    required this.isActive,
    this.badgeText,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: isActive ? activeColor.withOpacity(0.18) : AppTheme.slateCard,
          borderRadius: Radii.mdAll,
          child: InkWell(
            borderRadius: Radii.mdAll,
            onTap: onTap,
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                borderRadius: Radii.mdAll,
                border: Border.all(
                  color: isActive ? activeColor : AppTheme.subtleBorder,
                  width: isActive ? 2.0 : 1.0,
                ),
                boxShadow: isActive
                    ? [
                        BoxShadow(
                          color: activeColor.withOpacity(0.35),
                          blurRadius: 8.0,
                          spreadRadius: 1.0,
                        ),
                      ]
                    : null,
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    icon,
                    size: 26,
                    color: isActive ? activeColor : AppTheme.textPrimary,
                  ),
                  if (badgeText != null)
                    Positioned(
                      bottom: 2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0.5),
                        decoration: BoxDecoration(
                          color: AppTheme.obsidianVoid,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: activeColor, width: 0.8),
                        ),
                        child: Text(
                          badgeText!,
                          style: TextStyle(
                            color: activeColor,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            height: 1.1,
                          ),
                          maxLines: 1,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
