import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/config/feature_gates.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/plan_subscription_service.dart';
import 'plan_selector_screen.dart';
import 'subscription_expiry_banner.dart';

/// Payments & plan history: the current plan, every plan period, every
/// payment and the order ledger, all from `GET /subscription/history`.
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
    final plan = context.read<PlanSubscriptionService?>();
    if (plan == null) {
      setState(() {
        _loading = false;
        _error = 'Plan service unavailable.';
      });
      return;
    }
    setState(() {
      if (refresh) {
        _refreshing = true;
      } else {
        _loading = true;
      }
      _error = null;
    });
    try {
      final data = await plan.fetchHistory();
      if (refresh) plan.syncFromServer().ignore(); // a paid order may have settled
      if (!mounted) return;
      setState(() {
        _payments = _newestFirst(_rows(data['history']), const ['paidAt', 'validFrom']);
        _periods = _newestFirst(_rows(data['subscriptionHistory']), const ['endedAt', 'validUntil']);
        _orders = _newestFirst(_rows(data['orders']), const ['createdAt', 'paidAt']);
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
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
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
    for (final t in SubscriptionTier.values) {
      if (t.name.toLowerCase() == name.toLowerCase()) return FeatureGates.tierLabel(t);
    }
    return name.isEmpty ? 'Plan' : name;
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
    final plan = context.watch<PlanSubscriptionService?>();

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
                const SubscriptionExpiryBanner(),
                if (plan != null) _CurrentPlanCard(plan: plan, periods: _periods),
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
                  'Amounts are in Indian rupees. Payments are processed by Razorpay; a pending order settles within a few minutes of a successful UPI transfer.',
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
  final PlanSubscriptionService plan;
  final List<Map<String, dynamic>> periods;
  const _CurrentPlanCard({required this.plan, required this.periods});

  @override
  Widget build(BuildContext context) {
    final tier = plan.currentTier;
    final paid = tier != SubscriptionTier.community;
    final expired = plan.isExpired;
    final prev = plan.previousTier;
    final days = plan.daysRemaining;

    final String statusText;
    final bool warn;
    if (expired) {
      statusText = 'Expired';
      warn = true;
    } else if (paid && plan.expiringSoon) {
      statusText = 'Ends soon';
      warn = true;
    } else if (paid) {
      statusText = 'Active';
      warn = false;
    } else {
      statusText = 'Free';
      warn = false;
    }

    final validUntil = plan.validUntil > 0
        ? _PaymentHistoryScreenState._when(plan.validUntil, time: false)
        : (paid ? '—' : 'No expiry');

    return DsCard(
      radius: Radii.xl,
      accent: paid && !expired,
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
                    Text(FeatureGates.tierLabel(tier), style: AppText.title.copyWith(fontSize: 18)),
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
                  value: paid ? '$days' : '—',
                  valueColor: warn ? AppTheme.warnText : null,
                ),
              ),
            ],
          ),
          if (expired && prev != null) ...[
            const SizedBox(height: 12),
            Text(
              '${FeatureGates.tierLabel(prev)} ended ${plan.expiredAt > 0 ? 'on ${_PaymentHistoryScreenState._when(plan.expiredAt, time: false)}' : 'recently'}. '
              'Renew to get ${PlanSubscriptionService.keyFeatureSummary(prev)} back.',
              style: AppText.caption.copyWith(height: 1.35),
            ),
          ],
          if (paid || expired) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: DsButton(
                label: expired ? 'Renew ${FeatureGates.tierLabel(prev ?? tier)}' : 'Manage plan',
                icon: expired ? Icons.autorenew_rounded : Icons.tune_rounded,
                height: 48,
                fontSize: 14,
                tone: expired ? DsButtonTone.brand : DsButtonTone.outline,
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => PlanSelectorScreen(preselectTier: expired ? plan.renewTier : null)),
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
    final amount = p['amount'] is num ? p['amount'] as num : num.tryParse('${p['amount']}');
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
    final amount = paise == null ? null : paise / 100;
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
                  minimumSize: const Size(0, 44),
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
