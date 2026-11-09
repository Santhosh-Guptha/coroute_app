import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/rider_score_service.dart';
import '../../domain/score/rider_score.dart';
import '../widgets/feature_switch.dart';

/// 3.55 public leaderboard: top 10 riders by score, km, hours, rides and longest ride, all time,
/// usernames only. The rider's own row is highlighted, and their place is shown ("You: #42")
/// even when they are not in the top 10.
class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key});

  static const String title = 'Leaderboard';

  static Future<void> open(BuildContext context) async {
    if (!context.featureOnNow('leaderboard')) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('The leaderboard is turned off for now.')));
      return;
    }
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const LeaderboardScreen()));
  }

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  late final RiderScoreService _svc = RiderScoreService(context.read<ApiClient>());
  LeaderboardBoard _board = LeaderboardBoard.topScore;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _svc.loadLeaderboard());
  }

  @override
  void dispose() {
    _svc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: DsScreenHeader(
                    title: LeaderboardScreen.title,
                    subtitle: 'All time · usernames only',
                    onBack: () => Navigator.maybePop(context),
                  ),
                ),
                SizedBox(
                  height: 48,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    children: [
                      for (final b in LeaderboardBoard.values)
                        Padding(
                          padding: const EdgeInsets.only(right: Space.s8),
                          child: ChoiceChip(
                            key: Key('leaderboard_tab_${b.key}'),
                            label: Text(b.title),
                            selected: _board == b,
                            onSelected: (_) => setState(() => _board = b),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: Space.s8),
                Expanded(
                  child: ListenableBuilder(
                    listenable: _svc,
                    builder: (context, _) => RefreshIndicator(
                      color: AppTheme.accentText,
                      onRefresh: _svc.loadLeaderboard,
                      child: _body(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    final lb = _svc.leaderboard;
    final pos = _svc.position;
    if (lb == null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        children: [
          const SizedBox(height: Space.s32),
          if (_svc.error != null)
            EmptyState(icon: Icons.cloud_off_rounded, title: 'Leaderboard not loaded', message: _svc.error, primaryLabel: 'Try again', onPrimary: _svc.loadLeaderboard)
          else
            const Center(child: CircularProgressIndicator()),
        ],
      );
    }
    final rows = lb.rows(_board);
    final me = pos?.username;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      children: [
        if (pos != null)
          DsCard(
            key: const Key('leaderboard_my_place'),
            tinted: true,
            child: Row(
              children: [
                Icon(Icons.person_pin_rounded, color: AppTheme.accentText),
                const SizedBox(width: Space.s12),
                Expanded(child: Text(pos.line(_board), style: AppText.title)),
              ],
            ),
          ),
        const SizedBox(height: Space.s12),
        if (rows.isEmpty)
          const EmptyState(
            icon: Icons.emoji_events_rounded,
            title: 'No riders here yet',
            message: 'Riders appear after 3 rides of 10 km or more, with a username and the leaderboard on.',
          )
        else
          DsCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++)
                  _Row(
                    place: i + 1,
                    row: rows[i],
                    board: _board,
                    mine: me != null && rows[i].username == me,
                    divider: i < rows.length - 1,
                  ),
              ],
            ),
          ),
        const SizedBox(height: Space.s16),
        Text(
          'Only usernames and rounded totals are shown. Turn the leaderboard off in your profile to leave it. '
          'Score ranks safe riding; speed never earns points.',
          textAlign: TextAlign.center,
          style: AppText.caption,
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  final int place;
  final LeaderboardRow row;
  final LeaderboardBoard board;
  final bool mine;
  final bool divider;
  const _Row({required this.place, required this.row, required this.board, required this.mine, required this.divider});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${mine ? 'You, ' : ''}place $place, ${row.username}, ${board.format(row.value)}',
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        decoration: BoxDecoration(
          color: mine ? AppTheme.tint : null,
          border: divider ? Border(bottom: BorderSide(color: AppTheme.border)) : null,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            SizedBox(width: 36, child: Text('#$place', style: AppText.title.copyWith(color: place <= 3 ? AppTheme.accentText : AppTheme.text2))),
            Expanded(
              child: Text(
                mine ? '${row.username} (you)' : row.username,
                style: AppText.body.copyWith(fontWeight: mine ? FontWeight.w700 : FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(board.format(row.value), style: AppText.title),
          ],
        ),
      ),
    );
  }
}
