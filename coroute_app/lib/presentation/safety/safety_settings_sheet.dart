import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/safety_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/permissions_service.dart';
import '../../data/services/settings_service.dart';

/// Plain-language texts of the ride safety switches (shared with the pre-ride checklist).
class SafetyTexts {
  SafetyTexts._();

  static const String crashTitle = 'Crash detection';
  static String get crashExplain =>
      'Only during a ride, above ${SafetyConstants.crashArmSpeedKmh.round()} km/h. If the phone senses a crash it rings first: '
      'you have ${SafetyConstants.crashCountdown.inSeconds} seconds to tap I\'m OK, and then nothing is sent.';

  static const String smsTitle = 'Text the group if there is no internet';
  static String get smsExplain =>
      'Only when an SOS cannot be sent: your phone texts your emergency contact, the lead and the nearest riders '
      '(up to ${SafetyConstants.smsMaxRecipients}) with a map link. Numbers stay on this phone only during the ride. Normal SMS charges apply.';
  static const String smsDenied = 'Texts need the SMS permission. You can allow it in Permissions.';

  static const String fatigueTitle = 'Break reminder';
  static String get fatigueExplain =>
      'After ${SafetyConstants.fatigueRideFor.inHours} h of riding without a ${SafetyConstants.fatigueBreakFor.inMinutes} min stop, a gentle reminder for you only.';

  static const String checkInTitle = 'Check on me when I am far from the group';
  static String get checkInExplain =>
      'After ${SafetyConstants.checkInFarFor.inMinutes} min far from the group, CoRoute asks if you are OK. '
      'No answer in ${SafetyConstants.checkInAnswerWithin.inMinutes} min tells your lead.';
}

/// "Ride safety" (Profile tab): the four safety switches with one line each.
class SafetySettingsSheet extends StatefulWidget {
  /// Asks for a permission (tests pass a fake); defaults to [PermissionsService.request].
  final Future<bool> Function(String key)? requestPermission;
  const SafetySettingsSheet({super.key, this.requestPermission});

  static Future<void> show(BuildContext context) => showAppSheet<void>(
        context,
        isScrollControlled: true,
        title: 'Ride safety',
        builder: (_) => const SafetySettingsSheet(),
      );

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

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsService?>();
    if (s == null) return const SizedBox.shrink();
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
        ],
      ),
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
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
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
