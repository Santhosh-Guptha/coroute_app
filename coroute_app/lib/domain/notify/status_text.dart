import '../timeline/timeline_text.dart';

/// One convoy-mate as seen from this phone, for the live status notification.
class StatusMember {
  final String name;
  final double distanceM;

  /// true = ahead of me, false = behind me, null = unknown.
  final bool? ahead;
  final double speedKmh;
  final Duration sinceUpdate;

  /// Set while the member is stopped.
  final Duration? stoppedFor;

  const StatusMember({
    required this.name,
    required this.distanceM,
    this.ahead,
    this.speedKmh = 0,
    this.sinceUpdate = Duration.zero,
    this.stoppedFor,
  });

  bool get noSignal => sinceUpdate >= const Duration(minutes: 2);
}

/// Builds the text of the ongoing trip notification.
///
/// The first line is what a collapsed notification shows: the nearest three
/// riders, then "+N". The expanded notification shows one line per rider and
/// the destination progress. Same input, same text, so the caller can skip
/// redrawing when nothing visible changed.
class StatusText {
  StatusText._();

  static const int collapsedEntries = 3;

  static String shortName(String name) {
    final first = name.trim().split(RegExp(r'\s+')).first;
    return first.length <= 10 ? first : '${first.substring(0, 9)}.';
  }

  /// Distance rounded so the text does not change with every GPS fix.
  static String roundedDistance(double m) {
    if (m < 1000) return '${(m / 50).round() * 50} m';
    if (m < 10000) return '${(m / 1000).toStringAsFixed(1)} km';
    return '${(m / 1000).round()} km';
  }

  static String _relation(StatusMember m) {
    final d = roundedDistance(m.distanceM);
    if (m.ahead == true) return '$d ahead';
    if (m.ahead == false) return '$d behind';
    return d;
  }

  static String _compact(StatusMember m) {
    final n = shortName(m.name);
    if (m.noSignal) return '$n no signal';
    final stopped = m.stoppedFor;
    if (stopped != null && stopped >= const Duration(minutes: 1)) return '$n stopped ${stopped.inMinutes}m';
    return '$n ${_relation(m)}';
  }

  static String _ago(Duration d) {
    if (d.inSeconds < 15) return 'now';
    if (d.inMinutes < 1) return '${(d.inSeconds / 10).round() * 10} s ago';
    return '${d.inMinutes} min ago';
  }

  static String _line(StatusMember m) {
    final parts = <String>[_relation(m)];
    final stopped = m.stoppedFor;
    if (m.noSignal) {
      parts.add('no signal');
    } else if (stopped != null && stopped >= const Duration(minutes: 1)) {
      parts.add('stopped ${TimelineText.duration(stopped)}');
    } else {
      parts.add('${m.speedKmh.round()} km/h');
    }
    parts.add(_ago(m.sinceUpdate));
    return '${shortName(m.name)}: ${parts.join(' · ')}';
  }

  /// Returns the notification title and text (first line = collapsed view).
  static ({String title, String text}) build({
    required String convoyName,
    required List<StatusMember> others,
    double? destinationRemainingM,
    String? nextStopName,
    double? nextStopRemainingM,
  }) {
    final sorted = List<StatusMember>.from(others)..sort((a, b) => a.distanceM.compareTo(b.distanceM));
    final riders = sorted.length + 1;
    final title = '$convoyName · $riders rider${riders == 1 ? '' : 's'}';
    if (sorted.isEmpty) {
      return (title: title, text: 'Waiting for your group to join. Share the join code.');
    }
    final head = sorted.take(collapsedEntries).map(_compact).join(' · ');
    final more = sorted.length > collapsedEntries ? ' · +${sorted.length - collapsedEntries}' : '';
    final lines = <String>['$head$more', ...sorted.map(_line)];
    final progress = <String>[];
    if (nextStopName != null && nextStopName.isNotEmpty && nextStopRemainingM != null) {
      progress.add('Next: $nextStopName ${roundedDistance(nextStopRemainingM)}');
    }
    if (destinationRemainingM != null) progress.add('Destination ${roundedDistance(destinationRemainingM)}');
    if (progress.isNotEmpty) lines.add(progress.join(' · '));
    return (title: title, text: lines.join('\n'));
  }
}
