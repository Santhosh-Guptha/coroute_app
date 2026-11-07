import 'data/services/ride_essentials_coordinator.dart';
import 'data/services/route_essentials_service.dart';
import 'data/services/fuel_sharing_binding.dart';
import 'data/services/fuel_settings_binding.dart';
import 'data/services/garage_binding.dart';
import 'data/services/garage_service.dart';
import 'data/services/phone_call_service.dart';
import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:url_launcher/url_launcher.dart';
import 'core/constants/app_constants.dart';
import 'data/local/review_prompt_store.dart';
import 'core/l10n/l10n.dart';
import 'core/constants/navigation_constants.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'core/ui/ui.dart';
import 'data/services/alert_service.dart';
import 'data/services/api_client.dart';
import 'data/services/feature_flags_service.dart';
import 'data/services/admin_warnings_service.dart';
import 'data/services/auth_service.dart';
import 'data/services/background_service.dart';
import 'data/services/p2p_mesh_service.dart';
import 'data/services/convoy_service.dart';
import 'data/services/geo_service.dart';
import 'data/services/intercom_service.dart';
import 'data/services/meta_service.dart';
import 'data/services/app_version_service.dart';
import 'data/services/device_diagnostic_service.dart';
import 'data/services/membership_service.dart';
import 'data/local/ride_stats_store.dart';
import 'data/local/sqflite_track_queue.dart';
import 'data/services/realtime_service.dart';
import 'data/services/ride_notification_service.dart';
import 'data/services/medical_id_lock_sync.dart';
import 'data/services/safety_native.dart';
import 'data/services/safety_service.dart';
import 'data/services/solo_guardian_service.dart';
import 'data/services/sos_battery_reserve.dart';
import 'data/services/settings_service.dart';
import 'data/services/tile_cache_service.dart';
import 'data/services/timeline_service.dart';
import 'data/services/public_ride_service.dart';
import 'data/services/track_recorder.dart';
import 'data/services/track_uploader.dart';
import 'data/services/trip_storage_service.dart';
import 'data/services/nav_voice.dart';
import 'data/services/voice_service.dart';
import 'data/services/weather_service.dart';
import 'data/services/permission_revocation_safety_service.dart';
import 'data/services/place_review_service.dart';
import 'data/services/group_safety_service.dart';
import 'data/services/map_places_service.dart';
import 'domain/notify/notification_snapshot.dart';
import 'presentation/auth/access_gate_screen.dart';
import 'presentation/ride/emergency_guidance.dart';
import 'presentation/safety/crash_alarm_host.dart';
import 'presentation/splash/splash_screen.dart';

/// Lets services navigate (sign-out on session expiry, deep links) without a BuildContext.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz_data.initializeTimeZones();
  BackgroundService.initCommunicationPort();
  // Portrait + landscape are both supported; layouts adapt to width.
  await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  // Light or dark is decided before the first frame, so there is no flash.
  await MetaService.readPackageInfo();
  final theme = ThemeController();
  await theme.load();
  // Another rider's SOS over the lock screen (Android full-screen intent, heads-up fallback).
  AlertService.urgentPoster = RideNotificationChannel.postUrgent;
  // The phone's language decides the safety texts when the setting is "System language".
  L10n.systemLanguage = WidgetsBinding.instance.platformDispatcher.locale.languageCode;
  // Data saver is known before the first frame, so the first ride already uses it.
  final settings = SettingsService();
  await settings.load();
  // Map tiles saved on the phone (3.16): best effort; without it maps use the network.
  try {
    final dir = await SafetyNative.cacheDir();
    if (dir != null) TileCache.instance = await TileCache.open('$dir/tiles');
  } catch (_) {
    TileCache.instance = null;
  }
  // Rider-only ride numbers (hard stops) older than 90 days go; nothing else to maintain.
  RideStatsStore.prune().ignore();
  // Install time for the store-rating prompt (never in the first days after install).
  ReviewPromptStore.markFirstSeen().ignore();
  SystemChrome.setSystemUIOverlayStyle(AppTheme.overlayStyle);
  runApp(CoRouteApp(theme: theme, settings: settings));
}

class CoRouteApp extends StatelessWidget {
  final ThemeController theme;
  final SettingsService? settings;
  const CoRouteApp({super.key, required this.theme, this.settings});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeController>.value(value: theme),
        ChangeNotifierProvider<SettingsService>(create: (_) => settings ?? (SettingsService()..load())),
        ChangeNotifierProvider(create: (_) => ApiClient()),
        ChangeNotifierProvider<DeviceDiagnosticService>(create: (ctx) => DeviceDiagnosticService(apiClient: ctx.read<ApiClient>())..loadCachedReport()),
        // Weather along the route (3.16): two small requests per ride through the gateway.
        ChangeNotifierProvider<WeatherService>(create: (ctx) => WeatherService(ctx.read<ApiClient>(), ctx.read<SettingsService>())),
        // Route map tiles saved before the ride (3.16): one bounded job, on Wi-Fi or by a tap.
        ChangeNotifierProvider<TilePrefetcher>(create: (_) => TilePrefetcher(TileCache.instance)),
        ChangeNotifierProvider(create: (ctx) {
          final api = ctx.read<ApiClient>();
          final rt = RealtimeService();
          // A refreshed session token is used for the next reconnect.
          api.addListener(() => rt.updateToken(api.token));
          // The gateway answered over HTTP, or the app is back in front: a socket waiting out
          // its backoff reconnects now (no-op when connected or already connecting).
          api.onServerReached = rt.retryNow;
          AppLifecycleListener(onResume: rt.retryNow);
          return rt;
        }),
        // 3.55 admin feature switches: saved copy, GET /features, socket FEATURE_FLAGS pushes.
        // Not lazy, so a switch applies even before any screen asks for it.
        ChangeNotifierProvider<FeatureFlagsService>(lazy: false,
          create: (ctx) => FeatureFlagsService(ctx.read<ApiClient>(), realtime: ctx.read<RealtimeService>())),
        // 3.55 platform: moderator warnings on Home (GET /me/warnings + socket push; switch adminWarnings).
        ChangeNotifierProvider<AdminWarningsService>(lazy: false,
          create: (ctx) => AdminWarningsService(ctx.read<ApiClient>(), realtime: ctx.read<RealtimeService>())),
        ChangeNotifierProvider(create: (ctx) {
          final auth = AuthService(ctx.read<ApiClient>());
          ctx.read<RealtimeService>().onAuthRejected = auth.revalidate;
          return auth;
        }),
        Provider<FuelSettingsBinding>(lazy: false,
          create: (ctx) => FuelSettingsBinding(ctx.read<AuthService>(), ctx.read<SettingsService>()),
          dispose: (_, binding) => binding.dispose()),
        ChangeNotifierProvider(create: (ctx) => MetaService(ctx.read<ApiClient>())..load()),
        ChangeNotifierProvider(create: (ctx) => AppVersionService(ctx.read<MetaService>())),
        ChangeNotifierProvider(create: (ctx) {
          // The membership is the single source of the rider's plan; sign-out forgets it.
          final ms = MembershipService(ctx.read<ApiClient>())..fetchMyMembership()..fetchCatalog();
          ctx.read<AuthService>().onSessionCleared = () => ms.clearLocal().ignore();
          return ms;
        }),
        ChangeNotifierProvider(create: (ctx) => TripStorageService(ctx.read<ApiClient>())),
        ChangeNotifierProvider(create: (ctx) => TimelineService(ctx.read<ApiClient>(), ctx.read<RealtimeService>())),
        // Public ride, safe contact and road warnings (every plan; gateway feature pubride1). Road
        // warnings speak in the important tier and stay silent while my group has an emergency open.
        ChangeNotifierProvider<PublicRideService>(create: (ctx) {
          final pr = PublicRideService(ctx.read<RealtimeService>());
          pr.speaker = (line, key) => ctx.read<VoiceService>().speak(line, priority: VoicePriority.important, key: key).ignore();
          pr.emergencyActive = () => ctx.read<ConvoyService>().activeConvoy?.activeAlerts.any((a) => !a.resolved) ?? false;
          // 3.55 admin feature switch: public ride turned off for every rider.
          final ff = ctx.read<FeatureFlagsService>();
          pr.featureOn = FeatureFlagsService.on;
          ff.addListener(pr.featureSwitchesChanged);
          return pr;
        }),
        ChangeNotifierProvider(create: (ctx) {
          final queue = SqfliteTrackQueue();
          return TrackRecorder(queue, TrackUploader(ctx.read<ApiClient>(), queue));
        }),
        ChangeNotifierProvider<P2pMeshService>(create: (_) => P2pMeshService()),
        ChangeNotifierProvider(
          create: (ctx) {
            final convoys = ConvoyService(
              ctx.read<ApiClient>(),
              ctx.read<RealtimeService>(),
              ctx.read<TripStorageService>(),
              recorder: ctx.read<TrackRecorder>(),
              timeline: ctx.read<TimelineService>(),
              settings: ctx.read<SettingsService>(),
              mesh: ctx.read<P2pMeshService>(),
              onPlanChanged: () => ctx.read<MembershipService>().fetchMyMembership().ignore(),
            );
            // 3.55 riding role prompts ("You are now the sweeper, drop back...") in the important tier.
            convoys.speaker = (line, key) => ctx.read<VoiceService>().speak(line, priority: VoicePriority.important, key: key).ignore();
            // 3.55 admin feature switches (road warnings, riding roles): no hard dependency on the service.
            convoys.featureOn = FeatureFlagsService.on;
            final theme = ctx.read<ThemeController>();
            convoys.addListener(() {
              final me = convoys.myUserId == null ? null : convoys.activeConvoy?.riders[convoys.myUserId];
              if (me != null) theme.notePosition(me.lat, me.lng);
            });
            return convoys;
          },
        ),
        ChangeNotifierProvider<PhoneCallService>(
          create: (_) => PhoneCallService(),
        ),
        ChangeNotifierProvider(create: (ctx) {
          final intercom = IntercomService(ctx.read<RealtimeService>(), settings: ctx.read<SettingsService>());
          intercom.featureOn = FeatureFlagsService.on; // 3.55 admin feature switch 'intercom'
          final phoneCall = ctx.read<PhoneCallService>();
          phoneCall.addListener(() => intercom.setPhoneCallActive(phoneCall.isCallActive));
          return intercom;
        }),
        // Spoken alerts (phone text-to-speech). The engine starts with the first alert of a
        // ride and is released when the ride ends (nothing runs at idle).
        ChangeNotifierProvider<VoiceService>(create: (ctx) {
          final voice = VoiceService(ctx.read<SettingsService>());
          voice.attachPhoneCallService(ctx.read<PhoneCallService>());
          final convoys = ctx.read<ConvoyService>();
          convoys.addListener(() {
            final c = convoys.activeConvoy;
            if ((c == null || c.tripStatus == 'ENDED') && voice.started) voice.release().ignore();
          });
          return voice;
        }),
        // Trip alerts (SOS, stopped, separated, no signal, arrivals), separate from the ongoing status.
        Provider<AlertService>(
          lazy: false,
          create: (ctx) => AlertService(ctx.read<ConvoyService>(), ctx.read<TimelineService>(), voice: ctx.read<VoiceService>()),
          dispose: (_, a) => a.dispose(),
        ),
        // Rider safety: crash alarm, emergency texts, break reminder, "Are you OK?" check-in,
        // fuel reminder, hard stops, follow-up, night voice, weather and tiles at ride start.
        // Created at start so a crash alarm can open without any screen asking for it.
        ChangeNotifierProvider<SafetyService>(
          lazy: false,
          create: (ctx) {
            final convoys = ctx.read<ConvoyService>();
            final settings = ctx.read<SettingsService>();
            final safety = SafetyService(convoys, settings, ctx.read<AuthService>(),
              voice: ctx.read<VoiceService>(), weather: ctx.read<WeatherService>(), tiles: ctx.read<TilePrefetcher>());
            safety.featureOn = FeatureFlagsService.on; // 3.55 admin feature switches (engine care)
            // 3.55: potholes, speed breakers and rough road felt at the front warn the riders
            // behind and are saved for later rides (ConvoyService decides whether to send).
            safety.onRoadSurface = convoys.reportRoadSurface;
            return safety;
          },
        ),
        // 3.55 SOS battery reserve: below 10% in a ride, keep power for SOS / crash detection,
        // pause heavy extras and send the last location to the group once.
        ChangeNotifierProvider<SosBatteryReserve>.value(value: SosBatteryReserve.shared),
        Provider<SosBatteryReserveBinding>(
          lazy: false,
          create: (ctx) {
            SosBatteryReserve.shared.featureOn = FeatureFlagsService.on; // switch 'sosBatteryReserve'
            return SosBatteryReserveBinding(ctx.read<ConvoyService>(),
                realtime: ctx.read<RealtimeService>(), tiles: ctx.read<TilePrefetcher>(), intercom: ctx.read<IntercomService>());
          },
          dispose: (_, b) => b.dispose(),
        ),
        // 3.55 solo check-in by ETA (text the emergency contact when a solo ride is overdue and the
        // rider does not answer) and no-signal ahead (coverage log of my own rides). Not lazy: the
        // timer must run with the screen off.
        ChangeNotifierProvider<SoloGuardianService>(
          lazy: false,
          create: (ctx) => SoloGuardianService(
            ctx.read<ConvoyService>(),
            ctx.read<SettingsService>(),
            ctx.read<AuthService>(),
            ctx.read<RealtimeService>(),
            safety: ctx.read<SafetyService>(),
            voice: ctx.read<VoiceService>(),
            featureOn: FeatureFlagsService.on,
          ),
        ),
        // 3.55 group safety: missing-rider check, group stretch alert, smart regroup point, group
        // break planner, buddy pairs, risky-stretch heads-up. Logic on the phone; never speaks over
        // an SOS / crash alarm (docs/features_355/group_safety.md).
        ChangeNotifierProvider<GroupSafetyService>(
          lazy: false,
          create: (ctx) {
            final api = ctx.read<ApiClient>();
            final convoys = ctx.read<ConvoyService>();
            final safety = ctx.read<SafetyService>();
            final gs = GroupSafetyService(convoys, ctx.read<RealtimeService>(), api,
                timeline: ctx.read<TimelineService>(), places: () => MapPlacesService.shared(api).all)
              ..fatigueScore = (() => safety.fatigueLevel) // 0-100 on the phone; only a level 0..3 is shared
              ..hardStops = (() => safety.hardStops)
              ..alarmOpen = (() => safety.alarm != null || convoys.myOpenSosAlertId != null)
              ..featureOn = FeatureFlagsService.on
              ..speaker = (line, key) => ctx.read<VoiceService>().speak(line, priority: VoicePriority.important, key: key).ignore();
            return gs;
          },
        ),
        // 3.55: CoRoute rider place reviews: a polite "How was it?" after a while at a place
        // (never while riding or during an SOS / crash alarm), ratings on the map and place card.
        ChangeNotifierProvider<PlaceReviewService>(
          lazy: false,
          create: (ctx) {
            final convoys = ctx.read<ConvoyService>();
            final safety = ctx.read<SafetyService>();
            final reviews = PlaceReviewService(ctx.read<ApiClient>())
              // 3.55 safety review: also any open SOS / crash alert of another rider in the ride.
              ..emergencyOpen = (() => SosBatteryReserve.isActive /* 3.55: no review prompts on SOS reserve */ || safety.alarm != null || convoys.pendingSos != null || convoys.myOpenSosAlertId != null ||
                  (convoys.activeConvoy?.activeAlerts.any((a) => !a.resolved) ?? false))
              ..rideActive = (() => convoys.activeConvoy != null && convoys.activeConvoy!.tripStatus != 'ENDED')
              ..attachFixes(convoys.myFixes);
            return reviews;
          },
        ),
        // 3.55: one garage for the whole app; its active bike feeds engine care, the fuel
        // profile (when the rider set none), the ride's vehicle colour and the profile summary.
        Provider<GarageService>.value(value: GarageService.shared),
        Provider<GarageBinding>(
          lazy: false,
          create: (ctx) {
            final convoys = ctx.read<ConvoyService>();
            return GarageBinding(
              ctx.read<GarageService>(),
              engineCare: ctx.read<SafetyService>().engineCare,
              auth: ctx.read<AuthService>(),
              settings: ctx.read<SettingsService>(),
              weather: ctx.read<WeatherService>(),
              onVehicleColour: (c) => convoys.vehicleColor = c,
            );
          },
          dispose: (_, b) => b.dispose(),
        ),
        // 3.55 platform: HelmetVoiceService (hotwords) is no longer created at start-up. Nothing
        // feeds it speech (no recogniser; the mic runs only during PTT/VOX, FEAT-MIC-01), so it
        // only cost memory. Readers use context.read<HelmetVoiceService?>() and get null.
        // Register it here again (lazy) once a speech source exists.
        ChangeNotifierProvider<PermissionRevocationSafetyService>(
          lazy: false,
          create: (ctx) => PermissionRevocationSafetyService(
            convoyService: ctx.read<ConvoyService>(),
            intercomService: ctx.read<IntercomService>(),
          )..init(),
        ),
        Provider<FuelSharingBinding>(
          lazy: false,
          create: (ctx) => FuelSharingBinding(ctx.read<ConvoyService>(), ctx.read<SettingsService>(), ctx.read<SafetyService>()),
          dispose: (_, binding) => binding.dispose(),
        ),
        // In-app navigation to an emergency and accident warnings on my route (voice works with
        // the screen off, from fixes the ride already has).
        ChangeNotifierProvider<EmergencyGuidance>(
          lazy: false,
          create: (ctx) {
            final geo = GeoService(ctx.read<ApiClient>());
            return EmergencyGuidance(
              ctx.read<ConvoyService>(),
              ctx.read<VoiceService>(),
              ctx.read<SettingsService>(),
              fetchRoute: (wp) => geo.route(wp),
            );
          },
        ),
        ChangeNotifierProvider<RideEssentialsCoordinator>(
          lazy: false,
          create: (ctx) {
            final geo = GeoService(ctx.read<ApiClient>());
            return RideEssentialsCoordinator(
              ConvoyEssentialsPort(ctx.read<ConvoyService>()),
              ctx.read<SettingsService>(),
              RouteEssentialsService(ctx.read<ApiClient>()),
              fetchRoute: geo.route,
              reverseGeocode: geo.reverse,
              // Auto re-route: from where I am, in my direction of travel; short spoken lines.
              fetchRouteHeaded: (wp, heading) => geo.route(wp, startHeadingDeg: heading),
              onPrompt: NavVoice(ctx.read<VoiceService>()).say,
            );
          },
        ),
        // Medical ID on the lock screen / quick settings tile: always on, kept in step with the
        // profile (Agent 4: the on/off switch was removed; edit or clear the info instead).
        Provider<MedicalIdLockSync>(
          lazy: false,
          create: (ctx) => MedicalIdLockSync(ctx.read<AuthService>(), ctx.read<SettingsService>()),
          dispose: (_, m) => m.dispose(),
        ),
        // The big ride notification on the home and lock screen (replaces the plain one in place).
        Provider<RideNotificationService>(
          lazy: false,
          create: (ctx) {
            final settings = ctx.read<SettingsService>();
            final auth = ctx.read<AuthService>();
            final convoys = ctx.read<ConvoyService>();
            return RideNotificationService(
              convoys,
              ctx.read<TimelineService>(),
              settings,
              essentials: ctx.read<RideEssentialsCoordinator>(),
              safety: ctx.read<SafetyService>(),
              // Always on (Agent 4): the rider's medical ID badge on the lock screen during a ride
              // and the full line during their own SOS; empty when no medical info was entered.
              medicalId: () => MedicalId.fromAuth(auth),
              // Talk follows the ride's plan: a solo ride (Community host, one seat) has no Talk;
              // null while the seats are unknown (older gateway), so a group ride still shows it.
              talkAllowed: () {
                if (!FeatureFlagsService.on('intercom')) return false; // 3.55 admin feature switch
                final ride = convoys.activeConvoy;
                return ride == null || ride.capacity <= 0 ? null : ride.hasGroupFeatures;
              },
            );
          },
          dispose: (_, n) => n.dispose(),
        ),
      ],
      child: const _SessionBinder(
        child: _DeepLinkListener(
          child: _App(),
        ),
      ),
    );
  }
}

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeController>();
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      navigatorObservers: [appRouteObserver],
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(theme.palette),
      // Colours switch at once everywhere; a cross-fade would mix the two themes.
      themeAnimationDuration: Duration.zero,
      home: const SplashScreen(),
      builder: (context, child) {
        // Large text is honoured up to 1.3x (every screen is laid out for it); beyond that it is capped.
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(mq.textScaler.scale(1.0).clamp(0.85, 1.3).toDouble())),
          child: CrashAlarmHost(
            navigatorKey: appNavigatorKey,
            child: _UpdateGate(child: child ?? const SizedBox.shrink()),
          ),
        );
      },
    );
  }
}

/// Blocks the app when the server says this build is too old to be safe.
class _UpdateGate extends StatelessWidget {
  final Widget child;
  const _UpdateGate({required this.child});

  @override
  Widget build(BuildContext context) {
    final meta = context.watch<MetaService>();
    if (!meta.updateRequired) return child;
    final url = meta.meta?.downloadUrl ?? '';
    return Material(
      color: AppTheme.obsidianVoid,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Space.s24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: Radii.lgAll,
                    child: Image.asset('assets/branding/coroute_icon.png', width: 72, height: 72, cacheWidth: 216),
                  ),
                  const SizedBox(height: Space.s24),
                  Text('Update required', textAlign: TextAlign.center, style: AppText.title),
                  const SizedBox(height: Space.s8),
                  Text(
                    'This version of CoRoute no longer works with the convoy service. Install the latest version to keep riding with your group.',
                    textAlign: TextAlign.center,
                    style: AppText.body.copyWith(color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: Space.s24),
                  FilledButton(
                    onPressed: url.isEmpty ? null : () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
                    style: FilledButton.styleFrom(minimumSize: const Size(200, 56)),
                    child: const Text('Get the update'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens/closes the realtime session whenever authentication changes, and
/// returns to the sign-in screen when a session ends while the app is open.
class _SessionBinder extends StatefulWidget {
  final Widget child;
  const _SessionBinder({required this.child});

  @override
  State<_SessionBinder> createState() => _SessionBinderState();
}

class _SessionBinderState extends State<_SessionBinder> {
  String? _boundUserId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.watch<AuthService>();
    final convoys = context.read<ConvoyService>();
    final intercom = context.read<IntercomService>();
    final trips = context.read<TripStorageService>();

    if (auth.isAuthenticated && auth.currentUserId != _boundUserId) {
      _boundUserId = auth.currentUserId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        convoys.startSession(token: auth.token ?? '', userId: auth.currentUserId!, admin: auth.isMasterAdmin);
        trips.syncWithCloud(userId: auth.currentUserId);
      });
    } else if (!auth.isAuthenticated && _boundUserId != null) {
      _boundUserId = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        intercom.reset();
        convoys.endSession();
        trips.clearLocal();
        // Session expired, was revoked, or the account was deleted: back to sign-in.
        final nav = appNavigatorKey.currentState;
        if (nav != null) {
          nav.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const AccessGateScreen()), (_) => false);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Handles `coroute://join/CODE` and `https://<host>/join/CODE` links, and
/// `coroute://subscription` (return from the website checkout).
class _DeepLinkListener extends StatefulWidget {
  final Widget child;
  const _DeepLinkListener({required this.child});

  @override
  State<_DeepLinkListener> createState() => _DeepLinkListenerState();
}

class _DeepLinkListenerState extends State<_DeepLinkListener> {
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;

  @override
  void initState() {
    super.initState();
    _appLinks.getInitialLink().then((uri) {
      if (uri != null) _handle(uri);
    }).catchError((_) {});
    _sub = _appLinks.uriLinkStream.listen(_handle, onError: (_) {});
  }

  void _handle(Uri uri) {
    if (uri.scheme == 'coroute' && uri.host == 'cockpit') {
      // Return link from external navigation; activity is brought to foreground.
      return;
    }
    if (uri.scheme == 'coroute' && uri.host == 'subscription') {
      // Back from the website checkout: re-read the membership (the single source of the plan).
      context.read<MembershipService>().fetchMyMembership().ignore();
      return;
    }
    final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    String? code;
    if (uri.scheme == 'coroute' && uri.host == 'join' && segs.isNotEmpty) code = segs.first;
    if (segs.length >= 2 && segs[segs.length - 2] == 'join') code = segs.last;
    if (code == null) return;
    context.read<ConvoyService>().setPendingJoinCode(code);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
