import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/devmonks_branding.dart';
import '../../data/services/auth_service.dart';
import '../account/change_password_screen.dart';
import '../admin/master_admin_dashboard.dart';
import '../auth/access_gate_screen.dart';
import '../rider/rider_home_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _glowAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _glowAnimation = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _navigateToNext();
  }

  Future<void> _navigateToNext() async {
    final startTime = DateTime.now();
    final auth = context.read<AuthService>();

    // Guarantee that persistent auth session has finished loading
    while (auth.isLoading) {
      await Future.delayed(const Duration(milliseconds: 50));
    }

    // Ensure splash displays at least 700ms for visual comfort
    final elapsed = DateTime.now().difference(startTime).inMilliseconds;
    if (elapsed < 700) {
      await Future.delayed(Duration(milliseconds: 700 - elapsed));
    }

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
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const MasterAdminDashboard()),
      );
    } else if (auth.isAuthenticated) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const RiderHomeScreen()),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const AccessGateScreen()),
      );
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      body: Stack(
        children: [
          // Background ambient gradient
          Positioned(
            top: -100,
            left: -100,
            child: Container(
              width: 320,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.neonCyan.withOpacity(0.08),
              ),
            ),
          ),
          Positioned(
            bottom: -80,
            right: -80,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.devmonksPurple.withOpacity(0.08),
              ),
            ),
          ),

          // Center Logo and Pulse
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ScaleTransition(
                  scale: _glowAnimation,
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const RadialGradient(
                        colors: [AppTheme.slateCard, AppTheme.obsidianVoid],
                      ),
                      border: Border.all(color: AppTheme.neonCyan, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.neonCyan.withOpacity(0.4),
                          blurRadius: 28,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.navigation_rounded,
                      color: AppTheme.neonCyan,
                      size: 56,
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  AppConstants.appName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2.0,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  AppConstants.appTagline,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 36),
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(AppTheme.neonCyan),
                  ),
                ),
              ],
            ),
          ),

          // Bottom DevMonks Studio Branding
          const Positioned(
            bottom: 36,
            left: 0,
            right: 0,
            child: Center(
              child: DevMonksBadge(),
            ),
          ),
        ],
      ),
    );
  }
}
