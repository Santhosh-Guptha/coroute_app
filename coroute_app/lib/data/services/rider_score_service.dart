import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/score/rider_score.dart';
import '../local/ride_stats_store.dart';
import 'api_client.dart';

/// 3.55 rider score + leaderboard (docs/features_355/rider_score.md).
///
/// Reads GET /me/score, GET /public/leaderboard and GET /me/leaderboard, and sends each finished
/// ride's counts from the private ride safety report: hard brakes, breaks, highest tiredness, break
/// reminders and minutes over the limit. Counts only, never a position, time, speed or track. The
/// report itself stays on the phone.
///
/// "Use my safety report in my score" is always on since Nov 11 (owner decision, settings migration
/// v2): it has no switch. A rider who had turned it off is moved on by [adoptAlwaysOn], and rides that
/// ended before that moment are never sent ([prefsSendFrom]).
///
/// Created where it is used (the score screen / card); no global provider is needed.
class RiderScoreService extends ChangeNotifier {
  RiderScoreService(this._api);

  final ApiClient _api;

  static const String prefsUseReport = 'coroute_rider_score_use_report_v1';
  static const String prefsSent = 'coroute_rider_score_sent_v1';

  /// Rides that ended before this time (epoch ms) are never sent: set when a rider who had the
  /// report switched off is moved to always on, so rides recorded while it was off stay private.
  static const String prefsSendFrom = 'coroute_rider_score_send_from_v1';
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

  /// Always on (Nov 11). Kept so callers keep working.
  Future<void> loadSetting() async {
    useSafetyReport = true;
    _notify();
  }

  /// Always on (Nov 11): "off" is ignored. "On" sends what is pending and reloads the score.
  Future<void> setUseSafetyReport(bool on) async {
    if (!on) return;
    useSafetyReport = true;
    _notify();
    await syncPhoneCounts();
    await loadScore();
  }

  /// Settings migration v2 (SettingsService): fixes the report on. When the rider had switched it
  /// off, rides that ended before now are marked as never to send ([prefsSendFrom]). Pure storage.
  static Future<void> adoptAlwaysOn(SharedPreferences p, {int? nowMs}) async {
    final wasOff = p.getBool(prefsUseReport) == false;
    if (wasOff && !p.containsKey(prefsSendFrom)) {
      await p.setInt(prefsSendFrom, nowMs ?? DateTime.now().millisecondsSinceEpoch);
    }
    await p.setBool(prefsUseReport, true);
  }

  /// Sends the counts of finished rides not sent yet. Safe to call often.
  Future<int> syncPhoneCounts({int? nowMs}) async {
    if (!_api.hasToken) return 0;
    SharedPreferences p;
    try {
      p = await SharedPreferences.getInstance();
    } catch (_) {
      return 0;
    }
    final sendFrom = p.getInt(prefsSendFrom) ?? 0;
    final sent = (p.getStringList(prefsSent) ?? const <String>[]).toList();
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    var n = 0;
    for (final s in await RideStatsStore.loadAll()) {
      if (s.endedAt <= 0 || s.endedAt < sendFrom || !s.groupId.startsWith('GRP-') || sent.contains(s.groupId)) continue;
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
  /// Never sends rides from before [prefsSendFrom]; never throws.
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
