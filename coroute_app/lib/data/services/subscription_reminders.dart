import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/config/feature_gates.dart';
import 'alarm_notifier.dart';

/// One local reminder before (or at) the end of a paid plan. The server does
/// not push these; the app schedules them whenever the entitlement changes.
@immutable
class PlanReminder {
  /// Notification id (stable per step, so a reschedule replaces it).
  final int id;

  /// 7, 3 or 1 days before the end, or 0 for the moment the plan ends.
  final int daysBefore;

  /// When the reminder fires.
  final DateTime at;
  final String title;
  final String body;

  const PlanReminder({
    required this.id,
    required this.daysBefore,
    required this.at,
    required this.title,
    required this.body,
  });

  @override
  String toString() => 'PlanReminder($daysBefore d @ ${at.toIso8601String()})';
}

/// Days before validUntil at which a reminder fires; 0 is the end itself.
const List<int> planReminderOffsetsDays = [7, 3, 1, 0];

/// First notification id of the plan reminders (one id per offset).
const int planReminderBaseId = 47100;

/// Every id the plan reminders can use (for cancelling them all).
List<int> get planReminderIds => [for (var i = 0; i < planReminderOffsetsDays.length; i++) planReminderBaseId + i];

/// The reminders to schedule for a paid [tier] that ends at [validUntilMs]
/// (epoch ms), as seen at [now]: one 7, 3 and 1 day before the end and one
/// at the end, skipping any that would already be in the past. Empty for
/// Community, for no end date, or for a plan that has already ended.
///
/// Pure: no clock, no plugin, so it is unit-tested directly.
List<PlanReminder> computePlanReminders({
  required SubscriptionTier tier,
  required int validUntilMs,
  required DateTime now,
  String? planName,
  String? featureSummary,
}) {
  if (tier == SubscriptionTier.community || validUntilMs <= 0) return const [];
  final end = DateTime.fromMillisecondsSinceEpoch(validUntilMs);
  if (!end.isAfter(now)) return const [];
  final name = (planName == null || planName.isEmpty) ? FeatureGates.tierLabel(tier) : planName;
  final keep = (featureSummary == null || featureSummary.isEmpty) ? 'your plan features' : featureSummary;
  final out = <PlanReminder>[];
  for (var i = 0; i < planReminderOffsetsDays.length; i++) {
    final d = planReminderOffsetsDays[i];
    final at = end.subtract(Duration(days: d));
    if (!at.isAfter(now)) continue;
    out.add(PlanReminder(
      id: planReminderBaseId + i,
      daysBefore: d,
      at: at,
      title: d == 0 ? 'Your $name has ended' : 'Your $name ends in ${d == 1 ? '1 day' : '$d days'}',
      body: d == 0 ? 'You\'re on Community now. Tap to renew and get $keep back.' : 'Renew to keep $keep. Tap to see plans.',
    ));
  }
  return out;
}

/// Notification payload of a plan reminder: `PLAN:<tier>`.
String planReminderPayload(SubscriptionTier tier) => '${AlarmNotifier.payloadPlan}:${tier.name}';

/// The tier named in a plan reminder payload, null when it is not one.
SubscriptionTier? tierFromPlanReminderPayload(String? payload) {
  if (payload == null) return null;
  final prefix = '${AlarmNotifier.payloadPlan}:';
  if (!payload.startsWith(prefix)) return null;
  final name = payload.substring(prefix.length).toLowerCase();
  for (final t in SubscriptionTier.values) {
    if (t.name.toLowerCase() == name) return t;
  }
  return null;
}

/// Puts [PlanReminder]s on the phone with flutter_local_notifications (via
/// [AlarmNotifier], the one place that owns the plugin). Does nothing off
/// Android (unit tests, web), so the subscription service can always call it.
class PlanReminderScheduler {
  PlanReminderScheduler();

  static const String _permissionAskedKey = 'coroute_plan_reminder_permission_asked';

  bool get supported => !kIsWeb && Platform.isAndroid;

  /// Replaces whatever was scheduled with [reminders] for [tier].
  Future<void> schedule(List<PlanReminder> reminders, SubscriptionTier tier) async {
    if (!supported) return;
    await cancelAll();
    for (final r in reminders) {
      await AlarmNotifier.schedulePlanReminder(
        id: r.id,
        at: r.at,
        title: r.title,
        body: r.body,
        payload: planReminderPayload(tier),
      );
    }
  }

  /// Removes every plan reminder (renewed, revoked, refunded, signed out).
  Future<void> cancelAll() async {
    if (!supported) return;
    await AlarmNotifier.cancelPlanReminders(planReminderIds);
  }

  /// Asks for the Android 13+ notification permission, once per install.
  /// Called from the plan selector or the account screen, never at start-up.
  static Future<void> requestPermissionOnce() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_permissionAskedKey) ?? false) return;
      await prefs.setBool(_permissionAskedKey, true);
      await AlarmNotifier.requestNotificationPermission();
    } catch (_) {}
  }
}
