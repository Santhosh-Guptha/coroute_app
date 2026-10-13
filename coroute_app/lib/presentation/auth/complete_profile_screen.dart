import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/auth_service.dart';
import '../account/profile_form.dart';
import 'access_gate_screen.dart';

/// Safety details that must be filled in before riding with a group.
/// With [forced] (after a Google sign-in) the screen cannot be left except by
/// saving or signing out. It uses the same form as the profile editor.
class CompleteProfileScreen extends StatelessWidget {
  final bool forced;
  final bool isGoogleUser;

  const CompleteProfileScreen({
    super.key,
    this.forced = false,
    this.isGoogleUser = false,
  });

  Future<void> _signOut(BuildContext context) async {
    await context.read<AuthService>().logout();
    if (!context.mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const AccessGateScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !forced,
      child: Scaffold(
        backgroundColor: AppTheme.bg,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: DsScreenHeader(
                  title: 'Your safety details',
                  subtitle: 'Needed before riding with a group',
                  onBack: forced ? null : () => Navigator.maybePop(context),
                  trailing: forced
                      ? TextButton(
                          onPressed: () => _signOut(context),
                          style: TextButton.styleFrom(minimumSize: const Size(48, 44)),
                          child: const Text('Sign out'),
                        )
                      : null,
                ),
              ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 600),
                    child: ProfileForm(
                      saveLabel: 'Save and continue',
                      header: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: DsCard(
                          tinted: true,
                          borderColor: AppTheme.tint,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.health_and_safety_rounded, size: 22, color: AppTheme.accentText),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  isGoogleUser
                                      ? 'One more step. Your group needs a way to reach you and your family in an emergency.'
                                      : 'Your group needs a way to reach you and your family in an emergency.',
                                  style: AppText.body,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      onSaved: () => Navigator.of(context).pop(true),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
