import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/config/feature_gates.dart';
import '../../core/theme/app_theme.dart';
import '../../data/services/plan_subscription_service.dart';
import '../../data/services/subscription_reminders.dart';
import 'payment_checkout_modal.dart';
import 'subscription_expiry_banner.dart';

/// Screen allowing riders, captains, and tour operators to review entitlements
/// and upgrade their membership via Razorpay UPI.
class PlanSelectorScreen extends StatefulWidget {
  /// The plan to highlight for renewal (from an expiry banner or dialog); its
  /// card is marked "Renew" and the page opens scrolled to it.
  final SubscriptionTier? preselectTier;

  const PlanSelectorScreen({super.key, this.preselectTier});

  @override
  State<PlanSelectorScreen> createState() => _PlanSelectorScreenState();
}

class _PlanSelectorScreenState extends State<PlanSelectorScreen> {
  static final DateFormat _dateFmt = DateFormat('d MMM yyyy');

  /// "27 Nov 2026" for an epoch-ms validUntil (empty when the plan has no end date).
  static String formatValidUntil(int validUntilMs) =>
      validUntilMs > 0 ? _dateFmt.format(DateTime.fromMillisecondsSinceEpoch(validUntilMs)) : '';

  bool _isAnnual = false;
  final Map<SubscriptionTier, GlobalKey> _cardKeys = {
    for (final t in SubscriptionTier.values) t: GlobalKey(),
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final service = context.read<PlanSubscriptionService>();
        service.refreshPricingConfig().ignore();
        // Expiry reminders are local notifications: ask once, here (never at app start).
        if (service.isEntitledTo(service.entitledTier)) PlanReminderScheduler.requestPermissionOnce().ignore();
      }
    });
    final pre = widget.preselectTier;
    if (pre != null && pre != SubscriptionTier.community) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _cardKeys[pre]?.currentContext;
        if (ctx != null && mounted) {
          Scrollable.ensureVisible(ctx, alignment: 0.1, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final planService = context.watch<PlanSubscriptionService>();
    // What is unlocked now (the rider's choice, at or below what they hold).
    final currentTier = planService.effectiveTier;
    // What the server says they paid for (Community when nothing is active).
    final entitledTier = planService.entitledTier;
    final heldPlanActive = planService.isEntitledTo(entitledTier);
    final activeUntil = heldPlanActive ? formatValidUntil(planService.validUntil) : '';
    final plans = planService.plans;
    // Expired or ending: the plan to renew (never the free tier).
    final renewTier = widget.preselectTier ??
        ((planService.isExpired || planService.expiringSoon) ? planService.renewTier : null);
    final bestSaving = PlanSubscriptionService.bestAnnualSavingPercent();
    final pendingSummary = planService.pendingPlanSummary;

    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.card,
        elevation: 0,
        title: const Text(
          'Membership & Plans',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 14),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.accentText.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.accentText, width: 1.2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.verified_user_rounded, color: AppTheme.accentText, size: 14),
                const SizedBox(width: 5),
                Text(
                  FeatureGates.tierLabel(currentTier).toUpperCase(),
                  style: TextStyle(
                    color: AppTheme.accentText,
                    fontWeight: FontWeight.w900,
                    fontSize: 11,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              // Ending soon / ended: a tap only scrolls here, so no navigation.
              const SubscriptionExpiryBanner(opensPlanSelector: false),

              // Razorpay Security Trust Banner
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: AppTheme.card,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppTheme.accentText.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.shield_rounded, color: AppTheme.accentText, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                'Current Plan: ${FeatureGates.tierLabel(currentTier)}',
                                style: TextStyle(
                                  color: AppTheme.text,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Instant activation via Razorpay UPI · Zero gateway fees',
                            style: TextStyle(color: AppTheme.text2, fontSize: 11),
                          ),
                          if (pendingSummary != null) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(Icons.schedule_rounded, size: 13, color: AppTheme.accentText),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    'Next: $pendingSummary',
                                    style: TextStyle(color: AppTheme.accentText, fontSize: 11, fontWeight: FontWeight.w700),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Heading & Subtitle
              Text(
                'Choose Your Convoy Power',
                style: TextStyle(
                  color: AppTheme.text,
                  fontWeight: FontWeight.w900,
                  fontSize: 20,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Scale up to 40 riders per convoy, enable priority audio ducking, auto crash detection and fleet dispatch.',
                style: TextStyle(color: AppTheme.text2, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 14),

              // Monthly vs Annual Billing Toggle Switch
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: AppTheme.card,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          setState(() => _isAnnual = false);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            color: !_isAnnual ? AppTheme.accentText : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Center(
                            child: Text(
                              'Monthly Billing',
                              style: TextStyle(
                                color: !_isAnnual ? Colors.black : AppTheme.text2,
                                fontWeight: FontWeight.w800,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          setState(() => _isAnnual = true);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            color: _isAnnual ? AppTheme.accentText : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                bestSaving > 0 ? 'Annual (save up to $bestSaving%)' : 'Annual Billing',
                                style: TextStyle(
                                  color: _isAnnual ? Colors.black : AppTheme.text2,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Plan Cards
              for (final plan in plans) ...[
                _PlanCard(
                  key: _cardKeys[plan.tier],
                  plan: plan,
                  isAnnual: _isAnnual,
                  isActive: plan.tier == currentTier,
                  monthlyAmount: PlanSubscriptionService.priceOf(plan.tier, annual: false),
                  annualAmount: PlanSubscriptionService.priceOf(plan.tier, annual: true),
                  changeNote: plan.tier == currentTier ? null : planService.planChangeNote(plan.tier),
                  isPending: planService.pendingTier == plan.tier,
                  // The paid plan the rider holds (shown with its end date; free to switch back to).
                  isHeld: heldPlanActive && plan.tier == entitledTier,
                  activeUntil: heldPlanActive && plan.tier == entitledTier ? activeUntil : '',
                  isRenewal: renewTier != null &&
                      plan.tier == renewTier &&
                      plan.tier != currentTier &&
                      !(heldPlanActive && plan.tier == entitledTier),
                  onSelect: () async {
                    if (plan.tier == currentTier) return;

                    if (plan.tier == SubscriptionTier.community) {
                      // Dropping to Community never gives a paid plan up: the entitlement
                      // (validUntil) is kept and the rider can switch back for free.
                      if (heldPlanActive) {
                        final ok = await _confirmSwitchToCommunity(
                          context,
                          planName: FeatureGates.tierLabel(entitledTier),
                          until: activeUntil,
                        );
                        if (ok != true || !context.mounted) return;
                      }
                      HapticFeedback.heavyImpact();
                      await planService.selectTier(SubscriptionTier.community);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            duration: const Duration(seconds: 3),
                            content: Text(
                              heldPlanActive
                                  ? 'Switched to Community Rider. Your ${FeatureGates.tierLabel(entitledTier)} stays valid until $activeUntil.'
                                  : 'Switched to Community Rider Plan (Free Forever).',
                            ),
                          ),
                        );
                      }
                      return;
                    }

                    // A cheaper paid plan under a higher one that is still active: use it now
                    // for free (it is included), or buy it to start when the current plan ends.
                    var buyQueued = false;
                    if (planService.isQueuedDowngrade(plan.tier) && planService.pendingTier != plan.tier) {
                      final choice = await _askDowngrade(
                        context,
                        target: plan.name,
                        held: FeatureGates.tierLabel(entitledTier),
                        until: activeUntil,
                      );
                      if (choice == null || !context.mounted) return;
                      buyQueued = choice;
                    }

                    // A paid plan the rider already holds: just switch back to it, no payment.
                    if (!buyQueued && await planService.selectTier(plan.tier)) {
                      HapticFeedback.heavyImpact();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            duration: const Duration(seconds: 3),
                            content: Text('${plan.name} is active again (valid until $activeUntil).'),
                          ),
                        );
                      }
                      return;
                    }

                    // Above the entitlement: launch Razorpay UPI Checkout Bottom Sheet.
                    // The current plan stays in place until the payment is verified.
                    if (!context.mounted) return;
                    final upgraded = await PaymentCheckoutModal.show(
                      context,
                      plan: plan,
                      isAnnual: _isAnnual,
                    );

                    if (upgraded == true) {
                      // Re-read the server's subscriptionStatus so the card shows "Active until".
                      await planService.syncFromServer();
                      if (context.mounted) setState(() {});
                    }

                    if (upgraded == true && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          duration: const Duration(seconds: 3),
                          backgroundColor: AppTheme.card,
                          content: Row(
                            children: [
                              Icon(Icons.check_circle_rounded, color: AppTheme.accentText),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  planService.pendingTier == plan.tier && !planService.isEntitledTo(plan.tier)
                                      ? '${plan.name} booked. ${planService.pendingPlanSummary ?? ''}'.trim()
                                      : '${plan.name} Activated! Max ${plan.maxConvoySize} riders unlocked.',
                                  style: TextStyle(
                                    color: AppTheme.text,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                  },
                ),
                const SizedBox(height: 16),
              ],

              const SizedBox(height: 12),
              // Informative Footer
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.soft,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.border2),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.lock_rounded, color: AppTheme.accentText, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'All subscriptions are processed securely via Razorpay 100% UPI. Entitlements are verified cryptographically and unlocked automatically in real-time.',
                        style: TextStyle(color: AppTheme.text2, fontSize: 12, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 30),
            ],
          ),
        ),
      ),
    );
  }

  /// A cheaper paid plan while a higher one is active. Resolves false to use it
  /// now (included, no payment), true to buy it to start when [held] ends,
  /// null when dismissed.
  Future<bool?> _askDowngrade(
    BuildContext context, {
    required String target,
    required String held,
    required String until,
  }) {
    final when = until.isEmpty ? 'it ends' : 'it ends on $until';
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text('Switch to $target?', style: TextStyle(color: AppTheme.text, fontWeight: FontWeight.w800)),
        content: Text(
          '$target is included in your $held, so you can use it right now for free. '
          'To move to $target for good, buy it now: it starts when your $held ends${until.isEmpty ? '' : ' on $until'}.',
          style: TextStyle(color: AppTheme.text2, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Use it now (free)', style: TextStyle(color: AppTheme.text2)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.brand),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Buy, starts when $when', style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  /// "Switch to Community?" for a rider who holds a valid paid plan. Resolves true to switch.
  Future<bool?> _confirmSwitchToCommunity(
    BuildContext context, {
    required String planName,
    required String until,
  }) {
    final when = until.isEmpty ? 'its end date' : until;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(
          'Switch to Community?',
          style: TextStyle(color: AppTheme.text, fontWeight: FontWeight.w800),
        ),
        content: Text(
          'Your $planName stays valid until $when; you can switch back any time without paying.',
          style: TextStyle(color: AppTheme.text2, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Keep $planName', style: TextStyle(color: AppTheme.text2)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.brand),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Switch to Community', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final PlanDetails plan;
  final bool isAnnual;
  final bool isActive;

  /// A paid plan the rider holds (valid): "Active until"; switching to it is free.
  final bool isHeld;

  /// Formatted end date of the held plan ('' when none).
  final String activeUntil;

  /// The plan that ran out (or is about to): offered as "Renew" instead of "Upgrade".
  final bool isRenewal;
  final VoidCallback onSelect;

  /// Server prices (INR) used for the annual saving line.
  final num monthlyAmount;
  final num annualAmount;

  /// Upgrade credit or "starts when … ends" copy while another paid plan is held.
  final String? changeNote;

  /// Bought already and queued behind the current plan.
  final bool isPending;

  const _PlanCard({
    super.key,
    required this.plan,
    required this.isAnnual,
    required this.isActive,
    this.isHeld = false,
    this.activeUntil = '',
    this.isRenewal = false,
    required this.onSelect,
    this.monthlyAmount = 0,
    this.annualAmount = 0,
    this.changeNote,
    this.isPending = false,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = isActive || isHeld
        ? AppTheme.accentText
        : isRenewal
            ? AppTheme.warnText
            : (plan.isPopular ? AppTheme.accentText.withValues(alpha: 0.6) : AppTheme.border2);
    final price = isAnnual ? plan.annualPrice : plan.monthlyPrice;
    final saving = PlanSubscriptionService.annualSaving(monthlyAmount, annualAmount);
    final savingPct = PlanSubscriptionService.annualSavingPercent(monthlyAmount, annualAmount);
    final note = changeNote;

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: borderColor, width: (isActive || isHeld || isRenewal) ? 2.2 : 1.2),
        boxShadow: isActive
            ? [
                BoxShadow(
                  color: AppTheme.accentText.withValues(alpha: 0.25),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header: Name & Max Convoy Pill
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        plan.name,
                        style: TextStyle(
                          color: AppTheme.text,
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppTheme.soft,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppTheme.border2),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.two_wheeler_rounded, size: 14, color: AppTheme.accentText),
                          const SizedBox(width: 4),
                          Text(
                            'Max ${plan.maxConvoySize} bikes',
                            style: TextStyle(
                              color: AppTheme.text,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),

                // Tagline
                Text(
                  plan.tagline,
                  style: TextStyle(color: AppTheme.text2, fontSize: 12),
                ),
                const SizedBox(height: 12),

                // Price display
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      price,
                      style: TextStyle(
                        color: isActive ? AppTheme.accentText : AppTheme.text,
                        fontWeight: FontWeight.w900,
                        fontSize: 22,
                        letterSpacing: 0.2,
                      ),
                    ),
                    if (plan.tier != SubscriptionTier.community) ...[
                      const SizedBox(width: 6),
                      Text(
                        isAnnual ? '/ billed annually' : '/ month',
                        style: TextStyle(color: AppTheme.text2, fontSize: 11),
                      ),
                    ],
                  ],
                ),
                if (plan.tier != SubscriptionTier.community && saving > 0) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.savings_outlined, size: 14, color: isAnnual ? AppTheme.accentText : AppTheme.text2),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          isAnnual
                              ? 'Save ${PlanSubscriptionService.formatInr(saving)} a year ($savingPct% off 12 monthly payments)'
                              : 'Pay yearly and save $savingPct% (${PlanSubscriptionService.formatPlanPrice(annualAmount, isAnnual: true)})',
                          style: TextStyle(
                            color: isAnnual ? AppTheme.accentText : AppTheme.text2,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (isPending) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.schedule_rounded, size: 14, color: AppTheme.accentText),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Booked: starts when your current plan ends',
                          style: TextStyle(color: AppTheme.accentText, fontSize: 12, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ] else if (note != null && !isHeld) ...[
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline_rounded, size: 14, color: AppTheme.text2),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(note, style: TextStyle(color: AppTheme.text2, fontSize: 12, height: 1.3)),
                      ),
                    ],
                  ),
                ],
                if (isHeld && activeUntil.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.event_available_rounded, size: 14, color: AppTheme.accentText),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          isActive
                              ? 'Current plan \u2014 active until $activeUntil'
                              : 'Active until $activeUntil \u2014 switch back any time, no payment needed',
                          style: TextStyle(
                            color: AppTheme.accentText,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 14),

                Divider(height: 1, color: AppTheme.border2),
                const SizedBox(height: 12),

                // Feature List
                for (final feat in plan.features) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          feat.isHighlight ? Icons.star_rounded : Icons.check_circle_outline_rounded,
                          color: feat.isHighlight ? AppTheme.accentText : AppTheme.muted,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: RichText(
                            text: TextSpan(
                              children: [
                                TextSpan(
                                  text: '${feat.title}: ',
                                  style: TextStyle(
                                    color: feat.isHighlight ? AppTheme.accentText : AppTheme.text,
                                    fontWeight: feat.isHighlight ? FontWeight.w800 : FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                                TextSpan(
                                  text: feat.description,
                                  style: TextStyle(
                                    color: AppTheme.text2,
                                    fontSize: 12,
                                    height: 1.3,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 10),

                // Action Button (56dp glove-friendly target)
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: isActive ? AppTheme.soft : AppTheme.brand,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: isActive ? null : onSelect,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          isActive ? Icons.verified_rounded : Icons.flash_on_rounded,
                          color: isActive ? AppTheme.accentText : Colors.white,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          isActive
                              ? 'CURRENT PLAN ACTIVE'
                              : isHeld
                                  ? 'SWITCH BACK (NO PAYMENT)'
                                  : isRenewal
                                      ? 'RENEW VIA RAZORPAY UPI'
                                      : (plan.tier == SubscriptionTier.community
                                          ? 'SELECT COMMUNITY PLAN'
                                          : 'UPGRADE VIA RAZORPAY UPI'),
                          style: TextStyle(
                            color: isActive ? AppTheme.accentText : Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 13,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // "ACTIVE", "RENEW" or "POPULAR" Pill
          if (isRenewal && !isActive)
            Positioned(
              top: -10,
              right: 18,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.warnText,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(color: AppTheme.warnText.withValues(alpha: 0.4), blurRadius: 8),
                  ],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.autorenew_rounded, color: Colors.white, size: 12),
                    SizedBox(width: 4),
                    Text(
                      'RENEW THIS PLAN',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 10,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (isActive || isHeld)
            Positioned(
              top: -10,
              right: 18,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.accentText,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(color: AppTheme.accentText.withValues(alpha: 0.4), blurRadius: 8),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle_rounded, color: Colors.black, size: 12),
                    const SizedBox(width: 4),
                    Text(
                      isActive
                          ? 'ACTIVE PLAN'
                          : activeUntil.isEmpty
                              ? 'PAID \u00b7 ACTIVE'
                              : 'ACTIVE UNTIL ${activeUntil.toUpperCase()}',
                      style: const TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.w900,
                        fontSize: 10,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (plan.isPopular)
            Positioned(
              top: -10,
              right: 18,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.brand,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(color: AppTheme.brand.withValues(alpha: 0.4), blurRadius: 8),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.star_rounded, color: Colors.white, size: 12),
                    const SizedBox(width: 4),
                    const Text(
                      'MOST POPULAR',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 10,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
