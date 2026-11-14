import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/clubs_service.dart';
import '../../data/services/crews_service.dart';
import '../widgets/feature_switch.dart';
import 'club_widgets.dart';
import 'crew_create_flow.dart';
import 'crew_detail_screen.dart';
import 'people_screen.dart';

/// v3.58 "Riding communities": club and crew invites, clubs, crews, then "Join a club" and "Start a crew", as a
/// horizontal rail (Home and Community). Uses the existing crews and clubs APIs only.
class CommunitiesRail extends StatelessWidget {
  final ClubsSnapshot? clubs;
  final bool loading;
  final Future<void> Function() onClubsChanged;
  final VoidCallback? onSeeAll;
  final String title;
  const CommunitiesRail({super.key, required this.clubs, required this.loading, required this.onClubsChanged, this.onSeeAll, this.title = 'Riding communities'});

  @override
  Widget build(BuildContext context) {
    final crewsSvc = context.watch<CrewsService?>();
    final crewsOn = crewsSvc != null && context.featureOn(CrewsService.crewsFlag);
    final crews = crewsOn ? crewsSvc.crews : const <CrewSummary>[];
    final invites = crewsOn ? crewsSvc.invites : const <CrewInvite>[];
    final c = clubs ?? const ClubsSnapshot();
    final api = context.read<ApiClient?>();
    final cards = <Widget>[
      for (final i in c.invites)
        CommunityCard(
          title: i.name,
          meta: [if (i.city.isNotEmpty) i.city, 'Club invite'].join(' · '),
          icon: Icons.flag_outlined,
          action: 'Accept',
          onAction: api == null
              ? null
              : () async {
                  final err = await ClubsService(api).answer(i.inviteId, true);
                  if (!context.mounted) return;
                  showAppToast(context, err ?? 'You joined ${i.name}', error: err != null);
                  await onClubsChanged();
                },
        ),
      for (final i in invites)
        CommunityCard(
          title: i.crewName,
          meta: '${i.memberCount} ${i.memberCount == 1 ? 'member' : 'members'} · from @${i.invitedBy}',
          icon: Icons.mail_outline_rounded,
          action: 'View invite',
          onAction: () => PeopleScreen.open(context, segment: PeopleSegment.requests),
        ),
      for (final club in c.clubs)
        CommunityCard(
          title: club.name,
          meta: [if (club.city.isNotEmpty) club.city, '${club.members} members'].join(' · '),
          icon: Icons.flag_rounded,
          action: 'Open',
          onAction: () => ClubSheet.show(context, club),
        ),
      for (final crew in crews)
        CommunityCard(
          title: crew.name,
          meta: '${crew.memberCount} ${crew.memberCount == 1 ? 'member' : 'members'}${crew.openPolls > 0 ? ' · ${crew.openPolls} open poll${crew.openPolls == 1 ? '' : 's'}' : ''}',
          icon: Icons.groups_rounded,
          action: 'Open',
          onAction: () => CrewDetailScreen.open(context, crew.crewId),
        ),
      CommunityCard(
        title: 'Join a club',
        meta: 'Have a club link or code?',
        icon: Icons.qr_code_2_rounded,
        action: 'Join with code',
        outlined: true,
        onAction: api == null
            ? null
            : () async {
                final joined = await JoinClubSheet.show(context);
                if (joined == true) await onClubsChanged();
              },
      ),
      if (crewsOn)
        CommunityCard(
          title: 'Start a crew',
          meta: 'Your riding friends, polls and group rides',
          icon: Icons.add_circle_outline_rounded,
          action: 'Create',
          outlined: true,
          onAction: () async {
            final id = await CreateCrewFlow.open(context);
            if (id != null && context.mounted) CrewDetailScreen.open(context, id);
          },
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(title, action: onSeeAll == null ? null : 'See all', onAction: onSeeAll),
        const SizedBox(height: Space.s8),
        SizedBox(
          height: CommunityCard.height(context),
          child: loading && crews.isEmpty
              ? ListView(
                  scrollDirection: Axis.horizontal,
                  children: const [SizedBox(width: 220, child: SkeletonCard(lines: 2)), SizedBox(width: 12), SizedBox(width: 220, child: SkeletonCard(lines: 2))],
                )
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  physics: AppScrollBehavior.physics,
                  itemCount: cards.length,
                  separatorBuilder: (_, _) => const SizedBox(width: Space.s12),
                  itemBuilder: (_, i) => cards[i],
                ),
        ),
      ],
    );
  }
}

