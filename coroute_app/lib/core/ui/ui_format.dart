import '../../domain/notify/status_text.dart';
import '../../domain/timeline/timeline_text.dart';

/// Plain-language number formatting for the UI. These forward to the
/// helpers the timeline and the status notification already use, so a
/// distance or a duration reads the same everywhere in the app.

/// Exact distance: "350 m", "1.2 km", "186 km". For reports and summaries.
String formatDistance(num meters) {
  if (!meters.isFinite) return 'Unknown';
  return TimelineText.distance(meters.abs());
}

/// Distance rounded so it does not change with every GPS fix:
/// "350 m" (50 m steps), "1.8 km", "12 km". For live values.
String formatDistanceRounded(num meters) {
  if (!meters.isFinite) return 'Unknown';
  return StatusText.roundedDistance(meters.abs().toDouble());
}

/// "350 m behind", "1.8 km ahead", or "350 m away" when the side is unknown.
/// Uses [formatDistanceRounded].
String describeDistance(num meters, {bool? ahead}) {
  final d = formatDistanceRounded(meters);
  if (ahead == true) return '$d ahead';
  if (ahead == false) return '$d behind';
  return '$d away';
}

/// "45 s", "8 min", "1 h", "1 h 12 min". Negative durations count as zero.
String formatDuration(Duration d) => TimelineText.duration(d.isNegative ? Duration.zero : d);

/// "just now", "40 s ago", "6 min ago", "1 h 5 min ago".
/// For "Last seen 6 min ago" and "Last updated 2 min ago".
String formatAgo(Duration d) {
  if (d.inSeconds < 15) return 'just now';
  if (d.inMinutes < 1) return '${(d.inSeconds / 10).round() * 10} s ago';
  return '${TimelineText.duration(Duration(minutes: d.inMinutes))} ago';
}

/// One or two capital letters for an avatar: "Arjun Kumar" gives "AK",
/// "kiran" gives "K", an empty name gives "?".
String initialsOf(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  String first(String s) => String.fromCharCode(s.runes.first).toUpperCase();
  if (parts.length == 1) return first(parts.first);
  return first(parts.first) + first(parts.last);
}
