import 'package:flutter/material.dart';
import 'admin_config_tabs.dart';
import 'admin_payment_analytics_tab.dart';
import 'admin_payments_tabs.dart';
import 'admin_promotions_tabs.dart';
import 'admin_ui.dart';
import 'master_admin_dashboard.dart';

/// The four tabs of Payments.
enum AdminPaymentsTab {
  /// Every payment, with search, filters, refunds and CSV export.
  payments('Payments'),

  /// Revenue for a period: totals, per day, per plan and per coupon.
  revenue('Revenue'),

  /// The plans riders can buy (price, seats, on sale).
  plans('Plans'),

  /// Coupon codes and the automatic offers at checkout.
  coupons('Coupons');

  const AdminPaymentsTab(this.label);
  final String label;
}

/// Master admin: Payments. Four tabs, the same on a phone and a tablet: payments, revenue,
/// plans and coupons. The payment gateway keys and the audit log are in Settings; a rider's plan
/// is changed from the rider's details.
class AdminPlansPricingScreen extends StatefulWidget {
  /// The tab the section opens on.
  final AdminPaymentsTab initialTab;

  const AdminPlansPricingScreen({super.key, this.initialTab = AdminPaymentsTab.payments});

  @override
  State<AdminPlansPricingScreen> createState() => _AdminPlansPricingScreenState();
}

class _AdminPlansPricingScreenState extends State<AdminPlansPricingScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: AdminPaymentsTab.values.length, vsync: this, initialIndex: widget.initialTab.index);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AdminShell(
      title: 'Payments',
      subtitle: 'Payments, revenue, plans and coupons',
      nav: adminNavItems(context, AdminSection.payments),
      body: AdminTabbedBody(
        controller: _tabs,
        labels: [for (final t in AdminPaymentsTab.values) t.label],
        // Each tab keeps its scroll position and data when you switch back.
        children: const [
          AdminPaymentsListTab(),
          AdminPaymentAnalyticsTab(),
          AdminPricingTab(),
          AdminCouponsTab(),
        ],
      ),
    );
  }
}
