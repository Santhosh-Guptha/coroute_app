import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/permissions_service.dart';
import '../account/edit_profile_screen.dart';

/// One automatic check on the pre-ride checklist (read once when the sheet opens).
class AutoCheck {
  final String key;
  final String title;
  final String okText;
  final String problemText;
  final bool ok;

  /// Info only: shown, but never amber (for example the microphone).
  final bool infoOnly;

  /// What "Fix" opens: a permission key of [PermissionsService], 'profile', or null (no fix button).
  final String? fix;

  const AutoCheck({
    required this.key,
    required this.title,
    required this.okText,
    required this.problemText,
    required this.ok,
    this.infoOnly = false,
    this.fix,
  });

  AutoCheck withOk(bool value) =>
      AutoCheck(key: key, title: title, okText: okText, problemText: problemText, ok: value, infoOnly: infoOnly, fix: fix);
}

/// Pre-ride checklist logic (no UI): the 24-hour skip and the automatic checks.
class PreRideChecklist {
  PreRideChecklist._();

  /// Things to tick by hand. Local only: never sent anywhere, reset for every ride.
  static const List<String> manualItems = [
    'Fuel tank filled',
    'Helmet and riding gear',
    'Licence, RC, insurance and PUC',
    'Phone mount and charger',
    'First-aid kit',
  ];

  static Future<bool> skipActive({int? nowMs}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final until = prefs.getInt(AppConstants.keyChecklistSkipUntil) ?? 0;
      return until > (nowMs ?? DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      return false;
    }
  }

  static Future<void> skipFor24Hours({int? nowMs}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
      await prefs.setInt(AppConstants.keyChecklistSkipUntil, now + AppConstants.checklistSkipFor.inMilliseconds);
    } catch (_) {}
  }

  /// Builds the automatic checks from what the phone already knows (no network, no GPS).
  static List<AutoCheck> checksFrom({
    required List<PermissionItem> permissions,
    int? batteryLevel,
    bool isCharging = false,
    bool? hasEmergencyContact,
  }) {
    PermissionItem? perm(String key) {
      for (final p in permissions) {
        if (p.key == key) return p;
      }
      return null;
    }

    final always = perm('locationAlways');
    final notif = perm('notification');
    final battery = perm('battery');
    final mic = perm('microphone');
    return [
      if (always != null)
        AutoCheck(
          key: 'locationAlways',
          title: 'Location "Allow all the time"',
          okText: 'Your convoy sees you with the screen off.',
          problemText: 'Without it your position stops when the screen is off.',
          ok: always.granted,
          fix: 'locationAlways',
        ),
      if (notif != null)
        AutoCheck(
          key: 'notification',
          title: 'Notifications',
          okText: 'SOS and group alerts can reach you.',
          problemText: 'You would not see SOS or group alerts.',
          ok: notif.granted,
          fix: 'notification',
        ),
      if (batteryLevel != null)
        AutoCheck(
          key: 'batteryLevel',
          title: 'Battery $batteryLevel%${isCharging ? ', charging' : ''}',
          okText: 'Enough for the ride.',
          problemText: 'Charge the phone or bring a power bank.',
          ok: isCharging || batteryLevel >= AppConstants.lowBatteryPercent,
        ),
      if (battery != null)
        AutoCheck(
          key: 'battery',
          title: 'Unrestricted battery use',
          okText: 'The phone will not close CoRoute on a long ride.',
          problemText: 'Some phones close CoRoute in the background without it.',
          ok: battery.granted,
          fix: 'battery',
        ),
      if (hasEmergencyContact != null)
        AutoCheck(
          key: 'emergencyContact',
          title: 'Emergency contact',
          okText: 'Saved in your profile.',
          problemText: 'Add one so the SOS screen can call or text them.',
          ok: hasEmergencyContact,
          fix: 'profile',
        ),
      if (mic != null)
        AutoCheck(
          key: 'microphone',
          title: 'Microphone',
          okText: 'The intercom can be used.',
          problemText: 'Needed only if you want to talk on the intercom.',
          ok: mic.granted,
          infoOnly: true,
          fix: 'microphone',
        ),
    ];
  }
}

/// Shown before creating or joining a ride. It never blocks: "Start the ride" always works;
/// items that need attention are amber with a "Fix" button.
class PreRideChecklistSheet extends StatefulWidget {
  final List<AutoCheck> checks;
  const PreRideChecklistSheet({super.key, required this.checks});

  /// Opens the checklist unless it was skipped in the last 24 hours. Returns true to continue,
  /// false when the rider closed it without starting.
  static Future<bool> show(BuildContext context) async {
    if (await PreRideChecklist.skipActive()) return true;
    if (!context.mounted) return true;
    final convoys = Provider.of<ConvoyService?>(context, listen: false);
    final auth = Provider.of<AuthService?>(context, listen: false);
    List<PermissionItem> permissions = const [];
    try {
      permissions = await PermissionsService.status();
    } catch (_) {}
    if (!context.mounted) return true;
    final checks = PreRideChecklist.checksFrom(
      permissions: permissions,
      batteryLevel: convoys?.currentBatteryLevel,
      isCharging: convoys?.isCharging ?? false,
      hasEmergencyContact: auth == null ? null : (auth.emergencyContact ?? '').trim().isNotEmpty,
    );
    final result = await showAppSheet<bool>(
      context,
      isScrollControlled: true,
      builder: (_) => PreRideChecklistSheet(checks: checks),
    );
    return result ?? false;
  }

  @override
  State<PreRideChecklistSheet> createState() => _PreRideChecklistSheetState();
}

class _PreRideChecklistSheetState extends State<PreRideChecklistSheet> {
  late List<AutoCheck> _checks;
  final Set<int> _ticked = {};
  bool _skip24h = false;

  @override
  void initState() {
    super.initState();
    _checks = List.of(widget.checks);
  }

  Future<void> _fix(int index) async {
    final c = _checks[index];
    final fix = c.fix;
    if (fix == null) return;
    bool ok;
    if (fix == 'profile') {
      await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const EditProfileScreen()));
      if (!mounted) return;
      final auth = Provider.of<AuthService?>(context, listen: false);
      ok = (auth?.emergencyContact ?? '').trim().isNotEmpty;
    } else {
      ok = await PermissionsService.request(fix);
    }
    if (!mounted) return;
    setState(() => _checks[index] = c.withOk(ok));
  }

  Future<void> _start() async {
    if (_skip24h) await PreRideChecklist.skipFor24Hours();
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.9;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppSheetHeader(title: 'Before you ride', subtitle: 'A quick check. Nothing here is sent anywhere.'),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (var i = 0; i < _checks.length; i++) _autoRow(i),
                const Divider(),
                for (var i = 0; i < PreRideChecklist.manualItems.length; i++)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _ticked.contains(i),
                    activeColor: AppTheme.emeraldSafe,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(PreRideChecklist.manualItems[i], style: AppText.body),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _ticked.add(i);
                      } else {
                        _ticked.remove(i);
                      }
                    }),
                  ),
                const Divider(),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _skip24h,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text('Do not show for 24 hours', style: AppText.body.copyWith(color: AppTheme.textSecondary)),
                  onChanged: (v) => setState(() => _skip24h = v == true),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.s12),
          FilledButton(
            onPressed: _start,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            child: const Text('Start the ride', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Widget _autoRow(int i) {
    final c = _checks[i];
    final attention = !c.ok && !c.infoOnly;
    final color = c.ok ? AppTheme.emeraldSafe : (attention ? AppTheme.hyperAmber : AppTheme.textMuted);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(c.ok ? Icons.check_circle_rounded : (attention ? Icons.error_outline_rounded : Icons.info_outline_rounded), color: color),
      title: Text(c.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
      subtitle: Text(c.ok ? c.okText : c.problemText, style: AppText.caption.copyWith(color: attention ? AppTheme.hyperAmber : AppTheme.textMuted)),
      trailing: (!c.ok && c.fix != null)
          ? TextButton(
              onPressed: () => _fix(i),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              child: Text('Fix', style: TextStyle(color: AppTheme.neonCyan, fontWeight: FontWeight.bold)),
            )
          : null,
    );
  }
}
