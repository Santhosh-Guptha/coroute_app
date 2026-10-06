import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/meta_service.dart';
import '../auth/access_gate_screen.dart';
import '../onboarding/permissions_screen.dart';
import 'appearance_sheet.dart';
import 'change_password_screen.dart';
import 'edit_profile_screen.dart';

/// Account and security: password, permissions, legal pages, problem reports,
/// account deletion (required by Google Play for apps with account creation).
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});

  Future<void> _open(BuildContext context, String url) async {
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final meta = context.watch<MetaService>().meta;
    final theme = context.watch<ThemeController>();
    final base = AppConfig.apiBaseUrl;
    final privacyUrl = meta?.privacyUrl.isNotEmpty == true ? meta!.privacyUrl : '$base/privacy';
    final termsUrl = meta?.termsUrl.isNotEmpty == true ? meta!.termsUrl : '$base/terms';
    final support = meta?.supportEmail ?? '';

    Widget tile(IconData icon, String title, String subtitle, VoidCallback onTap, {Color? color}) {
      color ??= AppTheme.neonCyan;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: GlassCard(
          padding: EdgeInsets.zero,
          child: ListTile(
            leading: Icon(icon, color: color),
            title: Text(title, style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600, fontSize: 14)),
            subtitle: Text(subtitle, style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
            trailing: Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
            onTap: onTap,
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(title: const Text('Account & security')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              GlassCard(
                child: Row(
                  children: [
                    CircleAvatar(radius: 20, backgroundColor: AppTheme.elevatedCard, child: Icon(Icons.person_rounded, color: AppTheme.neonCyan)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(auth.currentUserName ?? '', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 15), overflow: TextOverflow.ellipsis),
                          Text(auth.currentUserEmail ?? '', style: TextStyle(color: AppTheme.textMuted, fontSize: 12), overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const _SectionLabel('Profile'),
              tile(
                Icons.badge_rounded,
                'Rider profile & ICE contacts',
                '${auth.vehicleType?.isNotEmpty == true ? auth.vehicleType : 'Motorcycle'} · ${auth.emergencyContact?.isNotEmpty == true ? 'ICE active' : 'No ICE contact configured'}',
                () => Navigator.push(context, MaterialPageRoute(builder: (_) => const EditProfileScreen())),
                color: AppTheme.hyperAmber,
              ),
              const SizedBox(height: 8),
              const _SectionLabel('Appearance'),
              tile(theme.isLight ? Icons.light_mode_rounded : Icons.dark_mode_rounded, 'Theme', AppearanceSheet.summary(theme),
                  () => AppearanceSheet.show(context)),
              const SizedBox(height: 8),
              const _SectionLabel('Security'),
              tile(Icons.password_rounded, 'Change password', 'Use at least 8 characters.',
                  () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ChangePasswordScreen()))),
              tile(Icons.verified_user_rounded, 'Permissions', 'Location, microphone, notifications and battery settings.',
                  () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PermissionsScreen()))),
              const SizedBox(height: 8),
              const _SectionLabel('Help'),
              tile(Icons.bug_report_rounded, 'Report a problem', 'Send a bug report or suggestion. We reply by e-mail.',
                  () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ReportProblemScreen()))),
              tile(Icons.privacy_tip_rounded, 'Privacy policy', privacyUrl, () => _open(context, privacyUrl)),
              tile(Icons.gavel_rounded, 'Terms of use', termsUrl, () => _open(context, termsUrl)),
              const SizedBox(height: 8),
              const _SectionLabel('Account'),
              tile(Icons.logout_rounded, 'Sign out', 'You can sign back in any time.', () async {
                await auth.logout();
                if (context.mounted) {
                  Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const AccessGateScreen()), (_) => false);
                }
              }, color: AppTheme.textSecondary),
              tile(Icons.delete_forever_rounded, 'Delete my account', 'Removes your account, profile and ride history permanently.',
                  () => _confirmDelete(context), color: AppTheme.laserRed),
              const SizedBox(height: 20),
              Center(
                child: Text(
                  'CoRoute ${MetaService.currentVersion} (build ${MetaService.currentBuild})${support.isNotEmpty ? ' · $support' : ''}',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          backgroundColor: AppTheme.slateCard,
          title: Text('Delete your account?', style: TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This permanently removes your account, profile, convoy memberships and ride history. It cannot be undone.\n\nType DELETE to confirm.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                style: TextStyle(color: AppTheme.textPrimary),
                decoration: InputDecoration(filled: true, fillColor: AppTheme.elevatedCard, border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: AppTheme.textMuted))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.laserRed, foregroundColor: Colors.white),
              onPressed: ctrl.text.trim() == 'DELETE'
                  ? () async {
                      Navigator.pop(ctx);
                      final res = await context.read<AuthService>().deleteAccount();
                      if (!context.mounted) return;
                      if (res['success'] == true) {
                        Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const AccessGateScreen()), (_) => false);
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Your account has been deleted.')));
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(res['error']?.toString() ?? 'Could not delete the account.'), backgroundColor: AppTheme.laserRed));
                      }
                    }
                  : null,
              child: const Text('Delete permanently'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 4),
        child: Text(text.toUpperCase(), style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Thanks. Your report was sent.'), backgroundColor: AppTheme.emeraldSafe));
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
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                'What happened, what you expected, and which screen you were on. Your e-mail, app version and phone platform are attached so we can reply.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 14),
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
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  counterStyle: TextStyle(color: AppTheme.textMuted),
                ),
              ),
              if (_error != null) Text(_error!, style: TextStyle(color: AppTheme.laserRed, fontSize: 13)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _busy ? null : _send,
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.neonCyan, foregroundColor: Colors.black, minimumSize: const Size.fromHeight(48)),
                child: _busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                    : const Text('Send report'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
