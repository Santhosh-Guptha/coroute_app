import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../core/constants/app_constants.dart';
import '../../core/constants/telemetry_utils.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/cockpit_hud.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/rider_model.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/trip_storage_service.dart';
import '../widgets/emergency_sos_sheet.dart';
import '../widgets/intercom_dock.dart';
import '../widgets/rider_status_sheet.dart';
import '../../data/services/geo_service.dart';
import '../map_picker/map_picker_screen.dart';
import '../trip_planner/route_stops_panel.dart';
import '../../data/models/stop_point_model.dart';
import '../../core/theme/map_tiles.dart';
import '../timeline/live_timeline_screen.dart';

class LiveCockpitMapScreen extends StatefulWidget {
  final String convoyId;

  const LiveCockpitMapScreen({super.key, required this.convoyId});

  @override
  State<LiveCockpitMapScreen> createState() => _LiveCockpitMapScreenState();
}

class _LiveCockpitMapScreenState extends State<LiveCockpitMapScreen> {
  final MapController _mapController = MapController();
  bool _autoFollow = true;
  bool _keepScreenOn = false;
  final Set<String> _dismissedAlertIds = {};
  StreamSubscription<CompassEvent>? _compassSub;
  double? _deviceCompassHeading;
  DateTime _lastCompassPaint = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    // Hardware compass (device facing). Repaint at most ~4×/s and only on a real change,
    // so the map is not rebuilt on every magnetometer sample.
    _compassSub = FlutterCompass.events?.listen((CompassEvent event) {
      if (event.heading == null || !mounted) return;
      double h = event.heading!;
      if (h < 0) h += 360.0;
      final prev = _deviceCompassHeading;
      final now = DateTime.now();
      final delta = prev == null ? 999.0 : ((h - prev).abs() % 360);
      if (delta >= 2.0 && now.difference(_lastCompassPaint).inMilliseconds >= 250) {
        _lastCompassPaint = now;
        setState(() => _deviceCompassHeading = h);
      } else {
        _deviceCompassHeading = h;
      }
    });
  }

  @override
  void dispose() {
    _compassSub?.cancel();
    if (_keepScreenOn) WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _toggleKeepScreenOn() async {
    final next = !_keepScreenOn;
    try {
      if (next) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (e) {
      debugPrint('wakelock note: $e');
    }
    if (mounted) setState(() => _keepScreenOn = next);
  }

  /// 1. Riders List Modal: Details + Pan/Navigate to Rider on Map
  void _showRidersListModal(BuildContext context, ConvoyModel convoy, RiderModel myRider) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        final riders = convoy.riders.values.toList();
        return Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
          decoration: BoxDecoration(
            color: AppTheme.obsidianVoid,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            border: Border(top: BorderSide(color: AppTheme.neonCyan, width: 1.5)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: AppTheme.textMuted,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(child: Text(
                    '🏍️ Convoy Pack (${riders.length} Riders)',
                    style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis)),
                  IconButton(
                    icon: Icon(Icons.close, color: AppTheme.textMuted, size: 20),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              Divider(color: AppTheme.glassBorder),
              Expanded(
                child: ListView.separated(
                  itemCount: riders.length,
                  separatorBuilder: (context, index) => Divider(color: AppTheme.glassBorder, height: 1),
                  itemBuilder: (context, idx) {
                    final r = riders[idx];
                    final isMe = r.userId == myRider.userId || r.name == myRider.name;
                    final isOffline = !isMe && r.lastSeenEpochMs > 0 && (DateTime.now().millisecondsSinceEpoch - r.lastSeenEpochMs) > 60000;
                    final minutesAgo = isOffline ? ((DateTime.now().millisecondsSinceEpoch - r.lastSeenEpochMs) / 60000).round() : 0;
                    Color roleColor = isOffline ? AppTheme.hyperAmber : AppTheme.neonCyan;
                    if (!isOffline && r.role == 'LEAD') roleColor = AppTheme.hyperAmber;
                    if (!isOffline && r.role == 'SWEEPER') roleColor = AppTheme.electricBlue;

                    final distanceMeters = TelemetryUtils.calculateDistanceMeters(
                      LatLng(myRider.lat, myRider.lng),
                      LatLng(r.lat, r.lng),
                    );
                    final distText = distanceMeters > 1000
                        ? '${(distanceMeters / 1000.0).toStringAsFixed(1)} km away'
                        : '${distanceMeters.round()} m away';

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                      leading: Stack(
                        alignment: Alignment.bottomRight,
                        children: [
                          CircleAvatar(
                            backgroundColor: roleColor.withOpacity(0.2),
                            child: Text(
                              r.name.isNotEmpty ? r.name[0].toUpperCase() : 'R',
                              style: TextStyle(color: roleColor, fontWeight: FontWeight.bold),
                            ),
                          ),
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isOffline ? AppTheme.laserRed : (r.speedKmh > 1.5 ? AppTheme.emeraldSafe : AppTheme.hyperAmber),
                              border: Border.all(color: Colors.black, width: 1.5),
                            ),
                          ),
                        ],
                      ),
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(
                              isMe ? '${r.name} (You)' : r.name,
                              style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 14),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: roleColor.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: roleColor, width: 0.8),
                            ),
                            child: Text(
                              isOffline ? 'OFFLINE' : r.role,
                              style: TextStyle(color: roleColor, fontSize: 9, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                isOffline ? 'Signal Lost' : '${r.speedKmh.round()} km/h',
                                style: TextStyle(color: isOffline ? AppTheme.laserRed : AppTheme.neonCyan, fontSize: 11, fontWeight: FontWeight.bold),
                              ),
                              Text(' · ', style: TextStyle(color: AppTheme.textMuted)),
                              Icon(
                                r.isCharging ? Icons.battery_charging_full_rounded : Icons.battery_std_rounded,
                                size: 13,
                                color: r.batteryLevel < 20 ? AppTheme.laserRed : AppTheme.emeraldSafe,
                              ),
                              Text(
                                ' ${r.batteryLevel}%',
                                style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                              ),
                              if (!isMe && (r.lat != 0.0 || r.lng != 0.0)) ...[
                                Text(' · ', style: TextStyle(color: AppTheme.textMuted)),
                                Text(
                                  distText,
                                  style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                                ),
                              ],
                            ],
                          ),
                          if (isOffline)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                '⚠️ Last captured location · ${minutesAgo <= 1 ? "1m" : "${minutesAgo}m"} ago',
                                style: TextStyle(color: AppTheme.hyperAmber, fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                            ),
                        ],
                      ),
                      trailing: IconButton(
                        tooltip: isOffline ? 'Pan map to last known location' : 'Pan map to this rider',
                        icon: Icon(isOffline ? Icons.pin_drop_rounded : Icons.near_me_rounded, color: isOffline ? AppTheme.hyperAmber : AppTheme.neonCyan, size: 22),
                        onPressed: () {
                          if (r.lat != 0.0 && r.lng != 0.0) {
                            setState(() => _autoFollow = false);
                            _mapController.move(LatLng(r.lat, r.lng), 16.5);
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(isOffline ? 'Focused map on ${r.name}\'s last known location' : 'Focused map on ${r.name}')),
                            );
                          }
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 2. In-Map Convoy Live Chat Modal: Read & Send without leaving map
  void _showChatModal(BuildContext context, ConvoyModel convoy, ConvoyService convoyService, RiderModel myRider) {
    final textCtrl = TextEditingController();
    final scrollCtrl = ScrollController();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final currentConvoy = convoyService.allConvoys[convoy.groupId] ?? convoy;
            final messages = currentConvoy.messages;

            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
              child: Container(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
                decoration: BoxDecoration(
                  color: AppTheme.obsidianVoid,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                  border: Border(top: BorderSide(color: AppTheme.neonCyan, width: 1.5)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: AppTheme.textMuted,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(child: Text(
                          '💬 Convoy Live Chat (${messages.length})',
                          style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis)),
                        IconButton(
                          icon: Icon(Icons.close, color: AppTheme.textMuted, size: 20),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    // Quick safety pills
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          {'emoji': '⛽', 'text': 'Need Fuel Stop'},
                          {'emoji': '☕', 'text': 'Tea / Rest Break'},
                          {'emoji': '⚠️', 'text': 'Road Hazard Ahead'},
                          {'emoji': '🛑', 'text': 'Regroup Here'},
                          {'emoji': '👍', 'text': 'All Good / Moving'},
                        ].map((q) {
                          return Padding(
                            padding: const EdgeInsets.only(right: 6, bottom: 8),
                            child: ActionChip(
                              backgroundColor: AppTheme.elevatedCard,
                              label: Text('${q['emoji']} ${q['text']}', style: TextStyle(color: AppTheme.textPrimary, fontSize: 11)),
                              side: BorderSide(color: AppTheme.glassBorder),
                              onPressed: () {
                                convoyService.sendGroupMessage(
                                  senderId: myRider.userId,
                                  senderName: myRider.name,
                                  text: '${q['emoji']} ${q['text']}',
                                  isQuickCard: true,
                                );
                                setModalState(() {});
                              },
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    Divider(color: AppTheme.glassBorder, height: 1),
                    Expanded(
                      child: messages.isEmpty
                          ? Center(
                              child: Text('No messages yet. Send a quick shout-out!', style: TextStyle(color: AppTheme.textMuted)),
                            )
                          : ListView.builder(
                              controller: scrollCtrl,
                              itemCount: messages.length,
                              itemBuilder: (context, i) {
                                final msg = messages[i];
                                final isMe = msg.senderId == myRider.userId || msg.senderName == myRider.name;
                                return Align(
                                  alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(vertical: 4),
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: isMe ? AppTheme.neonCyan.withOpacity(0.2) : AppTheme.slateCard,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isMe ? AppTheme.neonCyan.withOpacity(0.5) : AppTheme.glassBorder,
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                      children: [
                                        if (!isMe)
                                          Text(
                                            msg.senderName,
                                            style: TextStyle(color: AppTheme.neonCyan, fontSize: 10, fontWeight: FontWeight.bold),
                                          ),
                                        Text(
                                          msg.text,
                                          style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: textCtrl,
                            style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                            decoration: InputDecoration(
                              hintText: 'Type a message to pack...',
                              hintStyle: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                              filled: true,
                              fillColor: AppTheme.elevatedCard,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: Icon(Icons.send_rounded, color: AppTheme.neonCyan),
                          onPressed: () {
                            final txt = textCtrl.text.trim();
                            if (txt.isNotEmpty) {
                              convoyService.sendGroupMessage(
                                senderId: myRider.userId,
                                senderName: myRider.name,
                                text: txt,
                              );
                              textCtrl.clear();
                              setModalState(() {});
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 3. Route and stops sheet: same panel as the convoy screen.
  void _showStopsModal(BuildContext context, ConvoyModel convoy, ConvoyService convoyService) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
          decoration: BoxDecoration(
            color: AppTheme.obsidianVoid,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            border: Border(top: BorderSide(color: AppTheme.hyperAmber, width: 1.5)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 4),
                decoration: BoxDecoration(color: AppTheme.textMuted, borderRadius: BorderRadius.circular(2)),
              ),
              Row(
                children: [
                  const SizedBox(width: 16),
                  Expanded(child: Text('Route and stops', style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.bold))),
                  IconButton(icon: Icon(Icons.close, color: AppTheme.textMuted, size: 20), onPressed: () => Navigator.pop(ctx)),
                ],
              ),
              Flexible(
                child: Consumer<ConvoyService>(
                  builder: (_, svc, _) => RouteStopsPanel(convoy: svc.allConvoys[convoy.groupId] ?? convoy),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Marker _stopMarker(StopPointModel st, int i) => Marker(
        point: LatLng(st.lat, st.lng),
        width: 28,
        height: 28,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: st.isVisited ? AppTheme.emeraldSafe : AppTheme.hyperAmber,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.black, width: 1.5),
          ),
          child: Text('${i + 1}', style: const TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.bold)),
        ),
      );

  Future<void> _addStopAt(BuildContext context, ConvoyService service, LatLng point) async {
    final lead = service.canEditRoute;
    final p = await MapPickerScreen.pick(
      context,
      title: lead ? 'Add a stop' : 'Suggest a stop',
      forStop: true,
      confirmLabel: lead ? 'Add stop' : 'Send suggestion',
      initial: PickedPlace(lat: point.latitude, lng: point.longitude),
    );
    if (p == null) return;
    final ok = lead ? service.addStop(p) : service.suggestStop(p);
    if (ok && !lead && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Suggestion sent to the lead.')));
    }
  }

  /// Map Floating Quick-Button Widget
  Widget _buildMapQuickButton({
    required IconData icon,
    required VoidCallback onTap,
    String? badgeText,
    Color? badgeColor,
    required String tooltip,
  }) {
    badgeColor ??= AppTheme.neonCyan;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppTheme.obsidianVoid.withOpacity(0.85),
                shape: BoxShape.circle,
                border: Border.all(color: AppTheme.glassBorder, width: 1.2),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.shadow,
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Center(
                child: Icon(icon, color: AppTheme.textPrimary, size: 20),
              ),
            ),
            if (badgeText != null)
              Positioned(
                top: -3,
                right: -3,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: badgeColor,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.black, width: 1.2),
                  ),
                  child: Text(
                    badgeText,
                    style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.w900,
                      fontSize: 9,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showEndTripDialog(BuildContext context, ConvoyModel convoy) {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppTheme.slateCard,
          title: Text('Conclude Journey?', style: TextStyle(color: AppTheme.textPrimary)),
          content: Text(
            'This will complete the ride for "${convoy.name}" and save your full route and statistics to Trip History.',
            style: TextStyle(color: AppTheme.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Keep Riding', style: TextStyle(color: AppTheme.textMuted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.hyperAmber),
              onPressed: () async {
                final tripStorage = context.read<TripStorageService>();
                final convoyService = context.read<ConvoyService>();
                final auth = context.read<AuthService>();
                final history = convoyService.buildTripHistory(convoy, userId: auth.currentUserId);
                await tripStorage.saveTrip(history, userId: auth.currentUserId);
                convoyService.updateTripState('ENDED');

                if (ctx.mounted) Navigator.pop(ctx);
                if (context.mounted) Navigator.pop(context);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Journey saved to your trip history.'),
                      backgroundColor: AppTheme.emeraldSafe,
                    ),
                  );
                }
              },
              child: const Text('Save & Finish', style: TextStyle(color: Colors.black)),
            ),
          ],
        );
      },
    );
  }

  void _triggerSos(BuildContext context, ConvoyService convoyService, AuthService auth) async {
    final currentUserName = auth.currentUserName ?? 'Rider';
    final myRider = convoyService.activeConvoy?.riders[auth.currentUserId ?? ''];

    double lat = myRider?.lat ?? 0.0;
    double lng = myRider?.lng ?? 0.0;

    // If rider has no valid position, get real GPS as fallback
    if (lat == 0.0 && lng == 0.0) {
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 5),
          ),
        );
        lat = pos.latitude;
        lng = pos.longitude;
      } catch (_) {}
    }

    final myUserId = myRider?.userId ?? auth.currentUserId ?? '';

    convoyService.triggerSosAlert(
      userId: myUserId,
      userName: currentUserName,
      lat: lat,
      lng: lng,
    );

    if (context.mounted) {
      EmergencySosSheet.show(
        context,
        lat: lat,
        lng: lng,
      );
    }
  }

  LatLng? _lastFollowed;

  /// Where to open the map: my position, else another rider's, else the trip start.
  LatLng _initialCenter(RiderModel me, ConvoyModel convoy) {
    if (me.lat != 0 || me.lng != 0) return LatLng(me.lat, me.lng);
    for (final r in convoy.riders.values) {
      if (r.lat != 0 || r.lng != 0) return LatLng(r.lat, r.lng);
    }
    if (convoy.startLat != null && convoy.startLng != null) return LatLng(convoy.startLat!, convoy.startLng!);
    return const LatLng(AppConstants.defaultMapLat, AppConstants.defaultMapLng); // centre of India
  }

  /// Keeps my marker in view while auto-follow is on. Moves only when I moved
  /// more than 15 m (no constant redraws, which would cost battery).
  void _follow(RiderModel me, ConvoyModel convoy) {
    if (!_autoFollow || (me.lat == 0 && me.lng == 0)) return;
    final here = LatLng(me.lat, me.lng);
    final last = _lastFollowed;
    if (last != null && const Distance().as(LengthUnit.Meter, last, here) < 15) return;
    final first = last == null;
    _lastFollowed = here;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_autoFollow) return;
      try {
        _mapController.move(here, first ? 15.5 : _mapController.camera.zoom);
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final convoyService = context.watch<ConvoyService>();
    final convoy = convoyService.allConvoys[widget.convoyId];

    if (convoy == null) {
      return Scaffold(
        backgroundColor: AppTheme.obsidianVoid,
        appBar: AppBar(title: const Text('Convoy Concluded')),
        body: Center(
          child: Text('This convoy has been dissolved or ended.', style: TextStyle(color: AppTheme.textMuted)),
        ),
      );
    }

    final riders = convoy.riders.values.toList();
    final metrics = TelemetryUtils.calculateConvoyMetrics(riders);

    // Current user rider reference
    final myRider = convoy.riders[auth.currentUserId ?? ''] ??
        RiderModel(userId: auth.currentUserId ?? '0', name: auth.currentUserName ?? 'Rider', lat: 0.0, lng: 0.0, lastSeenEpochMs: 0);

    _follow(myRider, convoy);

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      body: Stack(
        children: [
          // 1. OpenStreetMap High-DPI Engine (100% Free, Zero Watermarks)
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _initialCenter(myRider, convoy),
              initialZoom: (myRider.lat != 0 || myRider.lng != 0) ? 15.5 : 12,
              onPositionChanged: (pos, hasGesture) {
                if (hasGesture && _autoFollow) {
                  setState(() => _autoFollow = false);
                }
              },
              // Long-press anywhere: the lead adds a stop there, anyone else suggests one.
              onLongPress: (_, point) => _addStopAt(context, convoyService, point),
            ),
            children: [
              TileLayer(
                tileBuilder: mapTileBuilder,
                urlTemplate: AppConstants.osmTileUrl,
                userAgentPackageName: AppConstants.osmUserAgent,
              ),

              // Planned route through every stop.
              if (convoy.routeLine.length >= 2)
                PolylineLayer(polylines: [
                  Polyline(
                    points: [for (final (lat, lng) in convoy.routeLine) LatLng(lat, lng)],
                    strokeWidth: 5,
                    color: (convoy.route?.approximate ?? false) ? AppTheme.neonCyan.withOpacity(0.45) : AppTheme.neonCyan.withOpacity(0.75),
                  ),
                ]),

              // Stops (numbered; suggestions dimmed) and destination.
              MarkerLayer(markers: [
                for (var i = 0; i < convoy.plannedStops.length; i++)
                  _stopMarker(convoy.plannedStops[i], i),
                for (final st in convoy.suggestedStops)
                  Marker(
                    point: LatLng(st.lat, st.lng),
                    width: 26,
                    height: 26,
                    child: Icon(Icons.add_location_rounded, color: AppTheme.hyperAmber, size: 24),
                  ),
                if (convoy.destinationLat != 0 || convoy.destinationLng != 0)
                  Marker(
                    point: LatLng(convoy.destinationLat, convoy.destinationLng),
                    width: 34,
                    height: 34,
                    child: Icon(Icons.sports_score_rounded, color: AppTheme.laserRed, size: 30),
                  ),
              ]),

              // Rider Markers with Directional Rotating Chevrons
              MarkerLayer(
                markers: riders.where((r) => r.lat != 0.0 && r.lng != 0.0).map((r) {
                  final isMe = r.userId == myRider.userId || r.name.toLowerCase() == myRider.name.toLowerCase();
                  final isOffline = !isMe && r.lastSeenEpochMs > 0 && (DateTime.now().millisecondsSinceEpoch - r.lastSeenEpochMs) > 60000;
                  Color roleColor = isOffline ? AppTheme.hyperAmber : AppTheme.neonCyan;
                  if (!isOffline && r.role == 'LEAD') roleColor = AppTheme.hyperAmber;
                  if (!isOffline && r.role == 'SWEEPER') roleColor = AppTheme.electricBlue;

                  // Heading calculation with Compass Sensor Fusion
                  final effectiveHeading = isMe
                      ? ((r.speedKmh < 10.0 && _deviceCompassHeading != null) ? _deviceCompassHeading! : r.heading)
                      : r.heading;

                  final hasStatus = r.statusReason.isNotEmpty;
                  final statusEmoji = hasStatus ? RiderStatusSheet.getStatusEmoji(r.statusReason) : '';
                  final statusLabel = hasStatus ? RiderStatusSheet.getStatusLabel(r.statusReason) : '';

                  return Marker(
                    point: LatLng(r.lat, r.lng),
                    width: 112,
                    height: 64,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Rider name & speed tag / status badge
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.slateCard.withOpacity(0.92),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: (isOffline ? AppTheme.laserRed : (hasStatus ? AppTheme.hyperAmber : roleColor)).withOpacity(0.8), width: 0.8),
                          ),
                          constraints: const BoxConstraints(maxWidth: 118),
                          child: Text(
                            isOffline
                                ? '${r.name.split(' ').first} · last seen ${((DateTime.now().millisecondsSinceEpoch - r.lastSeenEpochMs) ~/ 60000).clamp(1, 999)}m'
                                : (hasStatus
                                    ? '$statusEmoji ${isMe ? "You" : r.name.split(' ').first} · $statusLabel'
                                    : '${isMe ? "You" : r.name.split(' ').first} · ${r.speedKmh.toStringAsFixed(0)} km/h'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isOffline ? AppTheme.hyperAmber : (hasStatus ? AppTheme.hyperAmber : roleColor),
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),

                        // Directional Chevron Pointer / Last Location Marker
                        Transform.rotate(
                          angle: effectiveHeading * (math.pi / 180.0),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isOffline ? AppTheme.hyperAmber : roleColor,
                              border: Border.all(color: Colors.black, width: 2.2),
                              boxShadow: [
                                BoxShadow(
                                  color: (isOffline ? AppTheme.laserRed : roleColor).withOpacity(0.5),
                                  blurRadius: 8,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                            child: Center(
                              child: Icon(
                                isOffline ? Icons.pin_drop_rounded : Icons.navigation,
                                color: Colors.black,
                                size: 18,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ],
          ),

          // 2. Top Convoy Formation Status Bar
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            right: 12,
            child: Column(
              children: [
                // Global Emergency Safety Broadcast Banner (if active)
                if (convoyService.systemBroadcastMessage != null) ...[
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.laserRed,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.laserRed.withOpacity(0.4),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning, color: Colors.white, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            convoyService.systemBroadcastMessage!,
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Active SOS Emergency Alert Banner
                ...(() {
                  final myUserId = auth.currentUserId ?? myRider.userId;

                  // Active SOS alerts from current user (Self SOS - show status + cancel option, NO loud alarm)
                  final mySos = convoy.activeAlerts.where((a) => !a.resolved && a.userId == myUserId).toList();

                  // Active SOS alerts from OTHER riders
                  final otherSos = convoy.activeAlerts
                      .where((a) => !a.resolved && a.userId != myUserId && !_dismissedAlertIds.contains(a.alertId))
                      .toList();

                  final widgets = <Widget>[];

                  if (mySos.isNotEmpty) {
                    final alert = mySos.last;
                    widgets.add(
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppTheme.hyperAmber.withOpacity(0.95),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.hyperAmber.withOpacity(0.4),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.emergency_share_rounded, color: Colors.black, size: 20),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '🚨 YOUR SOS IS ACTIVE',
                                    style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12),
                                  ),
                                  Text(
                                    'Convoy members have your live coordinates',
                                    style: TextStyle(color: Colors.black87, fontSize: 10),
                                  ),
                                ],
                              ),
                            ),
                            ElevatedButton(
                              onPressed: () {
                                convoyService.resolveSosAlert(alert.alertId);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Your SOS emergency has been cancelled.')),
                                );
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.black,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text('CANCEL SOS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10)),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  if (otherSos.isNotEmpty) {
                    final lastSos = otherSos.last;
                    widgets.add(
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppTheme.laserRed,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.laserRed.withOpacity(0.5),
                              blurRadius: 10,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '🚨 SOS: ${lastSos.userName} NEEDS HELP!',
                                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                                  ),
                                  Text(
                                    'Type: ${lastSos.alertType}',
                                    style: TextStyle(color: Colors.white70, fontSize: 10),
                                  ),
                                ],
                              ),
                            ),
                            if (lastSos.lat != 0.0 && lastSos.lng != 0.0)
                              IconButton(
                                tooltip: 'Focus on Map',
                                icon: Icon(Icons.location_searching, color: AppTheme.textPrimary, size: 18),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () {
                                  setState(() => _autoFollow = false);
                                  _mapController.move(LatLng(lastSos.lat, lastSos.lng), 17.0);
                                },
                              ),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: 'Acknowledge & Dismiss',
                              icon: Icon(Icons.check_circle_outline, color: AppTheme.textPrimary, size: 20),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () {
                                setState(() {
                                  _dismissedAlertIds.add(lastSos.alertId);
                                });
                                convoyService.resolveSosAlert(lastSos.alertId);
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  return widgets;
                })(),

                // Stopped Rider Prompt Banner (Section 5.5 in PROJECT_CONTEXT.md)
                if (myRider.statusReason.isEmpty &&
                    myRider.stoppedSince > 0 &&
                    DateTime.now().millisecondsSinceEpoch - myRider.stoppedSince >= convoy.stopThresholdSeconds * 1000) ...[
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppTheme.hyperAmber.withOpacity(0.18),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.hyperAmber.withOpacity(0.7)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.local_parking_rounded, color: AppTheme.hyperAmber, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Stopped ${((DateTime.now().millisecondsSinceEpoch - myRider.stoppedSince) ~/ 60000)} min',
                            style: TextStyle(color: AppTheme.hyperAmber, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.hyperAmber,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () => RiderStatusSheet.show(context, convoyService: convoyService, userId: myRider.userId),
                          child: const Text('Set Reason', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ),
                ],

                // Active Status Banner (if current rider set a status)
                if (myRider.statusReason.isNotEmpty) ...[
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppTheme.slateCard.withOpacity(0.92),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppTheme.hyperAmber.withOpacity(0.6)),
                    ),
                    child: Row(
                      children: [
                        Text(RiderStatusSheet.getStatusEmoji(myRider.statusReason), style: const TextStyle(fontSize: 14)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Status: ${RiderStatusSheet.getStatusLabel(myRider.statusReason)}${myRider.statusMessage.isNotEmpty ? ": ${myRider.statusMessage}" : ""}',
                            style: TextStyle(color: AppTheme.textPrimary, fontSize: 11, fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero),
                          onPressed: () => convoyService.updateStatusReason(userId: myRider.userId, reason: ''),
                          child: Text('Clear', style: TextStyle(color: AppTheme.laserRed, fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ),
                ],

                // Convoy Header Card
                GlassCard(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: Icon(Icons.arrow_back, color: AppTheme.textPrimary, size: 20),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              convoy.name,
                              style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${metrics.activeRiderCount} online · ${metrics.spreadKm.toStringAsFixed(1)} km spread · ${metrics.averageSpeedKmh.toStringAsFixed(0)} km/h avg',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: AppTheme.textSecondary, fontSize: 10),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Color(metrics.statusColor).withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Color(metrics.statusColor).withOpacity(0.6)),
                        ),
                        child: Text(
                          metrics.status,
                          style: TextStyle(
                            color: Color(metrics.statusColor),
                            fontWeight: FontWeight.bold,
                            fontSize: 10,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: 'End Ride',
                        icon: Icon(Icons.flag_circle, color: AppTheme.hyperAmber, size: 22),
                        onPressed: () => _showEndTripDialog(context, convoy),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // Speed / heading / battery on the left, quick actions on the right, always below the header.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Flexible(
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: CockpitHud(
                          speedKmh: myRider.speedKmh,
                          heading: (myRider.speedKmh < 10.0 && _deviceCompassHeading != null) ? _deviceCompassHeading! : myRider.heading,
                          batteryLevel: myRider.batteryLevel,
                          isCharging: myRider.isCharging,
                          speedLimitKmh: convoy.speedLimitKmh,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      children: [
                        _buildMapQuickButton(
                          icon: Icons.two_wheeler_rounded,
                          badgeText: '${riders.length}',
                          badgeColor: AppTheme.neonCyan,
                          tooltip: 'Riders',
                          onTap: () => _showRidersListModal(context, convoy, myRider),
                        ),
                        const SizedBox(height: 10),
                        _buildMapQuickButton(
                          icon: Icons.chat_bubble_rounded,
                          badgeText: convoy.messages.isNotEmpty ? '${convoy.messages.length}' : null,
                          badgeColor: AppTheme.hyperAmber,
                          tooltip: 'Chat',
                          onTap: () => _showChatModal(context, convoy, convoyService, myRider),
                        ),
                        const SizedBox(height: 10),
                        _buildMapQuickButton(
                          icon: Icons.flag_rounded,
                          badgeText: convoy.plannedStops.isNotEmpty ? '${convoy.plannedStops.length}' : null,
                          badgeColor: AppTheme.emeraldSafe,
                          tooltip: 'Route and stops',
                          onTap: () => _showStopsModal(context, convoy, convoyService),
                        ),
                        const SizedBox(height: 10),
                        _buildMapQuickButton(
                          icon: Icons.timeline_rounded,
                          badgeText: null,
                          badgeColor: AppTheme.neonCyan,
                          tooltip: 'Live Timeline',
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => LiveTimelineScreen(groupId: convoy.groupId)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),

          // 4a. Keep screen on (for a phone mounted on the handlebar)
          Positioned(
            right: 14,
            bottom: 172,
            child: FloatingActionButton.small(
              heroTag: 'screen_on_btn',
              tooltip: _keepScreenOn ? 'Screen stays on. Tap to allow sleep.' : 'Keep screen on while riding',
              backgroundColor: AppTheme.slateCard,
              foregroundColor: _keepScreenOn ? AppTheme.hyperAmber : AppTheme.textMuted,
              onPressed: _toggleKeepScreenOn,
              child: Icon(_keepScreenOn ? Icons.light_mode_rounded : Icons.light_mode_outlined),
            ),
          ),

          // 4. Recenter FAB
          Positioned(
            right: 14,
            bottom: 120,
            child: FloatingActionButton.small(
              heroTag: 'recenter_btn',
              backgroundColor: AppTheme.slateCard,
              foregroundColor: _autoFollow ? AppTheme.neonCyan : AppTheme.textMuted,
              onPressed: () {
                setState(() => _autoFollow = true);
                _lastFollowed = null;
                if (myRider.lat != 0 || myRider.lng != 0) _mapController.move(LatLng(myRider.lat, myRider.lng), 16.0);
              },
              child: const Icon(Icons.my_location),
            ),
          ),

          // 5. SOS Panic Emergency Button
          Positioned(
            left: 14,
            bottom: 120,
            child: FloatingActionButton(
              heroTag: 'sos_btn',
              backgroundColor: AppTheme.laserRed,
              foregroundColor: Colors.white,
              onPressed: () => _triggerSos(context, convoyService, auth),
              child: const Icon(Icons.sos, size: 28),
            ),
          ),

          // 6. Voice Intercom Bottom Bar (group / private, PTT / VOX)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: IntercomDock(convoy: convoy, me: myRider, compact: true),
          ),
        ],
      ),
    );
  }
}
