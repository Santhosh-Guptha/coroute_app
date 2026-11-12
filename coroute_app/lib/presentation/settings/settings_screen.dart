import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/services/app_lock_service.dart';
import '../../domain/security/app_lock_policy.dart';
import '../../domain/security/lock_screen_cockpit_policy.dart';
import '../../domain/tracking/screen_awake_policy.dart';

import '../../core/constants/safety_constants.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/ui/ui.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/friends_service.dart';
import '../../data/services/nav_handoff_service.dart';
import '../../domain/navigation/nav_handoff.dart';
import '../../domain/notify/push_kinds.dart';
import '../../data/services/push_service.dart';
import '../../data/services/settings_service.dart';
import '../account/appearance_sheet.dart';
import '../account/edit_profile_screen.dart';
import '../diagnostics/pre_ride_phone_check_screen.dart';
import '../onboarding/permissions_screen.dart';
import '../ride/fuel_sheet.dart';
import '../ride/messages_sheet.dart' show QuickActionOrderView, showQuickActionOrderSheet;
import '../safety/safety_settings_sheet.dart';
import '../widgets/feature_switch.dart';
import 'features_guide_screen.dart';
import 'push_notifications_tile.dart';

/// The one Settings screen, minimal by design (3.55, docs/SETTINGS_MINIMAL_v3.55.md).
///
/// Safety features are always on and have no switch (crash detection, SOS, emergency texts,
/// break reminder, helping and asking nearby riders...): one row says so and lists them.
/// What is left:
///  * Safety: safety health (the phone check), emergency contact & Medical ID (data, not a
///    setting) and my speed warning.
///  * Ride: voice alerts, siren alerts (on by default), language, battery saver, data saver.
///  * Ride screen: "Show cockpit on lock screen while riding" (default on), when idle (Ride AOD / Dim / Let the
///    screen sleep) and keep screen on (only while moving / always during a ride), with battery estimates.
///  * App & privacy: appearance, push notifications, my username on leaderboards.
///  * More (collapsed): audio fine-tuning, fuel, navigation app, quick replies, permissions and
///    the features guide.
/// Fixed since Nov 11 (owner decision), no row: help / ask nearby riders (on), give-way side
/// (Automatic), safety report in my score (on), offline maps (automatic, kept 7 days after a trip).
/// Send feedback, Rate CoRoute and Diagnostics live once, in Profile › Help.
/// Rows tied to an admin switch hide when it is off.
class SettingsScreen extends StatefulWidget {
  /// Kept for callers and tests; emergency texts no longer have a switch that asks for SMS.
  final Future<bool> Function(String key)? requestPermission;
  const SettingsScreen({super.key, this.requestPermission});

  static const String title = 'Settings';

  /// Opens Settings as a full screen.
  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));

  /// One line for Profile, e.g. "Crash detection on" (always on since 3.55).
  static String summary(SettingsService s) => '${SafetyTexts.crashTitle} ${s.crashDetection ? 'on' : 'off'}';

  // Texts (short on purpose: less text, more understanding).
  static const String alwaysOnTitle = 'Safety is always on';
  static const String alwaysOnSubtitle = 'Crash detection, SOS and more';
  static const String voiceTitle = 'Voice alerts';
  static const String voiceSubtitle = 'Emergencies are always spoken';
  static const String sirenTitle = 'Siren alerts';
  static const String sirenSubtitle = 'Listens on your phone during rides. Nothing is recorded.';
  static const String batteryTitle = 'Battery saver';
  static const String batterySubtitle = 'Turns on by itself when low';
  static const String dataTitle = 'Data saver';
  static const String appearanceTitle = 'Appearance';
  static const String leaderboardTitle = 'Show me on leaderboards';
  static const String speedTitle = 'Speed warning';
  static const String emergencyTitle = 'Emergency contact & Medical ID';
  // Round 4 app lock.
  static const String appLockTitle = 'Lock CoRoute with fingerprint or screen lock';
  static const String appLockSubtitle = 'Never during a ride or SOS. SOS, Call 112 and Medical ID work while locked.';
  static String appLockDelayLabel(int minutes) => minutes <= 0 ? 'Every time I leave the app' : 'After $minutes min in the background';
  static const String moreTitle = 'More settings';
  static const String pauseMusicTitle = 'Pause music for alerts';
  static const String lowerMusicTitle = 'Lower music when speeding';
  static const String safetyHealthTitle = 'Safety health';
  static const String safetyHealthSubtitle = 'Check your phone is ready';
  // Ride screen (lock-screen cockpit and Ride AOD, docs/features_355/lock_screen_cockpit.md).
  static const String rideScreenSection = 'Ride screen';
  static const String lockScreenCockpitTitle = LockScreenCockpitPolicy.settingTitle;
  static const String lockScreenCockpitSubtitle = LockScreenCockpitPolicy.settingHint;
  static const String idleTitle = 'When idle';
  static const String keepOnTitle = 'Keep screen on';

  /// Rows removed on Nov 11 (owner decision); tests check none of them is shown.
  static const List<String> removedRowKeys = [
    'settings_give_way_side',
    'settings_score_report',
    'settings_help_nearby',
    'settings_ask_nearby',
    'settings_offline_maps',
    'settings_rate_coroute',
    'settings_send_feedback',
    'settings_diagnostics',
  ];

  /// The always-on list shown by the "Safety is always on" row (icon, short label).
  static List<(IconData, String)> get alwaysOn => [
    (Icons.car_crash_rounded, SafetyTexts.crashTitle),
    (Icons.sos_rounded, 'SOS, also on the lock screen'),
    (Icons.sms_rounded, 'Emergency texts from your phone'),
    (Icons.medical_information_rounded, 'Medical ID for responders'),
    (Icons.person_search_rounded, '"Are you OK?" check-in'),
    (Icons.timer_rounded, 'Solo ride ETA check-in'),
    (Icons.signal_cellular_connected_no_internet_4_bar_rounded, 'No-signal ahead'),
    (Icons.free_breakfast_rounded, 'Break reminder'),
    (Icons.warning_amber_rounded, 'Road warnings'),
    (Icons.alt_route_rounded, 'Auto re-route'),
    (Icons.volunteer_activism_rounded, SafetyTexts.helpTitle),
    (Icons.emergency_share_rounded, SafetyTexts.askTitle),
    (Icons.graphic_eq_rounded, 'Clear voice in group talk'),
    (Icons.stay_current_portrait_rounded, 'Screen stays on while riding'),
  ];

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _more = false;

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _push(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  void _pickLockDelay(AppLockService lock) {
    showAppSheet<void>(
      context,
      title: 'Lock after',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in AppLockPolicy.delayChoices)
            ListTile(
              title: Text(SettingsScreen.appLockDelayLabel(m)),
              trailing: m == lock.delayMinutes ? Icon(Icons.check_rounded, color: AppTheme.accentText) : null,
              onTap: () {
                lock.setDelayMinutes(m).ignore();
                Navigator.of(ctx).pop();
              },
            ),
        ],
      ),
    );
  }

  void _pickIdle(SettingsService s) {
    showAppSheet<void>(
      context,
      title: SettingsScreen.idleTitle,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in RideIdleMode.values)
            ListTile(
              key: ValueKey('settings_ride_idle_${m.id}'),
              title: Text(m == RideIdleMode.aod ? '${m.label} (default)' : m.label),
              subtitle: Text(RideScreenBattery.forIdle(m)),
              trailing: m == s.rideIdleMode ? Icon(Icons.check_rounded, color: AppTheme.accentText) : null,
              onTap: () {
                s.setRideIdleMode(m).ignore();
                Navigator.of(ctx).pop();
              },
            ),
        ],
      ),
    );
  }

  void _pickKeepOn(SettingsService s) {
    showAppSheet<void>(
      context,
      title: SettingsScreen.keepOnTitle,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in KeepScreenOnMode.values)
            ListTile(
              key: ValueKey('settings_keep_screen_on_${m.id}'),
              title: Text(m == KeepScreenOnMode.whileMoving ? '${m.label} (default)' : m.label),
              subtitle: Text(RideScreenBattery.keepOnHint(m)),
              trailing: m == s.keepScreenOnMode ? Icon(Icons.check_rounded, color: AppTheme.accentText) : null,
              onTap: () {
                s.setKeepScreenOnMode(m).ignore();
                Navigator.of(ctx).pop();
              },
            ),
        ],
      ),
    );
  }

  void _showAlwaysOn() {
    showAppSheet<void>(
      context,
      isScrollControlled: true,
      title: SettingsScreen.alwaysOnTitle,
      builder: (_) => ListView(
        key: const ValueKey('settings_always_on_list'),
        shrinkWrap: true,
        children: [
          for (final (icon, label) in SettingsScreen.alwaysOn)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Icon(icon, size: 22, color: AppTheme.accentText),
                  const SizedBox(width: Space.s16),
                  Expanded(child: Text(label, style: AppText.body)),
                  Icon(Icons.check_rounded, size: 20, color: AppTheme.accentText),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Safety texts follow the rider's language at once.
    return ValueListenableBuilder<String>(valueListenable: L10n.changes, builder: (context, _, _) => _body(context));
  }

  Widget _body(BuildContext context) {
    final s = context.watch<SettingsService?>();
    final auth = context.watch<AuthService?>();
    final theme = context.watch<ThemeController?>();
    final friends = context.watch<FriendsService?>();
    final profile = friends?.profile;
    final push = context.watch<PushService?>();
    final appLock = context.watch<AppLockService?>();

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
                    _Section('Safety', [
                      _Row(
                        key: const ValueKey('settings_always_on'),
                        icon: Icons.verified_user_rounded,
                        title: SettingsScreen.alwaysOnTitle,
                        subtitle: SettingsScreen.alwaysOnSubtitle,
                        onTap: _showAlwaysOn,
                      ),
                      // The phone check (permissions, battery, notifications, sensors): the same
                      // screen as the cockpit's "Safety health" tile.
                      _Row(
                        key: const ValueKey('settings_safety_health'),
                        icon: Icons.health_and_safety_rounded,
                        title: SettingsScreen.safetyHealthTitle,
                        subtitle: SettingsScreen.safetyHealthSubtitle,
                        onTap: () => PreRidePhoneCheckScreen.open(context),
                      ),
                      if (auth != null) _EmergencyRow(auth: auth, onTap: () => _push(const EditProfileScreen())),
                      _SpeedWarning(settings: s),
                    ]),
                    _Section('Ride', [
                      _Row(
                        key: const ValueKey('settings_spoken_alerts'),
                        icon: Icons.record_voice_over_rounded,
                        title: SettingsScreen.voiceTitle,
                        subtitle: SettingsScreen.voiceSubtitle,
                        value: s.voiceWarnings,
                        onChanged: s.setVoiceWarnings,
                      ),
                      // Admin switch 'sirenDetector'. Off releases the microphone at once.
                      if (context.featureOn('sirenDetector'))
                        _Row(
                          key: const ValueKey('settings_siren_alerts'),
                          icon: Icons.emergency_rounded,
                          title: SettingsScreen.sirenTitle,
                          subtitle: SettingsScreen.sirenSubtitle,
                          value: s.sirenAlerts,
                          onChanged: s.setSirenAlerts,
                        ),
                      _LanguageRow(settings: s),
                      _Row(
                        key: const ValueKey('batterySaver'),
                        icon: Icons.battery_saver_rounded,
                        title: SettingsScreen.batteryTitle,
                        subtitle: SettingsScreen.batterySubtitle,
                        value: s.batterySaver,
                        onChanged: s.setBatterySaver,
                      ),
                      _Row(
                        key: const ValueKey('settings_data_saver'),
                        icon: Icons.data_saver_on_rounded,
                        title: SettingsScreen.dataTitle,
                        value: s.lowData,
                        onChanged: s.setLowData,
                      ),
                    ]),
                    _Section(SettingsScreen.rideScreenSection, [
                      // Default on; the same stored key as 3.54's "Show ride on lock screen".
                      _Row(
                        key: const ValueKey('settings_lock_screen_cockpit'),
                        icon: Icons.screen_lock_portrait_rounded,
                        title: SettingsScreen.lockScreenCockpitTitle,
                        subtitle: SettingsScreen.lockScreenCockpitSubtitle,
                        value: s.rideOnLockScreen,
                        onChanged: s.setRideOnLockScreen,
                      ),
                      _Row(
                        key: const ValueKey('settings_ride_idle'),
                        icon: Icons.nightlight_round,
                        title: SettingsScreen.idleTitle,
                        subtitle: RideScreenBattery.idleHint(s.rideIdleMode),
                        onTap: () => _pickIdle(s),
                      ),
                      _Row(
                        key: const ValueKey('settings_keep_screen_on'),
                        icon: Icons.stay_current_portrait_rounded,
                        title: SettingsScreen.keepOnTitle,
                        subtitle: '${s.keepScreenOnMode.label}. ${RideScreenBattery.keepOnHint(s.keepScreenOnMode)}',
                        onTap: () => _pickKeepOn(s),
                      ),
                    ]),
                    _Section('App & privacy', [
                      // Round 4: off by default; never locks during a ride, convoy, SOS or crash countdown.
                      if (appLock != null)
                        _Row(
                          key: const ValueKey('settings_app_lock'),
                          icon: Icons.fingerprint_rounded,
                          title: SettingsScreen.appLockTitle,
                          subtitle: SettingsScreen.appLockSubtitle,
                          value: appLock.enabled,
                          onChanged: (on) async {
                            final err = await appLock.setEnabled(on);
                            if (err != null) _say(err);
                          },
                        ),
                      if (appLock != null && appLock.enabled)
                        _Row(
                          key: const ValueKey('settings_app_lock_delay'),
                          icon: Icons.timer_outlined,
                          title: 'Lock after',
                          subtitle: SettingsScreen.appLockDelayLabel(appLock.delayMinutes),
                          onTap: () => _pickLockDelay(appLock),
                        ),
                      if (theme != null)
                        _Row(
                          key: const ValueKey('settings_appearance'),
                          icon: theme.isLight ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                          title: SettingsScreen.appearanceTitle,
                          subtitle: AppearanceSheet.summary(theme),
                          onTap: () => AppearanceSheet.show(context),
                        ),
                      // Hidden when the build has no push set up.
                      if (push != null && push.available)
                        _Row(
                          key: const ValueKey('settings_push_notifications'),
                          icon: Icons.notifications_active_rounded,
                          title: PushNotificationsTile.title,
                          value: push.enabled,
                          onChanged: (on) => push.setEnabled(on),
                        ),
                      // 3.56: the opt-out category for admin pushes; safety and ride alerts are not in it.
                      if (push != null && push.available && push.enabled)
                        _Row(
                          key: const ValueKey('settings_push_news'),
                          icon: Icons.campaign_rounded,
                          title: PushNotificationsTile.newsTitle,
                          subtitle: PushNotificationsTile.newsSubtitle,
                          value: push.newsEnabled,
                          onChanged: (on) => push.setNewsEnabled(on),
                        ),
                      // 3.56 one switch per push kind (own Android channel each); partner perks start off.
                      if (push != null && push.available && push.enabled)
                        for (final kind in PushKinds.all.where((k) => k != PushKinds.update))
                          _Row(
                            key: ValueKey('settings_push_kind_${kind.id}'),
                            icon: switch (kind.id) {
                              'event' => Icons.event_rounded,
                              'safety_tip' => Icons.health_and_safety_rounded,
                              'community' => Icons.groups_rounded,
                              _ => Icons.handshake_rounded,
                            },
                            title: kind.title,
                            subtitle: kind.subtitle,
                            value: push.kindEnabled(kind),
                            onChanged: (on) => push.setKindEnabled(kind, on),
                          ),
                      if (friends != null && profile != null)
                        _Row(
                          key: const ValueKey('settings_public_leaderboard'),
                          icon: Icons.emoji_events_rounded,
                          title: SettingsScreen.leaderboardTitle,
                          value: profile.publicLeaderboard,
                          onChanged: (v) async {
                            final err = await friends.setPublicLeaderboard(v);
                            if (err != null) _say(err);
                          },
                        ),
                    ]),
                  ],
                  _MoreToggle(open: _more, onTap: () => setState(() => _more = !_more)),
                  if (_more) _moreSection(context, s),
                  const SizedBox(height: Space.s32),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Two cards: the less-used switches, then links to tools.
  Widget _moreSection(BuildContext context, SettingsService? s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (s != null)
          _Section(null, [
            _Row(
              key: const ValueKey('settings_pause_music'),
              icon: Icons.music_off_rounded,
              title: SettingsScreen.pauseMusicTitle,
              subtitle: 'Off: music only gets quieter',
              value: s.pauseOtherAudio,
              onChanged: s.setPauseOtherAudio,
            ),
            // Admin switch 'speedAudio'.
            if (context.featureOn('speedAudio'))
              _Row(
                key: const ValueKey('settings_lower_music_speeding'),
                icon: Icons.speed_rounded,
                title: SettingsScreen.lowerMusicTitle,
                value: s.lowerMusicWhenSpeeding,
                onChanged: s.setLowerMusicWhenSpeeding,
              ),
          ]),
        _Section(null, [
          if (s != null)
            _Row(
              icon: Icons.local_gas_station_rounded,
              title: 'Fuel',
              subtitle: s.fuelProfile.valid ? '${s.fuelProfile.rangeKm.floor()} km on a full tank' : null,
              onTap: () => showFuelSheet(context, configure: true),
            ),
          // 3.55 "Navigate in Google Maps / Mappls": which app the Navigate buttons open.
          const _NavAppRow(key: ValueKey('settings_nav_app')),
          // 3.55 ride chat: the order of the one-tap quick replies.
          _Row(
            key: const ValueKey('settings_chat_quick_replies'),
            icon: Icons.forum_rounded,
            title: QuickActionOrderView.title,
            onTap: () => showQuickActionOrderSheet(context),
          ),
          _Row(icon: Icons.verified_user_outlined, title: 'Permissions', onTap: () => _push(const PermissionsScreen())),
          _Row(
            key: const ValueKey('settings_features_guide'),
            icon: Icons.help_outline_rounded,
            title: 'Features guide',
            onTap: () => _push(const FeaturesGuideScreen()),
          ),
        ]),
      ],
    );
  }
}

/// "Navigation app": Automatic (Google Maps, else Mappls, else any map app), always Google Maps,
/// always Mappls, or any map app. Kept on the phone (NavHandoffService).
class _NavAppRow extends StatefulWidget {
  const _NavAppRow({super.key});

  static const String title = 'Navigation app';

  @override
  State<_NavAppRow> createState() => _NavAppRowState();
}

class _NavAppRowState extends State<_NavAppRow> {
  NavApp _value = NavHandoffService.choice;

  @override
  void initState() {
    super.initState();
    NavHandoffService.load().then((v) {
      if (mounted && v != _value) setState(() => _value = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    return _ChoiceRow<NavApp>(
      icon: Icons.navigation_rounded,
      title: _NavAppRow.title,
      value: _value,
      choices: {for (final a in NavApp.values) a: a.label},
      onChanged: (v) {
        setState(() => _value = v);
        NavHandoffService.setChoice(v).ignore();
      },
    );
  }
}

/// "More settings": one tap opens or closes the less-used rows.
class _MoreToggle extends StatelessWidget {
  final bool open;
  final VoidCallback onTap;
  const _MoreToggle({required this.open, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Space.s24),
      child: Semantics(
        button: true,
        expanded: open,
        child: InkWell(
          key: const ValueKey('settings_more'),
          borderRadius: Radii.lgAll,
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(horizontal: Space.s16),
            decoration: BoxDecoration(
              borderRadius: Radii.lgAll,
              border: Border.all(color: AppTheme.border),
            ),
            child: Row(
              children: [
                Icon(Icons.tune_rounded, size: 20, color: AppTheme.muted),
                const SizedBox(width: Space.s12),
                Expanded(child: Text(SettingsScreen.moreTitle, style: AppText.title)),
                Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: AppTheme.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A titled group of rows on one card. Hairlines between rows, none after the last.
class _Section extends StatelessWidget {
  final String? title;
  final List<Widget> rows;
  const _Section(this.title, this.rows);

  @override
  Widget build(BuildContext context) {
    final t = title;
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: t == null ? Space.s12 : Space.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (t != null) ...[Semantics(header: true, child: DsSectionHeader(t)), const SizedBox(height: Space.s8)],
          DsCard(
            padding: const EdgeInsets.symmetric(horizontal: Space.s16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < rows.length; i++) ...[if (i > 0) Divider(height: 1, thickness: 1, color: AppTheme.border), rows[i]],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One settings row: icon, short label, optional one-line subtitle, then a switch
/// (when [onChanged] is set) or a chevron (when [onTap] is set). The whole row toggles.
class _Row extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool? value;
  final ValueChanged<bool>? onChanged;
  final VoidCallback? onTap;
  final Color? color;

  const _Row({super.key, required this.icon, required this.title, this.subtitle, this.value, this.onChanged, this.onTap, this.color});

  @override
  Widget build(BuildContext context) {
    final v = value;
    final change = onChanged;
    final sub = subtitle;
    final isSwitch = v != null && change != null;
    return MergeSemantics(
      child: InkWell(
        onTap: isSwitch ? () => change(!v) : onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 22, color: color ?? AppTheme.accentText),
              const SizedBox(width: Space.s16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (sub != null)
                      Text(
                        sub,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption.copyWith(color: color),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: Space.s8),
              if (isSwitch)
                Switch(value: v, onChanged: change)
              else if (onTap != null)
                Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
            ],
          ),
        ),
      ),
    );
  }
}

/// A setting with a few named choices (speed warning, give-way side).
class _ChoiceRow<T> extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final T value;
  final Map<T, String> choices;
  final ValueChanged<T> onChanged;

  const _ChoiceRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.choices,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 22, color: AppTheme.accentText),
              const SizedBox(width: Space.s16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                    if (sub != null) Text(sub, style: AppText.caption),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.s8),
          Padding(
            padding: const EdgeInsets.only(left: 38),
            child: Wrap(
              spacing: Space.s8,
              runSpacing: Space.s8,
              children: [
                for (final e in choices.entries)
                  ChoiceChip(
                    label: Text(e.value),
                    selected: value == e.key,
                    showCheckmark: false,
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    onSelected: (_) => onChanged(e.key),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Emergency contact and Medical ID: data edited in the profile (amber when missing).
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
    final contact = contactSet ? (name.isNotEmpty ? name : phone) : 'Add a contact';
    final medical = medicalSet ? 'Medical ID set' : 'No Medical ID';
    return _Row(
      key: const ValueKey('settings_emergency_contact'),
      icon: contactSet ? Icons.contact_emergency_rounded : Icons.person_add_alt_1_rounded,
      title: SettingsScreen.emergencyTitle,
      subtitle: '$contact · $medical',
      color: contactSet ? null : AppTheme.warnText,
      onTap: onTap,
    );
  }
}

/// My own speed warning: the group limit, or one of a few speeds. Always on; the value is mine.
class _SpeedWarning extends StatelessWidget {
  final SettingsService settings;
  const _SpeedWarning({required this.settings});

  @override
  Widget build(BuildContext context) {
    return _ChoiceRow<int>(
      key: const ValueKey('settings_speed_warning'),
      icon: Icons.speed_rounded,
      title: SettingsScreen.speedTitle,
      value: settings.speedLimitWarningKmh,
      choices: {for (final v in SafetyConstants.speedWarningChoices) v: v == 0 ? 'Group limit' : '$v'},
      onChanged: settings.setSpeedLimitWarningKmh,
    );
  }
}

/// Language of the safety screens and spoken alerts, as a compact dropdown row.
class _LanguageRow extends StatelessWidget {
  final SettingsService settings;
  const _LanguageRow({required this.settings});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(Icons.translate_rounded, size: 22, color: AppTheme.accentText),
          const SizedBox(width: Space.s16),
          Expanded(
            child: Text(
              SafetyTexts.languageTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.body.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: Space.s8),
          Flexible(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<AppLanguage>(
                key: const ValueKey('language'),
                value: settings.language,
                isExpanded: true,
                isDense: true,
                dropdownColor: AppTheme.card,
                borderRadius: Radii.mdAll,
                style: AppText.body.copyWith(color: AppTheme.muted),
                alignment: AlignmentDirectional.centerEnd,
                items: [
                  for (final l in AppLanguage.values)
                    DropdownMenuItem(
                      value: l,
                      child: Text(l.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (l) {
                  if (l != null) settings.setLanguage(l);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
