import '../../data/services/ride_essentials_coordinator.dart';
import '../../data/services/route_essentials_service.dart';
import 'package:coroute_app/presentation/ride/essentials_sheet.dart';
import '../widgets/feature_switch.dart';
import 'package:coroute_app/presentation/ride/fuel_sheet.dart';
import 'package:coroute_app/presentation/ride/guardian_sheet.dart';
import 'package:coroute_app/presentation/ride/roll_call_card.dart';
import 'package:coroute_app/data/services/solo_guardian_service.dart';
import 'dart:async';
import '../ride/navigate_to.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../core/constants/navigation_constants.dart';
import '../../core/config/app_config.dart';
import '../../core/constants/app_constants.dart';
import '../../core/constants/network_constants.dart';
import '../../core/constants/safety_constants.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/map_tiles.dart';
import '../../core/ui/ui.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/route_essential.dart';

import '../../data/models/network_models.dart';
import '../../data/models/network_wire.dart';
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
import '../../data/services/sos_battery_reserve.dart';
import '../../data/services/settings_service.dart';
import '../../data/services/tile_cache_service.dart';
import '../../data/services/timeline_service.dart';
import '../../data/services/weather_service.dart';
import '../../domain/notify/alert_policy.dart';
import '../../domain/notify/alert_priority.dart';
import '../../domain/ride/ride_facts.dart';
import '../../domain/safety/effective_speed_limit.dart';
import '../../domain/route/route_plan.dart';
import '../../domain/route/route_progress.dart';
import '../../domain/safety/speed_limit_advisor.dart';
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
import '../ride/public_ride_widgets.dart';
import 'widgets/road_hazard_hud_pill.dart';
import 'widgets/siren_hud_pill.dart';
import 'widgets/ble_remote_hud_pill.dart';
import 'widgets/biometric_pulse_hud_pill.dart';
import 'widgets/smart_airbag_hud_pill.dart';

import '../../data/services/voice_service.dart';
import '../../data/services/helmet_voice_service.dart';
import '../../data/services/siren_acoustic_detector.dart';
import '../../data/services/ble_remote_service.dart';
import '../../data/services/biometric_safety_bridge.dart';
import '../../data/services/smart_airbag_bridge_service.dart';
import '../ride/incident_banner.dart';
import '../ride/incident_sheet.dart';
import '../ride/incident_view.dart';
import '../ride/map_focus.dart';
import '../../data/services/map_places_service.dart';
import '../map_places/map_places_layer.dart';
import '../map_places/place_review_prompt_banner.dart';
import '../../data/services/place_review_service.dart';
import '../../domain/places/place_dwell.dart';
import '../map_places/place_chips.dart';
import '../map_places/rider_stops_layer.dart';
import '../ride/meet_here_sheet.dart';
import '../ride/messages_sheet.dart';
import '../../domain/navigation/nav_handoff.dart';
import '../ride/report_down_sheet.dart';
import '../ride/ride_sheet.dart';
import '../ride/rider_card_sheet.dart';
import '../ride/riders_ladder.dart';
import '../ride/route_guide.dart';
import 'ride_advisories.dart'; // 3.55 heritage places on the way, off the group's route
import '../../domain/places/heritage_ahead.dart';
import '../../domain/route/off_route_group.dart';
import '../safety/sos_hold_screen.dart';
import 'package:flutter/gestures.dart' show GestureBinding, PointerDownEvent, PointerEvent;
import '../../core/theme/theme_controller.dart';
import '../../data/services/safety_native.dart';
import '../../domain/tracking/screen_awake_policy.dart';
import '../../domain/security/lock_screen_cockpit_policy.dart';
import '../../domain/route/next_turn.dart';
import '../../data/services/lock_screen_cockpit_service.dart';
import '../security/locked_cockpit_gate.dart';
import 'widgets/ride_aod_view.dart';
import '../timeline/member_colors.dart';
import '../trip/trip_feedback_sheet.dart';
import '../review/app_review_prompt.dart';
import '../engagement/ride_wrapup_sheet.dart'; // 3.55 after-ride wrap-up (trip + places)
import '../../data/services/engagement_service.dart';
import '../../data/local/ride_stats_store.dart';
import '../trip_planner/route_stops_panel.dart';
import '../widgets/connection_banner.dart';
import '../widgets/emergency_sos_sheet.dart';
import '../widgets/intercom_dock.dart';
import '../../data/services/intercom_service.dart';
import '../widgets/rider_status_sheet.dart';
import 'rider_home_screen.dart';
import 'widgets/cockpit_action_stack.dart';
import 'widgets/cockpit_hud_toast.dart';
import 'widgets/coroute_orbit_control.dart';
import 'widgets/glove_quick_settings_modal.dart';
import 'widgets/minimal_cockpit_overlay.dart';
import 'widgets/minimal_cockpit_settings_cards.dart';
import 'widgets/minimal_cockpit_stats_row.dart';
import 'widgets/minimal_hold_to_talk_bar.dart';
import 'widgets/ghost_rider_marker.dart';
import 'widgets/smooth_rider_marker_layer.dart';
import 'map/map_orientation_button.dart';
import 'map/nav_camera_controller.dart';
import '../../data/services/location_precision_service.dart';
import 'widgets/cockpit_dual_state_banner.dart';
import 'widgets/cockpit_permission_warning_banner.dart';
import 'widgets/rider_management_sheet.dart';
import '../widgets/sheet_coordinator.dart';
import '../diagnostics/pre_ride_phone_check_screen.dart';
import '../settings/settings_screen.dart';
import '../../data/services/group_safety_service.dart';
import '../ride/group_safety_cards.dart';
import '../ride/moving_card_chip.dart'; // 3.55 speak while moving, act when stopped
import '../map_places/after_ride_place_reviews.dart'; // 3.55 place review question after the ride
import '../../domain/ride/ride_tap_gate.dart';
import '../../domain/ride/bike_markers.dart'; // 3.55 bike markers, pillion on the bike
import 'widgets/bike_rider_marker.dart';
import '../ride/pillion_seat_sheet.dart'; // 3.55 pillion seat

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
  final bool isVisible;
  final RouteObserver<ModalRoute<void>>? routeObserver;

  const LiveCockpitMapScreen({
    super.key,
    required this.convoyId,
    this.embedded = false,
    this.focus,
    this.isVisible = true,
    this.routeObserver,
  });

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

class _LiveCockpitMapScreenState extends State<LiveCockpitMapScreen>
    with WidgetsBindingObserver, RouteAware {
  final MapController _mapController = MapController();

  /// Navigation camera (course-up / north-up follow, speed zoom, smooth motion between fixes).
  late final NavCameraController _navCam = NavCameraController(mapController: _mapController)
    ..addListener(_onNavCamChanged);

  // Free map area for the camera (refreshed by build; the sheet height comes from [_sheetRestTop]).
  bool _navSide = false;
  double _navPanelW = 0.0;
  double _navTopReserve = 0.0;
  bool _precisePromptShown = false;
  final GlobalKey<RideSheetState> _sheetKey = GlobalKey<RideSheetState>();
  final ValueNotifier<double> _sheetTop = ValueNotifier<double>(196);

  /// The sheet's top edge once at rest ([RideSheet.onTopSettled]): the map
  /// camera keeps the rider clear of it. Not [_sheetTop], which changes on
  /// every frame of a drag: moving the camera (and redrawing the map) on each
  /// of those frames made dragging the sheet stutter.
  double _sheetRestTop = 196;

  /// How far the ride sheet is open, 0 (collapsed) to 1 (fully expanded).
  /// Only the floating controls listen, so dragging the sheet never rebuilds
  /// the whole screen.
  final ValueNotifier<double> _sheetExpansion = ValueNotifier<double>(0);
  late final Listenable _sheetMotion = Listenable.merge(<Listenable>[_sheetTop, _sheetExpansion]);
  final AlertPolicy _policy = AlertPolicy();
  final Set<String> _dismissed = {};

  bool _autoFollow = true;
  bool _keepScreenOn = true;
  bool _isRouteObscured = false;
  bool _wakelockActive = false;

  // Always-on ride screen (Agent 4, [ScreenAwakePolicy]): the window dims after 30 s without a
  // touch; keep-on stops when parked over 5 min or below 15 % battery (the ride continues in
  // the foreground service). Battery saver also forces the dark ride theme / dark map.
  int _lastTouchMs = DateTime.now().millisecondsSinceEpoch;
  int _parkedSinceMs = 0;
  ScreenAwakeDecision? _awake;
  Timer? _awakeTimer;
  bool _dimmed = false;
  double? _brightness;

  // Cockpit on the lock screen + Ride AOD (docs/features_355/lock_screen_cockpit.md).
  LockScreenCockpitService? _lockCockpit;
  SettingsService? _settingsRef;
  Route<dynamic>? _reportedRoute;
  bool _aodOn = false;
  int _lastAlertMs = 0;
  String? _lastAlertKey;
  bool _pointerRouted = false;
  bool _rideDarkWanted = false;
  ThemeController? _theme;
  RouteObserver<ModalRoute<void>>? _subscribedObserver;
  ModalRoute<void>? _subscribedRoute;
  String? _selectedRiderId;

  /// 3.56 the way each bike faces: a standing rider's GPS course is noise, so below walking speed
  /// (or without a course) the 3D bike keeps its last heading.
  final HeadingHold _headingHold = HeadingHold();
  bool _sosNoticeScheduled = false;
  bool _leaveNoticeScheduled = false;

  String? _hudToastMessage;
  IconData? _hudToastIcon;
  Color? _hudToastColor;
  Timer? _hudToastTimer;

  void _showHudToast(String message, IconData icon, [Color? color]) {
    _hudToastTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _hudToastMessage = message;
      _hudToastIcon = icon;
      _hudToastColor = color;
    });
    _hudToastTimer = Timer(const Duration(milliseconds: 2400), () {
      if (mounted) {
        setState(() {
          _hudToastMessage = null;
          _hudToastIcon = null;
          _hudToastColor = null;
        });
      }
    });
  }

  /// Opacity of the floating map controls (zoom, recenter, fuel / action stack, Orbit):
  /// fully shown while the ride sheet is collapsed or barely moved, gone once it is about a
  /// third open, so they never sit over the sheet's content.
  static double _floatingOpacity(double expansion) => (1.0 - (expansion - 0.12) / 0.18).clamp(0.0, 1.0).toDouble();

  /// [value] kept between [lo] and [hi]; [lo] wins when the screen is too short for both
  /// (a plain `clamp` throws then).
  static double _clampSafe(double value, double lo, double hi) {
    if (hi < lo) return lo;
    return value < lo ? lo : (value > hi ? hi : value);
  }

  /// A floating control at [opacity]; it stops taking taps once mostly faded.
  static Widget _fade(double opacity, Widget child) => IgnorePointer(
        ignoring: opacity < 0.5,
        child: Opacity(opacity: opacity, child: child),
      );

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

  /// 3.55 taps while moving: re-checks [RideAdvisories.tapGate] when the rider should count as
  /// stopped (a parked phone may send no new fix).
  Timer? _tapGateTimer;
  int _hideTimerAt = 0;

  // Auto-dismiss HUD alert banner timer on the map.
  Timer? _autoDismissTimer;
  String? _autoDismissKey;
  int? _autoDismissDurationSec;
  int _activeAlertCount = 0;
  int _lastAutoMapPrepMs = 0;
  (double, double)? _lastPrepRiderPos;

  // Route following: fed with my own fixes by the convoy listener (never by a timer).
  late final RouteGuide _localGuide = RouteGuide(
    fetchRoute: _fetchRoute,
    reverseGeocode: (lat, lng) => _geoService().reverse(lat, lng),
  );
  RideEssentialsCoordinator? _rideEssentials;
  RouteGuide get _guide => _rideEssentials?.guide ?? _localGuide;
  ConvoyService? _convoys;
  AuthService? _auth;
  GeoService? _geo;
  SirenAcousticDetector? _sirenDetector;
  bool _ownsSirenDetector = false;
  BleRemoteService? _bleRemote;
  bool _ownsBleRemote = false;
  HelmetVoiceService? _helmetVoice;
  IntercomService? _intercomService;

  // The active line as map points, rebuilt only when the line is replaced or my matched point moves.
  RouteProgress? _lineSource;
  RouteEssentialsService? _essentials;

  // Map places (fuel, hospitals, mechanics, food...): one cache on the phone, shared with the planner.
  MapPlacesService? _places;
  // 3.55 road context: the line I follow and the cached road limits / zones, lent to SafetyService.
  SafetyService? _roadCareSafety;
  RouteProgress? _roadCareLine() => _guide.active;
  ({List<RoadLimitPoint> roads, List<SpeedZonePoint> zones}) _roadCareData() =>
      _places?.roadContext ?? (roads: const <RoadLimitPoint>[], zones: const <SpeedZonePoint>[]);

  // 3.55: "Historic place on your way" and "You left the group's route" (see ride_advisories.dart).
  final RideAdvisories _advice = RideAdvisories();
  MapPlacesService? _placesFor(bool lowData) {
    final api = context.read<ApiClient?>();
    if (api == null) return null;
    final places = _places ??= MapPlacesService.shared(api);
    places.lowData = lowData;
    final safety = context.read<SafetyService?>();
    if (safety != null) {
      safety.fuelAheadSource ??= (lat, lng, usableKm, marginKm) => places.fuelAhead(lat, lng, usableKm: usableKm, marginKm: marginKm);
      // 3.55: the places a dwell is measured against (no extra fetch).
      context.read<PlaceReviewService?>()?.placesSource ??= () => places.all;
      final type = safety.fuelEconomy.fuelType;
      if (places.fuelType != type) WidgetsBinding.instance.addPostFrameCallback((_) => places.fuelType = type);
    }
    return places;
  }

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
    final c = s?.allConvoys[widget.convoyId];
    final routeToUse = _guide.activeRoute ?? c?.route;
    await _essentials!.update(routeToUse,
      fromM: active?.matched?.alongM ?? 0, online: s?.isOnline ?? false,
      lowData: s?.settings?.lowData ?? false, selectedCategory: category ?? _essentials!.category, force: force);

    // If no route or corridor essentials are empty, fetch petrol bunks near current coordinates
    final me = c?.riders[s?.myUserId];
    if (me != null && me.lat != 0 && me.lng != 0 && (_essentials!.upcoming.isEmpty || routeToUse == null)) {
      await _essentials!.fetchNearbyFuel(lat: me.lat, lng: me.lng, force: force);
    }
  }
  void _essentialsChanged() { if (mounted) setState(() {}); }
  /// Every cockpit pop-up opens through here ([SheetCoordinator]): one at a
  /// time (an open one is closed first, never stacked) and the same button
  /// closes its own pop-up again. A tap outside or Back closes it (the
  /// pop-ups are barrier-dismissible); [protected] ones are never replaced.
  Future<T?> _popup<T>(Object key, Future<T?> Function() open, {bool protected = false}) =>
      SheetCoordinator.instance.present<T>(context, key: key, open: open, protected: protected);

  void _openEssentials() {
    final e = _essentials, s = _convoys;
    if (e == null || s == null) return;
    // 3.55 admin feature switch: stops on the way turned off for every rider.
    if (!context.featureOnNow('essentials')) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Stops on the way are turned off for now.')));
      return;
    }
    final c = s.allConvoys[widget.convoyId];
    final me = c?.riders[s.myUserId];
    final leader = me?.role == 'LEAD';
    _popup<void>('essentials', () => showEssentialsSheet(context, service: e, leader: leader, moving: (me?.speedKmh ?? 0) > 5,
      refresh: (category, force) => _syncEssentials(category: category, force: force),
      addStop: (place) {
        if ((s.activeConvoy?.riders[s.myUserId]?.speedKmh ?? 0) > 5 || !s.isOnline) return false;
        final picked = PickedPlace(name: place.name, lat: place.lat, lng: place.lng, category: place.category);
        final ok = leader ? s.addStop(picked) : s.suggestStop(picked);
        if (context.mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'Stop request sent. Waiting for the group plan to update.' : 'Could not send. Reconnect and try again.')));
        }
        return ok;
      }));
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

  RouteObserver<ModalRoute<void>> get _effectiveRouteObserver =>
      widget.routeObserver ?? appRouteObserver;

  void _subscribeRouteObserver() {
    final route = ModalRoute.of(context);
    final observer = _effectiveRouteObserver;
    if (route != _subscribedRoute || observer != _subscribedObserver) {
      _subscribedObserver?.unsubscribe(this);
      _subscribedRoute = route;
      _subscribedObserver = observer;
      if (route != null) {
        observer.subscribe(this, route);
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _subscribeRouteObserver();
    _syncWakelock();
    BikeSpriteCache.precache(context); // 3.56 the 3D bike images, decoded before the first marker
  }

  @override
  void didPushNext() {
    _isRouteObscured = true;
    _syncWakelock();
  }

  @override
  void didPopNext() {
    _isRouteObscured = false;
    _syncWakelock();
  }

  @override
  void didPop() {
    _isRouteObscured = true;
    _syncWakelock();
  }

  @override
  void didPush() {
    _isRouteObscured = false;
    _syncWakelock();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _syncWakelock();
    if (state == AppLifecycleState.resumed) _checkPreciseLocation();
  }

  @override
  void initState() {
    super.initState();
    _loadDismissed();
    RiderStopsLivePref.load().ignore(); // 3.56: the saved "Where riders stop" choice (off by default)
    WidgetsBinding.instance.addObserver(this);

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
      _guide.onFuelStopDone = _onFuelStopDone;
      _roadCareSafety = context.read<SafetyService?>();
      _roadCareSafety?.roadCare
        ?..activeLine = _roadCareLine
        ..roadData = _roadCareData;
      final s = context.read<ConvoyService>();
      _convoys = s;
      s.addListener(_onConvoyUpdate);
      // 3.55 ride chat: long texts are not spoken and typing is hidden while moving (same gate).
      s.rideMoving = _chatMoving;
      _onConvoyUpdate();
      try {
        _theme = Provider.of<ThemeController?>(context, listen: false);
      } catch (_) {
        _theme = null;
      }
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onAnyPointer);
      _pointerRouted = true;
      _settingsRef = context.read<SettingsService?>();
      _settingsRef?.addListener(_onScreenSettings);
      _lockCockpit = context.read<LockScreenCockpitService?>();
      _lockCockpit?.addListener(_onLockCockpit);
      _syncWakelock();
      _onFocusRequest();
      _syncEssentials(category: 'FUEL', force: true);
      _checkPreciseLocation();

      _intercomService = context.read<IntercomService?>();
      final existingDetector = context.read<SirenAcousticDetector?>();
      if (existingDetector != null) {
        _sirenDetector = existingDetector;
        _ownsSirenDetector = false;
      }
      // 3.55 platform: no private detector any more. Nothing feeds it audio (no PTT/VOX hook
      // calls processPcmChunk), so it was idle memory; the siren pill shows only when an app
      // level SirenAcousticDetector is provided with a real audio source.
      _sirenDetector?.activeSirenNotifier.addListener(_onSirenAlert);
      // FEAT-MIC-01: the microphone stays OFF by default; the siren detector is never fed
      // continuous background audio (capture only while the rider holds PTT or uses VOX).

      final existingRemote = context.read<BleRemoteService?>();
      if (existingRemote != null) {
        _bleRemote = existingRemote;
        _ownsBleRemote = false;
      } else {
        final intercom = context.read<IntercomService?>();
        final safety = context.read<SafetyService?>();
        final convoys = context.read<ConvoyService?>();
        _bleRemote = BleRemoteService(
          intercomService: intercom,
          safetyService: safety,
          convoyService: convoys,
        );
        _ownsBleRemote = true;
      }
      _bleRemote?.statusNotifier.addListener(_onRemoteStatus);
      BiometricSafetyBridge().snapshotNotifier.addListener(_onBiometricSnapshot);
      SmartAirbagBridgeService().connectionStateNotifier.addListener(_onAirbagUpdate);
      SmartAirbagBridgeService().telemetryNotifier.addListener(_onAirbagUpdate);

      final helmetVoice = context.read<HelmetVoiceService?>();
      _helmetVoice = helmetVoice;
      // Default microphone capture disabled on cockpit mount
      _helmetVoice?.stopListening();
    _intercomService?.stopCaptureOnTripEnd();
    });
  }

  void _onRemoteStatus() {
    if (mounted) setState(() {});
  }

  void _onBiometricSnapshot() {
    if (mounted) setState(() {});
  }

  void _onAirbagUpdate() {
    if (mounted) setState(() {});
  }

  void _onSirenAlert() {
    _noteAlert();
    if (mounted) setState(() {});
  }

  /// An alert came (siren, a new important / critical card): the full cockpit at normal brightness at once.
  void _noteAlert() {
    _lastAlertMs = DateTime.now().millisecondsSinceEpoch;
    if ((_dimmed || _aodOn) && mounted) scheduleMicrotask(() { if (mounted) _syncWakelock(); });
  }

  /// Locked mode, keyguard or heat changed.
  void _onLockCockpit() {
    if (!mounted) return;
    setState(() {});
    _syncWakelock();
  }

  /// Settings › Ride screen changed (idle display, keep screen on).
  void _onScreenSettings() {
    if (mounted) _syncWakelock();
  }

  /// Tells the lock-screen cockpit service whether this ride screen is the one in front.
  void _reportCockpit() {
    final svc = _lockCockpit;
    if (svc == null || !mounted) return;
    final route = ModalRoute.of(context);
    var active = false;
    try {
      final s = _convoys;
      final convoy = s == null ? null : (s.allConvoys[widget.convoyId] ?? s.activeConvoy);
      active = s != null &&
          convoy != null &&
          !_isTerminalTripStatus(convoy.tripStatus) &&
          (s.activeGroupId == null || s.activeGroupId == widget.convoyId);
    } catch (_) {
      active = false;
    }
    _reportedRoute = route;
    svc.setCockpit(route: route, visible: widget.isVisible && active);
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
    if (oldWidget.isVisible != widget.isVisible ||
        oldWidget.routeObserver != widget.routeObserver) {
      if (oldWidget.routeObserver != widget.routeObserver) {
        _subscribeRouteObserver();
      }
      _syncWakelock();
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
    // The shared guide may be a new one for a new ride session: keep my fuel-stop callback on it.
    _guide.onFuelStopDone ??= _onFuelStopDone;
    _syncWakelock();
    final convoy = s.allConvoys[widget.convoyId];
    final uid = _auth?.currentUserId ?? s.myUserId ?? '';
    if (convoy == null || uid.isEmpty) return;
    final me = convoy.riders[uid];
    _checkAutoOfflineMapPreparation(convoy, me);
    if (me != null) _updateAdvisories(s, convoy, me);
    if (_rideEssentials != null) {
      if (_essentials?.snapshot == null && convoy.route != null) {
        _syncEssentials(category: 'FUEL');
      }
      return;
    }
    _guide.setConvoy(convoy, uid);
    if (!s.isRealGpsActive) return;
    final life = WidgetsBinding.instance.lifecycleState;
    if (life != null && life != AppLifecycleState.resumed) return;
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

    // Auto-detect stop reason when stationary near a fuel bunk (minimal rider input)
    if (me.speedKmh < 3 && me.statusReason.isEmpty) {
      final nearestFuel = _essentials?.upcoming.where((e) => e.category == 'FUEL').firstOrNull;
      if (nearestFuel != null && me.lat != 0 && me.lng != 0) {
        final distM = GeoMath.haversine(me.lat, me.lng, nearestFuel.lat, nearestFuel.lng);
        if (distM <= 250) {
          s.updateStatusReason(userId: me.userId, reason: 'FUELING', message: 'At ${nearestFuel.name}');
        }
      }
    } else if (me.speedKmh > 15 && me.statusReason == 'FUELING') {
      // Auto-clear fueling status after rider resumes riding on the road
      s.updateStatusReason(userId: me.userId, reason: '', message: '');
    }
  }

  /// Automatically prepares map tiles around rider location, active route corridor (2.5 km),
  /// stops, destination, and nearby group members in background during normal riding.
  void _checkAutoOfflineMapPreparation(ConvoyModel convoy, RiderModel? me) {
    if (!mounted) return;
    final prefetcher = context.read<TilePrefetcher?>();
    if (prefetcher == null || prefetcher.running) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final pos = (me != null && RideFacts.hasPosition(me)) ? (me.lat, me.lng) : null;

    final movedSignificant = pos != null &&
        (_lastPrepRiderPos == null ||
            GeoMath.haversine(pos.$1, pos.$2, _lastPrepRiderPos!.$1, _lastPrepRiderPos!.$2) > 1000);

    if (_lastAutoMapPrepMs == 0 || (now - _lastAutoMapPrepMs > 120000) || movedSignificant) {
      _lastAutoMapPrepMs = now;
      _lastPrepRiderPos = pos;

      final stops = [for (final s in convoy.plannedStops) (s.lat, s.lng)];
      final dest = (convoy.destinationLat != 0.0 && convoy.destinationLng != 0.0)
          ? (convoy.destinationLat, convoy.destinationLng)
          : null;
      final members = [
        for (final r in convoy.riders.values)
          if (r.userId != me?.userId && RideFacts.hasPosition(r)) (r.lat, r.lng)
      ];

      prefetcher.prepareActiveRide(
        routeLine: convoy.routeLine,
        riderLocation: pos,
        stops: stops,
        destination: dest,
        groupMembers: members,
        label: convoy.name,
        tripId: convoy.groupId,
      ).ignore();
    }
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
    _subscribedObserver?.unsubscribe(this);
    _subscribedObserver = null;
    _subscribedRoute = null;
    WidgetsBinding.instance.removeObserver(this);
    _convoys?.removeListener(_onConvoyUpdate);
    if (_convoys?.rideMoving == _chatMoving) _convoys?.rideMoving = null;
    widget.focus?.removeListener(_onFocusRequest);
    _rideEssentials?.removeListener(_essentialsChanged);
    if (_guide.onFuelStopDone == _onFuelStopDone) _guide.onFuelStopDone = null;
    final roadCare = _roadCareSafety?.roadCare;
    if (roadCare != null && roadCare.activeLine == _roadCareLine) roadCare.activeLine = null;
    if (roadCare != null && roadCare.roadData == _roadCareData) roadCare.roadData = null;
    if (_rideEssentials == null) {
      _localGuide.removeListener(_onGuide);
      _localGuide.dispose();
      _essentials?.removeListener(_essentialsChanged);
      _essentials?.dispose();
    }
    _waitTimer?.cancel();
    _staleTimer?.cancel();
    _hideTimer?.cancel();
    _tapGateTimer?.cancel();
    _autoDismissTimer?.cancel();
    _hudToastTimer?.cancel();
    _awakeTimer?.cancel();
    if (_pointerRouted) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onAnyPointer);
      _pointerRouted = false;
    }
    if (_dimmed) SafetyNative.windowBrightness(null).ignore();
    _settingsRef?.removeListener(_onScreenSettings);
    _lockCockpit?.removeListener(_onLockCockpit);
    if (_aodOn) _lockCockpit?.aodShowing = false;
    _lockCockpit?.clearCockpit(_reportedRoute);
    final theme = _theme;
    if (_rideDarkWanted && theme != null) scheduleMicrotask(() => theme.setRideDarkOverride(false));
    _navCam.removeListener(_onNavCamChanged);
    _navCam.dispose();
    _sheetTop.dispose();
    _sheetExpansion.dispose();
    if (_intercomService?.onMicChunk == _sirenDetector?.processPcmChunk) {
      _intercomService?.onMicChunk = null;
    }
    _sirenDetector?.activeSirenNotifier.removeListener(_onSirenAlert);
    if (_ownsSirenDetector) {
      _sirenDetector?.dispose();
    }
    _bleRemote?.statusNotifier.removeListener(_onRemoteStatus);
    BiometricSafetyBridge().snapshotNotifier.removeListener(_onBiometricSnapshot);
    SmartAirbagBridgeService().connectionStateNotifier.removeListener(_onAirbagUpdate);
    SmartAirbagBridgeService().telemetryNotifier.removeListener(_onAirbagUpdate);
    if (_ownsBleRemote) {
      _bleRemote?.dispose();
    }
    _helmetVoice?.stopListening();
    _intercomService?.stopCaptureOnTripEnd();
    if (_wakelockActive || _keepScreenOn) {
      _wakelockActive = false;
      WakelockPlus.disable().catchError((e) => debugPrint('Wakelock dispose note: $e'));
    }
    super.dispose();
  }

  Future<void> _toggleKeepScreenOn() async {
    final next = !_keepScreenOn;
    _keepScreenOn = next;
    if (mounted) setState(() {});
    await _syncWakelock();
  }

  bool _calculateShouldKeepScreenOn() {
    if (!_keepScreenOn) return false;

    final life = WidgetsBinding.instance.lifecycleState;
    if (life == AppLifecycleState.paused || life == AppLifecycleState.hidden || life == AppLifecycleState.inactive) {
      return false;
    }

    if (!widget.isVisible) return false;

    if (_isRouteObscured) return false;

    if (mounted) {
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) {
        return false;
      }
    }

    final s = _convoys ?? (mounted ? _tryReadConvoyService() : null);
    if (s == null) {
      return true;
    }
    if (s.activeGroupId != null && s.activeGroupId != widget.convoyId) {
      return false;
    }
    final convoy = s.allConvoys[widget.convoyId] ?? s.activeConvoy;
    if (convoy == null || _isTerminalTripStatus(convoy.tripStatus)) {
      return false;
    }

    return _evaluateAwake(s, convoy).keepOn;
  }

  /// Any touch anywhere in the app wakes the dimmed ride screen and restarts the 30 s.
  void _onAnyPointer(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    // The Ride AOD's "Hold SOS" hint can be held without waking the full cockpit first.
    if (_aodOn && RideAodView.sosPointerDown) return;
    _lastTouchMs = DateTime.now().millisecondsSinceEpoch;
    if (_dimmed && mounted) _syncWakelock();
  }

  /// Riding with the ride screen in front: keep on (dim after 30 s) unless parked or low battery.
  ScreenAwakeDecision _evaluateAwake(ConvoyService s, ConvoyModel convoy) {
    final now = DateTime.now().millisecondsSinceEpoch;
    var moving = true;
    var battery = -1;
    var charging = false;
    try {
      final me = convoy.riders[s.myUserId ?? _auth?.currentUserId ?? ''];
      moving = me == null || me.speedKmh >= RideThresholds.movingSpeedKmh;
      battery = s.currentBatteryLevel;
      charging = s.isCharging;
    } catch (_) {
      // Partial test doubles of the service: no battery information (never blocks).
    }
    if (moving) {
      _parkedSinceMs = 0;
    } else if (_parkedSinceMs == 0) {
      _parkedSinceMs = now;
    }
    final emergency = SosHoldScreen.isOpen || convoy.activeAlerts.any((a) => !a.resolved);
    final settings = _settingsRef;
    final d = ScreenAwakePolicy.decide(
      riding: true,
      foreground: true,
      userKeepOn: true,
      nowMs: now,
      lastTouchMs: _lastTouchMs,
      parkedSinceMs: _parkedSinceMs,
      batteryPercent: battery,
      charging: charging,
      emergencyOpen: emergency,
      idleMode: settings?.rideIdleMode ?? RideIdleMode.aod,
      keepOnMode: settings?.keepScreenOnMode ?? KeepScreenOnMode.whileMoving,
      lastAlertMs: _lastAlertMs,
      thermalStatus: _lockCockpit?.thermalStatus ?? 0,
    );
    final before = _awake;
    _awake = d;
    final notice = d.notice;
    if (notice != null && (before == null || before.reason != d.reason)) {
      // Say why the screen may sleep now (never during a build: the toast calls setState).
      scheduleMicrotask(() {
        if (mounted) _showHudToast(notice, Icons.screen_lock_portrait_rounded);
      });
    }
    _armAwakeTimer(d, now);
    return d;
  }

  /// One timer for the next dim / parked change instead of polling.
  void _armAwakeTimer(ScreenAwakeDecision d, int now) {
    _awakeTimer?.cancel();
    _awakeTimer = null;
    final at = ScreenAwakePolicy.nextChangeAt(
      current: d,
      nowMs: now,
      lastTouchMs: _lastTouchMs,
      parkedSinceMs: _parkedSinceMs,
      lastAlertMs: _lastAlertMs,
      keepOnMode: _settingsRef?.keepScreenOnMode ?? KeepScreenOnMode.whileMoving,
    );
    if (at == null) return;
    _awakeTimer = Timer(Duration(milliseconds: at - now), () {
      _awakeTimer = null;
      if (mounted) _syncWakelock();
    });
  }

  /// Lowers only CoRoute's window brightness (the system setting is never changed): dimmed cockpit or Ride AOD.
  void _syncBrightness(double? value) {
    if (value == _brightness) return;
    _brightness = value;
    _dimmed = value != null;
    SafetyNative.windowBrightness(value).ignore();
  }

  /// The black Ride AOD over the cockpit (idle with the screen kept on).
  void _syncAod(bool on) {
    if (on == _aodOn) return;
    _aodOn = on;
    _lockCockpit?.aodShowing = on;
    if (!mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  /// Battery saver during an active ride: the dark ride theme and dark map.
  void _syncRideDark() {
    var want = false;
    try {
      final s = _convoys;
      final convoy = s == null ? null : (s.allConvoys[widget.convoyId] ?? s.activeConvoy);
      want = s != null && convoy != null && !_isTerminalTripStatus(convoy.tripStatus) && s.batterySaverActive;
    } catch (_) {
      want = false;
    }
    if (want == _rideDarkWanted) return;
    _rideDarkWanted = want;
    final theme = _theme;
    if (theme == null) return;
    // Never notify the theme listeners in the middle of a build.
    scheduleMicrotask(() => theme.setRideDarkOverride(want));
  }

  ConvoyService? _tryReadConvoyService() {
    try {
      return context.read<ConvoyService?>();
    } catch (_) {
      return null;
    }
  }

  static bool _isTerminalTripStatus(String? status) {
    if (status == null) return false;
    final s = status.trim().toUpperCase();
    return s == 'ENDED' || s == 'CANCELLED' || s == 'COMPLETED';
  }

  Future<void> _syncWakelock() async {
    _navCam.setForeground(_mapOnScreen());
    final shouldKeepOn = _calculateShouldKeepScreenOn();
    if (!shouldKeepOn) {
      _awakeTimer?.cancel();
      _awakeTimer = null;
    }
    _syncBrightness(shouldKeepOn ? _awake?.brightness : null);
    _syncAod(shouldKeepOn && _awake?.display == RideDisplay.aod);
    _syncRideDark();
    _reportCockpit();
    if (shouldKeepOn == _wakelockActive) return;
    _wakelockActive = shouldKeepOn;
    try {
      if (shouldKeepOn) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (e) {
      debugPrint('Wakelock sync note: $e');
    }
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
    if (mounted) _popup<void>('sos', () => EmergencySosSheet.show(context, lat: lat, lng: lng), protected: true);
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
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Suggestion sent to the trip owner and the Lead.')));
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
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Meeting point set. Your group gets an alert.')));
    }
  }

  /// "Report a rider down here" (3.16): the report sheet, then the existing
  /// REPORT_DOWN message. Needs a gateway with the safety network.
  Future<void> _reportDownAt(ConvoyService service, double lat, double lng, String placeName) async {
    if (!service.supports(ProtocolFeatures.safetyNet)) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.t('report.unavailable'))));
      }
      return;
    }
    final sent = await _popup<bool>('report_down', () => showReportDownSheet(context, lat: lat, lng: lng, placeName: placeName));
    if (sent == null || !mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
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
    LockedCockpit.run(context, CockpitAction.shareLiveLink, () => SharePlus.instance.share(ShareParams(text: text))).ignore();
  }

  void _focus(double lat, double lng) {
    if (lat == 0 && lng == 0) return;
    _setAutoFollow(false);
    _sheetKey.currentState?.collapse();
    try {
      _mapController.move(LatLng(lat, lng), 16.5);
    } catch (_) {}
  }

  bool _fuelRouting = false;

  /// One flow for "take me to fuel" (3.55): the pump is marked at once, the detour route is asked
  /// (awaited), and what the rider hears and reads says what really happened: routed, or marked
  /// without a route yet (no signal; retried from the next fixes). A second tap while a request is on
  /// its way does nothing. The group plan is never changed.
  Future<void> _autoRouteToFuel(ConvoyService service, RiderModel me,
      {required double lat, required double lng, required String name, double distM = 0}) async {
    if (_fuelRouting) return;
    // 3.55 admin feature switch: no automatic detour while fuel auto-route is off; the pump is shown.
    if (!context.featureOnNow('fuelAutoRoute')) {
      _focus(lat, lng);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Routing to fuel stations is turned off for now. $name is shown on the map.')));
      return;
    }
    _fuelRouting = true;
    final voice = context.read<VoiceService?>();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final safety = context.read<SafetyService?>();
    final distText = distM > 0 ? ' ${(distM / 1000).toStringAsFixed(1)} km ahead' : '';
    bool ok = false;
    try {
      _focus(lat, lng);
      ok = await _guide.addPersonalFuelStop(lat: lat, lng: lng, name: name);
    } finally {
      _fuelRouting = false;
    }
    if (!mounted) return;
    final usable = safety?.estimatedUsableKm?.round();
    service.updateStatusReason(
      userId: me.userId,
      reason: 'FUELING',
      message: 'Refuelling at $name$distText${usable != null ? ' ($usable km left)' : ''}',
    );
    messenger?.clearSnackBars();
    if (ok) {
      voice?.speak('Fuel stop added. Routing you to $name$distText.', priority: VoicePriority.important);
      messenger?.showSnackBar(SnackBar(content: Text('Routing to $name$distText. Only your route changed.'), backgroundColor: AppTheme.brand));
    } else {
      voice?.speak('Fuel stop $name marked on your map. No route yet, trying again.', priority: VoicePriority.important);
      messenger?.showSnackBar(SnackBar(content: Text('$name is marked on your map. No route yet (no signal); trying again as you ride.')));
    }
  }

  /// My fuel stop was reached or passed (RouteGuide): the "refuelling" status ends.
  void _onFuelStopDone(StopPointModel stop, {required bool reached}) {
    if (!mounted) return;
    final service = _convoys;
    final uid = service?.myUserId;
    if (service != null && uid != null) service.updateStatusReason(userId: uid, reason: '', message: '');
    final voice = context.read<VoiceService?>();
    voice?.speak(reached ? 'You have reached ${stop.name}.' : 'Fuel stop removed.', priority: VoicePriority.important);
  }

  void _handleFuelPromptAction(ConvoyService service, RiderModel? me) {
    if (me == null) return;
    final safety = context.read<SafetyService?>();
    // First choice: the next station on the route that sells this bike's fuel (matched on the phone).
    final matched = safety?.fuelAhead?.stops
        .where((s) => s.confirmed && !safety.isStationClosed(s.poi.id))
        .firstOrNull;
    final station = matched != null
        ? null
        : _essentials?.onRouteFuelAhead.firstOrNull ??
            _essentials?.upcoming
                .where((e) => e.category == 'FUEL' && !(safety?.isStationClosed(e.placeId) ?? false))
                .firstOrNull;
    if (matched != null || station != null) {
      final stationLat = matched?.poi.lat ?? station!.lat, stationLng = matched?.poi.lng ?? station!.lng;
      final stationName = matched != null ? matched.poi.displayName : (station!.name.isEmpty ? 'Petrol pump' : station.name);
      final distM = matched != null
          ? matched.distanceKm * 1000
          : (station!.routePositionM > (_essentials?.progressM ?? 0))
              ? (station.routePositionM - (_essentials?.progressM ?? 0))
              : station.accessDistanceM;
      safety?.answerPrompt(SafetyConstants.promptFuel);
      _autoRouteToFuel(service, me, lat: stationLat, lng: stationLng, name: stationName, distM: distM).ignore();
    } else {
      if (me.lat != 0 && me.lng != 0) {
        _essentials?.fetchNearbyFuel(lat: me.lat, lng: me.lng, force: true);
      }
      _openNearbyFuelSheet(service, me);
    }
  }

  void _openNearbyFuelSheet(ConvoyService service, RiderModel me) {
    final safety = context.read<SafetyService?>();
    final usableKm = safety?.estimatedUsableKm;
    final essentials = _essentials;
    final upcomingFuel = essentials?.upcoming.where((e) => e.category == 'FUEL').toList() ?? [];
    final nearbyFuel = essentials?.nearbyFuelStations ?? [];
    final allStations = upcomingFuel.isNotEmpty ? upcomingFuel : nearbyFuel;

    if (allStations.isEmpty && me.lat != 0 && me.lng != 0) {
      essentials?.fetchNearbyFuel(lat: me.lat, lng: me.lng, force: true);
    }

    _popup<void>('fuel_nearby', () => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      barrierColor: AppScrim.color,
      constraints: BoxConstraints(maxWidth: 600, maxHeight: MediaQuery.sizeOf(context).height * 0.88),
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(borderRadius: Radii.sheetTop),
      builder: (ctx) {
        List<RouteEssential> currentList = List.from(allStations);
        return StatefulBuilder(
          builder: (context, setSheetState) {
            bool isScanning = essentials?.loading ?? false;
            return SafeArea(
              // Only as tall as its content: the rest of the screen is the
              // scrim, so a tap there closes the sheet.
              child: Align(
                alignment: Alignment.bottomCenter,
                heightFactor: 1.0,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(Space.s24, Space.s16, Space.s24, Space.s24),
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: Container(
                              width: 36,
                              height: 4,
                              decoration: BoxDecoration(color: AppTheme.border, borderRadius: BorderRadius.circular(2)),
                            ),
                          ),
                          const SizedBox(height: Space.s16),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(Space.s8),
                                decoration: BoxDecoration(color: AppTheme.brand.withOpacity(0.15), shape: BoxShape.circle),
                                child: Icon(Icons.local_gas_station_rounded, color: AppTheme.brand, size: 28),
                              ),
                              const SizedBox(width: Space.s12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Fuel stations near you', style: AppText.title),
                                    Text(
                                      usableKm != null
                                          ? 'Usable range ~${usableKm.round()} km · Tap a station to route there'
                                          : 'Mapped fuel stations around your position',
                                      style: AppText.caption.copyWith(color: AppTheme.accentText, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: Space.s16),
                          const Divider(),
                          const SizedBox(height: Space.s8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('NEARBY FUEL STATIONS', style: AppText.caption.copyWith(fontWeight: FontWeight.w600, color: AppTheme.muted)),
                              if (me.lat != 0 && me.lng != 0)
                                TextButton.icon(
                                  onPressed: isScanning ? null : () async {
                                    setSheetState(() { isScanning = true; });
                                    final res = await essentials?.fetchNearbyFuel(lat: me.lat, lng: me.lng, force: true);
                                    if (ctx.mounted && res != null) {
                                      setSheetState(() {
                                        currentList = List.from(res);
                                        isScanning = false;
                                      });
                                    }
                                  },
                                  icon: isScanning ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh_rounded, size: 14),
                                  label: Text(isScanning ? 'Searching…' : 'Search again', style: const TextStyle(fontSize: 12)),
                                ),
                            ],
                          ),
                          const SizedBox(height: Space.s8),
                          if (currentList.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: Space.s24),
                              child: Column(
                                children: [
                                  Icon(Icons.location_searching_rounded, size: 40, color: AppTheme.muted),
                                  const SizedBox(height: Space.s12),
                                  Text(
                                    isScanning ? 'Finding fuel stations near you…' : 'No fuel stations found within 25 km.',
                                    textAlign: TextAlign.center,
                                    style: AppText.body.copyWith(color: AppTheme.muted),
                                  ),
                                ],
                              ),
                            )
                          else
                            for (final st in currentList) ...[
                              Builder(builder: (_) {
                                final distM = GeoMath.haversine(me.lat, me.lng, st.lat, st.lng);
                                final distStr = formatDistanceRounded(distM);
                                return Container(
                                  margin: const EdgeInsets.only(bottom: Space.s8),
                                  padding: const EdgeInsets.all(Space.s12),
                                  decoration: BoxDecoration(
                                    color: AppTheme.bg,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: AppTheme.border),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(Icons.local_gas_station_rounded, color: AppTheme.brand, size: 22),
                                      const SizedBox(width: Space.s8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(st.name.isEmpty ? 'Petrol pump' : st.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 14)),
                                            Text(
                                              st.isCoco ? 'COCO · $distStr away' : (st.operatorName != null ? '${st.operatorName} · $distStr away' : '$distStr away'),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: AppText.caption.copyWith(color: AppTheme.accentText, fontWeight: FontWeight.bold),
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        icon: Icon(Icons.block_rounded, size: 18, color: AppTheme.warnText),
                                        tooltip: 'Mark station closed',
                                        onPressed: () {
                                          if (ctx.mounted) Navigator.pop(ctx);
                                          _handleStationClosed(st, service, me);
                                        },
                                      ),
                                      const SizedBox(width: Space.s4),
                                      ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: AppTheme.brand,
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                          minimumSize: const Size(0, 44),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                        ),
                                        onPressed: () {
                                          if (ctx.mounted) Navigator.pop(ctx);
                                          final picked = PickedPlace(name: st.name.isEmpty ? 'Petrol pump' : st.name, lat: st.lat, lng: st.lng, category: 'FUEL');
                                          final lead = service.canEditRoute;
                                          if (lead) {
                                            if (service.activeConvoy?.route?.points.isEmpty ?? true) {
                                              service.setDestination(picked);
                                            } else {
                                              service.addStop(picked);
                                            }
                                          } else {
                                            service.suggestStop(picked);
                                          }
                                          _focus(st.lat, st.lng);
                                          safety?.answerPrompt(SafetyConstants.promptFuel);
                                          service.updateStatusReason(userId: me.userId, reason: 'FUELING', message: 'Diverting to ${st.name}');
                                          ScaffoldMessenger.of(context).clearSnackBars();
                                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                            content: Text('Auto-routing to ${st.name}'),
                                            backgroundColor: AppTheme.brand,
                                          ));
                                        },
                                        icon: const Icon(Icons.navigation_rounded, size: 16),
                                        label: const Text('Route', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                      ),
                                    ],
                                  ),
                                );
                              }),
                            ],
                          const SizedBox(height: Space.s12),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: AppTheme.text,
                                    side: BorderSide(color: AppTheme.border, width: 1.5),
                                    padding: const EdgeInsets.symmetric(vertical: Space.s12, horizontal: Space.s16),
                                    minimumSize: const Size(0, 48),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  ),
                                  onPressed: () {
                                    if (ctx.mounted) Navigator.pop(ctx);
                                    _popup<void>('fuel', () => showFuelSheet(context));
                                  },
                                  icon: const Icon(Icons.tune_rounded, size: 18),
                                  label: const Text('Configure Tank Range & Mileage'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    ));
  }

  void _handleStationClosed(RouteEssential station, ConvoyService service, RiderModel? me) {
    if (me == null) return;
    final safety = context.read<SafetyService?>();
    safety?.markStationClosed(station.placeId);
    // The closed pump was my fuel stop: it goes (the next one is picked below).
    final mine = _guide.personalFuelStop;
    if (mine != null && GeoMath.haversine(mine.lat, mine.lng, station.lat, station.lng) < 60) _guide.clearPersonalFuelStop();

    final upcomingFuel = _essentials?.upcoming
        .where((e) => e.category == 'FUEL' && !(safety?.isStationClosed(e.placeId) ?? false))
        .toList() ?? [];
    final nextStation = upcomingFuel.isNotEmpty ? upcomingFuel.first : null;
    final usableKm = safety?.estimatedUsableKm ?? 30.0;
    final voice = context.read<VoiceService?>();

    if (nextStation != null) {
      final distKm = nextStation.aheadM(_essentials?.progressM ?? 0) / 1000;
      if (distKm <= usableKm) {
        voice?.speak('Station closed. Next one: ${nextStation.name}, ${distKm.toStringAsFixed(1)} kilometers.');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${station.name} closed · Routing you to ${nextStation.name}'),
          backgroundColor: AppTheme.warnText,
        ));
        // 3.55: my own detour (the group plan is not changed for a closed pump; the lead can still
        // add a group fuel stop from Stops).
        _autoRouteToFuel(service, me,
            lat: nextStation.lat, lng: nextStation.lng,
            name: nextStation.name.isEmpty ? 'Petrol pump' : nextStation.name, distM: distKm * 1000).ignore();
        return;
      }
    }

    voice?.speak('Warning: no fuel station within ${usableKm.round()} kilometers. Turn back or call for help.');
    _popup<void>('fuel_warning', () => showDialog<void>(
      context: context,
      barrierColor: AppScrim.color,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text('No reachable fuel station ahead', style: TextStyle(color: AppTheme.sos, fontWeight: FontWeight.bold)),
        content: Text(
          'Every mapped fuel station ahead is beyond your usable range (${usableKm.round()} km).\n\nTurn back to the last fuel station you passed, or call for roadside help.',
          style: AppText.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Dismiss', style: TextStyle(color: AppTheme.muted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.sos),
            onPressed: () {
              Navigator.pop(ctx);
              final auth = context.read<AuthService>();
              _openSosHold(service, auth);
            },
            child: const Text('Emergency Assist', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    ));
  }

  void _openRider(RiderModel r) {
    setState(() => _selectedRiderId = r.userId);
    _popup<void>('rider_card:${r.userId}', () => showRiderCard(
      context,
      convoyId: widget.convoyId,
      userId: r.userId,
      onShowOnMap: (rider) => _focus(rider.lat, rider.lng),
    ));
  }

  /// The ride has no seat left (the host's membership seats): an invite could not be used.
  bool _rideFull(ConvoyModel convoy) {
    if (!convoy.isFull) return false;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('This ride is full (${convoy.riderCountLabel} riders).')));
    return true;
  }

  void _shareInvite(ConvoyModel convoy) {
    if (_rideFull(convoy)) return;
    final link = '${AppConfig.apiBaseUrl}/join/${convoy.joinCode}';
    LockedCockpit.run(
      context,
      CockpitAction.shareInvite,
      () => SharePlus.instance.share(ShareParams(
        text: 'Join my CoRoute ride "${convoy.name}". Code ${convoy.joinCode}. Tap to open: $link',
        subject: 'CoRoute ride: ${convoy.name}',
      )),
    ).ignore();
  }

  void _copyCode(ConvoyModel convoy) {
    if (_rideFull(convoy)) return;
    LockedCockpit.run(context, CockpitAction.shareInvite, () {
      Clipboard.setData(ClipboardData(text: convoy.joinCode));
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Code ${convoy.joinCode} copied')));
      }
    }).ignore();
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
    // Read before the end clears the active convoy: used for the post-trip review prompt.
    final endedConvoy = service.allConvoys[widget.convoyId] ?? service.activeConvoy;
    final endedUid = _auth?.currentUserId ?? service.myUserId ?? '';
    // When offline, preserve locally available trip and rider info, and queue ENDED in outbox
    if (!service.isOnline) {
      await service.endTripOffline();
      _intercomService?.stopCaptureOnTripEnd();
      await _syncWakelock();
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Offline: Trip saved locally. End of ride queued for server sync.')),
        );
        _scheduleTripReviewPrompt(endedConvoy, endedUid);
        if (!widget.embedded) Navigator.of(context).maybePop();
      }
      return;
    }
    // ConvoyService saves the trip when the server confirms the end (_onTripEnded); no second save here.
    service.updateTripState('ENDED');
    _intercomService?.stopCaptureOnTripEnd();
    await _syncWakelock();
    if (!mounted) return;
    _scheduleTripReviewPrompt(endedConvoy, endedUid);
    if (!widget.embedded) Navigator.of(context).maybePop();
  }

  Future<void> _leaveRide(ConvoyService service, String uid) async {
    final ok = await confirmAction(
      context,
      title: 'Leave ride?',
      message: 'Your live location sharing with this group will stop. Your ride is saved.',
      confirmLabel: 'Leave Ride',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final leftConvoy = service.allConvoys[widget.convoyId] ?? service.activeConvoy;
    service.leaveActiveConvoy(uid);
    _intercomService?.stopCaptureOnTripEnd();
    await _syncWakelock();
    if (!mounted) return;
    _scheduleTripReviewPrompt(leftConvoy, uid);
    if (!widget.embedded) Navigator.of(context).maybePop();
  }

  /// Asks once for a post-trip review after the rider ended or left the trip (it is saved by
  /// then). Called while the cockpit is still mounted, right before it closes; the sheet opens
  /// a moment later on the app's root navigator, so it never blocks or delays that navigation.
  /// Shares the once-per-trip flag with [TripReportScreen] (`review_prompted_<id>`, written for
  /// both the rider's trip record id and the convoy id it falls back to), so the rider is asked
  /// at most once whichever screen gets there first.
  void _scheduleTripReviewPrompt(ConvoyModel? convoy, String uid) {
    if (!mounted || convoy == null || convoy.groupId.isEmpty) return;
    final nav = Navigator.maybeOf(context, rootNavigator: true);
    if (nav == null) return;
    ApiClient? api;
    try {
      api = context.read<ApiClient>();
    } catch (_) {
      api = null;
    }
    if (api == null) return;
    final groupId = convoy.groupId;
    // Same id ConvoyService.buildTripHistory gives the rider's trip record.
    final recordId = uid.isEmpty ? '' : 'TRIP-${groupId.replaceAll('GRP-', '')}-$uid';
    // 3.55: places I stayed at and did not rate in the cockpit join the wrap-up (at most 2,
    // skippable; admin switches placeReviews and reviewPrompt).
    final places = context.read<PlaceReviewService?>();
    final placesOn = context.featureOnNow('placeReviews') && context.featureOnNow('reviewPrompt');
    places?.onRideEnded(rideId: groupId);
    unawaited(_promptWrapUp(nav, api, groupId: groupId, recordId: recordId, tripName: convoy.name, places: places, placesOn: placesOn));
  }

  /// 3.55 after-ride wrap-up (docs/features_355/ratings_reviews.md): one sheet with "How was the
  /// ride?" and up to 2 places, then, once it is closed, the "Rate CoRoute" ask on its own rules
  /// (usually nothing). A clean ride leaves the ask pending for the next app open; a ride with an
  /// SOS or crash alarm never leads to it.
  static Future<void> _promptWrapUp(NavigatorState nav, ApiClient api,
      {required String groupId, required String recordId, required String tripName, PlaceReviewService? places, bool placesOn = false}) async {
    final keys = <String>{'review_prompted_$groupId', if (recordId.isNotEmpty) 'review_prompted_$recordId'};
    // Let the cockpit close and the server record the end first.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (!nav.mounted) return;
    var hadProblem = false;
    try {
      hadProblem = (await RideStatsStore.load(groupId))?.hadEmergency ?? false;
    } catch (_) {}
    hadProblem = hadProblem || EngagementService.sessionHealth().safetyProblem;
    await EngagementService.instance?.onRideEnded(hadProblem: hadProblem);
    var canReviewTrip = false;
    var reviewed = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!keys.any((k) => prefs.getBool(k) == true)) {
        // The convoy id is accepted by the gateway at once (the trip record syncs a minute later).
        final res = await api.getTripReview(groupId);
        canReviewTrip = res['canReview'] == true;
        reviewed = TripReview.tryParse(res['feedback']) != null;
        if (canReviewTrip && !reviewed) {
          for (final k in keys) {
            await prefs.setBool(k, true);
          }
        }
      }
    } catch (_) {
      // Offline or no answer: the trip report offers the trip review later (up to 7 days).
    }
    if (!nav.mounted) return;
    await RideWrapUpSheet.show(nav.context,
        api: api,
        tripId: groupId,
        tripName: tripName,
        canReviewTrip: canReviewTrip,
        tripReviewed: reviewed,
        places: places,
        placesEnabled: placesOn,
        rideId: groupId);
    if (nav.mounted) await AppReviewPrompt.maybeAskAfterRide(nav.context);
  }

  /// Feeds my newest position to the navigation camera, which follows it
  /// smoothly (course-up or north-up, speed zoom) while auto-follow is on and
  /// animates my marker between fixes. Bad fixes are dropped there.
  void _follow(RiderModel me) {
    if (me.lat == 0 && me.lng == 0) return;
    final service = _convoys;
    _navCam.onRiderFix(
      lat: me.lat,
      lng: me.lng,
      speedKmh: me.speedKmh,
      heading: me.heading,
      timestampMs: me.lastSeenEpochMs,
      accuracyM: me.trackingConfidence == TrackingConfidence.gpsFix ? service?.myFixAccuracyM : null,
      estimated: me.trackingConfidence != TrackingConfidence.gpsFix,
    );
    var saving = false;
    try {
      saving = service?.batterySaverActive ?? false;
    } catch (_) {
      // Partial test doubles of the service: no battery information.
    }
    _navCam.setPowerSaving(saving);
  }

  /// Auto-follow on or off, for the camera and the recenter chip.
  void _setAutoFollow(bool value) {
    if (value) {
      _navCam.resumeFollow();
    } else {
      _navCam.pauseFollow();
    }
    if (mounted && _autoFollow != value) setState(() => _autoFollow = value);
  }

  /// The camera paused or resumed by itself (a gesture, or riding again after a pan).
  void _onNavCamChanged() {
    if (!mounted || _autoFollow == _navCam.following) return;
    setState(() => _autoFollow = _navCam.following);
  }

  /// Tells the camera which part of the map is covered (top bar, sheet or side panel).
  void _syncNavInsets() {
    _navCam.setObscuredInsets(_navSide
        ? EdgeInsets.only(left: _navPanelW, top: _navTopReserve)
        : EdgeInsets.only(top: _navTopReserve, bottom: _sheetRestTop));
  }

  /// The map is actually on screen (app in front, this tab shown, nothing pushed over it).
  bool _mapOnScreen() {
    final life = WidgetsBinding.instance.lifecycleState;
    if (life != null && life != AppLifecycleState.resumed) return false;
    return mounted && widget.isVisible && !_isRouteObscured;
  }

  /// Several far riders merged into a bubble: zoom in on them (stops following).
  void _zoomToCluster(LatLng center) {
    _setAutoFollow(false);
    try {
      _mapController.move(center, (_mapController.camera.zoom + 2.0).clamp(3.0, 19.0).toDouble());
    } catch (_) {}
  }

  /// Approximate location (Android "Approximate" / iOS precise off) puts me and
  /// the group kilometres off on the map: ask once per session to turn precise on.
  /// Never while riding (no dialog at speed); it is asked again on the next resume.
  Future<void> _checkPreciseLocation() async {
    if (_precisePromptShown || !mounted) return;
    if (!await LocationPrecision.isApproximate() || !mounted || _precisePromptShown) return;
    final s = _convoys;
    final uid = _auth?.currentUserId ?? s?.myUserId ?? '';
    final speed = s?.allConvoys[widget.convoyId]?.riders[uid]?.speedKmh ?? 0.0;
    if (speed >= 10.0 || !_mapOnScreen()) return;
    _precisePromptShown = true;
    final enable = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Turn on precise location'),
        content: const Text(
            'CoRoute only has your approximate location, so you and your group can show up kilometres away '
            'on the map. Precise location keeps the live map, the group and SOS accurate.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Use precise location')),
        ],
      ),
    );
    if (enable != true || !mounted) return;
    final after = await LocationPrecision.requestPrecise();
    if (after == LocationAccuracyStatus.reduced && mounted) {
      _showHudToast('Precise location is still off: turn on "Use precise location" in Settings', Icons.gps_not_fixed_rounded);
      await LocationPrecision.openSettings();
    }
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
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? 'Your group knows you are OK.' : 'Could not tell the group right now. Riding on also closes this alert.'),
    ));
  }

  void _openIncident(IncidentView i) {
    if (i.hasPosition) _focus(i.lat, i.lng);
    _popup<void>('incident', () => showIncidentSheet(context, convoyId: widget.convoyId, subjectUserId: i.subjectUserId, alertId: i.alertId));
  }

  void _openAssist(AssistRequest a) {
    _focus(a.lat, a.lng);
    _popup<void>('assist', () => showAssistSheet(context, incidentId: a.incidentId));
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

  // ------------------------------------------- 3.55 heritage places, off the group's route

  /// From the convoy listener: updates the advisories and says their lines once.
  void _updateAdvisories(ConvoyService s, ConvoyModel convoy, RiderModel me) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final sosOpen = s.pendingSos != null || convoy.activeAlerts.any((a) => !a.resolved);
    // 3.55 admin feature switches (unknown or no service: on).
    _advice.heritageEnabled = context.featureOnNow('heritagePlaces') && !SosBatteryReserve.isActive; // 3.55 SOS battery reserve
    _advice.offGroupEnabled = context.featureOnNow('offRouteGroupPrompt');
    final couldTap = _advice.tapGate.canTap;
    final lines = _advice.update(convoy: convoy, me: me, guide: _guide, places: _places, sosOpen: sosOpen, nowMs: nowMs);
    if (_advice.tapGate.canTap != couldTap) setState(() {});
    _armTapGateTimer(nowMs);
    if (lines.isEmpty) return;
    final voice = context.read<VoiceService?>();
    for (final l in lines) {
      // Heritage at the lowest voice priority; leaving the group's route as navigation.
      voice?.speak(l.text, priority: l.heritage ? VoicePriority.important : VoicePriority.warning, key: l.key).ignore();
    }
  }

  /// 3.55 taps while moving: once the speed has stayed low, the gate flips to stopped after
  /// [RideTapGate.stoppedHold] even when no new fix comes; one one-shot timer, nothing while idle.
  void _armTapGateTimer(int nowMs) {
    final at = _advice.tapGate.settleAtMs;
    if (at == null) {
      _tapGateTimer?.cancel();
      _tapGateTimer = null;
      return;
    }
    if (_tapGateTimer?.isActive ?? false) return;
    _tapGateTimer = Timer(Duration(milliseconds: (at - nowMs).clamp(0, 60000).toInt() + 100), () {
      _tapGateTimer = null;
      if (!mounted) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_advice.tapGate.tick(now)) setState(() {});
      _armTapGateTimer(now);
    });
  }

  /// "Route to group": my own route to the group's planned route near the closest rider.
  Future<void> _routeToGroup(ConvoyModel convoy, RiderModel me) async {
    final target = _advice.rejoinTarget(convoy, me, DateTime.now().millisecondsSinceEpoch);
    setState(_advice.resolveOffGroup);
    if (target == null) return;
    final voice = context.read<VoiceService?>();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await _guide.routeToGroup(lat: target.lat, lng: target.lng, name: target.name);
    if (!mounted) return;
    messenger?.clearSnackBars();
    if (ok) {
      voice?.speak('Routing you back to the group.', priority: VoicePriority.warning, key: 'ROUTE_TO_GROUP').ignore();
      messenger?.showSnackBar(SnackBar(content: Text('Routing you to the group near ${target.peer.name}. Only your route changed.')));
    } else {
      messenger?.showSnackBar(const SnackBar(content: Text('No route to the group yet (no signal). Trying again as you ride.')));
    }
  }

  /// "Add stop" on a historic place: the lead adds it, anyone else suggests it.
  void _heritageStop(ConvoyService service, HeritageAhead h) {
    final place = PickedPlace(lat: h.poi.lat, lng: h.poi.lng, name: h.poi.displayName, category: 'SCENIC', plannedDwellMin: 30);
    final lead = service.canEditRoute;
    final ok = lead ? service.addStop(place) : service.suggestStop(place);
    setState(_advice.dismissHeritage);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(ok
          ? (lead ? '${h.poi.displayName} added as a stop.' : '${h.poi.displayName} suggested to the trip owner.')
          : 'Could not add the stop now. Try again with signal.'),
    ));
  }

  // ------------------------------------------------------------- alert slot

  /// 3.55 ride chat: moving per the cockpit's tap gate (8 km/h, 5 s stop hold).
  bool _chatMoving() => _advice.tapGate.moving;

  void _openChat(ConvoyModel convoy, RiderModel me) =>
      _popup<void>('messages', () => showMessagesSheet(context, convoyId: convoy.groupId, me: me));

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
        onAction: () => _popup<void>('sos', () => EmergencySosSheet.show(context, lat: me.lat, lng: me.lng), protected: true),
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
    // FEAT-02: Severe road hazard alerts ahead (within 500m)
    for (final rh in service.roadHazards) {
      final d = myPos ? GeoMath.haversine(me.lat, me.lng, rh.lat, rh.lng) : null;
      if (d != null && d <= 500 && d >= 10) {
        final key = 'ROAD_HAZARD:${rh.eventId}';
        out.add(_Slot(
          key: key,
          tier: AlertTier.important,
          title: RoadHazardHudPill.titleFor(rh), // 3.55: by kind
          priority: AlertPriority.hazard,
          dismissible: true,
          child: RoadHazardHudPill(
            hazard: rh,
            distanceM: d.round(),
            onTap: () => _focus(rh.lat, rh.lng),
            onDismiss: () => _dismissAlert(key),
            // 3.55: a saved report the rider finds fixed.
            onFixed: rh.fromHistory ? () => service.clearSavedRoadHazard(rh.eventId) : null,
          ),
        ));
      }
    }
    // FEAT-03: Emergency Siren Acoustic Frequency Detector
    final sirenEvent = _sirenDetector?.activeSirenNotifier.value;
    if (sirenEvent != null) {
      // 3.55: keyed per episode, so a dismissed card does not hide later sirens on this ride.
      final key = 'EMERGENCY_SIREN_${_sirenDetector?.sirenEpisode ?? 0}';
      out.add(_Slot(
        key: key,
        tier: AlertTier.critical,
        title: 'EMERGENCY SIREN',
        priority: AlertPriority.hazard,
        dismissible: true,
        child: SirenHudPill(
          event: sirenEvent,
          onDismiss: () => _dismissAlert(key),
        ),
      ));
    }
    // FEAT-01: BLE Handlebar Wireless Remote Paired Status
    final remote = _bleRemote;
    if (remote != null && remote.status == BleRemoteStatus.paired) {
      const key = 'BLE_REMOTE_STATUS';
      out.add(_Slot(
        key: key,
        tier: AlertTier.normal,
        title: 'HANDLEBAR REMOTE',
        priority: AlertPriority.routeInfo,
        dismissible: true,
        child: BleRemoteHudPill(
          status: remote.status,
          batteryPercent: remote.batteryLevel,
          onDismiss: () => _dismissAlert(key),
        ),
      ));
    }
    // FEAT-04: Smartwatch Biometric Trauma & Pulse HUD Pill
    final bioBridge = BiometricSafetyBridge();
    if (bioBridge.isActive && (bioBridge.snapshot.isConnected || bioBridge.snapshot.currentBpm > 0)) {
      const key = 'BIOMETRIC_PULSE_STATUS';
      out.add(_Slot(
        key: key,
        tier: bioBridge.snapshot.isCritical ? AlertTier.critical : AlertTier.normal,
        title: 'BIOMETRIC PULSE',
        priority: bioBridge.snapshot.isCritical ? AlertPriority.sos : AlertPriority.routeInfo,
        dismissible: !bioBridge.snapshot.isCritical,
        child: BiometricPulseHudPill(
          snapshot: bioBridge.snapshot,
          onDismiss: () => _dismissAlert(key),
        ),
      ));
    }
    // FEAT-06: Smart Airbag Vest Peripheral Bluetooth Bridge HUD Pill
    final airbag = SmartAirbagBridgeService();
    if (airbag.isConnected ||
        airbag.connectionState == AirbagConnectionState.fault) {
      const key = 'SMART_AIRBAG_STATUS';
      final isDeployed = airbag.connectionState == AirbagConnectionState.deployed;
      out.add(_Slot(
        key: key,
        tier: isDeployed ? AlertTier.critical : AlertTier.normal,
        title: 'AIRBAG VEST',
        priority: isDeployed ? AlertPriority.sos : AlertPriority.routeInfo,
        dismissible: !isDeployed,
        child: SmartAirbagHudPill(
          connectionState: airbag.connectionState,
          telemetry: airbag.telemetry,
          batteryLevel: airbag.batteryLevel,
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
    // Ride safety prompts on this phone only ("Are you OK?", "Time for a break", "Overspeed", "Fuel").
    for (final p in prompts) {
      final second = p.secondaryLabel;
      final isOverspeed = p.kind == SafetyPromptKind.overspeed;
      final isFuel = p.kind == SafetyPromptKind.fuel;
      // DEDUPLICATION: CockpitActionStack provides the dedicated interactive handlebar capsule for fuel alerts.
      // Suppress the redundant top HUD toast banner for fuel to eliminate duplicate popups.
      if (isFuel) continue;
      out.add(_Slot(
        key: p.key,
        tier: p.tier,
        priority: isOverspeed ? AlertPriority.sos : (p.tier == AlertTier.critical ? AlertPriority.sos : (p.tier == AlertTier.important ? AlertPriority.groupSafety : null)),
        order: isOverspeed ? 960 : 800,
        title: p.title,
        message: p.message,
        actionLabel: p.primaryLabel,
        onAction: () {
          if (isFuel) {
            _handleFuelPromptAction(service, me);
          } else {
            context.read<SafetyService>().answerPrompt(p.key);
          }
        },
        onDismiss: second == null ? null : () => context.read<SafetyService>().answerPrompt(p.key, primary: false),
        dismissible: !isOverspeed,
      ));
    }
    // 3.55 ride chat: a text from another rider (8 s). Reply opens the chat (typing only when stopped).
    // Locked cockpit: "New message from <name>", never the text (same rule as the lock-screen notification).
    final chat = service.chatBanner;
    if (chat != null) {
      final line = LockScreenCockpitPolicy.chatBanner(locked: _lockCockpit?.locked ?? false, senderName: chat.senderName, text: chat.text);
      out.add(_Slot(
        key: 'CHAT:${chat.messageId}',
        tier: AlertTier.normal,
        priority: AlertPriority.social,
        title: line.title,
        message: line.message,
        actionLabel: 'Open chat',
        onAction: () {
          service.dismissChatBanner();
          _openChat(convoy, me);
        },
        onDismiss: service.dismissChatBanner,
        dismissible: true,
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
    // 3.55 place reviews: "How was Sri Sai Dhaba?" after a while there, only when stopped
    // (the service never offers it while riding or during an SOS / crash alarm).
    final placePrompt = context.select<PlaceReviewService?, PlaceReviewPrompt?>((s) => s?.prompt);
    final placeReviews = context.read<PlaceReviewService?>();
    // 3.55 taps while moving: the non-urgent cards below that need a tap show their buttons only
    // when stopped (a pillion can always tap); while moving, one line once and a chip.
    final canTap = _advice.tapGate.canTap;
    if (placePrompt != null && placeReviews != null && context.featureOn('placeReviews') && !canTap) {
      final key = 'PLACE_REVIEW:${placePrompt.placeId}';
      if (_advice.movingLines.take(key)) {
        context.read<VoiceService?>()?.speak(MovingCardText.reviewSpoken(placePrompt.place.displayName), priority: VoicePriority.important, key: key).ignore();
      }
      out.add(_Slot(
        key: key,
        tier: AlertTier.normal,
        priority: AlertPriority.social,
        title: placePrompt.title,
        child: MovingCardChip(text: MovingCardText.reviewChip(placePrompt.place.displayName), icon: Icons.star_rounded),
      ));
    } else if (placePrompt != null && placeReviews != null && context.featureOn('placeReviews')) {
      out.add(_Slot(
        key: 'PLACE_REVIEW:${placePrompt.placeId}',
        tier: AlertTier.normal,
        priority: AlertPriority.social,
        title: placePrompt.title,
        message: placePrompt.message,
        actionLabel: 'Rate',
        onAction: () => PlaceReviewPromptBanner.rate(context, placeReviews, placePrompt),
        dismissible: true,
        onDismiss: placeReviews.dismissPrompt,
        child: PlaceReviewPromptBanner(prompt: placePrompt, service: placeReviews),
      ));
    }
    // 3.55 riding roles: "You are now the sweeper, drop back..." (mine is important, others normal).
    final role = service.roleNotice;
    if (role != null) {
      out.add(_Slot(
        key: 'ROLE:${role.title}',
        tier: role.mine ? AlertTier.important : AlertTier.normal,
        title: role.title,
        message: role.message.isEmpty ? null : role.message,
        dismissible: true,
        onDismiss: service.dismissRoleNotice,
      ));
    }
    // 3.55: "You left the group's route": the way back first, then a wait request or my own way.
    if (_advice.offGroupShow && !canTap) {
      out.add(_Slot(
        key: 'OFF_GROUP:${_advice.offGroupSinceMs}',
        tier: AlertTier.important,
        title: OffRouteGroupMonitor.title,
        child: const MovingCardChip(text: MovingCardText.offRouteChip, icon: Icons.alt_route_rounded, important: true),
      ));
    } else if (_advice.offGroupShow) {
      final key = 'OFF_GROUP:${_advice.offGroupSinceMs}';
      final target = _advice.rejoinTarget(convoy, me, nowMs);
      out.add(_Slot(
        key: key,
        tier: AlertTier.important,
        title: OffRouteGroupMonitor.title,
        child: RideAlert(
          tier: AlertTier.important,
          title: OffRouteGroupMonitor.title,
          message: target == null ? 'No recent position from the group.' : 'The group is near ${target.peer.name.split(' ').first}.',
          actionLabel: target == null ? null : 'Route to group',
          onAction: target == null ? null : () => _routeToGroup(convoy, me),
          moreActions: [
            ('Ask group to wait', () {
              service.requestWait(me.name);
              setState(_advice.resolveOffGroup);
            }),
            ('Keep my own route', () => setState(_advice.resolveOffGroup)),
          ],
        ),
      ));
    }
    // 3.55 bike / pillion swap: someone asked me (Accept / Decline), then the outcome.
    final ask = service.swapAsk;
    if (ask != null && !canTap) {
      // The ask itself is spoken once by ConvoyService ("... Stop when safe to accept or decline.").
      out.add(_Slot(
        key: 'SWAP_ASK:${ask.requestId}',
        tier: AlertTier.important,
        title: ask.title,
        priority: AlertPriority.routeInfo,
        order: 250,
        child: MovingCardChip(text: MovingCardText.swapChip(ask.title), icon: Icons.swap_horiz_rounded, important: true),
      ));
    } else if (ask != null) {
      out.add(_Slot(
        key: 'SWAP_ASK:${ask.requestId}',
        tier: AlertTier.important,
        title: ask.title,
        priority: AlertPriority.routeInfo,
        order: 250,
        child: RideAlert(
          tier: AlertTier.important,
          title: ask.title,
          message: ask.message,
          actionLabel: 'Accept',
          onAction: () => service.answerSwap(ask.requestId, true),
          moreActions: [('Decline', () => service.answerSwap(ask.requestId, false))],
        ),
      ));
    }
    final swap = service.swapNotice;
    if (swap != null) {
      out.add(_Slot(
        key: 'SWAP:${swap.title}',
        tier: swap.mine ? AlertTier.important : AlertTier.normal,
        title: swap.title,
        message: swap.message.isEmpty ? null : swap.message,
        priority: AlertPriority.routeInfo,
        dismissible: true,
        onDismiss: service.dismissSwapNotice,
      ));
    }
    // 3.55 pillion seat: someone sat on my bike (Decline within a minute; later "Remove pillion" on
    // their rider card), and a pillion without a bike picks one (a pillion can always tap).
    final offer = service.pillionOffer;
    if (offer != null) {
      out.add(_Slot(
        key: 'PILLION_OFFER:${offer.pillionUserId}',
        tier: AlertTier.normal,
        title: offer.title,
        priority: AlertPriority.routeInfo,
        order: 251,
        child: canTap
            ? RideAlert(
                tier: AlertTier.normal,
                title: offer.title,
                message: offer.message,
                actionLabel: 'OK',
                onAction: service.dismissPillionOffer,
                moreActions: [('Decline', () => service.unseatPillion(offer.pillionUserId))],
              )
            : MovingCardChip(text: offer.title, icon: Icons.airline_seat_recline_normal_rounded),
      ));
    }
    if (service.pillionNeedsSeat && service.supportsPillionSeat) {
      out.add(_Slot(
        key: 'PILLION_PICK',
        tier: AlertTier.normal,
        title: 'Pick the bike you ride on',
        priority: AlertPriority.routeInfo,
        order: 252,
        child: RideAlert(
          tier: AlertTier.normal,
          title: 'Pick the bike you ride on',
          message: 'Your group then sees you on that bike.',
          actionLabel: 'Pick bike',
          onAction: () => showPillionSeatSheet(context, service),
          moreActions: [('Not now', service.dismissPillionPick)],
        ),
      ));
    }
    // 3.55: "Historic place on your way: Golconda Fort" (normal tier, Show / Add stop).
    final heritage = _advice.heritage;
    if (heritage != null && nowMs < _advice.heritageUntilMs && !canTap) {
      // Spoken once when it was found (RideAdvisories); the Show / Add stop buttons wait for a stop.
      out.add(_Slot(
        key: 'HERITAGE:${heritage.poi.id}',
        tier: AlertTier.normal,
        title: 'Historic place on your way: ${heritage.poi.displayName}',
        child: MovingCardChip(text: MovingCardText.heritageChip(heritage.poi.displayName), icon: Icons.account_balance_rounded),
      ));
    } else if (heritage != null && nowMs < _advice.heritageUntilMs) {
      final key = 'HERITAGE:${heritage.poi.id}';
      final title = 'Historic place on your way: ${heritage.poi.displayName}';
      out.add(_Slot(
        key: key,
        tier: AlertTier.normal,
        title: title,
        child: RideAlert(
          tier: AlertTier.normal,
          title: title,
          message: heritage.message,
          actionLabel: 'Show',
          onAction: () => _focus(heritage.poi.lat, heritage.poi.lng),
          moreActions: [('Add stop', () => _heritageStop(service, heritage))],
          onDismiss: () {
            _advice.dismissHeritage();
            _dismissAlert(key);
          },
        ),
      ));
    }
    // 3.55 engine care from the garage bike's details: a rest after a long hard stretch.
    final safetyForEngine = context.read<SafetyService?>();
    final engine = safetyForEngine?.engineNotice;
    if (safetyForEngine != null && engine != null) {
      out.add(_Slot(
        key: 'ENGINE:${engine.title}',
        tier: AlertTier.normal,
        title: engine.title,
        message: engine.message.isEmpty ? null : engine.message,
        dismissible: true,
        onDismiss: safetyForEngine.dismissEngineNotice,
      ));
    }
    // 3.55 road context: sharp bend, road speed limit, altitude or night care (informational;
    // road care itself stays silent and hidden while an emergency is open).
    final roadNotice = safetyForEngine?.roadCare.notice;
    if (safetyForEngine != null && roadNotice != null) {
      out.add(_Slot(
        key: roadNotice.key,
        tier: roadNotice.important ? AlertTier.important : AlertTier.normal,
        title: roadNotice.title,
        message: roadNotice.message.isEmpty ? null : roadNotice.message,
        priority: AlertPriority.routeInfo,
        dismissible: true,
        onDismiss: safetyForEngine.roadCare.dismissNotice,
      ));
    }
    // 3.55 SOS battery reserve (below 10%): "Battery saver for SOS is on" (informational).
    final reserve = context.read<SosBatteryReserve?>();
    if (reserve != null && reserve.showCard) {
      out.add(_Slot(
        key: 'SOS_RESERVE',
        tier: AlertTier.important,
        title: SosBatteryReserve.cardTitle,
        message: reserve.beaconSent ? SosBatteryReserve.cardMessage : SosBatteryReserve.cardMessageNotSent,
        priority: AlertPriority.groupSafety,
        order: 150,
        dismissible: true,
        onDismiss: reserve.dismissCard,
      ));
    }
    // 3.55 phone-mount check: once per ride when the phone is not in a handlebar mount.
    final sensorNotice = safetyForEngine?.sensorSafety.notice;
    if (safetyForEngine != null && sensorNotice != null) {
      out.add(_Slot(
        key: sensorNotice.key,
        tier: AlertTier.normal,
        title: sensorNotice.title,
        message: sensorNotice.message,
        priority: AlertPriority.routeInfo,
        dismissible: true,
        onDismiss: safetyForEngine.sensorSafety.dismissNotice,
      ));
    }
    // 3.55 no-signal ahead (mine and other riders'): informational route cards, never above safety.
    final soloGuardian = context.read<SoloGuardianService?>();
    for (final n in soloGuardian?.notices ?? const <SoloGuardianNotice>[]) {
      out.add(_Slot(key: n.key, tier: AlertTier.normal, title: n.title, message: n.message, dismissible: true,
          onDismiss: () => soloGuardian?.dismissNotice(n.key)));
    }
    // 3.55 group safety (missing-rider check, buddy, stretch, group break, risky stretch): group
    // safety priority at most, so SOS / crash / incidents always rank above; the card is the child
    // (slot message left empty so no other filter hides it).
    final groupSafety = context.watch<GroupSafetyService?>();
    if (groupSafety != null) {
      for (final n in groupSafety.notices) {
        out.add(_Slot(
          key: 'GS:${n.key}',
          tier: GroupSafetyCard.tierOf(n),
          title: n.title,
          child: GroupSafetyCard(notice: n, service: groupSafety, onSos: () => _triggerSos(service, _auth ?? context.read<AuthService>())),
        ));
      }
    }
    // The invite code belongs to a group ride; a solo ride (Community host) has none to share.
    if (convoy.riders.length <= 1 && convoy.hasGroupFeatures) {
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
            onView: () => _popup<void>('discovery', () => showDiscoverySheet(context, e, onWave: () => service.wave(e.encounterId))),
            onWave: () => service.wave(e.encounterId),
            onIgnore: () => service.ignoreEncounter(e.encounterId),
          ),
        ));
      }
    }
    // DEDUPLICATION: Suppress any fuel or petrol bunk alert from the top HUD slot.
    // The cockpit displays a single dedicated small red popup on the right handlebar stack instead.
    out.removeWhere((s) =>
        s.key == SafetyConstants.promptFuel ||
        s.key.toLowerCase().contains('fuel') ||
        s.title.toLowerCase().contains('fuel') ||
        (s.message?.toLowerCase().contains('fuel') ?? false) ||
        (s.message?.toLowerCase().contains('bunk') ?? false));
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
    // 3.55 engine care: rebuild when the "give your engine a rest" notice comes or goes.
    context.select<SafetyService?, Object?>((s) => s?.engineNotice);
    // 3.55 no-signal ahead cards (lib/data/services/solo_guardian_service.dart).
    context.select<SoloGuardianService?, int>((s) => s?.notices.length ?? 0);
    // 3.55 road context card and night contrast for alert cards.
    context.select<SafetyService?, (Object?, bool)>((s) => (s?.roadCare.notice, s?.roadCare.isNight ?? false));
    // 3.55 phone-mount card and the SOS battery reserve card.
    context.select<SafetyService?, Object?>((s) => s?.sensorSafety.notice);
    context.select<SosBatteryReserve?, (bool, bool)>((r) => (r?.showCard ?? false, r?.beaconSent ?? false));
    // 3.16: the fuel reminder row, the weather line and the route map prefetch state.
    final fuelRangeKm = context.select<SettingsService?, int>((s) => s?.fuelRangeKm ?? 0);
    final riddenKm = context.select<SafetyService?, int>((s) => ((s?.riddenSinceFillM ?? 0) / 1000).round());
    final weatherService = context.watch<WeatherService?>();
    final isWeatherUnavailable = weatherService?.isUnavailable ?? false;
    final weatherLine = context.select<WeatherService?, String?>((w) {
      final last = w?.last;
      return (last != null && last.rain) ? last.line : null;
    });
    // Rebuilds only when the prefetch state changes (at most every 500 ms while it runs).
    context.select<TilePrefetcher?, (bool, int, int, String?)>((p) => (p?.running ?? false, p?.done ?? 0, p?.total ?? 0, p?.error));
    final prefetcher = context.read<TilePrefetcher?>();
    final convoy = service.allConvoys[widget.convoyId];

    if (convoy == null || convoy.tripStatus == 'ENDED') return _ended(context);

    final isOffline = !service.isOnline || rtState != RealtimeState.connected;
    final isOfflineMode = isOffline || isWeatherUnavailable;

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
      final speedExpiresAt = r.lastSeenEpochMs + RideThresholds.staleAfter.inMilliseconds;
      if (r.lastSeenEpochMs > 0 && speedExpiresAt > now) _armHideTimer(speedExpiresAt, now);
    }
    final connection = ConnectionBanner.status(
      state: rtState,
      lastUpdateMs: newestOther,
      nowMs: now,
      serverUnreachable: service.serverUnreachable,
      serverBusy: service.serverBusy,
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
    // A new important / critical card (off-route, regroup, hazard...) brings the full cockpit back from the AOD.
    if (topSlot?.key != _lastAlertKey) {
      _lastAlertKey = topSlot?.key;
      if (topSlot != null && topSlot.tier != AlertTier.normal) _noteAlert();
    }
    final extra = slots.length - 1;
    const dismissSec = NetworkConstants.mapAlertDismissSeconds;

    if (topSlot != null) {
      if (topSlot.key != _autoDismissKey || _autoDismissDurationSec != dismissSec) {
        final isPermanent = topSlot.key == 'MY_SOS' || topSlot.key == SafetyConstants.promptOverspeed || !topSlot.dismissible;
        _scheduleAutoDismiss(topSlot.key, dismissSec, dismissible: !isPermanent);
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

    final personalLimit = context.select<SettingsService?, int>((s) => s?.speedLimitWarningKmh ?? 0);
    // 3.55 fix: the lead's town limit near the start, the destination and planned stops shows here too.
    final groupHere = groupLimitAt(
      groupKmh: convoy.speedLimitKmh,
      townKmh: convoy.townLimitKmh,
      lat: me.lat,
      lng: me.lng,
      places: [
        if (convoy.startLat != null && convoy.startLng != null) (convoy.startLat!, convoy.startLng!),
        (convoy.destinationLat, convoy.destinationLng),
        for (final s in convoy.plannedStops) (s.lat, s.lng),
      ],
    );
    final speedLimit = effectiveSpeedLimit(groupKmh: groupHere, personalKmh: personalLimit);
    final showSpeed = speedLimit > 0 && me.speedKmh >= speedLimit - 10;
    // "Guardian on" in the ride-summary card: this phone's crash detection setting.
    final guardianOn = context.select<SettingsService?, bool>((s) => s?.crashDetection ?? true);

    final cockpit = Scaffold(
      backgroundColor: AppTheme.map,
      body: LayoutBuilder(builder: (context, box) {
        final h = box.maxHeight;
        final w = box.maxWidth;
        final side = w > h && w >= 560;
        final panelW = side ? (w * 0.45).clamp(320.0, 420.0).toDouble() : w;
        // The SOS button's real footprint: the 68 dp button inside its 14 dp pulse ring.
        const sosSize = 68.0 + 14.0;
        final safe = MediaQuery.paddingOf(context);
        final bottomInset = safe.bottom;
        final topInset = safe.top;
        final leftInset = safe.left;
        final rightInset = safe.right;
        final textScaler = MediaQuery.textScalerOf(context);
        // Room kept above the fully open sheet in portrait: the top bar and, under it, the SOS
        // button, so SOS rides on the sheet's edge without covering the sheet or leaving the screen.
        final topBarReserve = textScaler.scale(64).clamp(64.0, 120.0).toDouble();
        final sheetMax = side
            ? 0.85
            : ((h - topInset - Space.s8 - topBarReserve - Space.s8 - sosSize - Space.s12) / h).clamp(0.5, 0.85).toDouble();
        // The recenter chip grows with the text size; the zoom pair is 2 x 44 dp + 8.
        final recenterH = Space.s16 + textScaler.scale(18).clamp(18.0, 40.0).toDouble();
        // Zoom pair plus the map orientation (compass) button above it: 3 x 44 dp + 2 x 8.
        // Places button, orientation, zoom in, zoom out: 4 x 44 dp + 3 x 8.
        // 3.55 ride chat: the always-visible Chat button (56 dp + 8) on top in a group ride.
        final showChat = !convoy.isSoloRide && convoy.hasGroupFeatures;
        final zoomH = 44.0 + 8.0 + 44.0 + 8.0 + 44.0 + 8.0 + 44.0 + (showChat ? RideChatButton.size + 8.0 : 0.0);
        _navSide = side;
        _navPanelW = panelW;
        _navTopReserve = topInset + topBarReserve;
        _syncNavInsets();
        double floatingOpacity() => side ? 1.0 : _floatingOpacity(_sheetExpansion.value);

        return Stack(
          children: [
            // 1. Full-screen map (hero layer)
            _map(convoy, service, me, uid, routePoints, colors, statuses, lowData, now,
                guidance: guidance, incidents: incidents),
            // Frame ticker for the navigation camera (draws nothing).
            NavCameraTicker(controller: _navCam),

            // 2. Draggable Ride Sheet (bottom sheet in portrait, left panel in landscape)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: panelW,
              // Landscape: the panel's right edge is not the screen edge, so no right cutout inset.
              child: MediaQuery.removePadding(
                context: context,
                removeRight: side,
                child: RideSheet(
                key: _sheetKey,
                onTopChanged: (v) => _sheetTop.value = v,
                onTopSettled: (v) {
                  _sheetRestTop = v;
                  _syncNavInsets();
                },
                onExpansionChanged: (t) => _sheetExpansion.value = t,
                maxFraction: sheetMax,
                minFraction: null, // Anchors sheet to exact bottom of hands-free VOX/PTT bar; cannot drag down further
                header: _sheetHeader(convoy, me, snap, stoppedFor, now,
                    guardianOn: guardianOn,
                    meshPeersCount: service.p2pMeshPeerCount),
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

            // 3. Disciplined Top HUD Column (Top Bar, Toasts, Alerts, Fuel Stack - strictly non-overlapping)
            // Bounded by the sheet's top edge and clipped there, so alerts never cover the open
            // sheet; only this Positioned follows the drag (the column is built once per frame).
            // Empty space inside stays click-through to the map.
            ListenableBuilder(
              listenable: _sheetTop,
              builder: (_, hud) {
                final hudTop = topInset + Space.s8;
                final hudBottom = side ? bottomInset + Space.s8 : _clampSafe(_sheetTop.value + Space.s8, 0, h - hudTop - 48);
                return Positioned(
                  top: hudTop,
                  left: (side ? panelW : leftInset) + Space.s12,
                  right: rightInset + Space.s12,
                  bottom: hudBottom,
                  child: ClipRect(
                    clipper: const _HudBottomClipper(),
                    child: OverflowBox(
                      alignment: Alignment.topCenter,
                      minHeight: 0,
                      maxHeight: double.infinity,
                      child: hud,
                    ),
                  ),
                );
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  MinimalCockpitTopBar(
                    title: _topTitle(convoy, snap),
                    connection: connection,
                    gps: gps,
                    routeStatus: guidance?.statusLine ?? _guide.statusLine,
                    emergencyRoute: guidance?.statusLine != null,
                    onStopNavigation: guidance?.target == null ? null : guidance?.stop,
                    onBack: widget.embedded ? null : () => Navigator.of(context).maybePop(),
                    onNavigationTap: () => _launchOfflineNav(convoy, me, snap),
                    isTunnelCoasting: me.isTunnelCoasting,
                    subtitle: convoy.name,
                    roadName: _guide.currentRoadName,
                    speedKmh: RideFacts.hasPosition(me) ? me.speedKmh : null,
                    speedLimitKmh: speedLimit,
                    riderCount: convoy.riders.length,
                    isAirbagPaired: SmartAirbagBridgeService().isConnected ||
                        SmartAirbagBridgeService().connectionState == AirbagConnectionState.connected,
                    isRemotePaired: _bleRemote?.status == BleRemoteStatus.paired,
                    isOfflineMode: isOfflineMode,
                    onOfflineModeTap: () => _popup<void>('offline', () => _showOfflineExplainer(context, convoy, service)),
                  ),
                  // HUD Toast Banner (cleanly positioned under top bar, never covering it)
                  if (_hudToastMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(top: Space.s8),
                      child: Center(
                        child: CockpitHudToast(
                          message: _hudToastMessage!,
                          icon: _hudToastIcon ?? Icons.info_outline_rounded,
                          color: _hudToastColor,
                        ),
                      ),
                    ),
                  if (me.isTunnelCoasting)
                    Container(
                      key: const Key('tunnel_mode_banner'),
                      margin: const EdgeInsets.only(top: Space.s8),
                      padding: const EdgeInsets.symmetric(horizontal: Space.s12, vertical: Space.s8),
                      decoration: BoxDecoration(
                        color: AppTheme.card.withValues(alpha: 0.95),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.brand.withValues(alpha: 0.8), width: 1.5),
                        boxShadow: dsFloatingShadow(),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('🚇', style: TextStyle(fontSize: 14)),
                          const SizedBox(width: Space.s8),
                          Flexible(
                            child: Text(
                              'Tunnel Mode · GPS lost',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.label.copyWith(
                                color: AppTheme.accentText,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.2,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  // Public ride: road warnings ahead, requests to my ride, open chats, "Warn riders".
                  const PublicRideHud(),
                  if (connection != null && prefetcher != null)
                    CockpitDualStateBanner(
                      isOffline: true,
                      isPackActive: prefetcher.isRouteCached(convoy.routeLine),
                      peerCount: service.p2pMeshPeerCount,
                      margin: const EdgeInsets.only(top: Space.s8),
                    ),
                  const CockpitPermissionWarningBanner(
                    margin: EdgeInsets.only(top: Space.s8),
                  ),
                  // In-cockpit alert slot
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
                      child: Padding(
                        padding: const EdgeInsets.only(top: Space.s4),
                        child: TextButton(
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 40),
                            backgroundColor: AppTheme.card,
                            foregroundColor: AppTheme.accentText,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(color: AppTheme.border, width: 2),
                            ),
                          ),
                          onPressed: () => RiderHomeScreen.selectTab(context, HomeTab.alerts),
                          child: Text('+$extra more', maxLines: 1, style: AppText.caption.copyWith(color: AppTheme.accentText, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    )
                  else if (topSlot == null && _activeAlertCount > 0)
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: Padding(
                        padding: const EdgeInsets.only(top: Space.s4),
                        child: TextButton.icon(
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 40),
                            backgroundColor: AppTheme.card,
                            foregroundColor: AppTheme.accentText,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(color: AppTheme.border, width: 2),
                            ),
                          ),
                          onPressed: () => RiderHomeScreen.selectTab(context, HomeTab.alerts),
                          icon: const Icon(Icons.notifications_none_rounded, size: 16),
                          label: Text('$_activeAlertCount in notifications', style: AppText.caption.copyWith(color: AppTheme.accentText, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ),
                  // Minimal speed warning if near/over speed limit
                  if (showSpeed) ...[
                    const SizedBox(height: Space.s8),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: MinimalSpeedAlert(speedKmh: me.speedKmh, limitKmh: speedLimit),
                    ),
                  ],
                  // Disciplined right-side fuel & action stack (flows under top bar & alerts without
                  // collision); fades out with the other floating controls as the sheet opens.
                  ValueListenableBuilder<double>(
                    valueListenable: _sheetExpansion,
                    builder: (_, t, stack) => _fade(side ? 1.0 : _floatingOpacity(t), stack!),
                    child: Builder(
                    builder: (ctx) {
                      final safety = ctx.watch<SafetyService?>();
                      return Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: Padding(
                          padding: const EdgeInsets.only(top: Space.s8),
                          child: CockpitActionStack(
                            convoy: convoy,
                            me: me,
                            essentialsService: _essentials,
                            estimatedUsableKm: safety?.estimatedUsableKm,
                            isLead: lead,
                            onAddStationStop: (station) async {
                              final distM = (station.routePositionM > (_essentials?.progressM ?? 0))
                                  ? (station.routePositionM - (_essentials?.progressM ?? 0))
                                  : station.accessDistanceM;
                              await _autoRouteToFuel(service, me, lat: station.lat, lng: station.lng,
                                  name: station.name.isEmpty ? 'Petrol pump' : station.name, distM: distM);
                            },
                            onFocusLocation: (lat, lng) => _focus(lat, lng),
                            onOpenFuelSheet: () => _popup<void>('fuel', () => showFuelSheet(context)),
                            onOpenStopsSheet: () => _openStops(convoy),
                          ),
                        ),
                      );
                    },
                    ),
                  ),
                ],
              ),
            ),

            // 5. Floating Recenter Chip (only when the map is panned away from the rider). Right
            // side, riding just above the sheet's top edge in portrait (bottom corner in landscape),
            // fading out as the sheet opens so it never sits over the sheet's content.
            if (!_autoFollow)
              ListenableBuilder(
                listenable: _sheetMotion,
                builder: (_, chip) {
                  final base = side ? bottomInset + Space.s16 : _sheetTop.value + Space.s12;
                  return Positioned(
                    right: rightInset + Space.s16,
                    bottom: _clampSafe(base, bottomInset + Space.s12, h - recenterH - topInset - Space.s16),
                    child: _fade(floatingOpacity(), chip!),
                  );
                },
                child: Material(
                  color: AppTheme.card.withAlpha(230),
                  borderRadius: BorderRadius.circular(24),
                  elevation: 4,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: () => _setAutoFollow(true),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Space.s16, vertical: Space.s8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.my_location_rounded, size: 18, color: AppTheme.brand),
                          const SizedBox(width: Space.s8),
                          Text(
                            'RECENTER',
                            maxLines: 1,
                            style: AppText.label.copyWith(
                              color: AppTheme.brand,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            // 6. Floating Zoom Controls (+ / -), stacked above the recenter chip when it shows
            // (in landscape too: they used to overlap it there).
            ListenableBuilder(
              listenable: _sheetMotion,
              builder: (_, zoom) {
                final recenterOffset = _autoFollow ? 0.0 : recenterH + Space.s8;
                final base = side ? bottomInset + Space.s16 : _sheetTop.value + Space.s12;
                return Positioned(
                  right: rightInset + Space.s16,
                  bottom: _clampSafe(base + recenterOffset, bottomInset + Space.s12, h - zoomH - topInset - Space.s16),
                  child: _fade(floatingOpacity(), zoom!),
                );
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showChat) ...[
                    RideChatButton(unread: service.unreadChat(convoy.groupId), onTap: () => _openChat(convoy, me)),
                    const SizedBox(height: 8),
                  ],
                  if (_placesFor(lowData) case final places?) ...[
                    PlacesMapButton(
                      service: places,
                      riderStopsSwitch: true, // 3.56: "Where riders stop" on the ride map (off by default)
                      usableKm: () => context.read<SafetyService?>()?.estimatedUsableKm,
                      marginKm: () => context.read<SettingsService?>()?.fuelProfile.marginKm ?? 0,
                    ),
                    const SizedBox(height: 8),
                  ],
                  MapOrientationButton(controller: _navCam),
                  const SizedBox(height: 8),
                  _MapZoomButton(
                    key: const Key('cockpit_zoom_in_button'),
                    icon: Icons.add_rounded,
                    tooltip: 'Zoom in',
                    onTap: () {
                      // Following: shift the speed zoom instead of fighting the camera.
                      if (_autoFollow) {
                        _navCam.nudgeZoom(1.0);
                        return;
                      }
                      try {
                        _mapController.move(_mapController.camera.center, (_mapController.camera.zoom + 1.0).clamp(3.0, 19.0));
                      } catch (_) {}
                    },
                  ),
                  const SizedBox(height: 8),
                  _MapZoomButton(
                    key: const Key('cockpit_zoom_out_button'),
                    icon: Icons.remove_rounded,
                    tooltip: 'Zoom out',
                    onTap: () {
                      if (_autoFollow) {
                        _navCam.nudgeZoom(-1.0);
                        return;
                      }
                      try {
                        _mapController.move(_mapController.camera.center, (_mapController.camera.zoom - 1.0).clamp(3.0, 19.0));
                      } catch (_) {}
                    },
                  ),
                ],
              ),
            ),

            // 7. Hold-to-SOS Button: always on top of the map and always tappable. In portrait it
            // rides just above the sheet's top edge; the sheet's largest size leaves room for it
            // under the top bar, so it never covers the sheet's content or leaves the screen.
            ValueListenableBuilder<double>(
              valueListenable: _sheetTop,
              builder: (_, top, sos) {
                if (side) {
                  return Positioned(
                    left: panelW + Space.s12,
                    bottom: bottomInset + Space.s12,
                    child: sos!,
                  );
                }
                return Positioned(
                  left: leftInset + Space.s12,
                  bottom: _clampSafe(top + Space.s12, bottomInset + Space.s12, h - sosSize - topInset - Space.s8),
                  child: sos!,
                );
              },
              child: RideSosButton(onTriggered: () => _triggerSos(service, auth)),
            ),

            // 8. Draggable CoRoute Orbit Control FAB & In-Cockpit Quick Access HUD Popup
            CorouteOrbitControl(
              sheetHeight: side ? null : _sheetTop,
              sheetExpansion: side ? null : _sheetExpansion,
              // Keeps the Orbit button clear of SOS (left) and the zoom / recenter stack (right).
              sheetClearance: Space.s12 + zoomH + Space.s8 + recenterH + Space.s8,
              leftInset: side ? panelW : leftInset,
              // A solo ride (Community host) shows no Intercom or Group tiles.
              isSolo: convoy.isSoloRide,
              onIntercomTap: () {
                final intercom = context.read<IntercomService?>();
                if (intercom != null) {
                  if (intercom.isMicMuted) {
                    intercom.setMicMuted(false);
                    if (intercom.mode == IntercomMode.vox) {
                      intercom.startVox();
                      _showHudToast('Intercom: VOX Hands-free Active', Icons.record_voice_over_rounded, AppTheme.accentText);
                    } else {
                      _showHudToast('Intercom: Hold to Talk Ready', Icons.mic_rounded, AppTheme.accentText);
                    }
                  } else {
                    intercom.setMicMuted(true);
                    _showHudToast('Intercom: Mic Muted', Icons.mic_off_rounded, AppTheme.sos);
                  }
                }
              },
              // Never a one-tap send: the hold screen asks for the 1.5 s hold first.
              onSosTap: () {
                if (!SosHoldScreen.isOpen) _openSosHold(service, auth);
              },
              onGroupTap: () => _popup<void>('group', () => showGroupSettings(context, convoyId: widget.convoyId)),
              onFuelTap: () => _popup<void>('fuel', () => showFuelSheet(context)),
              onRouteTap: _openEssentials,
              onGuardianTap: () {
                _popup<void>('guardian', () => showGuardianSheet(context, groupId: convoy.groupId));
              },
              onMoreTap: () {
                final settings = context.read<SettingsService?>();
                final intercom = context.read<IntercomService?>();
                _popup<void>('quick_settings', () => GloveQuickSettingsModal.show(
                  context,
                  settingsService: settings,
                  intercomService: intercom,
                  keepScreenOn: _keepScreenOn,
                  onToggleKeepScreenOn: _toggleKeepScreenOn,
                  groupId: convoy.groupId,
                  onOpenGuardian: () {
                    _popup<void>('guardian', () => showGuardianSheet(context, groupId: convoy.groupId));
                  },
                  onOpenFuel: () => _popup<void>('fuel', () => showFuelSheet(context)),
                  onLaunchOfflineNav: () => _launchOfflineNav(convoy, me, snap),
                  onSettingToggled: (name, isEnabled) => _showHudToast(
                    '$name: ${isEnabled ? "ON" : "OFF"}',
                    Icons.tune_rounded,
                    isEnabled ? AppTheme.accentText : AppTheme.muted,
                  ),
                ));
              },
            ),
          ],
        );
      }),
    );
    // Always the same tree shape, so the map and the sheet keep their state when the Ride AOD comes and goes.
    // Under the AOD the cockpit is not painted and its animations pause (less GPU work, a cooler phone).
    return Stack(
      fit: StackFit.expand,
      children: [
        TickerMode(enabled: !_aodOn, child: Offstage(offstage: _aodOn, child: cockpit)),
        if (_aodOn) Positioned.fill(child: _aodView(convoy, me, uid, snap, service, now)),
      ],
    );
  }

  /// The Ride AOD content: speed, next turn, the leader (or the group), time, battery and the SOS hint.
  Widget _aodView(ConvoyModel convoy, RiderModel me, String uid, RideSnapshot snap, ConvoyService service, int now) {
    NextTurn? turn;
    try {
      final line = _guide.active;
      final along = line?.matched?.alongM;
      final steps = _guide.activeRoute?.steps ?? const [];
      if (line != null && along != null) turn = NextTurn.compute(steps: steps, line: line, alongM: along);
    } catch (_) {
      turn = null;
    }
    double? leaderM;
    double? leaderRel;
    String? group;
    if (!convoy.isSolo) {
      final lead = RideFacts.findLead(convoy);
      if (lead != null && lead.userId != uid && RideFacts.hasPosition(lead) && RideFacts.hasPosition(me)) {
        leaderM = GeoMath.haversine(me.lat, me.lng, lead.lat, lead.lng);
        final heading = LiveCockpitMapScreen.myHeading(me, null);
        leaderRel = GeoMath.bearing(me.lat, me.lng, lead.lat, lead.lng) - heading;
      }
      final riding = RideFacts.ridingCount(convoy.riders.values, nowMs: now);
      group = '$riding of ${convoy.riders.length} riding';
    }
    var battery = -1;
    var charging = false;
    try {
      battery = service.currentBatteryLevel;
      charging = service.isCharging;
    } catch (_) {}
    return RideAodView(
      speedKmh: me.speedKmh,
      turn: turn,
      leaderDistanceM: leaderM,
      leaderRelativeBearing: leaderRel,
      groupLine: group,
      batteryPercent: battery,
      charging: charging,
      onHoldSos: () {
        final auth = _auth;
        if (auth != null && !SosHoldScreen.isOpen) _openSosHold(service, auth);
      },
      onWake: () {
        _lastTouchMs = DateTime.now().millisecondsSinceEpoch;
        _syncWakelock();
      },
    );
  }

  Widget _ended(BuildContext context) {
    // 3.55: the place review question after the ride (places I stayed at and did not rate in the
    // cockpit; at most 2, skippable; admin switches placeReviews and reviewPrompt).
    final places = context.read<PlaceReviewService?>();
    final placesOn = context.featureOn('placeReviews') && context.featureOn('reviewPrompt');
    final ended = EmptyState(
      icon: Icons.flag_rounded,
      title: 'Ride ended',
      message: 'The ride is saved in your trips.',
      primaryLabel: widget.embedded ? null : 'Back',
      onPrimary: widget.embedded ? null : () => Navigator.of(context).maybePop(),
    );
    return Scaffold(
      backgroundColor: AppTheme.map,
      body: SafeArea(
        child: places == null || !placesOn
            ? ended
            : Column(children: [
                Expanded(child: ended),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 600),
                    child: AfterRidePlaceReviews(service: places, enabled: placesOn),
                  ),
                ),
              ]),
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

  Widget _sheetHeader(ConvoyModel convoy, RiderModel me, RideSnapshot snap, Duration? stoppedFor, int now, {bool guardianOn = true, int meshPeersCount = 0, double bottomInset = 0.0}) {
    void toggle() => _sheetKey.currentState?.toggle();
    final next = snap.nextStop;
    return Padding(
      // Same side inset as the sheet body ([RideSheet.hPad]) so the stats, the talk bar and the
      // expanded content share one edge. The sheet itself adds the navigation bar inset.
      padding: EdgeInsets.fromLTRB(RideSheet.hPad, 0.0, RideSheet.hPad, Space.s8 + bottomInset),
      child: Column(
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
              onTellWhy: () => _popup<void>('status', () => RiderStatusSheet.show(context, userId: me.userId)),
              onTap: toggle,
              isSolo: convoy.isSoloRide,
            )
          else
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: toggle,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6.0),
                child: MinimalCockpitStatsRow(
                  convoy: convoy,
                  me: me,
                  snap: snap,
                  eta: _eta(snap.eta),
                  guardianOn: guardianOn,
                  now: now,
                  meshPeersCount: meshPeersCount,
                ),
              ),
            ),
          // Talk is a group feature: no talk bar in a solo ride (Community host).
          if (convoy.hasGroupFeatures)
            MinimalHoldToTalkBar(
              convoy: convoy,
              me: me,
            ),
        ],
      ),
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
    final chatQueued = service.outbox.where((o) => o.type == 'CHAT' && o.groupId == convoy.groupId).length;
    final hasDest = RideFacts.hasDestination(convoy);
    // "Dark in 40 min" during the last hour of daylight (null after dark or without a position).
    final darkLine = RideFacts.hasPosition(me) ? DarkCheck.rideLine(now: DateTime.fromMillisecondsSinceEpoch(now), lat: me.lat, lng: me.lng) : null;
    return [
      // 1. Compact Ride Summary
      Semantics(
        header: true,
        child: Text(convoy.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title),
      ),
      if (paused)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('Group ride paused', style: AppText.label.copyWith(color: StatusColors.warning, fontWeight: FontWeight.bold)),
        ),
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
      const SizedBox(height: Space.s12),

      // 2. Glove Quick Actions Grid (Essential in-ride controls, >=56dp targets)
      Builder(
        builder: (ctx) {
          final safety = ctx.watch<SafetyService?>();
          final estimate = safety?.estimatedUsableKm;
          final nearestFuel = _essentials?.upcoming.where((e) => e.category == 'FUEL').firstOrNull;
          final rawAheadM = nearestFuel?.aheadM(_essentials?.progressM ?? 0);
          final fuelAheadM = nearestFuel != null
              ? ((rawAheadM != null && rawAheadM > 0)
                  ? rawAheadM
                  : (me.lat != 0 && me.lng != 0 ? GeoMath.haversine(me.lat, me.lng, nearestFuel.lat, nearestFuel.lng) : null))
              : null;
          // "CHECK" when the sensors are missing or crash detection is off (tap opens the phone check).
          final crashOn = ctx.select<SettingsService?, bool>((s) => s?.crashDetection ?? true);
          final isSafetyHealthy = crashOn && !(safety?.isSensorUnavailable ?? false);
          // Prefer the next station that sells this bike's fuel, from the map places on the phone.
          final ahead = safety?.fuelAhead?.stops;
          final matchedFuel = ahead?.where((s) => s.confirmed).firstOrNull ?? ahead?.firstOrNull;

          return GloveQuickActionGrid(
            convoy: convoy,
            me: me,
            onOpenIntercom: () => _popup<void>('intercom', () => IntercomOptions.show(context)),
            onOpenStops: () => _openStops(convoy),
            onTellWhy: () => _popup<void>('status', () => RiderStatusSheet.show(context, userId: me.userId)),
            stopReasonText: riderReasonText(me),
            onOpenFuel: () => _openNearbyFuelSheet(service, me),
            estimatedUsableKm: estimate,
            nearestFuelName: matchedFuel?.poi.displayName ?? nearestFuel?.name,
            nearestFuelAheadM: matchedFuel != null ? matchedFuel.distanceKm * 1000 : fuelAheadM,
            onOpenMessages: () => _openChat(convoy, me),
            chatQueued: chatQueued,
            // "Safety health" opens the phone check (permissions, battery, alerts, sensors), not Settings.
            onOpenSafetyStatus: () => _popup<void>('safety', () => PreRidePhoneCheckScreen.open(context)),
            isSafetyHealthy: isSafetyHealthy,
            isSolo: convoy.isSolo,
            groupFeatures: convoy.hasGroupFeatures,
          );
        },
      ),
      const SizedBox(height: Space.s12),

      // 3. Convoy Status & Compact Roster
      if (!convoy.isSolo) ...[
        RollCallCard(convoy: convoy, nowMs: now), // 3.55 start and arrival roll call
        CompactConvoyRoster(
          convoy: convoy,
          me: me,
          spreadM: snap.spreadM,
          colors: colors,
          statuses: statuses,
          nowMs: now,
          onTapRider: _openRider,
          onOpenManageRiders: () => _popup<void>('riders', () => RiderManagementSheet.show(
            context,
            convoy: convoy,
            me: me,
            onShareInvite: () => _shareInvite(convoy),
            onCopyCode: () => _copyCode(convoy),
          )),
          isLead: lead,
        ),
        const SizedBox(height: Space.s12),
      ],

      // 4. Grouped Secondary Management
      SecondaryManagementGroup(
        convoy: convoy,
        isLead: lead,
        onOpenManageRiders: () => _popup<void>('riders', () => RiderManagementSheet.show(
          context,
          convoy: convoy,
          me: me,
          onShareInvite: () => _shareInvite(convoy),
          onCopyCode: () => _copyCode(convoy),
        )),
        onOpenAudioSettings: () => _popup<void>('intercom', () => IntercomOptions.show(context)),
        onOpenGroupSettings: () => _popup<void>('group', () => showGroupSettings(context, convoyId: convoy.groupId)),
        onOpenGuardian: () => _popup<void>('guardian', () => showGuardianSheet(context, groupId: convoy.groupId)),
        onOpenSafetyStatus: () => _popup<void>('safety', () => PreRidePhoneCheckScreen.open(context)),
        onOpenSettings: () => _popup<void>('settings', () => SettingsScreen.open(context)),
        onShareEta: hasDest ? () => _shareEta(convoy, snap.remainingM, snap.eta) : null,
        etaSubtitle: _etaShareSubtitle(snap),
        isSolo: convoy.isSolo,
        groupFeatures: convoy.hasGroupFeatures,
      ),
      const SizedBox(height: Space.s16),

      // 5. Ride Lifecycle Controls
      RideLifecycleBar(
        isLead: lead,
        canEnd: service.canEndTrip,
        isPaused: paused,
        onTogglePause: () => service.updateTripState(paused ? 'STARTED' : 'PAUSED'),
        onEndRide: () => _endRide(service),
        onLeaveRide: () => _leaveRide(service, uid),
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
    _popup<void>('stops', () => showAppSheet<void>(
      context,
      title: 'Route and stops',
      isScrollControlled: true,
      builder: (ctx) => Consumer<ConvoyService>(
        builder: (_, svc, _) => RouteStopsPanel(convoy: svc.allConvoys[convoy.groupId] ?? convoy),
      ),
    ));
  }

  void _launchOfflineNav(ConvoyModel convoy, RiderModel me, RideSnapshot snap) {
    final next = snap.nextStop;
    final hasDest = RideFacts.hasDestination(convoy);

    final double destLat;
    final double destLng;
    final String label;

    if (next != null) {
      destLat = next.lat;
      destLng = next.lng;
      label = next.name.isEmpty ? 'Next stop' : next.name;
    } else if (hasDest) {
      destLat = convoy.destinationLat;
      destLng = convoy.destinationLng;
      label = convoy.destinationName.isEmpty ? 'Destination' : convoy.destinationName;
    } else {
      _showHudToast('No destination set for offline routing', Icons.navigation_outlined, AppTheme.warnText);
      return;
    }

    _showHudToast('Navigating to $label', Icons.navigation_rounded, AppTheme.accentText);
    // 3.55 hand-off to Google Maps / Mappls (Settings > Navigation app). The ride, intercom and
    // safety keep running in the background; the ride notification brings the rider back.
    navigateTo(
      destLat,
      destLng,
      label: label,
      startLat: RideFacts.hasPosition(me) ? me.lat : null,
      startLng: RideFacts.hasPosition(me) ? me.lng : null,
      twoWheeler: NavHandoff.isTwoWheeler(me.vehicleKind),
    ).then((ok) {
      if (!ok && mounted) _showHudToast('No navigation app found', Icons.navigation_outlined, AppTheme.warnText);
    });
  }

  Future<void> _showOfflineExplainer(BuildContext context, ConvoyModel convoy, ConvoyService service) {
    return showAppSheet<void>(
      context,
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(Space.s16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.warnTint,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppTheme.warnBorder),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.cloud_off_rounded, size: 14, color: AppTheme.warnText),
                        const SizedBox(width: 4),
                        Text('OFFLINE MODE', style: AppText.overline.copyWith(color: AppTheme.warnText, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: Space.s12),
              Text(
                'Offline Group Status',
                style: AppText.title.copyWith(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: Space.s4),
              Text(
                'No internet. Your ride is kept on the phone.',
                style: AppText.caption.copyWith(color: AppTheme.text2, height: 1.3),
              ),
              const SizedBox(height: Space.s16),
              Text('PRESERVED & WORKING OFFLINE', style: AppText.overline.copyWith(color: AppTheme.accentText)),
              const SizedBox(height: Space.s8),
              _offlineBullet(Icons.check_circle_rounded, AppTheme.accentText, 'Speed, tunnel mode and offline maps'),
              _offlineBullet(Icons.check_circle_rounded, AppTheme.accentText, 'Last known spots of your group'),
              _offlineBullet(Icons.check_circle_rounded, AppTheme.accentText, 'Crash alerts and handlebar remote'),
              _offlineBullet(Icons.check_circle_rounded, AppTheme.accentText, 'Outbox queue: Messages and stop reasons queue for safe sync without duplicates'),
              _offlineBullet(Icons.check_circle_rounded, AppTheme.accentText, 'SOS: calls and texts work with phone signal'),
              const SizedBox(height: Space.s16),
              Text('TEMPORARILY UNAVAILABLE', style: AppText.overline.copyWith(color: AppTheme.warnText)),
              const SizedBox(height: Space.s8),
              _offlineBullet(Icons.remove_circle_outline_rounded, AppTheme.warnText, 'Live voice intercom streaming (microphone remains OFF by default)'),
              _offlineBullet(Icons.remove_circle_outline_rounded, AppTheme.warnText, 'Live spots of other riders'),
              _offlineBullet(Icons.remove_circle_outline_rounded, AppTheme.warnText, 'Instant mid-ride waypoint cloud push (queued for reconnection)'),
              _offlineBullet(Icons.remove_circle_outline_rounded, AppTheme.warnText, 'Ending group session on server (saved locally; cloud sync queued)'),
              const SizedBox(height: Space.s16),
              DsButton(
                label: 'Understood',
                onPressed: () => Navigator.pop(ctx),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _offlineBullet(IconData icon, Color color, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: Space.s8),
          Expanded(
            child: Text(text, style: AppText.caption.copyWith(color: AppTheme.accentText, height: 1.3)),
          ),
        ],
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
    return RepaintBoundary(
      child: FlutterMap(
        mapController: _mapController,
      options: MapOptions(
          minZoom: 3.0,
          maxZoom: 19.0,
          cameraConstraint: const CameraConstraint.containLatitude(),
        initialCenter: _initialCenter(me, convoy),
        initialZoom: (me.lat != 0 || me.lng != 0) ? 15.5 : 12,
        onPositionChanged: (pos, hasGesture) {
          _navCam.onCameraChanged(pos);
          // Any pan / pinch / twist by the rider pauses following; RECENTER resumes it.
          if (hasGesture && _autoFollow) _setAutoFollow(false);
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
              strokeWidth: 6,
              color: (!_guide.hasPersonalRoute && (convoy.route?.approximate ?? false))
                  ? AppTheme.brand.withOpacity(0.5)
                  : AppTheme.brand.withOpacity(0.9),
            ),
          ]),
        // Map places: icons from zoom 12, names from zoom 14, decluttered, nearest first.
        if (_placesFor(lowData) case final places?)
          MapPlacesLayer(
            service: places,
            riderLat: RideFacts.hasPosition(me) ? me.lat : null,
            riderLng: RideFacts.hasPosition(me) ? me.lng : null,
            routeLine: (_guide.active?.isUsable ?? false) ? _guide.active!.points : convoy.routeLine,
            groupFuelStops: [
              for (final s in convoy.plannedStops)
                if (s.category == 'FUEL') (lat: s.lat, lng: s.lng, name: s.name),
            ],
          ),
        // 3.56 (round 6): "Where riders stop" on the ride map: off by default, switched on in the
        // "Places on map" sheet, never while an alert is open (the map belongs to the emergency).
        ValueListenableBuilder<bool>(
          valueListenable: RiderStopsLivePref.on,
          builder: (context, on, _) => MarkerLayer(
            rotate: true,
            markers: RiderStopsLivePref.show(switchedOn: on, alertOpen: convoy.activeAlerts.isNotEmpty) && SafetyService.hasInstance
                ? riderStopMarkers(SafetyService.instance.intel.learnedStops)
                : const <Marker>[],
          ),
        ),
        if (_essentials != null && convoy.activeAlerts.isEmpty)
          // The next essentials on the route: medium discs with the category icon (3.55; were a small tag).
          MarkerLayer(rotate: true, markers: [for (final p in _essentials!.upcoming.take(3)) Marker(
            point: LatLng(p.lat, p.lng), width: 44, height: 44,
            child: Tooltip(
              message: '${p.name}, ${essentialCategories[p.category] ?? 'place'} on your route',
              child: Semantics(
                button: true,
                label: '${p.name}, ${essentialCategories[p.category] ?? 'place'} on your route',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _openEssentials,
                  child: Center(
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppTheme.brand,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 4, offset: Offset(0, 1))],
                      ),
                      child: Icon(essentialIcon(p.category), size: 21, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          )]),
        // The way to an emergency I navigate to (red), above the group route.
        if (navLine.length >= 2)
          PolylineLayer(polylines: [
            Polyline(points: navLine, strokeWidth: 5, color: StatusColors.critical.withOpacity(0.85)),
          ]),
        MarkerLayer(rotate: true, markers: [
          for (final s in convoy.plannedStops) _stopMarker(s),
          // My own fuel stop (3.55): marked from the moment I asked for it, until I reach or pass it.
          if (_guide.personalFuelStop != null)
            Marker(
              key: const ValueKey('personal_fuel_stop'),
              point: LatLng(_guide.personalFuelStop!.lat, _guide.personalFuelStop!.lng),
              width: 44,
              height: 44,
              child: Semantics(
                label: 'My fuel stop: ${_guide.personalFuelStop!.name}',
                child: Container(
                  decoration: BoxDecoration(
                    color: AppTheme.warnText,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 5, offset: Offset(0, 2))],
                  ),
                  child: const Icon(Icons.local_gas_station_rounded, size: 22, color: Colors.white),
                ),
              ),
            ),
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
        // Other riders glide between their updates (far ones simplified in a big group)...
        SmoothMarkerLayer(
          markers: [
            // 3.55: one marker per bike; a seated pillion rides on their rider's marker.
            for (final e in _bikePlan(convoy, uid).values)
              if (e.markerId != uid) _riderMarker(convoy.riders[e.markerId]!, uid, colors, statuses, now, bike: e),
          ],
          focus: _navCam.pose.value?.point ?? ((me.lat != 0 || me.lng != 0) ? LatLng(me.lat, me.lng) : null),
          clusterColor: AppTheme.brand,
          onClusterTap: (center, _) => _zoomToCluster(center),
        ),
        // ...and I am drawn on top, exactly where the navigation camera puts me.
        SmoothMarkerLayer(
          markers: [
            for (final e in _bikePlan(convoy, uid).values)
              if (e.markerId == uid) _riderMarker(convoy.riders[e.markerId]!, uid, colors, statuses, now, bike: e),
          ],
          driverId: uid,
          driverPose: _navCam.pose,
        ),
        // Public rides nearby, road warnings ahead, a chat partner's shared location (below the safety markers).
        PublicRideMarkerLayer(onTapRide: (r) => _popup<void>('public_ride', () => showPublicRideSheet(context, r))),
        MarkerLayer(rotate: true, markers: _safetyMarkers(convoy, service, me, now, guidance: guidance, incidents: incidents)),
      ],
    ),
  );
}

  /// One rider for the smooth marker layers: the full marker (or the ghost
  /// when their signal dropped), a heading arrow while moving, and a small dot
  /// for when they are far away in a big group.
  /// 3.55 bike markers: which riders get a marker and who sits on which bike (pillions merged
  /// while the admin switch `pillionSeat` is on).
  Map<String, BikeMarkerEntry> _bikePlan(ConvoyModel convoy, String uid) => BikeMarkerPlan.of(
        convoy.riders,
        myUserId: uid,
        hasPosition: RideFacts.hasPosition,
        mergePillions: context.featureOn('pillionSeat'),
      );

  SmoothMarker _riderMarker(RiderModel r, String uid, Map<String, Color> colors, Map<String, RiderStatus> statuses, int now, {BikeMarkerEntry? bike}) {
    final isMe = isMeRider(r, uid);
    // The bike's look comes from its rider (on the pillion's own phone the pair sits at my position).
    final bikeRider = bike?.bikeRider ?? r;
    final pillion = bike?.pillion;
    final ghost = !isMe && GhostRiderMarker.isDropped(r, now);
    final status = statuses[r.userId] ?? RiderStatus.offline;
    final color = colors[r.userId];
    final selected = _selectedRiderId == r.userId;
    final moving = !ghost && !status.isStale && r.speedKmh >= 5.0;
    return SmoothMarker(
      id: r.userId,
      point: LatLng(r.lat, r.lng),
      // 3.56: the 3D bike itself points the way (no separate arrow); stopped bikes keep their heading.
      heading: _headingHold.update(r.userId, r.heading, moving || isMe ? r.speedKmh : 0),
      showHeading: false,
      headingRadius: isMe ? 31.0 : 25.0,
      headingColor: isMe ? AppTheme.brand : (color ?? AppTheme.brand),
      width: 144,
      height: 140,
      pinned: isMe || selected || ghost || r.role == 'LEAD' || r.statusReason.isNotEmpty,
      child: ghost
          ? GhostRiderMarker(
              rider: r,
              nowMs: now,
              isMe: false,
              onTap: () => _openRider(r),
            )
          : RiderMapMarker(
              rider: r,
              isMe: isMe,
              color: color,
              status: status,
              selected: selected,
              nowMs: now,
              bikeRider: bikeRider,
              pillion: pillion,
              onTap: () => _openRider(bikeRider),
            ),
      compactSize: 36,
      compact: (isMe || ghost)
          ? null
          : CompactBikeDot(
              vehicleKind: bikeRider.vehicleKind,
              vehicleColor: bikeRider.vehicleColor,
              color: color ?? AppTheme.brand,
              twoUp: pillion != null,
              semanticsLabel: '${bikeRider.name}${pillion == null ? '' : ' with pillion ${pillion.name}'}, ${riderMapSpeedLabel(r, status: status, nowMs: now)}',
              onTap: () => _openRider(bikeRider),
            ),
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
    // FEAT-02: Map markers for collective road hazards
    for (final rh in service.roadHazards) {
      final d = myPos ? GeoMath.haversine(me.lat, me.lng, rh.lat, rh.lng) : null;
      // 3.55: saved reports along the route are drawn only near me (the map stays readable).
      if (rh.fromHistory && (d == null || d > 5000)) continue;
      out.add(Marker(
        point: LatLng(rh.lat, rh.lng),
        width: HazardMarker.width,
        height: HazardMarker.height,
        child: HazardMarker(
          // 3.55: "Pothole · 300 m", "Speed breaker", "Rough road".
          label: '${rh.classification.label}${d == null ? '' : ' · ${formatDistanceRounded(d)}'}',
          level: HazardLevel.active,
        ),
      ));
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
            color: AppTheme.card,
            shape: BoxShape.circle,
            border: Border.all(color: ring, width: 3),
            boxShadow: dsFloatingShadow(),
          ),
          child: Icon(s.isVisited ? Icons.check_rounded : kind.icon, size: 18, color: s.isVisited ? ring : AppTheme.text),
        ),
      ),
    );
  }
}

/// A rider on the map (canvas: a 44 dp avatar with a 3 px ring, "you" as a
/// solid teal 56 dp avatar, and a small solid label pill with the name and
/// speed). Uses the existing convoy updates; tapping opens the rider card.
class RiderMapMarker extends StatelessWidget {
  final RiderModel rider;
  final bool isMe;
  final Color? color;
  final RiderStatus status;
  final bool selected;
  final int nowMs;
  final VoidCallback onTap;

  /// 3.55 bike markers: the rider of the bike drawn (its type and colour; [rider] when null) and
  /// the pillion on it (two people on one marker; no separate dot for the pillion).
  final RiderModel? bikeRider;
  final RiderModel? pillion;

  const RiderMapMarker({
    super.key,
    required this.rider,
    required this.isMe,
    required this.color,
    required this.status,
    required this.selected,
    required this.nowMs,
    required this.onTap,
    this.bikeRider,
    this.pillion,
  });

  @override
  Widget build(BuildContext context) {
    final bike = bikeRider ?? rider;
    final mePillion = isMe && bike.userId != rider.userId;
    final first = bike.name.split(' ').first;
    final pillionFirst = pillion == null ? '' : (mePillion ? 'You' : pillion!.name.split(' ').first);
    final isTunnel = rider.isTunnelCoasting;
    final isMesh = rider.isMeshPeer;
    final speedBadge = riderMapSpeedLabel(rider, status: status, nowMs: nowMs);
    final isMoving = speedBadge.endsWith('km/h') && rider.speedKmh >= 5;
    final isLead = rider.role == 'LEAD';
    final whoOne = isMe && !mePillion ? 'You' : (isLead ? 'LEAD · $first' : first);
    final who = pillion == null ? whoOne : '$whoOne + $pillionFirst';
    final label = isTunnel ? '$who · Tunnel' : (isMesh ? '$who · Nearby' : who);

    // Ring: the rider's colour while moving (teal for the lead), amber while not.
    final ring = !isMoving && !isMe
        ? AppTheme.warnText
        : (isTunnel ? AppTheme.accentText : (isLead ? AppTheme.accentText : (color ?? AppTheme.accentText)));
    // Pill: dark for me, teal for the lead, amber when not moving, the rider's colour otherwise.
    final pill = isMe
        ? AppTheme.text
        : (!isMoving ? AppTheme.warnText : (isLead ? AppTheme.brand : (color ?? AppTheme.brand)));
    final pillText = isMe && !AppTheme.isLight ? AppTheme.bg : Colors.white;
    final avatarSize = isMe ? 56.0 : 44.0;

    final reason = rider.statusReason.isEmpty ? '' : RiderStatusSheet.getStatusLabel(rider.statusReason);
    return Semantics(
      container: true,
      button: true,
      label: bikeMarkerLabel(
        riderName: bike.name,
        model: bike.vehicleModel,
        colour: bike.vehicleColor,
        pillionName: pillion?.name,
        speed: speedBadge,
        status: status.label,
        reason: reason,
        me: isMe,
        mePillion: mePillion,
      ),
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: onTap,
        // The avatar sits on the rider's position (the marker box's centre); the pill hangs under it.
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            // 3.55: the bike (its shape and colour, two people with a pillion) instead of a round avatar.
            BikeMarkerBadge(
              vehicleKind: bike.vehicleKind,
              vehicleColor: bike.vehicleColor,
              fallbackColor: color ?? AppTheme.brand,
              ring: isMe ? AppTheme.brand : ring,
              statusColor: status.color,
              height: isMe ? 46 : 40, // 3.56: 3D bike box 65 / 57 px (the halo stays above the label)
              twoUp: pillion != null,
              heading: rider.heading,
              cue: BikeMarkerCue.of(
                sos: status == RiderStatus.emergency,
                stale: status.isStale,
                warning: status == RiderStatus.lowGps || rider.statusReason.isNotEmpty,
                stopped: !isMoving && !isMe,
              ),
              me: isMe,
              selected: selected,
              roleLetter: bike.role == 'LEAD' ? 'L' : (bike.role == 'SWEEPER' ? 'S' : ''),
              roleColor: AppTheme.brand,
            ),
            Positioned(
              top: 70 + avatarSize / 2 + 4,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 120),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: pill, borderRadius: BorderRadius.circular(8)),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textScaler: TextScaler.noScaling,
                        style: TextStyle(color: pillText, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5, height: 1.2),
                      ),
                      Text(
                        speedBadge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textScaler: TextScaler.noScaling,
                        style: TextStyle(color: pillText.withOpacity(0.85), fontSize: 10, fontWeight: FontWeight.w700, height: 1.2),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Never present a disconnected, estimated or invalid reading as live speed.
String riderMapSpeedLabel(RiderModel rider, {required RiderStatus status, required int nowMs}) {
  final age = nowMs - rider.lastSeenEpochMs;
  if (rider.lastSeenEpochMs <= 0 || age < 0 || age >= RideThresholds.staleAfter.inMilliseconds || status.isStale) {
    return 'Speed unavailable';
  }
  if (rider.isTunnelCoasting || status == RiderStatus.lowGps || !rider.speedKmh.isFinite || rider.speedKmh < 0) {
    return 'Speed unavailable';
  }
  return '${rider.speedKmh.round()} km/h';
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
      child: SOSButton(onTriggered: onTriggered, size: 68),
    );
  }
}

/// "Is this rider me?" by account id only (two riders may share a name).
bool isMeRider(RiderModel r, String myUserId) => myUserId.isNotEmpty && r.userId == myUserId;

/// Clips the top HUD only at its bottom edge (the sheet's top), leaving room for the cards'
/// shadows on the other three sides.
class _HudBottomClipper extends CustomClipper<Rect> {
  const _HudBottomClipper();

  @override
  Rect getClip(Size size) => Rect.fromLTRB(-64, -64, size.width + 64, size.height);

  @override
  bool shouldReclip(covariant _HudBottomClipper oldClipper) => false;
}

class _MapZoomButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _MapZoomButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.card.withAlpha(230),
      borderRadius: BorderRadius.circular(24),
      elevation: 4,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: SizedBox(
          // 3.56 audit A-01: 48 dp (gloves); was 44.
          width: 48,
          height: 48,
          child: Icon(icon, color: AppTheme.text, size: 24),
        ),
      ),
    );
  }
}

