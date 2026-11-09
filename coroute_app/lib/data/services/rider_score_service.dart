import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/score/rider_score.dart';
import '../local/ride_stats_store.dart';
import 'api_client.dart';

/// 3.55 rider score + leaderboard (docs/features_355/rider_score.md).
///
/// Reads GET /me/score, GET /public/leaderboard and GET /me/leaderboard, and (only while the rider's
/// setting "Use my ride safety report for my rider score" is on, default on) sends each finished
/// ride's counts from the private ride safety report: hard brakes, breaks, highest tiredness, break
/// reminders and minutes over the limit. Counts only, never a position, time, speed or track. The
/// report itself stays on the phone. Switching the setting off also deletes the counts already sent.
///
/// Created where it is used (the score screen / card); no global provider is needed.
class RiderScoreService extends ChangeNotifier {
  RiderScoreService(this._api);

  final ApiClient _api;

  static const String prefsUseReport = 'coroute_rider_score_use_report_v1';
  static const String prefsSent = 'coroute_rider_score_sent_v1';
  static const int _sentMax = 200;
  static const int _sendWithinDays = 30;

  RiderScore? score;
  Leaderboard? leaderboard;
  LeaderboardPosition? position;
  bool useSafetyReport = true;
  bool loading = false;
  String? error;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> loadSetting() async {
    try {
      final p = await SharedPreferences.getInstance();
      useSafetyReport = p.getBool(prefsUseReport) ?? true;
    } catch (_) {
      useSafetyReport = true;
    }
    _notify();
  }

  /// Turns the setting on or off. Off: the counts already sent are deleted on the server.
  Future<void> setUseSafetyReport(bool on) async {
    useSafetyReport = on;
    _notify();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(prefsUseReport, on);
      if (!on) await p.remove(prefsSent); // switched back on later: rides are sent again
    } catch (_) {}
    if (on) {
      await syncPhoneCounts();
    } else {
      try {
        await _api.delete('/me/score/phone');
      } catch (e) {
        debugPrint('rider score note: ${e.runtimeType}');
      }
    }
    await loadScore();
  }

  /// Sends the counts of finished rides not sent yet (only while the setting is on). Safe to call often.
  Future<int> syncPhoneCounts({int? nowMs}) async {
    if (!_api.hasToken) return 0;
    SharedPreferences p;
    try {
      p = await SharedPreferences.getInstance();
    } catch (_) {
      return 0;
    }
    if (!(p.getBool(prefsUseReport) ?? true)) return 0;
    final sent = (p.getStringList(prefsSent) ?? const <String>[]).toList();
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    var n = 0;
    for (final s in await RideStatsStore.loadAll()) {
      if (s.endedAt <= 0 || !s.groupId.startsWith('GRP-') || sent.contains(s.groupId)) continue;
      if (now - s.endedAt > _sendWithinDays * 86400000) continue;
      final sf = s.safety;
      try {
        await _api.post(
          '/me/score/rides',
          phoneCountsBody(
            groupId: s.groupId,
            hardBrakes: s.hardStops,
            breaks: s.breaks,
            fatiguePeak: sf?.fatiguePeak ?? 0,
            fatiguePrompts: sf?.fatiguePrompts ?? 0,
            overLimitMin: sf?.overLimitMin ?? 0,
          ),
        );
        sent.add(s.groupId);
        n++;
      } catch (e) {
        debugPrint('rider score note: ${e.runtimeType}');
        break; // offline or refused: try again next time
      }
    }
    if (n > 0) {
      while (sent.length > _sentMax) {
        sent.removeAt(0);
      }
      try {
        await p.setStringList(prefsSent, sent);
      } catch (_) {}
    }
    return n;
  }

  /// 3.55: fire-and-forget at ride end (wired in main.dart via SafetyService.onRideStatsEnded).
  /// Respects the setting (syncPhoneCounts returns early when it is off); never throws.
  static Future<void> syncAfterRide(ApiClient api) async {
    final svc = RiderScoreService(api);
    try {
      await svc.syncPhoneCounts();
    } catch (e) {
      debugPrint('rider score note: ${e.runtimeType}');
    } finally {
      svc.dispose();
    }
  }

  Future<void> loadScore() async {
    loading = true;
    error = null;
    _notify();
    try {
      score = RiderScore.fromJson(await _api.get('/me/score'));
    } on ApiException catch (e) {
      error = e.statusCode == 0 ? 'You are offline. Your score will load when you are back online.' : e.message;
    } catch (_) {
      error = 'Could not load your score.';
    } finally {
      loading = false;
      _notify();
    }
  }

  /// Settings + pending counts + score, in that order (the screen and the card call this).
  Future<void> refresh() async {
    await loadSetting();
    await syncPhoneCounts();
    await loadScore();
  }

  Future<void> loadLeaderboard() async {
    loading = true;
    error = null;
    _notify();
    try {
      leaderboard = Leaderboard.fromJson(await _api.get('/public/leaderboard'));
      if (_api.hasToken) {
        try {
          position = LeaderboardPosition.fromJson(await _api.get('/me/leaderboard'));
        } catch (_) {
          position = null;
        }
      }
    } on ApiException catch (e) {
      error = e.statusCode == 0 ? 'You are offline. The leaderboard will load when you are back online.' : e.message;
    } catch (_) {
      error = 'Could not load the leaderboard.';
    } finally {
      loading = false;
      _notify();
    }
  }
}
