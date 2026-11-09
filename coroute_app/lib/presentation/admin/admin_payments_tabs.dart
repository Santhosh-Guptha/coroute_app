import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import 'admin_payments_logic.dart';
import 'admin_payments_widgets.dart';
import 'admin_ui.dart';

// The Payments tab of Payments: every payment, its details and refunds.

String _query(Map<String, String?> params) {
  final clean = <String, String>{
    for (final e in params.entries)
      if (e.value != null && e.value!.isNotEmpty) e.key: e.value!,
  };
  return clean.isEmpty ? '' : '?${Uri(queryParameters: clean).query}';
}

/// Amount of a payment in paise (`amountInPaise`, else `amount` rupees).
num? _paymentPaise(Map p) {
  final paise = adminNumOrNull(p['amountInPaise']);
  if (paise != null) return paise;
  final rupees = adminNumOrNull(p['amount']);
  return rupees == null ? null : rupees * 100;
}

/// Already refunded, in paise.
num _refundedPaise(Map p) {
  final paise = adminPickNum(p, const ['refundedAmountInPaise', 'refundedInPaise', 'amountRefundedInPaise']);
  if (paise != null) return paise;
  final rupees = adminPickNum(p, const ['refundedAmount', 'refundAmount']);
  return rupees == null ? 0 : rupees * 100;
}

/// Display name of a row: its own name / email, or the joined `user` object of a payment.
String _who(Map m) {
  final user = m['user'];
  for (final source in [if (user is Map) user, m]) {
    for (final k in const ['name', 'userName', 'email', 'userEmail', 'callsign', 'phone']) {
      final v = source[k]?.toString() ?? '';
      if (v.isNotEmpty) return v;
    }
  }
  final id = m['userId']?.toString() ?? '';
  return id.isEmpty ? 'Unknown rider' : id;
}

// ======================================================================
// Payments
// ======================================================================

class _PaymentRow extends StatelessWidget {
  final Map<String, dynamic> payment;
  final bool last;
  final VoidCallback onTap;
  const _PaymentRow({super.key, required this.payment, required this.onTap, this.last = false});

  @override
  Widget build(BuildContext context) {
    final p = payment;
    final status = (p['status']?.toString() ?? '').toUpperCase();
    final refunded = _refundedPaise(p);
    return AdminRow(
      leading: AdminRowIcon(Icons.receipt_long_rounded, color: _statusColor(status) == AppTheme.sos ? AppTheme.sos : null),
      title: '${adminInrPaise(_paymentPaise(p))} · ${adminTierLabel(p['planTier'])} ${adminCycleLabel(p['billingCycle'])}',
      subtitle: '${_who(p)} · ${adminDate(p['paidAt'] ?? p['createdAt'], time: true)}',
      detail: p['orderId']?.toString(),
      status: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          AdminModeBadge(adminPaymentModeBadge(p)),
          if (status.isNotEmpty) StatusTextChip(icon: _statusIcon(status), text: _statusLabel(status), color: _statusColor(status)),
          if (refunded > 0 && !status.contains('REFUND'))
            StatusTextChip(icon: Icons.undo_rounded, text: 'Refunded ${adminInrPaise(refunded)}', color: AppTheme.warnText),
        ],
      ),
      divider: !last,
      onTap: onTap,
    );
  }
}

bool _isPaidStatus(String s) => s == 'PAID' || s == 'VERIFIED' || s == 'SUCCESS' || s == 'CAPTURED';

String _statusLabel(String s) {
  if (_isPaidStatus(s)) return 'Paid';
  switch (s) {
    case 'SIGNATURE_MISMATCH':
      return 'Signature failed';
    case 'REFUNDED':
      return 'Refunded';
    case 'PARTIALLY_REFUNDED':
      return 'Part refunded';
    case 'FAILED':
      return 'Failed';
    case 'CREATED':
      return 'Not paid';
    default:
      return adminCapitalize(s.toLowerCase().replaceAll('_', ' '));
  }
}

IconData _statusIcon(String s) {
  if (s.contains('REFUND')) return Icons.undo_rounded;
  if (s == 'FAILED' || s == 'SIGNATURE_MISMATCH') return Icons.error_outline_rounded;
  if (s == 'CREATED') return Icons.hourglass_empty_rounded;
  return Icons.check_circle_rounded;
}

Color _statusColor(String s) {
  if (s.contains('REFUND')) return AppTheme.warnText;
  if (s == 'FAILED' || s == 'SIGNATURE_MISMATCH') return AppTheme.sos;
  if (s == 'CREATED') return AppTheme.text2;
  return AppTheme.accentText;
}

/// Payment detail with refund. Resolves true when something changed.
Future<bool> showAdminPaymentSheet(BuildContext context, Map<String, dynamic> payment) async {
  final changed = await showAppSheet<bool>(
    context,
    isScrollControlled: true,
    title: 'Payment',
    builder: (_) => _PaymentDetailSheet(payment: payment),
  );
  return changed == true;
}

class _PaymentDetailSheet extends StatefulWidget {
  final Map<String, dynamic> payment;
  const _PaymentDetailSheet({required this.payment});

  @override
  State<_PaymentDetailSheet> createState() => _PaymentDetailSheetState();
}

class _PaymentDetailSheetState extends State<_PaymentDetailSheet> {
  bool _busy = false;

  Future<void> _refund() async {
    final p = widget.payment;
    final orderId = p['orderId']?.toString() ?? '';
    final total = _paymentPaise(p) ?? 0;
    final already = _refundedPaise(p);
    final remaining = total - already;
    if (orderId.isEmpty || remaining <= 0) return;
    final req = await showDialog<_RefundRequest>(
      context: context,
      builder: (_) => _RefundDialog(remainingPaise: remaining, plan: adminTierLabel(p['planTier'])),
    );
    if (req == null || !mounted) return;
    final amount = req.amountInPaise;
    final full = amount == null || amount >= remaining;
    final ok = await confirmAction(
      context,
      title: full ? 'Refund ${adminInrPaise(remaining)} in full?' : 'Refund ${adminInrPaise(amount)}?',
      message: full
          ? 'Razorpay returns the money to ${_who(p)}. A full refund ends their ${adminTierLabel(p['planTier'])} right away: '
              'they are told it was refunded and go back to Community. This cannot be undone.'
          : 'Razorpay returns part of the money to ${_who(p)}. Their plan stays active. This cannot be undone.',
      confirmLabel: 'Refund',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.read<ApiClient>().post('/admin/payments/$orderId/refund', {
        if (!full) 'amountInPaise': amount,
        'reason': req.reason,
      });
      if (!mounted) return;
      adminSnack(context, full ? 'Refunded in full. The plan has ended.' : 'Partial refund sent.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      adminSnack(context, adminErrorOf(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.payment;
    final status = (p['status']?.toString() ?? '').toUpperCase();
    final badge = adminPaymentModeBadge(p);
    final total = _paymentPaise(p);
    final refunded = _refundedPaise(p);
    final refundable = badge != 'MANUAL' && (_isPaidStatus(status) || status == 'PARTIALLY_REFUNDED') && (total ?? 0) - refunded > 0;
    final couponRaw = p['coupon'];
    final coupon = p['couponCode'] ?? (couponRaw is Map ? couponRaw['code'] : couponRaw);
    final offerRaw = p['offer'];
    final offer = offerRaw is Map ? offerRaw['title'] : p['offerTitle'];
    String txt(Object? v) => v?.toString() ?? '';
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(spacing: 6, runSpacing: 4, children: [
            AdminModeBadge(badge),
            if (status.isNotEmpty) StatusTextChip(icon: _statusIcon(status), text: _statusLabel(status), color: _statusColor(status)),
          ]),
          const SizedBox(height: 10),
          AdminDetailLine('Amount', adminInrPaise(total)),
          if (refunded > 0) AdminDetailLine('Refunded', adminInrPaise(refunded), color: AppTheme.warnText),
          AdminDetailLine('Rider', _who(p)),
          if (txt(p['userId']).isNotEmpty) AdminDetailLine('User ID', txt(p['userId'])),
          AdminDetailLine('Plan', '${adminTierLabel(p['planTier'])} · ${adminCycleLabel(p['billingCycle'])}'),
          AdminDetailLine('Order ID', txt(p['orderId']).isEmpty ? '—' : txt(p['orderId'])),
          if (txt(p['paymentId']).isNotEmpty) AdminDetailLine('Payment ID', txt(p['paymentId'])),
          AdminDetailLine('Created', adminDate(p['createdAt'], time: true)),
          if (adminEpoch(p['paidAt']) > 0) AdminDetailLine('Paid', adminDate(p['paidAt'], time: true)),
          if (adminEpoch(p['refundedAt']) > 0) AdminDetailLine('Refunded at', adminDate(p['refundedAt'], time: true)),
          if (adminEpoch(p['validUntil']) > 0) AdminDetailLine('Covers', '${adminDate(p['validFrom'])} → ${adminDate(p['validUntil'])}'),
          if (txt(coupon).isNotEmpty) AdminDetailLine('Coupon', txt(coupon)),
          if (txt(offer).isNotEmpty) AdminDetailLine('Offer', txt(offer)),
          if (txt(p['method']).isNotEmpty) AdminDetailLine('Method', txt(p['method']).toUpperCase()),
          if (txt(p['error']).isNotEmpty) AdminDetailLine('Error', txt(p['error']), color: AppTheme.sos),
          const SizedBox(height: 16),
          if (refundable)
            DsButton(
              label: _busy ? 'Refunding…' : 'Refund',
              icon: Icons.undo_rounded,
              tone: DsButtonTone.sos,
              onPressed: _busy ? null : _refund,
            )
          else if (badge == 'MANUAL')
            Text('A manual grant has no Razorpay payment to refund. Change the plan from the rider\'s details instead.', style: AppText.caption),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _RefundRequest {
  /// Null for a full refund.
  final int? amountInPaise;
  final String reason;
  const _RefundRequest(this.amountInPaise, this.reason);
}

class _RefundDialog extends StatefulWidget {
  final num remainingPaise;
  final String plan;
  const _RefundDialog({required this.remainingPaise, required this.plan});

  @override
  State<_RefundDialog> createState() => _RefundDialogState();
}

class _RefundDialogState extends State<_RefundDialog> {
  bool _full = true;
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    int? paise;
    if (!_full) {
      paise = adminRupeesToPaise(_amount.text);
      if (paise == null) {
        setState(() => _problem = 'Enter an amount in rupees, like 99 or 99.50.');
        return;
      }
      if (paise > widget.remainingPaise) {
        setState(() => _problem = 'At most ${adminInrPaise(widget.remainingPaise)} can still be refunded.');
        return;
      }
    }
    if (_reason.text.trim().length < 3) {
      setState(() => _problem = 'Give a short reason (kept in the audit log).');
      return;
    }
    Navigator.of(context).pop(_RefundRequest(paise, _reason.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final p = _problem;
    return AlertDialog(
      backgroundColor: AppTheme.card,
      title: Text('Refund payment', style: AppText.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Full'), icon: Icon(Icons.undo_rounded)),
                ButtonSegment(value: false, label: Text('Partial'), icon: Icon(Icons.call_split_rounded)),
              ],
              selected: {_full},
              onSelectionChanged: (v) => setState(() {
                _full = v.first;
                _problem = null;
              }),
            ),
            const SizedBox(height: 10),
            Text(
              _full
                  ? 'Refunds ${adminInrPaise(widget.remainingPaise)} and ends the ${widget.plan} right away.'
                  : 'Refunds part of the payment. The plan stays active.',
              style: AppText.caption.copyWith(color: _full ? AppTheme.sos : AppTheme.text2, fontWeight: FontWeight.w600),
            ),
            if (!_full) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: adminInput('Amount', prefix: '₹ ', helper: 'Up to ${adminInrPaise(widget.remainingPaise)}'),
              ),
            ],
            const SizedBox(height: 12),
            TextField(controller: _reason, decoration: adminInput('Reason')),
            if (p != null) ...[
              const SizedBox(height: 8),
              Text(p, style: AppText.caption.copyWith(color: AppTheme.sos, fontWeight: FontWeight.w600)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(style: FilledButton.styleFrom(backgroundColor: AppTheme.sos), onPressed: _submit, child: const Text('Continue')),
      ],
    );
  }
}

/// `GET /admin/payments?status=&mode=&plan=&q=&limit=&offset=`, with refunds and CSV export.
class AdminPaymentsListTab extends StatefulWidget {
  const AdminPaymentsListTab({super.key});

  @override
  State<AdminPaymentsListTab> createState() => _AdminPaymentsListTabState();
}

class _AdminPaymentsListTabState extends State<AdminPaymentsListTab> with AutomaticKeepAliveClientMixin {
  static const int _pageSize = 50;
  final List<Map<String, dynamic>> _rows = [];
  int _total = 0;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  bool _loaded = false;
  bool _exporting = false;
  String? _error;
  String _status = '';
  String _mode = '';
  String _userId = '';
  String _plan = '';
  Timer? _debounce;
  int _generation = 0;

  /// Plan filter options from the server (subscription tiers and membership plans).
  List<(String, String)> _plans = const [('', 'Any plan')];

  static const List<(String, String)> _statuses = [
    ('', 'Any status'),
    ('paid', 'Paid'),
    ('refunded', 'Refunded'),
    ('partially_refunded', 'Part refunded'),
    ('failed', 'Failed'),
    ('signature_mismatch', 'Signature failed'),
    ('created', 'Not paid'),
  ];
  static const List<(String, String)> _modes = [
    ('', 'Any mode'),
    ('live', 'Live'),
    ('test', 'Test'),
    ('manual', 'Manual'),
  ];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    _loadPlans();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadPlans() async {
    try {
      final res = await context.read<ApiClient>().get('/admin/coupons/plan-options');
      final list = adminMapList(res is Map ? res['plans'] : null);
      if (!mounted || list.isEmpty) return;
      setState(() {
        _plans = [
          ('', 'Any plan'),
          for (final p in list)
            if ((p['id']?.toString() ?? '').isNotEmpty) (p['id'].toString(), p['label']?.toString() ?? p['id'].toString()),
        ];
      });
    } catch (_) {
      // The plan filter stays at "Any plan"; the list still works.
    }
  }

  // `q` matches the order id, the payment id or the rider's user id.
  Map<String, String?> get _filters => {'status': _status, 'mode': _mode, 'plan': _plan, 'q': _userId.trim()};

  static String _labelOf(List<(String, String)> list, String v) => list.firstWhere((e) => e.$1 == v, orElse: () => (v, v)).$2;

  Future<void> _load({bool more = false}) async {
    final gen = more ? _generation : ++_generation;
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
      }
      _error = null;
    });
    try {
      final path = '/admin/payments${_query({
        ..._filters,
        'limit': '$_pageSize',
        'offset': more ? '${_rows.length}' : '0',
      })}';
      final res = await context.read<ApiClient>().get(path);
      if (gen != _generation) return;
      final list = adminMapList(res is Map ? res['payments'] : res);
      if (!more) _rows.clear();
      _rows.addAll(list);
      _total = res is Map ? (adminNumOrNull(res['total'])?.toInt() ?? _rows.length) : _rows.length;
      _hasMore = res is Map && res['hasMore'] == true;
      _loaded = true;
    } catch (e) {
      if (gen != _generation) return;
      _error = adminErrorOf(e);
      if (mounted && _loaded) adminSnack(context, _error!, error: true);
    }
    if (mounted) {
      setState(() {
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  /// Downloads the CSV with the admin's token (through the API client) and
  /// hands it to the share sheet, where it can be saved to Files or sent.
  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final csv = await context.read<ApiClient>().getText(
            '/admin/payments/export.csv${_query(_filters)}',
            timeout: const Duration(seconds: 60),
          );
      final now = DateTime.now();
      final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
      final name = 'coroute-payments-$stamp.csv';
      final file = XFile.fromData(utf8.encode(csv), mimeType: 'text/csv', name: name);
      await SharePlus.instance.share(ShareParams(
        files: [file],
        fileNameOverrides: [name],
        subject: 'CoRoute payments $stamp',
      ));
    } catch (e) {
      if (mounted) adminSnack(context, adminErrorOf(e), error: true);
    }
    if (mounted) setState(() => _exporting = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AdminTabBody(
      loading: _loading,
      hasData: _loaded,
      error: _error,
      onRefresh: _load,
      children: [
        const SizedBox(height: 4),
        AdminSearchRow(
          hint: 'Order, payment or user ID',
          onChanged: (v) {
            _userId = v;
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 400), () {
              if (mounted) _load();
            });
          },
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            AdminFilterButton<String>(
              value: _status,
              label: _labelOf(_statuses, _status),
              options: _statuses,
              onSelected: (v) {
                setState(() => _status = v);
                _load();
              },
            ),
            AdminFilterButton<String>(
              value: _mode,
              label: _labelOf(_modes, _mode),
              options: _modes,
              onSelected: (v) {
                setState(() => _mode = v);
                _load();
              },
            ),
            AdminFilterButton<String>(
              value: _plan,
              label: _labelOf(_plans, _plan),
              options: _plans,
              onSelected: (v) {
                setState(() => _plan = v);
                _load();
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        AdminTable(
          title: _loaded ? 'Payments ($_total)' : 'Payments',
          trailing: TextButton.icon(
            onPressed: _exporting ? null : _export,
            icon: _exporting
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(Icons.download_rounded, color: AppTheme.accentText),
            label: Text('Export CSV', style: TextStyle(color: AppTheme.accentText, fontWeight: FontWeight.w600)),
          ),
          rows: [
            for (var i = 0; i < _rows.length; i++)
              _PaymentRow(
                key: ValueKey(_rows[i]['orderId'] ?? i),
                payment: _rows[i],
                last: i == _rows.length - 1,
                onTap: () async {
                  final changed = await showAdminPaymentSheet(context, _rows[i]);
                  if (changed && mounted) _load();
                },
              ),
          ],
          empty: Text('No payments match.', style: AppText.caption),
        ),
        if (_hasMore) ...[
          const SizedBox(height: 12),
          Center(
            child: OutlinedButton.icon(
              onPressed: _loadingMore ? null : () => _load(more: true),
              icon: _loadingMore
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.expand_more_rounded),
              label: const Text('Load more'),
            ),
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }
}
