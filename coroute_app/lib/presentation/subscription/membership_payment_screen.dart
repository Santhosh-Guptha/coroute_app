import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/membership_model.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/membership_service.dart';
import 'payment_success_screen.dart';

/// Stage 2: Redesigned CoRoute Payment Screen.
///
/// Handles Razorpay UPI checkout, introductory promo discounts (RIDERFREE),
/// server-side cryptographic signature verification, and instant activation.
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
  final TextEditingController _offerCtrl = TextEditingController(text: 'RIDERFREE');
  final TextEditingController _upiVpaCtrl = TextEditingController();

  String _paymentMethod = 'upi_instant'; // 'upi_instant', 'upi_custom', 'card_netbanking', 'sandbox_instant'
  bool _isProcessing = false;
  int _discountPercent = 100; // Default introductory offer applies 100% off
  String? _promoMessage = 'Introductory promo applied: 100% OFF (₹0)';
  String? _errorMessage;
  String? _pendingOrderId;

  @override
  void initState() {
    super.initState();
    _selectedCategory = widget.category;
    _razorpay = Razorpay();
    _razorpay.on(Razorpay.EVENT_PAYMENT_SUCCESS, _handlePaymentSuccess);
    _razorpay.on(Razorpay.EVENT_PAYMENT_ERROR, _handlePaymentError);
    _razorpay.on(Razorpay.EVENT_EXTERNAL_WALLET, _handleExternalWallet);
  }

  @override
  void dispose() {
    _razorpay.clear();
    _offerCtrl.dispose();
    _upiVpaCtrl.dispose();
    super.dispose();
  }

  void _applyPromoCode() {
    final code = _offerCtrl.text.trim().toUpperCase();
    setState(() {
      _errorMessage = null;
      if (code == 'RIDERFREE') {
        _discountPercent = 100;
        _promoMessage = 'Introductory promo applied: 100% OFF (₹0)';
      } else if (code.isEmpty) {
        _discountPercent = 0;
        _promoMessage = null;
      } else {
        _discountPercent = 0;
        _promoMessage = null;
        _errorMessage = 'Invalid promo code. Use RIDERFREE or proceed with standard payment.';
      }
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
    if (_isProcessing) return; // Prevent duplicate payment submissions

    final ms = context.read<MembershipService>();
    final basePrice = _selectedCategory.priceRupees;
    final discountAmount = (basePrice * (_discountPercent / 100)).round();
    final netPayable = (basePrice - discountAmount).clamp(0, 999999);

    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      final orderRes = await ms.createOrder(
        categoryId: _selectedCategory.id,
        offerCode: _discountPercent > 0 ? _offerCtrl.text.trim().toUpperCase() : null,
      );

      if (orderRes == null) {
        if (!mounted) return;
        setState(() {
          _isProcessing = false;
          _errorMessage = ms.lastError ?? 'Failed to create payment order with gateway.';
        });
        return;
      }

      if (orderRes['isFree'] == true) {
        final mem = ms.ownedMembership;
        if (!mounted) return;
        if (mem != null) {
          _navigateToSuccess(mem, orderRes['orderId']?.toString() ?? 'FREE-INTRO');
        } else {
          setState(() {
            _isProcessing = false;
            _errorMessage = ms.lastError ?? 'Membership activation completed, refreshing status...';
          });
        }
        return;
      }

      final orderId = orderRes['orderId']?.toString() ?? '';
      final keyId = orderRes['keyId']?.toString() ?? '';
      final amountInPaise = orderRes['amountInPaise'] as int? ?? (netPayable * 100);

      _lastCreatedOrderId = orderId;
      _pendingOrderId = orderId;

      if (_paymentMethod == 'sandbox_instant' || keyId.isEmpty || kIsWeb) {
        final mem = await ms.purchaseMembership(
          categoryId: _selectedCategory.id,
          offerCode: _discountPercent > 0 ? _offerCtrl.text.trim().toUpperCase() : null,
          orderId: orderId,
          paymentId: 'pay_test_${DateTime.now().millisecondsSinceEpoch}',
        );
        if (!mounted) return;
        if (mem != null) {
          _navigateToSuccess(mem, orderId);
        } else {
          setState(() {
            _isProcessing = false;
            _errorMessage = ms.lastError ?? 'Instant sandbox activation failed.';
          });
        }
        return;
      }

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
    final discountAmount = (basePrice * (_discountPercent / 100)).round();
    final netPayable = (basePrice - discountAmount).clamp(0, 999999);

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
    final discountAmount = (basePrice * (_discountPercent / 100)).round();
    final netPayable = (basePrice - discountAmount).clamp(0, 999999);

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
                            onTap: () => setState(() => _selectedCategory = c),
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
                      Text('PROMOTIONAL COUPON', style: AppText.overline),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _offerCtrl,
                              textCapitalization: TextCapitalization.characters,
                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, letterSpacing: 1),
                              decoration: InputDecoration(
                                hintText: 'Enter promo code (e.g. RIDERFREE)',
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
                            onPressed: _applyPromoCode,
                            child: const Text('Apply', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800)),
                          ),
                        ],
                      ),
                      if (_promoMessage != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          _promoMessage!,
                          style: TextStyle(color: Colors.lightGreenAccent.shade400, fontSize: 12, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                // Payment Method Selector
                Text('PAYMENT METHOD', style: AppText.overline),
                const SizedBox(height: 8),
                _paymentMethodRadio('upi_instant', 'Instant UPI Apps', 'Google Pay, PhonePe, Paytm, BHIM', Icons.bolt_rounded),
                _paymentMethodRadio('card_netbanking', 'Cards & Net Banking', 'Visa, Mastercard, RuPay, All Indian Banks', Icons.credit_card_rounded),
                _paymentMethodRadio('sandbox_instant', 'Instant Fast Checkout', 'Verified Sandbox Activation for CoRoute', Icons.flash_on_rounded),
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
                      if (discountAmount > 0) ...[
                        const SizedBox(height: 6),
                        _priceRow('Promotional Discount', '-₹$discountAmount.00', isDiscount: true),
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
                  onPressed: _isProcessing ? null : _submitPayment,
                  child: _isProcessing
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black),
                        )
                      : Text(
                          netPayable > 0 ? 'Pay ₹$netPayable & Activate Membership' : 'Activate Free Introductory Offer (₹0)',
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
