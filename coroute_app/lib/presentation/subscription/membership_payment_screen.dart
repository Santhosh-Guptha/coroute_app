import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/membership_model.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/membership_service.dart';
import 'payment_success_screen.dart';

/// Membership checkout: buy Small Group or Large Group (Community is free and never bought).
///
/// The price always comes from the server (GET /membership/quote): list price, coupon, and credit
/// for the unused days of the current paid plan ("Large Group ₹99 − ₹31 credit for 19 unused
/// days = ₹68"). The order the rider pays is priced by the same server computation; the app never
/// sends an amount.
///
/// Coupons never block paying: a refused code shows a short message under the field, the field is
/// cleared and Pay still works at the normal price. When the server prices the order at ₹0 (a 100%
/// coupon, or credit covering it all) it activates the plan itself and no payment opens.
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

  /// Bumped on every new price request (and on Pay), so an older answer never overwrites a newer one.
  int _quoteSeq = 0;

  // Coupon state: empty until the rider enters a code (nothing is prefilled or sent on their behalf).
  String? _appliedCouponCode;
  String? _promoMessage;

  /// Why the last typed code was refused (shown under the field); the price stays the normal one.
  String? _couponError;
  String? _errorMessage;
  String? _pendingOrderId;

  /// The server's price for the selected plan (null until it answered; the list price shows meanwhile).
  PlanQuote? _quote;

  @override
  void initState() {
    super.initState();
    _selectedCategory = widget.category;
    _razorpay = Razorpay();
    _razorpay.on(Razorpay.EVENT_PAYMENT_SUCCESS, _handlePaymentSuccess);
    _razorpay.on(Razorpay.EVENT_PAYMENT_ERROR, _handlePaymentError);
    _razorpay.on(Razorpay.EVENT_EXTERNAL_WALLET, _handleExternalWallet);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Opened for a plan that is not sold (Community, the retired Individual): the cheapest paid plan.
      if (!_selectedCategory.canBuy) {
        final paid = context.read<MembershipService>().catalog?.paidCategories ?? const <MembershipCategory>[];
        if (paid.isNotEmpty) setState(() => _selectedCategory = paid.first);
      }
      _refreshQuote();
    });
  }

  @override
  void dispose() {
    _razorpay.clear();
    _offerCtrl.dispose();
    super.dispose();
  }

  /// What the rider pays now: the server's quote, or the list price before it answered.
  PlanQuote get _price => _quote ?? PlanQuote.listPrice(_selectedCategory);

  /// The price without a code (initial load, after Remove, after a refused code, on a plan switch).
  Future<void> _refreshQuote({String? coupon}) async {
    final seq = ++_quoteSeq;
    final ms = context.read<MembershipService>();
    final q = await ms.fetchQuote(categoryId: _selectedCategory.id, couponCode: coupon);
    if (!mounted || seq != _quoteSeq) return;
    if (q != null) setState(() => _quote = q);
  }

  /// When user switches plan tab (Small Group, Large Group): the applied code is checked again.
  void _onCategoryChanged(MembershipCategory newCat) {
    if (_selectedCategory.id == newCat.id) return;
    setState(() {
      _selectedCategory = newCat;
      _quote = null;
      _errorMessage = null;
      _couponError = null;
    });
    final code = _appliedCouponCode;
    if (code != null) {
      _checkCoupon(code, keepTextOnRefusal: false);
    } else {
      _refreshQuote();
    }
  }

  /// Applies the typed code via the server quote.
  Future<void> _applyPromoCode() async {
    final code = _offerCtrl.text.trim().toUpperCase();
    if (code.isEmpty) {
      _removeCoupon();
      return;
    }
    await _checkCoupon(code, keepTextOnRefusal: false);
  }

  Future<void> _checkCoupon(String code, {required bool keepTextOnRefusal}) async {
    final seq = ++_quoteSeq;
    setState(() {
      _isValidatingCoupon = true;
      _couponError = null;
      _errorMessage = null;
    });
    final ms = context.read<MembershipService>();
    final q = await ms.fetchQuote(categoryId: _selectedCategory.id, couponCode: code);
    if (!mounted) return;
    if (seq != _quoteSeq) {
      // Pay was pressed (or another code applied) meanwhile: this answer is stale.
      setState(() => _isValidatingCoupon = false);
      return;
    }
    setState(() {
      _isValidatingCoupon = false;
      if (q == null) {
        // The price could not be checked: the code is not applied, paying works at the normal price.
        _appliedCouponCode = null;
        _promoMessage = null;
        _couponError = couponErrorMessage(ms.lastErrorReason) ?? "Couldn't check the code. You can still pay the normal price.";
        if (!keepTextOnRefusal) _offerCtrl.clear();
        return;
      }
      _quote = q;
      if (q.couponRefused || !q.hasCoupon) {
        _appliedCouponCode = null;
        _promoMessage = null;
        _couponError = couponErrorMessage(q.couponErrorReason) ?? q.couponErrorMessage ?? "This code can't be used";
        if (!keepTextOnRefusal) _offerCtrl.clear();
      } else {
        _appliedCouponCode = code;
        _couponError = null;
        _promoMessage = '₹${q.couponDiscountInr} off';
      }
    });
  }

  /// The server refused the code at checkout: drop it so the rider can pay the normal price.
  void _dropCoupon(String? message) {
    _offerCtrl.clear();
    _appliedCouponCode = null;
    _promoMessage = null;
    _couponError = null;
    _errorMessage = '${message ?? "This code can't be used"}. The code was removed, so you can pay the normal price.';
    _quote = null;
    _refreshQuote();
  }

  /// Removes applied coupon and immediately restores original price
  void _removeCoupon() {
    setState(() {
      _offerCtrl.clear();
      _appliedCouponCode = null;
      _promoMessage = null;
      _couponError = null;
      _errorMessage = null;
      _quote = null;
    });
    _refreshQuote();
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
        _errorMessage = 'Could not open the payment page. Try again.';
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
        _errorMessage = 'The payment page returned no order. Check your payment history before you pay again.';
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
        _errorMessage = ms.lastError ?? 'Payment could not be verified. Check your payment history.';
      });
    }
  }

  void _handlePaymentError(PaymentFailureResponse response) {
    if (!mounted) return;
    setState(() {
      _isProcessing = false;
      if (response.code == Razorpay.PAYMENT_CANCELLED) {
        _errorMessage = 'Payment cancelled. Try again when ready.';
      } else {
        _errorMessage = response.message ?? 'Payment failed (code ${response.code}). Try again.';
      }
    });
  }

  void _handleExternalWallet(ExternalWalletResponse response) {
    // External wallet handler if configured
  }

  /// Pay: never blocked by the coupon field. The server prices the order (same as the quote); a
  /// code it refuses is dropped and the rider can pay again at the normal price.
  Future<void> _submitPayment() async {
    if (_isProcessing) return; // Prevent duplicate payment submissions
    // A code still being checked is left out (its answer is ignored); the applied one goes along.
    _quoteSeq++;

    final ms = context.read<MembershipService>();
    final shownPayable = _price.payableInr;

    setState(() {
      _isProcessing = true;
      _isValidatingCoupon = false;
      _errorMessage = null;
    });

    try {
      final orderRes = await ms.createOrder(
        categoryId: _selectedCategory.id,
        offerCode: _appliedCouponCode,
      );

      if (orderRes == null) {
        if (!mounted) return;
        setState(() {
          _isProcessing = false;
          if (ms.lastErrorIsCouponRefusal) {
            _dropCoupon(ms.lastError);
          } else {
            _errorMessage = ms.lastError ?? 'Could not start the payment. Try again.';
          }
        });
        return;
      }

      // The server priced the order at ₹0 itself (coupon or credit) and has already activated the plan.
      if (orderRes['isFree'] == true) {
        final raw = orderRes['membership'];
        final mem = raw is Map ? UserMembership.fromJson(Map<String, dynamic>.from(raw)) : ms.ownedMembership;
        if (!mounted) return;
        if (mem != null) {
          _navigateToSuccess(mem, orderRes['orderId']?.toString() ?? 'FREE-PROMO', paid: 0);
        } else {
          setState(() {
            _isProcessing = false;
            _errorMessage = 'Your plan is being activated. Check again in a moment.';
          });
        }
        return;
      }

      final orderId = orderRes['orderId']?.toString() ?? '';
      final keyId = orderRes['keyId']?.toString() ?? '';
      final amountInPaise = (orderRes['amountInPaise'] as num?)?.toInt() ?? (shownPayable * 100);

      _lastCreatedOrderId = orderId;
      _pendingOrderId = orderId;

      if (keyId.isEmpty) {
        if (!mounted) return;
        setState(() {
          _isProcessing = false;
          _errorMessage = 'Payments are not set up. Please contact support.';
        });
        return;
      }

      _openRazorpayCheckout(orderId: orderId, keyId: keyId, amountInPaise: amountInPaise);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _errorMessage = 'Could not start the payment. Try again.';
      });
    }
  }

  void _navigateToSuccess(UserMembership mem, String ref, {int? paid}) async {
    final res = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PaymentSuccessScreen(
          membership: mem,
          transactionReference: ref,
          amountPaidInRupees: paid ?? _price.payableInr,
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
        _errorMessage = 'Payment is still processing.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ms = context.watch<MembershipService>();
    final paid = ms.catalog?.paidCategories ?? const <MembershipCategory>[];
    final price = _price;
    final basePrice = price.basePriceInr;
    final netPayable = price.payableInr;

    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('Plan payment', style: AppText.headline.copyWith(fontSize: 16)),
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
                // Plan selector (the paid plans only: Community is free and never bought)
                if (paid.length > 1) ...[
                  Text('CHOOSE YOUR PLAN', style: AppText.overline),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final c in paid)
                        Expanded(
                          child: GestureDetector(
                            onTap: () => _onCategoryChanged(c),
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                              decoration: BoxDecoration(
                                color: _selectedCategory.id == c.id ? AppTheme.brand.withValues(alpha: 0.2) : AppTheme.card,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _selectedCategory.id == c.id ? AppTheme.brand : AppTheme.border,
                                  width: _selectedCategory.id == c.id ? 2 : 1,
                                ),
                              ),
                              child: Column(
                                children: [
                                  Text(
                                    'Up to ${c.capacity} riders',
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
                                      color: _selectedCategory.id == c.id ? AppTheme.text : AppTheme.text2,
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
                                  'Up to ${_selectedCategory.capacity} ${_selectedCategory.capacity == 1 ? 'rider' : 'riders'} · 30 days',
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

                      Text('Included with this plan:', style: AppText.caption.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      if (_selectedCategory.capacity > 1) ...[
                        _benefitItem(Icons.group_rounded, 'Host rides for up to ${_selectedCategory.capacity} riders'),
                        _benefitItem(Icons.mic_rounded, 'Group talk and messages'),
                        _benefitItem(Icons.flag_rounded, 'Regroup points and riding roles (lead, middle, sweeper)'),
                      ],
                      _benefitItem(Icons.emergency_rounded, 'Crash alerts and SOS (free for everyone)'),
                      _benefitItem(Icons.map_rounded, 'Offline maps and route guide'),
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
                              'COUPON CODE (OPTIONAL)',
                              style: AppText.overline,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (_appliedCouponCode != null)
                            GestureDetector(
                              onTap: _removeCoupon,
                              child: Text(
                                'Remove coupon',
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
                                onSubmitted: (_) => _applyPromoCode(),
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
                              onPressed: (_isValidatingCoupon || _isProcessing) ? null : _applyPromoCode,
                              child: _isValidatingCoupon
                                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                                  : const Text('Apply', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800)),
                            ),
                          ],
                        ),
                        if (_couponError != null) ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Icon(Icons.info_outline_rounded, size: 16, color: AppTheme.warnText),
                              const SizedBox(width: 6),
                              Expanded(child: Text(_couponError!, style: AppText.caption.copyWith(color: AppTheme.warnText))),
                            ],
                          ),
                        ],
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
                                      '$_appliedCouponCode applied',
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
                                  minimumSize: const Size(48, 48),
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

                // At ₹0 no payment method is shown; above it, Razorpay methods only.
                if (netPayable == 0) ...[
                  _buildZeroPaymentInfoCard(price),
                ] else ...[
                  Text('PAYMENT METHOD', style: AppText.overline),
                  const SizedBox(height: 8),
                  _paymentMethodRadio('razorpay_upi', 'UPI apps', 'Google Pay, PhonePe, Paytm, BHIM UPI', Icons.bolt_rounded),
                  _paymentMethodRadio('razorpay_card_netbanking', 'Cards & net banking', 'Visa, Mastercard, RuPay, all Indian banks', Icons.credit_card_rounded),
                ],
                const SizedBox(height: 16),

                // Price breakdown, exactly as the server computed it
                PlanQuoteBreakdown(quote: price),
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
                    label: const Text('Check payment status'),
                  ),
                  const SizedBox(height: 12),
                ],

                // Submit Button: never disabled by the coupon field.
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
                          netPayable > 0 ? 'Pay ₹$netPayable and start plan' : 'Start plan for ₹0',
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

  Widget _buildZeroPaymentInfoCard(PlanQuote price) {
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
                  'Nothing to pay',
                  style: AppText.title.copyWith(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 3),
                Text(
                  price.hasCoupon
                      ? 'Your coupon covers the full price. Tap below to start.'
                      : 'Your unused days cover the full price. Tap below to start.',
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
}

/// The price breakdown of a [PlanQuote]: one row per line (plan, coupon, credit), the total, and
/// the plain-words sentence ("Large Group ₹99 − ₹31 credit for 19 unused days = ₹68") and notes
/// (when the new period starts) whenever there is more than the list price to explain.
class PlanQuoteBreakdown extends StatelessWidget {
  final PlanQuote quote;
  const PlanQuoteBreakdown({super.key, required this.quote});

  @override
  Widget build(BuildContext context) {
    final explain = quote.creditInr > 0 || quote.isDowngrade || quote.extraDays > 0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final l in quote.itemLines) ...[
            _row(l.label, '${l.amountText}.00', discount: l.amountInr < 0),
            const SizedBox(height: 6),
          ],
          const SizedBox(height: 2),
          const Divider(height: 1),
          const SizedBox(height: 8),
          _row('Total to pay', quote.isFree ? '₹0.00 (Free)' : '₹${quote.payableInr}.00', total: true),
          if (explain && quote.summary.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(quote.summary, style: AppText.caption.copyWith(color: AppTheme.text, fontWeight: FontWeight.w600)),
          ],
          if (explain)
            for (final n in quote.notes) ...[
              const SizedBox(height: 4),
              Text(n, style: AppText.caption),
            ],
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool discount = false, bool total = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            label,
            style: total ? AppText.title.copyWith(fontSize: 14, fontWeight: FontWeight.bold) : AppText.caption,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          value,
          style: TextStyle(
            color: discount
                ? Colors.lightGreenAccent.shade400
                : (total ? (value.contains('Free') ? Colors.lightGreenAccent.shade400 : AppTheme.brand) : AppTheme.text),
            fontSize: total ? 15 : 13,
            fontWeight: total ? FontWeight.w900 : FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
