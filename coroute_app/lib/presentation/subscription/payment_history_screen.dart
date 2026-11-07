import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/membership_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/membership_service.dart';
import 'membership_dashboard_screen.dart';

/// Payments & plan history: the current plan (membership, or a legacy plan until it ends), every
/// membership payment, and the legacy plan periods and orders from `GET /subscription/history`
/// (read-only: legacy plans are no longer sold).
class PaymentHistoryScreen extends StatefulWidget {
  const PaymentHistoryScreen({super.key});

  @override
  State<PaymentHistoryScreen> createState() => _PaymentHistoryScreenState();
}

class _PaymentHistoryScreenState extends State<PaymentHistoryScreen> {
  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  List<Map<String, dynamic>> _payments = const [];
  List<Map<String, dynamic>> _periods = const [];
  List<Map<String, dynamic>> _orders = const [];

  static final DateFormat _dateTime = DateFormat('d MMM yyyy, h:mm a');
  static final DateFormat _date = DateFormat('d MMM yyyy');

  @override
  void initState() {
    super.initState();
    _load();
  }

  static const Duration _istOffset = Duration(hours: 5, minutes: 30);

  /// Converts an epoch millisecond timestamp to a DateTime representing Asia/Kolkata (IST, UTC+05:30).
  static DateTime _kolkataDateTime(int ms) {
    final ist = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).add(_istOffset);
    return DateTime(ist.year, ist.month, ist.day, ist.hour, ist.minute, ist.second, ist.millisecond);
  }

  /// Calculates whole days remaining on a plan or membership in Asia/Kolkata timezone.
  static int _calculateDaysRemainingKolkata(int validUntilMs) {
    if (validUntilMs <= 0) return 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (validUntilMs <= nowMs) return 0;
    final diffMs = validUntilMs - nowMs;
    return (diffMs / Duration.millisecondsPerDay).ceil();
  }

  /// Stable deduplication by paymentId / orderId.
  /// If two records share an orderId or paymentId, merges them preserving richer fields.
  static List<Map<String, dynamic>> _deduplicate(List<Map<String, dynamic>> items) {
    final seenOrderIds = <String, int>{};
    final seenPaymentIds = <String, int>{};
    final result = <Map<String, dynamic>>[];

    for (final raw in items) {
      final item = Map<String, dynamic>.from(raw);
      // Normalize common field aliases so cards can render them consistently
      if (item['amount'] == null && item['amountInr'] != null) {
        item['amount'] = item['amountInr'];
      } else if (item['amountInr'] == null && item['amount'] != null) {
        item['amountInr'] = item['amount'];
      }
      if (item['amountInPaise'] == null && item['amount'] is num) {
        item['amountInPaise'] = ((item['amount'] as num) * 100).round();
      }
      if (item['planTier'] == null && item['category'] != null) {
        item['planTier'] = item['category'];
      }

      final orderId = (item['orderId']?.toString() ?? '').trim();
      final paymentId = (item['paymentId']?.toString() ?? '').trim();

      int? existingIdx;
      if (orderId.isNotEmpty && seenOrderIds.containsKey(orderId)) {
        existingIdx = seenOrderIds[orderId];
      } else if (paymentId.isNotEmpty && seenPaymentIds.containsKey(paymentId)) {
        existingIdx = seenPaymentIds[paymentId];
      }

      if (existingIdx != null) {
        // Merge into existing entry, preserving non-empty values
        final existing = result[existingIdx];
        for (final entry in item.entries) {
          final existingVal = existing[entry.key];
          final newVal = entry.value;
          if (newVal != null && (existingVal == null || existingVal == '' || existingVal == 0)) {
            existing[entry.key] = newVal;
          }
        }
        if (orderId.isNotEmpty) seenOrderIds[orderId] = existingIdx;
        if (paymentId.isNotEmpty) seenPaymentIds[paymentId] = existingIdx;
      } else {
        final idx = result.length;
        result.add(item);
        if (orderId.isNotEmpty) seenOrderIds[orderId] = idx;
        if (paymentId.isNotEmpty) seenPaymentIds[paymentId] = idx;
      }
    }

    return result;
  }

  static List<Map<String, dynamic>> _rows(dynamic list) {
    if (list is! List) return const [];
    return list.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
  }

  static int _epoch(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) {
      final n = int.tryParse(v);
      if (n != null) return n;
      final d = DateTime.tryParse(v);
      if (d != null) return d.millisecondsSinceEpoch;
    }
    return 0;
  }

  /// Newest first by the given time fields (first non-zero wins).
  static List<Map<String, dynamic>> _newestFirst(List<Map<String, dynamic>> rows, List<String> keys) {
    int at(Map<String, dynamic> r) {
      for (final k in keys) {
        final t = _epoch(r[k]);
        if (t > 0) return t;
      }
      return 0;
    }

    final out = List<Map<String, dynamic>>.from(rows);
    out.sort((a, b) => at(b).compareTo(at(a)));
    return out;
  }

  Future<void> _load({bool refresh = false}) async {
    final api = context.read<ApiClient?>();
    final mem = context.read<MembershipService?>();
    setState(() {
      if (refresh) {
        _refreshing = true;
      } else {
        _loading = true;
      }
      _error = null;
    });
    try {
      Map<String, dynamic> data = const {};
      if (api != null) {
        // Legacy plan periods and orders (old purchases stay visible, read-only).
        try {
          final res = await api.get('/subscription/history');
          if (res is Map) data = Map<String, dynamic>.from(res);
        } catch (_) {}
      }
      List<Map<String, dynamic>> memOrders = const [];
      if (mem != null) {
        try {
          mem.fetchMyMembership().ignore();
          final items = await mem.fetchPaymentHistory();
          memOrders = items.map((m) => {
            'orderId': m.orderId,
            'paymentId': m.paymentId,
            'amount': m.amountInr,
            'amountInr': m.amountInr,
            'amountInPaise': (m.amountInr * 100).round(),
            'planTier': m.category,
            'status': m.status,
            'isFree': m.isFree,
            'couponCode': m.offerCode,
            'createdAt': m.createdAt,
            'paidAt': m.paidAt,
            'refundStatus': m.refundStatus,
            'refundedAmount': m.refundedAmount,
          }).toList();
        } catch (_) {}
      }
      if (!mounted) return;
      final combinedOrders = [
        ...memOrders,
        ..._rows(data['orders']),
      ];
      final combinedPayments = [
        ...memOrders.where((m) => (m['status']?.toString().toUpperCase()) == 'PAID'),
        ..._rows(data['history']),
        ..._rows(data['orders']).where((o) => (o['status']?.toString().toUpperCase()) == 'PAID'),
      ];

      final dedupedOrders = _deduplicate(_newestFirst(combinedOrders, const ['createdAt', 'paidAt']));
      final dedupedPayments = _deduplicate(_newestFirst(combinedPayments, const ['paidAt', 'createdAt', 'validFrom']));
      final dedupedPeriods = _newestFirst(_rows(data['subscriptionHistory']), const ['endedAt', 'validUntil']);

      setState(() {
        _payments = dedupedPayments;
        _periods = dedupedPeriods;
        _orders = dedupedOrders;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not load your payment history. Check your connection and try again.');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _refreshing = false;
        });
      }
    }
  }

  static String _when(dynamic v, {bool time = true}) {
    final ms = _epoch(v);
    if (ms <= 0) return '—';
    final d = _kolkataDateTime(ms);
    return (time ? _dateTime : _date).format(d);
  }

  static String _rupees(num? amount) {
    if (amount == null) return '₹—';
    final whole = amount == amount.roundToDouble();
    final s = whole ? amount.toInt().toString() : amount.toStringAsFixed(2);
    return '₹$s';
  }

  static String _tierName(dynamic v) {
    final name = v?.toString() ?? '';
    if (name.isEmpty) return 'Plan';
    switch (name.toLowerCase()) {
      case 'individual':
        return 'Legacy plan (Individual)';
      case 'group_small':
        return 'Small Group (2–6)';
      case 'group_large':
        return 'Large Group (7–12)';
      case 'prorider':
        return 'Legacy plan (CoRoute Pro)';
      case 'roadcaptain':
        return 'Legacy plan (Road Captain)';
      case 'touroperator':
        return 'Legacy plan (Tour Operator)';
      case 'community':
        return 'Community (free)';
    }
    return name.replaceAll('_', ' ').toUpperCase();
  }

  static String _cycle(dynamic v) {
    final c = v?.toString().toLowerCase() ?? '';
    if (c == 'annual' || c == 'yearly') return 'Annual';
    if (c == 'monthly') return 'Monthly';
    return c.isEmpty ? '' : c[0].toUpperCase() + c.substring(1);
  }

  static bool _isTest(dynamic mode) => mode?.toString().toLowerCase() == 'test';

  static num? _numOf(dynamic v) => v is num ? v : num.tryParse('${v ?? ''}');

  /// Refund of a payment or order: (rupees refunded, whole amount?), null when none.
  /// Reads `refundedAmount` (rupees) or `refundedAmountInPaise`, `fullyRefunded`,
  /// and `refundStatus` (PROCESSED / PENDING) or a REFUNDED `status`.
  static (num, bool)? _refundOf(Map<String, dynamic> m, num? amount) {
    final status = (m['refundStatus'] ?? m['status'] ?? '').toString().toUpperCase();
    final paise = _numOf(m['refundedAmountInPaise']) ?? _numOf(m['refundAmountInPaise']);
    final rupees = _numOf(m['refundedAmount']) ?? _numOf(m['refundAmount']) ?? (paise == null ? null : paise / 100);
    final flagged = status.contains('REFUND') || m['refunded'] == true;
    if ((rupees == null || rupees <= 0) && !flagged) return null;
    final partial = status.contains('PARTIAL');
    final full = m['fullyRefunded'] == true ||
        (!partial && (status == 'REFUNDED' || status == 'FULL' || rupees == null || (amount != null && amount > 0 && rupees >= amount)));
    return (rupees ?? amount ?? 0, full);
  }

  static bool _isPendingOrder(String status) =>
      status == 'CREATED' || status == 'UTR_CLAIMED' || status == 'PENDING' || status == 'ATTEMPTED';

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label copied')));
  }

  @override
  Widget build(BuildContext context) {
    final mem = context.watch<MembershipService?>();

    Widget body;
    if (_loading) {
      body = const LoadingSpinner();
    } else if (_error != null && _payments.isEmpty && _periods.isEmpty && _orders.isEmpty) {
      body = EmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Could not load history',
        message: _error,
        primaryLabel: 'Try again',
        onPrimary: () => _load(),
      );
    } else {
      body = RefreshIndicator(
        onRefresh: () => _load(refresh: true),
        color: AppTheme.brand,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
              children: [
                if (mem != null) _CurrentPlanCard(mem: mem, periods: _periods),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  DsCard(
                    warning: true,
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: AppTheme.warnText, size: 18),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_error!, style: AppText.caption.copyWith(color: AppTheme.warnText))),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 20),
                const DsSectionHeader('Plan periods'),
                const SizedBox(height: 10),
                if (_periods.isEmpty)
                  const _EmptyRow(icon: Icons.history_toggle_off_rounded, text: 'No past plan periods yet.')
                else
                  DsCard(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Column(
                      children: [
                        for (var i = 0; i < _periods.length; i++)
                          _PeriodRow(period: _periods[i], divider: i < _periods.length - 1),
                      ],
                    ),
                  ),

                const SizedBox(height: 20),
                const DsSectionHeader('Payments'),
                const SizedBox(height: 10),
                if (_payments.isEmpty)
                  const _EmptyRow(icon: Icons.receipt_long_rounded, text: 'No payments yet. Upgrades paid via UPI show up here.')
                else
                  for (var i = 0; i < _payments.length; i++) ...[
                    _PaymentCard(payment: _payments[i], onCopy: _copy),
                    if (i < _payments.length - 1) const SizedBox(height: 10),
                  ],

                const SizedBox(height: 20),
                DsSectionHeader(
                  'Orders',
                  trailing: _refreshing
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : null,
                ),
                const SizedBox(height: 10),
                if (_orders.isEmpty)
                  const _EmptyRow(icon: Icons.list_alt_rounded, text: 'No orders on this account.')
                else
                  for (var i = 0; i < _orders.length; i++) ...[
                    _OrderCard(
                      order: _orders[i],
                      checking: _refreshing,
                      onCheckStatus: () => _load(refresh: true),
                      onCopy: _copy,
                    ),
                    if (i < _orders.length - 1) const SizedBox(height: 10),
                  ],
                const SizedBox(height: 20),
                Text(
                  'Amounts in rupees. Paid via Razorpay. Pending payments clear in a few minutes.',
                  style: AppText.caption.copyWith(height: 1.4),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: DsScreenHeader(
                    title: 'Payments & plan history',
                    onBack: () => Navigator.maybePop(context),
                    trailing: DsRoundButton(
                      icon: Icons.refresh_rounded,
                      label: 'Refresh',
                      onTap: () {
                        if (!_loading && !_refreshing) _load(refresh: true);
                      },
                    ),
                  ),
                ),
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

class _CurrentPlanCard extends StatelessWidget {
  final MembershipService? mem;
  final List<Map<String, dynamic>> periods;
  const _CurrentPlanCard({this.mem, required this.periods});

  @override
  Widget build(BuildContext context) {
    final owned = mem?.ownedMembership;

    final participating = mem?.participating ?? const [];
    final activeParticipating = participating.where((m) => m.isActive).toList();

    String planName;
    int validUntilMs = 0;
    int daysRemaining = 0;
    bool isPaid = false;
    bool isExpired = false;
    bool isExpiringSoon = false;
    String? previousPlanName;
    int expiredAtMs = 0;
    bool isParticipatingMember = false;

    if (owned != null && owned.isActive) {
      planName = owned.name;
      validUntilMs = owned.validUntil;
      daysRemaining = _PaymentHistoryScreenState._calculateDaysRemainingKolkata(validUntilMs);
      isPaid = true;
      isExpired = false;
      isExpiringSoon = daysRemaining > 0 && daysRemaining <= 7;
    } else if (activeParticipating.isNotEmpty) {
      final part = (List<UserMembership>.from(activeParticipating)
            ..sort((a, b) => b.validUntil.compareTo(a.validUntil)))
          .first;
      planName = part.name;
      validUntilMs = part.validUntil;
      daysRemaining = _PaymentHistoryScreenState._calculateDaysRemainingKolkata(validUntilMs);
      isPaid = true;
      isExpired = false;
      isExpiringSoon = daysRemaining > 0 && daysRemaining <= 7;
      isParticipatingMember = true;
    } else if (mem?.planAccess.isLegacy == true) {
      // A legacy plan bought before the membership plans: kept until its end date.
      final access = mem!.planAccess;
      planName = '${access.name} (legacy)';
      validUntilMs = access.validUntil;
      daysRemaining = _PaymentHistoryScreenState._calculateDaysRemainingKolkata(validUntilMs);
      isPaid = true;
      isExpired = false;
      isExpiringSoon = daysRemaining > 0 && daysRemaining <= 7;
    } else if (owned != null && (owned.isExpired || owned.status == 'EXPIRED')) {
      planName = owned.name;
      validUntilMs = owned.validUntil;
      daysRemaining = 0;
      isPaid = false;
      isExpired = true;
      isExpiringSoon = false;
      previousPlanName = owned.name;
      expiredAtMs = owned.validUntil;
    } else {
      planName = 'No plan';
      validUntilMs = 0;
      daysRemaining = 0;
      isPaid = false;
      isExpired = false;
      isExpiringSoon = false;
    }

    final String statusText;
    final bool warn;
    if (isExpired) {
      statusText = 'Expired';
      warn = true;
    } else if (isPaid && isExpiringSoon) {
      statusText = 'Ends soon';
      warn = true;
    } else if (isPaid) {
      statusText = isParticipatingMember ? 'Active (Member)' : 'Active';
      warn = false;
    } else {
      statusText = 'Free';
      warn = false;
    }

    final validUntil = validUntilMs > 0
        ? _PaymentHistoryScreenState._when(validUntilMs, time: false)
        : (isPaid ? '—' : 'No expiry');

    return DsCard(
      radius: Radii.xl,
      accent: isPaid && !isExpired,
      warning: warn,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: AppTheme.tint, borderRadius: BorderRadius.circular(12)),
                child: Icon(Icons.card_membership_rounded, color: AppTheme.accentText, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Current plan', style: AppText.overline),
                    const SizedBox(height: 2),
                    Text(planName, style: AppText.title.copyWith(fontSize: 18)),
                  ],
                ),
              ),
              DsChip(statusText, warning: warn),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: DsStatCell(label: 'Valid until', value: validUntil)),
              const SizedBox(width: 8),
              Expanded(
                child: DsStatCell(
                  label: 'Days left',
                  value: isPaid ? '$daysRemaining' : '—',
                  valueColor: warn ? AppTheme.warnText : null,
                ),
              ),
            ],
          ),
          if (isExpired && previousPlanName != null) ...[
            const SizedBox(height: 12),
            Text(
              '$previousPlanName ended ${expiredAtMs > 0 ? 'on ${_PaymentHistoryScreenState._when(expiredAtMs, time: false)}' : 'recently'}. '
              'Renew to get your group seats back.',
              style: AppText.caption.copyWith(height: 1.35),
            ),
          ],
          if (isPaid || isExpired) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: DsButton(
                label: isExpired
                    ? 'Renew ${previousPlanName ?? planName}'
                    : (isParticipatingMember ? 'View plans' : 'Manage plan'),
                icon: isExpired ? Icons.autorenew_rounded : Icons.tune_rounded,
                height: 48,
                fontSize: 14,
                tone: isExpired ? DsButtonTone.brand : DsButtonTone.outline,
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const MembershipDashboardScreen()),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PeriodRow extends StatelessWidget {
  final Map<String, dynamic> period;
  final bool divider;
  const _PeriodRow({required this.period, required this.divider});

  @override
  Widget build(BuildContext context) {
    final tier = _PaymentHistoryScreenState._tierName(period['tier']);
    final reason = period['reason']?.toString() ?? '';
    final endedAt = _PaymentHistoryScreenState._epoch(period['endedAt']);
    final validUntil = _PaymentHistoryScreenState._epoch(period['validUntil']);
    final ended = endedAt > 0 ? _PaymentHistoryScreenState._when(endedAt, time: false) : null;
    final until = validUntil > 0 ? _PaymentHistoryScreenState._when(validUntil, time: false) : null;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Icon(Icons.history_rounded, size: 20, color: AppTheme.muted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tier, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (until != null) 'Valid until $until',
                        if (ended != null) 'Ended $ended',
                      ].join(' · '),
                      style: AppText.caption,
                    ),
                  ],
                ),
              ),
              if (reason.isNotEmpty) ...[
                const SizedBox(width: 8),
                DsChip(_reasonLabel(reason), warning: RegExp('expir|refund|revok').hasMatch(reason.toLowerCase())),
              ],
            ],
          ),
        ),
        if (divider) Divider(height: 1, color: AppTheme.border2),
      ],
    );
  }

  static String _reasonLabel(String reason) {
    final r = reason.toLowerCase();
    if (r.contains('expir')) return 'Expired';
    if (r.contains('refund')) return 'Refunded';
    if (r.contains('revok')) return 'Ended by support';
    if (r.contains('upgrade')) return 'Upgraded';
    if (r.contains('renew')) return 'Renewed';
    if (r.contains('cancel')) return 'Cancelled';
    return reason.replaceAll('_', ' ');
  }
}

class _PaymentCard extends StatelessWidget {
  final Map<String, dynamic> payment;
  final Future<void> Function(String label, String value) onCopy;
  const _PaymentCard({required this.payment, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    final p = payment;
    final amount = p['amount'] is num
        ? p['amount'] as num
        : (p['amountInr'] is num ? p['amountInr'] as num : num.tryParse('${p['amount'] ?? p['amountInr']}'));
    final plan = _PaymentHistoryScreenState._tierName(p['planTier']);
    final cycle = _PaymentHistoryScreenState._cycle(p['billingCycle']);
    final method = (p['method']?.toString() ?? '').toUpperCase();
    final paymentId = p['paymentId']?.toString() ?? '';
    final orderId = p['orderId']?.toString() ?? '';
    final source = p['source']?.toString() ?? '';
    final test = _PaymentHistoryScreenState._isTest(p['mode']);
    final validFrom = _PaymentHistoryScreenState._epoch(p['validFrom']);
    final validUntil = _PaymentHistoryScreenState._epoch(p['validUntil']);
    final refund = _PaymentHistoryScreenState._refundOf(p, amount);

    return DsCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_PaymentHistoryScreenState._when(p['paidAt']), style: AppText.caption),
              ),
              if (test) const DsChip('Test', warning: true),
              if (test) const SizedBox(width: 6),
              if (refund != null) ...[
                DsChip(refund.$2 ? 'Refunded' : 'Partly refunded', color: AppTheme.warnText, background: AppTheme.warnTint),
                const SizedBox(width: 6),
              ],
              Text(
                _PaymentHistoryScreenState._rupees(amount),
                style: AppText.title.copyWith(
                  fontSize: 18,
                  color: refund != null && refund.$2 ? AppTheme.muted : AppTheme.accentText,
                  decoration: refund != null && refund.$2 ? TextDecoration.lineThrough : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            [plan, if (cycle.isNotEmpty) cycle, if (method.isNotEmpty) method].join(' · '),
            style: AppText.body.copyWith(fontWeight: FontWeight.w700),
          ),
          if (validFrom > 0 || validUntil > 0) ...[
            const SizedBox(height: 2),
            Text(
              'Covers ${_PaymentHistoryScreenState._when(validFrom, time: false)} → ${_PaymentHistoryScreenState._when(validUntil, time: false)}',
              style: AppText.caption,
            ),
          ],
          if (refund != null) ...[
            const SizedBox(height: 4),
            Text(
              [
                'Refunded ${_PaymentHistoryScreenState._rupees(refund.$1)}',
                if (_PaymentHistoryScreenState._epoch(p['refundedAt']) > 0) 'on ${_PaymentHistoryScreenState._when(p['refundedAt'], time: false)}',
                if (refund.$2) '· plan ended',
              ].join(' '),
              style: AppText.caption.copyWith(color: AppTheme.warnText, fontWeight: FontWeight.w700),
            ),
          ],
          if (paymentId.isNotEmpty) ...[
            const SizedBox(height: 8),
            _CopyRow(label: 'Payment ID', value: paymentId, onCopy: onCopy),
          ],
          if (orderId.isNotEmpty) _CopyRow(label: 'Order', value: orderId, onCopy: onCopy),
          if (source.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Source: $source', style: AppText.caption),
          ],
        ],
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  final Map<String, dynamic> order;
  final bool checking;
  final VoidCallback onCheckStatus;
  final Future<void> Function(String label, String value) onCopy;
  const _OrderCard({required this.order, required this.checking, required this.onCheckStatus, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    final o = order;
    final status = (o['status']?.toString() ?? '').toUpperCase();
    final pending = _PaymentHistoryScreenState._isPendingOrder(status);
    final paid = status == 'PAID' || status == 'VERIFIED' || status == 'SUCCESS';
    final failed = status == 'FAILED' || status == 'EXPIRED' || status == 'CANCELLED' || status == 'REJECTED';
    final paise = o['amountInPaise'] is num ? (o['amountInPaise'] as num) : num.tryParse('${o['amountInPaise']}');
    final amount = paise != null
        ? paise / 100
        : (o['amount'] is num
            ? o['amount'] as num
            : (o['amountInr'] is num ? o['amountInr'] as num : num.tryParse('${o['amount'] ?? o['amountInr']}')));
    final plan = _PaymentHistoryScreenState._tierName(o['planTier']);
    final cycle = _PaymentHistoryScreenState._cycle(o['billingCycle']);
    final orderId = o['orderId']?.toString() ?? '';
    final paymentId = o['paymentId']?.toString() ?? '';
    final test = _PaymentHistoryScreenState._isTest(o['mode']);

    final chipColor = paid
        ? AppTheme.accentText
        : failed
            ? AppTheme.sos
            : AppTheme.warnText;
    final chipBg = paid
        ? AppTheme.tint
        : failed
            ? AppTheme.sos.withValues(alpha: 0.12)
            : AppTheme.warnTint;

    return DsCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(_PaymentHistoryScreenState._when(o['createdAt']), style: AppText.caption)),
              if (test) const DsChip('Test', warning: true),
              if (test) const SizedBox(width: 6),
              DsChip(_statusLabel(status), color: chipColor, background: chipBg),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  [plan, if (cycle.isNotEmpty) cycle].join(' · '),
                  style: AppText.body.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Text(_PaymentHistoryScreenState._rupees(amount), style: AppText.title.copyWith(fontSize: 16)),
            ],
          ),
          if (_PaymentHistoryScreenState._refundOf(o, amount) case final r?) ...[
            const SizedBox(height: 2),
            Text(
              '${r.$2 ? 'Refunded' : 'Partly refunded'}: ${_PaymentHistoryScreenState._rupees(r.$1)}',
              style: AppText.caption.copyWith(color: AppTheme.warnText, fontWeight: FontWeight.w700),
            ),
          ],
          if (paid && _PaymentHistoryScreenState._epoch(o['paidAt']) > 0) ...[
            const SizedBox(height: 2),
            Text('Paid ${_PaymentHistoryScreenState._when(o['paidAt'])}', style: AppText.caption),
          ],
          const SizedBox(height: 8),
          if (orderId.isNotEmpty) _CopyRow(label: 'Order', value: orderId, onCopy: onCopy),
          if (paymentId.isNotEmpty) _CopyRow(label: 'Payment ID', value: paymentId, onCopy: onCopy),
          if (pending) ...[
            const SizedBox(height: 8),
            Text(
              status == 'UTR_CLAIMED'
                  ? 'UPI reference submitted — waiting for the bank to confirm.'
                  : 'Waiting for payment. If you already paid, check again in a minute.',
              style: AppText.caption.copyWith(height: 1.35),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: checking ? null : onCheckStatus,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.accentText,
                  side: BorderSide(color: AppTheme.accentText),
                  minimumSize: const Size(0, 48),
                  shape: const RoundedRectangleBorder(borderRadius: Radii.mdAll),
                ),
                icon: checking
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh_rounded, size: 18),
                label: Text(checking ? 'Checking…' : 'Check status'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _statusLabel(String status) {
    switch (status) {
      case 'CREATED':
        return 'Awaiting payment';
      case 'UTR_CLAIMED':
        return 'Confirming';
      case 'PAID':
      case 'VERIFIED':
      case 'SUCCESS':
        return 'Paid';
      case 'REFUNDED':
        return 'Refunded';
      case 'PARTIALLY_REFUNDED':
        return 'Partly refunded';
      case '':
        return 'Unknown';
      default:
        return status.replaceAll('_', ' ');
    }
  }
}

class _CopyRow extends StatelessWidget {
  final String label;
  final String value;
  final Future<void> Function(String label, String value) onCopy;
  const _CopyRow({required this.label, required this.value, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onCopy(label, value),
      borderRadius: Radii.smAll,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Text('$label: ', style: AppText.caption),
            Expanded(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(color: AppTheme.text, fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.copy_rounded, size: 14, color: AppTheme.muted),
          ],
        ),
      ),
    );
  }
}

class _EmptyRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _EmptyRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return DsCard(
      dashed: true,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppTheme.muted),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: AppText.caption)),
        ],
      ),
    );
  }
}
