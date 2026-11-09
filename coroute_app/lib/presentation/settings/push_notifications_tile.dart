import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/services/push_service.dart';
import '../safety/safety_settings_sheet.dart';

/// 3.55 Settings > App & privacy (the screen draws its own row with [title]): "Push notifications" (default on). Shown only when the build
/// has push set up (PushService.available); turning it on asks for the notification permission
/// when Android has not granted it yet.
class PushNotificationsTile extends StatelessWidget {
  const PushNotificationsTile({super.key});

  static const String title = 'Push notifications';
  static const String subtitle = 'Invites and requests. Never your location.';

  @override
  Widget build(BuildContext context) {
    final push = context.watch<PushService?>();
    if (push == null || !push.available) return const SizedBox.shrink();
    return SafetySwitch(
      key: const ValueKey('settings_push_notifications'),
      icon: Icons.notifications_active_rounded,
      title: title,
      subtitle: subtitle,
      value: push.enabled,
      onChanged: (on) => push.setEnabled(on),
    );
  }
}
