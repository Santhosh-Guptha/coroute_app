import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/membership_model.dart';

/// Stage 1: Trip Creation Payment Alert Bottom Sheet.
///
/// Displayed when a rider configures a trip and proceeds toward the review stage
/// without an active, server-verified CoRoute membership.
///
/// Shows the plan's normal price. An offer is shown only when the caller passes one the
/// server advertises ([activeOfferCode] with a [discountPercent] above 0); no code is assumed.
class TripCreationPaymentAlertSheet extends StatefulWidget {
  final MembershipCategory category;
  final String? activeOfferCode;
  final int discountPercent;

  const TripCreationPaymentAlertSheet({
    super.key,
    required this.category,
    this.activeOfferCode,
    this.discountPercent = 0,
  });

  /// Shows the payment alert sheet and returns true if the user proceeds to payment,
  /// or false / null if the user chooses 'Maybe Later'.
  static Future<bool?> show(
    BuildContext context, {
    required MembershipCategory category,
    String? activeOfferCode,
    int discountPercent = 0,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => TripCreationPaymentAlertSheet(
        category: category,
        activeOfferCode: activeOfferCode,
        discountPercent: discountPercent,
      ),
    );
  }

  @override
  State<TripCreationPaymentAlertSheet> createState() => _TripCreationPaymentAlertSheetState();
}

class _TripCreationPaymentAlertSheetState extends State<TripCreationPaymentAlertSheet> {
  @override
  Widget build(BuildContext context) {
    final cat = widget.category;
    final basePrice = cat.priceRupees;
    final offerCode = widget.activeOfferCode?.trim() ?? '';
    final pct = widget.discountPercent.clamp(0, 100);
    final hasOffer = offerCode.isNotEmpty && pct > 0;
    final discountAmount = hasOffer ? (basePrice * (pct / 100)).round() : 0;
    final netAmount = (basePrice - discountAmount).clamp(0, 999999);

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: AppTheme.border, width: 1.5),
      ),
      padding: EdgeInsets.only(
        top: 20,
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.border2,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 18),

          // Header with safety badge
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppTheme.brand.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                  border: Border.all(color: AppTheme.brand, width: 1.5),
                ),
                child: Icon(Icons.shield_rounded, color: AppTheme.brand, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Membership Required',
                      style: AppText.headline.copyWith(fontSize: 18, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Activate membership to host & create trips',
                      style: AppText.caption.copyWith(color: AppTheme.accentText),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Explanation why payment is required
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.soft,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.border),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, color: AppTheme.accentText, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'You need an active plan to host group rides.',
                    style: AppText.body.copyWith(fontSize: 13, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Plan details card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  AppTheme.brand.withValues(alpha: 0.12),
                  AppTheme.card,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.brand.withValues(alpha: 0.4), width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        cat.name,
                        style: AppText.title.copyWith(fontSize: 16, fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppTheme.brand,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${cat.capacity} ${cat.capacity == 1 ? 'Rider' : 'Riders'}',
                        style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.w900,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Divider(height: 1),
                const SizedBox(height: 10),

                // Pricing details
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: Text('Monthly Plan', style: AppText.caption)),
                    const SizedBox(width: 8),
                    Text(
                      '₹$basePrice / month',
                      style: TextStyle(
                        color: AppTheme.text2,
                        decoration: hasOffer ? TextDecoration.lineThrough : null,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                if (hasOffer) ...[
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          'Offer ($offerCode)',
                          style: TextStyle(color: Colors.lightGreenAccent.shade400, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('-₹$discountAmount ($pct% OFF)', style: TextStyle(color: Colors.lightGreenAccent.shade400, fontSize: 12, fontWeight: FontWeight.w800)),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                const Divider(height: 1),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text('Payable Today', style: AppText.title.copyWith(fontSize: 14, fontWeight: FontWeight.w800)),
                    ),
                    Text(
                      netAmount == 0 ? '₹0.00 (Free)' : '₹$netAmount.00',
                      style: TextStyle(
                        color: netAmount == 0 ? Colors.lightGreenAccent.shade400 : AppTheme.brand,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Features included
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
              children: [
                _featureItem(Icons.emergency_rounded, 'Crash alerts and SOS'),
                const SizedBox(height: 8),
                _featureItem(Icons.map_rounded, 'Offline maps along your route'),
                const SizedBox(height: 8),
                _featureItem(Icons.group_rounded, 'Host group rides with Lead and Sweep'),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Action buttons: Proceed to Payment & Maybe Later
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.brand,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.payment_rounded, color: Colors.black, size: 18),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    netAmount == 0 ? 'Activate Free Introductory Offer' : 'Proceed to Payment (₹$netAmount)',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              side: BorderSide(color: AppTheme.border, width: 1.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'Maybe Later',
              style: TextStyle(color: AppTheme.text2, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    ),
  );
  }

  Widget _featureItem(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppTheme.accentText),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: AppText.body.copyWith(fontSize: 12)),
        ),
      ],
    );
  }
}
