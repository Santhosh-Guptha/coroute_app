import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/safety_constants.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/friends_service.dart';
import '../../data/services/push_service.dart';
import '../../data/services/rider_score_service.dart';
import '../../data/services/settings_service.dart';
import '../account/appearance_sheet.dart';
import '../account/edit_profile_screen.dart';
import '../diagnostics/pre_ride_phone_check_screen.dart';
import '../onboarding/permissions_screen.dart';
import '../ride/fuel_sheet.dart';
import '../safety/safety_settings_sheet.dart';
import '../trip_planner/offline_map_manager_screen.dart';
import '../widgets/feature_switch.dart';
import 'diagnostics_screen.dart';
import 'features_guide_screen.dart';
import 'push_notifications_tile.dart';
import '../engagement/rate_and_feedback.dart';

/// The one Settings screen, minimal by design (3.55, docs/SETTINGS_MINIMAL_v3.55.md).
///
/// Safety features are always on and have no switch (crash detection, SOS, emergency texts,
/// break reminder...): one row says so and lists them. What is left:
///  * Safety: emergency contact & Medical ID (data, not a setting) and my speed warning.
///  * Ride: voice alerts, siren alerts (on by default), language, battery saver, data saver.
///  * App & privacy: appearance, push notifications, my username on leaderboards.
///  * More (collapsed): audio fine-tuning, nearby riders help, score report, fuel, offline maps,
///    permissions, phone check, the features guide and Diagnostics (app log).
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
  static const String moreTitle = 'More settings';
  static const String pauseMusicTitle = 'Pause music for alerts';
  static const String lowerMusicTitle = 'Lower music when speeding';
  static const String giveWayTitle = 'Give way to the';
  static const String scoreReportTitle = 'Safety report in my score';

  /// The always-on list shown by the "Safety is always on" row (icon, short label).
  static List<(IconData, String)> get alwaysOn => [
    (Icons.car_crash_rounded, SafetyTexts.crashTitle),
    (Icons.sos_rounded, 'SOS, also on the lock screen'),
    (Icons.sms_rounded, 'Emergency texts'),
    (Icons.medical_information_rounded, 'Medical ID for responders'),
    (Icons.person_search_rounded, '"Are you OK?" check-in'),
    (Icons.timer_rounded, 'Solo ride ETA check-in'),
    (Icons.signal_cellular_connected_no_internet_4_bar_rounded, 'No-signal ahead'),
    (Icons.free_breakfast_rounded, 'Break reminder'),
    (Icons.warning_amber_rounded, 'Road warnings'),
    (Icons.alt_route_rounded, 'Auto re-route'),
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

  Future<void> _saveNet(AuthService auth, {bool? help, bool? ask}) async {
    final ok = await auth.updateNetworkPrefs(assistHelp: help, assistAsk: ask);
    if (!ok) _say(SafetyTexts.saveFailed);
  }

  void _push(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

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
                    _Section('App & privacy', [
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
                  if (_more) _moreSection(context, s, auth),
                  const SizedBox(height: Space.s32),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Two cards: the less-used switches, then links to tools and help.
  Widget _moreSection(BuildContext context, SettingsService? s, AuthService? auth) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Section(null, [
          if (s != null) ...[
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
            // Admin switch 'sirenDetector'.
            if (context.featureOn('sirenDetector'))
              _ChoiceRow<String>(
                key: const ValueKey('settings_give_way_side'),
                icon: Icons.swap_horiz_rounded,
                title: SettingsScreen.giveWayTitle,
                value: s.giveWaySide,
                choices: const {'auto': 'Auto', 'left': 'Left', 'right': 'Right'},
                onChanged: s.setGiveWaySide,
              ),
          ],
          // Admin switch 'riderScore'.
          if (context.featureOn('riderScore') && context.read<ApiClient?>() != null) const _ScoreReportRow(),
          if (auth != null) ...[
            _Row(
              icon: Icons.volunteer_activism_rounded,
              title: SafetyTexts.helpTitle,
              value: auth.assistHelp,
              onChanged: (v) => _saveNet(auth, help: v),
            ),
            _Row(
              icon: Icons.emergency_share_rounded,
              title: SafetyTexts.askTitle,
              value: auth.assistAsk,
              onChanged: (v) => _saveNet(auth, ask: v),
            ),
          ],
        ]),
        _Section(null, [
          if (s != null)
            _Row(
              icon: Icons.local_gas_station_rounded,
              title: 'Fuel',
              subtitle: s.fuelProfile.valid ? '${s.fuelProfile.rangeKm.floor()} km on a full tank' : null,
              onTap: () => showFuelSheet(context, configure: true),
            ),
          _Row(icon: Icons.download_for_offline_rounded, title: 'Offline maps', onTap: () => _push(const OfflineMapManagerScreen())),
          _Row(icon: Icons.verified_user_outlined, title: 'Permissions', onTap: () => _push(const PermissionsScreen())),
          _Row(
            icon: Icons.phonelink_setup_rounded,
            title: 'Phone check',
            onTap: () => _push(const PreRidePhoneCheckScreen(autoRun: false)),
          ),
          _Row(
            key: const ValueKey('settings_features_guide'),
            icon: Icons.help_outline_rounded,
            title: 'Features guide',
            onTap: () => _push(const FeaturesGuideScreen()),
          ),
          // 3.55 ratings & reviews: always available; straight to Google Play (no "do you like us?" first).
          _Row(
            key: const ValueKey('settings_rate_coroute'),
            icon: Icons.star_outline_rounded,
            title: RateAndFeedback.rateTitle,
            subtitle: RateAndFeedback.rateSubtitle,
            onTap: () => RateAndFeedback.rate(context),
          ),
          _Row(
            key: const ValueKey('settings_send_feedback'),
            icon: Icons.chat_bubble_outline_rounded,
            title: RateAndFeedback.feedbackTitle,
            onTap: () => RateAndFeedback.openFeedback(context),
          ),
          // 3.55 diagnostics log: send / share / view the app log (docs/features_355/diagnostics_logs.md).
          _Row(
            key: const ValueKey('settings_diagnostics'),
            icon: Icons.bug_report_outlined,
            title: DiagnosticsScreen.title,
            subtitle: 'App log for fixing problems',
            onTap: () => _push(const DiagnosticsScreen()),
          ),
        ]),
      ],
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

/// "Safety report in my score" (rider score, admin switch 'riderScore'): counts only, and
/// turning it off deletes the counts already sent. Shown only when the API is provided.
class _ScoreReportRow extends StatefulWidget {
  const _ScoreReportRow();

  @override
  State<_ScoreReportRow> createState() => _ScoreReportRowState();
}

class _ScoreReportRowState extends State<_ScoreReportRow> {
  late final RiderScoreService _svc;

  @override
  void initState() {
    super.initState();
    _svc = RiderScoreService(context.read<ApiClient>())..loadSetting();
  }

  @override
  void dispose() {
    _svc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final svc = _svc;
    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) => _Row(
        key: const ValueKey('settings_score_report'),
        icon: Icons.insights_rounded,
        title: SettingsScreen.scoreReportTitle,
        subtitle: 'Counts only, never your route',
        value: svc.useSafetyReport,
        onChanged: svc.setUseSafetyReport,
      ),
    );
  }
}
