import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/network_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/settings_service.dart';
import '../safety/safety_settings_sheet.dart';

/// "Riders helping riders": shown once before a ride until the rider
/// answers (Continue), or at most [NetworkConstants.netConsentMaxPrompts]
/// times when they tap Later (the defaults stay on meanwhile). Plain
/// explanation, the two assistance switches (on) and the medical switch
/// (off). Continue saves them with the consent.
class NetworkConsentSheet extends StatefulWidget {
  const NetworkConsentSheet({super.key});

  /// True when the sheet should be offered now.
  static bool due(SettingsService? settings, AuthService? auth) {
    if (settings == null || auth == null) return false;
    if (settings.netConsentSeen || auth.netConsentAt > 0) return false;
    return settings.netConsentPrompts < NetworkConstants.netConsentMaxPrompts;
  }

  /// Shows the sheet when [due]. Never blocks the ride: always completes.
  static Future<void> maybeShow(BuildContext context) async {
    final settings = Provider.of<SettingsService?>(context, listen: false);
    final auth = Provider.of<AuthService?>(context, listen: false);
    if (!due(settings, auth)) return;
    final answered = await showAppSheet<bool>(
      context,
      isScrollControlled: true,
      builder: (_) => const NetworkConsentSheet(),
    );
    if (answered != true) settings?.bumpNetConsentPrompts();
  }

  @override
  State<NetworkConsentSheet> createState() => _NetworkConsentSheetState();
}

class _NetworkConsentSheetState extends State<NetworkConsentSheet> {
  bool _help = true;
  bool _ask = true;
  bool _medical = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final auth = Provider.of<AuthService?>(context, listen: false);
    if (auth != null && auth.netLoaded) {
      _help = auth.assistHelp;
      _ask = auth.assistAsk;
      _medical = auth.responderMedical;
    }
  }

  Future<void> _continue() async {
    final auth = Provider.of<AuthService?>(context, listen: false);
    final settings = Provider.of<SettingsService?>(context, listen: false);
    setState(() => _busy = true);
    final ok = await (auth?.updateNetworkPrefs(assistHelp: _help, assistAsk: _ask, responderMedical: _medical, netConsent: true) ?? Future.value(false));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      settings?.markNetConsentSeen();
      Navigator.of(context).pop(true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not save this now. We will ask again before your next ride.')));
      Navigator.of(context).pop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.9;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppSheetHeader(title: 'Riders helping riders', subtitle: 'Safety does not depend on your group being public.'),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                Text(
                  'If you have an accident, CoRoute can also ask one to three riders from other groups who are already riding towards you, '
                  'when they may reach you faster than your own group. They see only where you are and how far. '
                  'Your name and vehicle are shared only after one of them accepts. Your phone number is never shared.',
                  style: AppText.body,
                ),
                const SizedBox(height: Space.s8),
                Text(
                  'You can change this any time in Profile, Ride safety.',
                  style: AppText.caption.copyWith(color: AppTheme.textSecondary),
                ),
                const SizedBox(height: Space.s8),
                SafetySwitch(
                  icon: Icons.emergency_share_rounded,
                  title: SafetyTexts.askTitle,
                  subtitle: SafetyTexts.askExplain,
                  value: _ask,
                  onChanged: (v) => setState(() => _ask = v),
                ),
                SafetySwitch(
                  icon: Icons.volunteer_activism_rounded,
                  title: SafetyTexts.helpTitle,
                  subtitle: SafetyTexts.helpExplain,
                  value: _help,
                  onChanged: (v) => setState(() => _help = v),
                ),
                SafetySwitch(
                  icon: Icons.medical_information_rounded,
                  title: SafetyTexts.medicalTitle,
                  subtitle: SafetyTexts.medicalExplain,
                  value: _medical,
                  onChanged: (v) => setState(() => _medical = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.s12),
          FilledButton(
            onPressed: _busy ? null : _continue,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            child: _busy
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                : const Text('Continue', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: const Text('Later'),
          ),
        ],
      ),
    );
  }
}
