import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/services/auth_service.dart';
import '../auth/access_gate_screen.dart';

/// What the rider chose in the sign-out dialog.
class SignOutChoice {
  const SignOutChoice({required this.everywhere, required this.keepEmergencyInfo});
  final bool everywhere;
  final bool keepEmergencyInfo;
}

/// 3.57 Profile › Account › Sign out (docs/features_355/sessions_and_security.md):
/// 1. a dialog: this phone or every device, and "Keep emergency info on this phone" (on by default: the emergency
///    contact and Medical ID stay on the lock screen, because SOS works without an account);
/// 2. the sign-out (server session revoked, push token removed, tokens and cached personal data wiped), or, during
///    a ride, SOS, crash countdown or pending emergency texts, a notice that it happens when the ride is over;
/// 3. the welcome / sign-in screen with the navigation stack cleared, so Back cannot return.
class SignOutFlow {
  SignOutFlow._();

  static const String title = 'Sign out?';
  static const String keepLabel = 'Keep emergency info on this phone';
  static const String keepHint = 'Your emergency contact and Medical ID stay on the lock screen. SOS and crash alerts work without an account.';
  static const String thisPhoneLabel = 'Sign out';
  static const String everywhereLabel = 'Sign out of all devices';

  /// The dialog. Null when cancelled.
  static Future<SignOutChoice?> ask(BuildContext context) {
    var keep = true;
    return showDialog<SignOutChoice>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('You can sign in again at any time with the same account.'),
              const SizedBox(height: 12),
              CheckboxListTile(
                key: const Key('signout_keep_emergency'),
                contentPadding: EdgeInsets.zero,
                value: keep,
                onChanged: (v) => setState(() => keep = v ?? true),
                title: const Text(keepLabel),
                subtitle: const Text(keepHint),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(
              key: const Key('signout_everywhere'),
              onPressed: () => Navigator.pop(ctx, SignOutChoice(everywhere: true, keepEmergencyInfo: keep)),
              child: const Text(everywhereLabel),
            ),
            FilledButton(
              key: const Key('signout_this_phone'),
              onPressed: () => Navigator.pop(ctx, SignOutChoice(everywhere: false, keepEmergencyInfo: keep)),
              child: const Text(thisPhoneLabel),
            ),
          ],
        ),
      ),
    );
  }

  /// Replaces the whole navigation stack with the welcome / sign-in screen (Back cannot return).
  static Future<void> goToWelcome(NavigatorState nav, {WidgetBuilder? welcome}) {
    return nav.pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: welcome ?? (_) => const AccessGateScreen()),
      (_) => false,
    );
  }

  /// The whole flow from the Sign out row.
  static Future<void> run(BuildContext context, AuthService auth, {WidgetBuilder? welcome}) async {
    final choice = await ask(context);
    if (choice == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    final res = await auth.signOut(everywhere: choice.everywhere, keepEmergencyInfo: choice.keepEmergencyInfo);
    if (res['success'] == true) {
      await goToWelcome(nav, welcome: welcome);
      messenger.clearSnackBars();
      messenger.showSnackBar(SnackBar(content: Text(choice.everywhere ? 'Signed out of all devices.' : 'You are signed out.')));
      return;
    }
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(
      backgroundColor: res['deferred'] == true ? AppTheme.warning : null,
      duration: const Duration(seconds: 6),
      content: Text(res['deferred'] == true
          ? '${res['error']} You will be signed out when the ride is over.'
          : (res['error']?.toString() ?? 'Could not sign out. Check your connection and try again.')),
    ));
  }
}
