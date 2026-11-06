import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import 'admin_payments_logic.dart';
import 'admin_payments_widgets.dart';
import 'admin_ui.dart';

/// Admin Console: Payment Analytics Dashboard.
///
/// Provides executive financial metrics, the plan breakdown (plan names and prices from the
/// server plan catalog, never hard-coded), promotional coupon ROI, and visual daily revenue
/// trend charts across time ranges.
class AdminPaymentAnalyticsTab extends StatefulWidget {
  const AdminPaymentAnalyticsTab({super.key});

  @override
  State<AdminPaymentAnalyticsTab> createState() => _AdminPaymentAnalyticsTabState();
}

class _AdminPaymentAnalyticsTabState extends State<AdminPaymentAnalyticsTab> with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  bool _loaded = false;
  String? _error;

  String _range = '30d';
  int? _customFrom;
  int? _customTo;

  Map<String, dynamic> _data = {};

  /// The server plan catalog (`/admin/coupons/plan-options`): names and prices of plans that
  /// have no sales in the period yet.
  List<Map<String, dynamic>> _planOptions = [];

  static const List<(String, String)> _rangeOptions = [
    ('today', 'Today'),
    ('7d', 'Last 7 days'),
    ('30d', 'Last 30 days'),
    ('this_month', 'This month'),
    ('last_month', 'Last month'),
    ('custom', 'Pick dates'),
  ];

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
      final params = <String, String>{'range': _range};
      if (_range == 'custom' && _customFrom != null && _customTo != null) {
        params['from'] = '$_customFrom';
        params['to'] = '$_customTo';
      }

      final queryStr = '?${Uri(queryParameters: params).query}';
      final api = context.read<ApiClient>();
      final res = await api.get('/admin/payments/analytics$queryStr');
      if (_planOptions.isEmpty) {
        try {
          final opts = await api.get('/admin/coupons/plan-options');
          _planOptions = adminMapList(opts is Map ? opts['plans'] : null);
        } catch (_) {
          // An older gateway: plans without sales show their names without a price.
        }
      }

      if (res is Map) {
        _data = Map<String, dynamic>.from(res);
      }
      _loaded = true;
    } catch (e) {
      _error = adminErrorOf(e);
      if (mounted && _loaded) adminSnack(context, _error!, error: true);
    }

    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
      initialDateRange: DateTimeRange(
        start: _customFrom != null ? DateTime.fromMillisecondsSinceEpoch(_customFrom!) : now.subtract(const Duration(days: 14)),
        end: _customTo != null ? DateTime.fromMillisecondsSinceEpoch(_customTo!) : now,
      ),
    );

    if (picked != null) {
      setState(() {
        _range = 'custom';
        _customFrom = picked.start.millisecondsSinceEpoch;
        _customTo = picked.end.add(const Duration(hours: 23, minutes: 59, seconds: 59)).millisecondsSinceEpoch;
      });
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isWide = MediaQuery.of(context).size.width >= adminWideBreakpoint;

    return AdminTabBody(
      loading: _loading,
      hasData: _loaded,
      error: _error,
      onRefresh: _load,
      children: [
        // Time Range Filter Bar
        _buildRangeBar(isWide),
        const SizedBox(height: 16),

        // Financial Summary KPI Grid
        _buildSummaryGrid(isWide),
        const SizedBox(height: 20),

        // Visual Revenue Trend Chart
        _buildTrendChartCard(),
        const SizedBox(height: 20),

        // Breakdown by Plan Table
        _buildPlanBreakdownTable(isWide),
        const SizedBox(height: 20),

        // Promotional Coupon ROI Table
        _buildCouponRoiTable(),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildRangeBar(bool isWide) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border, width: 1.5),
      ),
      child: Row(
        children: [
          Icon(Icons.calendar_month_outlined, size: 20, color: AppTheme.accentText),
          const SizedBox(width: 10),
          Text('Period', style: AppText.caption.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(width: 12),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final opt in _rangeOptions)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(opt.$2),
                        selected: _range == opt.$1,
                        onSelected: (selected) {
                          if (selected) {
                            if (opt.$1 == 'custom') {
                              _pickCustomRange();
                            } else {
                              setState(() => _range = opt.$1);
                              _load();
                            }
                          }
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          IconButton.filledTonal(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, size: 18),
            onPressed: _load,
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryGrid(bool isWide) {
    final summary = _data['summary'] is Map ? Map<String, dynamic>.from(_data['summary'] as Map) : const <String, dynamic>{};
    final gross = adminNumOrNull(summary['grossSalesInr']) ?? 0;
    final discount = adminNumOrNull(summary['discountsInr']) ?? 0;
    final net = adminNumOrNull(summary['netRevenueInr']) ?? 0;
    final paid = summary['paidOrders'] ?? summary['paidOrdersCount'] ?? 0;
    final total = summary['totalTransactions'] ?? summary['totalOrdersCount'] ?? 0;
    final freeActivations = summary['freeActivations'] ?? summary['freeActivationsCount'] ?? 0;
    final activeMem = summary['activeMemberships'] ?? summary['activeMembershipsCount'] ?? 0;
    final newMem = summary['newMemberships'] ?? 0;
    final aov = adminNumOrNull(summary['averageOrderValueInr'] ?? summary['aovInr']) ?? 0;
    final refundAmt = adminNumOrNull(summary['refundedAmountInr']) ?? 0;

    return AdminKpiGrid(
      tiles: [
        AdminKpiTile(
          label: 'Gross sales',
          value: adminInr(gross),
          delta: 'At list price',
          valueColor: AppTheme.accentText,
        ),
        AdminKpiTile(
          label: 'Discounts',
          value: adminInr(discount),
          delta: 'Coupons and offers',
          valueColor: AppTheme.warnText,
        ),
        AdminKpiTile(
          label: 'Net revenue',
          value: adminInr(net),
          delta: 'Collected',
          valueColor: AppTheme.brand,
        ),
        AdminKpiTile(
          label: 'Paid orders',
          value: '$paid / $total',
          delta: 'Average ${adminInr(aov)}',
          valueColor: AppTheme.accentText,
        ),
        AdminKpiTile(
          label: 'Free plans',
          value: '$freeActivations',
          delta: 'Fully covered by a coupon',
          valueColor: AppTheme.accentText,
        ),
        AdminKpiTile(
          label: 'Active members',
          value: '$activeMem',
          delta: '+$newMem in period',
          valueColor: AppTheme.brand,
        ),
        AdminKpiTile(
          label: 'Refunds',
          value: adminInr(refundAmt),
          delta: '${summary['refundedOrders'] ?? 0} refunded',
          valueColor: refundAmt > 0 ? AppTheme.sos : AppTheme.text2,
        ),
      ],
    );
  }

  Widget _buildTrendChartCard() {
    final timeline = adminMapList(_data['timeline']);

    return DsCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.auto_graph_rounded, size: 20, color: AppTheme.accentText),
              const SizedBox(width: 10),
              Text('Net revenue per day', style: AppText.title.copyWith(fontSize: 16)),
              const Spacer(),
              Text('${timeline.length} days', style: AppText.caption),
            ],
          ),
          const SizedBox(height: 16),
          if (timeline.isEmpty)
            const SizedBox(
              height: 140,
              child: Center(child: Text('No payments in this period.')),
            )
          else
            SizedBox(
              height: 160,
              child: _RevenueBarChart(points: timeline),
            ),
        ],
      ),
    );
  }

  Widget _buildPlanBreakdownTable(bool isWide) {
    final byPlan = _data['byPlan'] is Map ? Map<String, dynamic>.from(_data['byPlan'] as Map) : const <String, dynamic>{};
    final ids = [
      ...adminMembershipPlanIds(_planOptions),
      for (final k in byPlan.keys)
        if (!adminMembershipPlanNames.containsKey(k) && byPlan[k] is Map) k,
    ];
    final plans = [
      for (final id in ids.toSet())
        if (byPlan[id] is Map)
          {'id': id, ...Map<String, dynamic>.from(byPlan[id] as Map)}
        else
          {'id': id, 'name': adminPlanLabel(id, _planOptions), 'units': 0, 'grossInr': 0, 'discountsInr': 0, 'netInr': 0, 'activeMembers': 0},
    ];

    return AdminTable(
      title: 'By plan',
      rows: [
        for (var i = 0; i < plans.length; i++)
          _planRow(plans[i], i == plans.length - 1),
      ],
      empty: Text('No plan sold in this period.', style: AppText.caption),
    );
  }

  Widget _planRow(Map<String, dynamic> p, bool last) {
    final id = p['id']?.toString() ?? '';
    final name = (p['name']?.toString() ?? '').trim().isNotEmpty ? p['name'].toString() : adminPlanLabel(id, _planOptions);
    final units = p['units'] ?? 0;
    final gross = adminNumOrNull(p['grossInr']) ?? 0;
    final disc = adminNumOrNull(p['discountsInr']) ?? 0;
    final net = adminNumOrNull(p['netInr']) ?? 0;
    final active = p['activeMembers'] ?? 0;

    return AdminRow(
      leading: AdminRowIcon(
        id == 'group_large' ? Icons.groups_3_rounded : (id == 'group_small' ? Icons.group_rounded : Icons.person_rounded),
        color: AppTheme.accentText,
      ),
      title: name,
      subtitle: '$units sold in this period · $active active now',
      detail: 'Gross: ${adminInr(gross)} · Subsidy: -${adminInr(disc)} · Net: ${adminInr(net)}',
      status: StatusTextChip(
        icon: Icons.payments_rounded,
        text: adminInr(net),
        color: AppTheme.accentText,
      ),
      divider: !last,
    );
  }

  Widget _buildCouponRoiTable() {
    final couponAnalytics = _data['couponAnalytics'] is Map ? Map<String, dynamic>.from(_data['couponAnalytics'] as Map) : const <String, dynamic>{};
    final topCoupons = adminMapList(couponAnalytics['topCoupons']);

    return AdminTable(
      title: 'Coupons used (${topCoupons.length})',
      rows: [
        for (var i = 0; i < topCoupons.length; i++)
          _couponRoiRow(topCoupons[i], i == topCoupons.length - 1),
      ],
      empty: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text('No coupon used in this period.', style: AppText.caption),
        ),
      ),
    );
  }

  Widget _couponRoiRow(Map<String, dynamic> c, bool last) {
    final code = c['code']?.toString() ?? 'COUPON';
    final campaign = c['campaignName']?.toString() ?? code;
    final redemptions = c['redemptions'] ?? 0;
    final uniqueUsers = c['uniqueUsers'] ?? 0;
    final disc = adminNumOrNull(c['discountAmount']) ?? 0;
    final net = adminNumOrNull(c['netRevenue']) ?? 0;

    return AdminRow(
      leading: AdminRowIcon(Icons.discount_rounded, color: AppTheme.warnText),
      title: '$code · $campaign',
      subtitle: '$redemptions redemptions across $uniqueUsers riders',
      detail: 'Discount Given: ${adminInr(disc)} · Revenue Generated: ${adminInr(net)}',
      status: StatusTextChip(
        icon: Icons.trending_up_rounded,
        text: adminInr(net),
        color: AppTheme.accentText,
      ),
      divider: !last,
    );
  }
}

class _RevenueBarChart extends StatelessWidget {
  final List<Map<String, dynamic>> points;
  const _RevenueBarChart({required this.points});

  @override
  Widget build(BuildContext context) {
    num maxRev = 10;
    for (final p in points) {
      final net = adminNumOrNull(p['netInr']) ?? 0;
      if (net > maxRev) maxRev = net;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final barWidth = math.max(6.0, (constraints.maxWidth / points.length) - 4.0);

        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final p in points) ...[
              Tooltip(
                message: '${p['date']}\nNet: ${adminInr(adminNumOrNull(p['netInr']) ?? 0)}\nOrders: ${p['orders'] ?? 0}',
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      width: barWidth,
                      height: math.max(4.0, ((adminNumOrNull(p['netInr']) ?? 0) / maxRev) * 120),
                      decoration: BoxDecoration(
                        color: (adminNumOrNull(p['netInr']) ?? 0) > 0 ? AppTheme.accentText : AppTheme.border,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      (p['date']?.toString().length ?? 0) >= 10 ? p['date'].toString().substring(8, 10) : '',
                      style: AppText.caption.copyWith(fontSize: 9, color: AppTheme.muted),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
