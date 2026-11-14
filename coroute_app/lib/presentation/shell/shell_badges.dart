import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../core/ui/ui.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/safety_service.dart';
import '../../data/services/timeline_service.dart';
import '../alerts/alerts_screen.dart';
import '../social/people_screen.dart';

/// v3.58: the numbers on the bottom bar and the Home bell, from the same sources as before (one rule each).
class ShellBadges {
  ShellBadges._();

  /// Critical and important alerts (the old Alerts tab badge): ride facts, the timeline, this phone's own
  /// safety prompts, assistance requests and accidents reported ahead. Never social.
  static int alerts(BuildContext context) {
    final convoys = Provider.of<ConvoyService?>(context);
    final timeline = Provider.of<TimelineService?>(context);
    if (convoys == null || timeline == null) return 0;
    final facts = context.select<ConvoyService, AlertFacts>(alertFactsOf);
    final prompts = context.select<SafetyService?, int>((s) => s?.prompts.where((p) => p.tier != AlertTier.normal).length ?? 0);
    final network = context.select<ConvoyService, int>((s) => s.assistRequests.length + s.hazards.length);
    return alertsBadgeCount(facts, timeline) + prompts + network;
  }

  /// Requests and votes waiting in Community (friend requests, crew and ride invites, open votes).
  static int community(BuildContext context) => peopleBadgesOf(context).total;

  /// Unread messages of the live ride chat.
  static int chat(BuildContext context) {
    final convoys = Provider.of<ConvoyService?>(context);
    if (convoys == null) return 0;
    return context.select<ConvoyService, int>((s) {
      final gid = s.activeGroupId;
      return gid == null ? 0 : s.unreadChat(gid);
    });
  }
}
