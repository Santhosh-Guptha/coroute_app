import 'package:flutter/material.dart';

import '../../core/constants/safety_constants.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../domain/tracking/battery_saver.dart';

/// Plain-language texts of the ride safety switches, shared by Settings
/// (SettingsScreen), the pre-ride checklist and the nearby riders consent sheet.
/// Read at build time so they follow the rider's language (3.16).
class SafetyTexts {
  SafetyTexts._();

  static String get crashTitle => L10n.t('settings.crash');
  static String get crashExplain => L10n.t('settings.crash.hint', {
        'speed': SafetyConstants.crashArmSpeedKmh.round(),
        'sec': SafetyConstants.crashCountdown.inSeconds,
      });

  static String get smsTitle => L10n.t('settings.sms');
  static String get smsExplain =>
      L10n.t('settings.sms.hint', {'max': SafetyConstants.smsMaxRecipients});
  static String get smsDenied => L10n.t('settings.sms.denied');

  static String get fatigueTitle => L10n.t('settings.fatigue');
  static String get fatigueExplain => L10n.t('settings.fatigue.hint', {
        'h': SafetyConstants.fatigueRideFor.inHours,
        'min': SafetyConstants.fatigueBreakFor.inMinutes,
      });

  static String get checkInTitle => L10n.t('settings.checkin.title');
  static String get checkInExplain => L10n.t('settings.checkin.hint', {
        'far': SafetyConstants.checkInFarFor.inMinutes,
        'answer': SafetyConstants.checkInAnswerWithin.inMinutes,
      });

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

  static String get voiceWarningsTitle => L10n.t('settings.voiceWarnings');
  static String get voiceWarningsExplain => L10n.t('settings.voiceWarnings.hint');

  static const String batterySaverTitle = 'Battery saver';
  static const String batterySaverExplain =
      'On for every ride. Without it, it turns on by itself at ${BatterySaverPolicy.defaultEnterPercent}% battery: gentler GPS, '
      'a lighter map, slower position updates and the dark map. SOS, crash detection and alerts are never reduced.';
  static String get languageTitle => L10n.t('settings.language');
  static String get languageExplain => L10n.t('settings.language.hint');

  static String get lockTitle => L10n.t('settings.lock');
  static String get lockExplain => L10n.t('settings.lock.hint');

  static String get saveFailed => L10n.t('settings.saveFailed');
}

/// Language picker (system / English / Hindi / Telugu) for the safety screens and spoken alerts.
class LanguagePicker extends StatelessWidget {
  final AppLanguage value;
  final ValueChanged<AppLanguage> onChanged;

  const LanguagePicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InputDecorator(
          decoration: InputDecoration(
            labelText: SafetyTexts.languageTitle,
            prefixIcon: Icon(
              Icons.translate_rounded,
              color: AppTheme.accentText,
            ),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<AppLanguage>(
              key: const ValueKey('language'),
              value: value,
              isDense: true,
              isExpanded: true,
              dropdownColor: AppTheme.card,
              borderRadius: Radii.mdAll,
              style: AppText.body,
              items: [
                for (final l in AppLanguage.values)
                  DropdownMenuItem(
                    value: l,
                    child: Text(
                      l.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (l) {
                if (l != null) onChanged(l);
              },
            ),
          ),
        ),
        const SizedBox(height: Space.s4),
        Text(
          SafetyTexts.languageExplain,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: AppText.caption,
        ),
      ],
    );
  }
}

/// A switch row with an explanation (and an optional amber warning line).
/// Inside a card list: a hairline under the row unless [divider] is false.
class SafetySwitch extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? warning;
  final bool divider;

  const SafetySwitch({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.warning,
    this.divider = true,
  });

  @override
  Widget build(BuildContext context) {
    final w = warning;
    return Container(
      decoration: BoxDecoration(
        border: divider
            ? Border(bottom: BorderSide(color: AppTheme.border))
            : null,
      ),
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: value,
        onChanged: onChanged,
        activeColor: AppTheme.brand,
        secondary: Icon(icon, color: AppTheme.accentText, size: 22),
        title: Text(
          title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: AppText.body.copyWith(fontWeight: FontWeight.w700),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              subtitle,
              maxLines: 10,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption,
            ),
            if (w != null)
              Text(
                w,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(color: AppTheme.warnText),
              ),
          ],
        ),
      ),
    );
  }
}
