import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../auth/access_gate_screen.dart';

/// Three short pages shown once, on the first launch, before sign-in.
/// Every page can be skipped. One idea per page: an icon, a title, one line.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  /// SharedPreferences flag: true once the pages were seen or skipped.
  static const String doneKey = 'coroute_onboarding_done';

  static const List<OnboardingPage> pages = [
    OnboardingPage(
      icon: Icons.groups_outlined,
      title: 'Ride together',
      line: 'Your whole group on one map.',
    ),
    OnboardingPage(
      icon: Icons.headset_mic_outlined,
      title: 'Stay connected',
      line: 'Talk on the move. See who stopped.',
    ),
    OnboardingPage(
      icon: Icons.health_and_safety_outlined,
      title: 'Reach safely',
      line: 'Hold SOS to alert your group and family.',
    ),
  ];

  /// True when the pages should not be shown: already seen, or this phone
  /// was used with an account before (an update from an older version).
  static Future<bool> isDone() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(doneKey) ?? false) return true;
      return prefs.containsKey(AppConstants.keyUserId);
    } catch (_) {
      return true; // never block sign-in because of storage
    }
  }

  static Future<void> markDone() async {
    try {
      await (await SharedPreferences.getInstance()).setBool(doneKey, true);
    } catch (_) {}
  }

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

/// One onboarding page: a Material icon, a title and one line.
class OnboardingPage {
  final IconData icon;
  final String title;
  final String line;
  const OnboardingPage({required this.icon, required this.title, required this.line});
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;
  bool _leaving = false;
  bool _isTransitioning = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    if (_leaving) return;
    _leaving = true;
    await OnboardingScreen.markDone();
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const AccessGateScreen()));
  }

  void _next() {
    if (_isTransitioning || _leaving) return;
    if (_page >= OnboardingScreen.pages.length - 1) {
      _finish();
    } else {
      _isTransitioning = true;
      _controller.nextPage(duration: Motion.screen, curve: Motion.curve).then((_) {
        if (mounted) setState(() => _isTransitioning = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const pages = OnboardingScreen.pages;
    final last = _page == pages.length - 1;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              children: [
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: TextButton(
                      onPressed: _finish,
                      style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                      child: const Text('Skip'),
                    ),
                  ),
                ),
                Expanded(
                  child: PageView.builder(
                    controller: _controller,
                    itemCount: pages.length,
                    onPageChanged: (i) => setState(() => _page = i),
                    itemBuilder: (_, i) => _PageBody(page: pages[i]),
                  ),
                ),
                Semantics(
                  label: 'Page ${_page + 1} of ${pages.length}',
                  child: ExcludeSemantics(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < pages.length; i++)
                          Container(
                            margin: const EdgeInsets.symmetric(horizontal: Space.s4),
                            width: i == _page ? 20 : 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: i == _page ? AppTheme.primary : AppTheme.border2,
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, Space.s24, 20, 28),
                  child: DsButton(
                    label: last ? 'Get started' : 'Next',
                    onPressed: _next,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PageBody extends StatelessWidget {
  final OnboardingPage page;
  const _PageBody({required this.page});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: Space.s16),
        physics: const BouncingScrollPhysics(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // One outline icon on a soft teal circle.
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(color: AppTheme.primarySoft, shape: BoxShape.circle),
              child: Icon(page.icon, size: 44, color: AppTheme.primary),
            ),
            const SizedBox(height: Space.s32),
            Semantics(
              header: true,
              child: Text(page.title, textAlign: TextAlign.center, style: AppText.headline),
            ),
            const SizedBox(height: Space.s8),
            Text(
              page.line,
              textAlign: TextAlign.center,
              style: AppText.body.copyWith(color: AppTheme.textMuted, fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }
}
