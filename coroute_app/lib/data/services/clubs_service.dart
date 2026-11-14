import 'package:flutter/foundation.dart';

import '../../core/ui/optimistic.dart';
import 'api_client.dart';

/// One club (an approved operator's crew) the rider belongs to (GET /api/clubs).
@immutable
class ClubSummary {
  final String operatorId;
  final String crewId;
  final String name;
  final String typeLabel;
  final String city;
  final int members;
  final String role;
  final List<ClubRide> upcoming;
  const ClubSummary({
    required this.operatorId,
    required this.crewId,
    required this.name,
    this.typeLabel = '',
    this.city = '',
    this.members = 0,
    this.role = 'MEMBER',
    this.upcoming = const [],
  });

  static ClubSummary? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['operatorId']?.toString() ?? '';
    final name = j['name']?.toString() ?? '';
    if (id.isEmpty || name.isEmpty) return null;
    final up = j['upcoming'];
    return ClubSummary(
      operatorId: id,
      crewId: j['crewId']?.toString() ?? '',
      name: name,
      typeLabel: j['typeLabel']?.toString() ?? '',
      city: j['city']?.toString() ?? '',
      members: j['members'] is num ? (j['members'] as num).toInt() : 0,
      role: j['role']?.toString() ?? 'MEMBER',
      upcoming: [if (up is List) for (final r in up) ?ClubRide.fromJson(r)],
    );
  }
}

@immutable
class ClubRide {
  final String title;
  final int startsAt;
  final String meetName;
  const ClubRide({required this.title, this.startsAt = 0, this.meetName = ''});
  static ClubRide? fromJson(Object? j) {
    if (j is! Map || j['title'] is! String) return null;
    return ClubRide(title: j['title'] as String, startsAt: j['startsAt'] is num ? (j['startsAt'] as num).toInt() : 0, meetName: j['meetName']?.toString() ?? '');
  }
}

@immutable
class ClubInvite {
  final String inviteId;
  final String name;
  final String city;
  final String typeLabel;
  const ClubInvite({required this.inviteId, required this.name, this.city = '', this.typeLabel = ''});
  static ClubInvite? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['inviteId']?.toString() ?? '';
    if (id.isEmpty) return null;
    return ClubInvite(inviteId: id, name: j['name']?.toString() ?? 'Club', city: j['city']?.toString() ?? '', typeLabel: j['typeLabel']?.toString() ?? '');
  }
}

@immutable
class ClubsSnapshot {
  final List<ClubSummary> clubs;
  final List<ClubInvite> invites;
  const ClubsSnapshot({this.clubs = const [], this.invites = const []});
  bool get isEmpty => clubs.isEmpty && invites.isEmpty;
}

/// v3.58: clubs on Home and Community, read from the existing operator member routes (GET /api/clubs,
/// POST /api/clubs/invites/:id/{accept|decline}, POST /api/clubs/join). No new backend. Clubs are invite /
/// link only today, so the app offers "Join with a code" instead of "Request to join".
class ClubsService {
  ClubsService(this._api);
  final ApiClient _api;

  static const String cacheKey = 'clubs:mine';

  /// The last answer at once (stale-while-revalidate), or null.
  static ClubsSnapshot? cached() => SwrCache.shared.peek<ClubsSnapshot>(cacheKey);

  /// GET /api/clubs. An empty snapshot when the operators feature is off (403) or unknown (404).
  Future<ClubsSnapshot> load() async {
    if (!_api.hasToken) return const ClubsSnapshot();
    try {
      final res = await _api.get('/clubs');
      final m = res is Map ? res : const {};
      final clubs = m['clubs'], invites = m['invites'];
      final snap = ClubsSnapshot(
        clubs: [if (clubs is List) for (final c in clubs) ?ClubSummary.fromJson(c)],
        invites: [if (invites is List) for (final i in invites) ?ClubInvite.fromJson(i)],
      );
      SwrCache.shared.put<ClubsSnapshot>(cacheKey, snap);
      return snap;
    } on ApiException catch (e) {
      if (e.statusCode == 403 || e.statusCode == 404) return const ClubsSnapshot();
      rethrow;
    }
  }

  /// Accept or decline a club invite. Null on success, else the gateway's message.
  Future<String?> answer(String inviteId, bool accept) async {
    try {
      await _api.post('/clubs/invites/${Uri.encodeComponent(inviteId)}/${accept ? 'accept' : 'decline'}');
      SwrCache.shared.remove(cacheKey);
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (_) {
      return 'Could not reach CoRoute. Try again.';
    }
  }

  /// Join with a club's invite code (from its link). Returns (club name, error).
  Future<(String?, String?)> joinWithCode(String code) async {
    final c = code.trim();
    if (c.length < 4) return (null, 'Enter the code from the club link.');
    try {
      final res = await _api.post('/clubs/join', {'code': c});
      SwrCache.shared.remove(cacheKey);
      return (res is Map ? res['name']?.toString() : null, null);
    } on ApiException catch (e) {
      return (null, e.message);
    } catch (_) {
      return (null, 'Could not reach CoRoute. Try again.');
    }
  }
}
