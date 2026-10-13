import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
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

/// Glove-friendly Cockpit Quick-Action Shortcuts Dock: a floating card with
/// a row of 64 dp icon tiles (canvas "bottom dock").
///
/// Provides motorcycle riders with 1-tap thumb-accessible controls:
/// 1. Voice Mode Quick Toggle (All Alerts Spoken <-> Critical SOS Only <-> Night Extra Loud).
/// 2. Ride Guardian link share.
/// 3. Fuel range and quick refuel.
/// 4. Quick Stop Reason Picker (opens the stop sheet).
/// 5. Quick Essentials Radar Jump (shows nearest corridor essential, 1-tap opens corridor).
/// 6. Intercom Mic Mute/VOX Toggle (rapid toggle without opening options sheet).
/// 7. Glove Quick Settings (opens the in-flight toggles sheet).
///
/// Strict CoRoute Standards:
/// - Glove-sized touch targets (minimum 52-64dp).
/// - High-contrast icons; the active tile is tinted.
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
        : (nextMode == CockpitVoiceMode.criticalOnly ? AppTheme.warnText : AppTheme.accentText);

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
          AppTheme.warnText,
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
        AppTheme.accentText,
      );
    } else {
      intercom.setMicMuted(true);
      if (mounted) setState(() {});
      widget.onHudToast?.call(
        'Intercom: Mic Muted',
        Icons.mic_off_rounded,
        AppTheme.sos,
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
          isEnabled ? AppTheme.accentText : AppTheme.muted,
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
    Color fuelColor = AppTheme.accentText;
    bool fuelActive = false;
    if (estimate != null) {
      fuelBadge = '${estimate.floor()}k';
      fuelActive = true;
      if (estimate < 25) {
        fuelColor = AppTheme.sos;
      } else if (estimate < 50) {
        fuelColor = AppTheme.warnText;
      }
    }

    // Intercom status
    final isMicMuted = intercom?.isMicMuted ?? false;
    final isVoxMode = (intercom?.mode == IntercomMode.vox);

    final tiles = <Widget>[
      // 1. Voice Mode Quick Toggle
      _DockTile(
        key: const Key('cockpit_dock_voice_toggle'),
        icon: _voiceMode.icon,
        label: 'VOICE',
        tooltip: 'Voice: ${_voiceMode.label}',
        activeColor: _voiceMode == CockpitVoiceMode.nightLoud
            ? AppTheme.devmonksPurple
            : (_voiceMode == CockpitVoiceMode.criticalOnly ? AppTheme.warnText : AppTheme.accentText),
        isActive: _voiceMode != CockpitVoiceMode.allAlerts,
        onTap: () => _cycleVoiceMode(settings),
      ),

      // 2. Ride Guardian Link Share
      _DockTile(
        key: const Key('cockpit_dock_guardian'),
        icon: Icons.verified_user_outlined,
        label: 'GUARD',
        tooltip: 'Ride Guardian: Share live tracking link',
        activeColor: AppTheme.accentText,
        isActive: false,
        onTap: () => showGuardianSheet(context, groupId: widget.convoy.groupId),
      ),

      // 3. Fuel Range & Quick Refuel
      _DockTile(
        key: const Key('cockpit_dock_fuel'),
        icon: Icons.local_gas_station_outlined,
        label: fuelBadge ?? 'FUEL',
        tooltip: estimate != null ? 'Fuel Range: ${estimate.floor()} km' : 'Fuel: Confirm refuel or profile',
        activeColor: fuelColor,
        isActive: fuelActive && fuelColor != AppTheme.accentText,
        onTap: () => showFuelSheet(context),
      ),

      // 4. Quick Stop Reason Picker
      _DockTile(
        key: const Key('cockpit_dock_stop_reason'),
        icon: isStopped ? Icons.pause_circle_filled_rounded : Icons.stop_rounded,
        label: 'STOP',
        tooltip: isStopped ? 'Stop: ${widget.me.statusReason}' : 'Report Stop Reason',
        activeColor: AppTheme.warnText,
        iconColor: AppTheme.warnText,
        isActive: isStopped,
        onTap: () {
          if (convoyService != null) {
            _openStopReasonPicker(context, convoyService);
          }
        },
      ),

      // 5. Quick Essentials Radar Jump
      _DockTile(
        key: const Key('cockpit_dock_essentials_radar'),
        icon: radarIcon,
        label: radarLabel != 'Radar' ? radarLabel : 'RADAR',
        tooltip: 'Essentials Radar: $radarLabel',
        activeColor: AppTheme.accentText,
        isActive: nearest != null,
        onTap: widget.onEssentialsRadarTap,
      ),

      // 6. Intercom Mic Mute / VOX Toggle
      _DockTile(
        key: const Key('cockpit_dock_intercom_toggle'),
        icon: isMicMuted
            ? Icons.mic_off_rounded
            : (isVoxMode ? Icons.record_voice_over_rounded : Icons.mic_rounded),
        label: 'MIC',
        tooltip: isMicMuted
            ? 'Mic Muted - Tap for VOX'
            : (isVoxMode ? 'VOX Active - Tap to Mute' : 'PTT - Tap to Mute'),
        activeColor: isMicMuted
            ? AppTheme.sos
            : (isVoxMode ? AppTheme.accentText : AppTheme.warnText),
        isActive: isMicMuted || isVoxMode,
        onTap: () => _toggleIntercom(intercom),
      ),

      // 7. Glove Quick Settings
      _DockTile(
        key: const Key('cockpit_dock_quick_settings'),
        icon: Icons.grid_view_rounded,
        label: 'MORE',
        tooltip: 'Glove Quick Settings',
        activeColor: AppTheme.accentText,
        isActive: false,
        onTap: () => _openQuickSettings(context, settings, intercom),
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(Radii.xl),
        boxShadow: dsFloatingShadow(),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          const gap = 6.0;
          const minTile = 52.0;
          final fits = box.maxWidth.isFinite && (box.maxWidth - gap * (tiles.length - 1)) / tiles.length >= minTile;
          if (fits) {
            return Row(
              children: [
                for (var i = 0; i < tiles.length; i++) ...[
                  if (i > 0) const SizedBox(width: gap),
                  Expanded(child: tiles[i]),
                ],
              ],
            );
          }
          // Narrow screens: fixed 60 dp tiles that scroll sideways so every target stays glove-sized.
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < tiles.length; i++) ...[
                  if (i > 0) const SizedBox(width: gap),
                  SizedBox(width: 60, child: tiles[i]),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// One 64 dp dock tile: soft fill, teal icon, 11/800 uppercase label. Active
/// tiles are tinted with [activeColor].
class _DockTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final Color activeColor;
  final Color? iconColor;
  final bool isActive;
  final VoidCallback onTap;

  const _DockTile({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.activeColor,
    required this.isActive,
    required this.onTap,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: DsIconTile(
          icon: icon,
          label: label.toUpperCase(),
          height: 64,
          iconSize: 22,
          fontSize: 11,
          iconColor: isActive ? activeColor : (iconColor ?? AppTheme.accentText),
          background: isActive ? activeColor.withOpacity(0.14) : AppTheme.soft,
          foreground: isActive ? activeColor : AppTheme.text,
          onTap: onTap,
        ),
      ),
    );
  }
}
