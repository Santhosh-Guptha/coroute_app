import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/clubs_service.dart';
import '../../domain/home/home_feed.dart';

/// v3.58: one card in a horizontal "Riding communities" rail (Home and Community): our own art (no club photos
/// are stored), the name, one meta line and one action. 220 dp wide, the action is a 48 dp button.
class CommunityCard extends StatelessWidget {
  final String title;
  final String meta;
  final IconData icon;
  final String action;
  final VoidCallback? onAction;

  /// Dashed outline card for "Join a club" / "Start a crew".
  final bool outlined;

  const CommunityCard({super.key, required this.title, required this.meta, required this.icon, required this.action, required this.onAction, this.outlined = false});

  static const double width = 220;

  /// Grows with large text so nothing is cut off.
  static double height(BuildContext context) {
    final s = MediaQuery.textScalerOf(context).scale(1);
    return 214.0 + (s > 1 ? (s - 1) * 110 : 0);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: DsCard(
        dashed: outlined,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 78,
              width: double.infinity,
              child: outlined
                  ? Container(
                      decoration: BoxDecoration(color: AppTheme.tint, borderRadius: Radii.mdAll),
                      child: Icon(icon, size: 34, color: AppTheme.accentText),
                    )
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        PlaceArt(seed: title, borderRadius: Radii.mdAll),
                        Align(
                          alignment: Alignment.center,
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.92), shape: BoxShape.circle),
                            child: Icon(icon, color: AppTheme.primaryFill, size: 24),
                          ),
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 10),
            Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
            const SizedBox(height: 2),
            Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 15)),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44), shape: const StadiumBorder(), side: BorderSide(color: AppTheme.border2)),
                child: Text(action, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppTheme.text, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A club the rider is in: city, members, the next rides the organiser scheduled, and Leave.
class ClubSheet extends StatelessWidget {
  final ClubSummary club;
  const ClubSheet({super.key, required this.club});

  static Future<void> show(BuildContext context, ClubSummary club) =>
      showAppSheet<void>(context, title: club.name, isScrollControlled: true, builder: (_) => SingleChildScrollView(child: ClubSheet(club: club)));

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (club.typeLabel.isNotEmpty) InfoPill(icon: Icons.flag_outlined, text: club.typeLabel),
            if (club.city.isNotEmpty) InfoPill(icon: Icons.place_outlined, text: club.city),
            InfoPill(icon: Icons.groups_outlined, text: '${club.members} members'),
          ],
        ),
        const SizedBox(height: Space.s16),
        Text('Next rides', style: AppText.overline),
        const SizedBox(height: Space.s8),
        if (club.upcoming.isEmpty)
          Text('No ride scheduled yet. The organiser will post the next one here.', style: AppText.body.copyWith(color: AppTheme.text2))
        else
          DsCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Column(
              children: [
                for (var i = 0; i < club.upcoming.length; i++)
                  DsListRow(
                    icon: Icons.event_rounded,
                    label: club.upcoming[i].meetName.isEmpty ? club.upcoming[i].title : '${club.upcoming[i].title} · ${club.upcoming[i].meetName}',
                    value: UpcomingFeed.whenLabel(club.upcoming[i].startsAt, now: now),
                    divider: i < club.upcoming.length - 1,
                  ),
              ],
            ),
          ),
        const SizedBox(height: Space.s16),
        Text(
          'Clubs see your username and first name, and your live position only during their rides. Your phone, e-mail and Medical ID stay private.',
          style: AppText.caption,
        ),
        const SizedBox(height: Space.s8),
      ],
    );
  }
}

/// "Join a club with a code" (the code from the club's link). Pops true when joined.
class JoinClubSheet extends StatefulWidget {
  const JoinClubSheet({super.key});

  static Future<bool?> show(BuildContext context) =>
      showAppSheet<bool>(context, title: 'Join a club', isScrollControlled: true, builder: (_) => const SingleChildScrollView(child: JoinClubSheet()));

  @override
  State<JoinClubSheet> createState() => _JoinClubSheetState();
}

class _JoinClubSheetState extends State<JoinClubSheet> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final api = context.read<ApiClient?>();
    if (api == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final (name, err) = await ClubsService(api).joinWithCode(_code.text);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    showAppToast(context, name == null ? 'Request sent to the club' : 'You joined $name');
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final err = _error;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Clubs share a join link. Paste its code here.', style: AppText.body.copyWith(color: AppTheme.text2)),
        const SizedBox(height: Space.s16),
        TextField(
          key: const Key('join_club_code'),
          controller: _code,
          enabled: !_busy,
          autofocus: true,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => _join(),
          decoration: const InputDecoration(labelText: 'Club code', prefixIcon: Icon(Icons.qr_code_2_rounded)),
        ),
        if (err != null) ...[
          const SizedBox(height: Space.s8),
          Text(err, style: AppText.label.copyWith(color: AppTheme.sos)),
        ],
        const SizedBox(height: Space.s16),
        DsButton(label: 'Join', loading: _busy, onPressed: _join),
        const SizedBox(height: Space.s8),
      ],
    );
  }
}
