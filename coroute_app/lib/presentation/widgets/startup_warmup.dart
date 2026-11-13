import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../core/ui/async_view.dart';
import '../../core/ui/optimistic.dart';
import '../../data/services/api_client.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/feature_flags_service.dart';
import '../../data/services/garage_service.dart';
import '../../data/services/rider_score_service.dart';
import '../../domain/score/rider_score.dart';

/// Round 7 (perceived speed): once the app has been idle for a moment after
/// sign-in, the data of the screens a rider opens next is fetched into the
/// in-memory cache ([SwrCache]), so Profile, Garage and the Leaderboard open
/// with content instead of a placeholder.
///
/// Rules: never during a ride (the ride owns the network and the battery),
/// never before the first frame, once per sign-in, every failure is silent.
/// Friends, crews, invitations and the plan load themselves at sign-in
/// (their services), so they are not repeated here.
abstract final class StartupWarmup {
  static String? _doneFor;

  /// Seconds of quiet after sign-in before the warm-up starts.
  static const Duration idleDelay = Duration(seconds: 3);

  static void schedule(BuildContext context, {required String userId}) {
    if (_doneFor == userId) return;
    _doneFor = userId;
    final api = context.read<ApiClient>();
    final convoys = context.read<ConvoyService>();
    runWhenIdle(() => run(api: api, rideActive: () => convoys.activeConvoy != null), delay: idleDelay);
  }

  /// Sign-out: the next rider starts clean.
  static Future<void> reset() async {
    _doneFor = null;
    SwrCache.shared.clear();
  }

  static Future<void> run({required ApiClient api, required bool Function() rideActive, SwrCache? cache}) async {
    final c = cache ?? SwrCache.shared;
    if (rideActive() || !api.hasToken) return;
    try {
      await GarageService.shared.load();
    } catch (_) {}
    if (rideActive() || !FeatureFlagsService.on('leaderboard')) return;
    await c.warm<Leaderboard>('leaderboard', () async => Leaderboard.fromJson(await api.get('/public/leaderboard')), ttl: const Duration(minutes: 5));
    if (rideActive()) return;
    final svc = RiderScoreService(api);
    try {
      await svc.loadScore();
      final s = svc.score;
      if (s != null) c.put<RiderScore>('score:me', s);
    } catch (_) {
    } finally {
      svc.dispose();
    }
  }
}
