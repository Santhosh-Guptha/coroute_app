import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../../domain/diag/diag_log.dart';
import '../widgets/push_router_host.dart';
import 'trip_planner_screen.dart';

/// 3.56 "Share to CoRoute" (Android): text shared from a maps app (a Google Maps place,
/// a maps link, coordinates) opens the trip planner with the text in the destination
/// search, where map_link_parser.dart reads it. The native side is ShareInActivity.kt
/// (channel `coroute/share_in`). The shared text is never logged.
class ShareInOpener {
  ShareInOpener({required this.navigatorKey, required this.readContext});

  static const MethodChannel _channel = MethodChannel('coroute/share_in');

  final GlobalKey<NavigatorState> navigatorKey;

  /// A context above the navigator that can read the app's providers (null once gone).
  final BuildContext? Function() readContext;
  bool _opening = false;

  void start() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'sharedText') unawaited(_take());
      return null;
    });
    unawaited(_take());
  }

  void stop() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _channel.setMethodCallHandler(null);
  }

  Future<void> _take() async {
    String? text;
    try {
      text = await _channel.invokeMethod<String>('takeSharedText');
    } catch (_) {
      return; // older native side or no Android
    }
    if (text == null || text.trim().isEmpty) return;
    DiagLog.info(DiagCat.network, 'share_in', {'len': text.length});
    await _open(text.trim());
  }

  bool _ready(BuildContext ctx) {
    final auth = ctx.read<AuthService?>();
    return auth != null && auth.isAuthenticated && navigatorKey.currentState != null && PushRouterHost.observer.firstScreenShown;
  }

  Future<void> _open(String text) async {
    if (_opening) return;
    _opening = true;
    try {
      // Up to ~20 s for sign-in and the splash hand-over; then the shared text is dropped.
      for (var i = 0; i < 80; i++) {
        final ctx = readContext();
        if (ctx == null || !ctx.mounted) return;
        if (_ready(ctx)) break;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      final ctx = readContext();
      if (ctx == null || !ctx.mounted || !_ready(ctx)) return;
      final nav = navigatorKey.currentState;
      final navContext = navigatorKey.currentContext;
      if (nav == null || navContext == null) return;
      final active = ctx.read<ConvoyService?>()?.activeConvoy;
      if (active != null && active.tripStatus != 'ENDED') {
        ScaffoldMessenger.maybeOf(navContext)?.showSnackBar(
          const SnackBar(content: Text('You are on a ride. End it to plan a new one with this place.')),
        );
        return;
      }
      unawaited(nav.push(MaterialPageRoute(builder: (_) => TripPlannerScreen(sharedText: text))));
    } finally {
      _opening = false;
    }
  }
}
