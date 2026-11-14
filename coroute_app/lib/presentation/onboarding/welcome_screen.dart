import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/safety_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../auth/login_screen.dart';
import 'onboarding_screen.dart';
import 'package:coroute_app/core/ui/coroute_logo.dart';

/// v3.58 Welcome (first launch and after signing out): our mark, a two-line headline in CoRoute's voice, one line
/// with what keeps riders safe, then "Get started" (create account) and "I already have an account" (sign in).
/// "Emergency? Call 112" is always on it: help never waits for an account.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  static const String headline1 = 'Ride together.';
  static const String headline2 = 'Stay safe.';
  static const String valueLine = 'Crash detection, SOS that works without signal, live group tracking and helmet intercom. In one app.';
  static const String getStarted = 'Get started';
  static const String haveAccount = 'I already have an account';

  Future<void> _go(BuildContext context, {required bool register}) async {
    await OnboardingScreen.markDone();
    if (!context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LoginScreen(startInRegister: register)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: Stack(
        children: [
          // A calm teal wash at the top (our brand colour, low contrast), nothing else decorative.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.center,
                  colors: [AppTheme.primarySoft, AppTheme.bg],
                ),
              ),
            ),
          ),
          SafeArea(
            child: ContentWidth(
              maxWidth: 480,
              child: LayoutBuilder(
                builder: (context, box) => SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: box.maxHeight - 48),
                    child: IntrinsicHeight(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(height: Space.s32),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: const CoRouteAppIcon(size: 76, semanticLabel: null),
                          ),
                          const SizedBox(height: Space.s16),
                          const Align(alignment: Alignment.centerLeft, child: CoRouteWordmark(fontSize: 24)),
                          const SizedBox(height: Space.s32),
                          Semantics(
                            header: true,
                            label: '$headline1 $headline2',
                            child: ExcludeSemantics(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(headline1, style: AppText.headline.copyWith(fontSize: 38, height: 1.15, fontWeight: FontWeight.w700)),
                                  Text(headline2, style: AppText.headline.copyWith(fontSize: 38, height: 1.15, fontWeight: FontWeight.w700, color: AppTheme.accentText)),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: Space.s16),
                          Text(valueLine, style: AppText.body.copyWith(color: AppTheme.textMuted, fontSize: 16)),
                          const SizedBox(height: Space.s24),
                          const Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              InfoPill(icon: Icons.car_crash_outlined, text: 'Crash detection'),
                              InfoPill(icon: Icons.signal_cellular_off_outlined, text: 'SOS without signal'),
                              InfoPill(icon: Icons.headset_mic_outlined, text: 'Helmet intercom'),
                              InfoPill(icon: Icons.share_location_outlined, text: 'Live link for family'),
                            ],
                          ),
                          const Spacer(),
                          const SizedBox(height: Space.s32),
                          DsButton(key: const Key('welcome_get_started'), label: getStarted, icon: Icons.arrow_forward_rounded, onPressed: () => _go(context, register: true)),
                          const SizedBox(height: Space.s12),
                          DsButton(key: const Key('welcome_sign_in'), label: haveAccount, tone: DsButtonTone.outline, fontSize: 15, onPressed: () => _go(context, register: false)),
                          const SizedBox(height: Space.s8),
                          Center(
                            child: TextButton.icon(
                              key: const Key('welcome_call_112'),
                              onPressed: () => launchUrl(Uri(scheme: 'tel', path: SafetyConstants.emergencyNumber)),
                              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                              icon: Icon(Icons.emergency_outlined, color: AppTheme.sos),
                              label: Text('Emergency? Call ${SafetyConstants.emergencyNumber}', style: TextStyle(color: AppTheme.sos, fontWeight: FontWeight.w600)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
