import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'core/constants/app_constants.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'data/services/alert_service.dart';
import 'data/services/api_client.dart';
import 'data/services/auth_service.dart';
import 'data/services/background_service.dart';
import 'data/services/convoy_service.dart';
import 'data/services/intercom_service.dart';
import 'data/services/meta_service.dart';
import 'data/local/sqflite_track_queue.dart';
import 'data/services/realtime_service.dart';
import 'data/services/settings_service.dart';
import 'data/services/timeline_service.dart';
import 'data/services/track_recorder.dart';
import 'data/services/track_uploader.dart';
import 'data/services/trip_storage_service.dart';
import 'presentation/auth/access_gate_screen.dart';
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
  // Data saver is known before the first frame, so the first ride already uses it.
  final settings = SettingsService();
  await settings.load();
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
        // Trip alerts (SOS, stopped, separated, no signal, arrivals), separate from the ongoing status.
        Provider<AlertService>(
          lazy: false,
          create: (ctx) => AlertService(ctx.read<ConvoyService>(), ctx.read<TimelineService>()),
          dispose: (_, a) => a.dispose(),
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
        // Clamp runaway system font scaling so HUD layouts never overflow.
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(mq.textScaler.scale(1.0).clamp(0.85, 1.2).toDouble())),
          child: _UpdateGate(child: child ?? const SizedBox.shrink()),
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
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset('assets/branding/coroute_icon.png', width: 72, height: 72, cacheWidth: 216),
                const SizedBox(height: 18),
                Text('Update required', style: TextStyle(color: AppTheme.textPrimary, fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(
                  'This version of CoRoute no longer works with the convoy service. Install the latest version to keep riding with your group.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: url.isEmpty ? null : () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.neonCyan, foregroundColor: Colors.black, minimumSize: const Size(200, 48)),
                  child: const Text('Get the update'),
                ),
              ],
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
