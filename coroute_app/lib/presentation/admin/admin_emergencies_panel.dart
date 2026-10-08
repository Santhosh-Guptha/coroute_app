import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/ui/ui.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/safety_wire.dart';
import '../../data/models/sos_alert_model.dart';
import '../../data/services/alarm_notifier.dart';
import '../../data/services/api_client.dart';
import '../../data/services/convoy_service.dart';
import '../../domain/timeline/timeline_text.dart';
import '../ride/incident_view.dart';
import '../ride/navigate_to.dart';
import 'admin_ui.dart';

/// One open SOS or crash alert, from `GET /admin/emergencies` or the live
/// fleet. Never carries medical info or phone numbers.
class AdminEmergency {
  final String groupId;
  final String convoyName;
  final String alertId;
  final String alertType;
  final bool auto;
  final String userId;
  final String userName;
  final double lat;
  final double lng;
  final int startedAt;
  final int occurredAt;

  /// ONLINE, NO_SIGNAL, APP_CLOSED or empty (unknown).
  final String presence;
  final int lastSeenAt;
  final int riders;
  final String leadId;
  final String leadName;
  final List<SosResponder> responders;

  const AdminEmergency({
    required this.groupId,
    this.convoyName = '',
    required this.alertId,
    this.alertType = 'EMERGENCY',
    this.auto = false,
    required this.userId,
    this.userName = '',
    this.lat = 0,
    this.lng = 0,
    this.startedAt = 0,
    this.occurredAt = 0,
    this.presence = '',
    this.lastSeenAt = 0,
    this.riders = 0,
    this.leadId = '',
    this.leadName = '',
    this.responders = const [],
  });

  factory AdminEmergency.fromJson(Map<String, dynamic> j) {
    double d(Object? v) => v is num ? v.toDouble() : 0.0;
    int i(Object? v) => v is num ? v.toInt() : 0;
    final lead = j['lead'];
    final rs = j['responders'];
    return AdminEmergency(
      groupId: j['groupId']?.toString() ?? '',
      convoyName: j['convoyName']?.toString() ?? '',
      alertId: j['alertId']?.toString() ?? '',
      alertType: j['alertType']?.toString() ?? 'EMERGENCY',
      auto: j['auto'] == true,
      userId: j['userId']?.toString() ?? '',
      userName: j['userName']?.toString() ?? '',
      lat: d(j['lat']),
      lng: d(j['lng']),
      startedAt: i(j['startedAt']),
      occurredAt: i(j['occurredAt']),
      presence: j['presence']?.toString() ?? '',
      lastSeenAt: i(j['lastSeenAt']),
      riders: i(j['riders']),
      leadId: lead is Map ? (lead['userId']?.toString() ?? '') : '',
      leadName: lead is Map ? (lead['name']?.toString() ?? '') : '',
      responders: rs is List ? [for (final r in rs) if (r is Map) SosResponder.fromJson(Map<String, dynamic>.from(r))] : const [],
    );
  }

  /// From an open alert in the live fleet (admin socket FLEET).
  factory AdminEmergency.fromFleet(ConvoyModel c, SosAlertModel a) {
    final r = c.riders[a.userId];
    final lead = c.riders[c.createdByUserId];
    return AdminEmergency(
      groupId: c.groupId,
      convoyName: c.name,
      alertId: a.alertId,
      alertType: a.alertType,
      auto: a.auto,
      userId: a.userId,
      userName: a.userName.isNotEmpty ? a.userName : (r?.name ?? ''),
      lat: a.lat,
      lng: a.lng,
      startedAt: a.timestamp,
      occurredAt: a.occurredAt,
      presence: r?.presence ?? '',
      lastSeenAt: r?.lastSeenEpochMs ?? 0,
      riders: c.riders.length,
      leadId: c.createdByUserId,
      leadName: c.createdByUserName.isNotEmpty ? c.createdByUserName : (lead?.name ?? ''),
      responders: a.responders,
    );
  }

  AdminEmergency withLive({List<SosResponder>? responders, String? presence, int? lastSeenAt, int? riders}) => AdminEmergency(
        groupId: groupId,
        convoyName: convoyName,
        alertId: alertId,
        alertType: alertType,
        auto: auto,
        userId: userId,
        userName: userName,
        lat: lat,
        lng: lng,
        startedAt: startedAt,
        occurredAt: occurredAt,
        presence: presence ?? this.presence,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        riders: riders ?? this.riders,
        leadId: leadId,
        leadName: leadName,
        responders: responders ?? this.responders,
      );

  bool get isCrash => alertType.toUpperCase() == SosTypes.crash;
  String get who => userName.trim().isEmpty ? 'a rider' : userName.trim();

  /// "Crash: Kiran" / "SOS: Kiran needs help".
  String get title => isCrash ? 'Crash: ${userName.trim().isEmpty ? 'A rider' : userName.trim()}' : 'SOS: $who needs help';

  /// "Automatic crash alert" / "SOS, mechanical".
  String get kindText {
    if (isCrash) return auto ? 'Automatic crash alert' : 'Crash alert';
    final reason = TimelineText.reason(alertType);
    return auto ? 'Automatic SOS, $reason' : 'SOS, $reason';
  }

  /// "No signal" / "App closed on this phone" / "Online", or empty when unknown.
  String get presenceText {
    switch (presence.toUpperCase()) {
      case 'NO_SIGNAL':
        return 'No signal';
      case 'APP_CLOSED':
        return 'App closed on this phone';
      case 'ONLINE':
        return 'Online';
      default:
        return '';
    }
  }

  bool get hasPosition => lat != 0 || lng != 0;
}

/// Open emergencies: the REST list merged with the live fleet. An alert the
/// fleet shows as gone (its ride is known and the alert is not open) is
/// dropped; responders and presence come from the fleet when it has them; an
/// alert only the fleet knows is added. Newest first. Pure.
List<AdminEmergency> mergeEmergencies(List<AdminEmergency> rest, Iterable<ConvoyModel> fleet) {
  final convoys = {for (final c in fleet) c.groupId: c};
  final open = <String, (ConvoyModel, SosAlertModel)>{
    for (final c in fleet)
      for (final a in c.activeAlerts)
        if (!a.resolved) a.alertId: (c, a),
  };
  final out = <AdminEmergency>[];
  final seen = <String>{};
  for (final e in rest) {
    if (!seen.add(e.alertId)) continue;
    final live = open[e.alertId];
    if (live == null) {
      if (convoys.containsKey(e.groupId)) continue; // resolved since the list was loaded
      out.add(e);
      continue;
    }
    final (c, a) = live;
    final r = c.riders[a.userId];
    out.add(e.withLive(
      responders: a.responders,
      presence: (r?.presence ?? '').isEmpty ? null : r?.presence,
      lastSeenAt: r == null || r.lastSeenEpochMs <= 0 ? null : r.lastSeenEpochMs,
      riders: c.riders.length,
    ));
  }
  for (final entry in open.entries) {
    if (seen.contains(entry.key)) continue;
    final (c, a) = entry.value;
    out.add(AdminEmergency.fromFleet(c, a));
  }
  out.sort((x, y) => y.startedAt.compareTo(x.startedAt));
  return out;
}

/// The alarm sound of the admin console. Replaced in tests.
abstract class AdminAlarm {
  Future<void> start({required String title, required String body});
  Future<void> stop();
}

/// The real alarm: the coroute_admin_alarm notification channel (AlarmNotifier).
class NotifierAdminAlarm implements AdminAlarm {
  const NotifierAdminAlarm();

  @override
  Future<void> start({required String title, required String body}) async {
    try {
      await AlarmNotifier.startAdminAlarm(title: title, body: body);
    } catch (e) {
      debugPrint('admin alarm note: $e');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await AlarmNotifier.stopAdminAlarm();
    } catch (e) {
      debugPrint('admin alarm note: $e');
    }
  }
}

/// "Emergencies" at the top of the admin home: every open SOS and crash
/// across live rides (who, ride, kind, where, how long, presence,
/// responders). Loads `/admin/emergencies` on open and on [reload] (pull to
/// refresh), then follows the live fleet.
///
/// Alarm: a new emergency that was not silenced starts the alarm sound,
/// only while the admin app is open; "Silence" acknowledges every current
/// one; it stops when none is open, all are silenced, the app goes to the
/// background or the panel closes.
class AdminEmergenciesPanel extends StatefulWidget {
  final AdminAlarm alarm;

  /// Opens the ride inspector for a live ride.
  final ValueChanged<ConvoyModel>? onOpenConvoy;

  const AdminEmergenciesPanel({super.key, this.alarm = const NotifierAdminAlarm(), this.onOpenConvoy});

  @override
  State<AdminEmergenciesPanel> createState() => AdminEmergenciesPanelState();
}

class AdminEmergenciesPanelState extends State<AdminEmergenciesPanel> {
  /// Silenced alert ids. Kept for the app session, so reopening the console does not ring again.
  static final Set<String> _acknowledged = {};

  /// Clears the silenced ids (tests).
  @visibleForTesting
  static void resetAcknowledged() => _acknowledged.clear();

  final Set<String> _announced = {};
  List<AdminEmergency> _rest = const [];
  bool _loading = false;
  bool _ringing = false;
  bool _foreground = true;
  String _lastIds = '';
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(onStateChange: _onLifecycle);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) reload();
    });
  }

  @override
  void dispose() {
    _life.dispose();
    if (_ringing) {
      _ringing = false;
      widget.alarm.stop();
    }
    super.dispose();
  }

  void _onLifecycle(AppLifecycleState s) {
    final fg = s == AppLifecycleState.resumed;
    if (fg == _foreground) return;
    _foreground = fg;
    if (!fg && _ringing) {
      // Sound only while the admin app is open.
      _ringing = false;
      widget.alarm.stop();
    } else if (fg) {
      _lastIds = '';
      if (mounted) setState(() {});
    }
  }

  /// Loads the list from the gateway. What is on screen stays while it loads.
  Future<void> reload() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final res = await context.read<ApiClient>().get('/admin/emergencies');
      final list = adminMapList(res is Map ? res['emergencies'] : null);
      _rest = [for (final m in list) AdminEmergency.fromJson(m)];
    } catch (_) {
      // Offline or an older gateway: the live fleet still shows open SOS.
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Starts the alarm for an emergency not seen before (and not silenced),
  /// stops it when nothing unsilenced is left. Runs after the frame, never in build.
  void _syncAlarm(List<AdminEmergency> list) {
    if (!mounted) return;
    final ids = {for (final e in list) e.alertId};
    final unacked = ids.difference(_acknowledged);
    final fresh = unacked.difference(_announced);
    if (_foreground && (fresh.isNotEmpty || (unacked.isNotEmpty && !_ringing && _announced.isNotEmpty))) {
      _announced.addAll(unacked);
      final e = list.firstWhere((x) => unacked.contains(x.alertId));
      final more = unacked.length - 1;
      _ringing = true;
      widget.alarm.start(
        title: e.title,
        body: '${e.convoyName.isEmpty ? 'Live ride' : e.convoyName}. ${e.kindText}.${more > 0 ? ' $more more open.' : ''}',
      );
    } else if (unacked.isEmpty && _ringing) {
      _ringing = false;
      widget.alarm.stop();
    }
  }

  void _silence(List<AdminEmergency> list) {
    _acknowledged.addAll(list.map((e) => e.alertId));
    if (_ringing) {
      _ringing = false;
      widget.alarm.stop();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<ConvoyService>();
    final fleet = service.allConvoys.values;
    final list = mergeEmergencies(_rest, fleet);
    final now = DateTime.now().millisecondsSinceEpoch;

    final ids = list.map((e) => e.alertId).join(',');
    if (ids != _lastIds) {
      _lastIds = ids;
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncAlarm(list));
    }
    final unsilenced = list.any((e) => !_acknowledged.contains(e.alertId));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdminSectionLabel(
          list.isEmpty ? 'Emergencies' : 'Emergencies (${list.length})',
          trailing: _loading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : null,
        ),
        if (list.isEmpty)
          StatusLine(icon: Icons.check_circle_rounded, text: 'No open SOS or crash alerts', color: StatusColors.success)
        else ...[
          if (unsilenced)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s8),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  backgroundColor: StatusColors.critical,
                  foregroundColor: StatusColors.onCritical,
                ),
                onPressed: () => _silence(list),
                icon: const Icon(Icons.volume_off_rounded),
                label: const Text('Silence alarm', maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          for (final e in list)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s8),
              child: _EmergencyCard(
                key: ValueKey(e.alertId),
                emergency: e,
                nowMs: now,
                silenced: _acknowledged.contains(e.alertId),
                onOpenRide: (widget.onOpenConvoy != null && service.allConvoys[e.groupId] != null)
                    ? () => widget.onOpenConvoy!(service.allConvoys[e.groupId]!)
                    : null,
              ),
            ),
        ],
      ],
    );
  }
}

class _EmergencyCard extends StatelessWidget {
  final AdminEmergency emergency;
  final int nowMs;
  final bool silenced;
  final VoidCallback? onOpenRide;

  const _EmergencyCard({super.key, required this.emergency, required this.nowMs, required this.silenced, this.onOpenRide});

  @override
  Widget build(BuildContext context) {
    final e = emergency;
    final Color bg = StatusColors.critical;
    final Color fg = StatusColors.onCritical;
    final since = e.occurredAt > 0 ? e.occurredAt : e.startedAt;
    final open = since > 0 ? 'open ${formatDuration(Duration(milliseconds: math.max(0, nowMs - since)))}' : '';
    final responders = e.responders.where((r) => r.kind != SosResponseKind.cancel).toList();
    final who = responders.isEmpty
        ? 'No one has answered yet'
        : responders.map((r) => '${r.name.trim().isEmpty ? 'A rider' : r.name.trim()} ${responderWords(r.kind)}').join(', ');
    final presence = e.presenceText;
    final seen = e.lastSeenAt > 0 ? 'last seen ${formatAgo(Duration(milliseconds: math.max(0, nowMs - e.lastSeenAt)))}' : '';
    final lines = <String>[
      [e.kindText, if (open.isNotEmpty) open].join(', '),
      [
        e.convoyName.isEmpty ? 'Live ride' : e.convoyName,
        if (e.leadName.isNotEmpty) 'lead ${e.leadName}',
        if (e.riders > 0) '${e.riders} ${e.riders == 1 ? 'rider' : 'riders'}',
      ].join(', '),
      [if (presence.isNotEmpty) presence, if (seen.isNotEmpty) seen].join(', '),
      if (e.hasPosition) 'At ${e.lat.toStringAsFixed(5)}, ${e.lng.toStringAsFixed(5)}',
      'Helping: $who',
    ].where((l) => l.isNotEmpty).toList();

    return Semantics(
      container: true,
      liveRegion: !silenced,
      child: Material(
        color: bg,
        shape: const RoundedRectangleBorder(borderRadius: Radii.mdAll),
        child: Padding(
          padding: const EdgeInsets.all(Space.s12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(e.isCrash ? Icons.car_crash_rounded : Icons.sos_rounded, color: fg, size: 24),
                  const SizedBox(width: Space.s8),
                  Expanded(
                    child: Text(e.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(color: fg, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
              const SizedBox(height: Space.s4),
              for (final l in lines) Text(l, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: fg, fontWeight: FontWeight.w400)),
              const SizedBox(height: Space.s8),
              Wrap(
                spacing: Space.s8,
                runSpacing: Space.s8,
                children: [
                  if (e.hasPosition)
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(foregroundColor: fg, side: BorderSide(color: fg), minimumSize: const Size(48, 48)),
                      onPressed: () async {
                        final ok = await navigateTo(e.lat, e.lng, label: e.who);
                        if (!ok && context.mounted) adminSnack(context, 'No map app found on this phone.');
                      },
                      icon: const Icon(Icons.map_rounded),
                      label: const Text('Open map'),
                    ),
                  if (onOpenRide != null)
                    FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: fg, foregroundColor: bg, minimumSize: const Size(48, 48)),
                      onPressed: onOpenRide,
                      icon: const Icon(Icons.two_wheeler_rounded),
                      label: const Text('Open ride'),
                    ),
                ],
              ),
              if (silenced)
                Padding(
                  padding: const EdgeInsets.only(top: Space.s4),
                  child: Row(
                    children: [
                      Icon(Icons.volume_off_rounded, size: 16, color: fg),
                      const SizedBox(width: Space.s4),
                      Flexible(child: Text('Alarm silenced', style: AppText.caption.copyWith(color: fg))),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
