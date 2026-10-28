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
import 'admin_plans_pricing_screen.dart';
import 'admin_ui.dart';

// Overview, Subscribers and Payments tabs of "Payments & Plans".

String _query(Map<String, String?> params) {
  final clean = <String, String>{
    for (final e in params.entries)
      if (e.value != null && e.value!.isNotEmpty) e.key: e.value!,
  };
  return clean.isEmpty ? '' : '?${Uri(queryParameters: clean).query}';
}

/// Rupees from a JSON map: `<key>` in rupees, or `<key>InPaise`.
num? _money(Map? m, List<String> keys) {
  if (m == null) return null;
  for (final k in keys) {
    final r = adminNumOrNull(m[k]);
    if (r != null) return r;
    final p = adminNumOrNull(m['${k}InPaise']);
    if (p != null) return p / 100;
  }
  return null;
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
// Overview
// ======================================================================

/// Tiles from `GET /admin/subscription/overview`. Test-mode revenue is kept
/// apart from real revenue. Tapping a subscriber tile opens the list.
class AdminOverviewTab extends StatefulWidget {
  final ValueChanged<AdminPaymentsTab> onOpen;
  const AdminOverviewTab({super.key, required this.onOpen});

  @override
  State<AdminOverviewTab> createState() => _AdminOverviewTabState();
}

class _AdminOverviewTabState extends State<AdminOverviewTab> with AutomaticKeepAliveClientMixin {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await context.read<ApiClient>().get('/admin/subscription/overview');
      if (res is Map) _data = Map<String, dynamic>.from(res);
    } catch (e) {
      _error = adminErrorOf(e);
      if (mounted && _data != null) adminSnack(context, _error!, error: true);
    }
    if (mounted) setState(() => _loading = false);
  }

  Widget _tap(Widget tile, AdminPaymentsTab tab) => Material(
        color: Colors.transparent,
        child: InkWell(borderRadius: BorderRadius.circular(18), onTap: () => widget.onOpen(tab), child: tile),
      );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final d = _data ?? const <String, dynamic>{};
    // `subscribers` is the count per tier; the totals sit next to it.
    final tierMap = d['subscribers'] ?? d['subscribersByTier'] ?? d['byTier'];
    final byTier = tierMap is Map ? Map<String, dynamic>.from(tierMap) : const <String, dynamic>{};
    final active = adminPickNum(d, const ['active', 'activeSubscribers']);
    final expiring = adminPickNum(d, const ['expiringIn7Days', 'expiring7d', 'expiringSoon']);
    final expired = adminPickNum(d, const ['expiredLast30Days', 'expired30d']);

    final revenueRaw = d['revenue'] is Map ? Map<String, dynamic>.from(d['revenue'] as Map) : const <String, dynamic>{};
    final live = revenueRaw['live'] is Map ? Map<String, dynamic>.from(revenueRaw['live'] as Map) : revenueRaw;
    final testRaw = d['testRevenue'] ?? revenueRaw['test'];
    final test = testRaw is Map ? Map<String, dynamic>.from(testRaw) : null;

    final failed = adminPickNum(d, const ['failedSignatures', 'signatureFailures', 'failedSignatureCount']);
    final sweep = d['lastSweep'];
    final sweepAt = d['lastSweepAt'] ?? (sweep is Map ? (sweep['at'] ?? sweep['ranAt']) : sweep);
    final sweepNote = sweep is Map
        ? [
            if (adminNumOrNull(sweep['scanned']) != null) '${adminNumOrNull(sweep['scanned'])!.toInt()} scanned',
            if (adminNumOrNull(sweep['expired']) != null) '${adminNumOrNull(sweep['expired'])!.toInt()} expired',
            if (adminNumOrNull(sweep['warned']) != null) '${adminNumOrNull(sweep['warned'])!.toInt()} warned',
          ].join(', ')
        : '';

    String n(num? v) => v == null ? '—' : '${v.toInt()}';

    List<Widget> revenueTiles(Map? m, {bool isTest = false}) {
      final c = isTest ? AppTheme.warnText : null;
      return [
        AdminKpiTile(label: 'Today', value: adminInr(_money(m, const ['today']) ?? 0), valueColor: c),
        AdminKpiTile(label: 'Last 7 days', value: adminInr(_money(m, const ['last7Days', 'last7d']) ?? 0), valueColor: c),
        AdminKpiTile(label: 'Last 30 days', value: adminInr(_money(m, const ['last30Days', 'last30d']) ?? 0), valueColor: c),
        AdminKpiTile(label: 'All time', value: adminInr(_money(m, const ['allTime', 'total']) ?? 0), valueColor: c),
      ];
    }

    return AdminTabBody(
      loading: _loading,
      hasData: _data != null,
      error: _error,
      onRefresh: _load,
      children: [
        const AdminSectionLabel('Subscribers'),
        AdminKpiGrid(tiles: [
          _tap(AdminKpiTile(label: 'Active paid plans', value: n(active), delta: 'Open subscribers'), AdminPaymentsTab.subscribers),
          _tap(
            AdminKpiTile(
              label: 'Ending in 7 days',
              value: n(expiring),
              delta: (expiring ?? 0) > 0 ? 'Riders get reminders at 7, 3 and 1 day' : 'None ending soon',
              valueColor: (expiring ?? 0) > 0 ? AppTheme.warnText : null,
            ),
            AdminPaymentsTab.subscribers,
          ),
          _tap(AdminKpiTile(label: 'Expired in 30 days', value: n(expired), delta: 'Back on Community'), AdminPaymentsTab.subscribers),
        ]),
        if (byTier.isNotEmpty) ...[
          const SizedBox(height: 12),
          AdminKpiGrid(tiles: [
            for (final t in ['community', ...adminPaidTierNames])
              if (byTier.containsKey(t)) AdminKpiTile(label: adminTierLabel(t), value: n(adminNumOrNull(byTier[t]))),
          ]),
        ],
        const AdminSectionLabel('Revenue (real money)'),
        AdminKpiGrid(tiles: revenueTiles(live)),
        if (test != null) ...[
          const AdminSectionLabel('Test-mode revenue', trailing: AdminModeBadge('TEST')),
          AdminKpiGrid(tiles: revenueTiles(test, isTest: true)),
        ],
        const AdminSectionLabel('Health'),
        AdminKpiGrid(tiles: [
          _tap(
            AdminKpiTile(
              label: 'Failed signatures',
              value: n(failed),
              delta: (failed ?? 0) > 0 ? 'Orders with status SIGNATURE_MISMATCH' : 'All verified',
              valueColor: (failed ?? 0) > 0 ? AppTheme.sos : null,
              deltaColor: (failed ?? 0) > 0 ? AppTheme.sos : null,
            ),
            AdminPaymentsTab.payments,
          ),
          AdminKpiTile(
            label: 'Last expiry sweep',
            value: adminDate(sweepAt, time: true),
            delta: sweepNote.isEmpty ? 'Runs on the server' : sweepNote,
          ),
        ]),
        const SizedBox(height: 24),
      ],
    );
  }
}

// ======================================================================
// Subscribers
// ======================================================================

/// `GET /admin/subscriptions` with search, plan and state filters, cursor
/// paging, and per-row grant / extend, revoke and details.
class AdminSubscribersTab extends StatefulWidget {
  const AdminSubscribersTab({super.key});

  @override
  State<AdminSubscribersTab> createState() => _AdminSubscribersTabState();
}

class _AdminSubscribersTabState extends State<AdminSubscribersTab> with AutomaticKeepAliveClientMixin {
  final List<Map<String, dynamic>> _rows = [];
  String? _cursor;
  bool _loading = true;
  bool _loadingMore = false;
  bool _loaded = false;
  String? _error;
  String _tier = '';
  String _state = '';
  String _q = '';
  Timer? _debounce;
  int _generation = 0;

  static const List<(String, String)> _states = [
    ('', 'Any state'),
    ('active', 'Active'),
    ('expiring', 'Ending soon'),
    ('expired', 'Expired'),
    ('community', 'Community'),
  ];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

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
      final path = '/admin/subscriptions${_query({
        'tier': _tier,
        'state': _state,
        'q': _q.trim(),
        'limit': '50',
        'cursor': more ? _cursor : null,
      })}';
      final res = await context.read<ApiClient>().get(path);
      if (gen != _generation) return; // a newer search replaced this one
      final list = adminMapList(res is Map ? res['subscribers'] : null);
      if (!more) _rows.clear();
      _rows.addAll(list);
      final next = res is Map ? res['nextCursor']?.toString() : null;
      _cursor = (next == null || next.isEmpty) ? null : next;
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

  void _search(String q) {
    _q = q;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _load();
    });
  }

  String _stateLabel(String s) => _states.firstWhere((e) => e.$1 == s, orElse: () => (s, adminCapitalize(s))).$2;

  StatusTextChip _stateChip(String s) {
    switch (s) {
      case 'active':
        return StatusTextChip(icon: Icons.check_circle_rounded, text: 'Active', color: AppTheme.accentText);
      case 'expiring':
        return StatusTextChip(icon: Icons.timer_outlined, text: 'Ending soon', color: AppTheme.warnText);
      case 'expired':
        return StatusTextChip(icon: Icons.lock_clock_rounded, text: 'Expired', color: AppTheme.sos);
      default:
        return StatusTextChip(icon: Icons.person_outline_rounded, text: 'Community', color: AppTheme.text2);
    }
  }

  Future<void> _grant(Map<String, dynamic> s) async {
    final id = s['userId']?.toString() ?? '';
    if (id.isEmpty) return;
    final result = await showAppSheet<_GrantResult>(
      context,
      isScrollControlled: true,
      title: 'Grant or extend a plan',
      builder: (_) => _GrantSheet(name: _who(s), currentTier: s['tier']?.toString()),
    );
    if (result == null || !mounted) return;
    try {
      await context.read<ApiClient>().post('/admin/subscription/users/$id/grant', {
        'planTier': result.tier,
        'days': result.days,
        'reason': result.reason,
      });
      if (!mounted) return;
      adminSnack(context, '${adminTierLabel(result.tier)} granted to ${_who(s)} for ${result.days} days.');
      _load();
    } catch (e) {
      if (mounted) adminSnack(context, adminErrorOf(e), error: true);
    }
  }

  Future<void> _revoke(Map<String, dynamic> s) async {
    final id = s['userId']?.toString() ?? '';
    if (id.isEmpty) return;
    final reason = await adminAskText(
      context,
      title: 'Revoke ${adminTierLabel(s['tier'])}?',
      message: '${_who(s)} goes back to Community right away and is told the plan was ended by CoRoute support. '
          'No money is returned: refund the payment from the Payments tab if needed.',
      label: 'Reason (shown to the rider)',
      confirmLabel: 'Revoke plan',
      destructive: true,
      validator: (t) => t.length < 3 ? 'Give a short reason.' : null,
    );
    if (reason == null || !mounted) return;
    try {
      await context.read<ApiClient>().post('/admin/subscription/users/$id/revoke', {'reason': reason});
      if (!mounted) return;
      adminSnack(context, 'Plan revoked for ${_who(s)}.');
      _load();
    } catch (e) {
      if (mounted) adminSnack(context, adminErrorOf(e), error: true);
    }
  }

  void _open(Map<String, dynamic> s) {
    if ((s['userId']?.toString() ?? '').isEmpty) return;
    showAppSheet<void>(
      context,
      isScrollControlled: true,
      title: _who(s),
      builder: (_) => _SubscriberDetailSheet(subscriber: s, onChanged: _load),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final rows = <Widget>[];
    for (var i = 0; i < _rows.length; i++) {
      final s = _rows[i];
      final state = s['state']?.toString() ?? '';
      final tier = s['tier']?.toString() ?? 'community';
      final days = adminNumOrNull(s['daysRemaining']);
      final until = adminEpoch(s['validUntil']);
      final paidTotal = adminNumOrNull(s['totalPaid']);
      final count = adminNumOrNull(s['paymentsCount'])?.toInt() ?? 0;
      final prev = s['previousTier']?.toString() ?? '';
      rows.add(AdminRow(
        key: ValueKey(s['userId'] ?? i),
        leading: AdminRowIcon(Icons.card_membership_rounded, color: state == 'expired' ? AppTheme.sos : null),
        title: _who(s),
        subtitle: [
          if ((s['callsign']?.toString() ?? '').isNotEmpty) s['callsign'].toString(),
          if ((s['email']?.toString() ?? '').isNotEmpty) s['email'].toString(),
          if ((s['phone']?.toString() ?? '').isNotEmpty) s['phone'].toString(),
        ].join(' · '),
        detail: [
          adminTierLabel(tier),
          if (until > 0) 'until ${adminDate(until)}${days != null && days >= 0 ? ' (${days.toInt()} d)' : ''}',
          if (state == 'expired' && prev.isNotEmpty) 'was ${adminTierLabel(prev)}',
          if (count > 0) '$count ${count == 1 ? 'payment' : 'payments'}, ${adminInr(paidTotal ?? 0)}',
          if (s['lastPayment'] is Map) 'last ${adminDate((s['lastPayment'] as Map)['paidAt'] ?? (s['lastPayment'] as Map)['at'])}',
        ].join(' · '),
        status: _stateChip(state),
        trailing: PopupMenuButton<String>(
          tooltip: 'Actions',
          icon: Icon(Icons.more_vert_rounded, color: AppTheme.muted),
          color: AppTheme.card,
          onSelected: (v) {
            if (v == 'grant') _grant(s);
            if (v == 'revoke') _revoke(s);
            if (v == 'open') _open(s);
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'grant', child: Text('Grant / extend')),
            if (tier != 'community' && state != 'expired') const PopupMenuItem(value: 'revoke', child: Text('Revoke')),
            const PopupMenuItem(value: 'open', child: Text('Payments & details')),
          ],
        ),
        divider: i < _rows.length - 1,
        onTap: () => _open(s),
      ));
    }

    return AdminTabBody(
      loading: _loading,
      hasData: _loaded,
      error: _error,
      onRefresh: _load,
      children: [
        const SizedBox(height: 4),
        AdminSearchRow(hint: 'Search name, email, phone, callsign', onChanged: _search),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            AdminFilterButton<String>(
              value: _tier,
              label: _tier.isEmpty ? 'Any plan' : adminTierLabel(_tier),
              options: [('', 'Any plan'), ('community', 'Community'), for (final t in adminPaidTierNames) (t, adminTierLabel(t))],
              onSelected: (v) {
                setState(() => _tier = v);
                _load();
              },
            ),
            AdminFilterButton<String>(
              value: _state,
              label: _stateLabel(_state),
              options: _states,
              onSelected: (v) {
                setState(() => _state = v);
                _load();
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        AdminTable(
          title: 'Subscribers',
          rows: rows,
          empty: Text('No subscribers match.', style: AppText.caption),
        ),
        if (_cursor != null) ...[
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

class _GrantResult {
  final String tier;
  final int days;
  final String reason;
  const _GrantResult(this.tier, this.days, this.reason);
}

class _GrantSheet extends StatefulWidget {
  final String name;
  final String? currentTier;
  const _GrantSheet({required this.name, this.currentTier});

  @override
  State<_GrantSheet> createState() => _GrantSheetState();
}

class _GrantSheetState extends State<_GrantSheet> {
  late String _tier = adminPaidTierNames.contains(widget.currentTier) ? widget.currentTier! : adminPaidTierNames.first;
  final _days = TextEditingController(text: '30');
  final _reason = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _days.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    final days = int.tryParse(_days.text.trim());
    if (days == null || days < 1 || days > 3660) {
      setState(() => _problem = 'Days must be a whole number from 1 to 3660.');
      return;
    }
    if (_reason.text.trim().length < 3) {
      setState(() => _problem = 'Give a short reason (kept in the audit log).');
      return;
    }
    Navigator.of(context).pop(_GrantResult(_tier, days, _reason.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final p = _problem;
    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'For ${widget.name}. If the same plan is active, the days are added to its end date.',
            style: AppText.body.copyWith(color: AppTheme.text2),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _tier,
            decoration: adminInput('Plan'),
            items: [for (final t in adminPaidTierNames) DropdownMenuItem(value: t, child: Text(adminTierLabel(t)))],
            onChanged: (v) => setState(() => _tier = v ?? _tier),
          ),
          const SizedBox(height: 12),
          TextField(controller: _days, keyboardType: TextInputType.number, decoration: adminInput('Days', suffix: 'days')),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final d in const [7, 30, 90, 365])
                ActionChip(label: Text('$d days'), onPressed: () => setState(() => _days.text = '$d')),
            ],
          ),
          const SizedBox(height: 12),
          TextField(controller: _reason, decoration: adminInput('Reason', hint: 'Goodwill after the outage on 3 Nov')),
          if (p != null) ...[
            const SizedBox(height: 8),
            Text(p, style: AppText.caption.copyWith(color: AppTheme.sos, fontWeight: FontWeight.w700)),
          ],
          const SizedBox(height: 16),
          DsButton(label: 'Grant plan', icon: Icons.card_membership_rounded, onPressed: _submit),
        ],
      ),
    );
  }
}

/// `GET /admin/payments/users/:id`: the rider's plan and every payment, each
/// opening the payment sheet (refunds).
class _SubscriberDetailSheet extends StatefulWidget {
  final Map<String, dynamic> subscriber;
  final VoidCallback onChanged;
  const _SubscriberDetailSheet({required this.subscriber, required this.onChanged});

  @override
  State<_SubscriberDetailSheet> createState() => _SubscriberDetailSheetState();
}

class _SubscriberDetailSheetState extends State<_SubscriberDetailSheet> {
  Map<String, dynamic>? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final id = widget.subscriber['userId'];
      final res = await context.read<ApiClient>().get('/admin/payments/users/$id');
      if (!mounted) return;
      setState(() {
        _data = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = adminErrorOf(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.subscriber;
    final d = _data;
    final sub = d?['subscriptionStatus'] is Map ? Map<String, dynamic>.from(d!['subscriptionStatus'] as Map) : s;
    // Ledger orders carry status and refunds; older accounts may only have paymentHistory.
    final orders = adminMapList(d?['orders']);
    final payments = orders.isNotEmpty ? orders : adminMapList(d?['paymentHistory'] ?? d?['payments']);
    final periods = adminMapList(d?['subscriptionHistory']);
    final e = _error;
    return ListView(
      shrinkWrap: true,
      children: [
        AdminDetailLine('User ID', s['userId']?.toString() ?? '—'),
        if ((s['email']?.toString() ?? '').isNotEmpty) AdminDetailLine('Email', s['email'].toString()),
        if ((s['phone']?.toString() ?? '').isNotEmpty) AdminDetailLine('Phone', s['phone'].toString()),
        AdminDetailLine('Plan', adminTierLabel(sub['tier'] ?? s['tier'])),
        AdminDetailLine('Valid until', adminDate(sub['validUntil'] ?? s['validUntil'], time: true)),
        if ((sub['pendingTier']?.toString() ?? '').isNotEmpty)
          AdminDetailLine('Next plan', '${adminTierLabel(sub['pendingTier'])} from ${adminDate(sub['pendingStartsAt'] ?? sub['validUntil'])}'),
        AdminDetailLine('Total paid', adminInr(adminNumOrNull(s['totalPaid']) ?? 0)),
        const SizedBox(height: 12),
        if (d == null && e == null) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
        if (e != null) Text(e, style: AppText.caption.copyWith(color: AppTheme.sos)),
        if (d != null) ...[
          Text('Payments', style: AppText.title),
          const SizedBox(height: 6),
          if (payments.isEmpty) Text('No payments.', style: AppText.caption),
          for (var i = 0; i < payments.length; i++)
            _PaymentRow(
              payment: payments[i],
              last: i == payments.length - 1,
              onTap: () async {
                final changed = await showAdminPaymentSheet(context, payments[i]);
                if (changed && mounted) {
                  widget.onChanged();
                  _load();
                }
              },
            ),
          if (periods.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Plan periods', style: AppText.title),
            const SizedBox(height: 6),
            for (final p in periods)
              AdminDetailLine(
                adminTierLabel(p['tier']),
                '${adminDate(p['validFrom'] ?? p['startedAt'])} → ${adminDate(p['validUntil'] ?? p['endedAt'])}'
                '${(p['reason']?.toString() ?? '').isEmpty ? '' : ' · ${p['reason']}'}',
              ),
          ],
        ],
        const SizedBox(height: 16),
      ],
    );
  }
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
            Text('A manual grant has no Razorpay payment to refund. Revoke the plan from Subscribers instead.', style: AppText.caption),
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
              style: AppText.caption.copyWith(color: _full ? AppTheme.sos : AppTheme.text2, fontWeight: FontWeight.w700),
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
              Text(p, style: AppText.caption.copyWith(color: AppTheme.sos, fontWeight: FontWeight.w700)),
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

/// `GET /admin/payments?status=&mode=&userId=&limit=&offset=`, with refunds and CSV export.
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
  Timer? _debounce;
  int _generation = 0;

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
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Map<String, String?> get _filters => {'status': _status, 'mode': _mode, 'userId': _userId.trim()};

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
          hint: 'Filter by user ID',
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
            label: Text('Export CSV', style: TextStyle(color: AppTheme.accentText, fontWeight: FontWeight.w800)),
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
