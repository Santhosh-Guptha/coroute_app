/// Android 16 "Live Update" content for the ride notification (pure; test/live_update_test.dart).
///
/// On Android 16+ (API 36) RideNotification.kt posts the ride notification as a promoted ongoing notification
/// (status bar chip, top of the lock screen and the always-on display on phones that show it) when this content
/// exists and the rider has not turned Live Updates off for CoRoute. It holds the next turn and its distance, or
/// the group status. Emergencies, assists and hazards keep the full ride notification. Older Android keeps the
/// notification as it was.
library;

import '../route/next_turn.dart';
import 'notification_snapshot.dart';
import 'status_text.dart';

class LiveUpdateContent {
  LiveUpdateContent._();

  /// The status bar chip is short on Android (about 7 characters are shown).
  static const int chipMax = 7;

  /// Channel args under "live": title, text, chip, progress (0..100, or -1 when unknown).
  /// Null when there is nothing worth promoting (not a normal ride, or no turn and no group).
  static Map<String, Object>? build({
    required NotifMode mode,
    NextTurn? turn,
    List<RiderLine> ahead = const [],
    List<RiderLine> behind = const [],
    double? progress01,
  }) {
    if (mode != NotifMode.ride) return null;
    final progress = progress01 == null || !progress01.isFinite ? -1 : (progress01.clamp(0.0, 1.0) * 100).round();
    if (turn != null) {
      return {
        'title': turn.line,
        'text': turn.road.isNotEmpty ? turn.road : _groupLine(ahead, behind) ?? '',
        'chip': _chip(turn.distanceText),
        'progress': progress,
      };
    }
    if (ahead.isNotEmpty) {
      final lead = ahead.first;
      return {
        'title': '${lead.name} ${lead.detail}',
        'text': _groupLine(ahead, behind) ?? '',
        'chip': _chip(StatusText.roundedDistance(lead.distanceM)),
        'progress': progress,
      };
    }
    if (behind.isNotEmpty) {
      final last = behind.last;
      return {
        'title': 'You lead · ${ahead.length + behind.length + 1} riders',
        'text': '${last.name} ${last.detail}',
        'chip': 'Lead',
        'progress': progress,
      };
    }
    return null;
  }

  static String? _groupLine(List<RiderLine> ahead, List<RiderLine> behind) {
    final total = ahead.length + behind.length + 1;
    if (total <= 1) return null;
    return 'Pack #${ahead.length + 1} of $total';
  }

  static String _chip(String s) => s.length <= chipMax ? s : s.replaceAll(' ', '');
}
