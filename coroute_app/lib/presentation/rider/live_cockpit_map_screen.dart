import '../../data/services/ride_essentials_coordinator.dart';
import '../../data/services/route_essentials_service.dart';
import 'package:coroute_app/presentation/ride/essentials_sheet.dart';
import 'package:coroute_app/presentation/ride/fuel_sheet.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../core/config/app_config.dart';
import '../../core/constants/app_constants.dart';
import '../../core/constants/network_constants.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/map_tiles.dart';
import '../../core/ui/ui.dart';
import '../../core/widgets/cockpit_hud.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/network_models.dart';
import '../../data/models/network_wire.dart';
import '../../data/models/outbox_item.dart';
import '../../data/models/rider_model.dart';
import '../../data/models/safety_wire.dart';
import '../../data/models/route_model.dart';
import '../../data/models/stop_point_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/geo_service.dart';
import '../../data/services/realtime_service.dart';
import '../../data/services/safety_service.dart';
import '../../data/services/settings_service.dart';
import '../../data/services/tile_cache_service.dart';
import '../../data/services/timeline_service.dart';
import '../../data/services/weather_service.dart';
import '../../domain/notify/alert_policy.dart';
import '../../domain/notify/alert_priority.dart';
import '../../domain/ride/ride_facts.dart';
import '../../domain/route/route_plan.dart';
import '../../domain/route/route_progress.dart';
import '../../domain/safety/sun_helper.dart';
import '../../domain/tracking/geo_math.dart';
import '../alerts/alert_tiers.dart';
import '../alerts/alerts_screen.dart';
import '../map_picker/map_picker_screen.dart';
import '../ride/assist_banner.dart';
import '../ride/assist_sheet.dart';
import '../ride/discovery_card.dart';
import '../ride/emergency_guidance.dart';
import '../ride/group_settings_sheet.dart';
import '../ride/hazard_marker.dart';
import '../ride/incident_banner.dart';
import '../ride/incident_sheet.dart';
import '../ride/incident_view.dart';
import '../ride/map_focus.dart';
import '../ride/meet_here_sheet.dart';
import '../ride/messages_sheet.dart';
import '../ride/report_down_sheet.dart';
import '../ride/ride_sheet.dart';
import '../ride/rider_card_sheet.dart';
import '../ride/riders_ladder.dart';
import '../ride/route_guide.dart';
import '../safety/sos_hold_screen.dart';
import '../timeline/member_colors.dart';
import '../trip_planner/route_stops_panel.dart';
import '../widgets/connection_banner.dart';
import '../widgets/emergency_sos_sheet.dart';
import '../widgets/intercom_dock.dart';
import '../widgets/rider_status_sheet.dart';
import 'rider_home_screen.dart';

/// The active ride: the map first, a compact top bar (next stop or
/// destination, connection and GPS in words), one alert slot, the SOS
/// button (hold to send) and a draggable sheet. Collapsed, the sheet shows
/// four numbers while riding (remaining, ETA, riders moving, spread) or the
/// stop details while stopped, plus the talk row; dragged up it shows the
/// group ladder, trip progress, messages, settings, invite and End / Leave.
///
/// With [embedded] it is the Ride tab of the shell: no back button and it
/// never pops a route.
///
/// Only the part of the route still to ride is drawn (the line behind me
/// disappears as I ride), and remaining distance and ETA are measured along
/// it. When I leave the planned route a personal route is fetched quietly
/// ([RouteGuide]); one status line in the top bar says so. The lead can
/// long-press the map to set the group's meeting point. [focus] carries
/// "Show on map" requests from the Alerts tab.
class LiveCockpitMapScreen extends StatefulWidget {
  final String convoyId;
  final bool embedded;
  final MapFocus? focus;

  const LiveCockpitMapScreen({super.key, required this.convoyId, this.embedded = false, this.focus});

  /// Heading to draw for me: the compass while slow (GPS course is unreliable below 10 km/h).
  static double myHeading(RiderModel me, double? compass) => (me.speedKmh < 10.0 && compass != null) ? compass : me.heading;

  @override
  State<LiveCockpitMapScreen> createState() => _LiveCockpitMapScreenState();
}

/// One entry for the alert slot.
class _Slot {
  final String key;
  final AlertTier tier;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool dismissible;

  /// Runs instead of hiding the slot on this screen (a prompt answered "Later").
  final VoidCallback? onDismiss;

  /// Where it ranks (3.15): SOS, assistance request, hazard, group safety, route info, social.
  final AlertPriority priority;

  /// Within a priority: larger first (then the order added).
  final int order;

  /// A banner of its own (incident, assistance, hazard, discovery) instead of a [RideAlert].
  final Widget? child;

  _Slot({
    required this.key,
    required this.tier,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.dismissible = false,
    this.onDismiss,
    AlertPriority? priority,
    int? order,
    this.child,
  })  : priority = priority ?? (tier == AlertTier.normal ? AlertPriority.routeInfo : AlertPriority.groupSafety),
        order = order ?? (tier == AlertTier.critical ? 300 : (tier == AlertTier.important ? 200 : 100));
}

class _LiveCockpitMapScreenState extends State<LiveCockpitMapScreen> {
  final MapController _mapController = MapController();
  final GlobalKey<RideSheetState> _sheetKey = GlobalKey<RideSheetState>();
  final ValueNotifier<double> _sheetTop = ValueNotifier<double>(196);
  final AlertPolicy _policy = AlertPolicy();
  final Set<String> _dismissed = {};

  bool _autoFollow = true;
  bool _keepScreenOn = false;
  LatLng? _lastFollowed;
  String? _selectedRiderId;
  bool _sosNoticeScheduled = false;
  bool _leaveNoticeScheduled = false;

  // The planned route as map points, rebuilt only when the convoy's route changes.
  List<LatLng> _routePoints = const [];
  Object? _routeKey;
  Object? _breadcrumbKey;

  // Ride facts, recomputed only when the convoy changes.
  ConvoyModel? _snapConvoy;
  String? _snapUser;
  RideSnapshot? _snap;

  // Timeline alerts, recomputed when the timeline changes (or every 30 s for durations).
  Object? _alertsKey;
  int _alertsAt = 0;
  List<InAppAlert> _timelineAlerts = const [];

  // One-shot timers: a wait request expires; "last updated N min ago" moves on while offline.
  Timer? _waitTimer;
  int _waitTimerAt = 0;
  Timer? _staleTimer;

  // One-shot: hides "Another nearby rider is responding" and "X waved" when their time is up.
  Timer? _hideTimer;
  int _hideTimerAt = 0;

  // Auto-dismiss HUD alert banner timer on the map.
  Timer? _autoDismissTimer;
  String? _autoDismissKey;
  int? _autoDismissDurationSec;
  int _activeAlertCount = 0;

  // Route following: fed with my own fixes by the convoy listener (never by a timer).
  late final RouteGuide _localGuide = RouteGuide(fetchRoute: _fetchRoute);
  RideEssentialsCoordinator? _rideEssentials;
  RouteGuide get _guide => _rideEssentials?.guide ?? _localGuide;
  ConvoyService? _convoys;
  AuthService? _auth;
  GeoService? _geo;

  // The active line as map points, rebuilt only when the line is replaced or my matched point moves.
  RouteProgress? _lineSource;
  RouteEssentialsService? _essentials;

  Future<void> _syncEssentials({String? category, bool force = false}) async {
    if (!mounted) return;
    final shared = _rideEssentials;
    if (shared != null) {
      await shared.refresh(category: category, force: force);
      return;
    }
    final api = context.read<ApiClient?>();
    if (api == null) return;
    _essentials ??= RouteEssentialsService(api)..addListener(_essentialsChanged);
    final s = _convoys;
    final active = _guide.active;
    await _essentials!.update(active?.last?.onLine == false ? null : _guide.activeRoute,
      fromM: active?.matched?.alongM ?? 0, online: s?.isOnline ?? false,
      lowData: s?.settings?.lowData ?? false, selectedCategory: category ?? _essentials!.category, force: force);
  }
  void _essentialsChanged() { if (mounted) setState(() {}); }
  void _openEssentials() {
    final e = _essentials, s = _convoys;
    if (e == null || s == null) return;
    final c = s.allConvoys[widget.convoyId];
    final me = c?.riders[s.myUserId];
    final leader = me?.role == 'LEAD';
    showEssentialsSheet(context, service: e, leader: leader, moving: (me?.speedKmh ?? 0) > 5,
      refresh: (category, force) => _syncEssentials(category: category, force: force),
      addStop: (place) {
        if ((s.activeConvoy?.riders[s.myUserId]?.speedKmh ?? 0) > 5 || !s.isOnline) return false;
        final picked = PickedPlace(name: place.name, lat: place.lat, lng: place.lng, category: place.category);
        final ok = leader ? s.addStop(picked) : s.suggestStop(picked);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'Stop request sent. Waiting for the group plan to update.' : 'Could not send. Reconnect and try again.')));
        return ok;
      });
  }

  int _lineVersion = -1;
  List<LatLng> _lineFull = const [];
  RouteMatch? _trimKey;
  List<LatLng> _lineTrimmed = const [];

  Future<void> _loadDismissed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final saved = prefs.getStringList('coroute_dismissed_alerts_${widget.convoyId}');
      if (saved != null && saved.isNotEmpty) {
        setState(() => _dismissed.addAll(saved));
      }
    } catch (_) {}
  }

  void _dismissAlert(String key) {
    if (!mounted) return;
    if (_autoDismissKey == key) {
      _autoDismissTimer?.cancel();
      _autoDismissTimer = null;
      _autoDismissKey = null;
      _autoDismissDurationSec = null;
    }
    setState(() => _dismissed.add(key));
    SharedPreferences.getInstance().then((prefs) {
      prefs.setStringList('coroute_dismissed_alerts_${widget.convoyId}', _dismissed.toList()).ignore();
    }).ignore();
  }

  void _scheduleAutoDismiss(String key, int seconds, {required bool dismissible}) {
    if (seconds <= 0 || !dismissible || key == 'MY_SOS') {
      _autoDismissTimer?.cancel();
      _autoDismissTimer = null;
      _autoDismissKey = key;
      _autoDismissDurationSec = seconds;
      return;
    }
    if (_autoDismissKey == key && _autoDismissDurationSec == seconds && _autoDismissTimer != null) return;
    _autoDismissTimer?.cancel();
    _autoDismissKey = key;
    _autoDismissDurationSec = seconds;
    _autoDismissTimer = Timer(Duration(seconds: seconds), () {
      _autoDismissTimer = null;
      _autoDismissKey = null;
      _autoDismissDurationSec = null;
      _dismissAlert(key);
    });
  }

  void _cancelAutoDismiss() {
    _autoDismissTimer?.cancel();
    _autoDismissTimer = null;
    _autoDismissKey = null;
    _autoDismissDurationSec = null;
  }

  @override
  void initState() {
    super.initState();
    _loadDismissed();

    widget.focus?.addListener(_onFocusRequest);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _rideEssentials = context.read<RideEssentialsCoordinator?>();
      if (_rideEssentials != null) {
        _essentials = _rideEssentials!.essentials;
        _rideEssentials!.addListener(_essentialsChanged);
      } else {
        _localGuide.addListener(_onGuide);
      }
      _auth = context.read<AuthService>();
      final s = context.read<ConvoyService>();
      _convoys = s;
      s.addListener(_onConvoyUpdate);
      _onConvoyUpdate();
      _onFocusRequest();
    });
  }

  @override
  void didUpdateWidget(covariant LiveCockpitMapScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.focus, widget.focus)) {
      oldWidget.focus?.removeListener(_onFocusRequest);
      widget.focus?.addListener(_onFocusRequest);
    }
    if (oldWidget.convoyId != widget.convoyId) {
      _dismissed.clear();
      _loadDismissed();
    }
  }

  /// The route status or the active line changed (a new route arrived, or I
  /// am back on the plan). Called from a convoy update or a finished route
  /// request, never while building.
  void _onGuide() {
    if (mounted) _syncEssentials();
    if (mounted) setState(() {});
  }

  GeoService _geoService() => _geo ??= GeoService(context.read<ApiClient>());

  Future<RouteModel?> _fetchRoute(List<(double, double)> waypoints) async {
    if (!mounted) return null;
    return _geoService().route(waypoints);
  }

  /// Every convoy change: keep the guide on the current plan and give it my
  /// newest fix. Only while the app is on screen: in the background nothing
  /// is matched or fetched (the ongoing notification works as before).
  void _onConvoyUpdate() {
    final s = _convoys;
    if (s == null || !mounted) return;
    final convoy = s.allConvoys[widget.convoyId];
    final uid = _auth?.currentUserId ?? s.myUserId ?? '';
    if (convoy == null || uid.isEmpty) return;
    if (_rideEssentials != null) return;
    _guide.setConvoy(convoy, uid);
    if (!s.isRealGpsActive) return;
    final life = WidgetsBinding.instance.lifecycleState;
    if (life != null && life != AppLifecycleState.resumed) return;
    final me = convoy.riders[uid];
    if (me == null || !RideFacts.hasPosition(me)) return;
    _guide.onFix(
      lat: me.lat,
      lng: me.lng,
      speedKmh: me.speedKmh,
      accuracyM: s.myFixAccuracyM,
      nowMs: DateTime.now().millisecondsSinceEpoch,
      online: s.isOnline,
      lowData: s.settings?.lowData ?? false,
    );
    _syncEssentials();
  }

  /// "Show on map" from the Alerts tab: centre on the rider and open their card.
  void _onFocusRequest() {
    final req = widget.focus?.take();
    if (req == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final r = context.read<ConvoyService>().allConvoys[widget.convoyId]?.riders[req.userId];
      if (r == null) return;
      if (RideFacts.hasPosition(r)) _focus(r.lat, r.lng);
      _openRider(r);
    });
  }

  /// The part of the active line still to ride, as map points. Before I
  /// first reach the planned route (riding to the start) the whole line.
  List<LatLng> _activeLine(List<LatLng> planPoints) {
    final active = _guide.active;
    if (active == null || !active.isUsable) return planPoints;
    if (!identical(active, _lineSource) || _lineVersion != _guide.routeVersion) {
      _lineSource = active;
      _lineVersion = _guide.routeVersion;
      _lineFull = [for (final (lat, lng) in active.points) LatLng(lat, lng)];
      _trimKey = null;
    }
    final m = _guide.started ? active.matched : null;
    if (m == null) return _lineFull;
    if (!identical(m, _trimKey)) {
      _trimKey = m;
      final from = m.index + 1;
      _lineTrimmed = [LatLng(m.lat, m.lng), if (from < _lineFull.length) ..._lineFull.sublist(from)];
    }
    return _lineTrimmed;
  }

  List<LatLng> _routeFor(ConvoyModel convoy) {
    if (!identical(convoy.route, _routeKey) || !identical(convoy.routeBreadcrumbs, _breadcrumbKey)) {
      _routeKey = convoy.route;
      _breadcrumbKey = convoy.routeBreadcrumbs;
      _routePoints = [for (final (lat, lng) in convoy.routeLine) LatLng(lat, lng)];
    }
    return _routePoints;
  }

  RideSnapshot _snapshotFor(ConvoyModel convoy, String uid) {
    final cached = _snap;
    if (cached != null && identical(convoy, _snapConvoy) && uid == _snapUser) return cached;
    _snapConvoy = convoy;
    _snapUser = uid;
    return _snap = RideFacts.snapshot(convoy, uid);
  }

  List<InAppAlert> _alertsFor(TimelineService? timeline, ConvoyModel convoy, String uid, int nowMs) {
    if (timeline == null || timeline.groupId != convoy.groupId) return const [];
    final viewer = alertViewerFor(convoy, uid);
    if (viewer == null) return const [];
    final events = timeline.events;
    if (identical(events, _alertsKey) && nowMs - _alertsAt < 30000) return _timelineAlerts;
    _alertsKey = events;
    _alertsAt = nowMs;
    return _timelineAlerts = inAppAlerts(events, viewer, nowMs: nowMs, policy: _policy);
  }

  @override
  void dispose() {
    _convoys?.removeListener(_onConvoyUpdate);
    widget.focus?.removeListener(_onFocusRequest);
    _rideEssentials?.removeListener(_essentialsChanged);
    if (_rideEssentials == null) {
      _localGuide.removeListener(_onGuide);
      _localGuide.dispose();
      _essentials?.removeListener(_essentialsChanged);
      _essentials?.dispose();
    }
    _waitTimer?.cancel();
    _staleTimer?.cancel();
    _hideTimer?.cancel();
    _autoDismissTimer?.cancel();
    _sheetTop.dispose();
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

  // ---------------------------------------------------------------- actions

  /// The SOS from the ride notification: the hold screen (also over the lock
  /// screen); nothing is sent unless the rider holds SOS there.
  Future<void> _openSosHold(ConvoyService service, AuthService auth) async {
    final send = await SosHoldScreen.show(context);
    if (!send || !mounted) return;
    await _triggerSos(service, auth);
  }

  /// The one SOS path: my position (or a 5 s GPS fallback when I have none),
  /// type CRASH_OR_EMERGENCY, kept on the phone and re-sent after a dead zone
  /// by ConvoyService, then the SOS sheet with the delivery state.
  Future<void> _triggerSos(ConvoyService service, AuthService auth) async {
    final uid = auth.currentUserId ?? service.myUserId ?? '';
    final me = service.activeConvoy?.riders[uid];
    var lat = me?.lat ?? 0.0;
    var lng = me?.lng ?? 0.0;
    if (lat == 0.0 && lng == 0.0) {
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 5)),
        );
        lat = pos.latitude;
        lng = pos.longitude;
      } catch (_) {}
    }
    service.triggerSosAlert(
      userId: me?.userId ?? uid,
      userName: auth.currentUserName ?? me?.name ?? 'Rider',
      lat: lat,
      lng: lng,
      type: 'CRASH_OR_EMERGENCY',
    );
    if (mounted) EmergencySosSheet.show(context, lat: lat, lng: lng);
  }

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

  /// Long-press on the map. The lead gets "Meet here" (or add a stop there);
  /// anyone else suggests a stop, as before. Every rider also gets "Report a
  /// rider down here" (3.16), which sends the existing rider-down report.
  Future<void> _onLongPress(ConvoyService service, LatLng point) async {
    final convoy = service.allConvoys[widget.convoyId];
    if (convoy == null) return;
    final lead = service.canEditRoute;
    final uid = _auth?.currentUserId ?? service.myUserId ?? '';
    final me = convoy.riders[uid];
    final lat = point.latitude, lng = point.longitude;
    final distance = (me != null && RideFacts.hasPosition(me)) ? GeoMath.haversine(me.lat, me.lng, lat, lng) : null;
    final placement = lead
        ? RoutePlan.meetingPlacement(
            convoy,
            lat: lat,
            lng: lng,
            plan: _guide.plan,
            fromAlongM: _guide.started ? _guide.plan?.matched?.alongM : null,
          )
        : null;
    final old = placement?.replaces;
    final res = await showMeetHereSheet(
      context,
      placeName: () => _geoService().reverse(lat, lng),
      distanceFromMeM: distance,
      replacesName: old?.name,
      lead: lead,
      canReport: service.supports(ProtocolFeatures.safetyNet),
    );
    if (res == null || !mounted) return;
    if (res.action == MeetHereAction.addStop) {
      await _addStopAt(context, service, point);
      return;
    }
    if (res.action == MeetHereAction.reportDown) {
      await _reportDownAt(service, lat, lng, res.name);
      return;
    }
    if (placement == null) return;
    final ok = service.addMeetingPoint(
      PickedPlace(lat: lat, lng: lng, name: res.name.isEmpty ? StopKind.meeting.label : res.name, category: RoutePlan.meetingCategory),
      insertBefore: placement.insertBefore,
      replaceStopId: old?.stopId,
    );
    if (ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Meeting point set. Your group gets an alert.')));
    }
  }

  /// "Report a rider down here" (3.16): the report sheet, then the existing
  /// REPORT_DOWN message. Needs a gateway with the safety network.
  Future<void> _reportDownAt(ConvoyService service, double lat, double lng, String placeName) async {
    if (!service.supports(ProtocolFeatures.safetyNet)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.t('report.unavailable'))));
      return;
    }
    final sent = await showReportDownSheet(context, lat: lat, lng: lng, placeName: placeName);
    if (sent == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(sent ? L10n.t('report.sent') : 'Could not send the report. Try again.'),
    ));
  }

  /// "Leave ride" from the ride notification (3.16, item 3): the notification
  /// only asks; the rider confirms here, like the Leave button in the sheet.
  Future<void> _leaveFromNotification(ConvoyService service, String uid) =>
      leaveFromNotification(context, service, uid, embedded: widget.embedded);

  /// "Share my ETA": plain text through the phone's share sheet. No link and no coordinates.
  void _shareEta(ConvoyModel convoy, double? remainingM, Duration? eta) {
    final text = RideFacts.shareEtaText(
      destinationName: convoy.destinationName,
      remainingM: remainingM,
      arrival: eta == null ? null : _eta(eta),
    );
    SharePlus.instance.share(ShareParams(text: text));
  }

  void _focus(double lat, double lng) {
    if (lat == 0 && lng == 0) return;
    setState(() => _autoFollow = false);
    _sheetKey.currentState?.collapse();
    try {
      _mapController.move(LatLng(lat, lng), 16.5);
    } catch (_) {}
  }

  void _openRider(RiderModel r) {
    setState(() => _selectedRiderId = r.userId);
    showRiderCard(
      context,
      convoyId: widget.convoyId,
      userId: r.userId,
      onShowOnMap: (rider) => _focus(rider.lat, rider.lng),
    );
  }

  void _shareInvite(ConvoyModel convoy) {
    final link = '${AppConfig.apiBaseUrl}/join/${convoy.joinCode}';
    SharePlus.instance.share(ShareParams(
      text: 'Join my CoRoute ride "${convoy.name}". Code ${convoy.joinCode}. Tap to open: $link',
      subject: 'CoRoute ride: ${convoy.name}',
    ));
  }

  void _copyCode(ConvoyModel convoy) {
    Clipboard.setData(ClipboardData(text: convoy.joinCode));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Code ${convoy.joinCode} copied')));
  }

  Future<void> _endRide(ConvoyService service) async {
    final ok = await confirmAction(
      context,
      title: 'End ride?',
      message: 'Live location sharing for the whole group will stop and the ride is saved.',
      confirmLabel: 'End Ride',
      destructive: true,
    );
    if (!ok || !mounted) return;
    // The end is a message to the server; without signal it would be dropped silently and the
    // ride (and location sharing) would go on while the lead thinks it ended.
    if (!service.isOnline) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No signal, so the ride was not ended. Try again when you are back online.')),
      );
      return;
    }
    // ConvoyService saves the trip when the server confirms the end (_onTripEnded); no second save here.
    service.updateTripState('ENDED');
    if (!widget.embedded) Navigator.of(context).maybePop();
  }

  Future<void> _leaveRide(ConvoyService service, String uid) async {
    final ok = await confirmAction(
      context,
      title: 'Leave ride?',
      message: 'Your live location sharing with this group will stop. Your ride so far is kept in your trips.',
      confirmLabel: 'Leave Ride',
      destructive: true,
    );
    if (!ok || !mounted) return;
    service.leaveActiveConvoy(uid);
    if (!widget.embedded) Navigator.of(context).maybePop();
  }

  /// Keeps my marker in view while auto-follow is on. Moves only when I moved
  /// more than 15 m (no constant redraws, which would cost battery).
  void _follow(RiderModel me) {
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

  /// Where to open the map: my position, else another rider's, else the trip start.
  LatLng _initialCenter(RiderModel me, ConvoyModel convoy) {
    if (me.lat != 0 || me.lng != 0) return LatLng(me.lat, me.lng);
    for (final r in convoy.riders.values) {
      if (r.lat != 0 || r.lng != 0) return LatLng(r.lat, r.lng);
    }
    if (convoy.startLat != null && convoy.startLng != null) return LatLng(convoy.startLat!, convoy.startLng!);
    return const LatLng(AppConstants.defaultMapLat, AppConstants.defaultMapLng); // centre of India
  }

  void _armWaitTimer(int expiresAtMs, int nowMs) {
    if (_waitTimerAt == expiresAtMs && _waitTimer != null) return;
    _waitTimer?.cancel();
    _waitTimerAt = expiresAtMs;
    _waitTimer = Timer(Duration(milliseconds: (expiresAtMs - nowMs).clamp(0, 120000).toInt() + 500), () {
      _waitTimer = null;
      if (mounted) setState(() {});
    });
  }

  void _armStaleTimer() {
    _staleTimer ??= Timer(const Duration(minutes: 1), () {
      _staleTimer = null;
      if (mounted) setState(() {});
    });
  }

  /// "I'm OK" for an automatic check about me: closes it for the group.
  void _imOk(ConvoyService service) {
    final ok = service.sendCheckIn(CheckInResult.ok);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? 'Your group knows you are OK.' : 'Could not tell the group right now. Riding on also closes this alert.'),
    ));
  }

  void _openIncident(IncidentView i) {
    if (i.hasPosition) _focus(i.lat, i.lng);
    showIncidentSheet(context, convoyId: widget.convoyId, subjectUserId: i.subjectUserId, alertId: i.alertId);
  }

  void _openAssist(AssistRequest a) {
    _focus(a.lat, a.lng);
    showAssistSheet(context, incidentId: a.incidentId);
  }

  /// Rebuilds once when the earliest short notice ([NetworkConstants.assistTakenShowFor],
  /// [NetworkConstants.waveShowFor]) should go. One-shot; nothing while idle.
  void _armHideTimer(int atMs, int nowMs) {
    if (_hideTimer != null && _hideTimerAt <= atMs && _hideTimerAt > nowMs) return;
    _hideTimer?.cancel();
    _hideTimerAt = atMs;
    _hideTimer = Timer(Duration(milliseconds: (atMs - nowMs).clamp(0, 600000).toInt() + 300), () {
      _hideTimer = null;
      _hideTimerAt = 0;
      if (mounted) setState(() {});
    });
  }

  // ------------------------------------------------------------- alert slot

  List<_Slot> _slots({
    required ConvoyModel convoy,
    required ConvoyService service,
    required RiderModel me,
    required String uid,
    required List<InAppAlert> timelineAlerts,
    required List<IncidentView> incidents,
    required List<SafetyPrompt> prompts,
    required int nowMs,
    EmergencyGuidance? guidance,
  }) {
    final out = <_Slot>[];
    final incidentKeys = {for (final i in incidents) i.key};
    final mySos = convoy.activeAlerts.where((a) => !a.resolved && a.userId == uid).toList();
    final waiting = service.pendingSos != null;
    if (mySos.isNotEmpty || waiting) {
      final delivered = mySos.isNotEmpty && !waiting;
      out.add(_Slot(
        key: 'MY_SOS',
        tier: AlertTier.critical,
        title: delivered ? 'Your SOS is on' : (service.isOnline ? 'Sending your SOS' : 'SOS waiting to send'),
        message: delivered ? 'Your group can see where you are.' : 'It is kept on the phone and sent as soon as there is signal.',
        actionLabel: 'View SOS',
        onAction: () => EmergencySosSheet.show(context, lat: me.lat, lng: me.lng),
        priority: AlertPriority.sos,
        order: 1000,
      ));
    }
    // Someone else's emergency in my group: the big incident banner (SOS and crash first).
    final myPos = RideFacts.hasPosition(me);
    for (final i in incidents.where((x) => !x.isMe)) {
      out.add(_Slot(
        key: i.key,
        tier: AlertTier.critical,
        title: i.title,
        priority: i.isAlert ? AlertPriority.sos : AlertPriority.groupSafety,
        order: 900,
        child: IncidentBanner(
          incident: i,
          myLat: myPos ? me.lat : null,
          myLng: myPos ? me.lng : null,
          nowMs: nowMs,
          route: convoy.routeLine,
          phone: convoy.riders[i.subjectUserId]?.phone ?? '',
          onOpen: () => _openIncident(i),
        ),
      ));
    }
    // Assistance requests from other groups (mine first). After "Can't assist" only the Alerts tab keeps it.
    final assists = <AssistRequest>[];
    final active = service.activeAssist;
    if (active != null) assists.add(active);
    for (final a in service.assistRequests) {
      if (active != null && a.incidentId == active.incidentId) continue;
      if (a.myStatus == ResponderStatus.declined || assistStageOf(a) == AssistStage.closed) continue;
      assists.add(a);
    }
    for (var k = 0; k < assists.length; k++) {
      final a = assists[k];
      out.add(_Slot(
        key: 'ASSIST:${a.incidentId}',
        tier: AlertTier.critical,
        title: AssistTexts.requestTitle,
        priority: AlertPriority.assistRequest,
        order: 900 - k,
        child: AssistBanner(
          request: a,
          myLat: myPos ? me.lat : null,
          myLng: myPos ? me.lng : null,
          route: convoy.routeLine,
          nowMs: nowMs,
          onOpen: () => _openAssist(a),
        ),
      ));
    }
    // Accidents reported ahead (amber, never red).
    final views = <String, HazardView>{for (final v in guidance?.hazards ?? const <HazardView>[]) v.hazard.hazardId: v};
    for (final h in service.hazards) {
      if (guidance != null && !views.containsKey(h.hazardId)) continue; // passed
      final key = 'HAZARD:${h.hazardId}';
      out.add(_Slot(
        key: key,
        tier: AlertTier.important,
        title: L10n.t('hazard.title').toUpperCase(),
        priority: AlertPriority.hazard,
        dismissible: true,
        child: HazardBanner(
          hazard: h,
          view: views[h.hazardId],
          onTap: () => _focus(h.lat, h.lng),
          onDismiss: () => _dismissAlert(key),
        ),
      ));
    }
    // "Another nearby rider is responding": neutral, hides by itself.
    for (final n in service.assistNotices) {
      if (n.reason != AssistClosedReason.taken) continue;
      final until = n.at + NetworkConstants.assistTakenShowFor.inMilliseconds;
      if (nowMs >= until) continue;
      _armHideTimer(until, nowMs);
      out.add(_Slot(
        key: 'ASSIST_TAKEN:${n.incidentId}',
        tier: AlertTier.normal,
        title: AssistTexts.takenTitle,
        message: AssistTexts.takenBody,
        priority: AlertPriority.routeInfo,
        dismissible: true,
      ));
    }
    // About me: the group was asked to check on me (or my lead heard no reply): one tap says I'm OK.
    for (final i in incidents.where((x) => x.isMe && !x.isAlert)) {
      out.add(_Slot(
        key: i.key,
        tier: AlertTier.important,
        title: i.title,
        message: "Automatic check. Tap I'm OK if you are fine.",
        actionLabel: "I'm OK",
        onAction: () => _imOk(service),
      ));
    }
    // Ride safety prompts on this phone only ("Are you OK?", "Time for a break").
    for (final p in prompts) {
      final second = p.secondaryLabel;
      out.add(_Slot(
        key: p.key,
        tier: p.tier,
        title: p.title,
        message: p.message,
        actionLabel: p.primaryLabel,
        onAction: () => context.read<SafetyService>().answerPrompt(p.key),
        onDismiss: second == null ? null : () => context.read<SafetyService>().answerPrompt(p.key, primary: false),
      ));
    }
    final broadcast = service.systemBroadcastMessage;
    if (broadcast != null) {
      out.add(_Slot(key: 'BROADCAST', tier: AlertTier.critical, title: 'Safety message', message: broadcast));
    }
    // Alerts from the group timeline (same rules as the notifications). SOS is above already.
    for (final a in timelineAlerts) {
      if (a.key.startsWith('SOS:') || incidentKeys.contains(a.key)) continue;
      // The route status line already says it (and a new route is on the way).
      if (a.key == 'OFF_ROUTE:$uid' && _guide.handlesOffRoute) continue;
      if (!a.standing && a.tier == AlertTier.normal) continue;
      final r = a.userId == null ? null : convoy.riders[a.userId];
      final routeInfo = a.key.startsWith('OFF_ROUTE:') || a.key == AlertPolicy.meetingKey;
      out.add(_Slot(
        key: a.key,
        tier: a.tier,
        priority: routeInfo ? AlertPriority.routeInfo : null,
        title: a.spec.title,
        message: a.spec.body.isEmpty ? null : a.spec.body,
        actionLabel: (r != null && r.userId != uid) ? 'Show on map' : null,
        onAction: (r != null && r.userId != uid)
            ? () {
                _focus(r.lat, r.lng);
                _openRider(r);
              }
            : null,
        dismissible: a.tier != AlertTier.critical,
      ));
    }
    // "Wait for me": the newest request of the last 2 minutes, gone by itself after that.
    String? waitName;
    var waitAt = 0;
    convoy.waitRequests.forEach((name, at) {
      if (nowMs - at < 120000 && at > waitAt) {
        waitAt = at;
        waitName = name;
      }
    });
    final wn = waitName;
    if (wn != null) {
      _armWaitTimer(waitAt + 120000, nowMs);
      final mine = wn == me.name;
      out.add(_Slot(
        key: 'WAIT:$waitAt',
        tier: AlertTier.important,
        title: mine ? 'You asked the group to wait' : '$wn asked the group to wait',
        message: mine ? null : 'Pull over safely and wait for them.',
        dismissible: true,
      ));
    }
    final ok = service.sosOkNotice;
    if (ok != null) out.add(_Slot(key: 'SOS_OK', tier: AlertTier.normal, title: ok));
    if (convoy.riders.length <= 1) {
      out.add(_Slot(
        key: 'SHARE_CODE',
        tier: AlertTier.normal,
        title: 'Share code ${convoy.joinCode}',
        message: 'Your group joins with this code.',
        actionLabel: 'Share',
        onAction: () => _shareInvite(convoy),
        dismissible: true,
      ));
    }
    // Other public groups nearby (social): only when nothing safety related is open.
    final anyEmergency = out.any((s) => s.priority == AlertPriority.sos);
    final social = AlertArbiter.socialAllowed(
      anyEmergency: anyEmergency,
      anyAssist: service.assistRequests.isNotEmpty || service.activeAssist != null,
      anyHazard: service.hazards.isNotEmpty,
    );
    if (social) {
      for (final e in service.encounters) {
        final waved = e.theyWavedAt;
        if (waved != null) {
          final until = waved + NetworkConstants.waveShowFor.inMilliseconds;
          if (nowMs < until) {
            _armHideTimer(until, nowMs);
            out.add(_Slot(
              key: 'MEET:${e.encounterId}:WAVE:$waved',
              tier: AlertTier.normal,
              title: DiscoveryTexts.waved(e),
              priority: AlertPriority.social,
              order: 200,
              child: WavedLine(encounter: e),
            ));
          }
        }
        out.add(_Slot(
          key: 'MEET:${e.encounterId}',
          tier: AlertTier.normal,
          title: DiscoveryTexts.title(e),
          priority: AlertPriority.social,
          order: 100,
          child: DiscoveryCard(
            encounter: e,
            onView: () => showDiscoverySheet(context, e, onWave: () => service.wave(e.encounterId)),
            onWave: () => service.wave(e.encounterId),
            onIgnore: () => service.ignoreEncounter(e.encounterId),
          ),
        ));
      }
    }
    _activeAlertCount = out.length;
    final visible = out.where((s) => !_dismissed.contains(s.key)).toList();
    // Priority first (SOS, assistance, hazard, group safety, route, social), then
    // critical before important before normal; within that the order above (stable).
    return AlertArbiter.arrange<_Slot>(visible, (s) => s.priority, newest: (s) => s.order);
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final service = context.watch<ConvoyService>();
    final rtState = context.select<RealtimeService?, RealtimeState>((r) => r?.state ?? RealtimeState.connected);
    final timeline = context.watch<TimelineService?>();
    final guidance = context.watch<EmergencyGuidance?>();
    final lowData = context.select<SettingsService?, bool>((s) => s?.lowData ?? false);
    // This phone's ride safety prompts ("Are you OK?", "Time for a break").
    final prompts = safetyPromptsOf(context);
    // 3.16: the fuel reminder row, the weather line and the route map prefetch state.
    final fuelRangeKm = context.select<SettingsService?, int>((s) => s?.fuelRangeKm ?? 0);
    final riddenKm = context.select<SafetyService?, int>((s) => ((s?.riddenSinceFillM ?? 0) / 1000).round());
    final weatherLine = context.select<WeatherService?, String?>((w) {
      final last = w?.last;
      return (last != null && last.rain) ? last.line : null;
    });
    // Rebuilds only when the prefetch state changes (at most every 500 ms while it runs).
    context.select<TilePrefetcher?, (bool, int, int, String?)>((p) => (p?.running ?? false, p?.done ?? 0, p?.total ?? 0, p?.error));
    final prefetcher = context.read<TilePrefetcher?>();
    final convoy = service.allConvoys[widget.convoyId];

    if (convoy == null || convoy.tripStatus == 'ENDED') return _ended(context);

    final uid = auth.currentUserId ?? service.myUserId ?? '';
    final me = convoy.riders[uid] ??
        RiderModel(userId: uid.isEmpty ? '0' : uid, name: auth.currentUserName ?? 'Rider', lat: 0.0, lng: 0.0, lastSeenEpochMs: 0);
    final now = DateTime.now().millisecondsSinceEpoch;
    // Remaining distance and ETA along the part of the route still to ride, once I am on it.
    final guideLeft = RideFacts.hasDestination(convoy) ? _guide.remainingM : null;
    final baseSnap = _snapshotFor(convoy, uid);
    final snap = guideLeft == null ? baseSnap : baseSnap.withRemaining(guideLeft, _guide.eta);
    final routePoints = _activeLine(_routeFor(convoy));
    final colors = MemberColors.assign(convoy.riders.keys);
    final statuses = <String, RiderStatus>{
      for (final r in convoy.riders.values)
        r.userId: riderStatusOf(r, convoy,
            isMe: r.userId == uid,
            nowMs: now,
            online: rtState == RealtimeState.connected,
            gpsActive: service.isRealGpsActive,
            myAccuracyM: service.myFixAccuracyM),
    };
    final stoppedFor = RideFacts.stoppedFor(me, nowMs: now, thresholdSeconds: convoy.stopThresholdSeconds);
    final lead = service.canEditRoute;

    // "Leave ride" from the ride notification (3.16): never one tap; a confirm first.
    if (service.leaveRequestedFromNotification && !_leaveNoticeScheduled) {
      _leaveNoticeScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _leaveNoticeScheduled = false;
        if (!mounted) return;
        _leaveFromNotification(service, uid);
      });
    }

    // SOS from the ride notification: nothing was sent; the hold screen asks for the hold first.
    if (service.sosRequestedFromNotification && !_sosNoticeScheduled) {
      _sosNoticeScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _sosNoticeScheduled = false;
        if (!mounted) return;
        service.clearSosRequest();
        if (!SosHoldScreen.isOpen) _openSosHold(service, auth);
      });
    }

    _follow(me);

    // Connection and GPS in words, for the top bar.
    var newestOther = 0;
    for (final r in convoy.riders.values) {
      if (r.userId != uid && r.lastSeenEpochMs > newestOther) newestOther = r.lastSeenEpochMs;
    }
    final connection = ConnectionBanner.status(
      state: rtState,
      lastUpdateMs: newestOther,
      nowMs: now,
      serverUnreachable: service.serverUnreachable,
    );
    if (connection != null) {
      _armStaleTimer();
    }
    final gps = RideFacts.gpsState(
      active: service.isRealGpsActive,
      lastFixMs: me.lastSeenEpochMs,
      accuracyM: service.myFixAccuracyM,
      moving: me.speedKmh >= RideThresholds.movingSpeedKmh,
      nowMs: now,
    );

    // One top slot, by priority: my SOS, my group's emergency (the big incident banner), an
    // assistance request, an accident ahead, group safety, route info, then other groups nearby.
    final incidents = incidentsFor(convoy, timeline, uid, now);
    final slots = _slots(
      convoy: convoy,
      service: service,
      me: me,
      uid: uid,
      timelineAlerts: _alertsFor(timeline, convoy, uid, now),
      incidents: incidents,
      prompts: prompts,
      nowMs: now,
      guidance: guidance,
    );
    final topSlot = slots.isEmpty ? null : slots.first;
    final extra = slots.length - 1;
    final dismissSec = context.select<SettingsService?, int>((s) => s?.mapAlertDismissSeconds ?? 5);

    if (topSlot != null) {
      if (topSlot.key != _autoDismissKey || _autoDismissDurationSec != dismissSec) {
        _scheduleAutoDismiss(topSlot.key, dismissSec, dismissible: topSlot.dismissible || topSlot.key != 'MY_SOS');
      }
    } else if (_autoDismissKey != null) {
      _cancelAutoDismiss();
    }
    // Why other riders' positions are old, and who has a possible incident (ladder words and chip).
    final offlinePlaces = <String, String>{};
    final possible = <String>{};
    if (timeline != null && timeline.groupId == convoy.groupId) {
      for (final r in convoy.riders.values) {
        if (r.userId == uid) continue;
        final off = timeline.openFor(r.userId, 'OFFLINE');
        if (off != null && off.placeName.isNotEmpty) offlinePlaces[r.userId] = off.placeName;
      }
    }
    for (final i in incidents) {
      if (i.kind == IncidentKind.possibleIncident) possible.add(i.subjectUserId);
    }

    final speedLimit = convoy.speedLimitKmh;
    final showSpeed = speedLimit > 0 && me.speedKmh >= speedLimit - 10;

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      body: LayoutBuilder(builder: (context, box) {
        final h = box.maxHeight;
        final w = box.maxWidth;
        // Landscape (phone on its side, tablets): the sheet becomes a panel on the left so the
        // map stays visible beside it, and SOS and the map controls sit on the map, never under it.
        final side = w > h && w >= 560;
        final panelW = side ? (w * 0.45).clamp(320.0, 420.0).toDouble() : w;
        const sosRing = 56.0 + 12.0; // RideSosButton: 56 dp button plus its hold ring
        return Stack(
          children: [
            _map(convoy, service, me, uid, routePoints, colors, statuses, lowData, now, guidance: guidance, incidents: incidents),
            // Top: one compact bar, the alert slot, and my speed when near or over the group limit.
            Positioned(
              top: MediaQuery.paddingOf(context).top + Space.s8,
              left: side ? panelW + Space.s12 : Space.s12,
              right: Space.s12,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TopBar(
                    title: _topTitle(convoy, snap),
                    connection: connection,
                    gps: gps,
                    route: guidance?.statusLine ?? _guide.statusLine,
                    emergencyRoute: guidance?.statusLine != null,
                    onStopNavigation: guidance?.target == null ? null : guidance?.stop,
                    onBack: widget.embedded ? null : () => Navigator.of(context).maybePop(),
                    isTunnelCoasting: me.isTunnelCoasting,
                  ),
                  AnimatedSwitcher(
                    duration: Motion.screen,
                    switchInCurve: Motion.curve,
                    switchOutCurve: Motion.curve,
                    child: topSlot == null
                        ? const SizedBox.shrink()
                        : KeyedSubtree(
                            key: ValueKey<String>(topSlot.key),
                            child: Padding(
                              padding: const EdgeInsets.only(top: Space.s8),
                              child: topSlot.child ??
                                  RideAlert(
                                    tier: topSlot.tier,
                                    title: topSlot.title,
                                    message: topSlot.message,
                                    actionLabel: topSlot.actionLabel,
                                    onAction: topSlot.onAction,
                                    onDismiss: topSlot.onDismiss ??
                                        (topSlot.key != 'MY_SOS' ? () => _dismissAlert(topSlot.key) : null),
                                  ),
                            ),
                          ),
                  ),
                  if (extra > 0)
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          backgroundColor: AppTheme.slateCard,
                          foregroundColor: AppTheme.textPrimary,
                        ),
                        onPressed: () => RiderHomeScreen.selectTab(context, HomeTab.alerts),
                        child: Text('+$extra more', maxLines: 1),
                      ),
                    )
                  else if (topSlot == null && _activeAlertCount > 0)
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          backgroundColor: AppTheme.slateCard,
                          foregroundColor: AppTheme.textPrimary,
                        ),
                        onPressed: () => RiderHomeScreen.selectTab(context, HomeTab.alerts),
                        icon: const Icon(Icons.notifications_none_rounded, size: 18),
                        label: Text('$_activeAlertCount in notifications', maxLines: 1),
                      ),
                    ),
                  if (showSpeed) ...[
                    const SizedBox(height: Space.s8),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: CockpitHud(speedKmh: me.speedKmh, speedLimitKmh: speedLimit),
                    ),
                  ],
                ],
              ),
            ),
            // Map controls on the right, just above the sheet (landscape: above SOS on the map).
            ValueListenableBuilder<double>(
              valueListenable: _sheetTop,
              builder: (context, top, _) {
                final hide = !side && top > h * 0.5;
                return Positioned(
                  right: Space.s12,
                  bottom: side ? Space.s12 + sosRing + Space.s12 : top + Space.s12,
                  child: IgnorePointer(
                    ignoring: hide,
                    child: AnimatedOpacity(
                      opacity: hide ? 0 : 1,
                      duration: Motion.button,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          MapControl(
                            icon: _keepScreenOn ? Icons.light_mode_rounded : Icons.brightness_low_rounded,
                            tooltip: _keepScreenOn ? 'Screen stays on. Tap to allow sleep.' : 'Keep screen on while riding',
                            active: _keepScreenOn,
                            onPressed: _toggleKeepScreenOn,
                          ),
                          const SizedBox(height: Space.s12),
                          MapControl(
                            icon: Icons.my_location_rounded,
                            tooltip: 'Centre on me',
                            active: _autoFollow,
                            onPressed: () {
                              setState(() => _autoFollow = true);
                              _lastFollowed = null;
                              if (me.lat != 0 || me.lng != 0) _mapController.move(LatLng(me.lat, me.lng), 16.0);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: panelW,
              child: SafeArea(
                top: false,
                child: RideSheet(
                  key: _sheetKey,
                  onTopChanged: (v) => _sheetTop.value = v,
                  header: _sheetHeader(convoy, me, snap, stoppedFor, now),
                  body: _sheetBody(convoy, service, me, uid, snap, stoppedFor, colors, statuses, lead, now,
                      offlinePlaces: offlinePlaces,
                      possibleIncident: possible,
                      fuelRangeKm: fuelRangeKm,
                      riddenKm: riddenKm,
                      weatherLine: weatherLine,
                      prefetcher: prefetcher),
                ),
              ),
            ),
            // SOS is painted after the sheet so it is always visible: just above the collapsed
            // sheet, over the sheet when it is pulled up high, and on the map in landscape.
            ValueListenableBuilder<double>(
              valueListenable: _sheetTop,
              builder: (context, top, _) {
                if (side) {
                  return Positioned(
                    right: Space.s12,
                    bottom: Space.s12,
                    child: RideSosButton(onTriggered: () => _triggerSos(service, auth)),
                  );
                }
                final maxBottom = (h - 220).clamp(Space.s8, double.infinity).toDouble();
                final bottom = (top + Space.s8).clamp(Space.s8, maxBottom).toDouble();
                return Positioned(
                  left: Space.s12,
                  bottom: bottom,
                  child: RideSosButton(onTriggered: () => _triggerSos(service, auth)),
                );
              },
            ),
          ],
        );
      }),
    );
  }

  Widget _ended(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      body: SafeArea(
        child: EmptyState(
          icon: Icons.flag_rounded,
          title: 'Ride ended',
          message: 'The ride is saved in your trips.',
          primaryLabel: widget.embedded ? null : 'Back',
          onPrimary: widget.embedded ? null : () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }

  String _topTitle(ConvoyModel convoy, RideSnapshot snap) {
    final next = snap.nextStop;
    if (next != null) {
      final d = snap.nextStopM;
      final name = next.name.isEmpty ? StopKind.fromCategory(next.category).label : next.name;
      return d == null ? 'Next: $name' : 'Next: $name, ${formatDistanceRounded(d)}';
    }
    if (RideFacts.hasDestination(convoy)) {
      final name = convoy.destinationName.isEmpty ? 'destination' : convoy.destinationName;
      final d = snap.remainingM;
      return d == null ? 'To $name' : 'To $name, ${formatDistanceRounded(d)}';
    }
    return convoy.name;
  }

  String _eta(Duration? eta) {
    if (eta == null) return '-';
    final at = DateTime.now().add(eta);
    return MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(at),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
  }

  Widget _sheetHeader(ConvoyModel convoy, RiderModel me, RideSnapshot snap, Duration? stoppedFor, int now) {
    void toggle() => _sheetKey.currentState?.toggle();
    final next = snap.nextStop;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (stoppedFor != null)
          StoppedDetails(
            stoppedFor: stoppedFor,
            place: RideFacts.hasPosition(me) ? '${me.lat.toStringAsFixed(5)}, ${me.lng.toStringAsFixed(5)}' : '',
            nearby: RideFacts.nearbyCount(convoy, me.userId),
            nearbyRadiusM: RideFacts.nearbyRadiusM,
            nextM: next != null ? snap.nextStopM : snap.remainingM,
            nextLabel: next != null ? 'Next stop' : 'Destination',
            reason: riderReasonText(me),
            onTellWhy: () => RiderStatusSheet.show(context, userId: me.userId),
            onTap: toggle,
          )
        else
          RidingMetrics(
            remainingM: snap.remainingM,
            eta: _eta(snap.eta),
            riding: RideFacts.ridingCount(convoy.riders.values, nowMs: now),
            total: convoy.riders.length,
            spreadM: snap.spreadM,
            onTap: toggle,
          ),
        if (_essentials != null && convoy.activeAlerts.isEmpty)
          EssentialsRow(service: _essentials!, onTap: _openEssentials),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.s16, 0, Space.s16, Space.s12),
          child: IntercomDock(convoy: convoy, me: me, compact: true),
        ),
      ],
    );
  }

  List<Widget> _sheetBody(
    ConvoyModel convoy,
    ConvoyService service,
    RiderModel me,
    String uid,
    RideSnapshot snap,
    Duration? stoppedFor,
    Map<String, Color> colors,
    Map<String, RiderStatus> statuses,
    bool lead,
    int now, {
    Map<String, String> offlinePlaces = const {},
    Set<String> possibleIncident = const {},
    int fuelRangeKm = 0,
    int riddenKm = 0,
    String? weatherLine,
    TilePrefetcher? prefetcher,
  }) {
    final paused = convoy.tripStatus == 'PAUSED';
    final statusQueued = RiderStatusSheet.queuedStatus(service);
    final chatQueued = service.outbox.where((o) => o.type == 'CHAT' && o.groupId == convoy.groupId).length;
    final hasDest = RideFacts.hasDestination(convoy);
    // "Dark in 40 min" during the last hour of daylight (null after dark or without a position).
    final darkLine = RideFacts.hasPosition(me) ? DarkCheck.rideLine(now: DateTime.fromMillisecondsSinceEpoch(now), lat: me.lat, lng: me.lng) : null;
    final routeLine = convoy.routeLine;
    final pf = prefetcher;
    final canSaveMap = routeLine.length >= 2 && !(convoy.route?.approximate ?? true);
    return [
      Semantics(
        header: true,
        child: Text(convoy.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title),
      ),
      if (paused) Text('Paused by the lead', style: AppText.label.copyWith(color: StatusColors.warning)),
      if (weatherLine != null) SheetLine(icon: Icons.umbrella_rounded, text: weatherLine),
      if (darkLine != null) SheetLine(icon: Icons.nights_stay_rounded, text: darkLine),
      if (stoppedFor != null)
        RidingMetrics(
          remainingM: snap.remainingM,
          eta: _eta(snap.eta),
          riding: RideFacts.ridingCount(convoy.riders.values, nowMs: now),
          total: convoy.riders.length,
          spreadM: snap.spreadM,
        ),
      SheetSectionTitle('Riders (${convoy.riders.length})'),
      RidersLadder(
        rungs: snap.ladder,
        colors: colors,
        statuses: statuses,
        nowMs: now,
        onTap: _openRider,
        offlinePlaces: offlinePlaces,
        possibleIncident: possibleIncident,
      ),
      if (snap.stops.isNotEmpty || hasDest) ...[
        const SheetSectionTitle('Trip progress'),
        TripProgress(stops: [
          for (final (s, m) in snap.stops)
            TripProgressStop(name: s.name, kind: StopKind.fromCategory(s.category), done: s.isVisited, kmFromMe: m == null ? null : m / 1000),
          if (hasDest)
            TripProgressStop(
              name: convoy.destinationName.isEmpty ? 'Destination' : convoy.destinationName,
              kmFromMe: snap.remainingM == null ? null : snap.remainingM! / 1000,
            ),
        ]),
      ],
      const SizedBox(height: Space.s16),
      SheetRow(
        icon: Icons.route_rounded,
        title: 'Route and stops',
        subtitle: convoy.suggestedStops.isEmpty ? null : '${convoy.suggestedStops.length} suggested',
        onTap: () => _openStops(convoy),
      ),
      SheetRow(
        icon: Icons.chat_bubble_outline_rounded,
        title: 'Messages (${convoy.messages.length})',
        subtitle: chatQueued > 0
            ? (service.isOnline ? '$chatQueued sending' : '$chatQueued waiting for signal')
            : (convoy.messages.isEmpty ? null : convoy.messages.last.text),
        onTap: () => showMessagesSheet(context, convoyId: convoy.groupId, me: me),
      ),
      // 3.11 offered the stop reason at any time (set it before pulling in, clear it after
      // moving on); the stopped details only offer it while stopped.
      SheetRow(
        icon: Icons.pause_circle_outline_rounded,
        title: me.statusReason.isEmpty ? 'Tell the group why you stop' : 'Your stop reason',
        subtitle: statusQueued == null
            ? riderReasonText(me)
            : QueuedLine.textFor(
                failed: statusQueued.state == OutboxState.failed,
                sending: service.isOnline,
                what: riderReasonText(me).isEmpty ? null : riderReasonText(me),
              ),
        onTap: () => RiderStatusSheet.show(context, userId: me.userId),
      ),
      SheetRow(
        icon: Icons.local_gas_station_rounded,
        title: 'Fuel estimate / refuel',
        subtitle: 'Confirm a fill or update your fuel estimate while stopped',
        onTap: me.speedKmh > 5 ? null : () => showFuelSheet(context),
      ),
      if (pf != null && canSaveMap)
        SaveRouteMapRow(
          running: pf.running,
          done: pf.done,
          total: pf.total,
          error: pf.error,
          onSave: () => pf.start(routeLine, label: convoy.name),
        ),
      SheetRow(icon: Icons.tune_rounded, title: 'Group settings', onTap: () => showGroupSettings(context, convoyId: convoy.groupId)),
      SheetRow(icon: Icons.headset_mic_rounded, title: 'Intercom options', onTap: () => IntercomOptions.show(context)),
      if (hasDest)
        SheetRow(
          icon: Icons.share_rounded,
          title: 'Share my ETA',
          subtitle: _etaShareSubtitle(snap),
          onTap: () => _shareEta(convoy, snap.remainingM, snap.eta),
        ),
      SheetRow(
        icon: Icons.person_add_alt_rounded,
        title: 'Invite riders',
        subtitle: 'Code ${convoy.joinCode}',
        onTap: () => _shareInvite(convoy),
        trailing: IconButton(
          tooltip: 'Copy code',
          icon: Icon(Icons.copy_rounded, color: AppTheme.textSecondary),
          onPressed: () => _copyCode(convoy),
        ),
      ),
      if (lead)
        SheetRow(
          icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          title: paused ? 'Resume the ride' : 'Pause the ride',
          subtitle: paused ? 'The ride is paused' : null,
          onTap: () => service.updateTripState(paused ? 'STARTED' : 'PAUSED'),
          trailing: const SizedBox.shrink(),
        ),
      const SizedBox(height: Space.s24),
      if (lead) ...[
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: StatusColors.critical,
            foregroundColor: StatusColors.onCritical,
            minimumSize: const Size.fromHeight(56),
          ),
          onPressed: () => _endRide(service),
          icon: const Icon(Icons.flag_rounded),
          label: const Text('End ride'),
        ),
        const SizedBox(height: Space.s12),
      ],
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: StatusColors.critical,
          side: BorderSide(color: StatusColors.critical),
          minimumSize: const Size.fromHeight(56),
        ),
        onPressed: () => _leaveRide(service, uid),
        icon: const Icon(Icons.logout_rounded),
        label: const Text('Leave ride'),
      ),
    ];
  }

  /// "42 km left, about 4:35 PM" under "Share my ETA" (null when nothing is known yet).
  String? _etaShareSubtitle(RideSnapshot snap) {
    final left = snap.remainingM;
    final eta = snap.eta;
    final parts = <String>[
      if (left != null) '${formatDistanceRounded(left)} left',
      if (eta != null) 'about ${_eta(eta)}',
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }

  void _openStops(ConvoyModel convoy) {
    showAppSheet<void>(
      context,
      title: 'Route and stops',
      isScrollControlled: true,
      builder: (ctx) => Consumer<ConvoyService>(
        builder: (_, svc, _) => RouteStopsPanel(convoy: svc.allConvoys[convoy.groupId] ?? convoy),
      ),
    );
  }

  // -------------------------------------------------------------------- map

  Widget _map(
    ConvoyModel convoy,
    ConvoyService service,
    RiderModel me,
    String uid,
    List<LatLng> routePoints,
    Map<String, Color> colors,
    Map<String, RiderStatus> statuses,
    bool lowData,
    int now, {
    EmergencyGuidance? guidance,
    List<IncidentView> incidents = const [],
  }) {
    final navLine = [for (final (lat, lng) in guidance?.remainingLine ?? const <(double, double)>[]) LatLng(lat, lng)];
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _initialCenter(me, convoy),
        initialZoom: (me.lat != 0 || me.lng != 0) ? 15.5 : 12,
        onPositionChanged: (pos, hasGesture) {
          if (hasGesture && _autoFollow) setState(() => _autoFollow = false);
        },
        onTap: (_, _) {
          _sheetKey.currentState?.collapse();
          if (_selectedRiderId != null) setState(() => _selectedRiderId = null);
        },
        // Long-press anywhere: the lead sets a meeting point or adds a stop there, anyone else suggests a stop.
        onLongPress: (_, point) => _onLongPress(service, point),
      ),
      children: [
        // Tiles saved on the phone first (3.16 route map prefetch), then the network.
        // Data saver: no extra ring of tiles around the screen.
        appTileLayer(panBuffer: lowData ? 0 : 1),
        if (routePoints.length >= 2)
          PolylineLayer(polylines: [
            Polyline(
              points: routePoints,
              strokeWidth: 5,
              color: (!_guide.hasPersonalRoute && (convoy.route?.approximate ?? false))
                  ? AppTheme.neonCyan.withOpacity(0.45)
                  : AppTheme.neonCyan.withOpacity(0.75),
            ),
          ]),
        if (_essentials != null && convoy.activeAlerts.isEmpty)
          MarkerLayer(markers: [for (final p in _essentials!.upcoming.take(3)) Marker(
            point: LatLng(p.lat, p.lng), width: 40, height: 40,
            child: IconButton(tooltip: '${p.name}, mapped ${essentialCategories[p.category]}',
              onPressed: _openEssentials, icon: const Icon(Icons.local_offer_rounded), color: AppTheme.neonCyan),
          )]),
        // The way to an emergency I navigate to (red), above the group route.
        if (navLine.length >= 2)
          PolylineLayer(polylines: [
            Polyline(points: navLine, strokeWidth: 5, color: StatusColors.critical.withOpacity(0.85)),
          ]),
        MarkerLayer(markers: [
          for (final s in convoy.plannedStops) _stopMarker(s),
          for (final s in convoy.suggestedStops)
            Marker(
              point: LatLng(s.lat, s.lng),
              width: 32,
              height: 32,
              child: Semantics(
                label: 'Suggested stop, ${s.name}',
                child: Icon(Icons.add_location_rounded, color: StatusColors.warning, size: 28),
              ),
            ),
          if (RideFacts.hasDestination(convoy))
            Marker(
              point: LatLng(convoy.destinationLat, convoy.destinationLng),
              width: 40,
              height: 40,
              child: Semantics(
                label: 'Destination, ${convoy.destinationName}',
                child: Icon(Icons.sports_score_rounded, color: StatusColors.critical, size: 32),
              ),
            ),
        ]),
        MarkerLayer(markers: [
          for (final r in convoy.riders.values)
            if (RideFacts.hasPosition(r))
              Marker(
                point: LatLng(r.lat, r.lng),
                width: 132,
                height: 96,
                child: _RiderMarker(
                  rider: r,
                  isMe: isMeRider(r, uid),
                  color: colors[r.userId],
                  status: statuses[r.userId] ?? RiderStatus.offline,
                  selected: _selectedRiderId == r.userId,
                  nowMs: now,
                  onTap: () => _openRider(r),
                ),
              ),
        ]),
        MarkerLayer(markers: _safetyMarkers(convoy, service, me, now, guidance: guidance, incidents: incidents)),
      ],
    );
  }

  /// Small safety markers: accidents reported ahead (amber), the point of an
  /// emergency (red, the last known position, never dropped while open), and
  /// a nearby responder while on the way (green). Never other groups' riders.
  List<Marker> _safetyMarkers(
    ConvoyModel convoy,
    ConvoyService service,
    RiderModel me,
    int now, {
    EmergencyGuidance? guidance,
    List<IncidentView> incidents = const [],
  }) {
    final out = <Marker>[];
    final myPos = RideFacts.hasPosition(me);
    final views = guidance?.hazards;
    if (views != null) {
      for (final v in views) {
        out.add(Marker(
          point: LatLng(v.hazard.lat, v.hazard.lng),
          width: HazardMarker.width,
          height: HazardMarker.height,
          child: HazardMarker(label: v.label, level: v.hazard.level),
        ));
      }
    } else {
      for (final h in service.hazards) {
        final d = h.aheadM ?? (myPos ? GeoMath.haversine(me.lat, me.lng, h.lat, h.lng) : null);
        out.add(Marker(
          point: LatLng(h.lat, h.lng),
          width: HazardMarker.width,
          height: HazardMarker.height,
          child: HazardMarker(label: hazardMarkerLabel(d), level: h.level),
        ));
      }
    }
    // My group's open emergencies: the point where it is, unless the rider's own marker is already there.
    for (final i in incidents) {
      if (i.isMe || !i.isAlert || !i.hasPosition) continue;
      final r = convoy.riders[i.subjectUserId];
      final drawn = r != null && RideFacts.hasPosition(r) && GeoMath.haversine(r.lat, r.lng, i.lat, i.lng) < 30;
      if (!drawn) {
        final age = i.positionAt > 0 ? now - i.positionAt : 0;
        out.add(Marker(
          point: LatLng(i.lat, i.lng),
          width: EmergencyPointMarker.width,
          height: EmergencyPointMarker.height,
          child: EmergencyPointMarker(label: i.firstName, detail: age >= 60000 ? formatAgo(Duration(milliseconds: age)) : null),
        ));
      }
      final resp = i.network?.activeResponder;
      final rLat = resp?.lat, rLng = resp?.lng;
      if (resp != null && rLat != null && rLng != null && (rLat != 0 || rLng != 0) &&
          (resp.status == ResponderStatus.accepted || resp.status == ResponderStatus.enRoute || resp.status == ResponderStatus.arriving)) {
        out.add(Marker(
          point: LatLng(rLat, rLng),
          width: ResponderMarker.width,
          height: ResponderMarker.height,
          child: ResponderMarker(name: resp.name),
        ));
      }
    }
    // Assistance requests to me: only the emergency point, no names.
    final seen = <String>{};
    final active = service.activeAssist;
    for (final a in [?active, ...service.assistRequests]) {
      if (!seen.add(a.incidentId) || assistStageOf(a) == AssistStage.closed) continue;
      if (a.lat == 0 && a.lng == 0) continue;
      final d = myPos ? GeoMath.haversine(me.lat, me.lng, a.lat, a.lng) : a.distanceM;
      out.add(Marker(
        point: LatLng(a.lat, a.lng),
        width: EmergencyPointMarker.width,
        height: EmergencyPointMarker.height,
        child: EmergencyPointMarker(label: 'Rider emergency', detail: formatDistanceRounded(d)),
      ));
    }
    return out;
  }

  Marker _stopMarker(StopPointModel s) {
    final kind = StopKind.fromCategory(s.category);
    final Color ring = s.isVisited ? StatusColors.success : StatusColors.warning;
    return Marker(
      point: LatLng(s.lat, s.lng),
      width: 40,
      height: 40,
      child: Semantics(
        label: '${kind.label} stop, ${s.name}${s.isVisited ? ', visited' : ''}',
        excludeSemantics: true,
        child: Container(
          margin: const EdgeInsets.all(Space.s4),
          decoration: BoxDecoration(
            color: AppTheme.slateCard,
            shape: BoxShape.circle,
            border: Border.all(color: ring, width: 2),
          ),
          child: Icon(s.isVisited ? Icons.check_rounded : kind.icon, size: 18, color: s.isVisited ? ring : AppTheme.textPrimary),
        ),
      ),
    );
  }
}

/// The compact top bar: next stop or destination on one line; a second short
/// line only when the connection or the GPS needs a word.
class _TopBar extends StatelessWidget {
  final String title;
  final String? connection;
  final GpsState gps;
  final VoidCallback? onBack;

  /// The quiet route status ("New route, 42 km"), or the way to an emergency, or null.
  final String? route;

  /// [route] is the in-app navigation to an emergency (red icon, Stop button).
  final bool emergencyRoute;

  /// Stops the navigation to an emergency.
  final VoidCallback? onStopNavigation;

  /// Whether current rider is coasting through a tunnel without GPS fix.
  final bool isTunnelCoasting;

  const _TopBar({
    required this.title,
    required this.connection,
    required this.gps,
    this.onBack,
    this.route,
    this.emergencyRoute = false,
    this.onStopNavigation,
    this.isTunnelCoasting = false,
  });

  @override
  Widget build(BuildContext context) {
    final back = onBack;
    final stop = onStopNavigation;
    final c = connection;
    final words = <String>[
      ?c,
      if (gps != GpsState.accurate) 'GPS ${gps.label.toLowerCase()}',
    ];
    final warn = words.isNotEmpty;
    final r = route;
    return Material(
      color: AppTheme.slateCard,
      elevation: 2,
      shadowColor: AppTheme.shadow,
      shape: RoundedRectangleBorder(borderRadius: Radii.mdAll, side: BorderSide(color: AppTheme.subtleBorder)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(back == null ? Space.s12 : 0.0, Space.s4, Space.s12, Space.s4),
          child: Row(
            children: [
              if (back != null)
                IconButton(
                  tooltip: 'Back',
                  icon: Icon(Icons.arrow_back_rounded, color: AppTheme.textPrimary),
                  onPressed: back,
                ),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                    if (isTunnelCoasting)
                      Semantics(
                        liveRegion: true,
                        child: Row(
                          children: [
                            Icon(Icons.tune_rounded, size: 16, color: AppTheme.neonCyan),
                            const SizedBox(width: Space.s4),
                            Expanded(
                              child: Text(
                                'Tunnel Coasting (Dead-Reckoning)',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.caption.copyWith(color: AppTheme.neonCyan, fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        ),
                      )
                    else if (warn)
                      Semantics(
                        liveRegion: true,
                        child: Row(
                          children: [
                            Icon(c != null ? Icons.cloud_off_rounded : Icons.gps_not_fixed_rounded, size: 16, color: StatusColors.warning),
                            const SizedBox(width: Space.s4),
                            Expanded(
                              child: Text(words.join(', '), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppTheme.textSecondary)),
                            ),
                          ],
                        ),
                      ),
                    if (r != null)
                      Semantics(
                        liveRegion: true,
                        child: Row(
                          children: [
                            Icon(
                              emergencyRoute ? Icons.emergency_rounded : Icons.alt_route_rounded,
                              size: 16,
                              color: emergencyRoute ? StatusColors.critical : StatusColors.info,
                            ),
                            const SizedBox(width: Space.s4),
                            Expanded(
                              child: Text(r, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppTheme.textSecondary)),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              if (stop != null)
                IconButton(
                  tooltip: 'Stop navigation',
                  icon: Icon(Icons.close_rounded, color: AppTheme.textPrimary),
                  onPressed: stop,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A rider on the map: initials and a status dot, no animation. The name
/// shows only for the selected rider and for riders whose position is old
/// ("Kiran, 6 min ago"). Tapping it opens the rider card.
class _RiderMarker extends StatelessWidget {
  final RiderModel rider;
  final bool isMe;
  final Color? color;
  final RiderStatus status;
  final bool selected;
  final int nowMs;
  final VoidCallback onTap;

  const _RiderMarker({
    required this.rider,
    required this.isMe,
    required this.color,
    required this.status,
    required this.selected,
    required this.nowMs,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final first = rider.name.split(' ').first;
    final isTunnel = rider.isTunnelCoasting;
    final effectiveColor = isTunnel ? AppTheme.neonCyan : color;
    String? label;
    if (isTunnel) {
      label = isMe ? 'Tunnel Coasting' : '$first (Tunnel)';
    } else if (status.isStale && !isMe && rider.lastSeenEpochMs > 0) {
      label = '$first, ${formatAgo(Duration(milliseconds: nowMs - rider.lastSeenEpochMs))}';
    } else if (selected) {
      label = isMe ? 'You' : '$first, ${status.label}';
    }
    final l = label;
    final reason = rider.statusReason.isEmpty ? '' : RiderStatusSheet.getStatusLabel(rider.statusReason);
    return Semantics(
      container: true,
      button: true,
      label: '${riderSemanticsLabel(rider, isMe: isMe, statusLabel: reason)}, ${status.label}',
      excludeSemantics: true,
      onTap: onTap,
      child: Stack(
        alignment: Alignment.center,
        children: [
          RiderAvatar(name: rider.name, color: effectiveColor, status: status, size: isMe ? 44 : 40, onTap: onTap),
          if (l != null)
            Positioned(
              top: 72,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: Space.s4, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.slateCard,
                    borderRadius: Radii.smAll,
                    border: Border.all(color: AppTheme.subtleBorder),
                  ),
                  child: Text(l, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppTheme.textPrimary)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The ride's SOS button: hold for 1.5 s to send (a tap does nothing).
/// Screen readers hear "Send SOS to your convoy"; their long-press sends it.
class RideSosButton extends StatelessWidget {
  final VoidCallback onTriggered;
  const RideSosButton({super.key, required this.onTriggered});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      label: sosSemanticsLabel,
      hint: 'Press and hold to send',
      excludeSemantics: true,
      onLongPress: onTriggered,
      child: SOSButton(onTriggered: onTriggered, size: 56),
    );
  }
}

/// "Is this rider me?" by account id only (two riders may share a name).
bool isMeRider(RiderModel r, String myUserId) => myUserId.isNotEmpty && r.userId == myUserId;

/// What TalkBack reads for a rider marker.
String riderSemanticsLabel(RiderModel r, {required bool isMe, String statusLabel = ''}) {
  final who = isMe ? 'You' : r.name;
  final speed = '${r.speedKmh.round()} km per hour';
  return statusLabel.isEmpty ? '$who, $speed' : '$who, $speed, stopped: $statusLabel';
}
