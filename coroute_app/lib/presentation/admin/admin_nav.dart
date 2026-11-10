import 'package:flutter/material.dart';

import 'admin_crews_screen.dart';
import 'admin_diag_logs_screen.dart';
import 'admin_features_screen.dart';
import 'admin_insights_screen.dart';
import 'admin_place_reviews_screen.dart';
import 'admin_plans_pricing_screen.dart';
import 'admin_reviews_screen.dart';
import 'admin_ride_history_screen.dart';
import 'admin_safety_screen.dart';
import 'admin_settings_screen.dart';
import 'admin_ui.dart';
import 'admin_users_screen.dart';
import 'marketing/marketing_studio_screen.dart';

/// The six top-level sections of the admin console (rail on wide screens, drawer on
/// phones). Each groups one or more pages ([AdminPage]); a section with several pages
/// shows them as a row of tabs under the title, so every earlier screen is still one
/// tap away.
enum AdminSection {
  dashboard('Overview', Icons.space_dashboard_outlined),
  riders('Riders', Icons.people_alt_outlined),
  ridesSafety('Rides & safety', Icons.shield_outlined),
  plans('Plans & payments', Icons.payments_outlined),
  content('Content', Icons.rate_review_outlined),
  system('System', Icons.tune_rounded);

  const AdminSection(this.label, this.icon);
  final String label;
  final IconData icon;

  /// The pages of this section, in tab order (the first opens from the nav).
  List<AdminPage> get pages => [for (final p in AdminPage.values) if (p.section == this) p];
}

/// Every page of the console and the section it lives in.
enum AdminPage {
  overview(AdminSection.dashboard, 'Overview'),
  riders(AdminSection.riders, 'Riders'),
  rides(AdminSection.ridesSafety, 'Rides'),
  safety(AdminSection.ridesSafety, 'Safety'),
  payments(AdminSection.plans, 'Payments'),
  marketing(AdminSection.plans, 'Marketing'),
  reviews(AdminSection.content, 'Ride reviews'),
  places(AdminSection.content, 'Place photos'),
  crews(AdminSection.content, 'Crews'),
  features(AdminSection.system, 'Features'),
  usage(AdminSection.system, 'Usage'),
  diagnostics(AdminSection.system, 'Diagnostics'),
  settings(AdminSection.system, 'Settings');

  const AdminPage(this.section, this.label);
  final AdminSection section;
  final String label;
}

/// The screen of [page] (the Overview is the console home and is never built here).
Widget adminPageScreen(AdminPage page) {
  switch (page) {
    case AdminPage.overview:
    case AdminPage.riders:
      return const AdminUsersScreen();
    case AdminPage.rides:
      return const AdminRideHistoryScreen();
    case AdminPage.safety:
      return const AdminSafetyScreen();
    case AdminPage.payments:
      return const AdminPlansPricingScreen();
    case AdminPage.marketing:
      return const MarketingStudioScreen();
    case AdminPage.reviews:
      return const AdminReviewsScreen();
    case AdminPage.places:
      return const AdminPlaceReviewsScreen();
    case AdminPage.crews:
      return const AdminCrewsScreen();
    case AdminPage.features:
      return const AdminFeaturesScreen();
    case AdminPage.usage:
      return const AdminInsightsScreen();
    case AdminPage.diagnostics:
      return const AdminDiagLogsScreen(); // 3.55 app logs riders sent
    case AdminPage.settings:
      return const AdminSettingsScreen();
  }
}

/// Opens [page] from a screen showing [current]: pushed from the Overview (so the
/// Overview is always one back away), otherwise in place of the current page. Switching
/// tabs inside a section has no slide, so it feels like a tab.
void adminGo(BuildContext context, AdminPage current, AdminPage page) {
  if (page == current) return;
  if (page == AdminPage.overview) {
    Navigator.maybePop(context);
    return;
  }
  final sameSection = page.section == current.section;
  final Route<void> route = sameSection
      ? PageRouteBuilder<void>(pageBuilder: (_, _, _) => adminPageScreen(page), transitionDuration: Duration.zero, reverseTransitionDuration: Duration.zero)
      : MaterialPageRoute<void>(builder: (_) => adminPageScreen(page));
  if (current == AdminPage.overview) {
    Navigator.push(context, route);
  } else {
    Navigator.pushReplacement(context, route);
  }
}

/// The nav items (one per [AdminSection]) for a screen that shows [current].
/// [emergencies] badges the Overview; [onSignOut] adds a last "Sign out" item.
List<AdminNavItem> adminNavItems(BuildContext context, AdminPage current, {int emergencies = 0, VoidCallback? onSignOut}) {
  return [
    for (final s in AdminSection.values)
      AdminNavItem(
        icon: s.icon,
        label: s.label,
        selected: current.section == s,
        badge: s == AdminSection.dashboard ? emergencies : 0,
        onTap: current.section == s && s == AdminSection.dashboard
            ? null
            : s == AdminSection.dashboard
                ? () => Navigator.maybePop(context)
                : () => adminGo(context, current, s.pages.first),
      ),
    if (onSignOut != null) AdminNavItem(icon: Icons.logout_rounded, label: 'Sign out', danger: true, onTap: onSignOut),
  ];
}

/// The tabs of [current]'s section (empty when the section has one page).
List<AdminNavItem> adminSectionTabs(BuildContext context, AdminPage current) {
  final pages = current.section.pages;
  if (pages.length < 2) return const [];
  return [
    for (final p in pages)
      AdminNavItem(
        icon: Icons.circle,
        label: p.label,
        selected: p == current,
        onTap: p == current ? null : () => adminGo(context, current, p),
      ),
  ];
}
