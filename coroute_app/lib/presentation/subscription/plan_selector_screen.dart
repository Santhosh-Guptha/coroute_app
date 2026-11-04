import 'package:flutter/material.dart';
import 'membership_dashboard_screen.dart';

/// Legacy alias for the subscription and plans screen.
/// Directly redirects to [MembershipDashboardScreen] to ensure only the unified
/// CoRoute Membership and Mandatory Payment Plans are surfaced across the application,
/// eliminating duplicate plan screens.
class PlanSelectorScreen extends StatelessWidget {
  final dynamic preselectTier;

  const PlanSelectorScreen({super.key, this.preselectTier});

  @override
  Widget build(BuildContext context) {
    return const MembershipDashboardScreen();
  }
}
