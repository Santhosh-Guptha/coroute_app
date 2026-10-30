import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../subscription/plan_selector_screen.dart';
import 'admin_config_tabs.dart';
import 'admin_payments_tabs.dart';
import 'admin_promotions_tabs.dart';
import 'admin_ui.dart';
import 'master_admin_dashboard.dart';

/// Categories grouping the administrative configuration modules.
enum AdminPaymentsCategory {
  operations('OPERATIONS & LEDGER', Icons.query_stats_rounded),
  promotions('CATALOG & PRICING', Icons.sell_rounded),
  system('SYSTEM & GATEWAY', Icons.security_rounded);

  final String label;
  final IconData icon;
  const AdminPaymentsCategory(this.label, this.icon);
}

/// The modules of the "Payments & Plans" configuration console.
enum AdminPaymentsTab {
  overview(
    'Overview',
    Icons.space_dashboard_outlined,
    'Live subscription metrics & revenue KPI pulse',
    AdminPaymentsCategory.operations,
  ),
  subscribers(
    'Subscribers',
    Icons.card_membership_rounded,
    'Entitlements, manual grant & plan revocation',
    AdminPaymentsCategory.operations,
  ),
  payments(
    'Payments',
    Icons.receipt_long_rounded,
    'Ledger, settlements, refund dispatch & CSV export',
    AdminPaymentsCategory.operations,
  ),
  offers(
    'Offers',
    Icons.campaign_outlined,
    'Public promotional banners, discounts & trial codes',
    AdminPaymentsCategory.promotions,
  ),
  coupons(
    'Coupons',
    Icons.discount_outlined,
    'Single-use discount codes & redemption limits',
    AdminPaymentsCategory.promotions,
  ),
  pricing(
    'Pricing',
    Icons.sell_outlined,
    'Configure dynamic monthly & annual tier INR amounts',
    AdminPaymentsCategory.promotions,
  ),
  gateway(
    'Gateway',
    Icons.account_balance_wallet_outlined,
    'Razorpay Test / Live mode switch & API credentials',
    AdminPaymentsCategory.system,
  ),
  audit(
    'Audit',
    Icons.fact_check_outlined,
    'Immutable administrative audit trail of all changes',
    AdminPaymentsCategory.system,
  );

  const AdminPaymentsTab(this.label, this.icon, this.description, this.category);
  final String label;
  final IconData icon;
  final String description;
  final AdminPaymentsCategory category;
}

/// Master admin: "Payments & Plans" Configuration Console.
///
/// Designed as a high-density, mission-control configuration dashboard:
/// - Grouped into Operations, Catalog & Pricing, and System & Gateway domains.
/// - Left-docked menu rail on wide screens (>= 840 dp).
/// - Drawer/Modal module menu + glanceable quick pills on compact displays.
/// - Eliminates awkward horizontal scrolling tab clicks.
class AdminPlansPricingScreen extends StatefulWidget {
  /// The tab the section opens on (the dashboard cards open Gateway or Coupons).
  final AdminPaymentsTab initialTab;

  const AdminPlansPricingScreen({super.key, this.initialTab = AdminPaymentsTab.overview});

  @override
  State<AdminPlansPricingScreen> createState() => _AdminPlansPricingScreenState();
}

class _AdminPlansPricingScreenState extends State<AdminPlansPricingScreen> {
  late AdminPaymentsTab _currentTab = widget.initialTab;

  void _goTo(AdminPaymentsTab tab) {
    if (_currentTab != tab) {
      setState(() => _currentTab = tab);
    }
  }

  void _openModuleMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ModuleMenuSheet(
        current: _currentTab,
        onSelect: (tab) {
          Navigator.pop(ctx);
          _goTo(tab);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AdminShell(
      title: 'Configuration Console',
      subtitle: 'Subscribers, payments, pricing matrix and the Razorpay gateway',
      actions: [
        AdminIconAction(
          icon: Icons.preview_rounded,
          label: 'Preview rider plans',
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PlanSelectorScreen())),
        ),
      ],
      nav: adminNavItems(context, AdminSection.plans),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= adminWideBreakpoint;

          if (isWide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Left Configuration Menu Sidebar
                Container(
                  width: 250,
                  decoration: BoxDecoration(
                    color: AppTheme.card,
                    border: Border(
                      right: BorderSide(color: AppTheme.border, width: 1.5),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                        child: Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: AppTheme.accentText,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: AppTheme.accentText.withValues(alpha: 0.6),
                                    blurRadius: 4,
                                    spreadRadius: 1,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'MODULE CLUSTER',
                              style: AppText.overline.copyWith(
                                color: AppTheme.accentText,
                                letterSpacing: 1.2,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          children: [
                            for (final category in AdminPaymentsCategory.values) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                                child: Text(
                                  category.label,
                                  style: AppText.caption.copyWith(
                                    color: AppTheme.muted,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                              ),
                              for (final tab in AdminPaymentsTab.values.where((t) => t.category == category))
                                _SidebarMenuItem(
                                  tab: tab,
                                  isSelected: _currentTab == tab,
                                  onTap: () => _goTo(tab),
                                ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // Main Content Pane
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Breadcrumb bar
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        decoration: BoxDecoration(
                          color: AppTheme.card.withValues(alpha: 0.5),
                          border: Border(
                            bottom: BorderSide(color: AppTheme.border, width: 1),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(_currentTab.icon, size: 20, color: AppTheme.accentText),
                            const SizedBox(width: 10),
                            Text(
                              _currentTab.label,
                              style: AppText.title.copyWith(fontSize: 16, fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(width: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: AppTheme.tint,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: AppTheme.accentText.withValues(alpha: 0.3)),
                              ),
                              child: Text(
                                _currentTab.category.label,
                                style: AppText.caption.copyWith(
                                  color: AppTheme.accentText,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            const Spacer(),
                            Text(
                              _currentTab.description,
                              style: AppText.caption.copyWith(color: AppTheme.text2),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: IndexedStack(
                          index: _currentTab.index,
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
                ),
              ],
            );
          }

          // Compact / Mobile Layout: Executive Menu Header + Quick Action Pills
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                margin: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.border, width: 1.5),
                  boxShadow: dsFloatingShadow(),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: AppTheme.tint,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppTheme.accentText.withValues(alpha: 0.4)),
                          ),
                          child: Icon(_currentTab.icon, size: 20, color: AppTheme.accentText),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _currentTab.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.title.copyWith(fontSize: 15, fontWeight: FontWeight.w800),
                              ),
                              Text(
                                _currentTab.category.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.caption.copyWith(
                                  color: AppTheme.accentText,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Module Menu Button
                        ElevatedButton.icon(
                          onPressed: () => _openModuleMenu(context),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.tint,
                            foregroundColor: AppTheme.accentText,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(color: AppTheme.accentText.withValues(alpha: 0.5), width: 1.5),
                            ),
                          ),
                          icon: const Icon(Icons.dashboard_customize_rounded, size: 16),
                          label: const Text(
                            'Modules ▾',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    // Segmented Quick Access Pills: Overview, Pricing, Gateway, Subscribers
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _QuickPill(
                            tab: AdminPaymentsTab.overview,
                            isSelected: _currentTab == AdminPaymentsTab.overview,
                            onTap: () => _goTo(AdminPaymentsTab.overview),
                          ),
                          const SizedBox(width: 6),
                          _QuickPill(
                            tab: AdminPaymentsTab.pricing,
                            isSelected: _currentTab == AdminPaymentsTab.pricing,
                            onTap: () => _goTo(AdminPaymentsTab.pricing),
                          ),
                          const SizedBox(width: 6),
                          _QuickPill(
                            tab: AdminPaymentsTab.gateway,
                            isSelected: _currentTab == AdminPaymentsTab.gateway,
                            onTap: () => _goTo(AdminPaymentsTab.gateway),
                          ),
                          const SizedBox(width: 6),
                          _QuickPill(
                            tab: AdminPaymentsTab.subscribers,
                            isSelected: _currentTab == AdminPaymentsTab.subscribers,
                            onTap: () => _goTo(AdminPaymentsTab.subscribers),
                          ),
                          const SizedBox(width: 6),
                          _QuickPill(
                            tab: AdminPaymentsTab.payments,
                            isSelected: _currentTab == AdminPaymentsTab.payments,
                            onTap: () => _goTo(AdminPaymentsTab.payments),
                          ),
                          const SizedBox(width: 6),
                          InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => _openModuleMenu(context),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: AppTheme.bg,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: AppTheme.border),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.more_horiz_rounded, size: 14, color: AppTheme.text2),
                                  const SizedBox(width: 4),
                                  Text(
                                    'All Modules',
                                    style: AppText.caption.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: IndexedStack(
                  index: _currentTab.index,
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
          );
        },
      ),
    );
  }
}

class _SidebarMenuItem extends StatelessWidget {
  final AdminPaymentsTab tab;
  final bool isSelected;
  final VoidCallback onTap;

  const _SidebarMenuItem({
    required this.tab,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isSelected ? AppTheme.tint : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: isSelected ? Border.all(color: AppTheme.accentText.withValues(alpha: 0.5)) : null,
      ),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
        leading: Icon(
          tab.icon,
          size: 18,
          color: isSelected ? AppTheme.accentText : AppTheme.text2,
        ),
        title: Text(
          tab.label,
          style: TextStyle(
            color: isSelected ? AppTheme.accentText : AppTheme.text,
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
        trailing: isSelected
            ? Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: AppTheme.accentText,
                  shape: BoxShape.circle,
                ),
              )
            : null,
        onTap: onTap,
      ),
    );
  }
}

class _QuickPill extends StatelessWidget {
  final AdminPaymentsTab tab;
  final bool isSelected;
  final VoidCallback onTap;

  const _QuickPill({
    required this.tab,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.tint : AppTheme.bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? AppTheme.accentText : AppTheme.border,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              tab.icon,
              size: 13,
              color: isSelected ? AppTheme.accentText : AppTheme.text2,
            ),
            const SizedBox(width: 5),
            Text(
              tab.label,
              style: TextStyle(
                color: isSelected ? AppTheme.accentText : AppTheme.text2,
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModuleMenuSheet extends StatelessWidget {
  final AdminPaymentsTab current;
  final ValueChanged<AdminPaymentsTab> onSelect;

  const _ModuleMenuSheet({
    required this.current,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: AppTheme.border, width: 1.5),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Handle bar
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10, bottom: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppTheme.tint,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.dashboard_customize_rounded, color: AppTheme.accentText, size: 22),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Configuration Modules',
                          style: AppText.title.copyWith(fontSize: 18, fontWeight: FontWeight.w800),
                        ),
                        Text(
                          'Select an operational, catalog or infrastructure module',
                          style: AppText.caption.copyWith(color: AppTheme.text2),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close_rounded, color: AppTheme.text2),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  for (final category in AdminPaymentsCategory.values) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
                      child: Row(
                        children: [
                          Icon(category.icon, size: 14, color: AppTheme.accentText),
                          const SizedBox(width: 8),
                          Text(
                            category.label,
                            style: AppText.caption.copyWith(
                              color: AppTheme.accentText,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.0,
                            ),
                          ),
                        ],
                      ),
                    ),
                    for (final tab in AdminPaymentsTab.values.where((t) => t.category == category))
                      _ModuleCardItem(
                        tab: tab,
                        isSelected: current == tab,
                        onTap: () => onSelect(tab),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModuleCardItem extends StatelessWidget {
  final AdminPaymentsTab tab;
  final bool isSelected;
  final VoidCallback onTap;

  const _ModuleCardItem({
    required this.tab,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isSelected ? AppTheme.tint : AppTheme.bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSelected ? AppTheme.accentText : AppTheme.border,
          width: isSelected ? 2 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: isSelected ? AppTheme.accentText : AppTheme.card,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected ? AppTheme.accentText : AppTheme.border,
                  ),
                ),
                child: Icon(
                  tab.icon,
                  size: 22,
                  color: isSelected ? Colors.black : AppTheme.accentText,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          tab.label,
                          style: TextStyle(
                            color: isSelected ? AppTheme.accentText : AppTheme.text,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (isSelected) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppTheme.accentText,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'ACTIVE',
                              style: TextStyle(
                                color: Colors.black,
                                fontSize: 9,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tab.description,
                      style: AppText.caption.copyWith(color: AppTheme.text2),
                    ),
                  ],
                ),
              ),
              Icon(
                isSelected ? Icons.check_circle_rounded : Icons.chevron_right_rounded,
                color: isSelected ? AppTheme.accentText : AppTheme.muted,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
