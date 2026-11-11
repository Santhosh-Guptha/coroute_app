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
/// times when they tap Later. A plain explanation only: helping and being
/// helped by nearby riders are always on since Nov 11 (owner decision,
/// docs/SETTINGS_MINIMAL_v3.55.md), so there are no switches. Continue saves
/// both on with the consent. Medical info has no switch: a rider who accepts
/// sees it while the alert is open (see ProfileForm.medicalShareNote).
class NetworkConsentSheet extends StatefulWidget {
  const NetworkConsentSheet({super.key});

  /// True when the sheet should be offered now.
  static bool due(SettingsService? settings, AuthService? auth) {
    if (settings == null || auth == null) return false;
    if (settings.netConsentSeen || auth.netConsentAt > 0) return false;
    return settings.netConsentPrompts < NetworkConstants.netConsentMaxPrompts;
  }

  static bool _isShowing = false;

  /// Shown under the two lines (both are part of "Safety is always on").
  static const String alwaysOnNote = 'Both are always on, like crash detection and SOS.';

  /// Shows the sheet when [due]. Never blocks the ride: always completes.
  static Future<void> maybeShow(BuildContext context) async {
    if (_isShowing) return;
    final settings = Provider.of<SettingsService?>(context, listen: false);
    final auth = Provider.of<AuthService?>(context, listen: false);
    if (!due(settings, auth)) return;
    _isShowing = true;
    try {
      final answered = await showAppSheet<bool>(
        context,
        isScrollControlled: true,
        builder: (_) => const NetworkConsentSheet(),
      );
      if (answered != true) settings?.bumpNetConsentPrompts();
    } finally {
      _isShowing = false;
    }
  }

  @override
  State<NetworkConsentSheet> createState() => _NetworkConsentSheetState();
}

class _NetworkConsentSheetState extends State<NetworkConsentSheet> {
  bool _busy = false;

  Future<void> _continue() async {
    final auth = Provider.of<AuthService?>(context, listen: false);
    final settings = Provider.of<SettingsService?>(context, listen: false);
    setState(() => _busy = true);
    final ok = await (auth?.updateNetworkPrefs(assistHelp: true, assistAsk: true, netConsent: true) ?? Future.value(false));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      settings?.markNetConsentSeen();
      if (context.mounted) Navigator.of(context).pop(true);
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not save this now. We will ask again before your next ride.')));
        Navigator.of(context).pop(false);
      }
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
            child: SingleChildScrollView(
              padding: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DsCard(
                    tinted: true,
                    borderColor: AppTheme.tint,
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.volunteer_activism_outlined, size: 24, color: AppTheme.accentText),
                        const SizedBox(width: Space.s12),
                        Expanded(
                          child: Text(
                            'If you have an accident, CoRoute can also ask one to three riders from other groups who are already riding towards you, '
                            'when they may reach you faster than your own group. They see only where you are and how far. '
                            'Name, bike and your medical info are shared only after one accepts, while your alert is open. Never your phone number.',
                            style: AppText.body,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Space.s12),
                  DsCard(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Column(
                      children: [
                        _AlwaysOnLine(icon: Icons.emergency_share_rounded, title: SafetyTexts.askTitle, subtitle: SafetyTexts.askExplain),
                        Divider(color: AppTheme.border),
                        _AlwaysOnLine(icon: Icons.volunteer_activism_rounded, title: SafetyTexts.helpTitle, subtitle: SafetyTexts.helpExplain),
                      ],
                    ),
                  ),
                  const SizedBox(height: Space.s8),
                  Text(NetworkConsentSheet.alwaysOnNote, style: AppText.caption),
                ],
              ),
            ),
          ),
          const SizedBox(height: Space.s16),
          DsButton(
            label: _busy ? 'Saving...' : 'Continue',
            icon: _busy ? null : Icons.check_rounded,
            onPressed: _busy ? null : _continue,
          ),
          const SizedBox(height: Space.s4),
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

/// One always-on line: icon, title, one short explanation and a check (no switch).
class _AlwaysOnLine extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _AlwaysOnLine({required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: AppTheme.accentText),
          const SizedBox(width: Space.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                Text(subtitle, style: AppText.caption),
              ],
            ),
          ),
          const SizedBox(width: Space.s8),
          Icon(Icons.check_rounded, size: 20, color: AppTheme.accentText),
        ],
      ),
    );
  }
}
