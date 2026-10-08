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
    'CRASH': 'crash',
  };

  static String ordinal(int n) {
    final t = n % 100;
    if (t >= 11 && t <= 13) return '${n}th';
    switch (n % 10) {
      case 1:
        return '${n}st';
      case 2:
        return '${n}nd';
      case 3:
        return '${n}rd';
      default:
        return '${n}th';
    }
  }

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
        switch (e.dataString('cause')) {
          case 'APP_CLOSED':
            return e.open ? "CoRoute was closed on $who's phone, $dur so far" : "CoRoute was closed on $who's phone for $dur";
          case 'KILLED':
            return e.open ? "The phone closed CoRoute on $who's phone, $dur so far" : "The phone closed CoRoute on $who's phone for $dur";
          default:
            return e.open ? '$who has no signal, $dur so far' : '$who had no signal for $dur';
        }
      case 'SOS':
        final kind = e.dataString('alertType');
        if (kind == 'CRASH' && e.data['auto'] == true) return '$who: crash detected (automatic alert)';
        return '$who raised an SOS${kind.isEmpty ? '' : ' (${reason(kind)})'}';
      case 'POSSIBLE_INCIDENT':
        return 'Possible incident: $who';
      case 'NO_REPLY':
        return e.open ? 'No reply from $who' : '$who did not answer Are you OK';
      case 'SOS_RESPONSE':
        final forName = e.dataString('forUserName').isEmpty ? 'the rider' : e.dataString('forUserName');
        switch (e.dataString('kind')) {
          case 'GOING':
            return '$who is going to $forName';
          case 'WITH_THEM':
            return '$who is with $forName';
          default:
            return '$who is no longer going';
        }
      case 'CHECK_IN':
        return '$who said they are OK';
      case 'STATUS':
        return '$who: ${reason(e.dataString('reason'))}';
      case 'STOP_ADDED':
        return '$who added the stop ${e.dataString('name')}';
      case 'STOP_SUGGESTED':
        return '$who suggested the stop ${e.dataString('name')}';
      case 'STOP_SKIPPED':
        return '$who skipped the stop ${e.dataString('name')}';
      case 'ROUTE_CHANGED':
        switch (e.dataString('change')) {
          case 'DESTINATION':
            return '$who changed the destination';
          case 'START':
            return '$who changed the start';
          case 'STOPS_REORDERED':
            return '$who changed the order of the stops';
          case 'STOP_REMOVED':
            return '$who removed a stop';
          default:
            return '$who changed the route';
        }
      case 'STOP_REACHED':
        final at = e.dataString('name').isEmpty ? 'a stop' : e.dataString('name');
        return e.open ? '$who is at $at, $dur so far' : '$who reached $at, stayed $dur';
      case 'STOP_PASSED':
        return e.data['destination'] == true ? '$who rode past the destination' : '$who rode past ${e.dataString('name').isEmpty ? 'a stop' : e.dataString('name')}';
      case 'STOP_ALL_REACHED':
        return 'Everyone reached ${e.dataString('name').isEmpty ? 'the stop' : e.dataString('name')}';
      case 'DESTINATION_ALL_REACHED':
        return 'Everyone reached the destination';
      case 'DESTINATION_REACHED':
        return e.open || e.durationMs == 0 ? '$who reached the destination' : '$who reached the destination, stayed $dur';
      case 'OVERSPEED':
        final top = e.dataNum('maxKmh');
        final limit = e.dataNum('limitKmh');
        if (e.open) return '$who is over the ${limit == null ? 'group' : '${limit.round()} km/h'} limit';
        return '$who rode over the limit for $dur${top == null ? '' : ', top ${top.round()} km/h'}';
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
    const namedInTitle = {'STOP_ADDED', 'STOP_REACHED', 'STOP_SUGGESTED', 'STOP_SKIPPED', 'STOP_PASSED', 'STOP_ALL_REACHED'};
    if (e.placeName.isNotEmpty && !namedInTitle.contains(e.type)) parts.add(e.placeName);
    if (e.type == 'STOP_ADDED' && e.dataString('suggestedBy').isNotEmpty) parts.add('suggested by ${e.dataString('suggestedBy')}');
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
      case 'POSSIBLE_INCIDENT':
        if (e.open) {
          final from = e.dataNum('fromKmh');
          parts.add(from == null ? 'stopped suddenly, automatic' : 'stopped suddenly from ${from.round()} km/h, automatic');
        } else {
          parts.add(_closedWord(e.dataString('result'), e.durationAt(nowMs)));
        }
        break;
      case 'NO_REPLY':
        final away = e.dataNum('awayM');
        if (away != null && away > 0) parts.add('${distance(away)} from the group');
        if (e.open) {
          parts.add('automatic check');
        } else {
          parts.add(_closedWord(e.dataString('result'), e.durationAt(nowMs)));
        }
        break;
      case 'OFFLINE':
        final kmh = e.dataNum('lastKmh');
        if (e.data['escalated'] == true && kmh != null) parts.add('last seen at ${kmh.round()} km/h');
        break;
      case 'SOS':
        final going = e.data['responders'];
        if (e.open && going is List && going.isNotEmpty) parts.add('${going.length} ${going.length == 1 ? 'rider' : 'riders'} responding');
        if (e.open) {
          parts.add('open for ${duration(e.durationAt(nowMs))}');
        } else {
          final by = e.dataString('resolvedByName');
          final byId = e.dataString('resolvedBy');
          if (byId.isNotEmpty && byId == e.userId) {
            // The rider resolved their own SOS: an "I am OK" check-in.
            parts.add('said they are OK after ${duration(e.durationAt(nowMs))}');
          } else {
            parts.add('resolved${by.isEmpty ? '' : ' by $by'} after ${duration(e.durationAt(nowMs))}');
          }
        }
        break;
      case 'OVERSPEED':
        final limitKmh = e.dataNum('limitKmh');
        final peakKmh = e.dataNum('maxKmh');
        final n = e.dataNum('count')?.toInt() ?? 1;
        if (limitKmh != null) parts.add('limit ${limitKmh.round()} km/h');
        if (e.open && peakKmh != null) parts.add('${peakKmh.round()} km/h');
        if (n > 1) parts.add('${ordinal(n)} time this trip');
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

  /// How an automatic check ended: "OK after 4 min", "moved on after 4 min", "SOS raised after 4 min".
  static String _closedWord(String result, Duration d) {
    switch (result) {
      case 'OK':
        return 'OK after ${duration(d)}';
      case 'MOVED':
        return 'moved on after ${duration(d)}';
      case 'SOS':
        return 'SOS raised after ${duration(d)}';
      default:
        return 'closed after ${duration(d)}';
    }
  }
}
