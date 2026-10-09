import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/permissions_service.dart';
import '../../data/services/safety_native.dart';
import '../../data/services/settings_service.dart';
import '../account/edit_profile_screen.dart';
import '../ride/network_consent_sheet.dart';
import '../safety/oem_battery_guide.dart';
import '../safety/safety_settings_sheet.dart';

/// One automatic check on the pre-ride checklist (read once when the sheet opens).
class AutoCheck {
  final String key;
  final String title;
  final String okText;
  final String problemText;
  final bool ok;

  /// Info only: shown, but never amber (for example the microphone).
  final bool infoOnly;

  /// What "Fix" opens: a permission key of [PermissionsService], 'profile', 'oemGuide', or null (no fix button).
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
    String? manufacturer,
    bool oemGuideSeen = true,
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
    final fullScreen = perm('fullScreen');
    final brand = (manufacturer ?? '').trim();
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
      if (fullScreen != null)
        AutoCheck(
          key: 'fullScreen',
          title: 'Alarm on lock screen',
          okText: 'A crash alarm shows over the lock screen.',
          problemText: 'Allow it so you can stop a crash alarm without unlocking the phone.',
          ok: fullScreen.granted,
          fix: 'fullScreen',
        ),
      if (brand.isNotEmpty && !oemGuideSeen)
        AutoCheck(
          key: 'oemGuide',
          title: OemBatteryGuide.rowTitle(brand),
          okText: 'You have seen the steps.',
          problemText: 'Some phones close CoRoute during a ride. See the steps that stop it.',
          ok: false,
          fix: 'oemGuide',
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
/// items that need attention are amber with a "Fix" button. The first line (3.16, item 9)
/// reminds about helmet, licence and documents; it follows the "Helmet and documents
/// reminder" setting.
class PreRideChecklistSheet extends StatefulWidget {
  final List<AutoCheck> checks;

  static const String documentsLine = 'Helmet on, licence and documents with you?';

  /// Asks for a permission (tests pass a fake); defaults to [PermissionsService.request].
  final Future<bool> Function(String key)? requestPermission;
  const PreRideChecklistSheet({super.key, required this.checks, this.requestPermission});

  /// Opens the checklist unless it was skipped in the last 24 hours. Returns true to continue,
  /// false when the rider closed it without starting. Before it, once, the
  /// "Riders helping riders" explanation ([NetworkConsentSheet], also when
  /// the checklist itself is skipped).
  static Future<bool> show(BuildContext context) async {
    await NetworkConsentSheet.maybeShow(context);
    if (!context.mounted) return true;
    if (await PreRideChecklist.skipActive()) return true;
    if (!context.mounted) return true;
    final convoys = Provider.of<ConvoyService?>(context, listen: false);
    final auth = Provider.of<AuthService?>(context, listen: false);
    final settings = Provider.of<SettingsService?>(context, listen: false);
    List<PermissionItem> permissions = const [];
    var manufacturer = '';
    try {
      permissions = await PermissionsService.status();
      manufacturer = (await SafetyNative.deviceInfo()).manufacturer;
    } catch (_) {}
    if (!context.mounted) return true;
    final checks = PreRideChecklist.checksFrom(
      permissions: permissions,
      batteryLevel: convoys?.currentBatteryLevel,
      isCharging: convoys?.isCharging ?? false,
      hasEmergencyContact: auth == null ? null : (auth.emergencyContact ?? '').trim().isNotEmpty,
      manufacturer: manufacturer,
      oemGuideSeen: settings?.oemGuideSeen ?? true,
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
  bool _smsDenied = false;

  Future<bool> _request(String key) => (widget.requestPermission ?? PermissionsService.request)(key);

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
    } else if (fix == 'oemGuide') {
      await OemBatteryGuide.show(context);
      ok = true;
    } else {
      ok = await _request(fix);
    }
    if (!mounted) return;
    setState(() => _checks[index] = c.withOk(ok));
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
                if (Provider.of<SettingsService?>(context)?.documentsReminder ?? false)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.s4, bottom: Space.s8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.sports_motorsports_rounded, size: 22, color: AppTheme.neonCyan),
                        const SizedBox(width: Space.s12),
                        Expanded(child: Text(PreRideChecklistSheet.documentsLine, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.body)),
                      ],
                    ),
                  ),
                for (var i = 0; i < _checks.length; i++) _autoRow(i),
                ..._safetyRows(),
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

  /// The two safety switches (shown when the settings service is available).
  List<Widget> _safetyRows() {
    final s = Provider.of<SettingsService?>(context);
    if (s == null) return const [];
    return [
      const Divider(),
      Padding(
        padding: const EdgeInsets.only(top: Space.s8),
        child: Semantics(header: true, child: Text('Ride safety', style: AppText.label)),
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
    ];
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
