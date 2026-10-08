import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/safety_wire.dart';
import '../../domain/tracking/bearing.dart';
import '../../domain/tracking/geo_math.dart';
import 'incident_view.dart';
import 'navigate_to.dart';

/// "1.8 km north-east of you", or null when either position is unknown.
String? incidentDistanceText(IncidentView incident, {double? myLat, double? myLng}) {
  final la = myLat, ln = myLng;
  if (la == null || ln == null || (la == 0 && ln == 0) || !incident.hasPosition) return null;
  final m = GeoMath.haversine(la, ln, incident.lat, incident.lng);
  if (!m.isFinite) return null;
  return Bearing.fromMe(m, Bearing.degrees(la, ln, incident.lat, incident.lng));
}

/// "Arjun on the way" / "3 riders helping", or null when no one answered yet.
String? incidentHelpingText(IncidentView incident) {
  final list = incident.responders.where((r) => r.kind != SosResponseKind.cancel).toList();
  if (list.isEmpty) return null;
  if (list.length > 1) return '${list.length} riders helping';
  final r = list.single;
  final name = r.name.trim().isEmpty ? 'A rider' : r.name.trim();
  return '$name ${responderWords(r.kind)}';
}

/// The icon for an incident kind (status is never shown by colour alone).
IconData incidentIcon(IncidentKind k) {
  switch (k) {
    case IncidentKind.crash:
      return Icons.car_crash_rounded;
    case IncidentKind.sos:
      return Icons.sos_rounded;
    case IncidentKind.possibleIncident:
      return Icons.report_rounded;
    case IncidentKind.noSignal:
      return Icons.signal_cellular_connected_no_internet_0_bar_rounded;
    case IncidentKind.noReply:
      return Icons.help_outline_rounded;
  }
}

/// The critical banner at the top of the ride map for someone else's
/// emergency: who and what ("Crash detected: Kiran", "Automatic crash
/// alert, 3 min ago"), where ("1.8 km north-east of you") and two big
/// buttons, Navigate and Open. A tap anywhere else also opens the incident
/// sheet. Static: no animation, no timer (the time moves on with the next
/// rebuild).
class IncidentBanner extends StatelessWidget {
  final IncidentView incident;
  final double? myLat;
  final double? myLng;
  final VoidCallback onOpen;

  /// Defaults to [navigateTo] with the incident's position.
  final VoidCallback? onNavigate;

  /// For "x min ago"; defaults to now.
  final int? nowMs;

  const IncidentBanner({
    super.key,
    required this.incident,
    this.myLat,
    this.myLng,
    required this.onOpen,
    this.onNavigate,
    this.nowMs,
  });

  @override
  Widget build(BuildContext context) {
    final i = incident;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final ago = i.startedAt > 0 ? formatAgo(Duration(milliseconds: (now - i.startedAt).clamp(0, 1 << 40).toInt())) : null;
    final where = incidentDistanceText(i, myLat: myLat, myLng: myLng);
    final what = ago == null ? i.what : '${i.what}, $ago';
    final helping = incidentHelpingText(i);
    final Color bg = StatusColors.critical;
    final Color fg = StatusColors.onCritical;
    VoidCallback? nav = onNavigate;
    if (nav == null && i.hasPosition) nav = () => navigateTo(i.lat, i.lng, label: i.who);

    return Semantics(
      container: true,
      liveRegion: true,
      label: [i.title, what, ?where, ?helping].join('. '),
      child: Material(
        color: bg,
        elevation: 2,
        shadowColor: AppTheme.shadow,
        shape: const RoundedRectangleBorder(borderRadius: Radii.mdAll),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(Space.s12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ExcludeSemantics(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(incidentIcon(i.kind), color: fg, size: 28),
                      const SizedBox(width: Space.s12),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(i.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(color: fg, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 2),
                            Text(what, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: fg)),
                            if (where != null)
                              Text(where, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: fg, fontWeight: FontWeight.w700)),
                            if (helping != null)
                              Text(helping, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: fg)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Space.s8),
                Row(
                  children: [
                    if (nav != null) ...[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: nav,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: fg,
                            side: BorderSide(color: fg, width: 1.5),
                            minimumSize: const Size.fromHeight(48),
                            padding: const EdgeInsets.symmetric(horizontal: Space.s8),
                          ),
                          icon: const Icon(Icons.navigation_rounded),
                          label: const Text('Navigate', maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                      const SizedBox(width: Space.s8),
                    ],
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: onOpen,
                        style: FilledButton.styleFrom(
                          backgroundColor: fg,
                          foregroundColor: bg,
                          minimumSize: const Size.fromHeight(48),
                          padding: const EdgeInsets.symmetric(horizontal: Space.s8),
                        ),
                        icon: const Icon(Icons.open_in_full_rounded),
                        label: const Text('Open', maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
