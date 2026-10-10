import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/constants/network_constants.dart';
import '../../core/constants/safety_constants.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/permissions_service.dart';
import '../../data/services/safety_service.dart';
import '../../data/services/settings_service.dart';

/// Plain-language texts of the ride safety switches (shared with the pre-ride
/// checklist). Read at build time so they follow the rider's language (3.16).
class SafetyTexts {
  SafetyTexts._();

  static String get crashTitle => L10n.t('settings.crash');
  static String get crashExplain =>
      L10n.t('settings.crash.hint', {'speed': SafetyConstants.crashArmSpeedKmh.round(), 'sec': SafetyConstants.crashCountdown.inSeconds});

  static String get smsTitle => L10n.t('settings.sms');
  static String get smsExplain => L10n.t('settings.sms.hint', {'max': SafetyConstants.smsMaxRecipients});
  static String get smsDenied => L10n.t('settings.sms.denied');

  static String get fatigueTitle => L10n.t('settings.fatigue');
  static String get fatigueExplain =>
      L10n.t('settings.fatigue.hint', {'h': SafetyConstants.fatigueRideFor.inHours, 'min': SafetyConstants.fatigueBreakFor.inMinutes});

  static String get checkInTitle => L10n.t('settings.checkin.title');
  static String get checkInExplain =>
      L10n.t('settings.checkin.hint', {'far': SafetyConstants.checkInFarFor.inMinutes, 'answer': SafetyConstants.checkInAnswerWithin.inMinutes});

  // Nearby riders (3.15 Rider Safety Network).
  static String get nearbySection => L10n.t('settings.nearby');
  static String get helpTitle => L10n.t('settings.help');
  static String get helpExplain => L10n.t('settings.help.hint');
  static String get askTitle => L10n.t('settings.ask');
  static String get askExplain => L10n.t('settings.ask.hint');
  static String get medicalTitle => L10n.t('settings.medical');
  static String get medicalExplain => L10n.t('settings.medical.hint');
  static String get hazardTitle => L10n.t('settings.hazard');
  static String get hazardExplain => L10n.t('settings.hazard.hint');

  static String get voiceSection => L10n.t('settings.voice');
  static String get voiceCriticalTitle => L10n.t('settings.voiceCritical');
  static String get voiceCriticalExplain => L10n.t('settings.voiceCritical.hint');
  static String get voiceWarningsTitle => L10n.t('settings.voiceWarnings');
  static String get voiceWarningsExplain => L10n.t('settings.voiceWarnings.hint');

  // 3.16.
  static String get darkVoiceTitle => L10n.t('settings.darkVoice');
  static String get darkVoiceExplain => L10n.t('settings.darkVoice.hint');
  static String get medicalLockTitle => L10n.t('settings.medicalLock');
  static String get medicalLockExplain => L10n.t('settings.medicalLock.hint');
  static String get fuelTitle => L10n.t('settings.fuel');
  static String get fuelExplain => L10n.t('settings.fuel.hint');
  static String get docsTitle => L10n.t('settings.docs');
  static String get docsExplain => L10n.t('settings.docs.hint');
  static String get mapsTitle => L10n.t('settings.maps');
  static String get mapsExplain => L10n.t('settings.maps.hint');
  static String get languageTitle => L10n.t('settings.language');
  static String get languageExplain => L10n.t('settings.language.hint');
  static String get devTitle => L10n.t('settings.dev');

  static String get notificationSection => L10n.t('settings.notification');
  static String get lockTitle => L10n.t('settings.lock');
  static String get lockExplain => L10n.t('settings.lock.hint');
  static String get richTitle => L10n.t('settings.rich');
  static String get richExplain => L10n.t('settings.rich.hint');

  static String get saveFailed => L10n.t('settings.saveFailed');
}

/// "Ride safety" (Profile tab): the ride safety switches, the fuel range,
/// the nearby riders switches (help others, ask others to help me, medical
/// for responders, accident warnings), voice (incl. "Speak more after
/// dark"), the ride notification (incl. the medical ID on the lock screen),
/// the route map prefetch, the documents reminder and the language, one
/// line each. Tapping the title 7 times reveals the developer row that
/// simulates a wearable impact (only while a ride is active).
class SafetySettingsSheet extends StatefulWidget {
  /// Asks for a permission (tests pass a fake); defaults to [PermissionsService.request].
  final Future<bool> Function(String key)? requestPermission;
  const SafetySettingsSheet({super.key, this.requestPermission});

  static Future<void> show(BuildContext context) => showAppSheet<void>(
        context,
        isScrollControlled: true,
        builder: (_) => const SafetySettingsSheet(),
      );

  /// Tank range choices (km); "Other" lets the rider type one (0 = off).
  static const List<int> fuelChoices = [0, 150, 200, 250, 300, 400];

  /// Title taps that reveal the developer row.
  static const int devTaps = 7;

  /// One line for the Profile row.
  static String summary(SettingsService s) {
    final on = <String>[
      if (s.crashDetection) 'crash detection',
      if (s.smsFallback) 'texts',
      if (s.fatigueReminder) 'break reminder',
      if (s.soloCheckIn) 'check-in',
    ];
    if (on.isEmpty) return 'All off';
    final text = on.join(', ');
    return '${text[0].toUpperCase()}${text.substring(1)} on';
  }

  @override
  State<SafetySettingsSheet> createState() => _SafetySettingsSheetState();
}

class _SafetySettingsSheetState extends State<SafetySettingsSheet> {
  bool _smsDenied = false;
  int _titleTaps = 0;
  bool _customFuel = false;
  final TextEditingController _fuel = TextEditingController();

  @override
  void dispose() {
    _fuel.dispose();
    super.dispose();
  }

  Future<void> _setSms(SettingsService s, bool on) async {
    if (!on) {
      await s.setSmsFallback(false);
      return;
    }
    final ok = await (widget.requestPermission ?? PermissionsService.request)('sms');
    if (!mounted) return;
    if (ok) {
      setState(() => _smsDenied = false);
      await s.setSmsFallback(true);
    } else {
      setState(() => _smsDenied = true);
    }
  }

  Future<void> _saveNet(AuthService auth, {bool? help, bool? ask, bool? medical}) async {
    final ok = await auth.updateNetworkPrefs(assistHelp: help, assistAsk: ask, responderMedical: medical);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(SafetyTexts.saveFailed)));
    }
  }

  void _titleTap() {
    if (_titleTaps >= SafetySettingsSheet.devTaps) return;
    setState(() => _titleTaps++);
  }

  void _saveCustomFuel(SettingsService s) {
    final v = int.tryParse(_fuel.text.trim()) ?? 0;
    s.setFuelRangeKm(v.clamp(0, SafetyConstants.fuelMaxRangeKm));
    setState(() => _customFuel = false);
  }

  Widget _section(String text) => Padding(
        padding: const EdgeInsets.only(top: Space.s16, bottom: Space.s4),
        child: Semantics(header: true, child: Text(text, style: AppText.label)),
      );

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: L10n.changes,
      builder: (context, _, _) => _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final s = context.watch<SettingsService?>();
    if (s == null) return const SizedBox.shrink();
    final auth = context.watch<AuthService?>();
    final convoy = context.select<ConvoyService?, bool>((c) {
      final a = c?.activeConvoy;
      return a != null && a.tripStatus != 'ENDED';
    });
    final showDev = _titleTaps >= SafetySettingsSheet.devTaps && convoy;
    final fuel = s.fuelRangeKm;
    final fuelIsChoice = SafetySettingsSheet.fuelChoices.contains(fuel);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _titleTap,
            child: AppSheetHeader(title: L10n.t('settings.title')),
          ),
          SafetySwitch(
            icon: Icons.car_crash_rounded,
            title: SafetyTexts.crashTitle,
            subtitle: SafetyTexts.crashExplain,
            value: s.crashDetection,
            onChanged: (v) => s.setCrashDetection(v),
          ),
          SafetySwitch(
            icon: Icons.sms_rounded,
            title: SafetyTexts.smsTitle,
            subtitle: SafetyTexts.smsExplain,
            value: s.smsFallback,
            onChanged: (v) => _setSms(s, v),
            warning: _smsDenied ? SafetyTexts.smsDenied : null,
          ),
          SafetySwitch(
            icon: Icons.free_breakfast_rounded,
            title: SafetyTexts.fatigueTitle,
            subtitle: SafetyTexts.fatigueExplain,
            value: s.fatigueReminder,
            onChanged: (v) => s.setFatigueReminder(v),
          ),
          SafetySwitch(
            icon: Icons.person_search_rounded,
            title: SafetyTexts.checkInTitle,
            subtitle: SafetyTexts.checkInExplain,
            value: s.soloCheckIn,
            onChanged: (v) => s.setSoloCheckIn(v),
          ),
          SafetySwitch(
            icon: Icons.checklist_rounded,
            title: SafetyTexts.docsTitle,
            subtitle: SafetyTexts.docsExplain,
            value: s.documentsReminder,
            onChanged: (v) => s.setDocumentsReminder(v),
          ),
          _section(L10n.t('settings.ride')),
          FuelRangeField(
            value: fuel,
            custom: _customFuel || (!fuelIsChoice && fuel > 0),
            controller: _fuel,
            onChoice: (v) {
              setState(() => _customFuel = false);
              s.setFuelRangeKm(v);
            },
            onCustom: () {
              _fuel.text = fuelIsChoice ? '' : '$fuel';
              setState(() => _customFuel = true);
            },
            onSave: () => _saveCustomFuel(s),
          ),
          _section(SafetyTexts.nearbySection),
          if (auth != null) ...[
            SafetySwitch(
              icon: Icons.volunteer_activism_rounded,
              title: SafetyTexts.helpTitle,
              subtitle: SafetyTexts.helpExplain,
              value: auth.assistHelp,
              onChanged: (v) => _saveNet(auth, help: v),
            ),
            SafetySwitch(
              icon: Icons.emergency_share_rounded,
              title: SafetyTexts.askTitle,
              subtitle: SafetyTexts.askExplain,
              value: auth.assistAsk,
              onChanged: (v) => _saveNet(auth, ask: v),
            ),
            SafetySwitch(
              icon: Icons.medical_information_rounded,
              title: SafetyTexts.medicalTitle,
              subtitle: SafetyTexts.medicalExplain,
              value: auth.responderMedical,
              onChanged: (v) => _saveNet(auth, medical: v),
            ),
          ],
          SafetySwitch(
            icon: Icons.warning_amber_rounded,
            title: SafetyTexts.hazardTitle,
            subtitle: SafetyTexts.hazardExplain,
            value: s.hazardAlerts,
            onChanged: (v) => s.setHazardAlerts(v),
          ),
          _section(SafetyTexts.voiceSection),
          SafetySwitch(
            icon: Icons.record_voice_over_rounded,
            title: 'Announce all alerts',
            subtitle: 'Read out all notifications and alerts via voice',
            value: s.voiceAnnounceAllAlerts,
            onChanged: (v) => s.setVoiceAnnounceAllAlerts(v),
          ),
          SafetySwitch(
            icon: Icons.record_voice_over_rounded,
            title: SafetyTexts.voiceCriticalTitle,
            subtitle: SafetyTexts.voiceCriticalExplain,
            value: s.voiceCritical,
            onChanged: (v) => s.setVoiceCritical(v),
          ),
          SafetySwitch(
            icon: Icons.campaign_rounded,
            title: SafetyTexts.voiceWarningsTitle,
            subtitle: SafetyTexts.voiceWarningsExplain,
            value: s.voiceWarnings,
            onChanged: (v) => s.setVoiceWarnings(v),
          ),
          SafetySwitch(
            icon: Icons.nights_stay_rounded,
            title: SafetyTexts.darkVoiceTitle,
            subtitle: SafetyTexts.darkVoiceExplain,
            value: s.speakMoreAfterDark,
            onChanged: (v) => s.setSpeakMoreAfterDark(v),
          ),
          _section(SafetyTexts.notificationSection),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.s16, vertical: Space.s8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.timer_outlined, color: AppTheme.textSecondary, size: 22),
                    const SizedBox(width: Space.s12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Map alert banner duration', style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                          Text(
                            s.mapAlertDismissSeconds == 0
                                ? 'Manual dismissal only on map'
                                : 'Dismisses from map after ${s.mapAlertDismissSeconds} seconds (saved in notifications)',
                            style: AppText.caption,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.s8),
                Wrap(
                  spacing: Space.s8,
                  runSpacing: Space.s4,
                  children: [
                    for (final sec in NetworkConstants.mapAlertDismissChoices)
                      ChoiceChip(
                        label: Text(sec == 0 ? 'Manual' : '${sec}s'),
                        selected: s.mapAlertDismissSeconds == sec,
                        onSelected: (_) => s.setMapAlertDismissSeconds(sec),
                      ),
                  ],
                ),
              ],
            ),
          ),
          SafetySwitch(
            icon: Icons.lock_open_rounded,
            title: SafetyTexts.lockTitle,
            subtitle: SafetyTexts.lockExplain,
            value: s.rideOnLockScreen,
            onChanged: (v) => s.setRideOnLockScreen(v),
          ),
          SafetySwitch(
            icon: Icons.view_agenda_rounded,
            title: SafetyTexts.richTitle,
            subtitle: SafetyTexts.richExplain,
            value: s.richNotification,
            onChanged: (v) => s.setRichNotification(v),
          ),
          SafetySwitch(
            icon: Icons.medical_services_rounded,
            title: SafetyTexts.medicalLockTitle,
            subtitle: SafetyTexts.medicalLockExplain,
            value: s.medicalIdOnLockScreen,
            onChanged: (v) => s.setMedicalIdOnLockScreen(v),
          ),
          _section(L10n.t('settings.mapsSection')),
          SafetySwitch(
            icon: Icons.map_rounded,
            title: SafetyTexts.mapsTitle,
            subtitle: SafetyTexts.mapsExplain,
            value: s.saveRouteMaps,
            onChanged: (v) => s.setSaveRouteMaps(v),
          ),
          _section(SafetyTexts.languageTitle),
          LanguagePicker(value: s.language, onChanged: (l) => s.setLanguage(l)),
          if (showDev) ...[
            const Divider(),
            ListTile(
              key: const ValueKey('devImpact'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.watch_rounded, color: AppTheme.textSecondary),
              title: Text(SafetyTexts.devTitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
              subtitle: Text(L10n.t('settings.dev.hint'), maxLines: 4, overflow: TextOverflow.ellipsis, style: AppText.caption),
              onTap: () {
                context.read<SafetyService?>()?.externalImpact(
                      source: ExternalImpactSource.developer,
                      g: SafetyConstants.wearableImpactG,
                      atMs: DateTime.now().millisecondsSinceEpoch,
                    );
                Navigator.of(context).maybePop();
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// "Tank range (km)" (3.16, item 2): a row of choices (Off, 150 ... 400) and
/// "Other" with a number field. Shared by the safety settings and the profile.
class FuelRangeField extends StatelessWidget {
  final int value;
  final bool custom;
  final TextEditingController controller;
  final ValueChanged<int> onChoice;
  final VoidCallback onCustom;
  final VoidCallback onSave;

  const FuelRangeField({
    super.key,
    required this.value,
    required this.custom,
    required this.controller,
    required this.onChoice,
    required this.onCustom,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.local_gas_station_rounded, color: AppTheme.textSecondary),
            const SizedBox(width: Space.s16),
            Expanded(
              child: Text(SafetyTexts.fuelTitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
            ),
            Text(
              value > 0 ? '$value km' : L10n.t('settings.fuel.off'),
              style: AppText.body.copyWith(fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ],
        ),
        const SizedBox(height: Space.s8),
        Wrap(
          spacing: Space.s8,
          runSpacing: Space.s4,
          children: [
            for (final v in SafetySettingsSheet.fuelChoices)
              ChoiceChip(
                label: Text(v == 0 ? L10n.t('settings.fuel.off') : '$v'),
                selected: !custom && value == v,
                materialTapTargetSize: MaterialTapTargetSize.padded,
                onSelected: (_) => onChoice(v),
              ),
            ChoiceChip(
              label: Text(L10n.t('settings.fuel.custom')),
              selected: custom,
              materialTapTargetSize: MaterialTapTargetSize.padded,
              onSelected: (_) => onCustom(),
            ),
          ],
        ),
        if (custom)
          Padding(
            padding: const EdgeInsets.only(top: Space.s8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('fuelRange'),
                    controller: controller,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
                    style: AppText.body,
                    decoration: InputDecoration(
                      labelText: 'km',
                      isDense: true,
                      filled: true,
                      fillColor: AppTheme.elevatedCard,
                      border: const OutlineInputBorder(borderRadius: Radii.mdAll),
                    ),
                    onSubmitted: (_) => onSave(),
                  ),
                ),
                const SizedBox(width: Space.s8),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
                  onPressed: onSave,
                  child: const Text('Save'),
                ),
              ],
            ),
          ),
        const SizedBox(height: Space.s4),
        Text(SafetyTexts.fuelExplain, maxLines: 4, overflow: TextOverflow.ellipsis, style: AppText.caption),
      ],
    );
  }
}

/// System / English / Hindi / Telugu (3.16, item 23). Shared by the safety
/// settings and the profile; writes [SettingsService.setLanguage].
class LanguagePicker extends StatelessWidget {
  final AppLanguage value;
  final ValueChanged<AppLanguage> onChanged;

  const LanguagePicker({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InputDecorator(
          decoration: InputDecoration(
            labelText: SafetyTexts.languageTitle,
            prefixIcon: Icon(Icons.translate_rounded, color: AppTheme.textSecondary),
            filled: true,
            fillColor: AppTheme.elevatedCard,
            border: const OutlineInputBorder(borderRadius: Radii.mdAll),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<AppLanguage>(
              key: const ValueKey('language'),
              value: value,
              isDense: true,
              isExpanded: true,
              dropdownColor: AppTheme.slateCard,
              style: AppText.body,
              items: [
                for (final l in AppLanguage.values) DropdownMenuItem(value: l, child: Text(l.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (l) {
                if (l != null) onChanged(l);
              },
            ),
          ),
        ),
        const SizedBox(height: Space.s4),
        Text(SafetyTexts.languageExplain, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.caption),
      ],
    );
  }
}

/// A switch row with an explanation (and an optional amber warning line).
class SafetySwitch extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? warning;

  const SafetySwitch({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.warning,
  });

  @override
  Widget build(BuildContext context) {
    final w = warning;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: value,
      onChanged: onChanged,
      activeColor: AppTheme.neonCyan,
      secondary: Icon(icon, color: AppTheme.textSecondary),
      title: Text(title, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(subtitle, maxLines: 10, overflow: TextOverflow.ellipsis, style: AppText.caption),
          if (w != null) Text(w, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: StatusColors.warning)),
        ],
      ),
    );
  }
}
