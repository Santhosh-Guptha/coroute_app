import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/ui/ui.dart';
import '../../data/services/admin_warnings_service.dart';

/// 3.55 platform: a moderator's warning on Home ("A message from CoRoute moderators"), with
/// Acknowledge and a close button (hides it until the next app start). Renders nothing when there
/// is none, the service is absent, or the admin switch `adminWarnings` is off. Home shows only
/// with no ride active, so it never competes with ride or SOS alerts.
class AdminWarningCard extends StatelessWidget {
  const AdminWarningCard({super.key});

  /// The card's text for [message] (plain text).
  static String textFor(String message) => 'A message from CoRoute moderators: $message';

  @override
  Widget build(BuildContext context) {
    final service = context.watch<AdminWarningsService?>();
    final w = service?.current;
    if (service == null || w == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s16),
      child: RideAlert(
        tier: AlertTier.important,
        title: 'Message from moderators',
        message: textFor(w.message),
        actionLabel: 'Acknowledge',
        onAction: () => service.acknowledge(w.id),
        onDismiss: () => service.hide(w.id),
      ),
    );
  }
}
