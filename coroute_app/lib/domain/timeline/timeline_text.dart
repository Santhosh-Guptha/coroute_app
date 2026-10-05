import '../../data/models/timeline_event_model.dart';

/// Plain-language wording for timeline entries, shared by the timeline
/// screen and the notifications so both always say the same thing.
class TimelineText {
  TimelineText._();

  static String duration(Duration d) {
    final s = d.inSeconds;
    if (s < 60) return '$s s';
    final m = d.inMinutes;
    if (m < 60) return '$m min';
    final h = m ~/ 60, rest = m % 60;
    return rest == 0 ? '$h h' : '$h h $rest min';
  }

  static String distance(num metres) {
    if (metres < 1000) return '${metres.round()} m';
    final km = metres / 1000;
    return km < 10 ? '${km.toStringAsFixed(1)} km' : '${km.round()} km';
  }

  static const Map<String, String> reasons = {
    'FUELING': 'fuelling',
    'REST_BREAK': 'rest break',
    'MECHANICAL': 'mechanical issue',
    'FLAT_TIRE': 'flat tyre',
    'TRAFFIC': 'traffic',
    'RAIN_DELAY': 'rain',
    'PHOTO_STOP': 'photo stop',
    'MEDICAL': 'medical',
    'REGROUP': 'regrouping',
    'CUSTOM': 'custom stop',
    'CRASH_OR_EMERGENCY': 'emergency',
    'EMERGENCY': 'emergency',
  };

  static String reason(String code) => reasons[code] ?? code.toLowerCase().replaceAll('_', ' ');

  /// Main line, e.g. "Priya stopped for 18 min".
  static String title(TimelineEventModel e, {required int nowMs}) {
    final who = e.userName.isNotEmpty ? e.userName : 'A rider';
    final dur = duration(e.durationAt(nowMs));
    switch (e.type) {
      case 'TRIP_STARTED':
        return '$who started the trip';
      case 'TRIP_PAUSED':
        return 'Trip paused';
      case 'TRIP_RESUMED':
        return 'Trip resumed';
      case 'TRIP_ENDED':
        return 'Trip ended';
      case 'JOINED':
        return '$who joined';
      case 'LEFT':
        return '$who left the convoy';
      case 'STOPPED':
        return e.open ? '$who is stopped, $dur so far' : '$who stopped for $dur';
      case 'MOVING':
        final km = e.dataNum('distanceM');
        return km != null ? '$who rode ${distance(km)} in $dur' : '$who rode for $dur';
      case 'SEPARATED':
        final m = e.dataNum('maxDistanceM') ?? e.dataNum('distanceM') ?? 0;
        return e.open ? '$who is ${distance(m)} away from the group' : '$who fell behind ${distance(m)}';
      case 'OFF_ROUTE':
        return e.open ? '$who is off the route' : '$who went off the route';
      case 'OFFLINE':
        return e.open ? '$who has no signal, $dur so far' : '$who had no signal for $dur';
      case 'SOS':
        final kind = e.dataString('alertType');
        return '$who raised an SOS${kind.isEmpty ? '' : ' (${reason(kind)})'}';
      case 'STATUS':
        return '$who: ${reason(e.dataString('reason'))}';
      case 'STOP_ADDED':
        return '$who added the stop ${e.dataString('name')}';
      case 'STOP_REACHED':
        return '$who reached ${e.dataString('name').isEmpty ? 'a stop' : e.dataString('name')}';
      case 'DESTINATION_REACHED':
        return '$who reached the destination';
      case 'CORIDE':
        final w = e.dataString('withName');
        return e.open ? '$who is riding with ${w.isEmpty ? 'another rider' : w}' : '$who rode with ${w.isEmpty ? 'another rider' : w} for $dur';
      default:
        return '$who: ${e.type.toLowerCase().replaceAll('_', ' ')}';
    }
  }

  /// Second line: where, why and how it ended.
  static String detail(TimelineEventModel e, {required int nowMs}) {
    final parts = <String>[];
    if (e.placeName.isNotEmpty && e.type != 'STOP_ADDED' && e.type != 'STOP_REACHED') parts.add(e.placeName);
    switch (e.type) {
      case 'STOPPED':
        final r = e.dataString('reason');
        if (r.isNotEmpty) parts.add(reason(r));
        break;
      case 'MOVING':
        final avg = e.dataNum('avgKmh');
        final top = e.dataNum('maxKmh');
        if (avg != null) parts.add('avg ${avg.round()} km/h');
        if (top != null && top > 0) parts.add('top ${top.round()} km/h');
        break;
      case 'SEPARATED':
        if (!e.open) parts.add('regrouped after ${duration(e.durationAt(nowMs))}');
        break;
      case 'OFF_ROUTE':
        final d = e.dataNum('distanceM');
        if (d != null) parts.add('${distance(d)} from the route');
        if (!e.open) parts.add('back after ${duration(e.durationAt(nowMs))}');
        break;
      case 'SOS':
        if (e.open) {
          parts.add('open for ${duration(e.durationAt(nowMs))}');
        } else {
          final by = e.dataString('resolvedByName');
          parts.add('resolved${by.isEmpty ? '' : ' by $by'} after ${duration(e.durationAt(nowMs))}');
        }
        break;
      case 'STATUS':
        final msg = e.dataString('message');
        if (msg.isNotEmpty) parts.add(msg);
        break;
      default:
        break;
    }
    return parts.join(' · ');
  }
}
