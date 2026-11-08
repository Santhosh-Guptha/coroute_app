import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/safety_constants.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/ui/ui.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/permissions_service.dart';
import '../../data/services/settings_service.dart';
import '../account/appearance_sheet.dart';
import '../account/edit_profile_screen.dart';
import '../diagnostics/pre_ride_phone_check_screen.dart';
import '../onboarding/permissions_screen.dart';
import '../ride/fuel_sheet.dart';
import '../safety/crash_learning_row.dart';
import '../safety/safety_settings_sheet.dart';
import '../trip_planner/offline_map_manager_screen.dart';
import '../widgets/data_saver_tile.dart';
import '../widgets/feature_switch.dart';
import 'features_guide_screen.dart';

/// The one Settings screen: only the choices a rider really makes, grouped
/// (Ride, Safety, Voice & sound, Map & offline, Account & privacy, Help).
///
/// Safety features are on by default. Turning crash detection off asks first.
/// Everything else (emergency voice, after-dark voice, tunnel mode, the ride
/// notification, saving route maps on Wi-Fi, how long a map alert stays) is
/// decided by the app and has no switch. In-ride quick toggles (mute, battery
/// saver, night map, screen on) live in the cockpit's quick settings.
class SettingsScreen extends StatefulWidget {
  /// Asks for a permission (tests pass a fake); defaults to [PermissionsService.request].
  final Future<bool> Function(String key)? requestPermission;
  const SettingsScreen({super.key, this.requestPermission});

  static const String title = 'Settings';

  /// Opens Settings as a full screen.
  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));

  /// One line for Profile, e.g. "Crash detection on" or "Crash detection off".
  static String summary(SettingsService s) =>
      '${SafetyTexts.crashTitle} ${s.crashDetection ? 'on' : 'off'}';

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _smsDenied = false;

  Future<bool> _request(String key) => (widget.requestPermission ?? PermissionsService.request)(key);

  /// Turning crash detection off asks first; turning it on is instant.
  Future<void> _setCrash(SettingsService s, bool on) async {
    if (on) {
      await s.setCrashDetection(true);
      return;
    }
    final ok = await confirmAction(
      context,
      title: 'Turn off crash detection?',
      message: 'If you crash, CoRoute will not alert your group or your emergency contact. '
          'You can turn it back on here any time.',
      confirmLabel: 'Turn off',
      destructive: true,
    );
    if (ok && mounted) await s.setCrashDetection(false);
  }

  /// "Text the group if there is no internet": switching on asks for SEND_SMS first.
  Future<void> _setSms(SettingsService s, bool on) async {
    if (!on) {
      await s.setSmsFallback(false);
      return;
    }
    final ok = await _request('sms');
    if (!mounted) return;
    setState(() => _smsDenied = !ok);
    if (ok) await s.setSmsFallback(true);
  }

  Future<void> _saveNet(AuthService auth, {bool? help, bool? ask}) async {
    final ok = await auth.updateNetworkPrefs(assistHelp: help, assistAsk: ask);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(SafetyTexts.saveFailed)));
    }
  }

  void _push(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    // Safety texts follow the rider's language at once.
    return ValueListenableBuilder<String>(
      valueListenable: L10n.changes,
      builder: (context, _, _) => _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final s = context.watch<SettingsService?>();
    final auth = context.watch<AuthService?>();
    final theme = context.watch<ThemeController?>();

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            // Built in full (not lazily) so a language change re-words every row at once.
            child: SingleChildScrollView(
              padding: dsScreenPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DsScreenHeader(title: SettingsScreen.title, onBack: () => Navigator.maybePop(context)),
                  if (s != null) ...[
                    _Section('Ride', [
                      SafetySwitch(
                        key: const ValueKey('settings_auto_reroute'),
                        icon: Icons.alt_route_rounded,
                        title: 'Auto re-route',
                        subtitle: 'A new route from where you are when you leave the planned one.',
                        value: s.autoReroute,
                        onChanged: s.setAutoReroute,
                      ),
                      _SpeedWarning(settings: s),
                      _LinkRow(
                        icon: Icons.local_gas_station_rounded,
                        title: 'Fuel',
                        subtitle: s.fuelProfile.valid
                            ? '${s.fuelProfile.rangeKm.floor()} km on a full tank'
                            : 'Set your range for the fuel reminder',
                        onTap: () => showFuelSheet(context, configure: true),
                        divider: false,
                      ),
                    ]),
                    _Section('Safety', [
                      SafetySwitch(
                        key: const ValueKey('settings_crash'),
                        icon: Icons.car_crash_rounded,
                        title: SafetyTexts.crashTitle,
                        subtitle: SafetyTexts.crashExplain,
                        value: s.crashDetection,
                        onChanged: (v) => _setCrash(s, v),
                      ),
                      const CrashLearningRow(), // 3.55: "Learned from N false alarms on this bike"
                      if (auth != null) _EmergencyRow(auth: auth, onTap: () => _push(const EditProfileScreen())),
                      SafetySwitch(
                        key: const ValueKey('settings_sms'),
                        icon: Icons.sms_rounded,
                        title: SafetyTexts.smsTitle,
                        subtitle: SafetyTexts.smsExplain,
                        value: s.smsFallback,
                        onChanged: (v) => _setSms(s, v),
                        warning: _smsDenied ? SafetyTexts.smsDenied : null,
                      ),
                      SafetySwitch(
                        icon: Icons.person_search_rounded,
                        title: SafetyTexts.checkInTitle,
                        subtitle: SafetyTexts.checkInExplain,
                        value: s.soloCheckIn,
                        onChanged: s.setSoloCheckIn,
                      ),
                      // 3.55 solo check-in by ETA and no-signal ahead (docs/features_355/solo_guardian.md).
                      if (context.featureOn('soloCheckIn'))
                        SafetySwitch(
                          icon: Icons.timer_rounded,
                          title: 'Solo check-in timer',
                          subtitle: (auth?.emergencyContact ?? '').trim().length >= 7
                              ? 'On a solo ride with a destination, asks "Are you OK?" if you have not arrived by your ETA plus a margin, then texts your emergency contact.'
                              : 'Add an emergency contact to use it. On a solo ride, your contact is texted if you are overdue and do not answer.',
                          value: s.etaCheckIn,
                          onChanged: s.setEtaCheckIn,
                        ),
                      if (context.featureOn('noSignalAhead'))
                        SafetySwitch(
                          icon: Icons.signal_cellular_connected_no_internet_4_bar_rounded,
                          title: 'No-signal ahead',
                          subtitle: 'Before a stretch where your phone had no signal on earlier rides, tells your group and guardians when you expect to be back online.',
                          value: s.noSignalAhead,
                          onChanged: s.setNoSignalAhead,
                        ),
                      SafetySwitch(
                        icon: Icons.free_breakfast_rounded,
                        title: SafetyTexts.fatigueTitle,
                        subtitle: SafetyTexts.fatigueExplain,
                        value: s.fatigueReminder,
                        onChanged: s.setFatigueReminder,
                      ),
                      SafetySwitch(
                        icon: Icons.warning_amber_rounded,
                        title: SafetyTexts.hazardTitle,
                        subtitle: SafetyTexts.hazardExplain,
                        value: s.hazardAlerts,
                        onChanged: s.setHazardAlerts,
                        divider: false,
                      ),
                    ]),
                    if (auth != null)
                      _Section(SafetyTexts.nearbySection, [
                        SafetySwitch(
                          icon: Icons.emergency_share_rounded,
                          title: SafetyTexts.askTitle,
                          subtitle: SafetyTexts.askExplain,
                          value: auth.assistAsk,
                          onChanged: (v) => _saveNet(auth, ask: v),
                        ),
                        // Sharing medical info with a responder is chosen next to the
                        // medical info itself (Emergency contact & Medical ID).
                        SafetySwitch(
                          icon: Icons.volunteer_activism_rounded,
                          title: SafetyTexts.helpTitle,
                          subtitle: SafetyTexts.helpExplain,
                          value: auth.assistHelp,
                          onChanged: (v) => _saveNet(auth, help: v),
                          divider: false,
                        ),
                      ]),
                    _Section('Voice & sound', [
                      SafetySwitch(
                        key: const ValueKey('settings_spoken_alerts'),
                        icon: Icons.record_voice_over_rounded,
                        title: SafetyTexts.voiceWarningsTitle,
                        subtitle: '${SafetyTexts.voiceWarningsExplain} $emergencyAlwaysSpoken',
                        value: s.voiceWarnings,
                        onChanged: s.setVoiceWarnings,
                      ),
                      SafetySwitch(
                        key: const ValueKey('settings_pause_music'),
                        icon: Icons.music_off_rounded,
                        title: 'Pause music during alerts',
                        subtitle: s.pauseOtherAudio
                            ? 'Pauses music and other apps completely during alerts, then resumes.'
                            : 'Lowers music and other apps volume so alerts are loud and clear.',
                        value: s.pauseOtherAudio,
                        onChanged: s.setPauseOtherAudio,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: Space.s12),
                        child: LanguagePicker(value: s.language, onChanged: s.setLanguage),
                      ),
                    ]),
                    _Section('Map & offline', [
                      if (theme != null)
                        _LinkRow(
                          icon: theme.isLight ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                          title: 'Night mode',
                          subtitle: AppearanceSheet.summary(theme),
                          onTap: () => AppearanceSheet.show(context),
                        ),
                      SafetySwitch(
                        key: const ValueKey('batterySaver'),
                        icon: Icons.battery_saver_rounded,
                        title: SafetyTexts.batterySaverTitle,
                        subtitle: SafetyTexts.batterySaverExplain,
                        value: s.batterySaver,
                        onChanged: s.setBatterySaver,
                      ),
                      const DataSaverTile(),
                      _LinkRow(
                        icon: Icons.download_for_offline_rounded,
                        title: 'Offline maps',
                        subtitle: 'Save maps for places without signal',
                        onTap: () => _push(const OfflineMapManagerScreen()),
                        divider: false,
                      ),
                    ]),
                    _Section('Account & privacy', [
                      SafetySwitch(
                        icon: Icons.screen_lock_portrait_rounded,
                        title: SafetyTexts.lockTitle,
                        subtitle: SafetyTexts.lockExplain,
                        value: s.rideOnLockScreen,
                        onChanged: s.setRideOnLockScreen,
                      ),
                      _LinkRow(
                        icon: Icons.verified_user_rounded,
                        title: 'Permissions',
                        subtitle: 'Location, microphone, notifications, battery and texts',
                        onTap: () => _push(const PermissionsScreen()),
                      ),
                      _LinkRow(
                        icon: Icons.phonelink_setup_rounded,
                        title: 'Phone check',
                        subtitle: 'Test GPS and sensors before a ride',
                        onTap: () => _push(const PreRidePhoneCheckScreen(autoRun: false)),
                        divider: false,
                      ),
                    ]),
                  ],
                  _Section('Help', [
                    _LinkRow(
                      key: const ValueKey('settings_features_guide'),
                      icon: Icons.help_outline_rounded,
                      title: 'Features guide',
                      subtitle: 'What each feature does',
                      onTap: () => _push(const FeaturesGuideScreen()),
                      divider: false,
                    ),
                  ]),
                  const SizedBox(height: Space.s32),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Added to the spoken alerts line: the emergency voice has no switch.
  static const String emergencyAlwaysSpoken = 'Emergency alerts are always spoken.';
}

/// A titled group of rows on one card, with generous space above it.
class _Section extends StatelessWidget {
  final String title;
  final List<Widget> rows;
  const _Section(this.title, this.rows);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Space.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(header: true, child: DsSectionHeader(title)),
          const SizedBox(height: Space.s12),
          DsCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
          ),
        ],
      ),
    );
  }
}

/// A row that opens another screen: icon, title, one line and a chevron.
class _LinkRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool divider;
  final Color? color;

  const _LinkRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.divider = true,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(border: divider ? Border(bottom: BorderSide(color: AppTheme.border)) : null),
        child: Row(
          children: [
            Icon(icon, size: 22, color: color ?? AppTheme.accentText),
            const SizedBox(width: Space.s16),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: color)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
          ],
        ),
      ),
    );
  }
}

/// Emergency contact and Medical ID: both are edited in the profile.
class _EmergencyRow extends StatelessWidget {
  final AuthService auth;
  final VoidCallback onTap;
  const _EmergencyRow({required this.auth, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final name = (auth.emergencyContactName ?? '').trim();
    final phone = (auth.emergencyContact ?? '').trim();
    final contactSet = phone.length >= 7;
    final medicalSet = auth.bloodGroup.isNotEmpty || auth.medicalNotes.isNotEmpty;
    final contact = contactSet ? (name.isNotEmpty ? name : phone) : 'No emergency contact';
    final medical = medicalSet ? 'Medical ID set' : 'Medical ID not set';
    return _LinkRow(
      key: const ValueKey('settings_emergency_contact'),
      icon: contactSet ? Icons.contact_emergency_rounded : Icons.person_add_alt_1_rounded,
      title: 'Emergency contact & Medical ID',
      subtitle: '$contact · $medical',
      color: contactSet ? null : AppTheme.warnText,
      onTap: onTap,
    );
  }
}

/// My own speed warning: off (group limit) or one of a few speeds.
class _SpeedWarning extends StatelessWidget {
  final SettingsService settings;
  const _SpeedWarning({required this.settings});

  @override
  Widget build(BuildContext context) {
    final kmh = settings.speedLimitWarningKmh;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.speed_rounded, size: 22, color: AppTheme.accentText),
              const SizedBox(width: Space.s16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Speed warning', style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                    Text(
                      kmh == 0 ? 'Uses the group limit (off if none)' : 'Warns you above $kmh km/h',
                      style: AppText.caption,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.s12),
          Wrap(
            spacing: Space.s8,
            runSpacing: Space.s8,
            children: [
              for (final v in SafetyConstants.speedWarningChoices)
                ChoiceChip(
                  label: Text(v == 0 ? 'Group limit' : '$v'),
                  selected: kmh == v,
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  onSelected: (_) => settings.setSpeedLimitWarningKmh(v),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
