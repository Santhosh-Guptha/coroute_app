import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/plan_subscription_service.dart';
import '../../data/services/subscription_reminders.dart';

/// Checkout for a paid plan. Razorpay is the only way to pay, by UPI:
///
/// 1. In the app: the Razorpay Checkout SDK, restricted to UPI. The signed
///    result is verified by `/subscription/verify-payment`.
/// 2. On the website: the order's `webCheckoutUrl` (valid 30 minutes). The
///    server activates the plan from Razorpay's webhook; the app re-reads the
///    status when the site sends the rider back (`coroute://subscription`) or
///    when the app returns to the foreground.
///
/// The summary shows the server's price, any automatic `offer` and any
/// `coupon` discount, and what happens to the plan the rider already holds.
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

  /// How long the website payment link of an order stays valid.
  static const Duration webLinkLifetime = Duration(minutes: 30);

  @override
  State<PaymentCheckoutModal> createState() => _PaymentCheckoutModalState();
}

class _PaymentCheckoutModalState extends State<PaymentCheckoutModal> with WidgetsBindingObserver {
  late Razorpay _razorpay;
  late final PlanSubscriptionService _service;
  final TextEditingController _couponController = TextEditingController();

  /// True after the website checkout was opened; the status is re-read when
  /// the app comes back (deep link or foreground).
  bool _waitingForWebPayment = false;
  bool _checkingWeb = false;

  bool _isLoading = false;
  bool _isSuccess = false;
  String? _errorMessage;
  String? _infoMessage;
  Map<String, dynamic>? _orderData;
  DateTime? _orderCreatedAt;

  Map<String, dynamic>? _appliedCoupon;
  bool _isValidatingCoupon = false;
  String? _couponError;

  static final NumberFormat _inrFmt = NumberFormat.decimalPattern('en_IN');

  @override
  void initState() {
    super.initState();
    _service = context.read<PlanSubscriptionService>();
    _razorpay = Razorpay();
    _razorpay.on(Razorpay.EVENT_PAYMENT_SUCCESS, _handlePaymentSuccess);
    _razorpay.on(Razorpay.EVENT_PAYMENT_ERROR, _handlePaymentError);
    _razorpay.on(Razorpay.EVENT_EXTERNAL_WALLET, _handleExternalWallet);
    WidgetsBinding.instance.addObserver(this);
    _service.checkoutReturns.addListener(_onCheckoutReturn);

    _initOrder();
  }

  @override
  void dispose() {
    _service.checkoutReturns.removeListener(_onCheckoutReturn);
    WidgetsBinding.instance.removeObserver(this);
    _razorpay.clear();
    _couponController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingForWebPayment) {
      _checkWebPaymentResult();
    }
  }

  /// `coroute://subscription` opened the app: the service already re-read the
  /// plan. An expired link gets a fresh order; otherwise look at the result.
  void _onCheckoutReturn() {
    if (!mounted || _isSuccess) return;
    final status = (_service.lastCheckoutReturn?.queryParameters['status'] ?? '').toLowerCase();
    if (status.contains('expired')) {
      setState(() {
        _waitingForWebPayment = false;
        _infoMessage = 'That payment link expired. A new order has been created; pay again in the app or on the website.';
      });
      _initOrder(couponCode: _couponCode);
      return;
    }
    _checkWebPaymentResult(sync: false);
  }

  String? get _couponCode => _appliedCoupon?['code']?.toString();

  bool get _orderLinkExpired {
    final at = _orderCreatedAt;
    if (at == null) return true;
    // A minute of margin: the rider still has to finish on the site.
    return DateTime.now().difference(at) > PaymentCheckoutModal.webLinkLifetime - const Duration(minutes: 1);
  }

  /// Opens the order on the website (UPI only). A link older than 30 minutes
  /// would be refused there, so a new order is created first.
  Future<void> _payOnWebsite() async {
    if (_orderData == null || _orderLinkExpired) {
      await _initOrder(couponCode: _couponCode);
      if (!mounted || _orderData == null) return;
    }
    final url = _orderData?['webCheckoutUrl']?.toString();
    if (url == null || url.isEmpty) {
      setState(() => _errorMessage = 'Website payment is not available for this order. Pay in the app instead.');
      return;
    }
    try {
      final launched = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!launched) throw Exception('No browser available');
      if (!mounted) return;
      setState(() {
        _waitingForWebPayment = true;
        _errorMessage = null;
        _infoMessage = 'Finish the UPI payment on the website. You will come back here automatically.';
      });
    } catch (e) {
      if (mounted) setState(() => _errorMessage = 'Could not open the website: $e');
    }
  }

  Future<void> _checkWebPaymentResult({bool sync = true}) async {
    if (!mounted || _checkingWeb || _isSuccess) return;
    _checkingWeb = true;
    setState(() => _isLoading = true);
    try {
      if (sync) await _service.syncFromServer();
      if (!mounted) return;
      // The server's entitlement is what counts, not the rider's local preference.
      // A queued cheaper plan shows up as pendingTier instead.
      if (_service.isEntitledTo(widget.plan.tier) || _service.pendingTier == widget.plan.tier) {
        await _succeed();
      } else {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Payment not confirmed yet. Finish it on the website, then tap "I have paid".';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Could not check the payment: $e';
        });
      }
    } finally {
      _checkingWeb = false;
    }
  }

  Future<void> _succeed() async {
    HapticFeedback.heavyImpact();
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _isSuccess = true;
      _waitingForWebPayment = false;
      _errorMessage = null;
    });
    // A good moment to ask for the reminder notifications (once per install).
    PlanReminderScheduler.requestPermissionOnce().ignore();
    await Future.delayed(const Duration(milliseconds: 1400));
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _initOrder({String? couponCode}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final order = await _service.createOrder(
        widget.plan.tier,
        annual: widget.isAnnual,
        couponCode: couponCode,
      );
      if (mounted) {
        setState(() {
          _orderData = order;
          _orderCreatedAt = DateTime.now();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Could not create order: ${_messageOf(e)}';
        });
      }
    }
  }

  static String _messageOf(Object e) {
    final s = e.toString();
    final i = s.indexOf('): ');
    return s.startsWith('ApiException(') && i > 0 ? s.substring(i + 3) : s;
  }

  Future<void> _applyCoupon() async {
    // "Remove" when a coupon is on: back to the plain order.
    if (_appliedCoupon != null) {
      _couponController.clear();
      setState(() {
        _appliedCoupon = null;
        _couponError = null;
      });
      _initOrder();
      return;
    }
    final code = _couponController.text.trim().toUpperCase();
    if (code.isEmpty) {
      setState(() => _couponError = null);
      return;
    }

    setState(() {
      _isValidatingCoupon = true;
      _couponError = null;
    });

    try {
      final res = await _service.validateCoupon(
        code: code,
        tier: widget.plan.tier,
        annual: widget.isAnnual,
      );
      if (!mounted) return;
      if (res != null && res['valid'] == true) {
        setState(() {
          _appliedCoupon = {...res, 'code': res['code'] ?? code};
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
    } catch (e) {
      if (mounted) {
        setState(() {
          _appliedCoupon = null;
          _isValidatingCoupon = false;
          _couponError = _messageOf(e);
        });
      }
    }
  }

  /// Amount to pay in paise, from the server's order (never computed locally).
  int get _payablePaise {
    final v = _orderData?['amountInPaise'];
    if (v is num) return v.toInt();
    final rupees = _orderData?['amount'];
    if (rupees is num) return (rupees * 100).round();
    return -1; // unknown until the order exists
  }

  bool get _isFreeOrder => _orderData != null && (_payablePaise == 0 || _appliedCoupon?['isFree'] == true);

  /// Activates a 100 % coupon order: nothing to pay, the server verifies the coupon.
  Future<void> _claimFreePass() async {
    final orderId = _orderData?['orderId']?.toString();
    if (orderId == null) {
      _initOrder(couponCode: _couponCode);
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final res = await _service.verifyPayment(
      orderId: orderId,
      tier: widget.plan.tier,
      annual: widget.isAnnual,
      couponCode: _couponCode,
    );
    if (!mounted) return;
    if (res['success'] == true) {
      await _succeed();
    } else {
      setState(() {
        _isLoading = false;
        _errorMessage = res['error']?.toString() ?? 'Failed to activate free pass';
      });
    }
  }

  /// Launches the Razorpay Checkout SDK, UPI only.
  void _openRazorpayCheckout() {
    if (_orderData == null) {
      _initOrder(couponCode: _couponCode);
      return;
    }

    setState(() {
      _errorMessage = null;
      _infoMessage = null;
    });

    // The server sends the key id of the active mode (test or live).
    final keyId = _orderData?['razorpayOptions']?['key']?.toString() ?? _orderData?['razorpayKeyId']?.toString();
    if (keyId == null || keyId.isEmpty) {
      setState(() => _errorMessage = 'Online payment is not configured. Please try again later.');
      return;
    }
    final amountInPaise = _payablePaise;
    if (amountInPaise <= 0) {
      setState(() => _errorMessage = 'The order has no amount to pay. Close and try again.');
      return;
    }

    final orderId = _orderData?['orderId']?.toString() ?? '';
    final auth = context.read<AuthService?>();

    final options = <String, dynamic>{
      'key': keyId,
      'amount': amountInPaise,
      'name': 'CoRoute Motorcycle Safety',
      'description': '${widget.plan.name} (${widget.isAnnual ? 'Annual' : 'Monthly'})',
      'order_id': orderId,
      'prefill': {
        'contact': auth?.phone ?? '',
        'email': auth?.currentUserEmail ?? '',
        'name': auth?.currentUserName ?? '',
      },
      'notes': {
        'userId': auth?.currentUserId ?? '',
        'planTier': widget.plan.tier.name,
        'billingCycle': widget.isAnnual ? 'annual' : 'monthly',
      },
      'method': {
        'upi': true,
        'card': false,
        'netbanking': false,
        'wallet': false,
        'emi': false,
        'paylater': false,
      },
      'theme': {'color': '#FF5722'},
    };

    try {
      _razorpay.open(options);
    } catch (e) {
      setState(() => _errorMessage = 'Could not open Razorpay: $e. You can pay on the website instead.');
    }
  }

  /// Razorpay SDK success: verify the signature on the server, which activates the plan.
  Future<void> _handlePaymentSuccess(PaymentSuccessResponse response) async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final res = await _service.verifyPayment(
      orderId: response.orderId ?? _orderData?['orderId']?.toString() ?? '',
      tier: widget.plan.tier,
      annual: widget.isAnnual,
      paymentId: response.paymentId ?? '',
      signature: response.signature ?? '',
      couponCode: _couponCode,
    );
    if (!mounted) return;
    if (res['success'] == true) {
      await _succeed();
    } else {
      setState(() {
        _isLoading = false;
        _errorMessage = res['error']?.toString() ??
            'We could not confirm the payment yet. If money left your account, the plan activates within a few minutes.';
      });
    }
  }

  void _handlePaymentError(PaymentFailureResponse response) {
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _errorMessage = response.code == Razorpay.PAYMENT_CANCELLED
          ? 'Payment cancelled.'
          : (response.message ?? 'Payment failed (code ${response.code}).');
    });
  }

  void _handleExternalWallet(ExternalWalletResponse response) {
    if (!mounted) return;
    setState(() => _errorMessage = 'Wallets are not supported. Please pay by UPI.');
  }

  // ---------------------------------------------------------------- summary

  static num? _num(Object? v) => v is num ? v : num.tryParse('${v ?? ''}');

  /// Rupees of a discount object (`discountAmount` in rupees or `discountInPaise`).
  static num _discountOf(Object? m) {
    if (m is! Map) return 0;
    final rupees = _num(m['discountAmount']) ?? _num(m['discount']);
    if (rupees != null) return rupees;
    final paise = _num(m['discountInPaise']) ?? _num(m['discountAmountInPaise']);
    return paise == null ? 0 : paise / 100;
  }

  String _inr(num v) {
    final whole = v == v.roundToDouble();
    return '₹${whole ? _inrFmt.format(v.toInt()) : v.toStringAsFixed(2)}';
  }

  /// Rows: plan price, offer, coupon, total (from the server's order).
  List<(String, String, bool)> _summaryRows() {
    final o = _orderData;
    final list = PlanSubscriptionService.priceOf(widget.plan.tier, annual: widget.isAnnual);
    final base = _num(o?['baseAmount']) ?? _num(o?['originalAmount']) ?? _num(o?['listPrice']) ?? list;
    final rows = <(String, String, bool)>[
      ('${widget.plan.name} · ${widget.isAnnual ? 'Annual' : 'Monthly'}', _inr(base), false),
    ];
    final offer = o?['offer'];
    final offerOff = _discountOf(offer);
    if (offer is Map && offerOff > 0) {
      final title = offer['title']?.toString() ?? 'Offer';
      rows.add((title, '− ${_inr(offerOff)}', true));
    }
    final coupon = o?['coupon'] ?? _appliedCoupon;
    final couponOff = _discountOf(coupon);
    if (coupon is Map && couponOff > 0) {
      rows.add(('Coupon ${coupon['code'] ?? ''}'.trim(), '− ${_inr(couponOff)}', true));
    }
    final paise = _payablePaise;
    rows.add(('Total', paise >= 0 ? _inr(paise / 100) : '…', false));
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final changeNote = _service.planChangeNote(widget.plan.tier);
    final rows = _summaryRows();
    final free = _isFreeOrder;
    final total = rows.last.$2;

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(left: 20, right: 20, top: 14, bottom: MediaQuery.of(context).viewInsets.bottom + 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(color: AppTheme.border, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 16),
            if (_isSuccess) ..._successContent() else ...[
              Text(
                'Get ${widget.plan.name}',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.text, fontSize: 20, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 4),
              Text(
                'Secure UPI payment by Razorpay',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.text2, fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),

              // Order summary
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.bg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Column(
                  children: [
                    for (var i = 0; i < rows.length; i++) ...[
                      if (i == rows.length - 1) Divider(height: 18, color: AppTheme.border),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              rows[i].$1,
                              style: TextStyle(
                                color: rows[i].$3 ? AppTheme.accentText : AppTheme.text,
                                fontSize: i == rows.length - 1 ? 15 : 13,
                                fontWeight: i == rows.length - 1 ? FontWeight.w900 : FontWeight.w700,
                              ),
                            ),
                          ),
                          Text(
                            rows[i].$2,
                            style: TextStyle(
                              color: rows[i].$3 ? AppTheme.accentText : AppTheme.text,
                              fontSize: i == rows.length - 1 ? 17 : 13,
                              fontWeight: i == rows.length - 1 ? FontWeight.w900 : FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      if (i < rows.length - 1) const SizedBox(height: 6),
                    ],
                    if (changeNote != null) ...[
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            _service.isQueuedDowngrade(widget.plan.tier) ? Icons.schedule_rounded : Icons.swap_vert_circle_outlined,
                            size: 16,
                            color: AppTheme.accentText,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              changeNote,
                              style: TextStyle(color: AppTheme.accentText, fontSize: 12, fontWeight: FontWeight.w700, height: 1.3),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),

              if (_errorMessage != null) ...[
                _Banner(text: _errorMessage!, icon: Icons.info_outline_rounded, color: AppTheme.warnText),
                const SizedBox(height: 12),
              ] else if (_infoMessage != null) ...[
                _Banner(text: _infoMessage!, icon: Icons.schedule_rounded, color: AppTheme.accentText),
                const SizedBox(height: 12),
              ],

              // Coupon
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
                            enabled: _appliedCoupon == null,
                            textCapitalization: TextCapitalization.characters,
                            style: TextStyle(color: AppTheme.text, fontSize: 13, fontWeight: FontWeight.w700),
                            decoration: InputDecoration(
                              hintText: 'Coupon code',
                              hintStyle: TextStyle(color: AppTheme.text2, fontSize: 12),
                              isDense: true,
                              border: InputBorder.none,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: _isValidatingCoupon || _isLoading ? null : _applyCoupon,
                          child: _isValidatingCoupon
                              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                              : Text(
                                  _appliedCoupon != null ? 'Remove' : 'Apply',
                                  style: TextStyle(color: AppTheme.brand, fontWeight: FontWeight.w800, fontSize: 12),
                                ),
                        ),
                      ],
                    ),
                    if (_couponError != null) ...[
                      const SizedBox(height: 2),
                      Text(_couponError!, style: TextStyle(color: AppTheme.warnText, fontSize: 11)),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // 1. In the app: Razorpay SDK (UPI only), or a free pass.
              SizedBox(
                height: 56,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: free ? AppTheme.accentText : AppTheme.brand,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: _isLoading || _orderData == null ? null : (free ? _claimFreePass : _openRazorpayCheckout),
                  child: _isLoading
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(free ? Icons.card_giftcard_rounded : Icons.flash_on_rounded, size: 22, color: Colors.white),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                free ? 'Activate free pass' : 'Pay $total by UPI',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w900),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Google Pay · PhonePe · Paytm · BHIM · any UPI app',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.text2, fontSize: 11, fontWeight: FontWeight.w600),
              ),

              // 2. On the website, by UPI.
              if (!free) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(child: Divider(color: AppTheme.border)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text('or', style: TextStyle(color: AppTheme.text2, fontSize: 12)),
                    ),
                    Expanded(child: Divider(color: AppTheme.border)),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 48,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: AppTheme.brand),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _isLoading ? null : _payOnWebsite,
                    icon: Icon(Icons.language_rounded, size: 18, color: AppTheme.brand),
                    label: Text(
                      _waitingForWebPayment ? 'Open the website again' : 'Pay on the website by UPI',
                      style: TextStyle(color: AppTheme.brand, fontSize: 13, fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'The website link is valid for 30 minutes; a new one is made when needed.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.muted, fontSize: 10.5),
                ),
                if (_waitingForWebPayment) ...[
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 44,
                    child: TextButton.icon(
                      onPressed: _isLoading ? null : () => _checkWebPaymentResult(),
                      icon: Icon(Icons.refresh_rounded, size: 16, color: AppTheme.accentText),
                      label: Text(
                        'I have paid — check now',
                        style: TextStyle(color: AppTheme.accentText, fontSize: 12, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 14),
              Text(
                'Payments are processed by Razorpay. CoRoute never sees your UPI PIN.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.muted, fontSize: 10),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _successContent() {
    final queued = _service.pendingTier == widget.plan.tier && !_service.isEntitledTo(widget.plan.tier);
    return [
      const SizedBox(height: 20),
      Center(
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: AppTheme.accentText.withValues(alpha: 0.15), shape: BoxShape.circle),
          child: Icon(Icons.check_circle_rounded, color: AppTheme.accentText, size: 64),
        ),
      ),
      const SizedBox(height: 16),
      Text(
        queued ? '${widget.plan.name} booked' : '${widget.plan.name} activated',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppTheme.text, fontSize: 22, fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 8),
      Text(
        queued ? (_service.pendingPlanSummary ?? 'It starts when your current plan ends.') : 'Your features are unlocked on all your devices.',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppTheme.text2, fontSize: 13),
      ),
      const SizedBox(height: 32),
    ];
  }
}

class _Banner extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color color;

  const _Banner({required this.text, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: color, fontSize: 12, height: 1.3))),
        ],
      ),
    );
  }
}
