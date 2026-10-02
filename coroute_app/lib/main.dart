import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'core/constants/app_constants.dart';
import 'core/theme/app_theme.dart';
import 'data/services/api_client.dart';
import 'data/services/auth_service.dart';
import 'data/services/convoy_service.dart';
import 'data/services/intercom_service.dart';
import 'data/services/realtime_service.dart';
import 'data/services/trip_storage_service.dart';
import 'presentation/splash/splash_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Portrait + landscape are both supported; layouts adapt via LayoutBuilder/OrientationBuilder.
  await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: AppTheme.obsidianVoid,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const CoRouteApp());
}

class CoRouteApp extends StatelessWidget {
  const CoRouteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ApiClient()),
        ChangeNotifierProvider(create: (_) => RealtimeService()),
        ChangeNotifierProvider(create: (ctx) => AuthService(ctx.read<ApiClient>())),
        ChangeNotifierProvider(create: (ctx) => TripStorageService(ctx.read<ApiClient>())),
        ChangeNotifierProvider(
          create: (ctx) => ConvoyService(ctx.read<ApiClient>(), ctx.read<RealtimeService>(), ctx.read<TripStorageService>()),
        ),
        ChangeNotifierProvider(create: (ctx) => IntercomService(ctx.read<RealtimeService>())),
      ],
      child: const _SessionBinder(
        child: _App(),
      ),
    );
  }
}

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const SplashScreen(),
      builder: (context, child) {
        // Clamp runaway system font scaling so HUD layouts never overflow.
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(mq.textScaler.scale(1.0).clamp(0.85, 1.2).toDouble())),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}

/// Opens/closes the realtime session whenever authentication changes.
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
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
