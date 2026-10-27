import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/plan_subscription_service.dart';

/// Official Razorpay Checkout Modal for 100% UPI Payments.
///
/// Features:
/// 1. Direct native Razorpay Checkout sheet opening with `Razorpay.open(...)`.
/// 2. Strictly UPI-only instrument restriction (`method: { upi: true, card: false, ... }`).
/// 3. Native event listeners: `EVENT_PAYMENT_SUCCESS`, `EVENT_PAYMENT_ERROR`, `EVENT_EXTERNAL_WALLET`.
/// 4. Instant cryptographic signature verification with backend `/api/subscription/verify-payment`.
/// 5. Secondary fallback: direct UPI deep-link intent (`upi://pay`) and manual UTR submission.
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
  late Razorpay _razorpay;
  final TextEditingController _utrController = TextEditingController();
  final TextEditingController _couponController = TextEditingController();

  bool _isLoading = false;
  bool _isSuccess = false;
  String? _errorMessage;
  Map<String, dynamic>? _orderData;
  bool _showManualFallback = false;

  Map<String, dynamic>? _appliedCoupon;
  bool _isValidatingCoupon = false;
  String? _couponError;

  @override
  void initState() {
    super.initState();
    _razorpay = Razorpay();
    _razorpay.on(Razorpay.EVENT_PAYMENT_SUCCESS, _handlePaymentSuccess);
    _razorpay.on(Razorpay.EVENT_PAYMENT_ERROR, _handlePaymentError);
    _razorpay.on(Razorpay.EVENT_EXTERNAL_WALLET, _handleExternalWallet);

    _initOrder();
  }

  @override
  void dispose() {
    _razorpay.clear();
    _utrController.dispose();
    _couponController.dispose();
    super.dispose();
  }

  Future<void> _initOrder({String? couponCode}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final service = context.read<PlanSubscriptionService>();
      final order = await service.createOrder(
        widget.plan.tier,
        annual: widget.isAnnual,
        couponCode: couponCode,
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
          _errorMessage = 'Could not create order: ${e.toString()}';
        });
      }
    }
  }

  Future<void> _applyCoupon() async {
    final code = _couponController.text.trim().toUpperCase();
    if (code.isEmpty) {
      setState(() {
        _appliedCoupon = null;
        _couponError = null;
      });
      _initOrder();
      return;
    }

    setState(() {
      _isValidatingCoupon = true;
      _couponError = null;
    });

    try {
      final service = context.read<PlanSubscriptionService>();
      final res = await service.validateCoupon(
        code: code,
        tier: widget.plan.tier,
        annual: widget.isAnnual,
      );
      if (mounted) {
        if (res != null && res['valid'] == true) {
          setState(() {
            _appliedCoupon = res;
            _isValidatingCoupon = false;
            _couponError = null;
          });
          _initOrder(couponCode: code);
        } else {
          setState(() {
            _appliedCoupon = null;
            _isValidatingCoupon = false;
            _couponError = res?['error']?.toString() ?? 'Coupon invalid';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _appliedCoupon = null;
          _isValidatingCoupon = false;
          _couponError = 'Coupon check failed: $e';
        });
      }
    }
  }

  /// Claims and activates a 100% free pass coupon without gateway prompt.
  Future<void> _claimFreePass() async {
    final orderId = _orderData?['orderId']?.toString();
    if (orderId == null) {
      _initOrder(couponCode: _appliedCoupon?['code']?.toString());
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
        couponCode: _appliedCoupon?['code']?.toString(),
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
            _errorMessage = res['error']?.toString() ?? 'Failed to activate free pass';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Activation error: $e';
        });
      }
    }
  }

  /// Launches the official Razorpay Checkout SDK with UPI options.
  void _openRazorpayCheckout() {
    if (_orderData == null) {
      _initOrder();
      return;
    }

    setState(() {
      _errorMessage = null;
    });

    // The server sends the key id of the active mode (test or live).
    final keyId = _orderData?['razorpayOptions']?['key']?.toString() ??
        _orderData?['razorpayKeyId']?.toString();
    if (keyId == null || keyId.isEmpty) {
      setState(() => _errorMessage = 'Online payment is not configured. Please try again later.');
      return;
    }

    final orderId = _orderData?['orderId']?.toString() ?? '';
    int amountInPaise = _orderData?['amountInPaise'] is num
        ? (_orderData!['amountInPaise'] as num).toInt()
        : 0;
    if (amountInPaise == 0) {
      final rawPrice = widget.isAnnual ? widget.plan.annualPrice : widget.plan.monthlyPrice;
      final numeric = int.tryParse(rawPrice.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
      amountInPaise = numeric * 100;
    }

    final auth = context.read<AuthService?>();
    final userPhone = auth?.phone ?? '';
    final userEmail = auth?.currentUserEmail ?? '';
    final userName = auth?.currentUserName ?? '';
    final userId = auth?.currentUserId ?? '';

    // Compile options strictly restricted to UPI
    final options = <String, dynamic>{
      'key': keyId,
      'amount': amountInPaise,
      'name': 'CoRoute Motorcycle Safety',
      'description': '${widget.plan.name} (${widget.isAnnual ? 'Annual' : 'Monthly'})',
      'order_id': orderId,
      'prefill': {
        'contact': userPhone,
        'email': userEmail,
        'name': userName,
      },
      'notes': {
        'userId': userId,
        'planTier': widget.plan.tier.name,
        'billingCycle': widget.isAnnual ? 'annual' : 'monthly',
      },
      'method': {
        'upi': true,
        'card': false,
        'netbanking': false,
        'wallet': false,
        'emi': false,
      },
      'theme': {
        'color': '#FF5722',
      },
    };

    try {
      _razorpay.open(options);
    } catch (e) {
      setState(() {
        _errorMessage = 'Razorpay SDK error: $e';
        _showManualFallback = true;
      });
    }
  }

  /// Automated callback upon successful UPI payment in Razorpay SDK.
  Future<void> _handlePaymentSuccess(PaymentSuccessResponse response) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final orderId = response.orderId ?? _orderData?['orderId']?.toString() ?? '';
    final paymentId = response.paymentId ?? '';
    final signature = response.signature ?? '';

    try {
      final service = context.read<PlanSubscriptionService>();
      final res = await service.verifyPayment(
        orderId: orderId,
        tier: widget.plan.tier,
        annual: widget.isAnnual,
        paymentId: paymentId,
        signature: signature,
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
          _errorMessage = 'Verification error: $e';
        });
      }
    }
  }

  void _handlePaymentError(PaymentFailureResponse response) {
    if (mounted) {
      setState(() {
        _isLoading = false;
        if (response.code == Razorpay.PAYMENT_CANCELLED) {
          _errorMessage = 'Payment cancelled by user.';
        } else {
          _errorMessage = response.message ?? 'Payment failed (Code ${response.code})';
        }
      });
    }
  }

  void _handleExternalWallet(ExternalWalletResponse response) {
    if (mounted) {
      setState(() {
        _errorMessage = 'Selected external wallet: ${response.walletName}';
      });
    }
  }

  /// Fallback: Direct native UPI deep-link intent.
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

  /// Fallback: Manual UTR verification.
  Future<void> _verifyManualUtr() async {
    final orderId = _orderData?['orderId']?.toString();
    if (orderId == null) {
      setState(() => _errorMessage = 'Order reference missing.');
      return;
    }

    final utrText = _utrController.text.trim();
    if (utrText.length < 8) {
      setState(() => _errorMessage = 'Please enter a valid 12-digit UPI UTR reference.');
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
        utr: utrText,
      );

      // A UTR is only a claim: the plan is activated once the payment is
      // confirmed by the CoRoute team (server answers 202 / pending).
      if (res['pending'] == true) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _errorMessage = res['message']?.toString() ??
                'UTR received. Your plan is activated once the payment is confirmed.';
          });
        }
        return;
      }

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
    final vpa = _orderData?['upiVpa']?.toString() ?? 'coroute.payments@okaxis';
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
                        'Razorpay 100% UPI Gateway',
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

            // Promotional Coupon Code Section
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppTheme.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _appliedCoupon != null ? AppTheme.accentText.withValues(alpha: 0.5) : AppTheme.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.local_offer_outlined, size: 16, color: AppTheme.accentText),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _couponController,
                          textCapitalization: TextCapitalization.characters,
                          style: TextStyle(color: AppTheme.text, fontSize: 13, fontWeight: FontWeight.w700),
                          decoration: InputDecoration(
                            hintText: 'COUPON CODE (e.g. WELCOME50, RIDERFREE)',
                            hintStyle: TextStyle(color: AppTheme.text2, fontSize: 11),
                            isDense: true,
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _isValidatingCoupon ? null : _applyCoupon,
                        child: _isValidatingCoupon
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : Text(_appliedCoupon != null ? 'Remove' : 'Apply', style: TextStyle(color: AppTheme.brand, fontWeight: FontWeight.w800, fontSize: 12)),
                      ),
                    ],
                  ),
                  if (_appliedCoupon != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Coupon ${_appliedCoupon!['code']} active: Saved ₹${_appliedCoupon!['discountAmount']}',
                      style: TextStyle(color: AppTheme.accentText, fontSize: 11, fontWeight: FontWeight.w700),
                    ),
                  ],
                  if (_couponError != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      _couponError!,
                      style: TextStyle(color: AppTheme.warnText, fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Hero: Primary Razorpay UPI or Free Pass Checkout Button
            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: (_appliedCoupon != null && _appliedCoupon!['isFree'] == true) ? AppTheme.accentText : AppTheme.brand,
                  elevation: 2,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: _isLoading ? null : () => (_appliedCoupon != null && _appliedCoupon!['isFree'] == true) ? _claimFreePass() : _openRazorpayCheckout(),
                child: _isLoading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon((_appliedCoupon != null && _appliedCoupon!['isFree'] == true) ? Icons.card_giftcard_rounded : Icons.flash_on_rounded, size: 22, color: Colors.white),
                          const SizedBox(width: 8),
                          Text(
                            (_appliedCoupon != null && _appliedCoupon!['isFree'] == true)
                                ? 'Claim Free Pass (${_appliedCoupon!['code']})'
                                : 'Pay ₹${_appliedCoupon != null ? _appliedCoupon!['finalAmount'] : amount} with Razorpay UPI',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 12),

            // Supported UPI Apps Row
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle_outline_rounded, size: 14, color: AppTheme.accentText),
                const SizedBox(width: 5),
                Text(
                  'Supports Google Pay · PhonePe · Paytm · BHIM · Cred · QR',
                  style: TextStyle(color: AppTheme.text2, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Secondary: Fallback Direct UPI Intent / VPA
            InkWell(
              onTap: () {
                setState(() {
                  _showManualFallback = !_showManualFallback;
                });
              },
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _showManualFallback ? 'Hide direct UPI options' : 'Having trouble? Pay via direct UPI link / VPA',
                      style: TextStyle(
                        color: AppTheme.accentText,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      _showManualFallback ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                      size: 16,
                      color: AppTheme.accentText,
                    ),
                  ],
                ),
              ),
            ),

            if (_showManualFallback) ...[
              const SizedBox(height: 12),
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
                      'DIRECT UPI INTENT',
                      style: TextStyle(
                        color: AppTheme.text2,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: AppTheme.brand),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: _isLoading ? null : () => _launchUpiIntent(),
                        icon: Icon(Icons.open_in_new_rounded, size: 16, color: AppTheme.brand),
                        label: Text(
                          'Launch Native UPI App (Intent)',
                          style: TextStyle(color: AppTheme.brand, fontSize: 12, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Divider(height: 1, color: AppTheme.border),
                    const SizedBox(height: 12),
                    Text(
                      'OFFICIAL CO-ROUTE VPA',
                      style: TextStyle(
                        color: AppTheme.text2,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: AppTheme.card,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              vpa,
                              style: TextStyle(
                                color: AppTheme.text,
                                fontFamily: 'monospace',
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.copy_rounded, size: 18),
                          color: AppTheme.brand,
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: vpa));
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Copied $vpa to clipboard!'),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _utrController,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              hintText: 'Enter 12-digit UPI UTR',
                              hintStyle: TextStyle(color: AppTheme.muted, fontSize: 11),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppTheme.accentText,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                          onPressed: _isLoading ? null : () => _verifyManualUtr(),
                          child: const Text('Verify', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 16),
            Text(
              '256-Bit SSL Encrypted · RBI Regulated UPI Payment Processing',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.muted, fontSize: 10),
            ),
          ],
        ],
      ),
    );
  }
}
