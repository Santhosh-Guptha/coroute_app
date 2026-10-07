import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../core/widgets/devmonks_branding.dart';
import '../../data/services/auth_service.dart';
import '../account/change_password_screen.dart';
import '../admin/master_admin_dashboard.dart';
import '../auth/access_gate_screen.dart';
import '../onboarding/onboarding_screen.dart';
import '../rider/rider_home_screen.dart';

/// A static logo while the saved session loads. No animation, no polling,
/// no minimum display time: it moves on as soon as the account is known.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _navigateToNext();
  }

  /// Completes when [auth] has finished loading the saved session.
  static Future<void> _authReady(AuthService auth) {
    if (!auth.isLoading) return Future<void>.value();
    final done = Completer<void>();
    void listener() {
      if (auth.isLoading || done.isCompleted) return;
      auth.removeListener(listener);
      done.complete();
    }

    auth.addListener(listener);
    return done.future;
  }

  Future<void> _navigateToNext() async {
    final auth = context.read<AuthService>();
    await _authReady(auth);
    if (!mounted) return;

    if (auth.isAuthenticated && auth.mustChangePassword) {
      final changed = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const ChangePasswordScreen(forced: true)));
      if (!mounted) return;
      if (changed != true) {
        await auth.logout();
        if (!mounted) return;
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const AccessGateScreen()));
        return;
      }
    }

    if (auth.isAuthenticated && auth.isMasterAdmin) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MasterAdminDashboard()));
    } else if (auth.isAuthenticated) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const RiderHomeScreen()));
    } else {
      final onboarded = await OnboardingScreen.isDone();
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => onboarded ? const AccessGateScreen() : const OnboardingScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(Space.s24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ClipRRect(
                        borderRadius: Radii.lgAll,
                        child: Image.asset(
                          'assets/branding/coroute_icon.png',
                          width: 88,
                          height: 88,
                          cacheWidth: 264,
                          filterQuality: FilterQuality.medium,
                        ),
                      ),
                      const SizedBox(height: Space.s24),
                      Text(
                        AppConstants.appName,
                        textAlign: TextAlign.center,
                        style: AppText.metric,
                      ),
                      const SizedBox(height: Space.s8),
                      Text(
                        AppConstants.appTagline,
                        textAlign: TextAlign.center,
                        style: AppText.label,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: Space.s24),
              child: DevMonksBadge(),
            ),
          ],
        ),
      ),
    );
  }
}
