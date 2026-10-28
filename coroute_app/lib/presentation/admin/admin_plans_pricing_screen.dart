import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../subscription/plan_selector_screen.dart';
import 'admin_config_tabs.dart';
import 'admin_payments_tabs.dart';
import 'admin_promotions_tabs.dart';
import 'admin_ui.dart';
import 'master_admin_dashboard.dart';

/// The tabs of the "Payments & Plans" section.
enum AdminPaymentsTab {
  overview('Overview', Icons.space_dashboard_outlined),
  subscribers('Subscribers', Icons.card_membership_rounded),
  payments('Payments', Icons.receipt_long_rounded),
  offers('Offers', Icons.campaign_outlined),
  coupons('Coupons', Icons.discount_outlined),
  pricing('Pricing', Icons.sell_outlined),
  gateway('Gateway', Icons.account_balance_wallet_outlined),
  audit('Audit', Icons.fact_check_outlined);

  const AdminPaymentsTab(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Master admin: "Payments & Plans". Everything about money lives here (the
/// website admin page is gone): an overview, subscribers with grant / extend /
/// revoke, payments with refunds and CSV export, offers, coupons, plan
/// pricing, the Razorpay gateway (test / live keys) and the audit log.
///
/// The class keeps its old name so existing links into the console still work.
class AdminPlansPricingScreen extends StatefulWidget {
  /// The tab the section opens on (the dashboard cards open Gateway or Coupons).
  final AdminPaymentsTab initialTab;

  const AdminPlansPricingScreen({super.key, this.initialTab = AdminPaymentsTab.overview});

  @override
  State<AdminPlansPricingScreen> createState() => _AdminPlansPricingScreenState();
}

class _AdminPlansPricingScreenState extends State<AdminPlansPricingScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: AdminPaymentsTab.values.length,
    vsync: this,
    initialIndex: widget.initialTab.index,
  );

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// Jumps to another tab (the overview tiles link into the lists).
  void _goTo(AdminPaymentsTab tab) => _tabs.animateTo(tab.index);

  @override
  Widget build(BuildContext context) {
    return AdminShell(
      title: 'Payments & Plans',
      subtitle: 'Subscribers, payments, offers, pricing and the Razorpay gateway',
      actions: [
        AdminIconAction(
          icon: Icons.preview_rounded,
          label: 'Preview rider plans',
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PlanSelectorScreen())),
        ),
      ],
      nav: adminNavItems(context, AdminSection.plans),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
            child: TabBar(
              controller: _tabs,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelColor: AppTheme.accentText,
              unselectedLabelColor: AppTheme.text2,
              indicatorColor: AppTheme.accentText,
              dividerColor: Colors.transparent,
              labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
              unselectedLabelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              tabs: [
                for (final t in AdminPaymentsTab.values)
                  Tab(
                    height: 48,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [Icon(t.icon, size: 18), const SizedBox(width: 6), Text(t.label)],
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                AdminOverviewTab(onOpen: _goTo),
                const AdminSubscribersTab(),
                const AdminPaymentsListTab(),
                const AdminOffersTab(),
                const AdminCouponsTab(),
                const AdminPricingTab(),
                const AdminGatewayTab(),
                const AdminAuditTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
