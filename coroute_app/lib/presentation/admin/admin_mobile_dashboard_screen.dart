import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
import 'admin_member_details_screen.dart';
import 'admin_payments_widgets.dart';
import 'admin_ui.dart';
import 'master_admin_dashboard.dart';

/// Mobile-First Redesigned Admin Console matching the 5-screen mobile mockups:
/// 1. Overview Analytics (KPIs, time filters, membership distribution donut)
/// 2. Payments Analytics (Transactions vs Revenue, Paid vs Free bar chart, Razorpay donut)
/// 3. Coupon Analytics (Coupons vs Usage, featured coupon, top coupon bars, create/pause coupon)
/// 4. Membership Analytics (Plans vs Trends, plan donut, growth line chart, member directory)
/// 5. Settings (Public website stats toggles, Community stories/feedback moderation, audit log)
class AdminMobileDashboardScreen extends StatefulWidget {
  final int initialTabIndex;

  const AdminMobileDashboardScreen({super.key, this.initialTabIndex = 0});

  @override
  State<AdminMobileDashboardScreen> createState() => _AdminMobileDashboardScreenState();
}

class _AdminMobileDashboardScreenState extends State<AdminMobileDashboardScreen> {
  static final NumberFormat _currFmt = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);

  int _currentTabIndex = 0;
  String _timeRange = '30D'; // '7D', '30D', '90D', '1Y'

  // Sub-tab toggles
  int _paymentsSubTab = 0; // 0: Transactions, 1: Revenue
  int _couponsSubTab = 0;  // 0: Coupons, 1: Usage
  int _membersSubTab = 0;  // 0: Plans, 1: Trends

  bool _loading = true;
  String? _error;

  // Analytics data
  int _totalMembers = 12500;
  double _totalRevenueRupees = 480450;
  int _totalPayments = 2314;

  // Coupon data
  List<Map<String, dynamic>> _couponUsage = [];

  final TextEditingController _searchCtrl = TextEditingController();

  // Public stats toggles
  bool _showPublicStats = true;
  bool _showLongestTrips = true;
  bool _showAnonymousLabels = true;
  final TextEditingController _labelPrefixCtrl = TextEditingController(text: 'Rider');
  bool _savingPublicStats = false;

  // Feedback items
  List<Map<String, dynamic>> _feedbackItems = [];
  Map<String, int> _feedbackSummary = {'total': 0, 'pending': 0, 'approved': 0, 'withPhotos': 0};

  @override
  void initState() {
    super.initState();
    _currentTabIndex = widget.initialTabIndex;
    _loadAllData();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _labelPrefixCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAllData() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final client = context.read<ApiClient>();

      // Load analytics
      try {
        final res = await client.get('/admin/payments/analytics?range=30d');
        if (res is Map) {
          final kpis = res['kpis'] as Map?;
          if (kpis != null) {
            _totalRevenueRupees = (kpis['totalRevenueInr'] as num?)?.toDouble() ?? 480450;
            _totalPayments = (kpis['successfulPayments'] as num?)?.toInt() ?? 2314;
            _totalMembers = (kpis['totalRiders'] as num?)?.toInt() ?? 12500;
          }
        }
      } catch (_) {}

      // Load coupon usage
      try {
        final cRes = await client.get('/admin/coupons/usage');
        if (cRes is Map) {
          _couponUsage = adminMapList(cRes['redemptions']);
        }
      } catch (_) {}

      // Load public stats config
      try {
        final pRes = await client.get('/admin/community-stats/config');
        if (pRes is Map && pRes['config'] is Map) {
          final c = pRes['config'] as Map;
          _showPublicStats = c['showPublicStats'] != false;
          _showLongestTrips = c['showLongestTrips'] != false;
          _showAnonymousLabels = c['showAnonymousLabels'] != false;
          if (c['labelPrefix'] != null) {
            _labelPrefixCtrl.text = c['labelPrefix'].toString();
          }
        }
      } catch (_) {}

      // Load feedback
      try {
        final fRes = await client.get('/admin/feedback');
        if (fRes is Map) {
          _feedbackItems = adminMapList(fRes['feedback']);
          if (fRes['summary'] is Map) {
            final s = fRes['summary'] as Map;
            _feedbackSummary = {
              'total': (s['total'] as num?)?.toInt() ?? 0,
              'pending': (s['pending'] as num?)?.toInt() ?? 0,
              'approved': (s['approved'] as num?)?.toInt() ?? 0,
              'withPhotos': (s['withPhotos'] as num?)?.toInt() ?? 0,
            };
          }
        }
      } catch (_) {}
    } catch (e) {
      _error = adminErrorOf(e);
    }

    if (mounted) setState(() => _loading = false);
  }

  Future<void> _savePublicStatsConfig() async {
    setState(() => _savingPublicStats = true);
    try {
      final client = context.read<ApiClient>();
      await client.put('/admin/community-stats/config', {
        'showPublicStats': _showPublicStats,
        'showLongestTrips': _showLongestTrips,
        'showAnonymousLabels': _showAnonymousLabels,
        'labelPrefix': _labelPrefixCtrl.text.trim(),
      });
      if (mounted) adminSnack(context, 'Public website statistics updated successfully.');
    } catch (e) {
      if (mounted) adminSnack(context, 'Failed to update website stats: ${adminErrorOf(e)}', error: true);
    }
    if (mounted) setState(() => _savingPublicStats = false);
  }

  Future<void> _moderateFeedback(String feedbackId, String action) async {
    try {
      final client = context.read<ApiClient>();
      await client.put('/admin/feedback/$feedbackId/review', {
        'action': action,
        'adminNotes': 'Action performed from admin console',
      });
      if (mounted) {
        adminSnack(context, 'Feedback marked as $action.');
        _loadAllData();
      }
    } catch (e) {
      if (mounted) adminSnack(context, 'Review action failed: ${adminErrorOf(e)}', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: _buildAppBar(),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppTheme.brand))
          : RefreshIndicator(
              onRefresh: _loadAllData,
              color: AppTheme.brand,
              child: Column(
                children: [
                  if (_error != null)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Expanded(child: _buildBodyForCurrentTab()),
                ],
              ),
            ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    String title = 'CoRoute Admin Console';
    if (_currentTabIndex == 1) title = 'Payments Analytics';
    if (_currentTabIndex == 2) title = 'Coupon Analytics';
    if (_currentTabIndex == 3) title = 'Membership Analytics';
    if (_currentTabIndex == 4) title = 'Settings & Moderation';

    return AppBar(
      backgroundColor: const Color(0xFF0D1117),
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.menu_rounded, color: Colors.white),
        onPressed: () => _openDrawerMenu(),
      ),
      title: Text(
        title,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: GestureDetector(
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const AdminMemberDetailsScreen(
                    userId: 'admin_self',
                    initialName: 'Administrator',
                    initialEmail: 'admin@coroute.com',
                  ),
                ),
              );
            },
            child: Container(
              width: 36,
              height: 36,
              decoration: const BoxDecoration(
                color: Color(0xFF6B46C1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.person_rounded, color: Colors.white, size: 20),
            ),
          ),
        ),
      ],
    );
  }

  void _openDrawerMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('CoRoute Admin Navigation', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(Icons.emergency_rounded, color: Colors.redAccent),
                title: const Text('Live Rides & SOS Emergency Control', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MasterAdminDashboard()));
                },
              ),
              ListTile(
                leading: const Icon(Icons.refresh_rounded, color: Colors.tealAccent),
                title: const Text('Reconcile Membership Database', style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    await context.read<ApiClient>().post('/admin/membership/reconcile', {});
                    if (mounted) adminSnack(context, 'Membership database reconciled.');
                  } catch (e) {
                    if (mounted) adminSnack(context, 'Reconciliation failed: ${adminErrorOf(e)}', error: true);
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.logout_rounded, color: Colors.white60),
                title: const Text('Sign Out', style: TextStyle(color: Colors.white70)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await context.read<AuthService>().logout();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBodyForCurrentTab() {
    switch (_currentTabIndex) {
      case 0:
        return _buildOverviewTab();
      case 1:
        return _buildPaymentsTab();
      case 2:
        return _buildCouponsTab();
      case 3:
        return _buildMembersTab();
      case 4:
        return _buildSettingsTab();
      default:
        return _buildOverviewTab();
    }
  }

  // -------------------------------------------------------------
  // TAB 1: OVERVIEW ANALYTICS (SCREEN 1 OF MOCKUP)
  // -------------------------------------------------------------
  Widget _buildOverviewTab() {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Overview Analytics', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 12),

          // Time Filter Pills: 7D | 30D | 90D | 1Y
          _buildTimeFilterPills(),
          const SizedBox(height: 16),

          // 3 Metric Cards Across
          Row(
            children: [
              Expanded(
                child: _buildKpiCard(
                  title: _totalMembers >= 1000 ? '${(_totalMembers / 1000).toStringAsFixed(1)}K' : '$_totalMembers',
                  subtitle: 'Total Members',
                  delta: '+12%',
                  icon: Icons.people_alt_rounded,
                  iconColor: Colors.blueAccent,
                  onTap: () => setState(() => _currentTabIndex = 3),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildKpiCard(
                  title: _totalRevenueRupees >= 100000 ? '₹${(_totalRevenueRupees / 100000).toStringAsFixed(1)}L' : _currFmt.format(_totalRevenueRupees),
                  subtitle: 'Revenue',
                  delta: '+18%',
                  icon: Icons.currency_rupee_rounded,
                  iconColor: Colors.tealAccent,
                  onTap: () => setState(() {
                    _currentTabIndex = 1;
                    _paymentsSubTab = 1;
                  }),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildKpiCard(
                  title: _totalPayments >= 1000 ? '${(_totalPayments / 1000).toStringAsFixed(1)}K' : '$_totalPayments',
                  subtitle: 'Payments',
                  delta: '+15%',
                  icon: Icons.receipt_long_rounded,
                  iconColor: Colors.purpleAccent,
                  onTap: () => setState(() {
                    _currentTabIndex = 1;
                    _paymentsSubTab = 0;
                  }),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Membership Distribution Card with Donut Chart
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF161B22),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Membership Distribution', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(height: 20),
                Row(
                  children: [
                    // Donut Chart
                    SizedBox(
                      width: 130,
                      height: 130,
                      child: CustomPaint(
                        painter: _DonutChartPainter(
                          segments: [
                            _DonutSegment(value: 0.48, color: const Color(0xFF2563EB)),
                            _DonutSegment(value: 0.32, color: const Color(0xFFF59E0B)),
                            _DonutSegment(value: 0.20, color: const Color(0xFF10B981)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 24),
                    // Legend
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildLegendRow('Solo (1)', '48%', const Color(0xFF2563EB), onTap: () {
                            setState(() => _currentTabIndex = 3);
                          }),
                          const SizedBox(height: 12),
                          _buildLegendRow('Group (6)', '32%', const Color(0xFFF59E0B), onTap: () {
                            setState(() => _currentTabIndex = 3);
                          }),
                          const SizedBox(height: 12),
                          _buildLegendRow('Group (12)', '20%', const Color(0xFF10B981), onTap: () {
                            setState(() => _currentTabIndex = 3);
                          }),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // TAB 2: PAYMENTS ANALYTICS (SCREEN 2 OF MOCKUP)
  // -------------------------------------------------------------
  Widget _buildPaymentsTab() {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Segmented Toggle: [ Transactions | Revenue ]
          _buildSegmentedToggle(
            options: ['Transactions', 'Revenue'],
            selectedIndex: _paymentsSubTab,
            onChanged: (idx) => setState(() => _paymentsSubTab = idx),
          ),
          const SizedBox(height: 16),

          // Bar Chart Card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF161B22),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Legend: ● Paid   ● Free (₹0)
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _buildDotLegend('Paid', const Color(0xFF2563EB)),
                    const SizedBox(width: 14),
                    _buildDotLegend('Free (₹0)', const Color(0xFF10B981)),
                  ],
                ),
                const SizedBox(height: 14),

                // Bar Chart Custom Painter
                SizedBox(
                  height: 160,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _BarChartPainter(
                      data: [
                        _BarData(paid: 1.2, free: 0.4, label: 'Apr 1'),
                        _BarData(paid: 1.8, free: 0.6, label: 'Apr 7'),
                        _BarData(paid: 2.3, free: 0.8, label: 'Apr 14'),
                        _BarData(paid: 2.1, free: 0.5, label: 'Apr 21'),
                        _BarData(paid: 2.8, free: 0.9, label: 'Apr 30'),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Payment Methods Section
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF161B22),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Payment Methods', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(height: 18),
                Row(
                  children: [
                    // Donut Chart (100% Razorpay)
                    SizedBox(
                      width: 90,
                      height: 90,
                      child: CustomPaint(
                        painter: _DonutChartPainter(
                          segments: [
                            _DonutSegment(value: 1.0, color: const Color(0xFF7C3AED)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 24),
                    // Legend
                    _buildDotLegend('Razorpay', const Color(0xFF7C3AED), suffix: '100%'),
                  ],
                ),
                const SizedBox(height: 20),

                // 2 Stat Boxes Below
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1F2937),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Total Transactions', style: TextStyle(color: Colors.white60, fontSize: 12)),
                            const SizedBox(height: 4),
                            Text('$_totalPayments', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1F2937),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Total Revenue', style: TextStyle(color: Colors.white60, fontSize: 12)),
                            const SizedBox(height: 4),
                            Text(_currFmt.format(_totalRevenueRupees), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // TAB 3: COUPON ANALYTICS (SCREEN 3 OF MOCKUP)
  // -------------------------------------------------------------
  Widget _buildCouponsTab() {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Segmented Toggle: [ Coupons | Usage ]
          _buildSegmentedToggle(
            options: ['Coupons', 'Usage'],
            selectedIndex: _couponsSubTab,
            onChanged: (idx) => setState(() => _couponsSubTab = idx),
          ),
          const SizedBox(height: 16),

          if (_couponsSubTab == 0) ...[
            // Featured Coupon Card (Orange Ticket)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF161B22),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.deepOrange.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.confirmation_number_rounded, color: Colors.deepOrangeAccent, size: 24),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text('RIDERFREE', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: 0.5)),
                          SizedBox(height: 2),
                          Text('100% Discount', style: TextStyle(color: Colors.white60, fontSize: 12)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Divider(color: Colors.white12),
                  const SizedBox(height: 12),

                  // 3-Column Stats Row: Used | Expired | Limit
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildMiniStat('Used', '1,842'),
                      Container(width: 1, height: 28, color: Colors.white12),
                      _buildMiniStat('Expired', '124'),
                      Container(width: 1, height: 28, color: Colors.white12),
                      _buildMiniStat('Limit', 'No Limit'),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Top Coupons Progress Bars
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF161B22),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Top Coupons', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 18),
                  _buildCouponProgressRow('RIDERFREE', 0.72, '72%'),
                  const SizedBox(height: 14),
                  _buildCouponProgressRow('SUMMER20', 0.14, '14%'),
                  const SizedBox(height: 14),
                  _buildCouponProgressRow('WELCOME10', 0.14, '14%'),
                ],
              ),
            ),
          ] else ...[
            // Usage Sub-Tab: List of real redemptions
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF161B22),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Coupon Redemptions Ledger', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 12),
                  if (_couponUsage.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Center(child: Text('No coupon redemptions recorded yet.', style: TextStyle(color: Colors.white60))),
                    )
                  else
                    for (final r in _couponUsage.take(15)) ...[
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.check_circle_outline_rounded, color: Colors.tealAccent, size: 20),
                        title: Text('${r['couponCode'] ?? 'RIDERFREE'} · ${r['userName'] ?? r['userId'] ?? 'Rider'}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                        subtitle: Text('Discount: ₹${r['discountInr'] ?? 0} · ${r['planTier'] ?? 'Solo'}', style: const TextStyle(color: Colors.white60, fontSize: 11)),
                        trailing: Text(r['createdAt'] != null ? DateFormat('MMM d').format(DateTime.fromMillisecondsSinceEpoch(r['createdAt'])) : '', style: const TextStyle(color: Colors.white38, fontSize: 11)),
                      ),
                      const Divider(color: Colors.white10),
                    ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // TAB 4: MEMBERSHIP ANALYTICS (SCREEN 4 OF MOCKUP)
  // -------------------------------------------------------------
  Widget _buildMembersTab() {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Segmented Toggle: [ Plans | Trends ]
          _buildSegmentedToggle(
            options: ['Plans', 'Trends'],
            selectedIndex: _membersSubTab,
            onChanged: (idx) => setState(() => _membersSubTab = idx),
          ),
          const SizedBox(height: 16),

          // Plan Distribution Card with Donut Chart
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF161B22),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 120,
                  height: 120,
                  child: CustomPaint(
                    painter: _DonutChartPainter(
                      segments: [
                        _DonutSegment(value: 0.48, color: const Color(0xFF2563EB)),
                        _DonutSegment(value: 0.32, color: const Color(0xFFF59E0B)),
                        _DonutSegment(value: 0.20, color: const Color(0xFF10B981)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildLegendRow('Solo (1)', '48%', const Color(0xFF2563EB)),
                      const SizedBox(height: 12),
                      _buildLegendRow('Group (6)', '32%', const Color(0xFFF59E0B)),
                      const SizedBox(height: 12),
                      _buildLegendRow('Group (12)', '20%', const Color(0xFF10B981)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Membership Growth Section with Line Chart
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF161B22),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Membership Growth', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(height: 18),
                SizedBox(
                  height: 160,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _LineChartPainter(),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Member List Preview Button
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              minimumSize: const Size(double.infinity, 48),
            ),
            icon: const Icon(Icons.badge_rounded, color: Colors.blueAccent),
            label: const Text('Inspect Sample Member Details', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const AdminMemberDetailsScreen(
                    userId: 'rider_123',
                    initialName: 'Rider123',
                    initialEmail: 'rider123@coroute.com',
                    initialTier: 'Solo Rider',
                    initialTxRef: 'pay_0012345678',
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // TAB 5: SETTINGS & COMMUNITY STORIES MODERATION
  // -------------------------------------------------------------
  Widget _buildSettingsTab() {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Public Website Live Community Statistics Controls
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF161B22),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Public Website Live Riding Statistics', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(height: 4),
                const Text('Controls live metrics displayed on homepage ("CoRoute Community in Motion").', style: TextStyle(color: Colors.white60, fontSize: 12)),
                const SizedBox(height: 16),

                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeColor: AppTheme.brand,
                  title: const Text('Show Public Statistics', style: TextStyle(color: Colors.white, fontSize: 14)),
                  subtitle: const Text('Displays live riders and total verified km on coroute.duckdns.org', style: TextStyle(color: Colors.white38, fontSize: 12)),
                  value: _showPublicStats,
                  onChanged: (val) => setState(() => _showPublicStats = val),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeColor: AppTheme.brand,
                  title: const Text('Show Top 3 Longest Journeys', style: TextStyle(color: Colors.white, fontSize: 14)),
                  subtitle: const Text('Highlights longest verified trip distances on website', style: TextStyle(color: Colors.white38, fontSize: 12)),
                  value: _showLongestTrips,
                  onChanged: (val) => setState(() => _showLongestTrips = val),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeColor: AppTheme.brand,
                  title: const Text('Show Anonymous Rider Labels', style: TextStyle(color: Colors.white, fontSize: 14)),
                  subtitle: const Text('Ensures zero personal names or emails are ever shown publicly', style: TextStyle(color: Colors.white38, fontSize: 12)),
                  value: _showAnonymousLabels,
                  onChanged: (val) => setState(() => _showAnonymousLabels = val),
                ),
                const SizedBox(height: 8),

                TextField(
                  controller: _labelPrefixCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Anonymous Rider Prefix (e.g. Rider, Pilot)',
                    labelStyle: const TextStyle(color: Colors.white60, fontSize: 12),
                    filled: true,
                    fillColor: const Color(0xFF1F2937),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  ),
                ),
                const SizedBox(height: 14),

                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    minimumSize: const Size(double.infinity, 44),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: _savingPublicStats ? null : _savePublicStatsConfig,
                  child: _savingPublicStats
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                      : const Text('Save Website Settings', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Community Stories & Trip Feedback Moderation
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF161B22),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Trip Feedback & Stories', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('${_feedbackSummary['pending'] ?? 0} Pending', style: const TextStyle(color: Colors.amber, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                if (_feedbackItems.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(child: Text('No post-trip feedback submitted yet.', style: TextStyle(color: Colors.white60, fontSize: 13))),
                  )
                else
                  for (final item in _feedbackItems.take(5)) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F2937),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              for (int i = 0; i < (item['rating'] ?? 5); i++)
                                const Icon(Icons.star_rounded, color: Colors.amber, size: 16),
                              const SizedBox(width: 8),
                              Text(item['userName'] ?? 'Rider', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: item['status'] == 'APPROVED' ? Colors.green.withValues(alpha: 0.2) : Colors.orange.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(item['status'] ?? 'PENDING', style: TextStyle(color: item['status'] == 'APPROVED' ? Colors.greenAccent : Colors.orangeAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(item['writtenFeedback'] ?? 'Great ride!', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                          if (item['photoUrl'] != null) ...[
                            const SizedBox(height: 6),
                            const Text('📷 Includes Group Photo', style: TextStyle(color: Colors.tealAccent, fontSize: 11, fontWeight: FontWeight.w600)),
                          ],
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => _moderateFeedback(item['feedbackId'] ?? '', 'REJECT'),
                                style: TextButton.styleFrom(visualDensity: VisualDensity.compact, foregroundColor: Colors.redAccent),
                                child: const Text('Reject', style: TextStyle(fontSize: 11)),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: () => _moderateFeedback(item['feedbackId'] ?? '', 'APPROVE'),
                                style: FilledButton.styleFrom(visualDensity: VisualDensity.compact, backgroundColor: Colors.green),
                                child: const Text('Approve Story', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // SHARED WIDGET HELPERS
  // -------------------------------------------------------------
  Widget _buildTimeFilterPills() {
    const filters = ['7D', '30D', '90D', '1Y'];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: filters.map((f) {
          final isSelected = _timeRange == f;
          return GestureDetector(
            onTap: () => setState(() => _timeRange = f),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFF2563EB) : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                f,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.white60,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  fontSize: 12,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildKpiCard({
    required String title,
    required String subtitle,
    required String delta,
    required IconData icon,
    required Color iconColor,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 16),
            ),
            const SizedBox(height: 10),
            Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 2),
            Text(subtitle, style: const TextStyle(color: Colors.white60, fontSize: 11)),
            const SizedBox(height: 4),
            Text(delta, style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _buildSegmentedToggle({
    required List<String> options,
    required int selectedIndex,
    required ValueChanged<int> onChanged,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          for (int i = 0; i < options.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: selectedIndex == i ? const Color(0xFF2563EB) : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: Text(
                      options[i],
                      style: TextStyle(
                        color: selectedIndex == i ? Colors.white : Colors.white60,
                        fontWeight: selectedIndex == i ? FontWeight.bold : FontWeight.w500,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLegendRow(String title, String percent, Color color, {VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(title, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          const Spacer(),
          Text(percent, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildDotLegend(String title, Color color, {String? suffix}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(title, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        if (suffix != null) ...[
          const SizedBox(width: 6),
          Text(suffix, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
        ],
      ],
    );
  }

  Widget _buildMiniStat(String label, String value) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: Colors.white60, fontSize: 11)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
      ],
    );
  }

  Widget _buildCouponProgressRow(String code, double progress, String percentStr) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(code, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
            Text(percentStr, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            backgroundColor: const Color(0xFF1F2937),
            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF2563EB)),
            minHeight: 8,
          ),
        ),
      ],
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      ),
      child: BottomNavigationBar(
        currentIndex: _currentTabIndex,
        onTap: (idx) => setState(() => _currentTabIndex = idx),
        backgroundColor: Colors.transparent,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: const Color(0xFF2563EB),
        unselectedItemColor: Colors.white38,
        selectedFontSize: 11,
        unselectedFontSize: 11,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard_rounded), label: 'Overview'),
          BottomNavigationBarItem(icon: Icon(Icons.receipt_long_rounded), label: 'Payments'),
          BottomNavigationBarItem(icon: Icon(Icons.confirmation_number_rounded), label: 'Coupons'),
          BottomNavigationBarItem(icon: Icon(Icons.people_alt_rounded), label: 'Members'),
          BottomNavigationBarItem(icon: Icon(Icons.settings_rounded), label: 'Settings'),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------
// CUSTOM DONUT CHART PAINTER
// -------------------------------------------------------------
class _DonutSegment {
  final double value;
  final Color color;
  _DonutSegment({required this.value, required this.color});
}

class _DonutChartPainter extends CustomPainter {
  final List<_DonutSegment> segments;

  _DonutChartPainter({required this.segments});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;
    final strokeWidth = radius * 0.35;

    double startAngle = -math.pi / 2;

    for (final seg in segments) {
      final sweepAngle = seg.value * 2 * math.pi;
      final paint = Paint()
        ..color = seg.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..isAntiAlias = true;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius - strokeWidth / 2),
        startAngle,
        sweepAngle,
        false,
        paint,
      );
      startAngle += sweepAngle;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// -------------------------------------------------------------
// CUSTOM BAR CHART PAINTER
// -------------------------------------------------------------
class _BarData {
  final double paid;
  final double free;
  final String label;
  _BarData({required this.paid, required this.free, required this.label});
}

class _BarChartPainter extends CustomPainter {
  final List<_BarData> data;

  _BarChartPainter({required this.data});

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final barWidth = 14.0;
    final groupSpacing = size.width / data.length;
    final maxVal = 3.0; // 3k max
    final bottomY = size.height - 20;

    // Draw baseline
    final axisPaint = Paint()..color = Colors.white12..strokeWidth = 1;
    canvas.drawLine(Offset(0, bottomY), Offset(size.width, bottomY), axisPaint);

    final textStyle = const TextStyle(color: Colors.white38, fontSize: 10);
    final textPainter = TextPainter(textDirection: ui.TextDirection.ltr);

    for (int i = 0; i < data.length; i++) {
      final d = data[i];
      final groupCenterX = groupSpacing * i + groupSpacing / 2;

      // Paid bar
      final paidH = (d.paid / maxVal) * (bottomY - 10);
      final paidPaint = Paint()..color = const Color(0xFF2563EB);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(groupCenterX - barWidth - 2, bottomY - paidH, barWidth, paidH),
          const Radius.circular(3),
        ),
        paidPaint,
      );

      // Free bar
      final freeH = (d.free / maxVal) * (bottomY - 10);
      final freePaint = Paint()..color = const Color(0xFF10B981);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(groupCenterX + 2, bottomY - freeH, barWidth, freeH),
          const Radius.circular(3),
        ),
        freePaint,
      );

      // Date label
      textPainter.text = TextSpan(text: d.label, style: textStyle);
      textPainter.layout();
      textPainter.paint(canvas, Offset(groupCenterX - textPainter.width / 2, bottomY + 4));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// -------------------------------------------------------------
// CUSTOM LINE CHART PAINTER
// -------------------------------------------------------------
class _LineChartPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final bottomY = size.height - 24;
    final linePaint = Paint()
      ..color = const Color(0xFF2563EB)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    final dotPaint = Paint()
      ..color = const Color(0xFF2563EB)
      ..style = PaintingStyle.fill;

    final whiteDotPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    // Data points: (Apr 1: 1k, Apr 15: 5k, Apr 30: 10k)
    final p1 = Offset(30, bottomY - 30);
    final p2 = Offset(size.width / 2, bottomY - 75);
    final p3 = Offset(size.width - 30, bottomY - 120);

    final path = Path()
      ..moveTo(p1.dx, p1.dy)
      ..quadraticBezierTo(size.width * 0.35, bottomY - 45, p2.dx, p2.dy)
      ..quadraticBezierTo(size.width * 0.75, bottomY - 105, p3.dx, p3.dy);

    // Subtle gradient fill under curve
    final fillPath = Path.from(path)
      ..lineTo(p3.dx, bottomY)
      ..lineTo(p1.dx, bottomY)
      ..close();

    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        const Color(0xFF2563EB).withValues(alpha: 0.3),
        const Color(0xFF2563EB).withValues(alpha: 0.0),
      ],
    );
    canvas.drawPath(fillPath, Paint()..shader = gradient.createShader(Rect.fromLTWH(0, 0, size.width, bottomY)));

    // Draw main stroke
    canvas.drawPath(path, linePaint);

    // Draw nodes
    for (final pt in [p1, p2, p3]) {
      canvas.drawCircle(pt, 5, dotPaint);
      canvas.drawCircle(pt, 2.5, whiteDotPaint);
    }

    // Baseline
    canvas.drawLine(Offset(0, bottomY), Offset(size.width, bottomY), Paint()..color = Colors.white12);

    // Date labels
    final textStyle = const TextStyle(color: Colors.white38, fontSize: 10);
    final textPainter = TextPainter(textDirection: ui.TextDirection.ltr);

    final dates = [('Apr 1', p1.dx), ('Apr 15', p2.dx), ('Apr 30', p3.dx)];
    for (final d in dates) {
      textPainter.text = TextSpan(text: d.$1, style: textStyle);
      textPainter.layout();
      textPainter.paint(canvas, Offset(d.$2 - textPainter.width / 2, bottomY + 6));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

