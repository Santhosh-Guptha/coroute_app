import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/membership_model.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/membership_service.dart';
import 'payment_success_screen.dart';

/// Stage 2: CoRoute Membership Payment Screen.
///
/// Features:
/// 1. Zero-Amount Activation: When net payable is ₹0, payment methods are completely hidden,
///    and membership activates directly via backend authorization without Razorpay orders.
/// 2. Razorpay Only: Real Razorpay payment methods only (Instant UPI, Cards & Net Banking).
///    All sandbox activation shortcuts have been completely eliminated.
/// 3. Dynamic Coupon Recalculation: Instant recalculation when applying/removing coupons
///    or when switching membership tier tabs.
/// 4. Duplicate Submit Protection & Idempotent Verification.
class MembershipPaymentScreen extends StatefulWidget {
  final MembershipCategory category;
  final bool isTripCreationFlow;

  const MembershipPaymentScreen({
    super.key,
    required this.category,
    this.isTripCreationFlow = false,
  });

  /// Opens the payment screen and returns true if membership was activated.
  static Future<bool?> push(
    BuildContext context, {
    required MembershipCategory category,
    bool isTripCreationFlow = false,
  }) {
    return Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => MembershipPaymentScreen(
          category: category,
          isTripCreationFlow: isTripCreationFlow,
        ),
      ),
    );
  }

  @override
  State<MembershipPaymentScreen> createState() => _MembershipPaymentScreenState();
}

class _MembershipPaymentScreenState extends State<MembershipPaymentScreen> {
  late Razorpay _razorpay;
  String? _lastCreatedOrderId;

  late MembershipCategory _selectedCategory;
  final TextEditingController _offerCtrl = TextEditingController();

  // Supported Razorpay payment methods only (no sandbox)
  String _paymentMethod = 'razorpay_upi'; // 'razorpay_upi', 'razorpay_card_netbanking'

  bool _isProcessing = false;
  bool _isValidatingCoupon = false;

  // Coupon state: clean, empty initial state (no prefilled RIDERFREE, optional)
  String? _appliedCouponCode;
  int _discountAmountRupees = 0;
  String? _promoMessage;
  String? _errorMessage;
  String? _pendingOrderId;

  @override
  void initState() {
    super.initState();
    _selectedCategory = widget.category;
    _discountAmountRupees = 0;
    _razorpay = Razorpay();
    _razorpay.on(Razorpay.EVENT_PAYMENT_SUCCESS, _handlePaymentSuccess);
    _razorpay.on(Razorpay.EVENT_PAYMENT_ERROR, _handlePaymentError);
    _razorpay.on(Razorpay.EVENT_EXTERNAL_WALLET, _handleExternalWallet);
  }

  @override
  void dispose() {
    _razorpay.clear();
    _offerCtrl.dispose();
    super.dispose();
  }

  /// When user switches membership tier tab (Solo, 6 Bikes, 12 Bikes)
  void _onCategoryChanged(MembershipCategory newCat) {
    if (_selectedCategory.id == newCat.id) return;
    setState(() {
      _selectedCategory = newCat;
      _errorMessage = null;
    });

    if (_appliedCouponCode != null) {
      _revalidateCouponForCategory(newCat);
    }
  }

  /// Automatically re-validates current coupon when switching tiers
  Future<void> _revalidateCouponForCategory(MembershipCategory cat) async {
    final code = _appliedCouponCode;
    if (code == null) return;

    setState(() => _isValidatingCoupon = true);
    final ms = context.read<MembershipService>();
    final res = await ms.validateCoupon(code: code, categoryId: cat.id);
    if (!mounted) return;

    setState(() {
      _isValidatingCoupon = false;
      if (res != null && res['valid'] == true) {
        _discountAmountRupees = (res['discountAmount'] as num?)?.toInt() ?? 0;
        _promoMessage = res['message']?.toString() ?? 'Coupon $code applied: -₹$_discountAmountRupees';
      } else {
        // Coupon not applicable to new tier
        _appliedCouponCode = null;
        _discountAmountRupees = 0;
        _promoMessage = null;
        _errorMessage = ms.lastError ?? 'Coupon $code is not applicable to ${cat.name}. Reverted to original price.';
      }
    });
  }

  /// Applies coupon via server validation
  Future<void> _applyPromoCode() async {
    final code = _offerCtrl.text.trim().toUpperCase();
    if (code.isEmpty) {
      _removeCoupon();
      return;
    }

    setState(() {
      _isValidatingCoupon = true;
      _errorMessage = null;
    });

    final ms = context.read<MembershipService>();
    final res = await ms.validateCoupon(code: code, categoryId: _selectedCategory.id);
    if (!mounted) return;

    setState(() {
      _isValidatingCoupon = false;
      if (res != null && res['valid'] == true) {
        _appliedCouponCode = code;
        final rawDisc = res['discountAmount'] ?? res['discountInr'];
        _discountAmountRupees = (rawDisc as num?)?.toInt() ?? 0;
        _promoMessage = res['message']?.toString() ?? 'Coupon $code applied: -₹$_discountAmountRupees';
        _errorMessage = null;
      } else {
        _appliedCouponCode = null;
        _discountAmountRupees = 0;
        _promoMessage = null;
        _errorMessage = ms.lastError ?? 'Invalid or inapplicable coupon code.';
      }
    });
  }

  /// Removes applied coupon and immediately restores original price
  void _removeCoupon() {
    setState(() {
      _offerCtrl.clear();
      _appliedCouponCode = null;
      _discountAmountRupees = 0;
      _promoMessage = null;
      _errorMessage = null;
    });
  }

  void _openRazorpayCheckout({
    required String orderId,
    required String keyId,
    required int amountInPaise,
  }) {
    final auth = context.read<AuthService?>();
    final options = <String, dynamic>{
      'key': keyId,
      'amount': amountInPaise,
      'name': 'CoRoute Membership',
      'description': '${_selectedCategory.name} (${_selectedCategory.capacity} riders)',
      'order_id': orderId,
      'prefill': {
        'contact': auth?.phone ?? '',
        'email': auth?.currentUserEmail ?? '',
        'name': auth?.currentUserName ?? '',
      },
      'theme': {
        'color': '#FF5722',
      },
    };

    try {
      _razorpay.open(options);
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _errorMessage = 'Could not launch payment gateway: $e';
      });
    }
  }

  void _handlePaymentSuccess(PaymentSuccessResponse response) async {
    final ms = context.read<MembershipService>();
    final orderId = response.orderId ?? _lastCreatedOrderId;
    final paymentId = response.paymentId ?? '';
    final signature = response.signature ?? '';

    if (orderId == null || orderId.isEmpty) {
      setState(() {
        _isProcessing = false;
        _errorMessage = 'Missing order reference from payment gateway.';
      });
      return;
    }

    final mem = await ms.verifyPayment(
      orderId: orderId,
      paymentId: paymentId,
      signature: signature,
    );

    if (!mounted) return;
    if (mem != null) {
      _navigateToSuccess(mem, paymentId);
    } else {
      setState(() {
        _isProcessing = false;
        _errorMessage = ms.lastError ?? 'Payment signature verification failed. Please check your transaction history.';
      });
    }
  }

  void _handlePaymentError(PaymentFailureResponse response) {
    if (!mounted) return;
    setState(() {
      _isProcessing = false;
      if (response.code == Razorpay.PAYMENT_CANCELLED) {
        _errorMessage = 'Payment was cancelled by rider. You can retry when ready.';
      } else {
        _errorMessage = response.message ?? 'Payment failed (Code: ${response.code}).';
      }
    });
  }

  void _handleExternalWallet(ExternalWalletResponse response) {
    // External wallet handler if configured
  }

  Future<void> _submitPayment() async {
    if (_isProcessing || _isValidatingCoupon) return; // Prevent duplicate payment submissions

    final ms = context.read<MembershipService>();
    final basePrice = _selectedCategory.priceRupees;
    final netPayable = (basePrice - _discountAmountRupees).clamp(0, 999999);

    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      // 1. Zero-Amount Membership Activation Flow (No Razorpay Order Created)
      if (netPayable == 0) {
        final couponCode = _appliedCouponCode ?? _offerCtrl.text.trim();
        final mem = await ms.activateFreeMembership(
          categoryId: _selectedCategory.id,
          couponCode: couponCode.isNotEmpty ? couponCode : 'RIDERFREE',
        );

        if (!mounted) return;
        if (mem != null) {
          _navigateToSuccess(mem, 'FREE-PROMO');
        } else {
          setState(() {
            _isProcessing = false;
            _errorMessage = ms.lastError ?? 'Zero-amount membership activation failed.';
          });
        }
        return;
      }

      // 2. Paid Razorpay Checkout Flow
      final orderRes = await ms.createOrder(
        categoryId: _selectedCategory.id,
        offerCode: _appliedCouponCode,
      );

      if (orderRes == null) {
        if (!mounted) return;
        setState(() {
          _isProcessing = false;
          _errorMessage = ms.lastError ?? 'Failed to create payment order with gateway.';
        });
        return;
      }

      final orderId = orderRes['orderId']?.toString() ?? '';
      final keyId = orderRes['keyId']?.toString() ?? '';
      final amountInPaise = orderRes['amountInPaise'] as int? ?? (netPayable * 100);

      _lastCreatedOrderId = orderId;
      _pendingOrderId = orderId;

      _openRazorpayCheckout(orderId: orderId, keyId: keyId, amountInPaise: amountInPaise);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _errorMessage = 'Payment checkout error: $e';
      });
    }
  }

  void _navigateToSuccess(UserMembership mem, String ref) async {
    final basePrice = _selectedCategory.priceRupees;
    final netPayable = (basePrice - _discountAmountRupees).clamp(0, 999999);

    final res = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PaymentSuccessScreen(
          membership: mem,
          transactionReference: ref,
          amountPaidInRupees: netPayable,
          isTripCreationFlow: widget.isTripCreationFlow,
        ),
      ),
    );

    if (mounted && res == true) {
      Navigator.pop(context, true);
    }
  }

  Future<void> _checkPendingOrderStatus() async {
    final ms = context.read<MembershipService>();
    setState(() => _isProcessing = true);
    await ms.fetchMyMembership();
    if (!mounted) return;
    setState(() => _isProcessing = false);
    if (ms.ownedMembership != null && !ms.ownedMembership!.isExpired) {
      _navigateToSuccess(ms.ownedMembership!, _pendingOrderId ?? 'VERIFIED-SERVER');
    } else {
      setState(() {
        _errorMessage = 'Order is still processing or waiting for payment settlement.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ms = context.watch<MembershipService>();
    final catalog = ms.catalog;
    final basePrice = _selectedCategory.priceRupees;
    final netPayable = (basePrice - _discountAmountRupees).clamp(0, 999999);

    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('Membership Payment', style: AppText.headline.copyWith(fontSize: 16)),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              physics: const BouncingScrollPhysics(),
              children: [
                // Plan selector tabs (if catalog available)
                if (catalog != null && catalog.categories.isNotEmpty) ...[
                  Text('SELECT MEMBERSHIP TIER', style: AppText.overline),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final c in catalog.categories)
                        Expanded(
                          child: GestureDetector(
                            onTap: () => _onCategoryChanged(c),
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                              decoration: BoxDecoration(
                                color: _selectedCategory.id == c.id
                                    ? AppTheme.brand.withValues(alpha: 0.2)
                                    : AppTheme.card,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _selectedCategory.id == c.id ? AppTheme.brand : AppTheme.border,
                                  width: _selectedCategory.id == c.id ? 2 : 1,
                                ),
                              ),
                              child: Column(
                                children: [
                                  Text(
                                    c.capacity == 1 ? 'Solo' : '${c.capacity} Bikes',
                                    style: TextStyle(
                                      color: _selectedCategory.id == c.id ? AppTheme.brand : AppTheme.text,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '₹${c.priceRupees}/mo',
                                    style: TextStyle(
                                      color: _selectedCategory.id == c.id ? Colors.white : AppTheme.text2,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                ],

                // Selected Plan details card
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
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_selectedCategory.name, style: AppText.title.copyWith(fontSize: 17, fontWeight: FontWeight.w800)),
                                const SizedBox(height: 2),
                                Text(
                                  '${_selectedCategory.capacity} ${(_selectedCategory.capacity == 1 ? 'Rider' : 'Riders')} Capacity · Monthly Subscription',
                                  style: AppText.caption,
                                ),
                              ],
                            ),
                          ),
                          Text(
                            '₹$basePrice',
                            style: AppText.headline.copyWith(fontSize: 20, color: AppTheme.brand),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      const Divider(height: 1),
                      const SizedBox(height: 14),

                      Text('Included Benefits:', style: AppText.caption.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      _benefitItem(Icons.emergency_rounded, 'Continuous Impact Crash Detection & Emergency SOS'),
                      _benefitItem(Icons.map_rounded, 'Full Corridor Offline Maps (2.5 km Minkowski Corridor)'),
                      _benefitItem(Icons.navigation_rounded, 'High-Precision Route Navigation & Speed Alerts'),
                      if (_selectedCategory.capacity > 1) ...[
                        _benefitItem(Icons.group_rounded, 'Live Convoy Hosting for up to ${_selectedCategory.capacity} Riders'),
                        _benefitItem(Icons.mic_rounded, 'Tactical PTT Voice Intercom & Regroup Dispatch'),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                // Promotional coupon box
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppTheme.soft,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              'PROMOTIONAL COUPON (OPTIONAL)',
                              style: AppText.overline,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (_appliedCouponCode != null)
                            GestureDetector(
                              onTap: _removeCoupon,
                              child: Text(
                                'Remove Coupon',
                                style: TextStyle(color: Colors.redAccent.shade100, fontSize: 11, fontWeight: FontWeight.bold),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (_appliedCouponCode == null) ...[
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _offerCtrl,
                                textCapitalization: TextCapitalization.characters,
                                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, letterSpacing: 1),
                                decoration: InputDecoration(
                                  hintText: 'Enter coupon code',
                                  hintStyle: TextStyle(color: AppTheme.text2, fontSize: 12),
                                  filled: true,
                                  fillColor: AppTheme.card,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: AppTheme.border)),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: AppTheme.brand,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              ),
                              onPressed: _isValidatingCoupon ? null : _applyPromoCode,
                              child: _isValidatingCoupon
                                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                                  : const Text('Apply', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800)),
                            ),
                          ],
                        ),
                      ] else ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: Colors.greenAccent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.4)),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: Colors.greenAccent.withValues(alpha: 0.2),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.check_rounded, color: Colors.greenAccent, size: 16),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '$_appliedCouponCode Applied!',
                                      style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.w900, fontSize: 13),
                                    ),
                                    Text(
                                      _promoMessage ?? 'Discount applied to plan',
                                      style: TextStyle(color: Colors.greenAccent.shade100, fontSize: 11),
                                    ),
                                  ],
                                ),
                              ),
                              TextButton(
                                onPressed: _removeCoupon,
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  foregroundColor: Colors.redAccent.shade100,
                                ),
                                child: const Text('Remove', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                // CRITICAL REQUIREMENT 1: When netPayable is ₹0, NEVER show payment methods.
                // When netPayable > 0, show ONLY verified Razorpay payment methods.
                if (netPayable == 0) ...[
                  _buildZeroPaymentInfoCard(),
                ] else ...[
                  Text('PAYMENT METHOD', style: AppText.overline),
                  const SizedBox(height: 8),
                  _paymentMethodRadio('razorpay_upi', 'Instant UPI Apps', 'Google Pay, PhonePe, Paytm, BHIM UPI', Icons.bolt_rounded),
                  _paymentMethodRadio('razorpay_card_netbanking', 'Cards & Net Banking', 'Visa, Mastercard, RuPay, All Indian Banks', Icons.credit_card_rounded),
                ],
                const SizedBox(height: 16),

                // Pricing Summary
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.card,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Column(
                    children: [
                      _priceRow('Monthly Plan', '₹$basePrice.00'),
                      if (_discountAmountRupees > 0) ...[
                        const SizedBox(height: 6),
                        _priceRow('Promotional Discount', '-₹$_discountAmountRupees.00', isDiscount: true),
                      ],
                      const SizedBox(height: 8),
                      const Divider(height: 1),
                      const SizedBox(height: 8),
                      _priceRow('Total Payable', netPayable == 0 ? '₹0.00 (Free)' : '₹$netPayable.00', isTotal: true),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Error message banner
                if (_errorMessage != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.redAccent.withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(_errorMessage!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                // Pending order recovery
                if (_pendingOrderId != null) ...[
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: AppTheme.accentText),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _isProcessing ? null : _checkPendingOrderStatus,
                    icon: const Icon(Icons.sync_rounded, size: 18),
                    label: const Text('Check Pending Order Status'),
                  ),
                  const SizedBox(height: 12),
                ],

                // Submit Button
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    minimumSize: const Size.fromHeight(54),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: (_isProcessing || _isValidatingCoupon) ? null : _submitPayment,
                  child: _isProcessing
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black),
                        )
                      : Text(
                          netPayable > 0 ? 'Pay ₹$netPayable & Activate Membership' : 'Activate Free Membership (₹0)',
                          style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 15),
                        ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildZeroPaymentInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.brand.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.brand.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.verified_rounded, color: AppTheme.brand, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '100% Free Activation',
                  style: AppText.title.copyWith(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const SizedBox(height: 3),
                Text(
                  'Your coupon covers the entire membership fee. No payment method, card or UPI details are required. Tap below to activate instantly.',
                  style: AppText.caption.copyWith(color: AppTheme.text2, height: 1.3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _benefitItem(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppTheme.accentText),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: AppText.body.copyWith(fontSize: 12))),
        ],
      ),
    );
  }

  Widget _paymentMethodRadio(String value, String title, String subtitle, IconData icon) {
    final isSelected = _paymentMethod == value;
    return GestureDetector(
      onTap: () => setState(() => _paymentMethod = value),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.brand.withValues(alpha: 0.15) : AppTheme.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: isSelected ? AppTheme.brand : AppTheme.border, width: isSelected ? 1.5 : 1),
        ),
        child: Row(
          children: [
            Icon(icon, color: isSelected ? AppTheme.brand : AppTheme.text2, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppText.body.copyWith(fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600, fontSize: 13)),
                  Text(subtitle, style: AppText.caption.copyWith(fontSize: 11)),
                ],
              ),
            ),
            Radio<String>(
              value: value,
              groupValue: _paymentMethod,
              activeColor: AppTheme.brand,
              onChanged: (v) => setState(() => _paymentMethod = v!),
            ),
          ],
        ),
      ),
    );
  }

  Widget _priceRow(String label, String value, {bool isDiscount = false, bool isTotal = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            label,
            style: isTotal ? AppText.title.copyWith(fontSize: 14, fontWeight: FontWeight.bold) : AppText.caption,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          value,
          style: TextStyle(
            color: isDiscount
                ? Colors.lightGreenAccent.shade400
                : (isTotal ? (value.contains('Free') ? Colors.lightGreenAccent.shade400 : AppTheme.brand) : AppTheme.text),
            fontSize: isTotal ? 15 : 13,
            fontWeight: isTotal ? FontWeight.w900 : FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
