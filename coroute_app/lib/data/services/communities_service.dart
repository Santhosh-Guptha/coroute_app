import 'package:flutter/foundation.dart';

import 'api_client.dart';

String? _avatar(Object? v) {
  final s = v?.toString() ?? '';
  return s.startsWith('/api/avatars/') ? s : null;
}

int _i(Object? v) => v is num ? v.toInt() : 0;

/// A rider card (username, first name, picture).
@immutable
class RiderCard {
  final String username;
  final String displayName;
  final String? avatarUrl;
  const RiderCard({required this.username, this.displayName = '', this.avatarUrl});
  factory RiderCard.fromJson(Map m) => RiderCard(username: m['username']?.toString() ?? '', displayName: m['displayName']?.toString() ?? '', avatarUrl: _avatar(m['avatarUrl']));
}

/// A community as anyone sees it (GET /communities/discover and /communities/:id).
@immutable
class CommunitySummary {
  final String crewId;
  final String name;
  final String description;
  final String visibility;
  final String? photoUrl;
  final int memberCount;
  final bool club;

  /// MEMBER | REQUESTED | NONE
  final String status;
  const CommunitySummary({required this.crewId, required this.name, this.description = '', this.visibility = 'private', this.photoUrl, this.memberCount = 0, this.club = false, this.status = 'NONE'});
  bool get isPublic => visibility == 'public';
  factory CommunitySummary.fromJson(Map m) => CommunitySummary(
        crewId: m['crewId']?.toString() ?? '',
        name: m['name']?.toString() ?? '',
        description: m['description']?.toString() ?? '',
        visibility: m['visibility']?.toString() == 'public' ? 'public' : 'private',
        photoUrl: _avatar(m['photoUrl']),
        memberCount: _i(m['memberCount']),
        club: m['club'] == true,
        status: m['status']?.toString() ?? 'NONE',
      );
}

/// A ride a community admin planned; members answer Interested or Not interested.
@immutable
class CommunityRide {
  final String rideId;
  final String title;
  final String meetName;
  final String destName;
  final String notes;
  final int startAt;
  final String when;
  final String status;
  final bool past;
  final RiderCard? host;
  final int interestedCount;
  final int notInterestedCount;
  final List<RiderCard> interested;
  final String? myAnswer;
  final bool canEdit;
  const CommunityRide({
    required this.rideId,
    required this.title,
    required this.meetName,
    this.destName = '',
    this.notes = '',
    required this.startAt,
    this.when = '',
    this.status = 'PLANNED',
    this.past = false,
    this.host,
    this.interestedCount = 0,
    this.notInterestedCount = 0,
    this.interested = const [],
    this.myAnswer,
    this.canEdit = false,
  });
  bool get cancelled => status == 'CANCELLED';
  factory CommunityRide.fromJson(Map m) => CommunityRide(
        rideId: m['rideId']?.toString() ?? '',
        title: m['title']?.toString() ?? '',
        meetName: m['meetName']?.toString() ?? '',
        destName: m['destName']?.toString() ?? '',
        notes: m['notes']?.toString() ?? '',
        startAt: _i(m['startAt']),
        when: m['when']?.toString() ?? '',
        status: m['status']?.toString() ?? 'PLANNED',
        past: m['past'] == true,
        host: m['host'] is Map ? RiderCard.fromJson(m['host'] as Map) : null,
        interestedCount: _i(m['interestedCount']),
        notInterestedCount: _i(m['notInterestedCount']),
        interested: m['interested'] is List ? (m['interested'] as List).whereType<Map>().map(RiderCard.fromJson).toList() : const [],
        myAnswer: m['myAnswer']?.toString(),
        canEdit: m['canEdit'] == true,
      );
}

/// GET /communities/:id: the summary, and for a public community (or a member) members and rides.
@immutable
class CommunityView {
  final CommunitySummary summary;
  final List<(RiderCard, String)> members; // card, role
  final List<CommunityRide> rides;
  final bool open;
  const CommunityView({required this.summary, this.members = const [], this.rides = const [], this.open = false});
}

/// v3.60 communities (gateway/src/community_routes.js): find and join public / private communities, join
/// requests, the community picture and hosted rides with interest answers. Crews_service.dart keeps the member
/// view (members, polls, roles).
class CommunitiesService {
  CommunitiesService(this._api);
  final ApiClient _api;

  static const String ridesFlag = 'communityRides';

  String _c(String id) => Uri.encodeComponent(id);

  Future<String?> _act(Future<dynamic> Function() call) async {
    try {
      await call();
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (_) {
      return 'Could not reach CoRoute. Try again.';
    }
  }

  Future<List<CommunitySummary>> discover({String q = ''}) async {
    final res = await _api.get('/communities/discover${q.trim().isEmpty ? '' : '?q=${Uri.encodeQueryComponent(q.trim())}'}');
    final list = res is Map ? res['communities'] : null;
    return list is List ? list.whereType<Map>().map(CommunitySummary.fromJson).toList() : const [];
  }

  Future<CommunityView> view(String crewId) async {
    final res = await _api.get('/communities/${_c(crewId)}');
    final m = res is Map ? res : const {};
    final members = <(RiderCard, String)>[];
    if (m['members'] is List) {
      for (final x in (m['members'] as List).whereType<Map>()) {
        members.add((RiderCard.fromJson(x), x['role']?.toString() ?? 'MEMBER'));
      }
    }
    return CommunityView(
      summary: CommunitySummary.fromJson(m['community'] is Map ? m['community'] as Map : const {}),
      members: members,
      rides: m['rides'] is List ? (m['rides'] as List).whereType<Map>().map(CommunityRide.fromJson).toList() : const [],
      open: m['members'] is List,
    );
  }

  /// Joins a public community or asks to join a private one. Returns (status MEMBER | REQUESTED, error).
  Future<(String?, String?)> join(String crewId) async {
    try {
      final res = await _api.post('/communities/${_c(crewId)}/join');
      return (res is Map ? res['status']?.toString() : null, null);
    } on ApiException catch (e) {
      return (null, e.message);
    } catch (_) {
      return (null, 'Could not reach CoRoute. Try again.');
    }
  }

  Future<String?> cancelRequest(String crewId) => _act(() => _api.delete('/communities/${_c(crewId)}/join'));

  Future<List<(RiderCard, int)>> requests(String crewId) async {
    final res = await _api.get('/crews/${_c(crewId)}/requests');
    final list = res is Map ? res['requests'] : null;
    return list is List ? [for (final m in list.whereType<Map>()) (RiderCard.fromJson(m), _i(m['createdAt']))] : const [];
  }

  Future<String?> decide(String crewId, String username, bool approve) =>
      _act(() => _api.post('/crews/${_c(crewId)}/requests/${Uri.encodeComponent(username)}/${approve ? 'approve' : 'decline'}'));

  Future<String?> setPhoto(String crewId, Uint8List bytes, String mime) => _act(() => _api.postBytes('/crews/${_c(crewId)}/photo', bytes, mime));
  Future<String?> removePhoto(String crewId) => _act(() => _api.delete('/crews/${_c(crewId)}/photo'));

  Future<(List<CommunityRide>, bool)> rides(String crewId) async {
    final res = await _api.get('/crews/${_c(crewId)}/rides');
    final m = res is Map ? res : const {};
    final list = m['rides'] is List ? (m['rides'] as List).whereType<Map>().map(CommunityRide.fromJson).toList() : <CommunityRide>[];
    return (list, m['canHost'] == true);
  }

  Future<String?> createRide(String crewId, {required String title, required String meetName, String destName = '', String notes = '', required DateTime startAt}) =>
      _act(() => _api.post('/crews/${_c(crewId)}/rides', {
            'title': title.trim(),
            'meetName': meetName.trim(),
            'destName': destName.trim(),
            'notes': notes.trim(),
            'startAt': startAt.millisecondsSinceEpoch,
          }));

  Future<String?> updateRide(String crewId, String rideId, {String? title, String? meetName, String? destName, String? notes, DateTime? startAt}) =>
      _act(() => _api.patch('/crews/${_c(crewId)}/rides/${_c(rideId)}', {
            if (title != null) 'title': title.trim(),
            if (meetName != null) 'meetName': meetName.trim(),
            if (destName != null) 'destName': destName.trim(),
            if (notes != null) 'notes': notes.trim(),
            if (startAt != null) 'startAt': startAt.millisecondsSinceEpoch,
          }));

  Future<String?> cancelRide(String crewId, String rideId) => _act(() => _api.delete('/crews/${_c(crewId)}/rides/${_c(rideId)}'));

  /// Interested (true) or not interested (false).
  Future<String?> answer(String crewId, String rideId, bool interested) =>
      _act(() => _api.post('/crews/${_c(crewId)}/rides/${_c(rideId)}/answer', {'answer': interested ? 'INTERESTED' : 'NOT_INTERESTED'}));
}
