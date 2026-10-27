import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/theme/app_theme.dart';
import '../../data/services/plan_subscription_service.dart';

/// Production-ready Razorpay UPI-Only Checkout Bottom Sheet.
class PaymentCheckoutModal extends StatefulWidget {
  final PlanDetails plan;
  final bool isAnnual;

  const PaymentCheckoutModal({
    super.key,
    required this.plan,
    this.isAnnual = false,
  });

  static Future<bool?> show(
    BuildContext context, {
    required PlanDetails plan,
    bool isAnnual = false,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PaymentCheckoutModal(plan: plan, isAnnual: isAnnual),
    );
  }

  @override
  State<PaymentCheckoutModal> createState() => _PaymentCheckoutModalState();
}

class _PaymentCheckoutModalState extends State<PaymentCheckoutModal> {
  final TextEditingController _utrController = TextEditingController();
  bool _isLoading = false;
  bool _isSuccess = false;
  String? _errorMessage;
  Map<String, dynamic>? _orderData;

  @override
  void initState() {
    super.initState();
    _initOrder();
  }

  @override
  void dispose() {
    _utrController.dispose();
    super.dispose();
  }

  Future<void> _initOrder() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final service = context.read<PlanSubscriptionService>();
      final order = await service.createOrder(
        widget.plan.tier,
        annual: widget.isAnnual,
      );
      if (mounted) {
        setState(() {
          _orderData = order;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Could not initialize order: ${e.toString()}';
        });
      }
    }
  }

  Future<void> _launchUpiIntent() async {
    final upiUri = _orderData?['upiUri']?.toString();
    if (upiUri == null) {
      setState(() => _errorMessage = 'Order not initialized.');
      return;
    }

    try {
      final uri = Uri.parse(upiUri);
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) {
        setState(() {
          _errorMessage =
              'No native UPI app found. Please copy the UPI ID below to pay from any banking app.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = 'Error launching UPI app: $e');
      }
    }
  }

  Future<void> _verifyPayment() async {
    final orderId = _orderData?['orderId']?.toString();
    if (orderId == null) {
      setState(() => _errorMessage = 'Order reference missing.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final service = context.read<PlanSubscriptionService>();
      final res = await service.verifyPayment(
        orderId: orderId,
        tier: widget.plan.tier,
        annual: widget.isAnnual,
        utr: _utrController.text.trim(),
        paymentId: 'pay_upi_${DateTime.now().millisecondsSinceEpoch}',
      );

      if (res['success'] == true) {
        HapticFeedback.heavyImpact();
        if (mounted) {
          setState(() {
            _isLoading = false;
            _isSuccess = true;
          });
          await Future.delayed(const Duration(milliseconds: 1400));
          if (mounted) Navigator.of(context).pop(true);
        }
      } else {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _errorMessage = res['error']?.toString() ?? 'Verification failed';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final priceLabel = widget.isAnnual ? widget.plan.annualPrice : widget.plan.monthlyPrice;
    final vpa = _orderData?['upiVpa']?.toString() ?? 'coroute@upi';
    final amount = _orderData?['amount']?.toString() ??
        (widget.isAnnual ? widget.plan.annualPrice : widget.plan.monthlyPrice);

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 14,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          if (_isSuccess) ...[
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppTheme.accentText.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.check_circle_rounded,
                color: AppTheme.accentText,
                size: 64,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '${widget.plan.name} Activated!',
              style: TextStyle(
                color: AppTheme.text,
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Entitlements unlocked instantly across all devices.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.text2, fontSize: 13),
            ),
            const SizedBox(height: 32),
          ] else ...[
            // Razorpay Security Trust Badge
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.brand.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.brand.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.security_rounded, color: AppTheme.brand, size: 14),
                      const SizedBox(width: 6),
                      Text(
                        'Razorpay Secure · 100% UPI',
                        style: TextStyle(
                          color: AppTheme.brand,
                          fontWeight: FontWeight.w800,
                          fontSize: 11,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Plan Title & Price
            Text(
              'Upgrade to ${widget.plan.name}',
              style: TextStyle(
                color: AppTheme.text,
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              priceLabel,
              style: TextStyle(
                color: AppTheme.accentText,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 16),

            // Error Message (if any)
            if (_errorMessage != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.sos.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.warnText.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded, color: AppTheme.warnText, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(color: AppTheme.warnText, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
            ],

            // UPI Apps Direct Launcher
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.bg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'PAY DIRECTLY VIA UPI APPS',
                    style: TextStyle(
                      color: AppTheme.text2,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.brand,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _isLoading ? null : () => _launchUpiIntent(),
                      icon: const Icon(Icons.account_balance_wallet_rounded, size: 20, color: Colors.white),
                      label: Text(
                        'Open Google Pay / PhonePe / Paytm (₹$amount)',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Or Copy UPI ID & Enter Bank UTR
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.bg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'OR PAY TO OFFICIAL UPI ID',
                        style: TextStyle(
                          color: AppTheme.text2,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6,
                        ),
                      ),
                      InkWell(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: vpa));
                          HapticFeedback.selectionClick();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              duration: Duration(seconds: 2),
                              content: Text('UPI ID copied to clipboard'),
                            ),
                          );
                        },
                        child: Row(
                          children: [
                            Icon(Icons.copy_rounded, color: AppTheme.accentText, size: 14),
                            const SizedBox(width: 4),
                            Text(
                              'Copy',
                              style: TextStyle(
                                color: AppTheme.accentText,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.card,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.border),
                    ),
                    child: Text(
                      vpa,
                      style: TextStyle(
                        color: AppTheme.text,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _utrController,
                    keyboardType: TextInputType.number,
                    style: TextStyle(color: AppTheme.text, fontSize: 13),
                    decoration: InputDecoration(
                      labelText: '12-Digit Bank UTR / Ref No. (Optional)',
                      labelStyle: TextStyle(color: AppTheme.text2, fontSize: 12),
                      hintText: 'e.g. 429810238492',
                      hintStyle: TextStyle(color: AppTheme.text2.withValues(alpha: 0.5), fontSize: 12),
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),

            // Confirm & Activate Button
            SizedBox(
              width: double.infinity,
              height: 54,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.accentText,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: _isLoading ? null : _verifyPayment,
                child: _isLoading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black),
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.verified_user_rounded, color: Colors.black, size: 20),
                          const SizedBox(width: 8),
                          const Text(
                            'Verify & Activate Plan Instantly',
                            style: TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.w900,
                              fontSize: 14,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
