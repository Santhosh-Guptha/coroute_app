import 'data/services/ride_essentials_coordinator.dart';
import 'data/services/route_essentials_service.dart';
import 'data/services/fuel_sharing_binding.dart';
import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'core/constants/app_constants.dart';
import 'core/l10n/l10n.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'core/ui/ui.dart';
import 'data/services/alert_service.dart';
import 'data/services/api_client.dart';
import 'data/services/auth_service.dart';
import 'data/services/background_service.dart';
import 'data/services/convoy_service.dart';
import 'data/services/geo_service.dart';
import 'data/services/intercom_service.dart';
import 'data/services/meta_service.dart';
import 'data/local/ride_stats_store.dart';
import 'data/local/sqflite_track_queue.dart';
import 'data/services/realtime_service.dart';
import 'data/services/ride_notification_service.dart';
import 'data/services/safety_native.dart';
import 'data/services/safety_service.dart';
import 'data/services/settings_service.dart';
import 'data/services/tile_cache_service.dart';
import 'data/services/timeline_service.dart';
import 'data/services/track_recorder.dart';
import 'data/services/track_uploader.dart';
import 'data/services/trip_storage_service.dart';
import 'data/services/voice_service.dart';
import 'data/services/weather_service.dart';
import 'domain/notify/notification_snapshot.dart';
import 'presentation/auth/access_gate_screen.dart';
import 'presentation/ride/emergency_guidance.dart';
import 'presentation/safety/crash_alarm_host.dart';
import 'presentation/splash/splash_screen.dart';

/// Lets services navigate (sign-out on session expiry, deep links) without a BuildContext.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  BackgroundService.initCommunicationPort();
  // Portrait + landscape are both supported; layouts adapt to width.
  await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  // Light or dark is decided before the first frame, so there is no flash.
  await MetaService.readPackageInfo();
  final theme = ThemeController();
  await theme.load();
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
        // Weather along the route (3.16): two small requests per ride through the gateway.
        ChangeNotifierProvider<WeatherService>(create: (ctx) => WeatherService(ctx.read<ApiClient>(), ctx.read<SettingsService>())),
        // Route map tiles saved before the ride (3.16): one bounded job, on Wi-Fi or by a tap.
        ChangeNotifierProvider<TilePrefetcher>(create: (_) => TilePrefetcher(TileCache.instance)),
        ChangeNotifierProvider(create: (ctx) {
          final api = ctx.read<ApiClient>();
          final rt = RealtimeService();
          // A refreshed session token is used for the next reconnect.
          api.addListener(() => rt.updateToken(api.token));
          return rt;
        }),
        ChangeNotifierProvider(create: (ctx) {
          final auth = AuthService(ctx.read<ApiClient>());
          ctx.read<RealtimeService>().onAuthRejected = auth.revalidate;
          return auth;
        }),
        ChangeNotifierProvider(create: (ctx) => MetaService(ctx.read<ApiClient>())..load()),
        ChangeNotifierProvider(create: (ctx) => TripStorageService(ctx.read<ApiClient>())),
        ChangeNotifierProvider(create: (ctx) => TimelineService(ctx.read<ApiClient>(), ctx.read<RealtimeService>())),
        ChangeNotifierProvider(create: (ctx) {
          final queue = SqfliteTrackQueue();
          return TrackRecorder(queue, TrackUploader(ctx.read<ApiClient>(), queue));
        }),
        ChangeNotifierProvider(
          create: (ctx) => ConvoyService(
            ctx.read<ApiClient>(),
            ctx.read<RealtimeService>(),
            ctx.read<TripStorageService>(),
            recorder: ctx.read<TrackRecorder>(),
            timeline: ctx.read<TimelineService>(),
            settings: ctx.read<SettingsService>(),
          )..addListener(() => _notePosition(ctx)),
        ),
        ChangeNotifierProvider(create: (ctx) => IntercomService(ctx.read<RealtimeService>(), settings: ctx.read<SettingsService>())),
        // Spoken alerts (phone text-to-speech). The engine starts with the first alert of a
        // ride and is released when the ride ends (nothing runs at idle).
        ChangeNotifierProvider<VoiceService>(create: (ctx) {
          final voice = VoiceService(ctx.read<SettingsService>());
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
            return safety;
          },
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
          create: (ctx) => RideEssentialsCoordinator(
            ConvoyEssentialsPort(ctx.read<ConvoyService>()),
            ctx.read<SettingsService>(),
            RouteEssentialsService(ctx.read<ApiClient>()),
            fetchRoute: GeoService(ctx.read<ApiClient>()).route,
          ),
        ),
        // The big ride notification on the home and lock screen (replaces the plain one in place).
        Provider<RideNotificationService>(
          lazy: false,
          create: (ctx) {
            final settings = ctx.read<SettingsService>();
            final auth = ctx.read<AuthService>();
            return RideNotificationService(
              ctx.read<ConvoyService>(),
              ctx.read<TimelineService>(),
              settings,
              essentials: ctx.read<RideEssentialsCoordinator>(),
              safety: ctx.read<SafetyService>(),
              // Opt-in (3.16): the rider's medical ID on the lock screen during their own SOS.
              medicalId: () => settings.medicalIdOnLockScreen ? MedicalId.fromAuth(auth) : null,
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

/// Keeps automatic light/dark accurate as the rider travels, using the
/// position the convoy already shares (no extra GPS work).
void _notePosition(BuildContext ctx) {
  final convoys = ctx.read<ConvoyService>();
  final me = convoys.myUserId == null ? null : convoys.activeConvoy?.riders[convoys.myUserId];
  if (me != null) ctx.read<ThemeController>().notePosition(me.lat, me.lng);
}

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeController>();
    return MaterialApp(
      navigatorKey: appNavigatorKey,
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
        convoys.startSession(token: auth.token!, userId: auth.currentUserId!, admin: auth.isMasterAdmin);
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

/// Handles `coroute://join/CODE` and `https://<host>/join/CODE` links.
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
