import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/clubs_service.dart';
import '../../data/services/crews_service.dart';
import '../../data/services/friends_service.dart';
import '../../data/services/ride_invites_service.dart';
import '../score/leaderboard_screen.dart';
import '../score/rider_score_card.dart';
import '../widgets/feature_switch.dart';
import 'communities_rail.dart';
import 'people_screen.dart';
import 'rider_profile_screen.dart';
import 'user_avatar.dart';

/// v3.58 Community tab: search riders, requests waiting, crews and clubs (invites, Join with a code), the rider
/// score and leaderboard, friends and people you rode with. The full People hub (friends, crews, requests)
/// opens from here unchanged.
class CommunityScreen extends StatefulWidget {
  const CommunityScreen({super.key});

  static const String title = 'Community';

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  ClubsSnapshot? _clubs = ClubsService.cached();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  Future<void> _refresh() async {
    final api = context.read<ApiClient?>();
    final friends = context.read<FriendsService?>();
    final crews = context.read<CrewsService?>();
    final rides = context.read<RideInvitesService?>();
    await Future.wait<void>([
      if (friends != null) friends.refreshFriends(),
      if (friends != null) friends.refreshSuggestions(),
      if (crews != null) crews.refresh(),
      if (rides != null) rides.refresh(autoCheck: false),
      if (api != null)
        ClubsService(api).load().then((v) {
          if (mounted) setState(() => _clubs = v);
        }).catchError((Object _) {}),
    ]);
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _share() async {
    final svc = context.read<FriendsService>();
    if (svc.profile?.shareText == null) await svc.refreshProfile();
    final text = svc.profile?.shareText;
    if (!mounted) return;
    if (text == null) return showAppToast(context, 'Could not load your invite link. Try again.', error: true);
    await SharePlus.instance.share(ShareParams(text: text, subject: 'Ride with me on CoRoute'));
  }

  void _openPeople({PeopleSegment? segment, bool search = false}) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PeopleScreen(initial: segment, focusSearch: search)));

  @override
  Widget build(BuildContext context) {
    final friendsSvc = context.watch<FriendsService?>();
    final friendsOn = friendsSvc != null && context.featureOn(FriendsService.friendsFlag);
    final crewsOn = context.watch<CrewsService?>() != null && context.featureOn(CrewsService.crewsFlag);
    final badges = peopleBadgesOf(context);
    final friends = friendsOn ? friendsSvc.friends : const [];
    final suggestions = friendsOn ? friendsSvc.suggestions : const [];
    final photosOn = context.featureOn(FriendsService.photosFlag);
    final boardOn = context.featureOn('leaderboard');

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        bottom: false,
        child: ContentWidth(
          maxWidth: 680,
          child: AppRefresh(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
              physics: AppScrollBehavior.physics,
              children: [
                Row(
                  children: [
                    Expanded(child: Semantics(header: true, child: Text(CommunityScreen.title, style: AppText.headline.copyWith(fontSize: 28)))),
                    if (friendsOn) DsRoundButton(key: const Key('community_share'), icon: Icons.ios_share_rounded, label: 'Share my invite link', size: 48, onTap: _share),
                  ],
                ),
                const SizedBox(height: Space.s12),
                if (friendsOn)
                  Semantics(
                    button: true,
                    label: 'Search riders by username',
                    excludeSemantics: true,
                    child: Material(
                      color: AppTheme.card,
                      shape: RoundedRectangleBorder(borderRadius: Radii.mdAll, side: BorderSide(color: AppTheme.border)),
                      child: InkWell(
                        key: const Key('community_search'),
                        onTap: () => _openPeople(segment: PeopleSegment.friends, search: true),
                        child: Container(
                          height: 52,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Row(children: [Icon(Icons.search_rounded, color: AppTheme.text2), const SizedBox(width: 10), Text('Search riders by username', style: AppText.body.copyWith(color: AppTheme.textFaint))]),
                        ),
                      ),
                    ),
                  ),
                if (badges.requests > 0) ...[
                  const SizedBox(height: Space.s12),
                  DsCard(
                    key: const Key('community_requests'),
                    tinted: true,
                    onTap: () => _openPeople(segment: PeopleSegment.requests),
                    child: Row(
                      children: [
                        Icon(Icons.mark_email_unread_outlined, color: AppTheme.accentText),
                        const SizedBox(width: 12),
                        Expanded(child: Text('${badges.requests} ${badges.requests == 1 ? 'request is' : 'requests are'} waiting', style: AppText.title.copyWith(fontSize: 15))),
                        Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: Space.s24),
                CommunitiesRail(
                  title: 'Crews and clubs',
                  clubs: _clubs,
                  loading: !_loaded && _clubs == null,
                  onClubsChanged: _refresh,
                  onSeeAll: crewsOn ? () => _openPeople(segment: PeopleSegment.crews) : null,
                ),
                const SizedBox(height: Space.s24),
                const SectionTitle('Ride better together'),
                const SizedBox(height: Space.s8),
                const RiderScoreCard(),
                if (boardOn) ...[
                  const SizedBox(height: Space.s12),
                  DsCard(
                    key: const Key('community_leaderboard'),
                    onTap: () => LeaderboardScreen.open(context),
                    child: Row(
                      children: [
                        Icon(Icons.emoji_events_outlined, color: AppTheme.accent),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(LeaderboardScreen.title, style: AppText.title.copyWith(fontSize: 15)),
                              Text('Top riders by score, km, hours and rides', style: AppText.caption),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
                      ],
                    ),
                  ),
                ],
                if (friendsOn) ...[
                  const SizedBox(height: Space.s24),
                  SectionTitle('Friends', action: 'All friends', onAction: () => _openPeople(segment: PeopleSegment.friends)),
                  const SizedBox(height: Space.s8),
                  if (friends.isEmpty)
                    DsCard(
                      child: Row(
                        children: [
                          Icon(Icons.person_add_alt_1_outlined, color: AppTheme.accentText),
                          const SizedBox(width: 12),
                          Expanded(child: Text('Add riding friends by username or with your invite link.', style: AppText.label.copyWith(color: AppTheme.text))),
                          TextButton(onPressed: _share, style: TextButton.styleFrom(minimumSize: const Size(48, 48)), child: const Text('Invite')),
                        ],
                      ),
                    )
                  else
                    SizedBox(
                      height: 96,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: friends.length.clamp(0, 12),
                        separatorBuilder: (_, _) => const SizedBox(width: Space.s12),
                        itemBuilder: (_, i) {
                          final f = friends[i];
                          final name = f.displayName.isNotEmpty ? f.displayName : f.username;
                          return Semantics(
                            button: true,
                            label: 'Open $name',
                            excludeSemantics: true,
                            child: Pressable(
                              onTap: () => RiderProfileScreen.open(context, f.username),
                              child: SizedBox(
                                width: 64,
                                child: Column(
                                  children: [
                                    UserAvatar(label: name, avatarUrl: photosOn ? f.avatarUrl : null, size: 56),
                                    const SizedBox(height: 6),
                                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppTheme.text)),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  if (suggestions.isNotEmpty) ...[
                    const SizedBox(height: Space.s12),
                    DsCard(
                      onTap: () => _openPeople(segment: PeopleSegment.friends),
                      child: Row(
                        children: [
                          Icon(Icons.two_wheeler_outlined, color: AppTheme.accentText),
                          const SizedBox(width: 12),
                          Expanded(child: Text('${suggestions.length} ${suggestions.length == 1 ? 'rider' : 'riders'} you rode with', style: AppText.title.copyWith(fontSize: 15))),
                          Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
                        ],
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: Space.s24),
                DsCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(
                    children: [
                      if (friendsOn) DsListRow(icon: Icons.people_alt_outlined, label: 'Friends', onTap: () => _openPeople(segment: PeopleSegment.friends)),
                      if (crewsOn) DsListRow(icon: Icons.groups_outlined, label: 'Crews', onTap: () => _openPeople(segment: PeopleSegment.crews)),
                      DsListRow(icon: Icons.inbox_outlined, label: 'Requests', value: badges.requests > 0 ? '${badges.requests}' : null, divider: false, onTap: () => _openPeople(segment: PeopleSegment.requests)),
                    ],
                  ),
                ),
                if (!friendsOn && !crewsOn) ...[
                  const SizedBox(height: Space.s16),
                  Text('Friends and crews are turned off for now.', style: AppText.caption, textAlign: TextAlign.center),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
