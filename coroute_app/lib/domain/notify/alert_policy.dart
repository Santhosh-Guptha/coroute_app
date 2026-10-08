import '../../data/models/timeline_event_model.dart';
import '../timeline/timeline_text.dart';
import '../tracking/geo_math.dart';

/// Which notification channel an alert uses.
enum AlertChannel { sos, alerts, updates, activity }

/// One notification the phone should be showing.
class AlertSpec {
  /// Stable key: the same situation always maps to the same notification,
  /// so a repeat updates it instead of stacking a new one.
  final String key;
  final AlertChannel channel;
  final String title;
  final String body;
  const AlertSpec(this.key, this.channel, this.title, this.body);

  /// Android notification id derived from [key] (positive 31-bit, stable across runs).
  int get id {
    var h = 0x811c9dc5;
    for (final c in key.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return 2000 + (h % 1000000000); // ids below 2000 are reserved (1001 = trip status)
  }

  @override
  bool operator ==(Object other) => other is AlertSpec && other.key == key && other.title == title && other.body == body && other.channel == channel;

  @override
  int get hashCode => Object.hash(key, title, body, channel);
}

/// Who this phone belongs to, for deciding who gets which alert.
class AlertViewer {
  final String userId;
  final bool isLead;
  final bool isSweeper;

  /// My last known position (for "3.4 km from you"); null when unknown.
  final double? lat;
  final double? lng;
  const AlertViewer({required this.userId, this.isLead = false, this.isSweeper = false, this.lat, this.lng});
}

/// Turns the group timeline into notifications.
///
/// State versus events: the live trip status lives in the ongoing
/// notification. This policy covers events only, and only the ones that
/// deserve attention, and it answers "what should be showing now?" rather
/// than "what happened?". The caller shows what is new and removes what is
/// no longer true, so an alert disappears by itself when its cause ends
/// (the rider moves again, the SOS is resolved, the group regroups).
class AlertPolicy {
  /// One key for every "Meeting point changed" alert: a newer meeting point
  /// replaces the older alert (same notification, one row in the app).
  static const String meetingKey = 'EV:MEETING';

  /// Alerts that are shown as a notification even while CoRoute is open:
  /// safety alerts (the alerts channel). The meeting point already shows in
  /// the ride alert slot, so it is not posted twice while the app is open.
  static bool showWhileOpen(AlertSpec a) => a.channel == AlertChannel.alerts && a.key != meetingKey;

  /// "Meeting point changed": where, and how far from me as the crow flies.
  static AlertSpec meetingChanged(TimelineEventModel e, AlertViewer me) {
    final name = e.dataString('name').isNotEmpty ? e.dataString('name') : e.placeName;
    final lat = e.lat, lng = e.lng, myLat = me.lat, myLng = me.lng;
    var far = '';
    if (lat != null && lng != null && myLat != null && myLng != null && (myLat != 0 || myLng != 0)) {
      far = '${TimelineText.distance(GeoMath.haversine(myLat, myLng, lat, lng))} from you';
    }
    final body = [
      if (name.isNotEmpty) name,
      if (far.isNotEmpty) far,
    ].join(', ');
    return AlertSpec(meetingKey, AlertChannel.alerts, 'Meeting point changed', body.isEmpty ? '' : '$body.');
  }

  AlertPolicy({this.stationaryAlert = const Duration(minutes: 20), this.offlineAlert = const Duration(minutes: 5)});

  final Duration stationaryAlert;
  final Duration offlineAlert;

  /// Alerts that should be visible right now, from the open timeline entries.
  List<AlertSpec> standing(Iterable<TimelineEventModel> events, AlertViewer me, {required int nowMs}) {
    final out = <AlertSpec>[];
    for (final e in events) {
      if (!e.open || e.userId == null) continue;
      final mine = e.userId == me.userId;
      final who = e.userName.isNotEmpty ? e.userName : 'A rider';
      final dur = e.durationAt(nowMs);
      final where = e.placeName.isNotEmpty ? ' near ${e.placeName}' : '';
      switch (e.type) {
        case 'SOS':
          if (mine) break; // the sender already knows
          final kind = e.dataString('alertType');
          out.add(AlertSpec('SOS:${e.dataString('alertId').isEmpty ? e.eventId : e.dataString('alertId')}', AlertChannel.sos,
              'SOS from $who', '${kind.isEmpty ? 'Needs help' : TimelineText.reason(kind)}$where. Open CoRoute to see where.'));
          break;
        case 'STOPPED':
          if (mine || dur < stationaryAlert || !(me.isLead || me.isSweeper)) break;
          final r = e.dataString('reason');
          out.add(AlertSpec('STOPPED:${e.userId}', AlertChannel.alerts, '$who has been stopped for ${TimelineText.duration(dur)}',
              '${r.isEmpty ? 'No reason given' : TimelineText.reason(r)}$where.'));
          break;
        case 'SEPARATED':
          final km = TimelineText.distance(e.dataNum('maxDistanceM') ?? e.dataNum('distanceM') ?? 0);
          if (mine) {
            out.add(AlertSpec('SEPARATED:${e.userId}', AlertChannel.alerts, 'You are $km from your group', 'Slow down or wait for them to catch up.'));
          } else if (me.isLead || me.isSweeper) {
            out.add(AlertSpec('SEPARATED:${e.userId}', AlertChannel.alerts, '$who is $km from the group', 'Separated for ${TimelineText.duration(dur)}.'));
          }
          break;
        case 'OFFLINE':
          if (mine || !me.isLead || dur < offlineAlert) break;
          out.add(AlertSpec('OFFLINE:${e.userId}', AlertChannel.alerts, 'No signal from $who for ${TimelineText.duration(dur)}',
              'Last seen$where. Their phone will catch up when it has signal again.'));
          break;
        case 'OFF_ROUTE':
          if (mine) {
            out.add(AlertSpec('OFF_ROUTE:${e.userId}', AlertChannel.updates, 'You are off the planned route', 'Check the map to get back on the route.'));
          } else if (me.isLead) {
            out.add(AlertSpec('OFF_ROUTE:${e.userId}', AlertChannel.updates, '$who is off the route', 'For ${TimelineText.duration(dur)}$where.'));
          }
          break;
        default:
          break;
      }
    }
    return out;
  }

  /// A one-time alert for something that just happened (shown once, removed after a while).
  AlertSpec? oneShot(TimelineEventModel e, AlertViewer me) {
    final who = e.userName.isNotEmpty ? e.userName : 'A rider';
    final mine = e.userId == me.userId;
    switch (e.type) {
      case 'DESTINATION_REACHED':
        return AlertSpec('EV:${e.eventId}', AlertChannel.updates, mine ? 'You reached the destination' : '$who reached the destination', e.placeName);
      case 'STOP_REACHED':
        if (mine) return null;
        return AlertSpec('EV:${e.eventId}', AlertChannel.updates, '$who reached ${e.dataString('name').isEmpty ? 'the stop' : e.dataString('name')}', '');
      case 'STOP_ALL_REACHED':
        return AlertSpec('EV:${e.eventId}', AlertChannel.updates, 'Everyone reached ${e.dataString('name').isEmpty ? 'the stop' : e.dataString('name')}', 'The whole group is together.');
      case 'DESTINATION_ALL_REACHED':
        return AlertSpec('EV:${e.eventId}', AlertChannel.updates, 'Everyone reached the destination', e.placeName);
      case 'OVERSPEED':
        // Announced once per episode to everyone; repeats soon after are only logged.
        if (e.data['notify'] == false) return null;
        final limit = e.dataNum('limitKmh')?.round();
        final top = e.dataNum('maxKmh')?.round();
        final lim = limit == null ? 'the group speed limit' : 'the group limit of $limit km/h';
        final body = mine
            ? ['Please slow down.', if (top != null) 'You reached $top km/h.'].join(' ')
            : [if (top != null) 'Reached $top km/h', if (e.placeName.isNotEmpty) 'near ${e.placeName}'].join(' ');
        return AlertSpec('EV:${e.eventId}', AlertChannel.alerts, mine ? 'You are over $lim' : '$who is over $lim', body);
      case 'STOP_SUGGESTED':
        if (!me.isLead || mine) return null;
        return AlertSpec('EV:${e.eventId}', AlertChannel.updates, '$who suggests a stop', '${e.dataString('name')}. Open the stops list to add it or decline.');
      case 'JOINED':
        if (mine) return null;
        return AlertSpec('EV:${e.eventId}', AlertChannel.activity, '$who joined the convoy', '');
      case 'LEFT':
        if (mine) return null;
        return AlertSpec('EV:${e.eventId}', AlertChannel.activity, '$who left the convoy', '');
      case 'STOP_ADDED':
        if (mine) return null;
        if (e.dataString('category').toUpperCase() == 'MEETING') return meetingChanged(e, me);
        return AlertSpec('EV:${e.eventId}', AlertChannel.activity, TimelineText.title(e, nowMs: e.startedAt), 'The route on your map is updated.');
      case 'ROUTE_CHANGED':
        if (mine) return null;
        return AlertSpec('EV:${e.eventId}', AlertChannel.activity, TimelineText.title(e, nowMs: e.startedAt), 'The route on your map is updated.');
      default:
        return null;
    }
  }
}
