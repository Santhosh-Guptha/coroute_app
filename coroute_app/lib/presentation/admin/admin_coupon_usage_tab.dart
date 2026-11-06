import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import 'admin_payments_logic.dart';
import 'admin_payments_widgets.dart';
import 'admin_ui.dart';

/// Admin Console: Coupon Usage & Redemption Monitoring Tab.
///
/// Features:
/// - Real-time KPI pulse: Total coupons, active coupons, redemptions count, discount given, revenue generated.
/// - Filterable redemptions table by coupon code, member query, plan tier, and status.
/// - Detailed Payment & Redemption Audit modal with immutable math trace.
class AdminCouponUsageTab extends StatefulWidget {
  const AdminCouponUsageTab({super.key});

  @override
  State<AdminCouponUsageTab> createState() => _AdminCouponUsageTabState();
}

class _AdminCouponUsageTabState extends State<AdminCouponUsageTab> with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  bool _loaded = false;
  String? _error;

  Map<String, dynamic> _summary = {};
  List<Map<String, dynamic>> _redemptions = [];

  /// The server plan catalog (`/admin/coupons/plan-options`) for the plan filter's names and prices.
  List<Map<String, dynamic>> _planOptions = [];

  String _searchQuery = '';
  final String _selectedCoupon = '';
  String _selectedTier = 'all';
  String _selectedStatus = 'all';

  final TextEditingController _searchController = TextEditingController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final queryParams = <String, String>{};
      if (_selectedCoupon.isNotEmpty && _selectedCoupon != 'all') {
        queryParams['code'] = _selectedCoupon;
      }
      if (_selectedTier.isNotEmpty && _selectedTier != 'all') {
        queryParams['category'] = _selectedTier;
      }
      if (_selectedStatus.isNotEmpty && _selectedStatus != 'all') {
        queryParams['status'] = _selectedStatus;
      }

      final queryStr = queryParams.isEmpty ? '' : '?${Uri(queryParameters: queryParams).query}';
      final api = context.read<ApiClient>();
      final res = await api.get('/admin/coupons/usage$queryStr');
      if (_planOptions.isEmpty) {
        try {
          final opts = await api.get('/admin/coupons/plan-options');
          _planOptions = adminMapList(opts is Map ? opts['plans'] : null);
        } catch (_) {
          // An older gateway: the filter shows plan names without prices.
        }
      }

      if (res is Map) {
        _summary = Map<String, dynamic>.from(res['summary'] as Map? ?? {});
        _redemptions = adminMapList(res['redemptions']);
      }
      _loaded = true;
    } catch (e) {
      _error = adminErrorOf(e);
      if (mounted && _loaded) adminSnack(context, _error!, error: true);
    }

    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> get _filteredRedemptions {
    if (_searchQuery.trim().isEmpty) return _redemptions;
    final q = _searchQuery.trim().toLowerCase();
    return _redemptions.where((r) {
      final code = (r['couponCode']?.toString() ?? '').toLowerCase();
      final campaign = (r['campaignName']?.toString() ?? '').toLowerCase();
      final user = (r['userName']?.toString() ?? '').toLowerCase();
      final email = (r['userEmail']?.toString() ?? '').toLowerCase();
      final phone = (r['userPhone']?.toString() ?? '').toLowerCase();
      final uid = (r['userId']?.toString() ?? '').toLowerCase();
      final order = (r['orderId']?.toString() ?? '').toLowerCase();
      return code.contains(q) || campaign.contains(q) || user.contains(q) || email.contains(q) || phone.contains(q) || uid.contains(q) || order.contains(q);
    }).toList();
  }

  void _openRedemptionDetail(Map<String, dynamic> r) {
    showAppSheet<void>(
      context,
      isScrollControlled: true,
      title: 'Coupon Redemption Details',
      builder: (_) => _RedemptionDetailSheet(redemption: r),
    );
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
        // KPI Summary Pulse Cards
        _buildKpiPulse(isWide),
        const SizedBox(height: 16),

        // Filter and Search Toolbar
        _buildToolbar(isWide),
        const SizedBox(height: 12),

        // Redemptions List / Table
        _buildRedemptionsTable(),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildKpiPulse(bool isWide) {
    final totalCoupons = _summary['totalCoupons'] ?? 0;
    final activeCoupons = _summary['activeCoupons'] ?? 0;
    final totalRedemptions = _summary['totalRedemptions'] ?? 0;
    final totalDiscount = adminNumOrNull(_summary['totalDiscountGivenInr']) ?? 0;
    final totalRevenue = adminNumOrNull(_summary['revenueGeneratedInr']) ?? 0;
    final uniqueUsers = _summary['uniqueUsersCount'] ?? 0;

    return AdminKpiGrid(
      tiles: [
        AdminKpiTile(
          label: 'Total Redemptions',
          value: '$totalRedemptions',
          delta: '$uniqueUsers unique riders',
          valueColor: AppTheme.accentText,
        ),
        AdminKpiTile(
          label: 'Discounts Granted',
          value: adminInr(totalDiscount),
          delta: 'Promotional subsidy',
          valueColor: AppTheme.warnText,
        ),
        AdminKpiTile(
          label: 'Coupon Revenue',
          value: adminInr(totalRevenue),
          delta: 'Net paid through coupons',
          valueColor: AppTheme.brand,
        ),
        AdminKpiTile(
          label: 'Active Coupons',
          value: '$activeCoupons / $totalCoupons',
          delta: 'Live in catalog',
          valueColor: AppTheme.accentText,
        ),
      ],
    );
  }

  Widget _buildToolbar(bool isWide) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onChanged: (v) => setState(() => _searchQuery = v),
                  decoration: adminInput(
                    'Search redemptions',
                    prefix: null,
                    hint: 'Coupon code, rider, phone, order ID…',
                  ).copyWith(
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filledTonal(
                tooltip: 'Refresh data',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _load,
              ),
            ],
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Text('Filter by:', style: AppText.caption.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(width: 8),
                _FilterDropdown(
                  label: 'Tier',
                  value: _selectedTier,
                  items: [
                    const DropdownMenuItem(value: 'all', child: Text('All Plans')),
                    for (final id in {...adminMembershipPlanIds(_planOptions), if (_selectedTier != 'all') _selectedTier})
                      DropdownMenuItem(value: id, child: Text(adminPlanLabel(id, _planOptions, perMonth: false))),
                  ],
                  onChanged: (v) {
                    setState(() => _selectedTier = v ?? 'all');
                    _load();
                  },
                ),
                const SizedBox(width: 8),
                _FilterDropdown(
                  label: 'Status',
                  value: _selectedStatus,
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('All Statuses')),
                    DropdownMenuItem(value: 'SUCCESS', child: Text('Successful')),
                    DropdownMenuItem(value: 'RESERVED', child: Text('Reserved (Pending)')),
                    DropdownMenuItem(value: 'CANCELLED', child: Text('Cancelled')),
                  ],
                  onChanged: (v) {
                    setState(() => _selectedStatus = v ?? 'all');
                    _load();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRedemptionsTable() {
    final list = _filteredRedemptions;

    return AdminTable(
      title: 'Redemption Log (${list.length})',
      rows: [
        for (var i = 0; i < list.length; i++) _redemptionRow(list[i], i == list.length - 1),
      ],
      empty: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Column(
            children: [
              Icon(Icons.receipt_long_outlined, size: 36, color: AppTheme.text2),
              const SizedBox(height: 8),
              Text('No redemptions found matching filters.', style: AppText.caption),
            ],
          ),
        ),
      ),
    );
  }

  Widget _redemptionRow(Map<String, dynamic> r, bool last) {
    final code = r['couponCode']?.toString() ?? 'COUPON';
    final campaign = r['campaignName']?.toString() ?? '';
    final name = (r['userName']?.toString() ?? '').isNotEmpty ? r['userName'].toString() : (r['userId']?.toString() ?? 'Rider');
    final orig = adminNumOrNull(r['originalPrice']) ?? 0;
    final disc = adminNumOrNull(r['discountAmount']) ?? 0;
    final finalAmt = adminNumOrNull(r['finalAmount']) ?? 0;
    final status = (r['status']?.toString() ?? 'SUCCESS').toUpperCase();
    final at = adminEpoch(r['redeemedAt'] ?? r['reservedAt'] ?? r['createdAt']);
    final tier = r['categoryName']?.toString() ?? adminTierLabel(r['category']);

    return AdminRow(
      key: ValueKey(r['redemptionId'] ?? r['orderId']),
      leading: AdminRowIcon(
        Icons.confirmation_number_outlined,
        color: status == 'SUCCESS' ? AppTheme.accentText : (status == 'RESERVED' ? AppTheme.warnText : AppTheme.text2),
      ),
      title: '$code · $name',
      subtitle: [
        if (campaign.isNotEmpty && campaign != code) campaign,
        tier,
        '${adminInr(orig)} - ${adminInr(disc)} = ${adminInr(finalAmt)}',
      ].join(' · '),
      detail: [
        'Order ${r['orderId'] ?? '—'}',
        if (at > 0) adminDate(at, time: true),
      ].join(' · '),
      status: _statusChip(status, r['isFree'] == true),
      divider: !last,
      onTap: () => _openRedemptionDetail(r),
    );
  }

  Widget _statusChip(String status, bool isFree) {
    if (status == 'SUCCESS') {
      return StatusTextChip(
        icon: isFree ? Icons.celebration_rounded : Icons.check_circle_rounded,
        text: isFree ? '100% Free' : 'Paid',
        color: AppTheme.accentText,
      );
    }
    if (status == 'RESERVED') {
      return StatusTextChip(icon: Icons.hourglass_top_rounded, text: 'Reserved', color: AppTheme.warnText);
    }
    return StatusTextChip(icon: Icons.cancel_outlined, text: 'Cancelled', color: AppTheme.text2);
  }
}

class _FilterDropdown extends StatelessWidget {
  final String label;
  final String value;
  final List<DropdownMenuItem<String>> items;
  final ValueChanged<String?> onChanged;

  const _FilterDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isDense: true,
          style: AppText.caption.copyWith(fontWeight: FontWeight.w700),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _RedemptionDetailSheet extends StatelessWidget {
  final Map<String, dynamic> redemption;
  const _RedemptionDetailSheet({required this.redemption});

  @override
  Widget build(BuildContext context) {
    final r = redemption;
    final code = r['couponCode']?.toString() ?? '—';
    final campaign = r['campaignName']?.toString() ?? code;
    final name = r['userName']?.toString() ?? 'Rider';
    final email = r['userEmail']?.toString() ?? '';
    final phone = r['userPhone']?.toString() ?? '';
    final uid = r['userId']?.toString() ?? '';
    final orig = adminNumOrNull(r['originalPrice']) ?? 0;
    final disc = adminNumOrNull(r['discountAmount']) ?? 0;
    final finalAmt = adminNumOrNull(r['finalAmount']) ?? 0;
    final status = (r['status']?.toString() ?? 'SUCCESS').toUpperCase();
    final orderId = r['orderId']?.toString() ?? '—';
    final paymentId = r['paymentId']?.toString() ?? '';
    final method = r['method']?.toString() ?? 'RAZORPAY';
    final redeemedAt = adminEpoch(r['redeemedAt'] ?? r['activatedAt']);
    final reservedAt = adminEpoch(r['reservedAt']);
    final plan = r['categoryName']?.toString() ?? adminTierLabel(r['category']);

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: AppTheme.tint,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.accentText.withValues(alpha: 0.4)),
                ),
                child: Text(
                  code,
                  style: AppText.title.copyWith(fontSize: 16, color: AppTheme.accentText, fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(campaign, style: AppText.title.copyWith(fontSize: 15)),
                    Text(plan, style: AppText.caption),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 12),

          Text('FINANCIAL CALCULATION', style: AppText.caption.copyWith(fontWeight: FontWeight.w800, color: AppTheme.muted)),
          const SizedBox(height: 6),
          AdminDetailLine('Catalog Price', adminInr(orig)),
          AdminDetailLine('Discount Applied', '- ${adminInr(disc)}', color: AppTheme.warnText),
          AdminDetailLine('Net Paid by Rider', adminInr(finalAmt), color: AppTheme.accentText),
          AdminDetailLine('Status', status),
          const SizedBox(height: 14),

          Text('MEMBER DETAILS', style: AppText.caption.copyWith(fontWeight: FontWeight.w800, color: AppTheme.muted)),
          const SizedBox(height: 6),
          AdminDetailLine('Name', name),
          if (email.isNotEmpty) AdminDetailLine('Email', email),
          if (phone.isNotEmpty) AdminDetailLine('Phone', phone),
          AdminDetailLine('User ID', uid),
          const SizedBox(height: 14),

          Text('TRANSACTION AUDIT', style: AppText.caption.copyWith(fontWeight: FontWeight.w800, color: AppTheme.muted)),
          const SizedBox(height: 6),
          AdminDetailLine('Order ID', orderId),
          if (paymentId.isNotEmpty) AdminDetailLine('Payment ID', paymentId),
          AdminDetailLine('Method', method),
          if (reservedAt > 0) AdminDetailLine('Reserved at', adminDate(reservedAt, time: true)),
          if (redeemedAt > 0) AdminDetailLine('Redeemed at', adminDate(redeemedAt, time: true)),
          const SizedBox(height: 20),

          DsButton(
            label: 'Close',
            tone: DsButtonTone.outline,
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
