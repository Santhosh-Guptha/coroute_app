import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/network_wire.dart';
import '../../data/models/safety_wire.dart';
import '../../domain/notify/relation.dart';
import '../../domain/tracking/bearing.dart';
import '../../domain/tracking/geo_math.dart';
import 'emergency_guidance.dart';
import 'incident_view.dart';
import 'navigate_to.dart';

/// Opens the phone app with [phone]; a short message when that fails.
Future<void> dialNumber(BuildContext context, String phone) async {
  final clean = phone.replaceAll(RegExp(r'[^0-9+]'), '');
  if (clean.isEmpty) return;
  var ok = false;
  try {
    ok = await launchUrl(Uri(scheme: 'tel', path: clean));
  } catch (_) {}
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open the phone app.')));
  }
}

/// Starts the in-app navigation to [target] when [EmergencyGuidance] is
/// available, else opens the phone's map app at [lat], [lng]. True when
/// something opened.
Future<bool> navigateToEmergency(BuildContext context, NavTarget target, double lat, double lng) async {
  final guidance = Provider.of<EmergencyGuidance?>(context, listen: false);
  if (guidance != null && await guidance.start(target)) return true;
  final ok = await navigateTo(lat, lng, label: target.label.isEmpty ? 'Emergency' : target.label);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No map app found on this phone.')));
  }
  return ok;
}

/// "4.8 km behind your location" (along the group route when both are on it), or null.
String? incidentRelationText(IncidentView incident, {double? myLat, double? myLng, List<(double, double)> route = const []}) {
  final la = myLat, ln = myLng;
  if (la == null || ln == null || (la == 0 && ln == 0) || !incident.hasPosition) return null;
  return Relation.text(myLat: la, myLng: ln, lat: incident.lat, lng: incident.lng, route: route);
}

/// "Nearby rider responding, ETA 3 min" / "Nearby rider has reached Rahul", or null (no external responder).
String? nearbyHelpText(IncidentView incident) {
  final r = incident.network?.activeResponder;
  if (r == null) return null;
  if (r.status == ResponderStatus.arrived) return 'Nearby rider has reached ${incident.firstName}';
  final eta = etaWords(r.etaS);
  return eta == null ? 'A nearby rider is responding' : 'Nearby rider responding, $eta';
}

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
/// emergency.
///
/// An SOS or crash of my group (3.15): "EMERGENCY", "Rahul may have met
/// with an accident", "4.8 km behind your location", "Last location
/// update: 8 seconds ago", the nearby help line, and the actions
/// **Navigate to Rahul** (in-app guidance), **Call Rahul** and **View
/// Emergency** (the sheet).
///
/// A possible incident, no signal or no reply: who and what, where, and
/// Navigate and Open. A tap anywhere also opens the incident sheet.
/// Static: no animation, no timer (the time moves on with the next rebuild).
class IncidentBanner extends StatelessWidget {
  final IncidentView incident;
  final double? myLat;
  final double? myLng;
  final VoidCallback onOpen;

  /// Defaults to the in-app navigation (or the phone's map app) to the incident's position.
  final VoidCallback? onNavigate;

  /// For "x min ago"; defaults to now.
  final int? nowMs;

  /// The group route, for "4.8 km behind your location".
  final List<(double, double)> route;

  /// The rider's phone for "Call Rahul"; empty hides the button.
  final String phone;

  const IncidentBanner({
    super.key,
    required this.incident,
    this.myLat,
    this.myLng,
    required this.onOpen,
    this.onNavigate,
    this.nowMs,
    this.route = const [],
    this.phone = '',
  });

  @override
  Widget build(BuildContext context) {
    final i = incident;
    if (i.isAlert && !i.isMe) return _emergency(context);
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final ago = i.startedAt > 0 ? formatAgo(Duration(milliseconds: (now - i.startedAt).clamp(0, 1 << 40).toInt())) : null;
    final where = incidentDistanceText(i, myLat: myLat, myLng: myLng);
    final what = ago == null ? i.what : '${i.what}, $ago';
    final helping = incidentHelpingText(i);
    final Color bg = AppTheme.sos;
    const Color fg = Colors.white;
    VoidCallback? nav = onNavigate;
    if (nav == null && i.hasPosition) nav = () => navigateTo(i.lat, i.lng, label: i.who);

    return Semantics(
      container: true,
      liveRegion: true,
      label: [i.title, what, ?where, ?helping].join('. '),
      child: Material(
        color: bg,
        elevation: 4,
        shadowColor: AppTheme.shadow,
        shape: const RoundedRectangleBorder(borderRadius: Radii.lgAll),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ExcludeSemantics(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(incidentIcon(i.kind), color: fg, size: 26),
                      const SizedBox(width: Space.s12),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(i.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(color: fg)),
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
                          style: _onRedOutlined(),
                          icon: const Icon(Icons.navigation_outlined),
                          label: Text(L10n.t('incident.navigate'), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                      const SizedBox(width: Space.s8),
                    ],
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: onOpen,
                        style: _onRedFilled(height: 48),
                        icon: const Icon(Icons.open_in_full_rounded),
                        label: Text(L10n.t('incident.open'), maxLines: 1, overflow: TextOverflow.ellipsis),
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

  /// The 3.15 own-group emergency banner.
  Widget _emergency(BuildContext context) {
    final i = incident;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final where = incidentRelationText(i, myLat: myLat, myLng: myLng, route: route);
    final updated = i.positionAt > 0 ? Relation.lastUpdate(i.positionAt, now) : null;
    final nearby = nearbyHelpText(i);
    final helping = nearby == null ? incidentHelpingText(i) : null;
    final compact = MediaQuery.sizeOf(context).height < 480;
    final own = i.ownNearest;
    final ownEta = own == null ? null : etaWords(own.etaS);
    final nearest = (own == null || own.name.trim().isEmpty) ? null : 'Nearest member: ${own.name.trim()}${ownEta == null ? '' : ', $ownEta'}';
    final Color bg = AppTheme.sos;
    const Color fg = Colors.white;
    final id = i.alertId;
    VoidCallback? nav = onNavigate;
    if (nav == null && i.hasPosition) {
      nav = () => navigateToEmergency(
            context,
            NavTarget(kind: NavTargetKind.groupEmergency, ref: id ?? i.subjectUserId, label: i.firstName),
            i.lat,
            i.lng,
          );
    }
    final call = phone.trim().isEmpty ? null : () => dialNumber(context, phone);
    final semantics = [L10n.t('incident.emergency'), i.summary, ?where, ?updated, ?nearby, ?helping, ?nearest].join('. ');

    ButtonStyle outlined() => _onRedOutlined();

    return Semantics(
      container: true,
      liveRegion: true,
      label: semantics,
      child: Material(
        color: bg,
        elevation: 4,
        shadowColor: AppTheme.shadow,
        shape: const RoundedRectangleBorder(borderRadius: Radii.lgAll),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ExcludeSemantics(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(incidentIcon(i.kind), color: fg, size: 26),
                      const SizedBox(width: Space.s12),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(L10n.t('incident.emergency'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: sosPaleRose, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.5, height: 1.3)),
                            Text(i.summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(color: fg)),
                            if (where != null)
                              Text(where, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: fg, fontWeight: FontWeight.w700)),
                            if (updated != null && !compact)
                              Text(updated, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: sosPaleRose)),
                            if (helping != null)
                              Text(helping, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: fg)),
                            if (nearest != null && !compact)
                              Text(nearest, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: fg)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (nearby != null) ...[
                  const SizedBox(height: Space.s8),
                  ExcludeSemantics(child: PositiveLine(text: nearby)),
                ],
                const SizedBox(height: Space.s8),
                if (nav != null)
                  FilledButton.icon(
                    onPressed: nav,
                    style: _onRedFilled(height: 56),
                    icon: const Icon(Icons.navigation_outlined),
                    label: Text(L10n.t('incident.navigateTo', {'name': i.firstName}), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                const SizedBox(height: Space.s8),
                Row(
                  children: [
                    if (call != null) ...[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: call,
                          style: outlined(),
                          icon: const Icon(Icons.call_outlined),
                          label: Text(L10n.t('incident.call', {'name': i.firstName}), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                      const SizedBox(width: Space.s8),
                    ],
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: onOpen,
                        style: outlined(),
                        icon: const Icon(Icons.open_in_full_rounded),
                        label: Text(L10n.t('incident.view'), maxLines: 1, overflow: TextOverflow.ellipsis),
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

/// Pale rose for secondary text on the red banner.
const Color sosPaleRose = Color(0xFFFFD0D7);

/// White button with red text on the red banner.
ButtonStyle _onRedFilled({double height = 48}) => FilledButton.styleFrom(
      backgroundColor: Colors.white,
      foregroundColor: AppTheme.sos,
      minimumSize: Size.fromHeight(height),
      padding: const EdgeInsets.symmetric(horizontal: Space.s8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      textStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontSize: 15, fontWeight: FontWeight.w800),
    );

/// Outlined white button on the red banner.
ButtonStyle _onRedOutlined({double height = 48}) => OutlinedButton.styleFrom(
      foregroundColor: Colors.white,
      backgroundColor: Colors.transparent,
      side: BorderSide(color: Colors.white.withValues(alpha: 0.6), width: 2),
      minimumSize: Size.fromHeight(height),
      padding: const EdgeInsets.symmetric(horizontal: Space.s8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      textStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontSize: 15, fontWeight: FontWeight.w800),
    );

/// A short positive line: "Nearby rider responding, ETA 3 min". Solid teal
/// with white text so it reads on the red banner and in the sheets.
class PositiveLine extends StatelessWidget {
  final String text;
  final String? detail;
  const PositiveLine({super.key, required this.text, this.detail});

  @override
  Widget build(BuildContext context) {
    final Color bg = AppTheme.brand;
    const Color fg = Colors.white;
    final d = detail;
    return Semantics(
      container: true,
      label: d == null ? text : '$text. $d',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: bg, borderRadius: Radii.mdAll),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.health_and_safety_outlined, size: 20, color: fg),
            const SizedBox(width: Space.s8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: fg, fontWeight: FontWeight.w800)),
                  if (d != null) Text(d, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: DsHeroCard.secondary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
