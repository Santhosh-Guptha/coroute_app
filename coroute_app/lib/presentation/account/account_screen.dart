import '../ride/fuel_sheet.dart';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/meta_service.dart';
import '../../data/services/settings_service.dart';
import '../admin/master_admin_dashboard.dart';
import '../auth/access_gate_screen.dart';
import '../onboarding/permissions_screen.dart';
import '../safety/safety_settings_sheet.dart';
import '../widgets/data_saver_tile.dart';
import 'appearance_sheet.dart';
import 'change_password_screen.dart';
import 'edit_profile_screen.dart';

/// The Profile tab: who you are, then every setting in one place.
/// Each item (theme, data saver, permissions, sign out, version) appears
/// only here in the app.
class AccountScreen extends StatelessWidget {
  /// True when shown as the Profile tab (no back button).
  final bool embedded;
  const AccountScreen({super.key, this.embedded = false});

  Future<void> _open(BuildContext context, String url) async {
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
  }

  void _push(BuildContext context, Widget screen) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final meta = context.watch<MetaService>().meta;
    final theme = context.watch<ThemeController>();
    final settings = context.watch<SettingsService?>();
    final base = AppConfig.apiBaseUrl;
    final privacyUrl = meta?.privacyUrl.isNotEmpty == true ? meta!.privacyUrl : '$base/privacy';
    final termsUrl = meta?.termsUrl.isNotEmpty == true ? meta!.termsUrl : '$base/terms';
    final support = meta?.supportEmail ?? '';
    final name = (auth.currentUserName ?? '').trim();
    final vehicle = auth.isPillion
        ? 'Pillion'
        : [
            if ((auth.vehicleType ?? '').trim().isNotEmpty) auth.vehicleType!.trim(),
            if ((auth.vehicleNo ?? '').trim().isNotEmpty) auth.vehicleNo!.trim(),
          ].join(', ');
    final contactSet = (auth.emergencyContact ?? '').trim().length >= 7 && (auth.emergencyContactName ?? '').trim().length >= 2;

    Widget row(IconData icon, String title, {String? subtitle, VoidCallback? onTap, Color? color, bool chevron = true}) {
      final sub = subtitle;
      return ListTile(
        minVerticalPadding: Space.s12,
        leading: Icon(icon, color: color ?? AppTheme.textSecondary),
        title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(color: color ?? AppTheme.textPrimary)),
        subtitle: sub == null ? null : Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption),
        trailing: chevron && onTap != null ? Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted) : null,
        onTap: onTap,
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(title: const Text('Profile'), automaticallyImplyLeading: !embedded),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.only(bottom: Space.s32),
            children: [
              // Who you are: one tap opens the one profile editor.
              Semantics(
                button: true,
                label: 'Edit profile',
                child: InkWell(
                  onTap: () => _push(context, const EditProfileScreen()),
                  child: Padding(
                    padding: const EdgeInsets.all(Space.s16),
                    child: Row(
                      children: [
                        RiderAvatar(name: name.isEmpty ? '?' : name, size: 56),
                        const SizedBox(width: Space.s16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(name.isEmpty ? 'Your name' : name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title),
                              if (vehicle.isNotEmpty)
                                Text(vehicle, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  Icon(
                                    contactSet ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                                    size: 16,
                                    color: contactSet ? StatusColors.success : StatusColors.warning,
                                  ),
                                  const SizedBox(width: Space.s4),
                                  Flexible(
                                    child: Text(
                                      contactSet ? 'Emergency contact: set' : 'Emergency contact: not set',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppText.caption.copyWith(color: AppTheme.textSecondary),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.edit_rounded, color: AppTheme.textMuted),
                      ],
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              const _SectionLabel('Settings'),
              row(theme.isLight ? Icons.light_mode_rounded : Icons.dark_mode_rounded, 'Theme',
                  subtitle: AppearanceSheet.summary(theme), onTap: () => AppearanceSheet.show(context)),
              const DataSaverTile(),
              if (settings != null) row(Icons.local_gas_station_rounded, 'Fuel profile', subtitle: 'Range, mileage, reserve and buffer', onTap: () => showFuelSheet(context, configure: true)),
              if (settings != null)
                row(Icons.health_and_safety_rounded, 'Ride safety',
                    subtitle: SafetySettingsSheet.summary(settings), onTap: () => SafetySettingsSheet.show(context)),
              row(Icons.verified_user_rounded, 'Permissions',
                  subtitle: 'Location, microphone, notifications, battery and texts', onTap: () => _push(context, const PermissionsScreen())),
              row(Icons.password_rounded, 'Change password', onTap: () => _push(context, const ChangePasswordScreen())),
              if (auth.isMasterAdmin) row(Icons.admin_panel_settings_rounded, 'Admin', subtitle: 'Live rides, history and users',
                  onTap: () => _push(context, const MasterAdminDashboard())),
              const _SectionLabel('Help'),
              row(Icons.bug_report_rounded, 'Report a problem', subtitle: 'We reply by e-mail.',
                  onTap: () => _push(context, const ReportProblemScreen())),
              row(Icons.privacy_tip_rounded, 'Privacy policy', onTap: () => _open(context, privacyUrl)),
              row(Icons.gavel_rounded, 'Terms of use', onTap: () => _open(context, termsUrl)),
              const _SectionLabel('Account'),
              row(Icons.logout_rounded, 'Sign out', chevron: false, onTap: () async {
                await auth.logout();
                if (context.mounted) {
                  Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const AccessGateScreen()), (_) => false);
                }
              }),
              row(Icons.delete_forever_rounded, 'Delete my account', subtitle: 'Removes your account, profile and ride history.',
                  color: StatusColors.critical, chevron: false, onTap: () => _confirmDelete(context)),
              const SizedBox(height: Space.s24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.s16),
                child: Text(
                  'CoRoute ${MetaService.currentVersion} (build ${MetaService.currentBuild})${support.isNotEmpty ? ', $support' : ''}',
                  style: AppText.caption,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Two steps: the standard confirm, then type DELETE in a sheet.
  Future<void> _confirmDelete(BuildContext context) async {
    final go = await confirmAction(
      context,
      title: 'Delete your account?',
      message: 'This permanently removes your account, profile, ride memberships and ride history. It cannot be undone.',
      confirmLabel: 'Continue',
      destructive: true,
    );
    if (!go || !context.mounted) return;
    final typed = await showAppSheet<bool>(
      context,
      title: 'Type DELETE to confirm',
      isScrollControlled: true,
      builder: (_) => const _TypeDeleteSheet(),
    );
    if (typed != true || !context.mounted) return;
    final res = await context.read<AuthService>().deleteAccount();
    if (!context.mounted) return;
    if (res['success'] == true) {
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const AccessGateScreen()), (_) => false);
      messenger.showSnackBar(const SnackBar(content: Text('Your account has been deleted.')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(res['error']?.toString() ?? 'Could not delete the account.')));
    }
  }
}

class _TypeDeleteSheet extends StatefulWidget {
  const _TypeDeleteSheet();

  @override
  State<_TypeDeleteSheet> createState() => _TypeDeleteSheetState();
}

class _TypeDeleteSheetState extends State<_TypeDeleteSheet> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ok = _ctrl.text.trim() == 'DELETE';
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _ctrl,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            onChanged: (_) => setState(() {}),
            style: AppText.body,
            decoration: const InputDecoration(
              labelText: 'Type DELETE',
              border: OutlineInputBorder(borderRadius: Radii.mdAll),
            ),
          ),
          const SizedBox(height: Space.s16),
          FilledButton(
            onPressed: ok ? () => Navigator.pop(context, true) : null,
            style: FilledButton.styleFrom(
              backgroundColor: StatusColors.critical,
              foregroundColor: StatusColors.onCritical,
              minimumSize: const Size.fromHeight(56),
            ),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Space.s16, Space.s24, Space.s16, Space.s4),
        child: Semantics(header: true, child: Text(text, style: AppText.label)),
      );
}

/// In-app problem report. Posts to the same endpoint as the website form and
/// adds the app version and platform so reports are actionable.
class ReportProblemScreen extends StatefulWidget {
  const ReportProblemScreen({super.key});

  @override
  State<ReportProblemScreen> createState() => _ReportProblemScreenState();
}

class _ReportProblemScreenState extends State<ReportProblemScreen> {
  final _message = TextEditingController();
  bool _busy = false;
  String? _error;
  final int _openedAt = DateTime.now().millisecondsSinceEpoch;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _message.text.trim();
    if (text.length < 20) {
      setState(() => _error = 'Please describe the problem in at least 20 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = context.read<AuthService>();
    final device = kIsWeb ? 'web' : '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    try {
      await context.read<ApiClient>().post('/feedback', {
        'name': auth.currentUserName ?? '',
        'email': auth.currentUserEmail ?? '',
        'message': text,
        't': _openedAt,
        'appVersion': '${MetaService.currentVersion}+${MetaService.currentBuild}',
        'device': device,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Thanks. Your report was sent.')));
      Navigator.pop(context);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Could not send right now. Please try again later.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(title: const Text('Report a problem')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(Space.s16),
            children: [
              Text(
                'What happened, what you expected, and which screen you were on. Your e-mail, app version and phone platform are attached so we can reply.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: Space.s12),
              TextField(
                controller: _message,
                minLines: 6,
                maxLines: 12,
                maxLength: 2000,
                style: TextStyle(color: AppTheme.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Describe the problem',
                  hintStyle: TextStyle(color: AppTheme.textMuted),
                  filled: true,
                  fillColor: AppTheme.elevatedCard,
                  border: const OutlineInputBorder(borderRadius: Radii.mdAll),
                  counterStyle: TextStyle(color: AppTheme.textMuted),
                ),
              ),
              if (_error != null) Text(_error!, style: TextStyle(color: AppTheme.laserRed, fontSize: 13)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _send,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                child: _busy
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                    : const Text('Send report'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
