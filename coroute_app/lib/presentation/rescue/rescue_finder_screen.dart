// Round 10 rescue finder (responder phones): "Find Ravi". One simple guide from every signal:
//  * last known GPS + route (in-app emergency navigation, or a map app for walking), compass arrow
//    and distance; a small map from the offline tile cache;
//  * Bluetooth proximity meter (smoothed RSSI) with hotter / colder;
//  * locator beacon meter (near-ultrasonic SNR) with hotter / colder;
//  * "Listen: the siren should be audible now" when close;
//  * "Ping the phone": the victim's phone plays a loud burst now (server, or the offline mesh later);
//  * one big plain status line, and the honest note: sound and Bluetooth give proximity, not direction.
// Glove-friendly (64+ dp controls), keeps the screen on, opens over the locked cockpit (safety route
// 'safety/rescue_finder'), works offline with cached maps and the last known position.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/permissions/nearby_permission.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/rescue_finder_service.dart';
import '../../data/services/ride_mic_hub.dart';
import '../../data/services/safety_native.dart';
import '../../core/theme/map_tiles.dart';
import '../../domain/rescue/rescue_finder_model.dart';
import '../../domain/security/lock_screen_cockpit_policy.dart';
import '../ride/emergency_guidance.dart' show NavTarget, NavTargetKind;
import '../ride/incident_banner.dart' show navigateToEmergency;
import '../ride/navigate_to.dart';
import 'rescue_widgets.dart';

class RescueFinderScreen extends StatefulWidget {
  const RescueFinderScreen({super.key, required this.target});

  final RescueTarget target;

  /// Opens the finder for [target] (named safety route: allowed over the locked cockpit).
  static Future<void> open(BuildContext context, RescueTarget target) => Navigator.of(context).push(MaterialPageRoute<void>(
        settings: const RouteSettings(name: LockScreenCockpitPolicy.routeRescueFinder),
        builder: (_) => RescueFinderScreen(target: target),
      ));

  @override
  State<RescueFinderScreen> createState() => _RescueFinderScreenState();
}

class _RescueFinderScreenState extends State<RescueFinderScreen> {
  RescueFinderService? _finder;
  String? _pingNote;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable().catchError((Object _) {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _finder = context.read<RescueFinderService?>();
      _finder?.openFinder(widget.target);
    });
  }

  @override
  void dispose() {
    _finder?.closeFinder();
    WakelockPlus.disable().catchError((Object _) {});
    super.dispose();
  }

  Future<void> _askPermissions() async {
    try {
      await Permission.microphone.request();
    } catch (_) {}
    try {
      // "Nearby devices", shared with the pre-ride check and the offline mesh; blocked for good: app settings.
      await NearbyPermission.request(sdk: (await SafetyNative.deviceInfo()).sdkInt);
    } catch (_) {}
    if (!mounted) return;
    context.read<RideMicHub?>()?.reevaluate().ignore();
    _finder?.reevaluate();
  }

  void _ping(RescueFinderService f) {
    final r = f.ping();
    setState(() {
      _pingNote = switch (r) {
        PingOutcome.sent => "Asked ${widget.target.firstName}'s phone to sound now. Stop, stay quiet and listen.",
        PingOutcome.wait => 'Wait ${f.pingWaitSeconds} s before the next ping.',
        PingOutcome.offline => 'No connection to ask the phone. Its siren still sounds on its own every 30 to 60 s.',
        PingOutcome.noTarget => null,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final f = context.watch<RescueFinderService?>();
    final name = widget.target.firstName;
    if (f == null) {
      return Scaffold(appBar: AppBar(title: Text('Find $name')), body: const Center(child: Text('Not available right now.')));
    }
    final t = f.currentTarget() ?? widget.target;
    final g = f.guide();
    final closed = f.targetClosed;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              padding: dsScreenPadding,
              children: [
                DsScreenHeader(title: 'Find $name', onBack: () => Navigator.of(context).maybePop()),
                const SizedBox(height: Space.s12),
                if (closed)
                  _StatusCard(text: "$name's SOS is closed.", color: AppTheme.success)
                else
                  _StatusCard(text: g.status, sub: g.trendLine, color: _colorFor(g.closeness)),
                if (g.listenPrompt && !closed) ...[
                  const SizedBox(height: Space.s8),
                  Container(
                    padding: const EdgeInsets.all(Space.s12),
                    decoration: BoxDecoration(color: AppTheme.warning.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
                    child: Row(children: [
                      Icon(Icons.hearing_rounded, color: AppTheme.warning, size: 28),
                      const SizedBox(width: 10),
                      Expanded(child: Text("Listen: $name's siren should be audible now. Stop your engine, stay quiet, turn your head slowly.", style: AppText.body)),
                    ]),
                  ),
                ],
                const SizedBox(height: Space.s16),
                _Compass(guide: g),
                const SizedBox(height: Space.s12),
                if (t.lat != 0 || t.lng != 0) _MiniMap(lat: t.lat, lng: t.lng),
                if (g.gpsNote != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(g.gpsNote!, style: AppText.caption)),
                const SizedBox(height: Space.s12),
                Row(children: [
                  Expanded(
                    child: SizedBox(
                      height: 64,
                      child: FilledButton.icon(
                        onPressed: (t.lat == 0 && t.lng == 0)
                            ? null
                            : () => navigateToEmergency(
                                  context,
                                  NavTarget(kind: t.alertId.isNotEmpty ? NavTargetKind.groupEmergency : NavTargetKind.assist, ref: t.alertId.isNotEmpty ? t.alertId : t.incidentId, label: name),
                                  t.lat,
                                  t.lng,
                                ),
                        icon: const Icon(Icons.two_wheeler_rounded),
                        label: const Text('Ride there'),
                      ),
                    ),
                  ),
                  const SizedBox(width: Space.s8),
                  Expanded(
                    child: SizedBox(
                      height: 64,
                      child: OutlinedButton.icon(
                        onPressed: (t.lat == 0 && t.lng == 0) ? null : () => navigateTo(t.lat, t.lng, label: name, twoWheeler: false),
                        icon: const Icon(Icons.directions_walk_rounded),
                        label: const Text('Walk there'),
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: Space.s16),
                RescueMeter(
                  title: 'Bluetooth from $name\'s phone',
                  value: f.bleMeter(),
                  trend: f.bleTrend(),
                  emptyText: f.bleScanning ? 'Not picked up yet (range roughly 30 to 100 m).' : 'Bluetooth is off or not allowed.',
                  detail: 'Proximity only: walk and watch it rise.',
                ),
                const SizedBox(height: Space.s8),
                RescueMeter(
                  title: 'Rescue beacon sound',
                  value: f.beaconMeter(),
                  trend: f.beaconTrend(),
                  emptyText: f.micListening ? 'Not heard yet (range roughly 10 to 40 m).' : 'Microphone not listening.',
                  detail: 'Proximity only: walk and watch it rise.',
                ),
                if (!f.micListening || !f.bleScanning) ...[
                  const SizedBox(height: Space.s8),
                  TextButton.icon(
                    style: TextButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                    onPressed: _askPermissions,
                    icon: const Icon(Icons.settings_voice_rounded),
                    label: const Text('Allow microphone and nearby devices'),
                  ),
                ],
                if (f.otherBeacons.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('Another rescue beacon is nearby too.', style: AppText.caption),
                  ),
                const SizedBox(height: Space.s16),
                SizedBox(
                  height: 72,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: AppTheme.sos, foregroundColor: Colors.white),
                    onPressed: closed ? null : () => _ping(f),
                    icon: const Icon(Icons.notifications_active_rounded, size: 28),
                    label: Text("Ping $name's phone", style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                ),
                if (_pingNote != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_pingNote!, style: AppText.body)),
                const SizedBox(height: Space.s16),
                Text(RescueFinderModel.honestyNote, style: AppText.caption),
                const SizedBox(height: Space.s8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: f.helpAnyone,
                  onChanged: (v) => f.helpAnyone = v,
                  title: const Text('Help anyone'),
                  subtitle: const Text('Also follow rescue beacons of riders outside your group.'),
                ),
                const SizedBox(height: Space.s24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Color _colorFor(FinderCloseness c) => switch (c) {
        FinderCloseness.veryClose => AppTheme.sos,
        FinderCloseness.close => AppTheme.warning,
        FinderCloseness.near => AppTheme.warning,
        _ => AppTheme.infoBlue,
      };
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.text, required this.color, this.sub});
  final String text;
  final String? sub;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(Space.s16),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(16), border: Border.all(color: color, width: 2)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(text, style: TextStyle(color: AppTheme.text, fontSize: 20, fontWeight: FontWeight.w800, height: 1.25)),
          if (sub != null) ...[const SizedBox(height: 6), Text(sub!, style: TextStyle(color: AppTheme.text, fontSize: 16, fontWeight: FontWeight.w600))],
        ]),
      ),
    );
  }
}

class _Compass extends StatelessWidget {
  const _Compass({required this.guide});
  final FinderGuide guide;

  @override
  Widget build(BuildContext context) {
    final d = guide.distanceM;
    final arrow = guide.arrowDeg;
    final bearing = guide.bearingDeg;
    return Container(
      padding: const EdgeInsets.all(Space.s12),
      decoration: BoxDecoration(color: AppTheme.card, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppTheme.subtleBorder)),
      child: Row(children: [
        SizedBox(
          width: 96,
          height: 96,
          child: arrow == null
              ? Icon(Icons.explore_outlined, size: 64, color: AppTheme.textMuted)
              : Transform.rotate(angle: arrow * math.pi / 180, child: Icon(Icons.navigation_rounded, size: 88, color: AppTheme.sos)),
        ),
        const SizedBox(width: Space.s12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d == null ? 'Distance unknown' : RescueFinderModel.distanceWords(d), style: AppText.headline),
            const SizedBox(height: 4),
            Text(
              bearing == null
                  ? 'Waiting for both GPS positions.'
                  : (arrow == null ? 'Bearing ${bearing.round()}° from north. Hold the phone flat for the arrow.' : 'Arrow points to the last GPS position.'),
              style: AppText.caption,
            ),
          ]),
        ),
      ]),
    );
  }
}

class _MiniMap extends StatelessWidget {
  const _MiniMap({required this.lat, required this.lng});
  final double lat;
  final double lng;

  @override
  Widget build(BuildContext context) {
    final p = LatLng(lat, lng);
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        height: 180,
        child: FlutterMap(
          options: MapOptions(initialCenter: p, initialZoom: 16, interactionOptions: const InteractionOptions(flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag)),
          children: [
            appTileLayer(),
            MarkerLayer(markers: [Marker(point: p, width: 44, height: 44, child: Icon(Icons.location_on_rounded, color: AppTheme.sos, size: 44))]),
          ],
        ),
      ),
    );
  }
}
