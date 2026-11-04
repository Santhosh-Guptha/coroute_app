import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/membership_model.dart';

/// Stage 3: Payment Success Screen.
///
/// Shown immediately after the backend server cryptographically verifies payment
/// and activates the rider's membership.
class PaymentSuccessScreen extends StatelessWidget {
  final UserMembership membership;
  final String transactionReference;
  final int amountPaidInRupees;
  final bool isTripCreationFlow;

  static final DateFormat _dateFormat = DateFormat('MMMM d, yyyy');

  const PaymentSuccessScreen({
    super.key,
    required this.membership,
    required this.transactionReference,
    required this.amountPaidInRupees,
    this.isTripCreationFlow = false,
  });

  @override
  Widget build(BuildContext context) {
    final validUntilDate = membership.validUntil > 0
        ? _dateFormat.format(DateTime.fromMillisecondsSinceEpoch(membership.validUntil))
        : 'Permanent';

    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        centerTitle: true,
        title: Text(
          'Confirmation',
          style: AppText.headline.copyWith(fontSize: 16),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 580),
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              physics: const BouncingScrollPhysics(),
              children: [
                const SizedBox(height: 10),

                // Success badge
                Center(
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      color: Colors.greenAccent.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.8), width: 2),
                    ),
                    child: const Icon(
                      Icons.check_circle_rounded,
                      color: Colors.greenAccent,
                      size: 44,
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // Membership Activated Message
                Center(
                  child: Text(
                    'Membership Activated!',
                    textAlign: TextAlign.center,
                    style: AppText.headline.copyWith(fontSize: 24, fontWeight: FontWeight.w900),
                  ),
                ),
                const SizedBox(height: 6),
                Center(
                  child: Text(
                    'Your CoRoute membership is active and verified by the gateway.',
                    textAlign: TextAlign.center,
                    style: AppText.caption.copyWith(fontSize: 13, color: AppTheme.text2),
                  ),
                ),
                const SizedBox(height: 24),

                // Transaction summary card
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: AppTheme.card,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppTheme.border, width: 1.5),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              membership.name,
                              style: AppText.title.copyWith(fontSize: 17, fontWeight: FontWeight.w800),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: AppTheme.brand.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: AppTheme.brand),
                            ),
                            child: Text(
                              '${membership.capacity} ${membership.capacity == 1 ? 'Rider' : 'Riders'}',
                              style: TextStyle(
                                color: AppTheme.brand,
                                fontWeight: FontWeight.w800,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Divider(height: 1),
                      const SizedBox(height: 12),

                      _infoRow('Amount Paid', amountPaidInRupees == 0 ? '₹0.00 (Introductory Offer)' : '₹$amountPaidInRupees.00'),
                      const SizedBox(height: 8),
                      _infoRow('Transaction Ref', transactionReference.length > 20 ? '${transactionReference.substring(0, 18)}...' : transactionReference),
                      const SizedBox(height: 8),
                      _infoRow('Valid Until', validUntilDate),
                      const SizedBox(height: 8),
                      _infoRow('Status', 'Active · Server Verified', valueColor: Colors.greenAccent),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Features Included in Activated Membership (from backend config)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.soft,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Included in Your Membership',
                        style: AppText.overline.copyWith(color: AppTheme.accentText, letterSpacing: 1),
                      ),
                      const SizedBox(height: 12),
                      _featureRow(Icons.emergency_rounded, 'Continuous Impact Crash Detection & Emergency SOS'),
                      const SizedBox(height: 8),
                      _featureRow(Icons.map_rounded, 'Full Corridor Offline Maps (2.5 km lateral corridor)'),
                      const SizedBox(height: 8),
                      _featureRow(Icons.navigation_rounded, 'High-Precision Turn-by-Turn Rider Navigation'),
                      const SizedBox(height: 8),
                      _featureRow(Icons.speed_rounded, 'Real-time Live Telemetry & Speed Monitoring'),
                      if (membership.capacity > 1) ...[
                        const SizedBox(height: 8),
                        _featureRow(Icons.group_rounded, 'Convoy Ride Hosting for up to ${membership.capacity} bikes'),
                        const SizedBox(height: 8),
                        _featureRow(Icons.mic_rounded, 'Tactical PTT Voice Intercom & Regroup Dispatch'),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 28),

                // Primary button: Continue Creating Your Trip
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    minimumSize: const Size.fromHeight(54),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: () {
                    Navigator.pop(context, true);
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isTripCreationFlow ? Icons.arrow_forward_rounded : Icons.check_rounded,
                        color: Colors.black,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          isTripCreationFlow ? 'Continue Creating Your Trip' : 'Back to Dashboard',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value, {Color? valueColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: AppText.caption),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: valueColor ?? AppTheme.text,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }

  Widget _featureRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Colors.greenAccent),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: AppText.body.copyWith(fontSize: 13)),
        ),
      ],
    );
  }
}
