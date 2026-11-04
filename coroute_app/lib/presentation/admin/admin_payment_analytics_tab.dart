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
/// Provides executive financial metrics, plan breakdown (Individual ₹9, Small Group ₹49, Large Group ₹99),
/// promotional coupon ROI, and visual daily revenue trend charts across time ranges.
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

  static const List<(String, String)> _rangeOptions = [
    ('today', 'Today'),
    ('7d', 'Last 7 Days'),
    ('30d', 'Last 30 Days'),
    ('this_month', 'This Month'),
    ('last_month', 'Previous Month'),
    ('custom', 'Custom Range'),
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
      final res = await context.read<ApiClient>().get('/admin/payments/analytics$queryStr');

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
          Text('Time Window:', style: AppText.caption.copyWith(fontWeight: FontWeight.w800)),
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
            tooltip: 'Refresh analytics',
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
          label: 'Gross Sales',
          value: adminInr(gross),
          delta: 'Catalog value',
          valueColor: AppTheme.accentText,
        ),
        AdminKpiTile(
          label: 'Total Discounts',
          value: adminInr(discount),
          delta: 'Promotional savings',
          valueColor: AppTheme.warnText,
        ),
        AdminKpiTile(
          label: 'Net Revenue',
          value: adminInr(net),
          delta: 'Net collected',
          valueColor: AppTheme.brand,
        ),
        AdminKpiTile(
          label: 'Paid Orders',
          value: '$paid / $total',
          delta: 'AOV ${adminInr(aov)}',
          valueColor: AppTheme.accentText,
        ),
        AdminKpiTile(
          label: 'Free Activations',
          value: '$freeActivations',
          delta: '₹0 promo memberships',
          valueColor: Colors.tealAccent,
        ),
        AdminKpiTile(
          label: 'Active Members',
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
              Text('Net Revenue Trend (Daily)', style: AppText.title.copyWith(fontSize: 16)),
              const Spacer(),
              Text('${timeline.length} days plotted', style: AppText.caption),
            ],
          ),
          const SizedBox(height: 16),
          if (timeline.isEmpty)
            const SizedBox(
              height: 140,
              child: Center(child: Text('No daily transaction data recorded in this range.')),
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
    final plans = [
      byPlan['individual'] is Map ? Map<String, dynamic>.from(byPlan['individual'] as Map) : {'id': 'individual', 'name': 'Individual Membership (₹9/mo)', 'units': 0, 'grossInr': 0, 'discountsInr': 0, 'netInr': 0, 'activeMembers': 0},
      byPlan['group_small'] is Map ? Map<String, dynamic>.from(byPlan['group_small'] as Map) : {'id': 'group_small', 'name': 'Small Group 2–6 (₹49/mo)', 'units': 0, 'grossInr': 0, 'discountsInr': 0, 'netInr': 0, 'activeMembers': 0},
      byPlan['group_large'] is Map ? Map<String, dynamic>.from(byPlan['group_large'] as Map) : {'id': 'group_large', 'name': 'Large Group 7–12 (₹99/mo)', 'units': 0, 'grossInr': 0, 'discountsInr': 0, 'netInr': 0, 'activeMembers': 0},
    ];

    return AdminTable(
      title: 'Performance by Membership Plan',
      rows: [
        for (var i = 0; i < plans.length; i++)
          _planRow(plans[i], i == plans.length - 1),
      ],
      empty: Text('No plan transactions recorded.', style: AppText.caption),
    );
  }

  Widget _planRow(Map<String, dynamic> p, bool last) {
    final name = p['name']?.toString() ?? 'Plan';
    final units = p['units'] ?? 0;
    final gross = adminNumOrNull(p['grossInr']) ?? 0;
    final disc = adminNumOrNull(p['discountsInr']) ?? 0;
    final net = adminNumOrNull(p['netInr']) ?? 0;
    final active = p['activeMembers'] ?? 0;

    return AdminRow(
      leading: AdminRowIcon(
        name.contains('99') ? Icons.groups_3_rounded : (name.contains('49') ? Icons.group_rounded : Icons.person_rounded),
        color: AppTheme.accentText,
      ),
      title: name,
      subtitle: '$units units sold in period · $active currently active members',
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
      title: 'Promotional Coupon ROI & Adoption (${topCoupons.length})',
      rows: [
        for (var i = 0; i < topCoupons.length; i++)
          _couponRoiRow(topCoupons[i], i == topCoupons.length - 1),
      ],
      empty: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text('No promotional coupons redeemed in this period.', style: AppText.caption),
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
