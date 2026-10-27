import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/config/feature_gates.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/plan_subscription_service.dart';
import 'plan_selector_screen.dart';

/// Sits above the navigator (MaterialApp.builder) and turns pending plan
/// notices from [PlanSubscriptionService] into UI: a snackbar when the plan
/// is about to end (once per 7/3/1-day step) and a dialog with a Renew button
/// when it has ended. Shows nothing itself; does nothing without the service.
class SubscriptionNoticeHost extends StatefulWidget {
  final Widget child;

  /// The app's navigator (the host sits above it, so it cannot look it up).
  final GlobalKey<NavigatorState>? navigatorKey;

  const SubscriptionNoticeHost({super.key, required this.child, this.navigatorKey});

  @override
  State<SubscriptionNoticeHost> createState() => _SubscriptionNoticeHostState();
}

class _SubscriptionNoticeHostState extends State<SubscriptionNoticeHost> {
  PlanSubscriptionService? _plan;
  bool _dialogOpen = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final plan = Provider.of<PlanSubscriptionService?>(context, listen: false);
    if (!identical(plan, _plan)) {
      _plan?.removeListener(_sync);
      _plan = plan;
      _plan?.addListener(_sync);
      WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
    }
  }

  @override
  void dispose() {
    _plan?.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    if (!mounted) return;
    final plan = _plan;
    if (plan == null) return;
    final nav = widget.navigatorKey?.currentState;
    final navContext = widget.navigatorKey?.currentContext;
    if (nav == null || navContext == null) {
      // Navigator not attached yet; try again on the next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sync();
      });
      return;
    }

    final expired = plan.expiredNotice;
    if (expired != null && !_dialogOpen) {
      plan.consumeExpiredNotice();
      _showExpiredDialog(navContext, nav, expired);
      return;
    }

    final expiring = plan.expiringNotice;
    if (expiring != null) {
      plan.consumeExpiringNotice();
      _showExpiringSnackBar(navContext, nav, expiring);
    }
  }

  void _openPlanSelector(NavigatorState nav, SubscriptionTier tier) {
    nav.push(MaterialPageRoute<void>(builder: (_) => PlanSelectorScreen(preselectTier: tier)));
  }

  void _showExpiringSnackBar(BuildContext ctx, NavigatorState nav, SubscriptionExpiringNotice n) {
    final messenger = ScaffoldMessenger.maybeOf(ctx);
    if (messenger == null) return;
    final name = FeatureGates.tierLabel(n.tier);
    final when = n.daysRemaining <= 0
        ? 'today'
        : n.daysRemaining == 1
            ? 'in 1 day'
            : 'in ${n.daysRemaining} days';
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.card,
        content: Row(
          children: [
            Icon(Icons.timer_outlined, color: AppTheme.warnText),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Your $name ends $when — renew to keep ${PlanSubscriptionService.keyFeatureSummary(n.tier)}.',
                style: TextStyle(color: AppTheme.text, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'RENEW',
          textColor: AppTheme.accentText,
          onPressed: () => _openPlanSelector(nav, n.tier),
        ),
      ),
    );
  }

  Future<void> _showExpiredDialog(BuildContext ctx, NavigatorState nav, SubscriptionExpiredNotice n) async {
    _dialogOpen = true;
    final name = FeatureGates.tierLabel(n.previousTier);
    final features = PlanSubscriptionService.keyFeatureSummary(n.previousTier);
    try {
      final renew = await showDialog<bool>(
        context: ctx,
        builder: (dctx) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: AlertDialog(
              backgroundColor: AppTheme.card,
              shape: const RoundedRectangleBorder(borderRadius: Radii.lgAll),
              title: Row(
                children: [
                  Icon(Icons.lock_clock_rounded, color: AppTheme.warnText),
                  const SizedBox(width: 10),
                  Expanded(child: Text('Your $name has ended', style: AppText.title.copyWith(color: AppTheme.text))),
                ],
              ),
              content: Text(
                'You\'re on Community now. Renew to keep $features.',
                style: AppText.body.copyWith(color: AppTheme.text2),
              ),
              actionsPadding: const EdgeInsets.fromLTRB(Space.s16, 0, Space.s16, Space.s16),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dctx).pop(false),
                  style: TextButton.styleFrom(foregroundColor: AppTheme.textPrimary, minimumSize: const Size(64, 48)),
                  child: const Text('Not now', maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dctx).pop(true),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.neonCyan,
                    foregroundColor: Colors.black,
                    minimumSize: const Size(64, 48),
                    shape: const RoundedRectangleBorder(borderRadius: Radii.mdAll),
                  ),
                  child: const Text('Renew', maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
        ),
      );
      if (renew == true) _openPlanSelector(nav, n.previousTier);
    } finally {
      _dialogOpen = false;
      if (mounted) _sync(); // a warning may have queued up behind the dialog
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
